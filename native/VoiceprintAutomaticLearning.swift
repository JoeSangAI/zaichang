import Foundation
import CryptoKit

// Automatic evidence is a reversible supplement to manual references. It is
// deliberately excluded from the human profile projection and from all later
// candidate qualification.
struct VoiceprintAutomaticReplay:Codable,Equatable {
    let correct:Int
    let wrong:Int
    let unknown:Int
    let lostPreviouslyCorrect:Int
    let newlyWrong:Int
    var passes:Bool {
        correct>=0 && wrong>=0 && unknown>=0 && lostPreviouslyCorrect==0 && newlyWrong==0
    }
}
struct VoiceprintAutomaticEvidence:Codable,Equatable {
    let key:SessionSpeakerKey
    let support:[VoiceprintEvidenceRef]
    let anchorConfirmationIDs:[String]
    let sourceArchiveRevision:Int
    let replayBefore:VoiceprintAutomaticReplay
    let replayAfter:VoiceprintAutomaticReplay
}
struct VoiceprintAutomaticSupport {
    let evidence:VoiceprintEvidenceRef
    let sample:VoiceprintSample
}
struct VoiceprintAutomaticCandidate {
    let personID:String
    let key:SessionSpeakerKey
    let support:[VoiceprintAutomaticSupport]
    let anchorConfirmationIDs:[String]
    let sourceArchiveRevision:Int
}
struct VoiceprintAutomaticLearningResult {
    let archive:VoiceprintArchive
    let accepted:Bool
    let reason:String?
    let before:VoiceprintAutomaticReplay
    let after:VoiceprintAutomaticReplay
}

let voiceprintMaximumAutomaticSamplesPerPerson=16

private func automaticKeyIsValid(_ key:SessionSpeakerKey)->Bool {
    guard !key.session.isEmpty,key.session.count<=160,isTranscriptAudioTrack(key.source),
          !key.epoch.isEmpty,key.epoch.count<=160,
          let slot=Int(key.identity.replacingOccurrences(of:"slot:",with:"")),
          key.identity=="slot:\(slot)",(0..<8).contains(slot) else{return false}
    return true
}

private func automaticContributionID(personID:String,key:SessionSpeakerKey,support:[VoiceprintEvidenceRef])->String {
    let refs=support.map{"\($0.id)@\($0.revision)"}.sorted().joined(separator:"\u{1f}")
    let material=["voiceprint-auto-v1",personID,key.session,key.source,key.epoch,key.identity,refs].joined(separator:"\u{1e}")
    var bytes=Array(SHA256.hash(data:Data(material.utf8)).prefix(16))
    bytes[6]=(bytes[6]&0x0f)|0x50
    bytes[8]=(bytes[8]&0x3f)|0x80
    let hex=bytes.map{String(format:"%02x",$0)}.joined()
    return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
}

func validAutomaticVoiceEvidence(_ value:VoiceprintAutomaticEvidence,samples:[VoiceprintSample])->Bool {
    guard automaticKeyIsValid(value.key),(3...8).contains(samples.count),value.support.count==samples.count,
          value.sourceArchiveRevision>=1,value.anchorConfirmationIDs.count<=512,
          Set(value.anchorConfirmationIDs).count==value.anchorConfirmationIDs.count,
          value.anchorConfirmationIDs.allSatisfy({UUID(uuidString:$0) != nil}),
          Set(value.support.map(\.id)).count==value.support.count,
          value.support.allSatisfy({!$0.id.isEmpty && $0.id.count<=256 && $0.revision>=0}),
          value.replayAfter.correct>value.replayBefore.correct,
          value.replayAfter.wrong<=value.replayBefore.wrong,
          value.replayAfter.lostPreviouslyCorrect==0,value.replayAfter.newlyWrong==0,
          value.replayBefore.lostPreviouslyCorrect==0,value.replayBefore.newlyWrong==0 else{return false}
    guard samples.allSatisfy({$0.session==value.key.session && $0.source==value.key.source && $0.epoch==value.key.epoch}) else{return false}
    for i in samples.indices {for j in samples.indices where j>i {
        if voiceSampleOverlap(samples[i],samples[j]) || voiceSimilarity(samples[i],samples[j])<0.60 {return false}
    }}
    return true
}

