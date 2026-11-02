import Foundation

extension Delegate {
    func finalizeSessionTitle() {
        scheduleAutoTitle(finalized:true);titleProvider=nil;titleTextAllowed=false
    }
    // Every start path, new or continued, goes through one place: whoever may
    // transcribe this meeting may also title it. A stop clears it again.
    func adoptTitleProvider(key:String?) {
        titleProvider=(key?.isEmpty==false ? key:nil).flatMap{titleProviderMaker?($0)};titleTextAllowed=titleProvider != nil
    }
    // Offline builds never reach the real service unless a check injects one.
    private var titleProviderMaker:((String)->MeetingTitleProvider)? {
        if let titleProviderFactory {return titleProviderFactory}
        return Credential.offline ? nil:{DashScopeMeetingTitleProvider(apiKey:$0)}
    }
    // Titles lost to a crash, a quit or a failed final request come back here.
    // The secret is read only when something is owed, and never with a prompt.
    func reconcileOwedTitles(_ items:[CachedMeeting]) {
        guard !isHistoryReader,!quitting,!recordingBusy,owedTitleTask==nil else{return}
        let now=Date().timeIntervalSince1970
        guard now-owedTitleLastPass>=owedTitlePassInterval else{return}
        let injected=titleProviderFactory != nil
        guard let factory=titleProviderMaker,injected || authorized else{return}
        let candidates=items.filter{finalTitleTasks[$0.id]==nil}
        owedTitleLastPass=now
        let generator=autoTitle
        owedTitleTask=Task.detached { [weak self] in
            let owed=Array(candidates.filter{$0.owesTitle}.prefix(5))
            let secret:String?=owed.isEmpty ? nil:injected ? "synthetic":(try? Credential.load(allowInteraction:false))
            guard let key=secret,!key.isEmpty else{
                await MainActor.run {self?.owedTitleTask=nil}
                return
            }
            let provider=factory(key)
            pass: for item in owed {
                guard !Task.isCancelled else{break}
                guard let session=(try? item.metadata())?["session"] as? String,let events=try? item.events() else{continue}
                let result=await generator.generate(cacheID:item.id,session:session,directory:item.directory,events:events,provider:provider,cloudTextAllowed:true,finalized:true)
                switch result {
                case .saved(let title):await MainActor.run {self?.adoptOwedTitle(title,item:item,session:session)}
                case .unreachable:break pass
                default:continue
                }
            }
            await MainActor.run {self?.owedTitleTask=nil;self?.reloadLibrary()}
        }
    }
    private func adoptOwedTitle(_ title:String,item:CachedMeeting,session:String) {
        documentContextPublisher?.updateTitle(session:session,title:title)
        for document in [self,historyReader].compactMap({$0}) where document.currentCacheID==item.id && !document.recordingBusy {
            document.meetingTitle=title;document.meetingTitleField.stringValue=title;document.updateWorkspacePresentation()
        }
    }
    func invalidateAutoTitle() {
        // Finalization belongs to its saved session, not the next visible meeting.
        titleRevision &+= 1;titleTask?.cancel();titleTask=nil
    }
    func scheduleAutoTitle(finalized: Bool = false) {
        guard !quitting,!previewRenderOnly,!isHistoryReader,let id=currentCacheID,let session=activeSession else{return}
        let directory=recoveryBase().appendingPathComponent(id),generator=autoTitle
        let provider=titleProvider,allowed=titleTextAllowed && !sessionLocalOnly
        let publisher=documentContextPublisher
        guard allowed,provider != nil else{return}
        let recordingUpdate = !finalized && phase.phase == .recording
        if recordingUpdate {
            // Keep the provisional title stable during recording (and resume).
            // Pause-tail owns later calibration against the complete text.
            guard titleTask == nil else{return}
            let info=try? MeetingDisplayInfoStore.load(in:directory)
            if let info {
                if info.provenance == .manual || !info.title.isEmpty {return}
                if let last=info.attemptedAt,Date().timeIntervalSince1970-last<60 {return}
            }
            let finalEvents=sequence.compactMap{segments[$0]}.filter{$0["final"] as? Bool == true}
            guard MeetingTitleInput(events:finalEvents) != nil else{return}
        } else if let info=try? MeetingDisplayInfoStore.load(in:directory),info.provenance == .manual {
            return
        }
        if finalized,finalTitleTasks[id] != nil {return}
        // Each scheduled request gets its own completion token. Older work must
        // never clear the handle for a newer pause/final-title task.
        titleRevision &+= 1
        let revision=titleRevision
        // Take ownership of the pause request before a new meeting can cancel it.
        let pauseTask=(finalized || phase.phase == .paused) ? titleTask:nil
        if finalized || phase.phase == .paused {titleTask=nil}
        else {titleTask?.cancel();titleTask=nil}
        let refresh=phase.phase == .paused
        let task=Task.detached { [weak self] in
            if let pauseTask {await pauseTask.value}
            guard !Task.isCancelled else{return}
            guard let item=try? cachedMeetings(in:directory.deletingLastPathComponent()).first(where:{$0.id==id}),let events=try? item.events() else{
                await MainActor.run {
                    if finalized {self?.finalTitleTasks.removeValue(forKey:id)}
                    else if self?.titleRevision==revision {self?.titleTask=nil}
                }
                return
            }
            var result=await generator.generate(cacheID:id,session:session,directory:directory,events:events,provider:provider,cloudTextAllowed:allowed,finalized:finalized,refresh:refresh,finalOnly:recordingUpdate,requestRevision:revision)
            // One bounded final retry; no polling or unbounded provider loop.
            if finalized,case .failed=result,!Task.isCancelled {
                result=await generator.generate(cacheID:id,session:session,directory:directory,events:events,provider:provider,cloudTextAllowed:allowed,finalized:true,requestRevision:revision)
            }
            guard !Task.isCancelled else{return}
            await MainActor.run { [weak self] in
                guard let self else{return}
                if finalized {self.finalTitleTasks.removeValue(forKey:id)}
                let currentInfo=try? MeetingDisplayInfoStore.load(in:directory)
                if let currentInfo,currentInfo.provenance == .automatic,currentInfo.state == .ready,!currentInfo.title.isEmpty {
                    if !(self.currentCacheID==id && self.activeSession==session) || self.titleRevision==revision {publisher?.updateTitle(session:session,title:currentInfo.title)}
                    // Read the latest committed sidecar: a pause-tail request
                    // may have superseded this task while it was waiting.
                    if self.currentCacheID==id,self.activeSession==session,self.titleRevision==revision,
                       [.recording,.paused,.stopped,.ended,.failed].contains(self.phase.phase) {
                        self.meetingTitle=currentInfo.title;self.updateWorkspacePresentation();self.updateMeetingContext()
                    }
                }
                if !finalized,self.titleRevision==revision {self.titleTask=nil}
                if currentInfo?.provenance == .automatic,currentInfo?.state == .ready {self.reloadLibrary()}
            }
        }
        if finalized {finalTitleTasks[id]=task} else {titleTask=task}
    }
}
