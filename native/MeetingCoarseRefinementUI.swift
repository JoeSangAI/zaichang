import AppKit
import Foundation

/// Uses the existing pause/end job gate. Every cloud request is scoped to the
/// saved meeting and every result is a disposable projection over original data.
enum MeetingCoarseAudioInput {
    static func object(_ file:URL,limit:Int=512*1024)throws->[String:Any] {
        let values=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isRegularFile==true,values.isSymbolicLink != true,(values.fileSize ?? Int.max)<=limit,
              file.standardizedFileURL==file.resolvingSymlinksInPath().standardizedFileURL,
              let value=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any] else{throw Failure(code:"coarse_input_invalid")}
        return value
    }
    static func tracks(meeting:CachedMeeting,events:[[String:Any]],allowUnsealed:Bool,cutoff:Double?=nil)throws->[[String:Any]] {
        let metadata=try meeting.metadata()
        guard let origin=metadata["capture_origin_uptime"] as? Double,origin.isFinite else{throw Failure(code:"coarse_origin_missing")}
        var result:[[String:Any]]=[]
        for source in Set(events.compactMap{$0["source_id"] as? String}).sorted() {
            guard isTranscriptAudioTrack(source) else{throw Failure(code:"coarse_source_invalid")}
            let manifest=try object(meeting.directory.appendingPathComponent(source+"-manifest.json"))
            let journalError=manifest["error"] as? String
            let isRecoverableWriterBackpressure=journalError=="cache_writer_backpressure"
            let processingError:String?
            if let value=manifest["processing_error"],!(value is NSNull) {
                guard let code=value as? String,!code.isEmpty,code.count<=128,
                      !code.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{throw Failure(code:"coarse_audio_incomplete")}
                processingError=code
            } else {processingError=nil}
            guard manifest["track"] as? String==source,manifest["format"] as? String=="pcm_s16le",
                  manifest["sample_rate"] as? Int==16000,manifest["channels"] as? Int==1,
                  manifest["audio_cleaned"] as? Bool != true,
                  manifest["ended"] as? Bool==true || allowUnsealed || isRecoverableWriterBackpressure,
                  let trackOrigin=manifest["origin_uptime"] as? Double,trackOrigin.isFinite,abs(trackOrigin-origin)<=86400,
                  let chunks=manifest["chunks"] as? [[String:Any]],chunks.count<=10000,
                  let written=manifest["written_bytes"] as? Int,written>0,written<=2764800000,written%2==0 else{throw Failure(code:"coarse_audio_incomplete")}
            let readableBytes:Int
            // Capture cutoff history is separate from coverage of saved PCM.
            // Once its durable ASR cursor catches up, no transcription is pending.
            let partialCoverage=processingError != nil ||
                ((manifest["ended"] as? Bool==true || isRecoverableWriterBackpressure) && (manifest["asr_committed_bytes"] as? Int ?? written)<written)
            if partialCoverage {
                guard let committed=manifest["asr_committed_bytes"] as? Int,committed>=0,committed%2==0,committed<=written else{throw Failure(code:"coarse_audio_incomplete")}
                readableBytes=committed
            } else {readableBytes=written}
            let offset=trackOrigin-origin
            guard offset.isFinite,offset >= -0.25,offset<=86400 else{throw Failure(code:"coarse_origin_invalid")}
            // Only read this pause's immutable PCM prefix. ASR can finish its
            // tail independently; already-readable text does not wait for it.
            let cap=cutoff.map{min(readableBytes,max(0,Int(($0-offset)*16000)*2))} ?? readableBytes
            guard cap>0 else{continue}
            var cursor=0,files:[[String:Any]]=[]
            for (index,chunk) in chunks.enumerated() {
                guard chunk["index"] as? Int==index,chunk["start_sample"] as? Int==cursor/2,
                      let count=chunk["bytes"] as? Int,count>0,count<=320000,count%2==0 else{throw Failure(code:"coarse_audio_invalid")}
                guard cursor<=written-count else{throw Failure(code:"coarse_audio_invalid")}
                let file=meeting.directory.appendingPathComponent(source+String(format:"-%06d.pcm",index))
                let attrs=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                guard attrs.isRegularFile==true,attrs.isSymbolicLink != true,(attrs.fileSize ?? 0)>=count else{throw Failure(code:"coarse_audio_changed")}
                let handle=try FileHandle(forReadingFrom:file)
                defer{try? handle.close()}
                let data=try handle.read(upToCount:count) ?? Data()
                guard data.count==count else{throw Failure(code:"coarse_audio_changed")}
                if let hash=chunk["sha256"] as? String {guard MeetingSpeakerReconciliation.hash(data)==hash else{throw Failure(code:"coarse_audio_changed")}}
                else {guard chunk["sha256"]==nil,index==chunks.count-1,(allowUnsealed && manifest["ended"] as? Bool==false) || SpeakerRefinementArtifact.isRecoveredTranscription(manifest) else{throw Failure(code:"coarse_audio_invalid")}}
                if cursor<cap {
                    let included=min(count,cap-cursor)
                    files.append(["path":file.path,"written_bytes":included])
                }
                cursor+=count
            }
            guard cursor==written,cap<=cursor else{throw Failure(code:"coarse_audio_changed")}
            result.append(["source_id":source,"origin_seconds":offset,"written_bytes":cap,"chunks":files,
                           "coverage_complete":!partialCoverage])
        }
        guard !result.isEmpty else{throw Failure(code:"coarse_audio_missing")}
        return result
    }

}

