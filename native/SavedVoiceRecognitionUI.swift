import AppKit

// A real embedded history reader deliberately uses preview rendering to avoid
// capture/startup effects. That rendering flag must not disable saved matching.
func savedVoiceRecognitionEligible(offline:Bool,preview:Bool,history:Bool,fixtureExecutor:Bool)->Bool {
    (!offline || fixtureExecutor) && (!preview || history)
}

extension Delegate {
    // A paused capture helper remains alive for resume, so recordingBusy stays
    // true. It must not block matching a different, already saved meeting.
    var savedVoiceRecognitionBlocksHistory:Bool {
        if phase.phase == .paused {
            return quitting || preparingModels || processingAudio || resumeBusy ||
                credentialReadJob.waiting || newMeetingRequested ||
                recordingControlInFlight != nil || hasPendingTranscriptionWork
        }
        return quitting || recordingBusy
    }
    private func applySavedVoiceMatches(_ values:[SessionSpeakerKey:VoiceprintRecommendation],conflicts:Set<SessionSpeakerKey>,keys:[SessionSpeakerKey]) {
        var changed=false
        for key in keys {
            voiceprintCandidates[key]=values[key]
            changed=naming.reconcileAutoVoiceprint(key:key,candidate:values[key],conflictingEvidence:conflicts.contains(key)) || changed
        }
        if changed {persistSessionNames();markAllTranscriptParentsDirty();reloadLibraryAfterVoiceprintNameWrite()}
        for key in keys {refreshVoiceprintHeading(key)}
    }
    func scheduleSavedVoiceRecognition() {
        guard !quitting,savedVoiceRecognitionEligible(offline:Credential.offline,preview:previewRenderOnly,history:isHistoryReader,fixtureExecutor:savedVoiceRecognitionExecutorOverride != nil),
              [.paused,.stopped,.failed].contains(phase.phase),!sessionLocalOnly,
              !isHistoryReader || !voiceprintManagementOwner.savedVoiceRecognitionBlocksHistory,
              let cache=currentCacheID,UUID(uuidString:cache) != nil,let session=activeSession else{return}
        guard !resumeBusy,recordingControlInFlight != "resume",
              isHistoryReader || (!processingAudio && !hasPendingTranscriptionWork) else{return}
        // Revisit the reader when capture pauses / finishes draining. Merely
        // opening it during capture must not leave it permanently unprocessed.
        if !isHistoryReader {historyReader?.scheduleSavedVoiceRecognition()}
        let owner=voiceprintManagementOwner
        if owner.voiceprintService==nil {owner.configureVoiceprintRecommendations()}
        guard let service=owner.voiceprintService else{return}
        let continuousLearning=VoiceprintLearningPolicy().isEnabled
        let keys=Array(naming.choices(session:session).filter{(naming.name(speaker:$0)==nil && !naming.autoNameIsSuppressed($0)) || (continuousLearning && naming.name(speaker:$0) != nil)}.sorted{
            [$0.source,$0.epoch,$0.identity].joined() < [$1.source,$1.epoch,$1.identity].joined()
        }.prefix(32))
        guard !keys.isEmpty else{return}
        let job=savedVoiceRecognitionJob,token=job.reserve(),generation=meetingDocumentGeneration,revision=naming.correctionRevision
        let request=SavedVoiceRecognitionRequest(folder:recoveryBase().appendingPathComponent(cache).path,session:session,inputKind:Credential.offline ? "synthetic_model_output":"consented_live_audio",keys:keys,sampleLimit:24)
        service.profiles { [weak self] archive,error in
            guard let self,job.isCurrent(token),self.activeSession==session,self.currentCacheID==cache else{return}
            owner.voiceprintSuggestionArchive=archive
            self.naming.validateVoiceprintArchive(archive)
            self.markAllTranscriptParentsDirty()
            let hasManualLabels=continuousLearning && keys.contains{key in self.naming.segmentIDs(for:key).contains{self.naming.name(segment:$0) != nil}}
            guard (archive.map{!$0.people.isEmpty} ?? false) || hasManualLabels else{job.cancel();if let error {self.voiceprintStatus=error};return}
            self.voiceprintStatus="正在本机识别已保存的声音…";self.refreshOpenSpeakerReview()
            let completed:(UUID,Result<Data,Error>)->Void = { [weak self] returned,value in
                guard let self else{return}
                self.cacheWriteQueue.async {
                    guard job.isCurrent(returned) else{return}
                    do {
                        let result=try JSONDecoder().decode(SavedVoiceRecognitionResult.self,from:value.get())
                        try SavedVoiceRecognition.validate(result,request:request)
                        guard job.isCurrent(returned) else{return}
                        service.recognizeSaved(result) { [weak self] values,conflicts in
                            guard let self,job.isCurrent(returned),!self.quitting,
                                  self.activeSession==session,self.currentCacheID==cache,self.meetingDocumentGeneration==generation,
                                  self.naming.correctionRevision==revision,[.paused,.stopped,.failed].contains(self.phase.phase) else{return}
                            self.applySavedVoiceMatches(values,conflicts:conflicts,keys:keys)
                            self.voiceprintStatus=values.isEmpty ? (result.skipped>0 ? "部分声音证据不可用，暂未识别出已有姓名。":"暂未识别出已有姓名，可确认后记住声音。"):
                                "已识别有把握的发言；其余发言可按需确认。"
                            self.refreshOpenSpeakerReview()
                            if continuousLearning {
                                let writes=self.cacheWriteQueue,enrollmentRevision=self.naming.correctionRevision
                                service.learnSaved(result:result,folder:URL(fileURLWithPath:request.folder),job:job,token:returned,commitGate:{replace in try writes.sync(execute:replace)}) { [weak self] outcome in
                                    guard let self,job.isCurrent(returned),self.activeSession==session,self.currentCacheID==cache,
                                          self.meetingDocumentGeneration==generation,self.naming.correctionRevision==enrollmentRevision else{return}
                                    switch outcome {
                                    case .success(let rows):
                                        let statuses=rows.compactMap{$0["status"] as? String}
                                        if !statuses.isEmpty && statuses.allSatisfy({$0=="rejected" || $0=="session_capacity"}) {
                                            self.voiceprintStatus="姓名已保存；声音记忆未更新，请重新打开录音重试。"
                                        }
                                        // A bank revision invalidates restored per-span metadata.
                                        // Re-score the already extracted features, without reading audio again.
                                        if !rows.isEmpty {
                                            let rematchRevision=self.naming.correctionRevision
                                            service.recognizeSaved(result) { [weak self] updated,updatedConflicts in
                                                guard let self,job.isCurrent(returned),self.activeSession==session,self.currentCacheID==cache,
                                                      self.meetingDocumentGeneration==generation,self.naming.correctionRevision==rematchRevision,
                                                      [.paused,.stopped,.failed].contains(self.phase.phase) else{return}
                                                self.applySavedVoiceMatches(updated,conflicts:updatedConflicts,keys:keys)
                                                self.refreshOpenSpeakerReview()
                                            }
                                        }
                                    case .failure:
                                        self.voiceprintStatus="姓名已保存；声音记忆未更新，请重新打开录音重试。"
                                    }
                                    self.refreshOpenSpeakerReview()
                                }
                            }
                        }
                    }catch {
                        DispatchQueue.main.async { [weak self] in
                            guard let self,job.isCurrent(returned),self.activeSession==session,self.currentCacheID==cache else{return}
                            self.voiceprintStatus="本机声音识别暂未完成，可重新打开录音重试。";self.refreshOpenSpeakerReview()
                        }
                    }
                }
            }
            do {
                let object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(request)) as! [String:Any]
                if let injected=self.savedVoiceRecognitionExecutorOverride {injected(request,token,completed)}
                else {job.startProcess(request:object,executable:owner.captureExecutableURL,arguments:["--saved-voice-recognition",URL(fileURLWithPath:owner.root).appendingPathComponent("native/local-embedding-install/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx").path],maximumInput:65536,reservedToken:token,done:completed)}
            }catch{completed(token,.failure(error))}
        }
    }
}
