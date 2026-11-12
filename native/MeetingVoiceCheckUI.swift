import Foundation

/// Runs the after-meeting voice check (MeetingVoiceCheck) on this Mac: when a
/// finished meeting is opened, after its voices are reconciled, and a few
/// seconds after the user names a line. Never while anything is recording,
/// pending transcription or being tidied up; a newer request replaces an
/// older one. The result is derived and only shown for the names it was made for.
extension Delegate {
    func scheduleVoiceCheck(delay:Double=3) {
        voiceCheckPending?.cancel()
        let work=DispatchWorkItem{[weak self] in self?.startVoiceCheck()}
        voiceCheckPending=work
        DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:work)
    }

    private var voiceCheckAllowed:Bool {
        guard !quitting,!Credential.offline,!previewRenderOnly || isHistoryReader,!hasRunningCoarseRefinement else{return false}
        if isHistoryReader {return !voiceprintManagementOwner.savedVoiceRecognitionBlocksHistory}
        return [.stopped,.failed].contains(phase.phase) && !recordingBusy && !resumeBusy && !processingAudio && !hasPendingTranscriptionWork
    }

    private func startVoiceCheck() {
        guard voiceCheckAllowed,let cache=currentCacheID,UUID(uuidString:cache) != nil,let session=activeSession else{return}
        let folder=recoveryBase().appendingPathComponent(cache,isDirectory:true),job=voiceCheckJob
        let model=URL(fileURLWithPath:root).appendingPathComponent("native/local-embedding-install/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")
        let executable=captureExecutableURL
        cacheWriteQueue.async { [weak self] in
            guard MeetingVoiceCheck.isStale(directory:folder,session:session) else{return}
            DispatchQueue.main.async { [weak self] in
                guard let self,self.voiceCheckAllowed,self.currentCacheID==cache,self.activeSession==session else{return}
                job.cancel()
                job.startProcess(request:["folder":folder.path,"session":session],executable:executable,
                                 arguments:["--voice-check",model.path],maximumInput:65536,maximumOutput:8*1024*1024) { [weak self] returned,result in
                    guard let self else{return}
                    self.cacheWriteQueue.async {
                        guard job.isCurrent(returned),case .success(let data)=result,
                              let checked=try? MeetingVoiceCheck.validated(data,session:session,cacheID:cache),
                              let names=try? Data(contentsOf:folder.appendingPathComponent("session-names.json")),
                              let object=(try? JSONSerialization.jsonObject(with:names)) as? [String:Any],
                              MeetingVoiceCheck.namesDigest(object)==checked.digest else{return}
                        do {try MeetingVoiceCheck.write(data,directory:folder)} catch {return}
                        DispatchQueue.main.async { [weak self] in
                            guard let self,job.isCurrent(returned),self.currentCacheID==cache,self.activeSession==session else{return}
                            self.naming.applyVoiceChecks(checked.names)
                            self.markAllTranscriptParentsDirty();self.renderText();self.updateUI()
                            self.refreshSpeakerStrip(force:true);self.refreshOpenSpeakerReview()
                        }
                    }
                }
            }
        }
    }
}
