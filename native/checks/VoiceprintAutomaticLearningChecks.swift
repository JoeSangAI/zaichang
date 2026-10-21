import Foundation

// Synthetic and frozen-feature replay checks. Frozen inputs contain only saved
// embeddings and labels; this helper never opens recordings or meeting audio.
func voiceprintAutomaticLearningChecks()throws->[String] {
    let domain="synthetic_model_output",time="2026-10-08T12:00:00Z"
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:name)};checks.append(name)}
    func vector(_ degrees:Double)->[Double] {
        let angle=degrees * .pi / 180
        var v=[Double](repeating:0,count:192);v[0]=cos(angle);v[1]=sin(angle);return v
    }
    func person(_ id:String,_ name:String,_ degrees:Double,_ session:String="baseline",_ enabled:Bool=true)->VoiceprintPerson {
        let samples=(0..<12).map{i in VoiceprintSample(session:session,source:"mic",epoch:"epoch",start:Double(i*5),end:Double(i*5+2),vector:vector(degrees))}
        return VoiceprintPerson(id:id,name:name,authorizedAt:time,enabled:enabled,samples:samples)
    }
    func sample(_ degrees:Double,_ session:String,_ index:Int,_ epoch:String="epoch")->VoiceprintSample {
        VoiceprintSample(session:session,source:"mic",epoch:epoch,start:Double(index*5),end:Double(index*5+2),vector:vector(degrees))
    }
    func base(_ people:[VoiceprintPerson])->VoiceprintArchive {
        let ledger=VoiceprintLearningLedger(baseline:people,contributions:[],revokedConfirmationIDs:[],enabledOverrides:[:])
        return VoiceprintArchive(schema:2,partition:SpeakerEmbeddingBackend.partition,inputKind:domain,revision:1,people:people,learning:ledger)
    }
    func contribution(_ id:String,_ personID:String,_ name:String,_ sample:VoiceprintSample)->VoiceprintLearningContribution {
        VoiceprintLearningContribution(confirmationID:id,personID:personID,name:name,confirmedAt:time,samples:[sample])
    }
    func candidate(_ id:String,_ personID:String,_ key:SessionSpeakerKey,_ degrees:Double,_ anchors:[String],_ revision:Int)->VoiceprintAutomaticCandidate {
        let support=(0..<3).map { i -> VoiceprintAutomaticSupport in
            let evidence=VoiceprintEvidenceRef(id:"\(id)-\(i)",revision:0)
            return VoiceprintAutomaticSupport(evidence:evidence,sample:sample(degrees,key.session,i,key.epoch))
        }
        return VoiceprintAutomaticCandidate(personID:personID,key:key,support:support,anchorConfirmationIDs:anchors,sourceArchiveRevision:revision)
    }
    func key(_ session:String,_ epoch:String="auto-epoch")->SessionSpeakerKey {
        SessionSpeakerKey(session:session,source:"mic",epoch:epoch,identity:"slot:0")
    }

    // Human-only query at cosine .59 stays unknown; coherent .62 support moves
    // it over the existing threshold without changing the projected people.
    let aid=UUID().uuidString
    let baseline=person(aid,"合成人物",0)
    let manualID=UUID().uuidString
    let labeled=try archiveAddingVoiceConfirmation(base([baseline]),contribution:contribution(manualID,aid,"合成人物",sample(53.84,"human-query",0)),domain:domain)
    let originalPeople=labeled.people
    let source=key("automatic-positive")
    let proposed=try proposeAutomaticVoiceprintContribution(labeled,candidate:candidate("positive",aid,source,51.68,[manualID],labeled.revision),domain:domain)
    try check(proposed.accepted && proposed.after.correct>proposed.before.correct && proposed.after.wrong<=proposed.before.wrong,"coherent_human_anchored_candidate_adds_cross_meeting_correct_match")
    try check(proposed.archive.people==originalPeople,"automatic_layer_does_not_change_human_projection")
    try check(activeAutomaticVoiceSamples(archive:proposed.archive,personID:aid).count==3,"automatic_support_is_available_only_as_bounded_supplement")
    let autoRecord=proposed.archive.learning!.contributions.first{$0.automatic != nil}!
    let retry=VoiceprintAutomaticCandidate(personID:aid,key:source,support:candidate("positive",aid,source,51.68,[manualID],proposed.archive.revision).support,anchorConfirmationIDs:[manualID],sourceArchiveRevision:proposed.archive.revision)
    let duplicate=try proposeAutomaticVoiceprintContribution(proposed.archive,candidate:retry,domain:domain)
    try check(!duplicate.accepted && duplicate.reason=="duplicate" && duplicate.archive.revision==proposed.archive.revision,"same_source_retry_is_idempotent")
    let withoutAnchor=try archiveRevokingVoiceConfirmation(proposed.archive,confirmationID:manualID,domain:domain)
    try check(activeAutomaticVoiceSamples(archive:withoutAnchor,personID:aid).isEmpty,"revoking_human_anchor_immediately_hides_automatic_support")
    let afterAutoRevoke=try archiveRevokingVoiceConfirmation(proposed.archive,confirmationID:autoRecord.confirmationID,domain:domain)
    let revokedCandidate=VoiceprintAutomaticCandidate(personID:aid,key:source,support:retry.support,anchorConfirmationIDs:[manualID],sourceArchiveRevision:afterAutoRevoke.revision)
    let cannotResurrect=try proposeAutomaticVoiceprintContribution(afterAutoRevoke,candidate:revokedCandidate,domain:domain)
    try check(!cannotResurrect.accepted && ["revoked","revoked_source"].contains(cannotResurrect.reason ?? ""),"revoked_automatic_source_cannot_resurrect")
    let another=key("automatic-no-self-anchor")
    let automaticOnly=try proposeAutomaticVoiceprintContribution(proposed.archive,candidate:candidate("automatic-only",aid,another,100,[manualID],proposed.archive.revision),domain:domain)
    try check(!automaticOnly.accepted && automaticOnly.reason=="human_match_gate","automatic_samples_never_qualify_future_candidates")
    let unknown=try proposeAutomaticVoiceprintContribution(labeled,candidate:candidate("unknown-person",UUID().uuidString,source,51.68,[manualID],labeled.revision),domain:domain)
    try check(!unknown.accepted && unknown.reason=="unknown_or_disabled_person","automatic_learning_cannot_create_a_person")
    let cancelled=try proposeAutomaticVoiceprintContribution(labeled,candidate:candidate("cancelled",aid,source,51.68,[manualID],labeled.revision),domain:domain,isCurrent:{false})
    try check(!cancelled.accepted && cancelled.reason=="cancelled","cancellation_stops_candidate_replay")

    // Previously unknown B-labeled audio becomes a wrong A name: reject it.
    let bid=UUID().uuidString
    let a=person(UUID().uuidString,"A",0),b=person(bid,"B",90)
    let unknownBID=UUID().uuidString
    let wrongArchive=try archiveAddingVoiceConfirmation(base([a,b]),contribution:contribution(unknownBID,bid,"B",sample(45,"unknown-b",0)),domain:domain)
    let wrongCandidate=try proposeAutomaticVoiceprintContribution(wrongArchive,candidate:candidate("wrong",a.id,key("wrong-source"),36.87,[],wrongArchive.revision),domain:domain)
    try check(!wrongCandidate.accepted && wrongCandidate.reason=="replay_gate" && wrongCandidate.after.newlyWrong>0,"candidate_that_adds_a_wrong_name_is_rejected")

    // The same candidate also turns one previously correct B label into A.
    let correctAID=UUID().uuidString,correctBID=UUID().uuidString
    var lossArchive=try archiveAddingVoiceConfirmation(base([a,b]),contribution:contribution(correctAID,a.id,"A",sample(45,"uncertain-a",0)),domain:domain)
    lossArchive=try archiveAddingVoiceConfirmation(lossArchive,contribution:contribution(correctBID,bid,"B",sample(52,"correct-b",0)),domain:domain)
    let lossCandidate=try proposeAutomaticVoiceprintContribution(lossArchive,candidate:candidate("loss",a.id,key("loss-source"),36.87,[correctAID],lossArchive.revision),domain:domain)
    try check(!lossCandidate.accepted && lossCandidate.reason=="replay_gate" && lossCandidate.after.lostPreviouslyCorrect>0,"candidate_that_loses_a_prior_correct_name_is_rejected")

    // Disabled profiles continue to compete as negatives, while a disabled
    // target cannot receive automatic support.
    let disabled=person(UUID().uuidString,"Disabled",90,"baseline",false)
    let disabledArchive=base([a,disabled])
    try check(disabledArchive.scores(vector(90),excludingSession:"query").first?.0==disabled.id,"disabled_person_remains_a_negative_competitor")
    let disabledCandidate=try proposeAutomaticVoiceprintContribution(disabledArchive,candidate:candidate("disabled",disabled.id,key("disabled-source"),90,[],disabledArchive.revision),domain:domain)
    try check(!disabledCandidate.accepted && disabledCandidate.reason=="unknown_or_disabled_person","disabled_person_cannot_gain_automatic_support")
    return checks
}

