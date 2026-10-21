import AppKit
import AVFoundation

// One transient editor reuses the document's naming and durable learning owner.
// Opening, searching, dismissing and model updates never confirm an identity.
final class SpeakerConfirmationController:NSObject,NSTextFieldDelegate,NSPopoverDelegate,AVAudioPlayerDelegate {
    weak var owner:Delegate?
    let popover=NSPopover()
    let field=NSTextField(string:"")
    let scope=NSButton(checkboxWithTitle:"",target:nil,action:nil)
    let learn=NSButton(checkboxWithTitle:"用于以后识别声音",target:nil,action:nil)
    private let environmentField=NSTextField(string:"")
    let status=NSTextField(wrappingLabelWithString:"")
    let confirm=NSButton(title:"确认",target:nil,action:nil)
    let candidates=NSStackView()
    private var service:SharedPersonIdentityService?
    private var searchWork:DispatchWorkItem?
    private var selectedPerson:SharedPersonReference?
    private var segmentIDs:[String]=[]
    private var groupIDs:[String]=[]
    private var groupScopeAllowed=false
    private var learningAllowed=true
    private var learningExplanation=""
    private var fingerprint:[String:String]=[:]
    private var session=""
    private var draftKey=""
    private var committed=false
    private var cancelDraft=false
    private var candidateValues:[SharedPersonCandidate]=[]
    private var readingPosition:Delegate.TranscriptReadingPosition?
    private var readingRevision=0
    private var documentGeneration=0
    private var openedSelection=NSRange(location:0,length:0)
    private var openedNames:[String:String]=[:]
    private var openedCache:String?
    private var quickCandidate:VoiceprintRecommendation?
    private var quickKey:SessionSpeakerKey?
    private var quickEditing=false
    private var quickSaveInFlight=false
    private let listen=NSButton(title:"试听",target:nil,action:nil)
    private let changeName=NSButton(title:"更正姓名…",target:nil,action:nil)
    private let reject=NSButton(title:"不是",target:nil,action:nil)
    private let previewJob=CacheReadJob()
    private var previewPlayer:AVAudioPlayer?
    private var previewRevision=0
    init(owner:Delegate) {self.owner=owner;super.init()}
    private func stamp(_ item:[String:Any])->String {
        let key=SessionSpeakerKey.from(item)
        let revision=String(item["revision"] as? Int ?? -1)
        let body=item["text"] as? String ?? ""
        let identity=key.map{[$0.session,$0.source,$0.epoch,$0.identity].joined(separator:"|")} ?? "unknown"
        return [revision,body,identity].joined(separator:"|")
    }
    func present(segment:String,anchor:NSView?=nil,showPopover:Bool=true) {
        guard let owner,let item=owner.namingItem(segment),let current=owner.activeSession else{return}
        session=current;openedCache=owner.currentCacheID;draftKey=current+"|"+segment
        readingPosition=owner.captureTranscriptReadingPosition()
        readingRevision=owner.transcriptReadingRestoreRevision;documentGeneration=owner.meetingDocumentGeneration;openedSelection=owner.output.selectedRange()
        let turn=owner.readingTurns().first{$0.id==segment || $0.parts.contains{$0.0==segment}}
        segmentIDs=turn?.parts.map(\.0) ?? [segment]
        if segmentIDs.isEmpty {segmentIDs=[segment]}
        for id in segmentIDs {if let item=owner.namingItem(id) {owner.naming.register(segment:id,item:item)}}
        if let key=owner.naming.key(segment:segment) {
            groupIDs=owner.naming.segmentIDs(for:key).filter{owner.namingItem($0) != nil}
        }
        for id in Set(segmentIDs+groupIDs) {if let value=owner.namingItem(id){fingerprint[id]=stamp(value);openedNames[id]=owner.naming.name(segment:id) ?? ""}}
        if let key=owner.naming.key(segment:segment),let candidate=owner.voiceprintRecommendation(for:key) {
            quickCandidate=candidate;quickKey=key
        }
        selectedPerson=owner.naming.personReference(segment:segment)
        field.stringValue=owner.confirmationDrafts[draftKey] ?? owner.naming.displayName(segment:segment)?.value ?? ""
        if let candidate=quickCandidate {field.stringValue=candidate.name}
        if field.stringValue != selectedPerson?.name {selectedPerson=nil}
        let root=MeetingDocumentView();root.translatesAutoresizingMaskIntoConstraints=false
        let title=NSTextField(labelWithString:quickCandidate.map{$0.name+"？"} ?? "这段是谁说的？");title.font = .systemFont(ofSize:quickCandidate==nil ? 14:18,weight:.semibold)
        title.lineBreakMode = .byTruncatingTail;title.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);title.widthAnchor.constraint(lessThanOrEqualToConstant:292).isActive=true
        field.placeholderString="输入姓名，或选择已有的人";field.delegate=self;field.setAccessibilityLabel("发言人姓名")
        field.target=self;field.action=#selector(commit)
        field.translatesAutoresizingMaskIntoConstraints=false;field.widthAnchor.constraint(equalToConstant:292).isActive=true
        candidates.orientation = .vertical;candidates.alignment = .leading;candidates.spacing=4
        scope.title="同时修改本场同组的 \(groupIDs.count) 段";scope.state = .off
        scope.isHidden=groupIDs.count<=segmentIDs.count || groupIDs.isEmpty
        let distinct=Set(groupIDs.compactMap{owner.naming.name(segment:$0)})
        groupScopeAllowed = distinct.count<=1
        scope.isEnabled=groupScopeAllowed
        if !groupScopeAllowed {scope.title="同组姓名不一致，请详细复核";scope.toolTip="这组已有不同人工姓名，请从详细复核逐段核对。"}
        let continuousLearningEnabled=VoiceprintLearningPolicy().isEnabled
        let evidenceEligible = segmentIDs.allSatisfy { id in
            guard let item=owner.namingItem(id) else{return false}
            let speaker=item["speaker"] as? [String:Any] ?? [:]
            return speaker["basis"] as? String != "multiple" && speaker["reason"] as? String != "overlap"
        }
        learningAllowed=evidenceEligible && continuousLearningEnabled
        if owner.isHistoryReader {
            learningAllowed = continuousLearningEnabled && !owner.voiceprintManagementOwner.recordingBusy && historySelectionEligible(segmentIDs)
            scope.target=self;scope.action=#selector(historyScopeChanged)
            learn.title="学习已保存声音，用于以后识别"
        }
        learn.isEnabled=learningAllowed
        learn.state=learningAllowed ? .on:.off
        learn.toolTip="仅本次确认片段，本机处理不上传；自动记录可用设备和来源，环境备注不证明身份。撤销姓名会撤回对应声音参考。"
        status.font = .systemFont(ofSize:12);status.textColor = .secondaryLabelColor
        learningExplanation=learningAllowed ? "":!continuousLearningEnabled ? "持续学习已关闭，请在“声音记忆”中开启；姓名仍可保存。":owner.isHistoryReader ? historyUnavailableReason():"这段包含不同声音，不用于学习。"
        if !learningAllowed {learn.toolTip=learningExplanation+"姓名仍可保存。"}
        status.stringValue=learningAllowed ? "仅修改当前这段，确认后保存在本机。":learningExplanation
        let more=NSButton(title:"详细复核…",target:self,action:#selector(openDetails));more.bezelStyle = .inline
        let undo=NSButton(title:"撤销上次",target:self,action:#selector(undo));undo.bezelStyle = .inline;undo.isEnabled=owner.naming.canUndo
        let buttons=NSStackView(views:[more,undo,confirm]);buttons.spacing=12;buttons.orientation = .horizontal
        confirm.target=self;confirm.action=#selector(commit);confirm.bezelStyle = .rounded
        let fields:[NSView]
        if let key=quickKey,quickCandidate != nil {
            let count=owner.readingTurns().filter{turn in turn.parts.contains{owner.naming.key(segment:$0.0)==key}}.count
            let hint=NSTextField(wrappingLabelWithString:"本场「"+owner.naming.displayLabel(speaker:key)+"」的 \(count) 轮发言");hint.font = .systemFont(ofSize:12);hint.textColor = .secondaryLabelColor
            field.isHidden=true;scope.isHidden=true;learn.isHidden=true;learn.state = .off
            // A prefilled hidden text field must not submit its target/action
            // when AppKit transfers focus during the popover's layout change.
            field.target=nil;field.action=nil
            environmentField.isHidden=true;candidates.isHidden=true
            status.stringValue="";status.isHidden=true
            listen.target=self;listen.action=#selector(listenQuickVoice);listen.bezelStyle = .inline;listen.controlSize = .small;listen.image=NSImage(systemSymbolName:"play.fill",accessibilityDescription:nil);listen.imagePosition = .imageLeading;listen.toolTip="播放一小段匹配到的声音";listen.isEnabled = !owner.voiceprintManagementOwner.recordingBusy
            changeName.target=self;changeName.action=#selector(editQuickName);changeName.bezelStyle = .inline;changeName.controlSize = .small
            reject.target=self;reject.action=#selector(rejectQuickVoice);reject.bezelStyle = .inline
            more.title="详细查看…";undo.isHidden=true
            let accessories=NSStackView(views:[listen,changeName,more]);accessories.spacing=12
            let spacer=NSView();spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
            let actions=NSStackView(views:[reject,spacer,confirm]);actions.spacing=12
            fields=[title,hint,field,status,accessories,actions]
            for row in [hint,accessories,actions] {row.translatesAutoresizingMaskIntoConstraints=false;row.widthAnchor.constraint(equalToConstant:292).isActive=true}
        }else {fields=[title,field,candidates,scope,learn,status,buttons]}
        let column=NSStackView(views:fields);column.orientation = .vertical;column.alignment = .leading;column.spacing=12;column.translatesAutoresizingMaskIntoConstraints=false
        root.addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:16),column.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-16),column.topAnchor.constraint(equalTo:root.topAnchor,constant:16),column.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-16),status.widthAnchor.constraint(equalTo:field.widthAnchor)])
        let vc=NSViewController();vc.view=root;popover.contentViewController=vc;popover.behavior = .transient;popover.delegate=self
        root.layoutSubtreeIfNeeded();popover.contentSize=NSSize(width:324,height:root.fittingSize.height)
        if showPopover && !owner.documentIsPreview {
            if let anchor {popover.show(relativeTo:anchor.bounds,of:anchor,preferredEdge:.maxY)}
            else if let range=owner.incrementalTranscript.range(forTurn:segment) ?? owner.incrementalTranscript.range(forPart:segment) {
                let rect=owner.output.firstRect(forCharacterRange:NSRange(location:range.location,length:1),actualRange:nil)
                let local=owner.output.convert(owner.window.convertFromScreen(rect),from:nil)
                popover.show(relativeTo:local,of:owner.output,preferredEdge:.maxY)
                popover.contentViewController?.view.window?.makeFirstResponder(field)
            }
            if quickCandidate==nil {service=SharedPersonIdentityService(root:owner.root);search()}
        }
        refreshValidity()
        _ = item
    }
    private func historySelectionEligible(_ ids:[String])->Bool {
        guard let owner else{return false}
        let items=ids.compactMap{owner.namingItem($0)}
        return items.count==ids.count && historicalVoiceClearSelection(items,session:session)
    }
    private func historyUnavailableReason()->String {
        if owner?.voiceprintManagementOwner.recordingBusy==true {return "当前录音或收尾处理中，暂不能学习历史原音。"}
        return "所选内容尚无足够清晰的单人证据，暂不学习声音。"
    }
    @objc private func historyScopeChanged() {
        guard let owner,owner.isHistoryReader else{return}
        let ids=scope.state == .on && groupScopeAllowed && scope.isEnabled && !scope.isHidden ? groupIDs:segmentIDs
        learningAllowed = !owner.voiceprintManagementOwner.recordingBusy && historySelectionEligible(ids)
        learn.isEnabled=learningAllowed
        if !learningAllowed {learn.state = .off}
        learningExplanation=learningAllowed ? "":historyUnavailableReason()
        learn.toolTip=learningAllowed ? "仅本次确认片段，本机处理不上传；环境备注不证明身份。撤销姓名会撤回对应声音参考。":learningExplanation+"姓名仍可保存。"
        status.stringValue=learningAllowed ? "仅学习本次明确勾选的片段。":learningExplanation
    }
    func controlTextDidChange(_ obj:Notification) {selectedPerson=nil;refreshValidity();if quickCandidate==nil {search()}}
    func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector)->Bool {
        if commandSelector==#selector(NSResponder.insertNewline(_:)) {if textView.hasMarkedText(){return false};commit();return true}
        if commandSelector==#selector(NSResponder.cancelOperation(_:)) {cancelDraft=true;popover.close();return true}
        return false
    }
    private func refreshValidity() {
        let value=field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        confirm.isEnabled = !value.isEmpty && value.count<=80 && !value.unicodeScalars.contains{CharacterSet.controlCharacters.contains($0)}
    }
    private func showQuickStatus(_ message:String) {
        status.stringValue=message;status.isHidden=message.isEmpty
        resizePopover()
    }
    private func resizePopover() {
        guard let view=popover.contentViewController?.view else{return}
        view.layoutSubtreeIfNeeded();popover.contentSize=NSSize(width:324,height:view.fittingSize.height)
    }
    private var currentQuickContext:Bool {
        guard let owner else{return false}
        if let workspace=owner.workspaceOwner,workspace.displayedDocument !== owner {return false}
        return owner.activeSession==session && owner.currentCacheID==openedCache && owner.meetingDocumentGeneration==documentGeneration && !(owner.workspaceOwner ?? owner).meetingDeletionBusy
    }
    var pendingQuickName:String? {quickSaveInFlight && currentQuickContext ? quickCandidate?.name:nil}
    @objc func editQuickName() {
        guard quickCandidate != nil else{return}
        if let draft=owner?.confirmationDrafts[draftKey],!draft.isEmpty {field.stringValue=draft;refreshValidity()}
        quickEditing=true;field.isHidden=false;field.placeholderString="输入正确姓名";confirm.title="保存";changeName.isHidden=true
        resizePopover()
        DispatchQueue.main.async { [weak self] in
            guard let self,self.popover.isShown,self.currentQuickContext else{return}
            self.popover.contentViewController?.view.window?.makeFirstResponder(self.field)
            self.field.currentEditor()?.selectAll(nil)
        }
    }
    @objc func rejectQuickVoice() {
        guard currentQuickContext,let owner,let key=quickKey,let candidate=quickCandidate,owner.voiceprintRecommendation(for:key)==candidate else{return}
        let previous=owner.naming
        guard owner.naming.dismissAutoName(key) else{return}
        let revision=owner.naming.correctionRevision
        quickSaveInFlight=true;confirm.isEnabled=false;reject.isEnabled=false;changeName.isEnabled=false;stopQuickPreview();owner.refreshQuickVoiceCandidate()
        owner.persistSessionNames { [weak self,weak owner] result in
            guard let self,let owner else{return};self.quickSaveInFlight=false
            guard self.currentQuickContext else{return}
            switch result {
            case .success:
                self.committed=true;owner.voiceprintCandidates.removeValue(forKey:key);owner.voiceprintManagementOwner.voiceprintService?.dismiss(key)
                self.popover.close();owner.showTransientFeedback("已移除候选")
            case .failure:
                if owner.naming.correctionRevision==revision {owner.naming=previous}
                self.refreshValidity();self.reject.isEnabled=true;self.changeName.isEnabled=true;self.showQuickStatus("未保存，请重试。")
            }
            owner.markAllTranscriptParentsDirty();owner.refreshOpenSpeakerReview();owner.reloadLibraryAfterVoiceprintNameWrite()
        }
    }
    private func stopQuickPreview() {
        previewRevision &+= 1;previewJob.cancel();previewPlayer?.stop();previewPlayer=nil;listen.title="试听"
        listen.isEnabled = owner?.voiceprintManagementOwner.recordingBusy != true
    }
    func cancelQuickInteraction() {stopQuickPreview();if quickCandidate != nil {popover.close()}}
    @objc private func listenQuickVoice() {
        if previewPlayer != nil || previewJob.waiting {stopQuickPreview();return}
        guard currentQuickContext,let owner,!owner.voiceprintManagementOwner.recordingBusy,let cache=openedCache,
              let candidate=quickCandidate,let key=quickKey,owner.voiceprintRecommendation(for:key)==candidate,
              let id=candidate.support.first(where:{owner.namingItem($0.id) != nil})?.id,var item=owner.namingItem(id),
              let start=item["start"] as? Double,let end=item["end"] as? Double else{return}
        item["end"]=min(end,start+6)
        let root=owner.recoveryBase(),savedSession=session,revision=previewRevision
        listen.title="读取中…";listen.isEnabled=false
        previewJob.run(work:{try SpeakerAudioPreview.read(root:root,cacheID:cache,session:savedSession,items:[item])}) { [weak self] result in
            guard let self,self.currentQuickContext,self.popover.isShown,self.previewRevision==revision,self.owner?.voiceprintManagementOwner.recordingBusy != true else{return}
            do {
                let clip=try result.get(),player=try AVAudioPlayer(data:SpeakerAudioPreview.listeningData(clip.wav));player.delegate=self
                guard player.prepareToPlay(),player.play() else{throw Failure(code:"quick_voice_play_failed")}
                self.previewPlayer=player;self.listen.title="停止";self.listen.isEnabled=true
            }catch{self.stopQuickPreview();self.showQuickStatus("原音暂时无法试听，可详细查看。")}
        }
    }
    func audioPlayerDidFinishPlaying(_ player:AVAudioPlayer,successfully flag:Bool) {stopQuickPreview()}
    func audioPlayerDecodeErrorDidOccur(_ player:AVAudioPlayer,error:Error?) {stopQuickPreview();showQuickStatus("试听未完成，可详细查看。")}
    private func search() {
        searchWork?.cancel();service?.cancel()
        let query=field.stringValue
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            showCandidates([]);showQueryStatus("输入姓名，或选择已有的人。");return
        }
        let work=DispatchWorkItem { [weak self] in self?.service?.search(query:query) { [weak self] result in
            guard let self,self.field.stringValue==query,!self.committed else{return}
            switch result {
            case .success(let values):self.showCandidates(Array(values.prefix(3)));if values.isEmpty {self.showQueryStatus("未找到已有的人；也可以只保存本场姓名。")}
            case .failure:self.showCandidates([]);self.showQueryStatus("已有人员暂时无法查询；仍可保存本场姓名。")
            }
        }}
        searchWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:work)
    }
    private func showQueryStatus(_ message:String) {
        status.stringValue=message+(learningExplanation.isEmpty ? "":"\n"+learningExplanation)
        if let view=popover.contentViewController?.view {view.layoutSubtreeIfNeeded();popover.contentSize=NSSize(width:324,height:view.fittingSize.height)}
    }
    func showCandidates(_ values:[SharedPersonCandidate]) {
        candidateValues=values
        for view in candidates.arrangedSubviews {candidates.removeArrangedSubview(view);view.removeFromSuperview()}
        for (index,value) in values.enumerated() {
            let detail=value.organization.isEmpty ? value.role:value.organization
            let button=NSButton(title:value.reference.name+(detail.isEmpty ? "":" · "+String(detail.prefix(24))),target:self,action:#selector(choose))
            button.tag=index;button.bezelStyle = .rounded;button.controlSize = .regular
            button.lineBreakMode = .byTruncatingTail
            button.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
            button.widthAnchor.constraint(lessThanOrEqualToConstant:292).isActive=true
            button.toolTip=button.title
            button.setAccessibilityLabel("选择已有人员："+button.title)
            candidates.addArrangedSubview(button)
        }
        popover.contentViewController?.view.layoutSubtreeIfNeeded()
        if let view=popover.contentViewController?.view {popover.contentSize=NSSize(width:324,height:view.fittingSize.height)}
    }
    @objc private func choose(_ sender:NSButton) {
        guard candidateValues.indices.contains(sender.tag) else{return}
        let value=candidateValues[sender.tag];selectedPerson=value.reference;field.stringValue=value.reference.name
        showQueryStatus("已选择已有人员，点击确认保存。");refreshValidity()
    }
    func setMemoryStatus(_ message:String) {if committed {status.stringValue=message}}
    @objc func commit() {
        guard let owner,confirm.isEnabled,owner.activeSession==session,owner.currentCacheID==openedCache,owner.meetingDocumentGeneration==documentGeneration else{return}
        guard quickCandidate==nil || currentQuickContext else{return}
        if let editor=field.currentEditor() as? NSTextView,editor.hasMarkedText(){return}
        let ids=quickCandidate != nil ? groupIDs:(scope.state == .on && groupScopeAllowed && scope.isEnabled && !scope.isHidden ? groupIDs:segmentIDs)
        if let candidate=quickCandidate,let key=quickKey {
            guard owner.voiceprintRecommendation(for:key)==candidate,!ids.isEmpty,groupScopeAllowed else{showQuickStatus("候选已变化，请重新打开。");confirm.isEnabled=false;return}
        }
        guard ids.allSatisfy({id in (owner.naming.name(segment:id) ?? "")==openedNames[id] && (owner.namingItem(id).map{stamp($0)==fingerprint[id]} ?? false)}) else{showQuickStatus("这段内容已更新，请重新打开确认。");confirm.isEnabled=false;return}
        if owner.isHistoryReader && quickCandidate==nil {historyScopeChanged()}
        let name=field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        let previous=owner.naming
        let continuousLearningEnabled=VoiceprintLearningPolicy().isEnabled
        if let key=quickKey {
            guard !owner.naming.values.contains(where:{owner.naming.key(segment:$0.key)==key && $0.value != name}),owner.naming.renameSpeaker(key:key,name:name) else{showQuickStatus("这组已有人工姓名，请详细查看。");return}
            if let candidate=quickCandidate,continuousLearningEnabled {
                let learningIDs=candidate.groupConsistent ? groupIDs : candidate.support.map(\.id).filter{groupIDs.contains($0)}
                owner.naming.attachConfirmation(segmentIDs:learningIDs,name:name,learn:true)
            }
            owner.cancelPendingVoiceprintMemory()
        }else {guard owner.naming.confirmSegments(ids,name:name,person:selectedPerson,learn:continuousLearningEnabled && learningAllowed && learn.state == .on) else{return}}
        let revision=owner.naming.correctionRevision
        let savedSession=session,savedDraftKey=draftKey,savedCache=owner.currentCacheID,savedGeneration=owner.meetingDocumentGeneration
        quickSaveInFlight=quickCandidate != nil;confirm.isEnabled=false;field.isEnabled=false;scope.isEnabled=false;learn.isEnabled=false;reject.isEnabled=false;changeName.isEnabled=false;showQuickStatus("正在保存…");stopQuickPreview();owner.refreshQuickVoiceCandidate()
        owner.persistSessionNames { [weak self,weak owner] result in
            self?.quickSaveInFlight=false
            guard let owner,owner.activeSession==savedSession,owner.currentCacheID==savedCache,owner.meetingDocumentGeneration==savedGeneration else{return}
            switch result {
            case .success:
                self?.committed=true;owner.confirmationDrafts.removeValue(forKey:savedDraftKey)
                if let key=self?.quickKey {owner.voiceprintCandidates.removeValue(forKey:key)}
                if self?.quickCandidate != nil,let cache=savedCache,owner.naming.correctionRevision==revision {owner.quickVoiceUndoScope=(savedSession,cache,savedGeneration,revision)}
                self?.popover.close();owner.showTransientFeedback(self?.quickCandidate==nil ? "姓名已保存":name+" · 已确认",nameUndo:true);owner.refreshOpenSpeakerReview();owner.reloadLibraryAfterVoiceprintNameWrite()
            case .failure:
                if owner.naming.correctionRevision==revision {owner.naming=previous;owner.markAllTranscriptParentsDirty()}
                self?.field.isEnabled=true;self?.learn.isEnabled=self?.learningAllowed ?? false;self?.scope.isEnabled=self?.groupScopeAllowed ?? false;self?.reject.isEnabled=true;self?.changeName.isEnabled=true;self?.refreshValidity();self?.showQuickStatus("姓名未保存，请重试。");owner.refreshOpenSpeakerReview()
                owner.showTransientFeedback("姓名未保存，请点姓名重试")
            }
        }
        owner.markAllTranscriptParentsDirty()
    }
    @objc private func undo() {owner?.undoName();popover.close()}
    @objc private func openDetails() {popover.close();owner?.openSpeakerReview(for:segmentIDs.first.flatMap{owner?.naming.key(segment:$0)})}
    func popoverDidClose(_ notification:Notification) {
        stopQuickPreview()
        searchWork?.cancel();service?.cancel()
        guard let owner else{return}
        if cancelDraft {owner.confirmationDrafts.removeValue(forKey:draftKey)}
        else if !committed {owner.confirmationDrafts[draftKey]=field.stringValue}
        // A dismissal must not override navigation made while the editor was open.
        // Transcript rendering already preserves its own live anchor; its changed
        // revision also makes the old popover anchor obsolete.
        if let position=readingPosition,owner.activeSession==session,
           owner.meetingDocumentGeneration==documentGeneration,
           owner.transcriptReadingRestoreRevision==readingRevision,
           owner.output.selectedRange()==openedSelection {
            owner.restoreTranscriptReadingPosition(position)
        }
    }
}

