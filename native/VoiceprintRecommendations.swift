import Foundation
import Darwin

// Local, bounded voice features only. No audio, network, or credentials. Human
// confirmations anchor profiles; separately marked automatic evidence is only a
// replay-verified supplement and never acts as a human label.
struct VoiceprintPerson:Codable,Equatable {
    let id:String;let name:String;let authorizedAt:String;var enabled:Bool;let samples:[VoiceprintSample]
    let sharedPerson:SharedPersonReference?
    init(id:String,name:String,authorizedAt:String,enabled:Bool,samples:[VoiceprintSample],sharedPerson:SharedPersonReference?=nil) {
        self.id=id;self.name=name;self.authorizedAt=authorizedAt;self.enabled=enabled;self.samples=samples;self.sharedPerson=sharedPerson
    }
}
struct VoiceprintArchive:Codable {
    let schema:Int;let partition:String;let inputKind:String;var revision:Int;var people:[VoiceprintPerson]
    var learning:VoiceprintLearningLedger?=nil
    func validated(domain:String)throws->Self {
        guard [1,2].contains(schema),partition==SpeakerEmbeddingBackend.partition,inputKind==domain,revision>=1,
              people.count<=voiceprintMaximumPeople,Set(people.map(\.id)).count==people.count,people.allSatisfy(validVoicePerson) else{throw ProfileStoreError.invalid}
        if schema==1 {
            guard learning==nil,!people.isEmpty else{throw ProfileStoreError.invalid}
        } else {
            guard let ledger=learning,ledger.baseline.count<=voiceprintMaximumPeople,Set(ledger.baseline.map(\.id)).count==ledger.baseline.count,
                  ledger.baseline.allSatisfy(validVoicePerson),ledger.contributions.count<=voiceprintMaximumContributions,
                  Set(ledger.contributions.map(\.confirmationID)).count==ledger.contributions.count,
                  ledger.contributions.allSatisfy(validVoiceContribution),
                  ledger.contributions.reduce(0,{$0+$1.samples.count})<=voiceprintMaximumContributionSamples,
                  ledger.revokedConfirmationIDs.count<=voiceprintMaximumRevocations,
                  Set(ledger.revokedConfirmationIDs).count==ledger.revokedConfirmationIDs.count,
                  ledger.revokedConfirmationIDs.allSatisfy({UUID(uuidString:$0) != nil}),
                  ledger.enabledOverrides.count<=128,ledger.enabledOverrides.keys.allSatisfy({UUID(uuidString:$0) != nil}),
                  validAutomaticVoiceLedger(ledger),
                  try projectVoiceLedger(ledger)==people else{throw ProfileStoreError.invalid}
        }
        return self
    }
    static func validVector(_ vector:[Double])->Bool {vector.count==192 && vector.allSatisfy(\.isFinite) && abs(vector.reduce(0){$0+$1*$1}-1)<0.001}
    func scores(_ vector:[Double],excludingSession:String?=nil)->[(String,Double)] {
        scores(vector,excludingSession:excludingSession,includingAutomatic:true)
    }
    func humanOnlyScores(_ vector:[Double],excludingSession:String?=nil)->[(String,Double)] {
        scores(vector,excludingSession:excludingSession,includingAutomatic:false)
    }
    func scores(_ vector:[Double],excludingSession:String?,includingAutomatic:Bool)->[(String,Double)] {
        // Disabled voices remain negative comparisons, so opting one out
        // cannot make a similar enabled person win by default.
        people.compactMap {p in
            // Keep the same bounded reference view used after commit. New
            // automatic evidence supplements the existing bounded layer; it
            // cannot evict human references or push older automatic samples
            // beyond the per-person cap in a hypothetical replay.
            let automatic=includingAutomatic ? Array(activeAutomaticVoiceSamples(archive:self,personID:p.id).prefix(voiceprintMaximumAutomaticSamplesPerPerson)) : []
            let references=uniqueVoiceSamples(p.samples + automatic)
            let scores=references.filter{$0.session != excludingSession}.map{s in zip(vector,s.vector).reduce(0){$0+$1.0*$1.1}}.sorted(by:>)
            guard scores.count>=3 else{return nil}
            // Two examples must agree; one exceptionally similar sample cannot win alone.
            return (p.id,(scores[0]+scores[1])/2)
        }.sorted{$0.1>$1.1}
    }
}