private struct FrozenAutomaticFeatureFile:Decodable {
    struct Evidence:Decodable {let id:String;let revision:Int;let key:SessionSpeakerKey;let sample:VoiceprintSample}
    let session:String
    let evidence:[Evidence]
}
private struct FrozenAutomaticCandidateFile:Decodable {
    struct Row:Decodable {let session:String;let name:String;let support_count:Int;let support_ids:[String];let dependency_confirmation_ids:[String];let before:Counts;let after:Counts;let lost_previously_correct:Int;let new_wrong_rows:Int;let passes_strict_gate:Bool
        struct Counts:Decodable {let correct:Int;let unknown:Int;let wrong:Int}
    }
    let candidate_results:[Row]
}

func voiceprintAutomaticFrozenFeatureReplay(archiveURL:URL,featureDirectory:URL,candidateResultsURL:URL)throws->[String] {
    let decodedArchive=try JSONDecoder().decode(VoiceprintArchive.self,from:Data(contentsOf:archiveURL))
    let archive=try decodedArchive.validated(domain:decodedArchive.inputKind)
    let decisions=try JSONDecoder().decode(FrozenAutomaticCandidateFile.self,from:Data(contentsOf:candidateResultsURL))
    let selected=decisions.candidate_results.filter{$0.name=="顾问甲" || $0.new_wrong_rows>0}.prefix(3)
    let files=try FileManager.default.contentsOfDirectory(at:featureDirectory,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasSuffix("-features.json")}
    var evidence:[String:FrozenAutomaticFeatureFile.Evidence]=[:]
    for file in files {
        let doc=try JSONDecoder().decode(FrozenAutomaticFeatureFile.self,from:Data(contentsOf:file))
        for row in doc.evidence {evidence[row.id]=row}
    }
    var checks:[String]=[]
    for row in selected {
        let refs=try row.support_ids.map{id -> VoiceprintAutomaticSupport in
            guard let match=evidence[id],match.key.session==row.session else{throw Failure(code:"automatic_frozen_support_missing")}
            return VoiceprintAutomaticSupport(evidence:VoiceprintEvidenceRef(id:match.id,revision:match.revision),sample:match.sample)
        }
        guard let first=refs.first else{throw Failure(code:"automatic_frozen_empty_support")}
        guard let target=archive.people.first(where:{$0.name==row.name}) else{throw Failure(code:"automatic_frozen_target_missing")}
        let candidate=VoiceprintAutomaticCandidate(personID:target.id,key:first.sample.session==row.session ? evidence[first.evidence.id]!.key:SessionSpeakerKey(session:row.session,source:first.sample.source,epoch:first.sample.epoch,identity:"slot:0"),support:refs,anchorConfirmationIDs:row.dependency_confirmation_ids,sourceArchiveRevision:archive.revision)
        let result=try proposeAutomaticVoiceprintContribution(archive,candidate:candidate,domain:archive.inputKind)
        let outcome=result.accepted ? "accepted" : "rejected_\(result.reason ?? "unknown")"
        let gate=result.after.correct>result.before.correct && result.after.wrong<=result.before.wrong && result.after.lostPreviouslyCorrect==0 && result.after.newlyWrong==0
        if row.name=="顾问甲" {
            guard result.accepted,result.after.correct-result.before.correct==3,gate else{throw Failure(code:"automatic_frozen_huang_positive_gate_mismatch")}
        }
        checks.append("native_frozen_\(row.name)_\(row.session)_\(outcome)_expected_pass_\(row.passes_strict_gate)_actual_pass_\(gate)_before_\(result.before.correct)-\(result.before.unknown)-\(result.before.wrong)_after_\(result.after.correct)-\(result.after.unknown)-\(result.after.wrong)_lost_\(result.after.lostPreviouslyCorrect)_newWrong_\(result.after.newlyWrong)")
    }
    return checks
}