extension Delegate {
    // The existing name undo stack remains the authority. This receipt only
    // makes the lightweight confirmation's visible undo wait for its save.
    func undoQuickVoiceConfirmationIfAvailable()->Bool {
        if quickVoiceUndoPending {return true}
        guard let scope=quickVoiceUndoScope else{return false}
        guard activeSession==scope.session,currentCacheID==scope.cache,meetingDocumentGeneration==scope.generation,naming.correctionRevision==scope.revision else{quickVoiceUndoScope=nil;return false}
        let previous=naming
        guard naming.undo() != nil else{quickVoiceUndoScope=nil;return false}
        let revision=naming.correctionRevision
        quickVoiceUndoScope=nil;quickVoiceUndoPending=true;cancelPendingVoiceprintMemory()
        persistSessionNames { [weak self] result in
            guard let self else{return};self.quickVoiceUndoPending=false
            guard self.activeSession==scope.session,self.currentCacheID==scope.cache,self.meetingDocumentGeneration==scope.generation else{return}
            switch result {
            case .success:self.showTransientFeedback("已撤销姓名确认")
            case .failure:
                if self.naming.correctionRevision==revision {self.naming=previous;self.quickVoiceUndoScope=scope}
                self.showTransientFeedback("撤销未保存，请重试",nameUndo:true)
            }
            self.markAllTranscriptParentsDirty();self.refreshOpenSpeakerReview();self.reloadLibraryAfterVoiceprintNameWrite()
        }
        markAllTranscriptParentsDirty();return true
    }
    func quickVoiceChoice()->(SessionSpeakerKey,VoiceprintRecommendation)? {
        guard let session=activeSession else{return nil}
        for key in naming.choices(session:session) {
            if let candidate=voiceprintRecommendation(for:key),candidate.recognizedSupport==nil,naming.displayName(speaker:key)?.origin != .voiceprint,!naming.values.contains(where:{naming.key(segment:$0.key)==key && $0.value != candidate.name}) {return (key,candidate)}
        }
        return nil
    }
    func refreshQuickVoiceCandidate() {
        guard let button=voiceCandidateButton else{return}
        if let name=confirmationController?.pendingQuickName {button.title=name+"？";button.isHidden=false;button.isEnabled=false;return}
        button.isEnabled=true
        guard let (_,candidate)=quickVoiceChoice() else{button.isHidden=true;return}
        button.title=candidate.name+"？";button.toolTip="确认或更正这组发言的姓名";button.setAccessibilityLabel("确认声音候选："+candidate.name);button.isHidden=false
    }
    @objc func showQuickVoiceConfirmation() {
        guard !(workspaceOwner ?? self).meetingDeletionBusy,let (key,candidate)=quickVoiceChoice(),
              let id=candidate.support.first(where:{namingItem($0.id) != nil})?.id ?? naming.segmentIDs(for:key).first,
              let anchor=voiceCandidateButton else{return}
        confirmationController?.popover.close()
        let controller=SpeakerConfirmationController(owner:self);confirmationController=controller;controller.present(segment:id,anchor:anchor)
    }
    func showSpeakerConfirmation(_ segment:String) {
        guard !(workspaceOwner ?? self).meetingDeletionBusy else{return}
        confirmationController?.popover.close()
        let controller=SpeakerConfirmationController(owner:self);confirmationController=controller;controller.present(segment:segment)
    }
}