// Group identity, from the 2026-10-15 leave-one-meeting-out evaluation
// (.runtime/voice-recognition-eval-20261014/report.md): the mean voice of one
// session group is compared with each person's human reference centroid.
// Only a person whose references span at least two other meetings can be named
// this way; single-meeting enrollments keep the strict per-span rule because a
// one-condition reference attracted unregistered voices in the evaluation.
let voiceprintGroupCentroidThreshold=0.62
let voiceprintGroupCentroidMargin=0.10
let voiceprintGroupOutlierFloor=0.50
struct VoiceprintGroupCentroidScore:Equatable {let id:String;let score:Double;let sessions:Int}
final class VoiceprintCentroidTable {
    private let order:[String]
    private let sums:[String:[String:(vector:[Double],count:Int)]]
    // Human references only: baseline plus unrevoked manual confirmations, never
    // automatic support or the bounded 12-sample view. Audio claimed by two
    // people is ambiguous and left out.
    init(archive:VoiceprintArchive) {
        let ids=Set(archive.people.map(\.id))
        var rows:[(String,VoiceprintSample)]=[]
        var bySession:[String:[Int]]=[:]
        func add(_ id:String,_ sample:VoiceprintSample,samePersonOnly:Bool) {
            let clash=(bySession[sample.session] ?? []).contains{i in voiceSampleOverlap(rows[i].1,sample) && (!samePersonOnly || rows[i].0==id)}
            guard !clash else{return}
            bySession[sample.session,default:[]].append(rows.count);rows.append((id,sample))
        }
        if let ledger=archive.learning {
            for person in ledger.baseline {for sample in person.samples {add(person.id,sample,samePersonOnly:false)}}
            for contribution in ledger.contributions where contribution.automatic==nil && !ledger.revokedConfirmationIDs.contains(contribution.confirmationID) {
                for sample in contribution.samples {add(contribution.personID,sample,samePersonOnly:true)}
            }
        } else {
            for person in archive.people {for sample in person.samples {add(person.id,sample,samePersonOnly:false)}}
        }
        var sums:[String:[String:(vector:[Double],count:Int)]]=[:]
        for row in rows where ids.contains(row.0) {
            let owners=Set((bySession[row.1.session] ?? []).filter{voiceSampleOverlap(rows[$0].1,row.1)}.map{rows[$0].0})
            guard owners.count==1 else{continue}
            var entry=sums[row.0,default:[:]][row.1.session] ?? (vector:[Double](repeating:0,count:row.1.vector.count),count:0)
            for i in entry.vector.indices {entry.vector[i]+=row.1.vector[i]}
            entry.count+=1
            sums[row.0,default:[:]][row.1.session]=entry
        }
        self.sums=sums;self.order=archive.people.map(\.id)
    }
    func scores(_ vector:[Double],excludingSession:String)->[VoiceprintGroupCentroidScore] {
        order.compactMap { id -> VoiceprintGroupCentroidScore? in
            guard let sessions=sums[id] else{return nil}
            var total=[Double](repeating:0,count:vector.count),count=0,used=0
            for (session,entry) in sessions where session != excludingSession && entry.count>0 {
                for i in total.indices {total[i]+=entry.vector[i]}
                count+=entry.count;used+=1
            }
            let norm=sqrt(total.reduce(0){$0+$1*$1})
            guard count>=3,norm>1e-12 else{return nil}
            return VoiceprintGroupCentroidScore(id:id,score:zip(total,vector).reduce(0){$0+$1.0*$1.1}/norm,sessions:used)
        }.sorted{$0.score>$1.score}
    }
}
// One table per archive state; matchers on the voice queue share the cache.
final class VoiceprintCentroidCache {
    private let lock=NSLock()
    private var key:String?
    private var table:VoiceprintCentroidTable?
    func table(for archive:VoiceprintArchive)->VoiceprintCentroidTable {
        let ledger=archive.learning
        let fingerprint="\(archive.revision)|\(archive.partition)|\(ledger?.contributions.count ?? -1)|\(ledger?.revokedConfirmationIDs.count ?? -1)|"+archive.people.map{"\($0.id):\($0.enabled):\($0.samples.count)"}.joined(separator:",")
        lock.lock();defer{lock.unlock()}
        if key==fingerprint,let table {return table}
        let next=VoiceprintCentroidTable(archive:archive)
        key=fingerprint;table=next
        return next
    }
}
struct VoiceprintArchiveStore {
    let folder:URL;let domain:String
    var file:URL {folder.appendingPathComponent("voices.json")}
    func load()throws->VoiceprintArchive? {
        guard FileManager.default.fileExists(atPath:file.path) else{return nil}
        guard try folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true,
              try file.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey]).isSymbolicLink != true,
              (try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=voiceprintMaximumFileBytes else{throw ProfileStoreError.invalid}
        return try JSONDecoder().decode(VoiceprintArchive.self,from:Data(contentsOf:file)).validated(domain:domain)
    }
    func save(_ archive:VoiceprintArchive,expectedRevision:Int?=nil,expectAbsent:Bool=false,commitGate:((()throws->Void)throws->Void)?=nil)throws {
        _ = try archive.validated(domain:domain)
        if FileManager.default.fileExists(atPath:folder.path) {guard try folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else{throw ProfileStoreError.invalid}}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let lockPath=folder.appendingPathComponent(".voices.lock").path
        let descriptor=open(lockPath,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard descriptor>=0 else{throw ProfileStoreError.invalid}
        defer{flock(descriptor,LOCK_UN);close(descriptor)}
        guard flock(descriptor,LOCK_EX)==0 else{throw ProfileStoreError.invalid}
        if expectAbsent,FileManager.default.fileExists(atPath:file.path) {throw ProfileStoreError.invalid}
        if let expectedRevision {guard try load()?.revision==expectedRevision else{throw ProfileStoreError.invalid}}
        if FileManager.default.fileExists(atPath:file.path) {guard try file.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else{throw ProfileStoreError.invalid}}
        // Write through a restricted temporary file; Foundation atomic defaults
        // can otherwise briefly expose the feature file with umask permissions.
        let temp=folder.appendingPathComponent(".voices-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:temp)}
        let data=try JSONEncoder().encode(archive)
        guard data.count<=voiceprintMaximumFileBytes else{throw VoiceprintLearningError.capacity}
        guard FileManager.default.createFile(atPath:temp.path,contents:data,attributes:[.posixPermissions:0o600]) else{throw ProfileStoreError.invalid}
        let replacingExisting=FileManager.default.fileExists(atPath:file.path)
        let replace = {
            if replacingExisting {_ = try FileManager.default.replaceItemAt(self.file,withItemAt:temp)}else{try FileManager.default.moveItem(at:temp,to:self.file)}
        }
        // Optional cancellation gate covers only atomic replacement. Encoding,
        // temporary-file writes and the archive's CAS lock stay outside it.
        if let commitGate {try commitGate(replace)}else{try replace()}
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:folder.path)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
}
struct VoiceprintEvidenceRef:Codable,Equatable {
    let id:String;let revision:Int
}
struct VoiceprintRecommendation:Equatable {
    let personID:String;let name:String;let archiveRevision:Int;let evidenceCount:Int
    let support:[VoiceprintEvidenceRef]
    let groupConsistent:Bool
    let recognizedSupport:[VoiceprintEvidenceRef]?
    init(personID:String,name:String,archiveRevision:Int,evidenceCount:Int,support:[VoiceprintEvidenceRef]=[],groupConsistent:Bool=true,recognizedSupport:[VoiceprintEvidenceRef]?=nil) {
        self.personID=personID;self.name=name;self.archiveRevision=archiveRevision;self.evidenceCount=evidenceCount;self.support=support;self.groupConsistent=groupConsistent;self.recognizedSupport=recognizedSupport
    }
}
func quickVoiceConfirmationSegmentIDs(candidate:VoiceprintRecommendation,groupIDs:[String],learningEnabled:Bool)->[String] {
    guard learningEnabled,!groupIDs.isEmpty else{return []}
    let scope=candidate.groupConsistent ? groupIDs:candidate.support.map(\.id).filter{groupIDs.contains($0)}
    return Array(Set(scope)).sorted()
}
struct VoiceprintEvidence {
    let id:String;let revision:Int;let key:SessionSpeakerKey;let start:Double;let end:Double;let vector:[Double];let context:VoiceprintAcousticContext
    static func events(from parent:[String:Any],domain:String)->[[String:Any]] {
        // A qualified whole sentence wins; never double-count its child audio.
        if from(parent,domain:domain) != nil {return [parent]}
        guard let id=parent["segment_id"] as? String else{return []}
        return TranscriptTimeline.speakerRuns(parent).compactMap {run in
            var item=run
            for field in ["session","source_id","epoch","track","revision","final","end_time_known","quality_flags","voice_acoustic_context"] {item[field]=parent[field]}
            item["segment_id"]=TranscriptTimeline.runID(parent:id,run:run)
            return from(item,domain:domain)==nil ? nil:item
        }
    }
    static func from(_ event:[String:Any],domain:String)->Self? {
        guard event["final"] as? Bool==true,event["end_time_known"] as? Bool==true,
              (event["quality_flags"] as? [String] ?? []).isEmpty,
              let key=SessionSpeakerKey.from(event),
              (event["speaker"] as? [String:Any])?["basis"] as? String=="anonymous_cluster",
              let id=event["segment_id"] as? String,let revision=event["revision"] as? Int,revision>=0,
              let f=event["identity_features"] as? [String:Any],
              f["partition"] as? String==SpeakerEmbeddingBackend.partition,f["input_kind"] as? String==domain,
              f["quality_gate"] as? String=="single_model_slot_asr_final_unclipped",
              f["source_id"] as? String==key.source,f["epoch"] as? String==key.epoch,
              let start=f["evidence_start"] as? Double,let end=f["evidence_end"] as? Double,
              let lo=event["start"] as? Double,let hi=event["end"] as? Double,
              start.isFinite,end.isFinite,start>=lo-1e-6,end<=hi+1e-6,(1.9...4.01).contains(end-start),
              let vector=f["values"] as? [Double],VoiceprintArchive.validVector(vector) else{return nil}
        var context=VoiceprintAcousticContext(channel:VoiceprintAcousticContext.channel(for:key.source))
        if let raw=event["voice_acoustic_context"] as? [String:Any] {
            guard let data=try? JSONSerialization.data(withJSONObject:raw),let decoded=try? JSONDecoder().decode(VoiceprintAcousticContext.self,from:data),decoded.valid,decoded.channel==context.channel else{return nil}
            context=decoded
        }
        return Self(id:id,revision:revision,key:key,start:start,end:end,vector:vector,context:context)
    }
}
struct VoiceprintMatcher {
    var archive:VoiceprintArchive?
    init(archive:VoiceprintArchive?=nil) {self.archive=archive}
    private let centroids=VoiceprintCentroidCache()
    private var evidence:[SessionSpeakerKey:[VoiceprintEvidence]]=[:]
    private var byID:[String:SessionSpeakerKey]=[:]
    private var byParent:[String:Set<String>]=[:]
    private var ignored=Set<SessionSpeakerKey>()
    private(set) var session:String?
    mutating func reset(session:String?) {self.session=session;evidence=[:];byID=[:];byParent=[:];ignored=[]}
    mutating func dismiss(_ key:SessionSpeakerKey) {ignored.insert(key)}
    mutating func remove(_ id:String) {
        if let children=byParent.removeValue(forKey:id) {for child in children where child != id {remove(child)}}
        if let key=byID.removeValue(forKey:id) {evidence[key]?.removeAll{$0.id==id}}
    }
    mutating func observe(_ event:[String:Any],domain:String)->Set<SessionSpeakerKey> {
        var changed=Set<SessionSpeakerKey>()
        guard event["session"] as? String==session else{return changed}
        if let id=event["segment_id"] as? String,let old=byID[id] {changed.insert(old);remove(id)}
        guard let value=VoiceprintEvidence.from(event,domain:domain),evidence.count<128 || evidence[value.key] != nil else{return changed}
        var rows=evidence[value.key] ?? []
        if !rows.contains(where:{$0.start<value.end && $0.end>value.start}) {
            rows.append(value);if rows.count>8 {let old=rows.removeFirst();byID.removeValue(forKey:old.id)}
            evidence[value.key]=rows;byID[value.id]=value.key
        }
        changed.insert(value.key);return changed
    }
    mutating func observeParent(_ event:[String:Any],domain:String)->Set<SessionSpeakerKey> {
        guard event["session"] as? String==session,let parent=event["segment_id"] as? String else{return []}
        var changed=Set<SessionSpeakerKey>()
        for id in (byParent[parent] ?? []).union([parent]) {if let key=byID[id] {changed.insert(key)}}
        remove(parent)
        var children=Set<String>()
        for item in VoiceprintEvidence.events(from:event,domain:domain) {
            changed.formUnion(observe(item,domain:domain))
            if let id=item["segment_id"] as? String,byID[id] != nil {children.insert(id)}
        }
        if !children.isEmpty {byParent[parent]=children}
        byParent=byParent.filter{$0.value.contains(where:{byID[$0] != nil})}
        return changed
    }
    func recommendation(_ key:SessionSpeakerKey)->VoiceprintRecommendation? {
        guard key.session==session,!ignored.contains(key),let archive,let rows=evidence[key],rows.count>=3 else{return nil}
        // A group name also covers clear rows that do not match any saved
        // person. They must agree acoustically with the whole group; otherwise
        // an unregistered second voice would silently inherit a known name.
        // Use the existing enrollment consistency gate, without weakening the
        // identity score/margin. This is temporary insufficiency, not a known
        // identity conflict: revised evidence can restore the recommendation.
        for i in rows.indices {for j in rows.indices where j>i {
            guard zip(rows[i].vector,rows[j].vector).reduce(0.0,{$0+$1.0*$1.1})>=0.60 else{return nil}
        }}
        var predictions:[String]=[];var support:[VoiceprintEvidenceRef]=[]
        for row in rows {
            let scores=archive.scores(row.vector,excludingSession:key.session)
            guard let best=scores.first,best.1>=0.60,best.1-(scores.dropFirst().first?.1 ?? 0)>=0.14 else{continue}
            predictions.append(best.0);support.append(VoiceprintEvidenceRef(id:row.id,revision:row.revision))
        }
        // A conflicting clear voice invalidates the whole group recommendation.
        guard predictions.count==rows.count,Set(predictions).count==1,
              let person=archive.people.first(where:{$0.id==predictions[0] && $0.enabled}) else{return nil}
        return VoiceprintRecommendation(personID:person.id,name:person.name,archiveRevision:archive.revision,evidenceCount:predictions.count,support:Array(support.prefix(8)))
    }
    func conflictingEvidence(_ key:SessionSpeakerKey)->Bool {
        guard let archive,let rows=evidence[key] else{return false}
        let predictions=rows.compactMap {row -> String? in
            let scores=archive.scores(row.vector,excludingSession:key.session)
            guard let best=scores.first,best.1>=0.60,best.1-(scores.dropFirst().first?.1 ?? 0)>=0.14 else{return nil}
            return best.0
        }
        return Set(predictions).count>1
    }
    // The group's mean voice against human reference centroids. Spans far from
    // the group's own centre stay unnamed; if any are dropped, only the kept
    // spans are named. A clear voice of another person still withholds it.
    func groupCentroidRecommendation(_ key:SessionSpeakerKey)->VoiceprintRecommendation? {
        guard key.session==session,!ignored.contains(key),let archive,let rows=evidence[key],rows.count>=3,!conflictingEvidence(key) else{return nil}
        func centre(_ values:[VoiceprintEvidence])->[Double] {
            var total=[Double](repeating:0,count:values[0].vector.count)
            for value in values {for i in total.indices {total[i]+=value.vector[i]}}
            let norm=sqrt(total.reduce(0){$0+$1*$1})
            return norm>1e-12 ? total.map{$0/norm}:total
        }
        let first=centre(rows)
        let kept=rows.filter{zip($0.vector,first).reduce(0.0,{$0+$1.0*$1.1})>=voiceprintGroupOutlierFloor}
        guard kept.count>=3 else{return nil}
        let scores=centroids.table(for:archive).scores(centre(kept),excludingSession:key.session)
        guard let best=scores.first,best.sessions>=2,best.score>=voiceprintGroupCentroidThreshold,
              best.score-(scores.dropFirst().first?.score ?? 0)>=voiceprintGroupCentroidMargin,
              let person=archive.people.first(where:{$0.id==best.id && $0.enabled}) else{return nil}
        // Any span that alone clearly matches someone else marks a mixed group.
        for row in rows {
            let single=archive.scores(row.vector,excludingSession:key.session)
            if let top=single.first,top.0 != person.id,top.1>=0.60,top.1-(single.dropFirst().first?.1 ?? 0)>=0.14 {return nil}
        }
        let refs=kept.map{VoiceprintEvidenceRef(id:$0.id,revision:$0.revision)}
        if kept.count==rows.count {
            return VoiceprintRecommendation(personID:person.id,name:person.name,archiveRevision:archive.revision,evidenceCount:rows.count,support:Array(refs.prefix(8)))
        }
        return VoiceprintRecommendation(personID:person.id,name:person.name,archiveRevision:archive.revision,evidenceCount:kept.count,support:Array(refs.prefix(8)),groupConsistent:false,recognizedSupport:Array(refs.prefix(24)))
    }
    // A mixed group never receives a group-wide name. Once three independent
    // spans agree, only individually qualified, coherent spans may be named.
    // Automatic learning passes groupCentroid:false so new references still
    // come only from spans that pass the strict per-span rule.
    func suggestion(_ key:SessionSpeakerKey,groupCentroid:Bool=true)->VoiceprintRecommendation? {
        if let complete=recommendation(key) {return complete}
        if groupCentroid,let group=groupCentroidRecommendation(key) {return group}
        guard key.session==session,!ignored.contains(key),let archive,let rows=evidence[key],!conflictingEvidence(key) else{return nil}
        let supported=rows.compactMap {row -> (VoiceprintEvidence,String)? in
            let scores=archive.scores(row.vector,excludingSession:key.session)
            guard let best=scores.first,best.1>=0.60,best.1-(scores.dropFirst().first?.1 ?? 0)>=0.14 else{return nil}
            return (row,best.0)
        }
        guard supported.count>=3,Set(supported.map{$0.1}).count==1,
              let person=archive.people.first(where:{$0.id==supported[0].1 && $0.enabled}) else{return nil}
        var best:[VoiceprintEvidence]=[]
        func agrees(_ a:VoiceprintEvidence,_ b:VoiceprintEvidence)->Bool {
            zip(a.vector,b.vector).reduce(0.0,{$0+$1.0*$1.1})>=0.60
        }
        if supported.count<=8 {
            for mask in 1..<(1<<supported.count) where mask.nonzeroBitCount>=3 && mask.nonzeroBitCount>best.count {
                let subset=supported.indices.filter{mask & (1<<$0) != 0}.map{supported[$0].0}
                if subset.indices.allSatisfy({i in subset.indices.filter{$0>i}.allSatisfy{j in agrees(subset[i],subset[j])}}) {best=subset}
            }
        } else {
            // At most 24 spans: enumerate triples, then grow a coherent set up
            // to eight references. This finds every qualifying triple without
            // an exponential search or weakening any acoustic gate.
            for i in supported.indices {for j in supported.indices where j>i && agrees(supported[i].0,supported[j].0) {
                for k in supported.indices where k>j && agrees(supported[i].0,supported[k].0) && agrees(supported[j].0,supported[k].0) {
                    var subset=[supported[i].0,supported[j].0,supported[k].0]
                    for row in supported.map({$0.0}) where subset.count<8 && !subset.contains(where:{$0.id==row.id}) {
                        if subset.allSatisfy({agrees($0,row)}) {subset.append(row)}
                    }
                    if subset.count>best.count {best=subset}
                }
            }}
        }
        guard best.count>=3 else{return nil}
        let recognized=supported.map{$0.0}.filter{row in best.allSatisfy{agrees($0,row)}}
        return VoiceprintRecommendation(personID:person.id,name:person.name,archiveRevision:archive.revision,evidenceCount:best.count,support:best.map{VoiceprintEvidenceRef(id:$0.id,revision:$0.revision)},groupConsistent:false,recognizedSupport:recognized.map{VoiceprintEvidenceRef(id:$0.id,revision:$0.revision)})
    }
    mutating func importSavedEvidence(_ rows:[SavedVoiceRecognitionEvidence]) {
        for row in rows where row.key.session==session {
            guard evidence.count<128 || evidence[row.key] != nil,(evidence[row.key]?.count ?? 0)<24,byID.count<256 else{continue}
            let sample=row.sample
            guard !(evidence[row.key] ?? []).contains(where:{$0.id==row.id || ($0.start<sample.end && $0.end>sample.start)}) else{continue}
            evidence[row.key,default:[]].append(VoiceprintEvidence(id:row.id,revision:row.revision,key:row.key,start:sample.start,end:sample.end,vector:sample.vector,context:sample.context ?? VoiceprintAcousticContext(channel:VoiceprintAcousticContext.channel(for:sample.source))))
            byID[row.id]=row.key
        }
    }
    func enrollmentSamples(_ key:SessionSpeakerKey)->[VoiceprintSample] {
        guard key.session==session,let rows=evidence[key],rows.count>=3 else{return []}
        // All independent examples must agree acoustically; explicit naming
        // cannot turn a mixed anonymous cluster into a trusted voice profile.
        for i in rows.indices {for j in rows.indices where j>i {
            guard zip(rows[i].vector,rows[j].vector).reduce(0.0,{$0+$1.0*$1.1})>=0.60 else{return []}
        }}
        return rows.map{VoiceprintSample(session:key.session,source:key.source,epoch:key.epoch,start:$0.start,end:$0.end,vector:$0.vector,context:$0.context)}
    }
    func confirmationSamples(segmentIDs:[String])->[VoiceprintSample] {
        guard !segmentIDs.isEmpty,segmentIDs.count<=4096 else{return []}
        var selected:[VoiceprintSample]=[]
        for id in Array(Set(segmentIDs)).sorted() {
            guard let key=byID[id],key.session==session,
                  let row=evidence[key]?.first(where:{$0.id==id}) else{continue}
            let sample=VoiceprintSample(session:key.session,source:key.source,epoch:key.epoch,start:row.start,end:row.end,vector:row.vector,context:row.context)
            if !selected.contains(where:{voiceSampleOverlap($0,sample)}) {selected.append(sample)}
        }
        selected.sort{$0.start<$1.start}
        if selected.count>8 {selected=Array(selected.suffix(8))}
        for i in selected.indices {for j in selected.indices where j>i {
            guard voiceSimilarity(selected[i],selected[j])>=0.60 else{return []}
        }}
        return selected
    }
    var retainedEvidenceCount:Int {byID.count}
}

// Pure enrollment decision. Callers must obtain the name from an explicit
// person-level edit, never displayName, semantic suggestions or a restored file.
func archiveRememberingManualVoice(_ old:VoiceprintArchive?,name:String,key:SessionSpeakerKey,samples:[VoiceprintSample],domain:String,now:Date=Date())throws->VoiceprintArchive? {
    let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
    guard !name.isEmpty,name.count<=80,(3...8).contains(samples.count),
          samples.allSatisfy({$0.session==key.session && $0.source==key.source && $0.epoch==key.epoch}) else{return nil}
    var archive=old ?? VoiceprintArchive(schema:1,partition:SpeakerEmbeddingBackend.partition,inputKind:domain,revision:0,people:[])
    if let old {guard old.schema==1 else{throw VoiceprintLearningError.invalidConfirmation};_ = try old.validated(domain:domain)}
    let matches=archive.people.indices.filter{archive.people[$0].name==name}
    guard matches.count<=1 else{return nil}
    let index=matches.first
    if let index,!archive.people[index].enabled {return nil} // Explicit opt-out persists.
    for sample in samples {
        guard VoiceprintArchive.validVector(sample.vector) else{return nil}
        let scores=archive.humanOnlyScores(sample.vector)
        if let best=scores.first,best.1>=0.60,best.1-(scores.dropFirst().first?.1 ?? 0)>=0.14,
           best.0 != index.map({archive.people[$0].id}) {return nil}
        // An explicit human confirmation may add a new microphone condition
        // whose timbre differs from old references. Internal agreement and no
        // strong different-person match remain required; matching stays strict.
    }
    for i in samples.indices {for j in samples.indices where j>i {
        guard zip(samples[i].vector,samples[j].vector).reduce(0.0,{$0+$1.0*$1.1})>=0.60 else{return nil}
    }}
    if let index {
        let person=archive.people[index]
        let additions=samples.filter {s in !person.samples.contains(where:{$0.session==s.session && $0.source==s.source && $0.epoch==s.epoch && $0.start<s.end && $0.end>s.start})}
        guard !additions.isEmpty else{return nil}
        // Retain existing references and append bounded independent examples.
        let all=person.samples+additions
        let combined=all.count<=12 ? all:Array(all.prefix(3))+Array(all.suffix(9))
        archive.people[index]=VoiceprintPerson(id:person.id,name:person.name,authorizedAt:person.authorizedAt,enabled:person.enabled,samples:combined)
    } else {
        guard archive.people.count<voiceprintMaximumPeople else{return nil}
        archive.people.append(VoiceprintPerson(id:UUID().uuidString,name:name,authorizedAt:ISO8601DateFormatter().string(from:now),enabled:true,samples:samples))
    }
    archive.revision+=1
    return try archive.validated(domain:domain)
}

// Schema 2 retains the original reference set and each explicit confirmation's
// contribution. `people` is a rebuildable matching view, never the undo owner.
struct VoiceprintLearningContribution:Codable,Equatable {
    let confirmationID:String
    let personID:String
    let name:String
    let sharedPerson:SharedPersonReference?
    let confirmedAt:String
    let samples:[VoiceprintSample]
    let automatic:VoiceprintAutomaticEvidence?
    var session:String {samples.first?.session ?? ""}
    init(confirmationID:String,personID:String,name:String,sharedPerson:SharedPersonReference?=nil,confirmedAt:String,samples:[VoiceprintSample],automatic:VoiceprintAutomaticEvidence?=nil) {
        self.confirmationID=confirmationID;self.personID=personID;self.name=name;self.sharedPerson=sharedPerson;self.confirmedAt=confirmedAt;self.samples=samples;self.automatic=automatic
    }
}
struct VoiceprintLearningLedger:Codable,Equatable {
    var baseline:[VoiceprintPerson]
    var contributions:[VoiceprintLearningContribution]
    var revokedConfirmationIDs:[String]
    var enabledOverrides:[String:Bool]
}
enum VoiceprintLearningError:Error {
    case invalidConfirmation,conflictingIdentity,conflictingVoice,revokedConfirmation,capacity,disabled
}
let voiceprintMaximumPeople=64
private let voiceprintMaximumFileBytes=16_000_000
let voiceprintMaximumContributions=512
let voiceprintMaximumContributionSamples=2048
private let voiceprintMaximumRevocations=2048

struct VoiceprintLearningPolicy {
    static let preferenceKey="VoiceprintContinuousLearningEnabled"
    private static let gate=NSRecursiveLock()
    private let defaults:UserDefaults
    init(defaults:UserDefaults = .standard) {self.defaults=defaults}
    var isEnabled:Bool {defaults.object(forKey:Self.preferenceKey) as? Bool ?? false}
    func setEnabled(_ enabled:Bool) {Self.gate.lock();defer{Self.gate.unlock()};defaults.set(enabled,forKey:Self.preferenceKey)}
    func commitIfEnabled(_ replace:()throws->Void)throws {
        Self.gate.lock();defer{Self.gate.unlock()}
        guard isEnabled else{throw Failure(code:"voice_learning_not_authorized")}
        try replace()
    }
}

func voiceSampleOverlap(_ a:VoiceprintSample,_ b:VoiceprintSample)->Bool {
    // Simultaneous copies on another source/epoch are still the same speech.
    a.session==b.session && a.start<b.end && a.end>b.start
}
func voiceSimilarity(_ a:VoiceprintSample,_ b:VoiceprintSample)->Double {
    zip(a.vector,b.vector).reduce(0.0){$0+$1.0*$1.1}
}
private func validSharedVoicePerson(_ value:SharedPersonReference?)->Bool {
    guard let value else{return true}
    return (try? value.validated()) != nil
}
private func validVoiceSamples(_ samples:[VoiceprintSample],minimum:Int,maximum:Int)->Bool {
    guard (minimum...maximum).contains(samples.count) else{return false}
    var intervals:[String:[VoiceprintSample]]=[:]
    for sample in samples {
        guard !sample.session.isEmpty,sample.session.count<=160,isTranscriptAudioTrack(sample.source),sample.source.count<=160,
              !sample.epoch.isEmpty,sample.epoch.count<=160,sample.start.isFinite,sample.end.isFinite,sample.start>=0,
              (1.9...4.01).contains(sample.end-sample.start),VoiceprintArchive.validVector(sample.vector),
              sample.context?.valid != false,sample.context == nil || sample.context?.channel==VoiceprintAcousticContext.channel(for:sample.source) else{return false}
        let key=sample.session+"\u{1f}"+sample.source+"\u{1f}"+sample.epoch
        guard !(intervals[key] ?? []).contains(where:{$0.start<sample.end && $0.end>sample.start}) else{return false}
        intervals[key,default:[]].append(sample)
    }
    return true
}
private func validVoicePerson(_ person:VoiceprintPerson)->Bool {
    UUID(uuidString:person.id) != nil && !person.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty &&
        person.name.count<=80 && !person.name.unicodeScalars.contains(where:{$0.value<32}) &&
        ISO8601DateFormatter().date(from:person.authorizedAt) != nil && validSharedVoicePerson(person.sharedPerson) &&
        (person.sharedPerson == nil || person.sharedPerson?.name==person.name) &&
        validVoiceSamples(person.samples,minimum:3,maximum:12)
}
private func validVoiceContribution(_ value:VoiceprintLearningContribution)->Bool {
    guard UUID(uuidString:value.confirmationID) != nil,UUID(uuidString:value.personID) != nil,
          !value.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,value.name.count<=80,
          !value.name.unicodeScalars.contains(where:{$0.value<32}),validSharedVoicePerson(value.sharedPerson),
          value.sharedPerson == nil || value.sharedPerson?.name==value.name,
          ISO8601DateFormatter().date(from:value.confirmedAt) != nil,
          validVoiceSamples(value.samples,minimum:value.automatic == nil ? 1:3,maximum:8),
          value.samples.allSatisfy({$0.session==value.session}) else{return false}
    if let automatic=value.automatic {return validAutomaticVoiceEvidence(automatic,samples:value.samples)}
    for i in value.samples.indices {for j in value.samples.indices where j>i {
        if voiceSampleOverlap(value.samples[i],value.samples[j]) || voiceSimilarity(value.samples[i],value.samples[j])<0.60 {return false}
    }}
    return true
}
func uniqueVoiceSamples(_ values:[VoiceprintSample])->[VoiceprintSample] {
    var result:[VoiceprintSample]=[]
    for sample in values where !result.contains(where:{voiceSampleOverlap($0,sample)}) {result.append(sample)}
    return result
}
private func learnedVoiceSamples(_ values:[VoiceprintSample])->[VoiceprintSample] {
    // Each acoustic condition needs three mutually consistent independent
    // confirmations. A single edit is retained as pending evidence, not trained.
    var groups:[[VoiceprintSample]]=[]
    for sample in uniqueVoiceSamples(values) {
        if let index=groups.firstIndex(where:{$0.allSatisfy{voiceSimilarity($0,sample)>=0.60}}) {groups[index].append(sample)}
        else {groups.append([sample])}
    }
    let eligible=groups.filter{$0.count>=3}.flatMap{$0}
    return uniqueVoiceSamples(values).filter{eligible.contains($0)}
}
// Preserve the first three references and reserve a complete three-sample
// cohort for each recent recording condition before spending spare slots on
// recency. The reversible ledger still owns every original and contribution.
private func contextBalancedVoiceSamples(_ all:[VoiceprintSample])->[VoiceprintSample] {
    guard all.count>12 else{return all}
    guard all.contains(where:{$0.context != nil}) else{return Array(all.prefix(3))+Array(all.suffix(9))}
    var selected=Set(Array(all.indices.prefix(3)))
    var contexts:[VoiceprintAcousticContext?]=[]
    for sample in all.reversed() where !contexts.contains(sample.context) {contexts.append(sample.context)}
    for context in contexts {
        let cohort=all.indices.filter{all[$0].context==context}
        guard cohort.count>=3 else{continue}
        let existing=cohort.filter{selected.contains($0)}.count
        let needed=max(0,3-existing)
        let missing=cohort.reversed().filter{!selected.contains($0)}.prefix(needed)
        guard selected.count+missing.count<=12 else{continue}
        selected.formUnion(missing)
    }
    for index in all.indices.reversed() where selected.count<12 {selected.insert(index)}
    return all.indices.filter{selected.contains($0)}.map{all[$0]}
}
private func projectVoiceLedger(_ ledger:VoiceprintLearningLedger)throws->[VoiceprintPerson] {
    let active=ledger.contributions.filter{$0.automatic==nil && !ledger.revokedConfirmationIDs.contains($0.confirmationID)}
    let ids=Array(ledger.baseline.map(\.id)+active.map(\.personID)).reduce(into:[String]()){if !$0.contains($1){$0.append($1)}}
    guard ids.count<=voiceprintMaximumPeople else{throw VoiceprintLearningError.capacity}
    var result:[VoiceprintPerson]=[]
    for id in ids {
        let baseline=ledger.baseline.first{$0.id==id}
        let additions=active.filter{$0.personID==id}
        let references=([baseline?.sharedPerson]+additions.map(\.sharedPerson)).compactMap{$0}
        guard Set(references.map(\.id)).count<=1,Set(references.map(\.name)).count<=1 else{throw VoiceprintLearningError.conflictingIdentity}
        guard let first=additions.first else {if var baseline {if let enabled=ledger.enabledOverrides[id] {baseline.enabled=enabled};result.append(baseline)};continue}
        let shared=references.last
        let name=shared?.name ?? baseline?.name ?? first.name
        let eligible=learnedVoiceSamples(additions.flatMap(\.samples))
        // Baseline order and sample bytes are preserved. Trimming applies only
        // to this view; undo rebuilds from the complete original and ledger.
        let original=baseline?.samples ?? []
        let all=original+uniqueVoiceSamples(eligible).filter{sample in !original.contains(where:{voiceSampleOverlap($0,sample)})}
        guard all.count>=3 else{continue}
        let samples=contextBalancedVoiceSamples(all)
        result.append(VoiceprintPerson(id:id,name:name,authorizedAt:baseline?.authorizedAt ?? first.confirmedAt,
            enabled:ledger.enabledOverrides[id] ?? baseline?.enabled ?? true,samples:samples,sharedPerson:shared))
    }
    let sharedIDs=result.compactMap{$0.sharedPerson?.id}
    guard Set(sharedIDs).count==sharedIDs.count else{throw VoiceprintLearningError.conflictingIdentity}
    return result
}
private func voiceLedger(_ archive:VoiceprintArchive?)->VoiceprintLearningLedger {
    archive?.learning ?? VoiceprintLearningLedger(baseline:archive?.people ?? [],contributions:[],revokedConfirmationIDs:[],enabledOverrides:[:])
}
func archiveWithVoiceLedger(_ old:VoiceprintArchive?,ledger:VoiceprintLearningLedger,domain:String)throws->VoiceprintArchive {
    var archive=VoiceprintArchive(schema:2,partition:SpeakerEmbeddingBackend.partition,inputKind:domain,
        revision:(old?.revision ?? 0)+1,people:try projectVoiceLedger(ledger))
    archive.learning=ledger
    let validated=try archive.validated(domain:domain)
    guard try JSONEncoder().encode(validated).count<=voiceprintMaximumFileBytes else{throw VoiceprintLearningError.capacity}
    return validated
}

func archiveAddingVoiceConfirmation(_ old:VoiceprintArchive?,contribution:VoiceprintLearningContribution,domain:String)throws->VoiceprintArchive {
    if let old {_ = try old.validated(domain:domain)}
    guard contribution.automatic==nil,validVoiceContribution(contribution) else{throw VoiceprintLearningError.invalidConfirmation}
    var ledger=voiceLedger(old)
    guard !ledger.revokedConfirmationIDs.contains(contribution.confirmationID) else{throw VoiceprintLearningError.revokedConfirmation}
    guard ledger.enabledOverrides[contribution.personID] != false,
          ledger.baseline.first(where:{$0.id==contribution.personID})?.enabled != false || ledger.enabledOverrides[contribution.personID]==true else{throw VoiceprintLearningError.disabled}
    let knownReferences=([ledger.baseline.first{$0.id==contribution.personID}?.sharedPerson]+ledger.contributions.filter{$0.personID==contribution.personID && !ledger.revokedConfirmationIDs.contains($0.confirmationID)}.map(\.sharedPerson)).compactMap{$0}
    if let shared=contribution.sharedPerson {
        guard knownReferences.allSatisfy({$0.id==shared.id && $0.name==shared.name}),
              !ledger.baseline.contains(where:{$0.id != contribution.personID && $0.sharedPerson?.id==shared.id}),
              !ledger.contributions.contains(where:{$0.personID != contribution.personID && $0.sharedPerson?.id==shared.id && !ledger.revokedConfirmationIDs.contains($0.confirmationID)}) else{throw VoiceprintLearningError.conflictingIdentity}
    }
    for sample in contribution.samples {
        let scores=old?.humanOnlyScores(sample.vector) ?? []
        if let best=scores.first,best.0 != contribution.personID,best.1>=0.60,best.1-(scores.dropFirst().first?.1 ?? 0)>=0.14 {throw VoiceprintLearningError.conflictingVoice}
    }
    if let index=ledger.contributions.firstIndex(where:{$0.confirmationID==contribution.confirmationID}) {
        let previous=ledger.contributions[index]
        guard previous.automatic==nil,previous.personID==contribution.personID,previous.name==contribution.name,
              previous.sharedPerson==contribution.sharedPerson,previous.confirmedAt==contribution.confirmedAt,
              previous.session==contribution.session else{throw VoiceprintLearningError.conflictingIdentity}
        var merged=previous.samples
        for sample in contribution.samples {
            if merged.contains(sample) {continue}
            guard !merged.contains(where:{voiceSampleOverlap($0,sample)}) else{throw VoiceprintLearningError.invalidConfirmation}
            merged.append(sample)
        }
        if merged==previous.samples {return old!}
        guard merged.count<=8 else{throw VoiceprintLearningError.capacity}
        let next=VoiceprintLearningContribution(confirmationID:previous.confirmationID,personID:previous.personID,name:previous.name,
            sharedPerson:previous.sharedPerson,confirmedAt:previous.confirmedAt,samples:merged)
        guard validVoiceContribution(next) else{throw VoiceprintLearningError.conflictingVoice}
        ledger.contributions[index]=next
    } else {
        guard ledger.contributions.count<voiceprintMaximumContributions else{throw VoiceprintLearningError.capacity}
        ledger.contributions.append(contribution)
    }
    guard ledger.contributions.reduce(0,{$0+$1.samples.count})<=voiceprintMaximumContributionSamples else{throw VoiceprintLearningError.capacity}
    return try archiveWithVoiceLedger(old,ledger:ledger,domain:domain)
}
func archiveRevokingVoiceConfirmation(_ old:VoiceprintArchive,confirmationID:String,domain:String)throws->VoiceprintArchive {
    _ = try old.validated(domain:domain)
    guard UUID(uuidString:confirmationID) != nil else{throw VoiceprintLearningError.invalidConfirmation}
    var ledger=voiceLedger(old)
    if ledger.revokedConfirmationIDs.contains(confirmationID) {return old}
    guard ledger.revokedConfirmationIDs.count<voiceprintMaximumRevocations else{throw VoiceprintLearningError.capacity}
    // Keep a small durable tombstone, including for a cancelled write which has
    // not landed yet. Delayed callbacks cannot silently relearn a revoked edit.
    ledger.revokedConfirmationIDs.append(confirmationID)
    return try archiveWithVoiceLedger(old,ledger:ledger,domain:domain)
}
func archiveSettingVoiceEnabled(_ old:VoiceprintArchive,personID:String,enabled:Bool,domain:String)throws->VoiceprintArchive {
    _ = try old.validated(domain:domain)
    var ledger=voiceLedger(old)
    guard ledger.baseline.contains(where:{$0.id==personID}) || ledger.contributions.contains(where:{$0.personID==personID}) || ledger.enabledOverrides[personID] != nil else{throw VoiceprintLearningError.conflictingIdentity}
    if ledger.enabledOverrides[personID]==enabled {return old}
    guard ledger.enabledOverrides.count<128 || ledger.enabledOverrides[personID] != nil else{throw VoiceprintLearningError.capacity}
    ledger.enabledOverrides[personID]=enabled
    return try archiveWithVoiceLedger(old,ledger:ledger,domain:domain)
}

// This is an explicit durable user-state reconciliation, never a model callback.
// Re-enabling an old confirmation is permitted only through this entry point.
func archiveReconcilingVoiceConfirmations(_ old:VoiceprintArchive,session:String,activeIDs:Set<String>,domain:String)throws->VoiceprintArchive {
    _ = try old.validated(domain:domain)
    guard !session.isEmpty,session.count<=160,activeIDs.count<=4096,activeIDs.allSatisfy({UUID(uuidString:$0) != nil}) else{throw VoiceprintLearningError.invalidConfirmation}
    var ledger=voiceLedger(old)
    var revoked=Set(ledger.revokedConfirmationIDs)
    for contribution in ledger.contributions where contribution.automatic==nil && contribution.session==session {
        if activeIDs.contains(contribution.confirmationID) {revoked.remove(contribution.confirmationID)}
        else {revoked.insert(contribution.confirmationID)}
    }
    guard revoked.count<=voiceprintMaximumRevocations else{throw VoiceprintLearningError.capacity}
    if revoked==Set(ledger.revokedConfirmationIDs) {return old}
    ledger.revokedConfirmationIDs=revoked.sorted()
    return try archiveWithVoiceLedger(old,ledger:ledger,domain:domain)
}