// Group-centroid identity: synthetic geometry where every span alone stays
// below the per-span gate, but the group's mean voice is clearly one person.
func voiceprintGroupCentroidChecks()throws->[String] {
    let domain="synthetic_model_output",time="2026-10-15T12:00:00Z"
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:name)};checks.append(name)}
    func unit(_ parts:[(Int,Double)])->[Double] {
        var v=[Double](repeating:0,count:192);for (i,x) in parts {v[i]+=x}
        let n=sqrt(v.reduce(0){$0+$1*$1});return v.map{$0/n}
    }
    func refs(_ sessions:[String],_ v:[Double])->[VoiceprintSample] {
        sessions.flatMap{s in (0..<3).map{i in VoiceprintSample(session:s,source:"mic",epoch:"e-"+s,start:Double(i*5),end:Double(i*5+2),vector:v)}}
    }
    func person(_ name:String,_ sessions:[String],_ v:[Double],enabled:Bool=true)->VoiceprintPerson {
        VoiceprintPerson(id:UUID().uuidString,name:name,authorizedAt:time,enabled:enabled,samples:refs(sessions,v))
    }
    func archive(_ people:[VoiceprintPerson])->VoiceprintArchive {
        VoiceprintArchive(schema:1,partition:SpeakerEmbeddingBackend.partition,inputKind:domain,revision:1,people:people)
    }
    let key=SessionSpeakerKey(session:"group-query",source:"mic",epoch:"q",identity:"slot:0")
    // Each span: cos 0.55 to A plus its own orthogonal noise.
    let c=0.55,s=sqrt(1-c*c)
    func rows(_ count:Int,extra:[[Double]]=[])->[SavedVoiceRecognitionEvidence] {
        let base=(0..<count).map{i in unit([(0,c),(20+i,s)])}
        return (base+extra).enumerated().map{i,v in
            SavedVoiceRecognitionEvidence(id:"g-\(i)",revision:1,key:key,sample:VoiceprintSample(session:key.session,source:"mic",epoch:"q",start:Double(i*5),end:Double(i*5+2),vector:v))}
    }
    func matcher(_ a:VoiceprintArchive,_ r:[SavedVoiceRecognitionEvidence])->VoiceprintMatcher {
        var m=VoiceprintMatcher(archive:a);m.reset(session:key.session);m.importSavedEvidence(r);return m
    }
    let a=person("组甲",["m1","m2"],unit([(0,1)])),b=person("组乙",["m1","m3"],unit([(1,1)]))
    let two=matcher(archive([a,b]),rows(4))
    let named=two.suggestion(key)
    try check(named?.personID==a.id && named?.groupConsistent==true && named?.evidenceCount==4,"group_centroid_names_group_whose_spans_each_miss_the_strict_gate")
    try check(two.suggestion(key,groupCentroid:false)==nil && two.recommendation(key)==nil,"strict_learning_path_ignores_group_centroid_names")
    try check(matcher(archive([a,b]),rows(2)).suggestion(key)==nil,"group_centroid_needs_three_spans")
    let single=person("单场甲",["m1"],unit([(0,1)]))
    try check(matcher(archive([single,b]),rows(4)).suggestion(key)==nil,"single_meeting_reference_cannot_name_by_group_centroid")
    let sameSession=person("同场甲",["m1",key.session],unit([(0,1)]))
    try check(matcher(archive([sameSession,b]),rows(4)).suggestion(key)==nil,"query_meeting_references_do_not_count_as_a_second_meeting")
    let close=person("近似乙",["m1","m3"],unit([(0,0.95),(2,0.31)]))
    try check(matcher(archive([a,close]),rows(4)).suggestion(key)==nil,"close_second_person_withholds_group_name")
    let disabled=person("禁用甲",["m1","m2"],unit([(0,1)]),enabled:false)
    try check(matcher(archive([disabled,b]),rows(4)).suggestion(key)==nil,"disabled_best_person_is_not_named_and_does_not_promote_another")
    // A span far from the group's centre stays unnamed; the rest are named.
    let outlier=matcher(archive([a,b]),rows(4,extra:[unit([(5,1)])])).suggestion(key)
    try check(outlier?.personID==a.id && outlier?.groupConsistent==false && outlier?.recognizedSupport?.map(\.id).sorted()==["g-0","g-1","g-2","g-3"],"outlier_span_is_left_unnamed_by_group_centroid")
    // A clear voice of another person still withholds the group.
    let conflict=matcher(archive([a,b]),rows(4,extra:[unit([(1,1)])])).suggestion(key)
    try check(conflict==nil,"clear_other_person_span_withholds_group_centroid_name")
    // Schema 2: a revoked confirmation stops counting as a second meeting, and
    // automatic support never does.
    let pid=UUID().uuidString
    let base=VoiceprintPerson(id:pid,name:"账本甲",authorizedAt:time,enabled:true,samples:refs(["m1"],unit([(0,1)])))
    let other=person("账本乙",["m1","m3"],unit([(1,1)]))
    let ledger=VoiceprintLearningLedger(baseline:[base,other],contributions:[],revokedConfirmationIDs:[],enabledOverrides:[:])
    let schema2=VoiceprintArchive(schema:2,partition:SpeakerEmbeddingBackend.partition,inputKind:domain,revision:1,people:[base,other],learning:ledger)
    let confirmation=UUID().uuidString
    let added=try archiveAddingVoiceConfirmation(schema2,contribution:VoiceprintLearningContribution(confirmationID:confirmation,personID:pid,name:"账本甲",confirmedAt:time,samples:refs(["m2"],unit([(0,1)]))),domain:domain)
    try check(matcher(added,rows(4)).suggestion(key)?.personID==pid,"manual_confirmation_from_second_meeting_enables_group_centroid")
    let revoked=try archiveRevokingVoiceConfirmation(added,confirmationID:confirmation,domain:domain)
    try check(matcher(revoked,rows(4)).suggestion(key)==nil,"revoked_confirmation_no_longer_counts_as_second_meeting")
    let table=VoiceprintCentroidTable(archive:added)
    try check(table.scores(unit([(0,1)]),excludingSession:"none").first?.sessions==2,"centroid_table_counts_reference_meetings")
    return checks
}