/// A pause snapshot may outlive the visible meeting. Keep only its immutable
/// cache/session/cutoff identity when chaining the queued pause after a switch.
struct SavedCoarseBatchScope {
    let cacheID:String
    let session:String
    let cutoff:Double
}

extension Delegate {
    func coarseErrorCode(_ error:Error?)->String {
        if case .serviceFailure(let value)=error as? SpeakerRefinementJobError {return value}
        if let value=error as? Failure {return value.code}
        if let value=error as? SpeakerRefinementArtifactError {return String(describing:value)}
        if let value=error as? MeetingCoarseRefinementError {return String(describing:value)}
        if let value=error as? SpeakerRefinementJobError {return String(describing:value)}
        if let error {let value=error as NSError;return value.domain+":"+String(value.code)}
        return "unavailable"
    }
    func coarseFailureMessage(_ error:Error?)->String {
        let code=coarseErrorCode(error)
        if code=="coarse_key_unavailable" {return "整理服务未连接，请检查服务设置"}
        if code=="previous_attempt_unknown" {return "上次整理中断，可点击重新整理"}
        if code=="provider_timeout" {return "整理服务连接超时，可重试；原音与原文保留"}
        if code=="provider_dns_unavailable" {return "整理服务地址解析失败，请检查网络；原音与原文保留"}
        if code=="provider_tls_unavailable" {return "整理服务安全连接失败；原音与原文保留"}
        if code=="provider_connection_unavailable" {return "整理服务连接中断，可重试；原音与原文保留"}
        if code=="provider_http_400" || code=="provider_http_404" {return "整理服务暂不支持本次请求，已有文字保留"}
        if code=="provider_http_401" || code=="provider_http_403" {return "整理服务无访问权限，请检查服务设置"}
        if code=="coarse_audio_incomplete" {return "录音尚有文字待补齐，暂未整理"}
        if code=="coarse_no_complete_text" {return "这段录音尚无可整理的完整转写；原音已保留，补齐转写后可重试"}
        return "AI整理未完成，已有文字保留"
    }
    /// Local acoustic reconciliation always precedes text-only presentation.
    /// It uses the same cancellable job as the following cloud stage.
    func runAutomaticAcoustic(folder:URL,session:String,allowUnsealed:Bool,job:SpeakerRefinementJob,token:UUID,
                              done:@escaping(Result<Void,Error>)->Void) {
        // Existing injected text-worker tests have no PCM/model. Real meeting
        // validation exercises this helper and the same validated commit below.
        if coarseRefinementExecutorOverride != nil {done(.success(()));return}
        if currentCacheID==folder.lastPathComponent,activeSession==session {savedVoiceRecognitionJob.cancel()}
        let namesFile=folder.appendingPathComponent("session-names.json")
        func manualState()->Data? {
            guard let data=try? Data(contentsOf:namesFile),let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{return nil}
            let fields=Set(["schema","session","sentences","speakers","assignments","runAnchors","aliases","voiceConfirmations","personReferences","autoSuppressed"])
            return try? JSONSerialization.data(withJSONObject:object.filter{fields.contains($0.key)},options:[.sortedKeys])
        }
        let namesBefore=manualState()
        let model=URL(fileURLWithPath:root).appendingPathComponent("native/local-embedding-install/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")
        job.startProcess(request:["folder":folder.path,"session":session,"allow_unsealed":allowUnsealed],executable:captureExecutableURL,
            arguments:["--automatic-acoustic-refinement",model.path],maximumInput:65536,maximumOutput:SpeakerRefinementArtifact.maximumBytes,reservedToken:token) { returned,result in
            self.cacheWriteQueue.async {
                guard job.isCurrent(returned) else{return}
                do {
                    let data=try result.get()
                    guard manualState()==namesBefore else{throw Failure(code:"acoustic_names_changed")}
                    guard let meeting=try cachedMeetings(in:folder.deletingLastPathComponent()).first(where:{$0.id==folder.lastPathComponent}) else{throw Failure(code:"acoustic_meeting_missing")}
                    let events=try meeting.events(includeAutomaticRefinement:false),hashes=try meeting.transcriptHashes()
                    let prepared=try SpeakerRefinementArtifact.prepareValidated(data:data,events:events,sourceHashes:hashes,directory:folder,cacheID:meeting.id)
                    try job.commitIfCurrent(returned) {try SpeakerRefinementArtifact.writePrepared(prepared)}
                    try job.prepareNextProcess(returned)
                    DispatchQueue.main.async {
                        if self.currentCacheID==meeting.id,self.activeSession==session {
                            self.refreshSpeakerRefinementProjection(cacheID:meeting.id,session:session)
                        }
                    }
                    done(.success(()))
                } catch {done(.failure(error))}
            }
        }
    }

