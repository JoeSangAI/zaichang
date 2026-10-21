import Foundation

// A standing local-learning permission does not turn inferred names into labels.
// Every feature is checked against the current projected, manually named sentence.
func enrollSavedVoiceReferences(result:SavedVoiceRecognitionResult,folder:URL,store:VoiceprintArchiveStore,authorized:Bool,createConfirmationIfMissing:Bool=true,commitGate:((()throws->Void)throws->Void)?=nil)throws->[[String:Any]] {
    guard authorized,result.inputKind==store.domain else{throw Failure(code:"voice_learning_not_authorized")}
    let keys=Array(Set(result.evidence.map(\.key)))
    guard !keys.isEmpty else{return []}
    let request=SavedVoiceRecognitionRequest(folder:folder.path,session:result.session,inputKind:result.inputKind,keys:keys,sampleLimit:24)
    try SavedVoiceRecognition.validate(result,request:request)
    let file=folder.appendingPathComponent("session-names.json")
    var original=try SavedVoiceRecognition.read(file,limit:4*1024*1024)
    guard var object=try JSONSerialization.jsonObject(with:original) as? [String:Any] else{throw Failure(code:"voice_learning_names_invalid")}
    let tracks=try meetingAudioTracks(in:folder)
    let meeting=CachedMeeting(id:folder.lastPathComponent,directory:folder,date:Date(),writtenBytes:0,pendingBytes:0,occupiedBytes:0,tracks:tracks,audioCleaned:false,warning:false,retiredBytes:0)
    var names=SessionNames()
    for event in try meeting.events() {
        guard let parent=event["segment_id"] as? String else{continue}
        names.register(segment:parent,item:event)
        for run in TranscriptTimeline.speakerRuns(event) {names.register(segment:TranscriptTimeline.runID(parent:parent,run:run),item:run)}
    }
    try names.restore(original,session:result.session,events:try meeting.events(),directory:folder)
    let eligible=result.evidence.filter { row in
        guard let name=names.name(segment:row.id) else{return false}
        return createConfirmationIfMissing || names.voiceConfirmations.contains{$0.name==name && $0.segmentIDs.contains(row.id)}
    }
    let groups=Dictionary(grouping:eligible,by:{names.name(segment:$0.id)!})
    var report:[[String:Any]]=[]
    for name in groups.keys.sorted() {
        let rows=groups[name]!.sorted{$0.sample.start<$1.sample.start}
        // Largest mutually coherent cohort; a contaminated slot cannot train all
        // its speech merely because the human gave that slot a name.
        var cohort:[SavedVoiceRecognitionEvidence]=[]
        for seed in rows {
            var candidate=[seed]
            let explicitScope=createConfirmationIfMissing ? nil:names.voiceConfirmations.first{$0.name==name && $0.segmentIDs.contains(seed.id)}
            let scopedRows=explicitScope.map{scope in rows.filter{scope.segmentIDs.contains($0.id)}} ?? rows
            for row in scopedRows where row.id != seed.id {
                guard !candidate.contains(where:{$0.sample.session==row.sample.session && $0.sample.start<row.sample.end && $0.sample.end>row.sample.start}),
                      candidate.allSatisfy({zip($0.sample.vector,row.sample.vector).reduce(0.0,{$0+$1.0*$1.1})>=0.60}) else{continue}
                candidate.append(row);if candidate.count==8 {break}
            }
            if candidate.count>cohort.count {cohort=candidate}
        }
        // One or two clean human-labelled examples remain reversible references;
        // the shared ledger requires three coherent examples before recognition.
        guard !cohort.isEmpty else{report.append(["name":name,"status":"insufficient_coherent_audio","available":rows.count,"coherent":cohort.count]);continue}
        let ids=cohort.map(\.id),wanted=Set(ids)
        let persisted=object["voiceConfirmations"] as? [[String:Any]] ?? []
        var records=try persisted.map{try JSONDecoder().decode(SessionVoiceConfirmation.self,from:JSONSerialization.data(withJSONObject:$0))}
        var record=names.voiceConfirmations.first{$0.name==name && wanted.isSubset(of:Set($0.segmentIDs))}
        if createConfirmationIfMissing,let existing=record,
           let prior=try store.load()?.learning?.contributions.first(where:{$0.confirmationID==existing.id}),
           !prior.samples.allSatisfy({old in cohort.allSatisfy{row in zip(old.vector,row.sample.vector).reduce(0.0,{$0+$1.0*$1.1})>=0.60}}) {
            // Preserve earlier pending evidence by keeping this cohort separate.
            record=nil
        }
        if record==nil {
            guard createConfirmationIfMissing else{report.append(["name":name,"status":"waiting_for_persisted_confirmation"]);continue}
            let references=ids.compactMap{names.personReference(segment:$0)}
            let person=references.count==ids.count && Set(references.map(\.id)).count==1 ? references.first:nil
            let added=SessionVoiceConfirmation(id:UUID().uuidString,session:result.session,name:name,person:person,segmentIDs:ids,createdAt:ISO8601DateFormatter().string(from:Date()))
            guard records.count<128 else{report.append(["name":name,"status":"session_capacity"]);continue}
            records.append(added)
            object["voiceConfirmations"]=try records.map{try JSONSerialization.jsonObject(with:JSONEncoder().encode($0))}
            let next=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
            guard try Data(contentsOf:file)==original else{throw Failure(code:"voice_learning_names_changed")}
            let replace = { try next.write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path) }
            if let commitGate {try commitGate(replace)}else{try replace()}
            original=next;record=added
        }
        guard let record else{continue}
        do {
            try SavedVoiceRecognition.validate(result,request:request)
            guard try Data(contentsOf:file)==original else{throw Failure(code:"voice_learning_names_changed")}
            let old=try store.load()
            let known=(old?.people ?? [])+(old?.learning?.baseline ?? [])
            let prior=old?.learning?.contributions.first{$0.confirmationID==record.id}
            let identities:Set<String>
            if let person=record.person {identities=Set(known.filter{$0.sharedPerson?.id==person.id}.map(\.id)+(old?.learning?.contributions.filter{$0.sharedPerson?.id==person.id}.map(\.personID) ?? []))}
            else {identities=Set(known.filter{$0.sharedPerson==nil && $0.name==name}.map(\.id)+(old?.learning?.contributions.filter{$0.sharedPerson==nil && $0.name==name}.map(\.personID) ?? []))}
            guard identities.count<=1 else{throw VoiceprintLearningError.conflictingIdentity}
            let identity=prior?.personID ?? identities.first ?? UUID().uuidString
            if old?.people.first(where:{$0.id==identity})?.enabled==false || old?.learning?.enabledOverrides[identity]==false {throw VoiceprintLearningError.disabled}
            var samples=prior?.samples ?? []
            for row in cohort where samples.count<8 {
                if !samples.contains(where:{$0.session==row.sample.session && $0.start<row.sample.end && $0.end>row.sample.start}),samples.allSatisfy({zip($0.vector,row.sample.vector).reduce(0.0,{$0+$1.0*$1.1})>=0.60}) {samples.append(row.sample)}
            }
            let contribution=VoiceprintLearningContribution(confirmationID:record.id,personID:identity,name:name,sharedPerson:record.person,confirmedAt:record.createdAt,samples:samples)
            let next=try archiveAddingVoiceConfirmation(old,contribution:contribution,domain:store.domain)
            guard try Data(contentsOf:file)==original else{throw Failure(code:"voice_learning_names_changed")}
            if next.revision != old?.revision {try store.save(next,expectedRevision:old?.revision,expectAbsent:old==nil,commitGate:commitGate)}
            report.append(["name":name,"status":next.people.contains{$0.id==identity} ? "ready":"reference_only","samples":samples.count,"confirmation":record.id])
        }catch {report.append(["name":name,"status":"rejected","reason":String(describing:error)])}
    }
    return report
}