func validAutomaticVoiceLedger(_ ledger:VoiceprintLearningLedger)->Bool {
    let manual=ledger.contributions.filter{$0.automatic==nil}
    let automatic=ledger.contributions.filter{$0.automatic != nil}
    let people=Set(ledger.baseline.map(\.id)+manual.map(\.personID))
    guard automatic.allSatisfy({people.contains($0.personID)}) else{return false}
    var sourceKeys=Set<String>()
    for contribution in automatic {
        guard let evidence=contribution.automatic,
              validAutomaticVoiceEvidence(evidence,samples:contribution.samples),
              evidence.key.session==contribution.session,
              contribution.confirmationID==automaticContributionID(personID:contribution.personID,key:evidence.key,support:evidence.support),
              Set(evidence.anchorConfirmationIDs).allSatisfy({id in
                  manual.contains(where:{$0.confirmationID==id && $0.personID==contribution.personID})
              }) else{return false}
        let source="\(evidence.key.session)\u{1f}\(evidence.key.source)\u{1f}\(evidence.key.epoch)\u{1f}\(evidence.key.identity)"
        guard sourceKeys.insert(source).inserted else{return false}
        if evidence.anchorConfirmationIDs.isEmpty && !ledger.baseline.contains(where:{$0.id==contribution.personID}) {return false}
    }
    return true
}

private func activeAutomaticAnchorIDs(_ ledger:VoiceprintLearningLedger,personID:String)->Set<String> {
    Set(ledger.contributions.filter{$0.automatic==nil && $0.personID==personID && !ledger.revokedConfirmationIDs.contains($0.confirmationID)}.map(\.confirmationID))
}

func activeAutomaticVoiceSamples(archive:VoiceprintArchive,personID:String)->[VoiceprintSample] {
    guard let ledger=archive.learning else{return []}
    let allManual=ledger.contributions.filter{$0.automatic==nil && !ledger.revokedConfirmationIDs.contains($0.confirmationID)}.flatMap(\.samples)
    let active=ledger.contributions.reversed().filter { contribution in
        guard contribution.personID==personID,!ledger.revokedConfirmationIDs.contains(contribution.confirmationID),
              let evidence=contribution.automatic else{return false}
        let anchors=activeAutomaticAnchorIDs(ledger,personID:personID)
        guard evidence.anchorConfirmationIDs.allSatisfy(anchors.contains),
              (evidence.anchorConfirmationIDs.isEmpty && ledger.baseline.contains(where:{$0.id==personID}) || !evidence.anchorConfirmationIDs.isEmpty) else{return false}
        // A later manual correction on the same source interval supersedes
        // automatic evidence even when a baseline voice is the dependency.
        return !contribution.samples.contains(where:{auto in allManual.contains(where:{voiceSampleOverlap($0,auto)})})
    }
    var selected:[VoiceprintSample]=[]
    let human=(archive.people.first(where:{$0.id==personID})?.samples ?? [])
    for sample in active.flatMap(\.samples) {
        guard selected.count<voiceprintMaximumAutomaticSamplesPerPerson,
              !human.contains(where:{voiceSampleOverlap($0,sample)}),
              !selected.contains(where:{voiceSampleOverlap($0,sample)}) else{continue}
        selected.append(sample)
    }
    return selected
}

private func automaticHumanLabels(_ ledger:VoiceprintLearningLedger)->[(sample:VoiceprintSample,personID:String)] {
    let manual=ledger.contributions.filter{$0.automatic==nil && !ledger.revokedConfirmationIDs.contains($0.confirmationID)}
    var rows:[(VoiceprintSample,String)]=[]
    for person in ledger.baseline {for sample in person.samples {
        if rows.contains(where:{voiceSampleOverlap($0.0,sample)}) {continue}
        rows.append((sample,person.id))
    }}
    for contribution in manual {for sample in contribution.samples {
        if rows.contains(where:{voiceSampleOverlap($0.0,sample) && $0.1==contribution.personID}) {continue}
        rows.append((sample,contribution.personID))
    }}
    return rows
}