    func scheduleCoarseRefinement(trigger:String,allowUnsealed:Bool,cutoff:Double?=nil,savedScope:SavedCoarseBatchScope?=nil) {
        guard (!Credential.offline || coarseRefinementExecutorOverride != nil),!quitting,!meetingDeletionBusy else{return}
        let cacheID:String,session:String,boundary:Double?,isSavedScope:Bool
        if let savedScope {
            guard savedScope.cutoff.isFinite,savedScope.cutoff>0 else{return}
            cacheID=savedScope.cacheID;session=savedScope.session;boundary=savedScope.cutoff;isSavedScope=true
        } else {
            guard !sessionLocalOnly,let currentID=currentCacheID,UUID(uuidString:currentID) != nil,let currentSession=activeSession,
                  [.paused,.stopped].contains(phase.phase) || (phase.phase == .recording && cutoff != nil) || (phase.phase == .failed && cachedTranscriptionComplete) else{return}
            cacheID=currentID;session=currentSession
            boundary=cutoff.flatMap{$0.isFinite && $0>0 ? $0:nil};isSavedScope=false
        }
        let base=recoveryBase(),folder=recoveryBase().appendingPathComponent(cacheID,isDirectory:true)
        let owner=workspaceOwner ?? self
        if owner.savedCoarseJobs[cacheID] != nil {
            // Let the earlier pause commit its finished windows. Its completion
            // schedules one fresh snapshot for audio appended since that pause.
            owner.pendingCoarseCutoffs[cacheID]=max(owner.pendingCoarseCutoffs[cacheID] ?? 0,boundary ?? self.phase.elapsed)
            if !isSavedScope {
                speakerRefinementNeedsRetry=true
                speakerRefinementMessage="正在完成上一段整理"
                updateUI()
            }
            return
        }
        // An explicit retry rebuilds from the complete current transcript and
        // therefore subsumes any queued append-only follow-up.
        if trigger=="manual_retry" {speakerRefinementNeedsRetry=false}
        owner.savedCoarseJobs.removeValue(forKey:cacheID)
        owner.pendingCoarseCutoffs.removeValue(forKey:cacheID)
        if !isSavedScope {speakerRefinementNeedsRetry=false}
        let job=isSavedScope ? SpeakerRefinementJob():speakerRefinementJob
        let priorInputSignature=owner.lastCoarseInputSignatures[cacheID]
        let token=job.reserve(),generation=meetingDocumentGeneration,revision=naming.correctionRevision
        owner.savedCoarseJobs[cacheID]=job
        if !isSavedScope {
            speakerRefinementToken=token;speakerRefinementScope=(cacheID,session,generation,revision);speakerRefinementMessage=nil;speakerRefinementFailureCode=nil;speakerRefinementFailureRevision=nil;coarseResultToken=nil
            coarseProcessingProgress=CoarseProcessingProgress(runID:token.uuidString,stage:"preparing",completed:0,total:0)
            coarseProcessingSummary=nil
        }
        saveCoarseStatus(cacheID:cacheID,session:session,state:"running")
        if !isSavedScope {
            observeCoarseProgress(cacheID:cacheID,session:session,token:token,job:job)
            diagnostic.stringValue="正在整理暂停前的内容…";updateUI();refreshOpenSpeakerReview()
        }
        let prepareSavedNames:(@escaping (Result<Void,Error>)->Void)->Void = { completion in
            if isSavedScope {completion(.success(()))}
            else {self.persistSessionNames(done:completion)}
        }
        prepareSavedNames { saved in
            guard job.isCurrent(token) else{return}
            if case .failure(let error)=saved {self.failSpeakerRefinement(token:token,cacheID:cacheID,session:session,generation:generation,revision:revision,error:error,job:job);return}
            self.runAutomaticAcoustic(folder:folder,session:session,allowUnsealed:allowUnsealed,job:job,token:token) { acoustic in
            if case .failure(let error)=acoustic {
                DispatchQueue.main.async {
                    self.failSpeakerRefinement(token:token,cacheID:cacheID,session:session,generation:generation,revision:revision,error:error,job:job)
                    self.continuePendingCoarseBatch(cacheID:cacheID,session:session)
                }
                return
            }
            self.cacheWriteQueue.async {
                guard job.isCurrent(token) else{return}
                do {
                    guard let meeting=try cachedMeetings(in:base).first(where:{$0.id==cacheID}) else{throw Failure(code:"coarse_meeting_missing")}
                    let metadata=try meeting.metadata()
                    guard metadata["session"] as? String==session,metadata["cloud_session_authorized"] as? Bool==true,
                          metadata["asr_destination"] as? String=="dashscope.aliyuncs.com" else{throw Failure(code:"coarse_cloud_scope_missing")}
                    let allEvents=try meeting.events(includeCoarseRefinement:false),hashes=try meeting.transcriptHashes()
                    let events=boundary.map{end in allEvents.filter{($0["end"] as? Double ?? .infinity)<=end}} ?? allEvents
                    let payload=try MeetingCoarseRefinement.prepareRequest(directory:folder,session:session,cacheID:cacheID,events:events,transcriptHashes:hashes)
                    guard !payload.units.isEmpty else{throw Failure(code:"coarse_no_complete_text")}
                    var request=try JSONSerialization.jsonObject(with:JSONEncoder().encode(payload)) as! [String:Any]
                    request["audio_tracks"]=try MeetingCoarseAudioInput.tracks(meeting:meeting,events:events,allowUnsealed:allowUnsealed,cutoff:boundary)
                    request["run_id"]=token.uuidString
                    request["allow_retry"]=trigger=="manual_retry"
                    request["cache_dir"]=folder.path
                    var signatureInput=request
                    for name in ["run_id","source_sha256","snapshot_sha256","allow_retry"] {signatureInput.removeValue(forKey:name)}
                    let inputSignature=MeetingSpeakerReconciliation.hash(try JSONSerialization.data(withJSONObject:signatureInput,options:[.sortedKeys]))
                    if inputSignature==priorInputSignature {
                        DispatchQueue.main.async {
                            guard job.isCurrent(token),owner.savedCoarseJobs[cacheID] === job else{return}
                            owner.savedCoarseJobs.removeValue(forKey:cacheID)
                            self.saveCoarseStatus(cacheID:cacheID,session:session,state:"complete")
                            job.cancel() // No process was started; release the reserved waiting slot.
                            if self.currentCacheID==cacheID {
                                self.speakerRefinementToken=nil;self.speakerRefinementScope=nil
                                self.coarseProcessingProgress=nil;self.coarseProgressTimer?.invalidate()
                                self.coarseProcessingSummary="上一段已整理，可标记发言人"
                                self.updateUI();self.refreshOpenSpeakerReview()
                            }
                            self.continuePendingCoarseBatch(cacheID:cacheID,session:session)
                        }
                        return
                    }
                    let injected=self.coarseRefinementExecutorOverride
                    let key=try injected != nil ? "synthetic":Credential.load(allowInteraction:false)
                    guard let key,!key.isEmpty else{throw Failure(code:"coarse_key_unavailable")}
                    guard job.isCurrent(token) else{return}
                    let completed:(UUID,Result<Data,Error>)->Void = { returned,result in
                        self.cacheWriteQueue.async {
                            guard job.isCurrent(returned) else{return}
                            do {
                                let data=try result.get()
                                guard let output=try JSONSerialization.jsonObject(with:data) as? [String:Any],output["session"] as? String==session,output["cache_id"] as? String==cacheID,
                                      output["records"] is [[String:Any]] else{throw Failure(code:"coarse_output_invalid")}
                                let current=try meeting.events(includeCoarseRefinement:false),currentHashes=try meeting.transcriptHashes()
                                let check=try MeetingCoarseRefinement.prepareRequest(directory:folder,session:session,cacheID:cacheID,events:current,transcriptHashes:currentHashes)
                                let projected=try MeetingCoarseRefinement.rebaseResponse(output,request:payload,events:current,directory:folder,transcriptHashes:currentHashes)
                                let reserved=(output["reserved_yuan"] as? NSNumber)?.doubleValue ?? 0
                                let usage=try? MeetingCoarseAudioInput.object(folder.appendingPathComponent("session-usage.json"))
                                let asr=(usage?["cumulative_estimated_yuan"] as? String).flatMap(Double.init)
                                let estimated=asr.map{$0+reserved}
                                let artifact=try JSONSerialization.data(withJSONObject:projected.artifact,options:[.sortedKeys])
                                try job.commitIfCurrent(returned) {
                                    try artifact.write(to:folder.appendingPathComponent(MeetingCoarseRefinement.filename),options:.atomic)
                                    try self.writeCoarsePreference(directory:folder,session:session,enabled:true)
                                }
                                DispatchQueue.main.async {
                                    guard job.isCurrent(returned) else{return}
                                    let detached = job !== self.speakerRefinementJob || self.currentCacheID != cacheID
                                    if self.currentCacheID==cacheID,let estimated,estimated.isFinite {self.phase.estimated=estimated}
                                    if projected.events.first?["coarse_refinement_warning"] == nil {owner.lastCoarseInputSignatures[cacheID]=inputSignature}
                                    self.finishSpeakerRefinement(token:returned,cacheID:cacheID,session:session,generation:generation,revision:revision,events:projected.events,coarseSourceSHA256:check.source_sha256,coarseSnapshotSHA256:check.snapshot_sha256,job:job)
                                    // A resumed worker owns only its immutable request snapshot.
                                    // Refresh through the active delegate so current names,
                                    // revisions, and transcript edits remain authoritative.
                                    if detached,self.currentCacheID==cacheID,self.activeSession==session {
                                        self.refreshSpeakerRefinementProjection(cacheID:cacheID,session:session)
                                    }
                                    self.continuePendingCoarseBatch(cacheID:cacheID,session:session)

                                }
                            } catch {DispatchQueue.main.async{
                                self.failSpeakerRefinement(token:returned,cacheID:cacheID,session:session,generation:generation,revision:revision,error:error,job:job)
                                self.showCoarseFailureIfCurrent(cacheID:cacheID,session:session,error:error)
                                self.continuePendingCoarseBatch(cacheID:cacheID,session:session)
                            }}
                        }
                    }
                    if let injected {injected(request,token,completed)}
                    else {job.startProcess(request:["key":key,"request":request],executable:URL(fileURLWithPath:"/usr/local/bin/python3"),arguments:["-u",self.root+"/coarse_audio.py"],maximumInput:4*1024*1024,reservedToken:token,done:completed)}
                } catch {DispatchQueue.main.async{
                    self.failSpeakerRefinement(token:token,cacheID:cacheID,session:session,generation:generation,revision:revision,error:error,job:job)
                    self.showCoarseFailureIfCurrent(cacheID:cacheID,session:session,error:error)
                                self.continuePendingCoarseBatch(cacheID:cacheID,session:session)
                }}
            }
        }
        }
    }
    func continuePendingCoarseBatch(cacheID:String,session:String) {
        guard !quitting,!meetingDeletionBusy,
              let cutoff=(workspaceOwner ?? self).pendingCoarseCutoffs.removeValue(forKey:cacheID) else{return}
        if currentCacheID==cacheID,activeSession==session {
            speakerRefinementNeedsRetry=false
            scheduleCoarseRefinement(trigger:"pause",allowUnsealed:true,cutoff:cutoff)
        } else {
            // A new meeting may already be visible. Continue only the saved
            // meeting's bounded batch, without borrowing its names or UI state.
            scheduleCoarseRefinement(trigger:"pause",allowUnsealed:true,
                savedScope:SavedCoarseBatchScope(cacheID:cacheID,session:session,cutoff:cutoff))
        }
    }
    func observeCoarseProgress(cacheID:String,session:String,token:UUID,job:SpeakerRefinementJob) {
        coarseProgressTimer?.invalidate()
        let owner=workspaceOwner ?? self
        let file=recoveryBase().appendingPathComponent(cacheID).appendingPathComponent("coarse-audio-progress.json")
        var reading=false
        coarseProgressTimer=Timer.scheduledTimer(withTimeInterval:0.7,repeats:true) { [weak self] timer in
            guard let self,owner.savedCoarseJobs[cacheID] === job,job.isCurrent(token) else{timer.invalidate();return}
            guard !reading else{return};reading=true
            self.cacheWriteQueue.async {
                let value=(try? MeetingCoarseAudioInput.object(file,limit:32*1024*1024))?["status"] as? [String:Any]
                DispatchQueue.main.async {
                    reading=false
                    guard self.currentCacheID==cacheID,self.activeSession==session,
                          owner.savedCoarseJobs[cacheID] === job,job.isCurrent(token),
                          let value,value["run_id"] as? String==token.uuidString,
                          value["session"] as? String==session,value["cache_id"] as? String==cacheID,
                          let stage=value["stage"] as? String,["audio","speakers"].contains(stage) else{return}
                    self.coarseProcessingProgress=CoarseProcessingProgress(runID:token.uuidString,stage:stage,completed:value["completed"] as? Int ?? 0,total:value["total"] as? Int ?? 0)
                    self.updateUI();self.refreshOpenSpeakerReview()
                }
            }
        }
    }
    func showCoarseFailureIfCurrent(cacheID:String,session:String,error:Error) {
        guard currentCacheID==cacheID,activeSession==session else{return}
        speakerRefinementMessage=coarseFailureMessage(error)
        if !speakerRefinementCheckMode {updateUI()}
    }
    func saveCoarseStatus(cacheID:String,session:String,state:String,error:Error?=nil) {
        guard !Credential.offline else{return}
        let directory=recoveryBase().appendingPathComponent(cacheID,isDirectory:true)
        let value:[String:Any]=["schema":1,"session":session,"state":state,"error":error.map{coarseErrorCode($0)} ?? "", "updated_at":ISO8601DateFormatter().string(from:Date())]
        cacheWriteQueue.async {
            guard let metadata=try? MeetingCoarseAudioInput.object(directory.appendingPathComponent("meeting.json")),metadata["session"] as? String==session else{return}
            try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:directory.appendingPathComponent("coarse-refinement-status.json"),options:.atomic)
        }
    }
    var hasCoarseResult:Bool {
        guard let cacheID=currentCacheID else{return false}
        return FileManager.default.fileExists(atPath:recoveryBase().appendingPathComponent(cacheID).appendingPathComponent(MeetingCoarseRefinement.filename).path)
    }
    func writeCoarsePreference(directory:URL,session:String,enabled:Bool)throws {
        try JSONSerialization.data(withJSONObject:["schema":1,"session":session,"enabled":enabled],options:[.sortedKeys]).write(to:directory.appendingPathComponent("coarse-refinement-preference.json"),options:.atomic)
    }
    @objc func toggleCoarseRefinement() {
        if hasRunningCoarseRefinement {
            if let id=currentCacheID,let session=activeSession {
                cancelSpeakerRefinement(cacheID:id);saveCoarseStatus(cacheID:id,session:session,state:"cancelled")
            } else {cancelSpeakerRefinement()}
            speakerRefinementMessage="整理已停止，已有文字保留"
            updateUI();refreshOpenSpeakerReview()
        } else {retrySpeakerRefinement()}
    }
    var hasRunningCoarseRefinement:Bool {
        speakerRefinementToken != nil || currentCacheID.map{(workspaceOwner ?? self).savedCoarseJobs[$0] != nil}==true
    }
    var showsCoarseProjection:Bool {segments.values.contains{$0["coarse_refinement_applied"] as? Bool==true}}
    @objc func toggleCoarseProjection() {
        guard let cacheID=currentCacheID,let session=activeSession,[.paused,.stopped].contains(phase.phase),!hasRunningCoarseRefinement else{return}
        let enabled = !showsCoarseProjection,folder=recoveryBase().appendingPathComponent(cacheID,isDirectory:true)
        cacheReadJob.run(work:{try self.writeCoarsePreference(directory:folder,session:session,enabled:enabled)}) { [weak self] result in
            guard let self,self.currentCacheID==cacheID,self.activeSession==session else{return}
            if case .success=result {self.refreshSpeakerRefinementProjection(cacheID:cacheID,session:session);self.speakerRefinementMessage=enabled ? "显示整理稿":"显示原始转写";self.updateUI()}
            else {self.showTransientFeedback("切换未完成，当前文字保留")}
        }
    }
}

