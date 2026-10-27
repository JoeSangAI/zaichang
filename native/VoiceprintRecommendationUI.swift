import AppKit

// One serial utility queue owns matching and disk I/O. It never shares the
// capture/control queue, so archive reads or scoring cannot delay pause.
final class VoiceprintRecommendationService {
    let queue=DispatchQueue(label:"meeting.voiceprint.recommendations",qos:.utility)
    let store:VoiceprintArchiveStore
    private var matcher=VoiceprintMatcher()
    private var loaded=false
    private var approved:[SessionVoiceConfirmation]=[]
    private var approvedSession:String?
    var learningUpdate:((String,String)->Void)?
    private var previousLearningStatus=""
    private let learningPolicy=VoiceprintLearningPolicy()
    init(store:VoiceprintArchiveStore) {self.store=store}
    // The committed session names remain the authority if a crash interrupts
    // the second (voice archive) write. Deleted recordings retain their voices.
    private func recovered(_ old:VoiceprintArchive?)throws->VoiceprintArchive? {
        guard var archive=old,let ledger=archive.learning else{return old}
        let sessions=Set(ledger.contributions.map(\.session))
        let base=store.folder.deletingLastPathComponent().appendingPathComponent("SessionCache")
        guard FileManager.default.fileExists(atPath:base.path) else{return old}
        let dirs=try FileManager.default.contentsOfDirectory(at:base,includingPropertiesForKeys:[.isSymbolicLinkKey],options:[.skipsHiddenFiles])
        guard dirs.count<=4096 else{throw ProfileStoreError.invalid}
        for dir in dirs where UUID(uuidString:dir.lastPathComponent) != nil {
            guard try dir.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else{continue}
            // Identify the recording before parsing its potentially unrelated names.
            let metadata=dir.appendingPathComponent("meeting.json")
            guard let info=try? metadata.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey]),info.isSymbolicLink != true,(info.fileSize ?? Int.max)<=1024*1024,
                  let data=try? Data(contentsOf:metadata),let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
                  let targetSession=object["session"] as? String,sessions.contains(targetSession) else{continue}
            let file=dir.appendingPathComponent("session-names.json")
            guard FileManager.default.fileExists(atPath:file.path) else{
                for row in archive.learning?.contributions.filter({$0.automatic?.key.session==targetSession && archive.learning?.revokedConfirmationIDs.contains($0.confirmationID) != true}) ?? [] {
                    archive=try archiveRevokingVoiceConfirmation(archive,confirmationID:row.confirmationID,domain:store.domain)
                }
                continue
            }
            let attributes=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey])
            guard attributes.isSymbolicLink != true,(attributes.fileSize ?? Int.max)<=4*1024*1024 else{throw ProfileStoreError.invalid}
            let namesData=try Data(contentsOf:file)
            let value=try JSONSerialization.jsonObject(with:namesData) as? [String:Any]
            guard let session=value?["session"] as? String,session==targetSession else{throw ProfileStoreError.invalid}
            // A session with a previous contribution but no current confirmation
            // list means those contributions were removed and must be retracted.
            // A present-but-malformed field remains a hard validation failure.
            let rawRecords:[[String:Any]]
            if let names=value {
                if names.keys.contains("voiceConfirmations") {
                    guard let rows=names["voiceConfirmations"] as? [[String:Any]] else{throw ProfileStoreError.invalid}
                    rawRecords=rows
                } else {rawRecords=[]}
            } else {throw ProfileStoreError.invalid}
            guard rawRecords.count<=128 else{throw ProfileStoreError.invalid}
            let records=try rawRecords.map{try JSONDecoder().decode(SessionVoiceConfirmation.self,from:JSONSerialization.data(withJSONObject:$0))}
            guard records.allSatisfy({$0.session==session && UUID(uuidString:$0.id) != nil && !$0.segmentIDs.isEmpty}) && Set(records.map(\.id)).count==records.count else{throw ProfileStoreError.invalid}
            let current=Dictionary(uniqueKeysWithValues:records.map{($0.id,$0)})
            let matchingIDs=Set(archive.learning?.contributions.filter{contribution in
                guard contribution.session==session,let row=current[contribution.confirmationID] else{return false}
                return row.name==contribution.name && row.person==contribution.sharedPerson
            }.map(\.confirmationID) ?? [])
            archive=try archiveReconcilingVoiceConfirmations(archive,session:session,activeIDs:matchingIDs,domain:store.domain)
            archive=try self.reconcilingAutomaticSource(archive,folder:dir,session:session,namesData:namesData)
        }
        return archive
    }
    // Reuse the same projected source and SessionNames validation as display.
    // A model label may supply a candidate scope; it is never a human anchor.
    private func automaticSourceNames(folder:URL,session:String,data:Data)throws->SessionNames {
        let files=try FileManager.default.contentsOfDirectory(atPath:folder.path)
        let tracks=files.filter{$0.hasSuffix("-transcript.jsonl")}.map{String($0.dropLast("-transcript.jsonl".count))}.filter(isTranscriptAudioTrack)
        let item=CachedMeeting(id:folder.lastPathComponent,directory:folder,date:Date(),writtenBytes:0,pendingBytes:0,occupiedBytes:0,tracks:tracks,audioCleaned:false,warning:false,retiredBytes:0)
        var names=SessionNames()
        for event in try item.events() {
            guard let id=event["segment_id"] as? String else{continue}
            names.register(segment:id,item:event)
            for run in TranscriptTimeline.speakerRuns(event) {names.register(segment:TranscriptTimeline.runID(parent:id,run:run),item:run)}
        }
        try names.restore(data,session:session,events:try item.events(),directory:folder)
        return names
    }
    private func automaticSourceAllows(_ names:SessionNames,key:SessionSpeakerKey,personID:String,name:String,support:[VoiceprintEvidenceRef])->Bool {
        guard !support.isEmpty,support.allSatisfy({names.key(segment:$0.id)==key}) else{return false}
        // A manually named source may provide further independently matched
        // audio beyond its already stored samples. Its saved learning intent
        // must still exist; naming-only edits never opt a source into learning.
        if support.allSatisfy({names.name(segment:$0.id)==name}) {
            return names.voiceConfirmations.contains{record in
                record.name==name && record.segmentIDs.contains{names.key(segment:$0)==key}
            }
        }
        guard !names.autoNameIsSuppressed(key),let decision=names.autoName(for:key) ?? names.voiceSuggestion(for:key),
              decision.key==key,decision.personID==personID,decision.name==name else{return false}
        let scope=decision.recognizedSupport ?? decision.support
        return support.allSatisfy{ref in scope.contains(ref) && names.name(segment:ref.id)==nil}
    }
    private func reconcilingAutomaticSource(_ archive:VoiceprintArchive,folder:URL,session:String,namesData:Data)throws->VoiceprintArchive {
        let rows=archive.learning?.contributions.filter{$0.automatic?.key.session==session && archive.learning?.revokedConfirmationIDs.contains($0.confirmationID) != true} ?? []
        guard !rows.isEmpty else{return archive}
        let names=try automaticSourceNames(folder:folder,session:session,data:namesData)
        var next=archive
        for row in rows {
            guard let provenance=row.automatic else{continue}
            if !automaticSourceAllows(names,key:provenance.key,personID:row.personID,name:row.name,support:provenance.support) {
                next=try archiveRevokingVoiceConfirmation(next,confirmationID:row.confirmationID,domain:store.domain)
            }
        }
        return next
    }
    private func load()throws {
        if !loaded {
            let old=try store.load(),next=try recovered(old)
            if let old,let next,next.revision != old.revision {try store.save(next,expectedRevision:old.revision)}
            matcher.archive=next;loaded=true
        }
    }
    func setContinuousLearningEnabled(_ enabled:Bool) {
        learningPolicy.setEnabled(enabled)
        if !enabled {queue.async{self.approved=[];self.approvedSession=nil}}
    }
    private func learnAutomaticSaved(result:SavedVoiceRecognitionResult,folder:URL,job:SpeakerRefinementJob,token:UUID,commitGate:((()throws->Void)throws->Void)?)throws->[[String:Any]] {
        guard learningPolicy.isEnabled,job.isCurrent(token),let old=try store.load(),old.schema==2 else{return []}
        // Flush already queued name writes before checking the source decision.
        if let commitGate {try commitGate({})}
        let file=folder.appendingPathComponent("session-names.json")
        let namesData=try SavedVoiceRecognition.read(file,limit:4*1024*1024)
        let names=try automaticSourceNames(folder:folder,session:result.session,data:namesData)
        let human=VoiceprintArchive(schema:1,partition:old.partition,inputKind:old.inputKind,revision:old.revision,people:old.people)
        let ledger=old.learning!
        let manualSamples=ledger.baseline.flatMap(\.samples)+ledger.contributions.filter{$0.automatic==nil && !ledger.revokedConfirmationIDs.contains($0.confirmationID)}.flatMap(\.samples)
        let eligible=result.evidence.filter{row in
            !manualSamples.contains(where:{voiceSampleOverlap($0,row.sample)}) &&
            (names.name(segment:row.id) != nil || !names.autoNameIsSuppressed(row.key))
        }
        guard !eligible.isEmpty else{return []}
        var matcher=VoiceprintMatcher(archive:human);matcher.reset(session:result.session);matcher.importSavedEvidence(eligible)
        var next=old,report:[[String:Any]]=[]
        for key in Set(eligible.map(\.key)).sorted(by:{[$0.source,$0.epoch,$0.identity].joined() < [$1.source,$1.epoch,$1.identity].joined()}) {
            guard learningPolicy.isEnabled,job.isCurrent(token) else{throw SpeakerRefinementJobError.cancelled}
            // A source is learned once; reopening it must not repeat the replay.
            guard !next.learning!.contributions.contains(where:{$0.automatic?.key==key}) else{continue}
            guard let candidate=matcher.suggestion(key,groupCentroid:false),
                  automaticSourceAllows(names,key:key,personID:candidate.personID,name:candidate.name,support:candidate.support) else{continue}
            let support=candidate.support.compactMap{ref -> VoiceprintAutomaticSupport? in
                guard let row=eligible.first(where:{$0.id==ref.id && $0.revision==ref.revision && $0.key==key}) else{return nil}
                return VoiceprintAutomaticSupport(evidence:ref,sample:row.sample)
            }
            guard support.count==candidate.support.count else{continue}
            let anchors=next.learning!.contributions.filter{$0.automatic==nil && $0.personID==candidate.personID && !next.learning!.revokedConfirmationIDs.contains($0.confirmationID)}.map(\.confirmationID).sorted()
            let proposal=VoiceprintAutomaticCandidate(personID:candidate.personID,key:key,support:support,anchorConfirmationIDs:anchors,sourceArchiveRevision:next.revision)
            let decision=try proposeAutomaticVoiceprintContribution(next,candidate:proposal,domain:store.domain,isCurrent:{self.learningPolicy.isEnabled && job.isCurrent(token)})
            if decision.accepted {
                next=decision.archive
                report.append(["name":candidate.name,"status":"automatic_verified","samples":support.count,"before_correct":decision.before.correct,"after_correct":decision.after.correct])
            }
        }
        guard next.revision != old.revision else{return []}
        let request=SavedVoiceRecognitionRequest(folder:folder.path,session:result.session,inputKind:result.inputKind,keys:Array(Set(result.evidence.map(\.key))),sampleLimit:24)
        try SavedVoiceRecognition.validate(result,request:request)
        try store.save(next,expectedRevision:old.revision,commitGate:{replace in
            if let commitGate {
                try commitGate {
                    guard try Data(contentsOf:file)==namesData else{throw Failure(code:"voice_learning_names_changed")}
                    try replace()
                }
            } else {
                guard try Data(contentsOf:file)==namesData else{throw Failure(code:"voice_learning_names_changed")}
                try replace()
            }
        })
        return report
    }
    func learnSaved(result:SavedVoiceRecognitionResult,folder:URL,job:SpeakerRefinementJob,token:UUID,commitGate:((()throws->Void)throws->Void)?=nil,done:@escaping(Result<[[String:Any]],Error>)->Void) {
        let policy=learningPolicy
        queue.async {
            do {
                guard policy.isEnabled,job.isCurrent(token) else{throw Failure(code:"voice_learning_not_authorized")}
                try self.load()
                let gate:((()throws->Void)throws->Void)={replace in
                    try policy.commitIfEnabled {
                        try job.commitIfCurrent(token) {
                            if let commitGate {try commitGate(replace)}else{try replace()}
                        }
                    }
                }
                var report=try enrollSavedVoiceReferences(result:result,folder:folder,store:self.store,authorized:policy.isEnabled,createConfirmationIfMissing:false,commitGate:gate)
                report += try self.learnAutomaticSaved(result:result,folder:folder,job:job,token:token,commitGate:gate)
                guard job.isCurrent(token) else{throw SpeakerRefinementJobError.cancelled}
                self.matcher.archive=try self.store.load();self.loaded=true
                DispatchQueue.main.async{done(.success(report))}
            }catch {DispatchQueue.main.async{done(.failure(error))}}
        }
    }
    func reset(_ session:String?) {queue.async {self.matcher.reset(session:session);self.approved=[];self.approvedSession=nil}}
    private func personID(for record:SessionVoiceConfirmation,in archive:VoiceprintArchive?)->String {
        if let existing=archive?.learning?.contributions.first(where:{$0.confirmationID==record.id}) {return existing.personID}
        let people=(archive?.people ?? [])+(archive?.learning?.baseline ?? [])
        if let ref=record.person {
            let ids=Set(people.filter{$0.sharedPerson?.id==ref.id}.map(\.id)+(archive?.learning?.contributions.filter{$0.sharedPerson?.id==ref.id}.map(\.personID) ?? []))
            if ids.count==1 {return ids.first!}
            // The user selected an exact authoritative identity. Only a unique
            // legacy unlinked local voice can inherit that explicit selection.
            let legacy=Set(people.filter{$0.sharedPerson==nil && $0.name==record.name}.map(\.id))
            if ids.isEmpty,legacy.count==1 {return legacy.first!}
        } else {
            // Free text can use only an unlinked local voice, never silently
            // attach a shared identity merely because the name is equal.
            let ids=Set(people.filter{$0.sharedPerson==nil && $0.name==record.name}.map(\.id)+(archive?.learning?.contributions.filter{$0.sharedPerson==nil && $0.name==record.name}.map(\.personID) ?? []))
            if ids.count==1 {return ids.first!}
        }
        return UUID().uuidString
    }
    private func applyApproved(session:String,records:[SessionVoiceConfirmation])throws->String {
        try load()
        var old=try store.load()
        // Retractions must reach disk even if a new sample later fails quality
        // or capacity checks. A failed addition never keeps a revoked voice alive.
        if let value=old {
            let reconciled=try archiveReconcilingVoiceConfirmations(value,session:session,activeIDs:Set(records.map(\.id)),domain:store.domain)
            if reconciled.revision != value.revision {try store.save(reconciled,expectedRevision:value.revision);matcher.archive=reconciled;old=reconciled}
        }
        var next=old
        for record in records where matcher.session==record.session {
            guard learningPolicy.isEnabled else{continue}
            let samples=matcher.confirmationSamples(segmentIDs:record.segmentIDs)
            guard !samples.isEmpty else{continue}
            let prior=next?.learning?.contributions.first(where:{$0.confirmationID==record.id})
            if let prior,prior.samples.count>=8 {continue}
            var accumulated=prior?.samples ?? []
            for sample in samples where accumulated.count<8 {
                guard !accumulated.contains(sample),!accumulated.contains(where:{voiceSampleOverlap($0,sample)}),
                      accumulated.allSatisfy({voiceSimilarity($0,sample)>=0.60}) else{continue}
                accumulated.append(sample)
            }
            guard accumulated != prior?.samples, !accumulated.isEmpty else{continue}
            let identity=personID(for:record,in:next)
            if next?.learning?.enabledOverrides[identity]==false || next?.people.first(where:{$0.id==identity})?.enabled==false {continue}
            let contribution=VoiceprintLearningContribution(confirmationID:record.id,personID:identity,name:record.name,sharedPerson:record.person,confirmedAt:record.createdAt,samples:accumulated)
            next=try archiveAddingVoiceConfirmation(next,contribution:contribution,domain:store.domain)
        }
        if let next,next.revision != old?.revision {
            try store.save(next,expectedRevision:old?.revision,expectAbsent:old==nil,commitGate:{replace in
                try self.learningPolicy.commitIfEnabled(replace)
            })
        }
        matcher.archive=next
        guard !records.isEmpty else{return "姓名已保存，声音记忆已同步。"}
        let activeIDs=Set(records.suffix(1).map(\.id))
        let contributions=next?.learning?.contributions.filter{activeIDs.contains($0.confirmationID)} ?? []
        let hasReady=contributions.contains {row in next?.people.contains(where:{$0.id==row.personID && $0.enabled && $0.samples.contains(where:{s in row.samples.contains(where:{$0.session==s.session && $0.source==s.source && $0.epoch==s.epoch && $0.start==s.start && $0.end==s.end})})})==true}
        return hasReady ? "姓名已保存，已在本机记住声音。":"姓名已保存；声音参考还不足，暂未用于识别。"
    }
    func synchronize(session:String,confirmations:[SessionVoiceConfirmation],sourceFolder:URL?=nil,sourceNames:Data?=nil,done:@escaping(Result<String,Error>)->Void) {
        queue.async {
            if self.matcher.session==session {self.approvedSession=session;self.approved=confirmations}
            do {
                if let sourceFolder,let sourceNames,let old=try self.store.load() {
                    let reconciled=try self.reconcilingAutomaticSource(old,folder:sourceFolder,session:session,namesData:sourceNames)
                    if reconciled.revision != old.revision {try self.store.save(reconciled,expectedRevision:old.revision);self.matcher.archive=reconciled}
                }
                let status=try self.applyApproved(session:session,records:confirmations);DispatchQueue.main.async{done(.success(status))}
            }
            catch {self.matcher.archive=nil;self.loaded=false;DispatchQueue.main.async{done(.failure(error))}}
        }
    }
    func observe(_ event:[String:Any],confirmedManualNames:[SessionSpeakerKey:String]=[:],done:@escaping(Set<SessionSpeakerKey>,[SessionSpeakerKey:VoiceprintRecommendation],Set<SessionSpeakerKey>,String?)->Void) {
        queue.async {
            do {
                try self.load();let keys=self.matcher.observeParent(event,domain:self.store.domain)
                if let session=self.approvedSession,session==self.matcher.session,!self.approved.isEmpty {
                    let status=try self.applyApproved(session:session,records:self.approved)
                    if status != self.previousLearningStatus {self.previousLearningStatus=status;DispatchQueue.main.async{self.learningUpdate?(session,status)}}
                }
                var result:[SessionSpeakerKey:VoiceprintRecommendation]=[:];var conflicts=Set<SessionSpeakerKey>()
                for key in keys {result[key]=self.matcher.suggestion(key);if self.matcher.conflictingEvidence(key){conflicts.insert(key)}}
                DispatchQueue.main.async{done(keys,result,conflicts,nil)}
            }catch{self.matcher.archive=nil;self.loaded=false;DispatchQueue.main.async{done([],[:],[],"声音记忆暂未更新；请在发言人处重试，姓名标注不受影响。")}}
        }
    }
    func cancelPendingMemory(session:String?=nil) {queue.async{if session==nil || self.approvedSession==session {self.approved=[];self.approvedSession=nil}}}
    func dismiss(_ key:SessionSpeakerKey) {queue.async{self.matcher.dismiss(key)}}
    func discard(_ ids:[String]) {queue.async{for id in ids {self.matcher.remove(id)}}}
    func profiles(done:@escaping(VoiceprintArchive?,String?)->Void) {queue.async{do{try self.load();let archive=self.matcher.archive;DispatchQueue.main.async{done(archive,nil)}}catch{DispatchQueue.main.async{done(nil,"声音记忆暂时无法读取，请重试。")}}}}
    func updateEnabled(_ enabled:[String:Bool],revision:Int,done:@escaping(Bool)->Void) {
        queue.async {
            do {guard var archive=try self.store.load(),archive.revision==revision else{throw ProfileStoreError.invalid};let oldRevision=archive.revision
                for (id,value) in enabled {archive=try archiveSettingVoiceEnabled(archive,personID:id,enabled:value,domain:self.store.domain)}
                if archive.revision != oldRevision {try self.store.save(archive,expectedRevision:oldRevision)}
                self.matcher.archive=archive;self.loaded=true;DispatchQueue.main.async{done(true)}
            }catch{DispatchQueue.main.async{done(false)}}
        }
    }
    func recognizeSaved(_ result:SavedVoiceRecognitionResult,done:@escaping([SessionSpeakerKey:VoiceprintRecommendation],Set<SessionSpeakerKey>)->Void) {
        queue.async {
            do {
                let archive=try self.store.load()
                guard archive?.inputKind==result.inputKind else{DispatchQueue.main.async{done([:],[])};return}
                var matcher=VoiceprintMatcher(archive:archive);matcher.reset(session:result.session);matcher.importSavedEvidence(result.evidence)
                var values:[SessionSpeakerKey:VoiceprintRecommendation]=[:],conflicts=Set<SessionSpeakerKey>()
                for key in Set(result.evidence.map(\.key)) {values[key]=matcher.suggestion(key);if matcher.conflictingEvidence(key){conflicts.insert(key)}}
                DispatchQueue.main.async{done(values,conflicts)}
            }catch{DispatchQueue.main.async{done([:],[])}}
        }
    }
}