// Frozen real-feature replay (saved embeddings only; never opens audio). Groups:
// human ledger labels (session, source, epoch, person) plus exported saved
// group evidence. Prints each row's decision under the strict and new rules.
func voiceprintGroupFrozenReplay(archiveURL:URL,featureDirectory:URL)throws->[String:Any] {
    let archive=try JSONDecoder().decode(VoiceprintArchive.self,from:Data(contentsOf:archiveURL))
    var groups:[String:[SavedVoiceRecognitionEvidence]]=[:]
    if let ledger=archive.learning {
        var labels:[(String,VoiceprintSample)]=[]
        for p in ledger.baseline {for s in p.samples where !labels.contains(where:{voiceSampleOverlap($0.1,s)}) {labels.append((p.id,s))}}
        for c in ledger.contributions where c.automatic==nil && !ledger.revokedConfirmationIDs.contains(c.confirmationID) {
            for s in c.samples where !labels.contains(where:{$0.0==c.personID && voiceSampleOverlap($0.1,s)}) {labels.append((c.personID,s))}
        }
        for (pid,s) in labels where Set(labels.filter{voiceSampleOverlap($0.1,s)}.map(\.0)).count==1 {
            let key=SessionSpeakerKey(session:s.session,source:s.source,epoch:s.epoch,identity:"person:"+pid)
            groups["A",default:[]].append(SavedVoiceRecognitionEvidence(id:"\(s.session)|\(s.source)|\(s.start)|\(s.end)",revision:0,key:key,sample:s))
        }
    }
    let files=try FileManager.default.contentsOfDirectory(at:featureDirectory,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasSuffix("-features.json")}
    for file in files.sorted(by:{$0.path<$1.path}) {
        let doc=try JSONDecoder().decode(FrozenAutomaticFeatureFile.self,from:Data(contentsOf:file))
        for e in doc.evidence {groups["B",default:[]].append(SavedVoiceRecognitionEvidence(id:"\(e.sample.session)|\(e.sample.source)|\(e.sample.start)|\(e.sample.end)",revision:e.revision,key:e.key,sample:e.sample))}
    }
    var out:[String:Any]=["revision":archive.revision,"capture":false,"cloud":false,"original_files_modified":false]
    for (name,rows) in groups {
        var strict:[String:String]=[:],group:[String:String]=[:]
        for session in Set(rows.map(\.key.session)).sorted() {
            var m=VoiceprintMatcher(archive:archive);m.reset(session:session)
            let mine=rows.filter{$0.key.session==session}
            for key in Set(mine.map(\.key)) {m.importSavedEvidence(mine.filter{$0.key==key})}
            for key in Set(mine.map(\.key)) {
                let ids=mine.filter{$0.key==key}.map(\.id)
                for (rule,flag) in [("strict",false),("group",true)] {
                    guard let r=m.suggestion(key,groupCentroid:flag) else{continue}
                    let named=r.groupConsistent ? ids:(r.recognizedSupport ?? []).map(\.id)
                    for id in named {if rule=="strict" {strict[id]=r.personID}else{group[id]=r.personID}}
                }
            }
        }
        out[name]=["rows":rows.count,"strict":strict,"group":group]
    }
    return out
}