/// Real saved-audio acceptance: only isolated runtime copies, no capture/cloud.
@MainActor
func automaticAcousticMeetingCheck(directory:URL) async throws->[String:Any] {
    guard Credential.offline,directory.path.contains("/.runtime/automatic-speakers-"),
          let meeting=try cachedMeetings(in:directory.deletingLastPathComponent()).first(where:{$0.id==directory.lastPathComponent}),
          let session=try meeting.metadata()["session"] as? String else{throw Failure(code:"acoustic_check_scope")}
    let raw=try meeting.events(includeAutomaticRefinement:false),before=try meeting.transcriptHashes()
    let readingBefore=MeetingCoarseRefinement.loadApply(events:raw,directory:directory,session:session,cacheID:meeting.id,transcriptHashes:before)
    let namesFile=directory.appendingPathComponent("session-names.json"),namesBefore=try? Data(contentsOf:namesFile)
    let view=Delegate();view.speakerRefinementCheckMode=true
    let job=SpeakerRefinementJob(),token=job.reserve()
    try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
        view.runAutomaticAcoustic(folder:directory,session:session,allowUnsealed:false,job:job,token:token) {result in continuation.resume(with:result)}
    }
    guard job.waiting,job.isCurrent(token) else{throw Failure(code:"acoustic_stage_did_not_rearm")}
    let _:Data=try await withCheckedThrowingContinuation { continuation in
        job.startProcess(request:[:],executable:view.captureExecutableURL,arguments:[],reservedToken:token) {_,result in continuation.resume(with:result)}
    }
    guard job.isCurrent(token),!job.busy,!job.waiting else{throw Failure(code:"acoustic_second_stage_failed")}
    job.cancel()
    do {try job.prepareNextProcess(token);throw Failure(code:"acoustic_stale_stage_rearmed")} catch SpeakerRefinementJobError.cancelled {}
    let events=try meeting.events(includeCoarseRefinement:false)
    guard events.count==raw.count,try meeting.transcriptHashes()==before,(try? Data(contentsOf:namesFile))==namesBefore,
          !events.contains(where:{$0["speaker_refinement_warning"] != nil}) else{throw Failure(code:"acoustic_check_projection")}
    for (a,b) in zip(raw,events) {
        for field in ["text","start","end","segment_id","source_id","epoch","revision"] {
            guard String(describing:a[field] ?? "")==String(describing:b[field] ?? "") else{throw Failure(code:"acoustic_source_mutated")}
        }
    }
    func register(_ rows:[[String:Any]],_ names:inout SessionNames) {
        for event in rows {
            guard let id=event["segment_id"] as? String else{continue}
            names.register(segment:id,item:event)
            for run in TranscriptTimeline.speakerRuns(event) {names.register(segment:TranscriptTimeline.runID(parent:id,run:run),item:run)}
        }
    }
    var incremental=SessionNames(),fresh=SessionNames()
    register(raw,&incremental);register(events,&incremental);register(events,&fresh)
    guard Set(incremental.choices(session:session))==Set(fresh.choices(session:session)) else{throw Failure(code:"acoustic_stale_identity_bindings")}
    let readingAfter=try meeting.events()
    guard readingBefore.count==readingAfter.count,
          zip(readingBefore,readingAfter).allSatisfy({($0["text"] as? String)==($1["text"] as? String)}) else{throw Failure(code:"acoustic_clean_text_changed")}
    guard !readingAfter.contains(where:{$0["coarse_refinement_warning"] != nil || $0["speaker_refinement_warning"] != nil}) else{throw Failure(code:"acoustic_clean_text_warning")}
    let artifact=try SpeakerRefinement.object(directory.appendingPathComponent(SpeakerRefinementArtifact.filename))
    let units=events.flatMap{event -> [[String:Any]] in
        let rows=event["speaker_runs"] as? [[String:Any]] ?? []
        return (rows.isEmpty ? [event]:rows).map { row in
            var unit=row
            for field in ["session","source_id","epoch"] {unit[field]=event[field]}
            unit["segment_id"]=rows.isEmpty ? event["segment_id"]:TranscriptTimeline.runID(parent:event["segment_id"] as! String,run:row)
            return unit
        }
    }
    return ["cache_id":meeting.id,"summary":artifact["summary"] ?? [:],"units":units,
            "original_preserved":true,"names_preserved":true,"clean_text_preserved":true,"incremental_identities_match_reopen":true,
            "validated_ui_commit":true,"cancelled_stage_rejected":true,"capture":false,"cloud":false]
}