private func automaticReplay(_ archive:VoiceprintArchive,isCurrent:()->Bool)->VoiceprintAutomaticReplay? {
    guard let ledger=archive.learning else{return VoiceprintAutomaticReplay(correct:0,wrong:0,unknown:0,lostPreviouslyCorrect:0,newlyWrong:0)}
    let labels=automaticHumanLabels(ledger)
    var tables:[String:VoiceprintReferenceTable]=[:]
    var correct=0,wrong=0,unknown=0,ambiguous=0
    for row in labels {
        guard isCurrent() else{return nil}
        let colliding=labels.filter{voiceSampleOverlap($0.sample,row.sample)}
        let identities=Set(colliding.map(\.personID))
        guard identities.count==1 else{ambiguous+=1;continue}
        let table=tables[row.sample.session] ?? VoiceprintReferenceTable(archive:archive,excludingSession:row.sample.session,includingAutomatic:true)
        tables[row.sample.session]=table
        let scores=table.scores(row.sample.vector)
        guard let best=scores.first,best.1>=0.60,
              best.1-(scores.dropFirst().first?.1 ?? 0)>=0.14 else{unknown+=1;continue}
        if best.0==row.personID {correct+=1}else{wrong+=1}
    }
    _ = ambiguous
    return VoiceprintAutomaticReplay(correct:correct,wrong:wrong,unknown:unknown,lostPreviouslyCorrect:0,newlyWrong:0)
}

private func automaticReplayComparison(_ before:VoiceprintAutomaticReplay,_ after:VoiceprintAutomaticReplay,beforeArchive:VoiceprintArchive,afterArchive:VoiceprintArchive,isCurrent:()->Bool)->VoiceprintAutomaticReplay? {
    guard let ledger=beforeArchive.learning else{return VoiceprintAutomaticReplay(correct:0,wrong:0,unknown:0,lostPreviouslyCorrect:0,newlyWrong:0)}
    let labels=automaticHumanLabels(ledger)
    var oldTables:[String:VoiceprintReferenceTable]=[:],freshTables:[String:VoiceprintReferenceTable]=[:]
    var lost=0,newWrong=0
    for row in labels {
        guard isCurrent() else{return nil}
        let colliding=labels.filter{voiceSampleOverlap($0.sample,row.sample)}
        guard Set(colliding.map(\.personID)).count==1 else{continue}
        let session=row.sample.session
        let oldTable=oldTables[session] ?? VoiceprintReferenceTable(archive:beforeArchive,excludingSession:session,includingAutomatic:true)
        let freshTable=freshTables[session] ?? VoiceprintReferenceTable(archive:afterArchive,excludingSession:session,includingAutomatic:true)
        oldTables[session]=oldTable;freshTables[session]=freshTable
        let old=oldTable.scores(row.sample.vector),fresh=freshTable.scores(row.sample.vector)
        func classification(_ scores:[(String,Double)])->String? {
            guard let top=scores.first,top.1>=0.60,top.1-(scores.dropFirst().first?.1 ?? 0)>=0.14 else{return nil}
            return top.0
        }
        let oldResult=classification(old),newResult=classification(fresh)
        if oldResult==row.personID && newResult != row.personID {lost+=1}
        if oldResult == nil && newResult != nil && newResult != row.personID {newWrong+=1}
    }
    return VoiceprintAutomaticReplay(correct:after.correct,wrong:after.wrong,unknown:after.unknown,lostPreviouslyCorrect:lost,newlyWrong:newWrong)
}

private func rejectedAutomatic(_ archive:VoiceprintArchive,reason:String,before:VoiceprintAutomaticReplay?=nil,isCurrent:()->Bool)->VoiceprintAutomaticLearningResult {
    let metrics=before ?? automaticReplay(archive,isCurrent:isCurrent) ?? VoiceprintAutomaticReplay(correct:0,wrong:0,unknown:0,lostPreviouslyCorrect:0,newlyWrong:0)
    return VoiceprintAutomaticLearningResult(archive:archive,accepted:false,reason:reason,before:metrics,after:metrics)
}