extension Delegate {
    var voiceprintManagementOwner:Delegate {workspaceOwner ?? self}
    func reloadLibraryAfterVoiceprintNameWrite() {
        cacheWriteQueue.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else{return}
                (self.workspaceOwner ?? self).reloadLibrary()
            }
        }
    }
    func setContinuousVoiceLearning(_ enabled:Bool) {
        let owner=voiceprintManagementOwner
        owner.voiceprintService?.setContinuousLearningEnabled(enabled)
        if !enabled {
            var seen=Set<ObjectIdentifier>()
            for reader in [owner,self,owner.historyReader].compactMap({$0}) where seen.insert(ObjectIdentifier(reader)).inserted {
                reader.savedVoiceRecognitionJob.cancel()
            }
        } else {
            let reader=isHistoryReader ? self:owner
            if let session=reader.activeSession {reader.synchronizeCommittedVoiceMemory(session:session,confirmations:reader.naming.voiceConfirmations,revision:reader.naming.correctionRevision)}
            reader.scheduleSavedVoiceRecognition()
        }
    }
    @objc func manageVoiceprintRecommendations() {
        guard let service=voiceprintManagementOwner.voiceprintService else{return}
        service.profiles { [weak self] archive,error in
            guard let self else{return}
            if let error {let notice=NSAlert();notice.messageText=error;notice.addButton(withTitle:"完成");notice.runModal();return}
            let notice=NSAlert();notice.messageText="声音记忆"
            notice.informativeText="以你确认过的人物为依据，自动积累通过效果验证的新声音。只在本机处理，关闭可停止新学习；也可随时撤销或禁用人物。"
            let panel=NSStackView();panel.orientation = .vertical;panel.alignment = .leading;panel.spacing=10
            let policy=VoiceprintLearningPolicy(),continuous=NSButton(checkboxWithTitle:"持续学习，让熟人识别更准",target:nil,action:nil)
            continuous.state=policy.isEnabled ? .on:.off;continuous.toolTip="只读取已保存录音中质量合格的片段，在本机提取声音特征。新安装默认关闭。"
            panel.addArrangedSubview(continuous)
            let people=NSStackView();people.orientation = .vertical;people.alignment = .leading;people.spacing=6
            var boxes:[(String,NSButton)]=[]
            for person in archive?.people ?? [] {let conditions=Set(person.samples.compactMap(\.context));let label=person.name+(conditions.isEmpty ? "":" · \(conditions.count) 种声音条件");let box=NSButton(checkboxWithTitle:label,target:nil,action:nil);box.state=person.enabled ? .on:.off;people.addArrangedSubview(box);boxes.append((person.id,box))}
            if archive?.people.isEmpty != false {
                let empty=NSTextField(wrappingLabelWithString:"目前还没有声音记忆。确认姓名后，符合质量条件的声音会逐步积累。")
                empty.textColor = .secondaryLabelColor;empty.maximumNumberOfLines=3;people.addArrangedSubview(empty)
            }
            let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:380,height:300));scroll.hasVerticalScroller=true;scroll.drawsBackground=false;scroll.borderType = .noBorder
            people.frame=NSRect(x:0,y:0,width:360,height:max(64,(archive?.people.count ?? 0)*30+8));scroll.documentView=people;panel.addArrangedSubview(scroll)
            panel.frame=NSRect(x:0,y:0,width:400,height:340);notice.accessoryView=panel;notice.addButton(withTitle:"保存");notice.addButton(withTitle:"取消")
            guard notice.runModal() == .alertFirstButtonReturn else{return}
            let nextPolicy=continuous.state == .on
            if nextPolicy != policy.isEnabled {self.setContinuousVoiceLearning(nextPolicy)}
            let values=Dictionary(uniqueKeysWithValues:boxes.map{($0.0,$0.1.state == .on)})
            guard let archive,!values.isEmpty else{return}
            service.updateEnabled(values,revision:archive.revision) { [weak self] ok in
                guard let self else{return}
                if ok {self.revokeDisabledVoiceprintNames(Set(values.filter{!$0.value}.map(\.key)))}
                else{self.voiceprintStatus="声音记忆未保存，请重试。"}
            }
        }
    }
    func configureVoiceprintRecommendations() {
        guard !previewRenderOnly else{return}
        let folder=RuntimeConfiguration.dataRoot().appendingPathComponent(offlineQA ? "DevelopmentQA/Voiceprints":"Voiceprints")
        voiceprintService=VoiceprintRecommendationService(store:VoiceprintArchiveStore(folder:folder,domain:offlineQA ? "synthetic_model_output":"consented_live_audio"))
        voiceprintService?.learningUpdate={ [weak self] session,status in
            guard let self,self.activeSession==session else{return};self.voiceprintStatus=status;self.showTransientFeedback(status,nameUndo:true)
        }
    }
    func resetVoiceprintRecommendations(session:String?) {
        confirmationController?.cancelQuickInteraction()
        savedVoiceRecognitionJob.cancel()
        if !isHistoryReader {historyReader?.savedVoiceRecognitionJob.cancel()}
        voiceprintGeneration &+= 1;voiceprintCandidates=[:];voiceprintService?.reset(session)
    }
    func observeVoiceprint(_ event:[String:Any]) {
        guard !replayingHistory,let service=voiceprintService,let session=activeSession,event["session"] as? String==session else{return}
        let generation=voiceprintGeneration
        var manualNames:[SessionSpeakerKey:String]=[:]
        for key in naming.choices(session:session) {if let name=naming.name(speaker:key) {manualNames[key]=name}}
        var contextualEvent=event
        if let sourceID=event["source_id"] as? String,VoiceprintAcousticContext.channel(for:sourceID)=="microphone",
           let input=(sourceActivity.signal[sourceID] ?? sourceActivity.signal["mic"])?["input_diagnostics"] as? [String:Any],
           let uid=(input["input_device"] as? [String:Any])?["uid"] as? String,!uid.isEmpty,uid.count<=512 {
            let context=VoiceprintAcousticContext(channel:"microphone",deviceFingerprint:historicalVoiceHash(Data(uid.utf8)))
            if let data=try? JSONEncoder().encode(context),let object=try? JSONSerialization.jsonObject(with:data) {contextualEvent["voice_acoustic_context"]=object}
        }
        service.observe(contextualEvent,confirmedManualNames:manualNames) { [weak self] keys,result,conflicts,error in
            guard let self,self.activeSession==session,self.voiceprintGeneration==generation else{return}
            if let error {self.voiceprintStatus=error;return}
            var changed=Set<SessionSpeakerKey>();var namesChanged=false
            for key in keys {
                let old=self.voiceprintCandidates[key],next=result[key]
                if old != next {changed.insert(key)}
                self.voiceprintCandidates[key]=next
                if self.naming.reconcileAutoVoiceprint(key:key,candidate:next,conflictingEvidence:conflicts.contains(key)) {namesChanged=true;changed.insert(key)}
            }
            if namesChanged {self.persistSessionNames();self.markAllTranscriptParentsDirty();self.reloadLibraryAfterVoiceprintNameWrite()}
            for key in changed {self.refreshVoiceprintHeading(key)}
            if !changed.isEmpty {self.refreshOpenSpeakerReview()}
        }
    }
    // Call only after the person-level name was explicitly saved by the user.
    // Restores, semantic inference and automatic voiceprint labels never call it.
    func rememberManualVoiceprint(key:SessionSpeakerKey,name:String) {
        guard VoiceprintLearningPolicy().isEnabled,key.session==activeSession,naming.name(speaker:key)==name else{return}
        naming.attachConfirmation(segmentIDs:naming.segmentIDs(for:key),name:name)
    }
    func synchronizeCommittedVoiceMemory(session:String,confirmations:[SessionVoiceConfirmation],revision:Int) {
        guard !previewRenderOnly || isHistoryReader || voiceprintService != nil else{return}
        let owner=voiceprintManagementOwner
        if owner.voiceprintService==nil {owner.configureVoiceprintRecommendations()}
        let generation=meetingDocumentGeneration
        let quietConfirmation=confirmationController?.pendingQuickName != nil || quickVoiceUndoPending
        let namesData=try? naming.snapshot(session:session)
        let sourceFolder=currentCacheID.map{recoveryBase().appendingPathComponent($0)}
        owner.voiceprintService?.synchronize(session:session,confirmations:confirmations,sourceFolder:sourceFolder,sourceNames:namesData) { [weak self] result in
            guard let self,self.activeSession==session,self.meetingDocumentGeneration==generation,self.naming.correctionRevision==revision else{return}
            switch result {
            case .success(let status):
                self.voiceprintStatus=status
                if !quietConfirmation && !confirmations.isEmpty {self.showTransientFeedback(status,nameUndo:true)}
            case .failure:self.voiceprintStatus="姓名已保存；声音记忆更新失败，请点姓名重试。";self.diagnostic.stringValue=self.voiceprintStatus
            }
            if !quietConfirmation && !confirmations.isEmpty {self.confirmationController?.setMemoryStatus(self.voiceprintStatus)}
        }
    }
    func cancelPendingVoiceprintMemory() {voiceprintManagementOwner.voiceprintService?.cancelPendingMemory(session:activeSession)}
    func observeSemanticName(_ event:[String:Any]) {
        guard !replayingHistory,event["session"] as? String==activeSession else{return}
        if naming.observeSemanticName(event) {persistSessionNames();markAllTranscriptParentsDirty();reloadLibraryAfterVoiceprintNameWrite();refreshOpenSpeakerReview()}
    }
    func voiceprintRecommendation(for key:SessionSpeakerKey)->VoiceprintRecommendation? {
        guard naming.name(speaker:key)==nil,!naming.autoNameIsSuppressed(key) else{return nil}
        if let candidate=voiceprintCandidates[key] {return candidate}
        guard let saved=naming.voiceSuggestion(for:key),
              let archive=voiceprintManagementOwner.voiceprintSuggestionArchive,
              archive.revision==saved.archiveRevision,
              archive.people.contains(where:{$0.id==saved.personID && $0.enabled && $0.name==saved.name}) else{return nil}
        return VoiceprintRecommendation(personID:saved.personID,name:saved.name,archiveRevision:saved.archiveRevision,evidenceCount:saved.support.count,support:saved.support,groupConsistent:false,recognizedSupport:saved.recognizedSupport)
    }
    func voiceprintHint(_ turn:ReadingTurn)->String {
        guard !turn.parts.contains(where:{naming.displayName(segment:$0.0) != nil}) else{return ""}
        let keys=Set(turn.parts.compactMap{naming.key(segment:$0.0) ?? SessionSpeakerKey.from($0.1)})
        guard keys.count==1,let key=keys.first,let candidate=voiceprintRecommendation(for:key) else{return ""}
        if !candidate.groupConsistent {
            let supported=Set(candidate.support.map(\.id))
            guard turn.parts.contains(where:{supported.contains($0.0)}) else{return ""}
        }
        return candidate.groupConsistent ? " · 可能是"+candidate.name:" · 部分声音像"+candidate.name
    }
    func refreshVoiceprintHeading(_ key:SessionSpeakerKey) {
        let identity=[key.session,key.source,key.epoch,key.identity].joined(separator:"\u{001F}")
        for parent in incrementalTranscript.parents(for:identity) {markTranscriptParentDirty(parent)}
        scheduleTranscriptRender()
    }
    @discardableResult func acceptVoiceprintRecommendation(_ key:SessionSpeakerKey)->Bool {
        guard key.session==activeSession else{return false}
        if let candidate=voiceprintRecommendation(for:key),let id=candidate.support.first(where:{namingItem($0.id) != nil})?.id {
            confirmationController?.popover.close()
            let editor=SpeakerConfirmationController(owner:self);confirmationController=editor
            editor.present(segment:id,showPopover:false);editor.commit()
            return naming.name(speaker:key)==candidate.name
        }
        let automatic=naming.displayName(speaker:key).flatMap{$0.origin != .manual ? $0.value:nil}
        guard let name=voiceprintRecommendation(for:key)?.name ?? automatic else{return false}
        guard !naming.values.contains(where:{naming.key(segment:$0.key)==naming.canonical(key) && $0.value != name}) else{voiceprintStatus="这组已有不同的人工标注，请先核对。";return false}
        guard naming.renameSpeaker(key:key,name:name) else{return false}
        cancelPendingVoiceprintMemory();rememberManualVoiceprint(key:key,name:name)
        voiceprintService?.dismiss(key);voiceprintCandidates.removeValue(forKey:key)
        persistSessionNames();markAllTranscriptParentsDirty();refreshOpenSpeakerReview()
        reloadLibraryAfterVoiceprintNameWrite()
        return true
    }
    func rejectVoiceprintRecommendation(_ key:SessionSpeakerKey) {
        cancelPendingVoiceprintMemory()
        voiceprintCandidates.removeValue(forKey:key);voiceprintService?.dismiss(key)
        if naming.dismissAutoName(key) {persistSessionNames();markAllTranscriptParentsDirty();reloadLibraryAfterVoiceprintNameWrite()}
        refreshVoiceprintHeading(key);refreshOpenSpeakerReview()
    }
    func revokeDisabledVoiceprintNames(_ people:Set<String>) {
        let owner=voiceprintManagementOwner;owner.voiceprintSuggestionArchive=nil
        var seen=Set<ObjectIdentifier>()
        for reader in [owner,self,owner.historyReader].compactMap({$0}) where seen.insert(ObjectIdentifier(reader)).inserted {
            reader.savedVoiceRecognitionJob.cancel()
            let keys=reader.voiceprintCandidates.filter{people.contains($0.value.personID)}.map(\.key)
            for key in keys {reader.voiceprintCandidates.removeValue(forKey:key)}
            var changed=false
            for person in people {for key in reader.naming.autoNamedKeys(personID:person) {changed=reader.naming.dismissAutoName(key) || changed}}
            if changed {reader.persistSessionNames();reader.markAllTranscriptParentsDirty()}
            for key in keys {reader.refreshVoiceprintHeading(key)}
            reader.refreshOpenSpeakerReview()
        }
        owner.reloadLibraryAfterVoiceprintNameWrite()
    }
}