func proposeAutomaticVoiceprintContribution(_ old:VoiceprintArchive,candidate:VoiceprintAutomaticCandidate,domain:String,now:Date=Date(),isCurrent:()->Bool={true})throws->VoiceprintAutomaticLearningResult {
    _ = try old.validated(domain:domain)
    guard let before=automaticReplay(old,isCurrent:isCurrent) else{return rejectedAutomatic(old,reason:"cancelled",isCurrent:isCurrent)}
    guard isCurrent() else{return rejectedAutomatic(old,reason:"cancelled",before:before,isCurrent:isCurrent)}
    guard old.schema==2,let ledger=old.learning else{return rejectedAutomatic(old,reason:"schema",before:before,isCurrent:isCurrent)}
    guard candidate.sourceArchiveRevision==old.revision else{return rejectedAutomatic(old,reason:"stale_archive",before:before,isCurrent:isCurrent)}
    guard automaticKeyIsValid(candidate.key),(3...8).contains(candidate.support.count),
          candidate.support.allSatisfy({$0.sample.session==candidate.key.session && $0.sample.source==candidate.key.source && $0.sample.epoch==candidate.key.epoch}),
          Set(candidate.support.map(\.evidence.id)).count==candidate.support.count,
          candidate.support.allSatisfy({!$0.evidence.id.isEmpty && $0.evidence.id.count<=256 && $0.evidence.revision>=0}) else{return rejectedAutomatic(old,reason:"invalid_support",before:before,isCurrent:isCurrent)}
    guard let target=old.people.first(where:{$0.id==candidate.personID}),target.enabled else{return rejectedAutomatic(old,reason:"unknown_or_disabled_person",before:before,isCurrent:isCurrent)}
    let activeHuman=ledger.contributions.filter{$0.automatic==nil && !ledger.revokedConfirmationIDs.contains($0.confirmationID)}
    let targetAnchors=Set(activeHuman.filter{$0.personID==candidate.personID}.map(\.confirmationID))
    guard Set(candidate.anchorConfirmationIDs).count==candidate.anchorConfirmationIDs.count,
          (candidate.anchorConfirmationIDs.isEmpty ? ledger.baseline.contains(where:{$0.id==candidate.personID}) : candidate.anchorConfirmationIDs.allSatisfy(targetAnchors.contains)) else{return rejectedAutomatic(old,reason:"invalid_anchor",before:before,isCurrent:isCurrent)}
    if targetAnchors.isEmpty {
        guard candidate.anchorConfirmationIDs.isEmpty,ledger.baseline.contains(where:{$0.id==candidate.personID}) else{return rejectedAutomatic(old,reason:"missing_human_anchor",before:before,isCurrent:isCurrent)}
    } else if candidate.anchorConfirmationIDs.isEmpty {return rejectedAutomatic(old,reason:"missing_human_anchor",before:before,isCurrent:isCurrent)}
    let samples=candidate.support.sorted{$0.evidence.id<$1.evidence.id}.map(\.sample)
    for i in samples.indices {for j in samples.indices where j>i {
        guard isCurrent() else{return rejectedAutomatic(old,reason:"cancelled",before:before,isCurrent:isCurrent)}
        guard !voiceSampleOverlap(samples[i],samples[j]),voiceSimilarity(samples[i],samples[j])>=0.60 else{return rejectedAutomatic(old,reason:"incoherent_support",before:before,isCurrent:isCurrent)}
    }}
    let allManual=ledger.baseline.flatMap(\.samples)+activeHuman.flatMap(\.samples)
    guard !samples.contains(where:{candidateSample in allManual.contains(where:{voiceSampleOverlap($0,candidateSample)})}) else{return rejectedAutomatic(old,reason:"manual_overlap",before:before,isCurrent:isCurrent)}
    let humanOnly=VoiceprintReferenceTable(archive:VoiceprintArchive(schema:1,partition:old.partition,inputKind:old.inputKind,revision:old.revision,people:old.people,learning:nil),excludingSession:candidate.key.session,includingAutomatic:false)
    for sample in samples {
        guard isCurrent() else{return rejectedAutomatic(old,reason:"cancelled",before:before,isCurrent:isCurrent)}
        let scores=humanOnly.scores(sample.vector)
        guard let top=scores.first,top.0==candidate.personID,top.1>=0.60,
              top.1-(scores.dropFirst().first?.1 ?? 0)>=0.14 else{return rejectedAutomatic(old,reason:"human_match_gate",before:before,isCurrent:isCurrent)}
    }
    let id=automaticContributionID(personID:candidate.personID,key:candidate.key,support:candidate.support.map(\.evidence))
    if ledger.revokedConfirmationIDs.contains(id) {return rejectedAutomatic(old,reason:"revoked",before:before,isCurrent:isCurrent)}
    if ledger.contributions.contains(where:{contribution in
        contribution.automatic?.key==candidate.key && ledger.revokedConfirmationIDs.contains(contribution.confirmationID)
    }) {return rejectedAutomatic(old,reason:"revoked_source",before:before,isCurrent:isCurrent)}
    if let sameSource=ledger.contributions.first(where:{$0.automatic?.key==candidate.key}) {
        if sameSource.confirmationID==id && sameSource.personID==candidate.personID && sameSource.samples==samples && sameSource.automatic?.anchorConfirmationIDs==candidate.anchorConfirmationIDs.sorted() {
            return VoiceprintAutomaticLearningResult(archive:old,accepted:false,reason:"duplicate",before:before,after:before)
        }
        return rejectedAutomatic(old,reason:"source_already_learned",before:before,isCurrent:isCurrent)
    }
    guard !ledger.contributions.contains(where:{$0.confirmationID==id}) else{return rejectedAutomatic(old,reason:"id_collision",before:before,isCurrent:isCurrent)}
    let refs=candidate.support.sorted{$0.evidence.id<$1.evidence.id}.map(\.evidence)
    let anchors=candidate.anchorConfirmationIDs.sorted()
    // Replay against the exact in-memory ledger projection that would be
    // committed. This applies the same per-person 16-reference cap/order and
    // session exclusion as all subsequent matching calls.
    let provisionalEvidence=VoiceprintAutomaticEvidence(key:candidate.key,support:refs,anchorConfirmationIDs:anchors,sourceArchiveRevision:old.revision,
        replayBefore:before,replayAfter:before)
    let provisional=VoiceprintLearningContribution(confirmationID:id,personID:target.id,name:target.name,sharedPerson:target.sharedPerson,
        confirmedAt:ISO8601DateFormatter().string(from:now),samples:samples,automatic:provisionalEvidence)
    var probeLedger=ledger
    probeLedger.contributions.append(provisional)
    guard probeLedger.contributions.count<=voiceprintMaximumContributions,
          probeLedger.contributions.reduce(0,{$0+$1.samples.count})<=voiceprintMaximumContributionSamples else{return rejectedAutomatic(old,reason:"capacity",before:before,isCurrent:isCurrent)}
    let probe=VoiceprintArchive(schema:2,partition:old.partition,inputKind:old.inputKind,revision:old.revision+1,people:old.people,learning:probeLedger)
    guard let afterCounts=automaticReplay(probe,isCurrent:isCurrent) else{return rejectedAutomatic(old,reason:"cancelled",before:before,isCurrent:isCurrent)}
    guard let after=automaticReplayComparison(before,afterCounts,beforeArchive:old,afterArchive:probe,isCurrent:isCurrent) else{return rejectedAutomatic(old,reason:"cancelled",before:before,isCurrent:isCurrent)}
    guard isCurrent() else{return rejectedAutomatic(old,reason:"cancelled",before:before,isCurrent:isCurrent)}
    guard after.correct>before.correct,after.lostPreviouslyCorrect==0,
          after.wrong<=before.wrong,after.newlyWrong==0 else{
        return VoiceprintAutomaticLearningResult(archive:old,accepted:false,reason:"replay_gate",before:before,after:after)
    }
    let evidence=VoiceprintAutomaticEvidence(key:candidate.key,support:refs,anchorConfirmationIDs:anchors,sourceArchiveRevision:old.revision,
        replayBefore:VoiceprintAutomaticReplay(correct:before.correct,wrong:before.wrong,unknown:before.unknown,lostPreviouslyCorrect:0,newlyWrong:0),
        replayAfter:after)
    let contribution=VoiceprintLearningContribution(confirmationID:id,personID:target.id,name:target.name,sharedPerson:target.sharedPerson,
        confirmedAt:ISO8601DateFormatter().string(from:now),samples:samples,automatic:evidence)
    var nextLedger=ledger
    nextLedger.contributions.append(contribution)
    guard nextLedger.contributions.count<=voiceprintMaximumContributions,
          nextLedger.contributions.reduce(0,{$0+$1.samples.count})<=voiceprintMaximumContributionSamples else{return rejectedAutomatic(old,reason:"capacity",before:before,isCurrent:isCurrent)}
    let next=try archiveWithVoiceLedger(old,ledger:nextLedger,domain:domain)
    return VoiceprintAutomaticLearningResult(archive:next,accepted:true,reason:nil,before:before,after:after)
}
