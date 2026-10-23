import AppKit

final class MeetingDocumentView:NSView {
    override var isOpaque:Bool {true}
    override func draw(_ dirtyRect:NSRect){MeetingVisualStyle.surface.setFill();NSBezierPath(rect:bounds.intersection(dirtyRect)).fill()}
}

final class MeetingSidebarSurface:NSView {
    override var isOpaque:Bool {true}
    override func draw(_ dirtyRect:NSRect){MeetingVisualStyle.sidebar.setFill();NSBezierPath(rect:bounds.intersection(dirtyRect)).fill();MeetingVisualStyle.border.setFill();NSBezierPath(rect:NSRect(x:bounds.maxX-1,y:0,width:1,height:bounds.height)).fill()}
}

// Populate the dynamic menu before presentation; an empty NSView menu is not
// reliably opened by forwarding rightMouseDown alone. Derive its row from the
// original event, never from selection or the global mouse position.
final class MeetingLibraryTableView:NSTableView {
    private var contextRow:Int?
    var contextMenuPresenter:((NSMenu,NSEvent,NSView)->Void)?
    override var clickedRow:Int {contextRow ?? super.clickedRow}
    override func menu(for event:NSEvent)->NSMenu? {
        contextRow=row(at:convert(event.locationInWindow,from:nil))
        guard let menu=menu else{return nil}
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu
    }
    override func rightMouseDown(with event:NSEvent) {
        defer{contextRow=nil}
        guard let menu=menu(for:event),!menu.items.isEmpty else{return}
        if let present=contextMenuPresenter {present(menu,event,self)}
        else {NSMenu.popUpContextMenu(menu,with:event,for:self)}
    }
    override func mouseDown(with event:NSEvent) {
        if event.modifierFlags.contains(.control) {rightMouseDown(with:event);return}
        contextRow=nil;super.mouseDown(with:event)
    }
}

// Row text is display-only: the table owns selection and context-menu targeting.
// Keep participant tracking areas on their original view for hover animation.
final class MeetingLibraryCellView:NSTableCellView {
    weak var libraryTable:NSTableView?
    override func menu(for event:NSEvent)->NSMenu? {libraryTable?.menu(for:event)}
    override func hitTest(_ point:NSPoint)->NSView? {
        guard let hit=super.hitTest(point) else{return nil}
        return hit === self || hit.isDescendant(of:self) ? self:hit
    }
    override func mouseDown(with event:NSEvent) {
        if let table=libraryTable {table.mouseDown(with:event)}else{super.mouseDown(with:event)}
    }
    override func rightMouseDown(with event:NSEvent) {
        if let table=libraryTable {table.rightMouseDown(with:event)}else{super.rightMouseDown(with:event)}
    }
}

final class MeetingTranscriptScroll:NSScrollView {
    var manualScroll:(()->Void)?
    private var liveScrollObserver:NSObjectProtocol?
    override init(frame:NSRect) {super.init(frame:frame);observeLiveScroll()}
    required init?(coder:NSCoder) {super.init(coder:coder);observeLiveScroll()}
    private func observeLiveScroll() {liveScrollObserver=NotificationCenter.default.addObserver(forName:NSScrollView.willStartLiveScrollNotification,object:self,queue:.main) { [weak self] _ in self?.manualScroll?() }}
    deinit {if let token=liveScrollObserver {NotificationCenter.default.removeObserver(token)}}
    override func scrollWheel(with event:NSEvent) {manualScroll?();super.scrollWheel(with:event)}
}
final class MeetingTranscriptTextView:NSTextView {
    var manualNavigation:(()->Void)?
    override func mouseDown(with event:NSEvent) {manualNavigation?();super.mouseDown(with:event)}
    override func keyDown(with event:NSEvent) {manualNavigation?();super.keyDown(with:event)}
}

// The recording delegate owns capture. A separate document delegate renders a
// historical meeting, so browsing never replaces the live timeline or cursors.
extension Delegate {
    var recordingBusy:Bool {child != nil || [.connecting,.recording,.paused,.stopping].contains(phase.phase) || preparingModels || processingAudio || resumeBusy || credentialReadJob.waiting || newMeetingRequested}
    /// A stopped meeting can still be transcribing saved audio, and a paused
    /// capture can still be draining its already-recorded tail.
    var hasPendingTranscriptionWork:Bool {
        if phase.phase == .stopping {
            return resumeBusy && processingAudio && currentCacheID != nil
        }
        return phase.phase == .paused && pausedTailStates.values.contains("processing")
    }
    func shouldRefineAfterStopped(session:String?,reason:String,transcriptionComplete:Bool,
                                  localOnly:Bool,recoverySucceeded:Bool)->Bool {
        let userCancelled=suppressAutomaticRefinementAfterStop
        suppressAutomaticRefinementAfterStop=false
        guard !userCancelled else{return false}
        return speakerRefinementLifecycle.shouldRefineStopped(session:session,reason:reason,
            transcriptionComplete:transcriptionComplete,localOnly:localOnly,recoverySucceeded:recoverySucceeded)
    }
    var displayedDocument:Delegate {historyReader ?? self}
    // History uses preview initialization to avoid a second app/capture owner;
    // its visible document still follows the real workspace interaction mode.
    var documentIsPreview:Bool {(workspaceOwner ?? self).previewRenderOnly}
    func buildWorkspace() {
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.title="在场";window.minSize=NSSize(width:640,height:480);window.backgroundColor = MeetingVisualStyle.surface;window.titleVisibility = .hidden;window.titlebarAppearsTransparent=true;window.delegate=self
        let root=window.contentView!
        sidebar=NSView();sidebar.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(sidebar)
        sidebarWidth=sidebar.widthAnchor.constraint(equalToConstant:preferredSidebarWidth)
        documentHost=MeetingDocumentView();documentHost.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(documentHost)
        NSLayoutConstraint.activate([sidebar.leadingAnchor.constraint(equalTo:root.leadingAnchor),sidebar.topAnchor.constraint(equalTo:root.topAnchor),sidebar.bottomAnchor.constraint(equalTo:root.bottomAnchor),sidebarWidth,documentHost.leadingAnchor.constraint(equalTo:sidebar.trailingAnchor),documentHost.trailingAnchor.constraint(equalTo:root.trailingAnchor),documentHost.topAnchor.constraint(equalTo:root.topAnchor),documentHost.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
        let background=MeetingSidebarSurface();background.translatesAutoresizingMaskIntoConstraints=false;sidebar.addSubview(background);pin(background,to:sidebar)
        let column=stack(.vertical,spacing:10);column.alignment = .leading;column.distribution = .fill;column.translatesAutoresizingMaskIntoConstraints=false;sidebar.addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:14),column.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:-14),column.topAnchor.constraint(equalTo:sidebar.topAnchor,constant:14),column.bottomAnchor.constraint(equalTo:sidebar.bottomAnchor,constant:-14)])
        let new=ImmediateButton(title:"新对话",target:self,action:#selector(beginNewMeeting));new.bezelStyle = .rounded;new.controlSize = .regular;new.font = .systemFont(ofSize:12,weight:.medium);new.image=NSImage(systemSymbolName:"plus",accessibilityDescription:nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:13,weight:.medium));new.imagePosition = .imageLeading;new.heightAnchor.constraint(equalToConstant:32).isActive=true;new.setAccessibilityLabel("新对话");newButton=new;column.addArrangedSubview(new)
        librarySearch=NSSearchField();librarySearch.placeholderString="搜索会议";librarySearch.delegate=self;librarySearch.controlSize = .regular;librarySearch.focusRingType = .default;librarySearch.setAccessibilityLabel("搜索会议标题和原文");librarySearch.isHidden=true;column.addArrangedSubview(librarySearch)
        liveReturn=ImmediateButton(title:"返回当前记录",target:self,action:#selector(returnToCurrent));liveReturn.bezelStyle = .inline;column.addArrangedSubview(liveReturn)
        libraryStatus=label("会议记录",size:11,weight:.semibold);libraryStatus.textColor = MeetingVisualStyle.muted;libraryStatus.lineBreakMode = .byTruncatingTail
        libraryRetryButton=ImmediateButton(title:"重试",target:self,action:#selector(retryLibraryLoad));libraryRetryButton.bezelStyle = .inline;libraryRetryButton.controlSize = .small;libraryRetryButton.isHidden=true
        let libraryHeading=stack(.horizontal,spacing:4);libraryStatus.setContentHuggingPriority(.defaultLow,for:.horizontal);libraryHeading.addArrangedSubview(libraryStatus);libraryHeading.addArrangedSubview(libraryRetryButton);column.addArrangedSubview(libraryHeading)
        libraryTable=MeetingLibraryTableView();let tableColumn=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("meeting"));libraryTable.addTableColumn(tableColumn);libraryTable.headerView=nil;libraryTable.rowHeight=72;libraryTable.intercellSpacing=NSSize(width:0,height:2);libraryTable.backgroundColor = .clear;libraryTable.selectionHighlightStyle = .regular;libraryTable.delegate=self;libraryTable.dataSource=self;libraryTable.setAccessibilityLabel("会议列表");installLibraryContextMenu()
        let listScroll=NSScrollView();listScroll.documentView=libraryTable;listScroll.hasVerticalScroller=true;listScroll.autohidesScrollers=true;listScroll.drawsBackground=false;listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:80).isActive=true;column.addArrangedSubview(listScroll)
        let settings=ImmediateButton(title:"设置",target:self,action:#selector(showSettings));settings.bezelStyle = .inline;settings.image=NSImage(systemSymbolName:"gearshape",accessibilityDescription:nil);settings.imagePosition = .imageLeading;let utilities=stack(.horizontal,spacing:10);utilities.addArrangedSubview(makeLibraryRecycleButton());let utilitySpacer=NSView();utilitySpacer.setContentHuggingPriority(.defaultLow,for:.horizontal);utilities.addArrangedSubview(utilitySpacer);utilities.addArrangedSubview(settings);column.addArrangedSubview(utilities)
        for row in column.arrangedSubviews {row.widthAnchor.constraint(equalTo:column.widthAnchor).isActive=true}
        currentDocument=makeDocumentView();documentHost.addSubview(currentDocument);pin(currentDocument,to:documentHost)
        let divider=MeetingSidebarDivider();divider.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(divider);sidebarDivider=divider
        divider.widthProvider={ [weak self] in self?.sidebarWidth.constant ?? MeetingSidebarSizing.defaultWidth }
        divider.changeWidth={ [weak self] width,persist in self?.resizeSidebar(to:width,persist:persist) }
        NSLayoutConstraint.activate([divider.centerXAnchor.constraint(equalTo:sidebar.trailingAnchor),divider.widthAnchor.constraint(equalToConstant:8),divider.topAnchor.constraint(equalTo:root.topAnchor),divider.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
        let toolbar=NSToolbar(identifier:"meeting-workspace");toolbar.delegate=self;toolbar.displayMode = .iconOnly;window.toolbarStyle = .unified;window.toolbar=toolbar
        updateWorkspacePresentation()
    }
    func pin(_ child:NSView,to parent:NSView) {child.translatesAutoresizingMaskIntoConstraints=false;NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo:parent.leadingAnchor),child.trailingAnchor.constraint(equalTo:parent.trailingAnchor),child.topAnchor.constraint(equalTo:parent.topAnchor),child.bottomAnchor.constraint(equalTo:parent.bottomAnchor)])}
    func makeDocumentView()->NSView {
        let view=MeetingDocumentView();view.translatesAutoresizingMaskIntoConstraints=false
        let main=stack(.vertical,spacing:12);main.alignment = .leading;main.distribution = .fill;main.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(main)
        NSLayoutConstraint.activate([main.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:26),main.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-26),main.topAnchor.constraint(equalTo:view.topAnchor,constant:22),main.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-12)])
        let header=stack(.horizontal,spacing:16);header.alignment = .centerY;header.distribution = .fill
        let words=stack(.vertical,spacing:7);words.alignment = .leading;words.distribution = .fill;words.setContentHuggingPriority(.defaultLow,for:.horizontal)
        meetingTitleField=NSTextField();meetingTitleField.isBordered=false;meetingTitleField.drawsBackground=false;meetingTitleField.focusRingType = .none;meetingTitleField.font = .systemFont(ofSize:20,weight:.semibold);meetingTitleField.textColor=MeetingVisualStyle.ink;meetingTitleField.stringValue=meetingTitle;meetingTitleField.placeholderString="会议名称";meetingTitleField.delegate=self;meetingTitleField.lineBreakMode = .byTruncatingTail;meetingTitleField.setAccessibilityLabel("会议名称");words.addArrangedSubview(meetingTitleField)
        heading=label("准备就绪",size:12);heading.textColor = MeetingVisualStyle.muted;heading.lineBreakMode = .byTruncatingTail;heading.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);header.addArrangedSubview(words)
        action=RecordingPrimaryButton(title:"开始录音",target:self,action:#selector(primaryWorkspaceAction));action.bezelStyle = .rounded;action.controlSize = .large;action.isBordered=false;action.wantsLayer=true;action.layer?.cornerRadius=12;action.widthAnchor.constraint(equalToConstant:48).isActive=true;action.heightAnchor.constraint(equalToConstant:48).isActive=true;action.font = .systemFont(ofSize:14,weight:.semibold);action.setAccessibilityLabel("开始录音或继续录音");(action as? RecordingPrimaryButton)?.circularTransport=true
        main.addArrangedSubview(header)
        historyLiveButton=ImmediateButton(title:"返回当前记录",target:self,action:#selector(returnFromHistory));historyLiveButton.bezelStyle = .inline;historyLiveButton.lineBreakMode = .byTruncatingTail;historyLiveButton.isHidden=true;main.addArrangedSubview(historyLiveButton)
        let tools=stack(.horizontal,spacing:10);tools.distribution = .fill;tools.alignment = .centerY
        tools.addArrangedSubview(heading)
        let statusSpacer=NSView();statusSpacer.setContentHuggingPriority(.defaultLow,for:.horizontal);tools.addArrangedSubview(statusSpacer)
        tools.addArrangedSubview(makeTranslationControl())
        timelineToggle=ImmediateButton(checkboxWithTitle:"人物时间线",target:self,action:#selector(toggleSpeakerRanges));timelineToggle.controlSize = .small;timelineToggle.isHidden=true
        let peopleButton=ImmediateButton(title:"发言人",target:self,action:#selector(showSpeakerReview));speakerReviewButton=peopleButton;peopleButton.bezelStyle = .inline;peopleButton.font = .systemFont(ofSize:12);peopleButton.controlSize = .small;peopleButton.contentTintColor=MeetingVisualStyle.ink;peopleButton.image=NSImage(systemSymbolName:"person.2",accessibilityDescription:"按发言人查看与修改");peopleButton.imagePosition = .imageLeading;peopleButton.setAccessibilityLabel("按发言人查看与修改");tools.addArrangedSubview(peopleButton)
        let voice=ImmediateButton(title:"",target:self,action:#selector(showQuickVoiceConfirmation));voice.bezelStyle = .inline;voice.controlSize = .small;voice.contentTintColor=MeetingVisualStyle.muted;voice.isHidden=true;voice.lineBreakMode = .byTruncatingTail;voice.widthAnchor.constraint(lessThanOrEqualToConstant:180).isActive=true;voiceCandidateButton=voice;tools.addArrangedSubview(voice)
        let archive=makeMeetingArchiveButton();archive.controlSize = .small;archiveButton=archive
        latest=ImmediateButton(title:"回到最新",target:self,action:#selector(goLatest));latest.bezelStyle = .inline;latest.isHidden=true;tools.addArrangedSubview(latest);main.addArrangedSubview(tools)
        main.addArrangedSubview(makeRecordingDashboard())
        let doc=NSView();doc.translatesAutoresizingMaskIntoConstraints=false
        let transcriptScroll=MeetingTranscriptScroll();transcriptScroll.manualScroll={ [weak self] in self?.cancelTranscriptReadingRestore() };scroll=transcriptScroll;scroll.automaticallyAdjustsContentInsets=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=true;scroll.backgroundColor = MeetingVisualStyle.surface;scroll.findBarPosition = .aboveContent;doc.addSubview(scroll);pin(scroll,to:doc)
        let transcriptView=MeetingTranscriptTextView(frame:NSRect(x:0,y:0,width:700,height:400));transcriptView.manualNavigation={ [weak self] in self?.cancelTranscriptReadingRestore() };output=transcriptView;output.backgroundColor=MeetingVisualStyle.surface;output.textColor=MeetingVisualStyle.ink;output.isEditable=false;output.isSelectable=true;output.isRichText=true;output.delegate=self;output.isVerticallyResizable=true;output.isHorizontallyResizable=false;output.autoresizingMask=[.width];output.textContainerInset=NSSize(width:0,height:12);output.textContainer?.widthTracksTextView=true;output.textContainer?.containerSize=NSSize(width:700,height:CGFloat.greatestFiniteMagnitude);output.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude);output.usesFindBar=true;output.isIncrementalSearchingEnabled=true;output.linkTextAttributes=[.underlineStyle:0];output.setAccessibilityLabel("会议原文");scroll.documentView=output
        let emptyLabel=MeetingEmptyLabel(labelWithString:"开始录音，文字会显示在这里");empty=emptyLabel;empty.font = .systemFont(ofSize:13);empty.textColor=MeetingVisualStyle.muted;empty.maximumNumberOfLines=0;empty.lineBreakMode = .byWordWrapping;empty.alignment = .center;empty.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let mark=MeetingVoiceMark();emptyLabel.voiceMark=mark;mark.widthAnchor.constraint(equalToConstant:38).isActive=true;mark.heightAnchor.constraint(equalToConstant:38).isActive=true
        let emptyGroup=NSStackView(views:[mark,empty]);emptyGroup.orientation = .vertical;emptyGroup.alignment = .centerX;emptyGroup.spacing=10;emptyGroup.translatesAutoresizingMaskIntoConstraints=false;doc.addSubview(emptyGroup)
        NSLayoutConstraint.activate([emptyGroup.centerXAnchor.constraint(equalTo:doc.centerXAnchor),emptyGroup.centerYAnchor.constraint(equalTo:doc.centerYAnchor),emptyGroup.widthAnchor.constraint(lessThanOrEqualTo:doc.widthAnchor,constant:-24)])
        doc.heightAnchor.constraint(greaterThanOrEqualToConstant:80).isActive=true;main.addArrangedSubview(assistantEnabled ? doc : attachMeetingNotes(to:doc))
        main.addArrangedSubview(assistantEnabled ? makeRecordingTransport() : notesTransport(makeRecordingTransport()))
        // Waveform plots can shrink with the document; their preferred 180pt
        // widths must not enlarge the window's content beyond its visible frame.
        for level in [microphoneLevel,computerLevel].compactMap({$0}) {
            level.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
            level.widthAnchor.constraint(greaterThanOrEqualToConstant:assistantEnabled ? 30 : 96).isActive=true
        }
        let separator=NSBox();separator.boxType = .separator;separator.isHidden=true
        let footer=stack(.horizontal,spacing:10)
        diagnostic=label("",size:11);diagnostic.textColor = .secondaryLabelColor;diagnostic.lineBreakMode = .byTruncatingTail;diagnostic.maximumNumberOfLines=1;diagnostic.setContentHuggingPriority(.defaultLow,for:.horizontal);diagnostic.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);footer.addArrangedSubview(diagnostic)
        let translationStatus=label("",size:11);translationStatus.textColor=MeetingVisualStyle.muted;translationStatus.lineBreakMode = .byTruncatingTail;translationStatus.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);translationStatus.isHidden=true;translationStatusLabel=translationStatus;footer.addArrangedSubview(translationStatus)
        let undoFeedback=NSButton(title:"撤销",target:self,action:#selector(undoName));undoFeedback.bezelStyle = .inline;undoFeedback.isHidden=true;undoFeedback.setAccessibilityLabel("撤销上次发言人修改及对应声音学习");feedbackUndoButton=undoFeedback;footer.addArrangedSubview(undoFeedback)
        meter=label("",size:11);meter.textColor = .secondaryLabelColor;meter.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular);meter.isHidden=true
        footerDetails=ImmediateButton(title:"会议详情",target:self,action:#selector(showDetails));footerDetails.bezelStyle = .inline;footerDetails.isHidden=true;main.addArrangedSubview(footer)
        for row in main.arrangedSubviews {row.widthAnchor.constraint(equalTo:main.widthAnchor).isActive=true}
        // Detailed audio health stays available in Details without dominating reading.
        source=label("自动收录麦克风与电脑声音",size:12)
        return assistantEnabled ? attachMeetingAssistant(to:view) : view
    }
    func updateWorkspacePresentation() {
        guard documentHost != nil else{return}
        refreshMeetingNotes();agentController?.layout()
        if meetingTitleField.currentEditor()==nil {meetingTitleField.stringValue=meetingTitle}
        meetingTitleField.isEditable = !(workspaceOwner ?? self).meetingDeletionBusy && (currentCacheID != nil || !sequence.isEmpty)
        let owner=isHistoryReader ? (workspaceOwner ?? self):self
        let state=owner.phase.phase
        switch state {
        case .recording:action.title="暂停录音"
        case .paused:action.title="继续录音"
        case .connecting:action.title="取消启动"
        case .stopping:action.title="正在保存"
        case .failed:action.title=currentCacheID == nil ? "开始录音":"继续这场录音"
        default:action.title=currentCacheID == nil ? "开始录音":"继续这场录音"
        }
        action.isHidden=false
        action.isEnabled=owner.recordingControlInFlight==nil && state != .stopping && !owner.preparingModels && !owner.processingAudio && (!owner.credentialReadJob.busy || state == .connecting) && !owner.newMeetingRequested && !owner.meetingDeletionBusy && (owner.recordingBusy || !owner.audioAssetOperationBusy)
        if currentCacheID != nil && [.idle,.stopped,.failed,.ended].contains(state) {
            action.isEnabled = !owner.newMeetingRequested && !owner.meetingDeletionBusy && !owner.audioAssetOperationBusy
        }
        action.image=NSImage(systemSymbolName:state == .recording ? "pause.fill":state == .paused || currentCacheID != nil ? "play.fill":"record.circle.fill",accessibilityDescription:action.title)
        (action as? RecordingPrimaryButton)?.brandedRecordGlyph = currentCacheID == nil && ![.recording,.paused,.connecting,.stopping].contains(state)
        action.imagePosition = .imageLeading
        action.contentTintColor = .white;action.needsDisplay=true
        action.attributedTitle=NSAttributedString(string:action.title,attributes:[.font:NSFont.systemFont(ofSize:14,weight:.semibold),.foregroundColor:NSColor.white])
        action.setAccessibilityLabel(action.title)
        timelineToggle?.state=showsSpeakerRanges ? .on:.off
        if isHistoryReader {
            action.title="继续这场录音";action.isHidden=false
            action.isEnabled = !owner.newMeetingRequested && !owner.preparingModels && !owner.credentialReadJob.waiting && !owner.meetingDeletionBusy && !owner.audioAssetOperationBusy
            action.image=NSImage(systemSymbolName:"play.fill",accessibilityDescription:action.title)
            action.attributedTitle=NSAttributedString(string:action.title,attributes:[.font:NSFont.systemFont(ofSize:14,weight:.semibold),.foregroundColor:NSColor.white])
            action.setAccessibilityLabel(action.title)
            historyLiveButton.isHidden = !owner.recordingBusy
            historyLiveButton.title="返回录音 · "+owner.meetingTitle+" · "+owner.phase.time
            historyLiveButton.toolTip="返回正在录音的「"+owner.meetingTitle+"」"
            action.toolTip=owner.recordingBusy ? "先保存「"+owner.meetingTitle+"」，再继续这场会议录音":"继续这场会议录音"
        } else {
            newButton?.isEnabled = !newMeetingRequested && phase.phase != .connecting && !preparingModels && !credentialReadJob.waiting && !meetingDeletionBusy && !audioAssetOperationBusy
            newButton?.toolTip="保存当前对话并开始一场新对话"
            newButton?.title="新对话"
            historyButton?.isEnabled=true
            liveReturn.isHidden=true
            liveReturn.title="返回当前会议"
            exportButton?.isEnabled = !(displayedDocument.sequence.isEmpty && displayedDocument.recoveredArchiveText==nil && displayedDocument.currentCacheID==nil)
            exportButton?.toolTip="导出正在查看的已有文字，保持录音状态"
        }
        heading.font = .systemFont(ofSize:12,weight:.regular)
        if phase.error==nil {
            let stateText:[RecordingPhase:String]=[.idle:"",.recording:"录音中",.paused:"已暂停",.connecting:"正在连接",.stopping:"正在整理",.stopped:"已保存",.ended:"已保存",.failed:"已停止"]
            var status=stateText[phase.phase] ?? ""
            if phase.phase == .recording {if asrNetworkStates.values.contains("pending") {status="录音中 · 待补转写"}else if asrNetworkStates.values.contains("waiting") {status="录音中 · 等待网络"}else if asrNetworkStates.values.contains("catching") {status="录音中 · 补全转写"}}
            if phase.phase == .stopped,currentCacheID != nil,!cachedTranscriptionComplete {status="已保存 · 待转写"}
            heading.stringValue=status+(currentCacheID==nil ? "":" · "+phase.time)
        }
        translationSwitch?.isEnabled=currentCacheID != nil && !translationCredentialJob.busy
        speakerReviewButton?.isHidden=sequence.isEmpty;meter.isHidden=true;footerDetails.isHidden=true
        refreshQuickVoiceCandidate()
        refreshMeetingArchiveButtonState()
        diagnostic.isHidden = !showsMissingCredentialHint && speakerRefinementToken==nil && Date()>=feedbackExpiresAt && phase.error==nil && !diagnostic.stringValue.contains("失败") && !diagnostic.stringValue.contains("无法") && !diagnostic.stringValue.contains("请")
        feedbackUndoButton?.isHidden=Date()>=feedbackExpiresAt || !feedbackAllowsNameUndo || !naming.canUndo
        if [.stopped,.ended].contains(phase.phase),currentCacheID != nil,cachedTranscriptionComplete {heading.stringValue="已保存 · "+phase.time}
        source.toolTip=source.stringValue
        timelineToggle?.state=showsSpeakerRanges ? .on:.off
        updateRecordingDashboard()
        if !isHistoryReader {updateLibraryManagement()}
        if !isHistoryReader {scheduleMeetingArchivePreparationIfEligible(trigger:"workspace_refresh")}
        historyReader?.updateWorkspacePresentation()
    }
    @objc func returnFromHistory(){workspaceOwner?.returnToCurrent()}
    @objc func primaryWorkspaceAction() {
        // First click acts immediately. A second click in the same mouse
        // double-click must not cancel startup or reverse a pause.
        if (NSApp.currentEvent?.clickCount ?? 0)>1 {return}
        if isHistoryReader {workspaceOwner?.resumeViewedMeeting();return}
        if phase.phase == .connecting {end();return}
        if phase.phase == .recording {sendRecordingControl("pause");return}
        if phase.phase == .paused {sendRecordingControl("resume");return}
        guard !recordingBusy else{return}
        if currentCacheID != nil {resumeViewedMeeting();return}
        toggle()
    }
    @objc func beginNewMeeting() {
        guard (NSApp.currentEvent?.clickCount ?? 0)<=1,phase.phase != .connecting else{return}
        requestNewMeeting()
    }
    func requestNewMeeting() {
        guard !newMeetingRequested,!preparingModels,!credentialReadJob.waiting,!meetingDeletionBusy,!audioAssetOperationBusy else{return}
        // NSTextField keeps its field editor while editing. If we replace the
        // document first, the next presentation refresh can keep the old text
        // in that editor indefinitely and the final rename never reaches the
        // old meeting's cache. Commit it while the old cache is still active.
        if meetingTitleField.currentEditor() != nil {
            window.endEditing(for:meetingTitleField)
            if meetingTitleField.currentEditor() != nil { _ = window.makeFirstResponder(nil) }
            guard meetingTitleField.currentEditor() == nil else {
                diagnostic.stringValue="请先完成会议名称编辑，再新建对话";updateUI();return
            }
        }
        returnToCurrent();cacheReadJob.cancel();libraryOpenJob.cancel()
        newMeetingRequested=true
        if [.recording,.paused].contains(phase.phase) {finishRecording()}
        else if phase.phase == .connecting {end()}
        if child != nil || [.connecting,.recording,.paused,.stopping].contains(phase.phase) || processingAudio {
            diagnostic.stringValue="正在补齐上一场转写并保存，随后新建";updateUI()
        }
        finishPendingNewMeetingIfReady()
    }
    func finishPendingNewMeetingIfReady() {
        guard newMeetingRequested,!newMeetingSaveInFlight,child==nil,!processingAudio,!preparingModels,
              ![.connecting,.recording,.paused,.stopping].contains(phase.phase) else{return}
        func complete() {
            newMeetingRequested=false;newMeetingSaveInFlight=false
            let appendID=pendingAppendCaptureID;pendingAppendCaptureID=nil
            newMeeting()
            if let appendID {openMeetingForCaptureAppend(appendID)}
            else {meetingTitle=MeetingLibraryInfo.defaultTitle(Date());updateWorkspacePresentation()}
        }
        guard currentCacheID != nil else{complete();return}
        newMeetingSaveInFlight=true
        func failed() {
            newMeetingRequested=false;newMeetingSaveInFlight=false;pendingAppendCaptureID=nil
            diagnostic.stringValue="上一场保存未完成；原音和原文保留，请重试新建";updateUI()
        }
        // Name persistence must succeed before clearing its in-memory mapping.
        // Both receipts are serialized behind existing annotation writes.
        persistSessionNames { [weak self] namesResult in
            guard let self else{return}
            guard case .success=namesResult else{failed();return}
            self.persistRecordingLifecycle { result in
                switch result {case .success:complete();case .failure:failed()}
            }
        }
    }
    @objc func toggleSidebar(){sidebarManualVisible = sidebar.isHidden;layoutWorkspace()}
    func layoutWorkspace(){
        guard sidebar != nil else{return}
        let width=window.contentLayoutRect.width,visible=sidebarManualVisible ?? (width>=800)
        sidebar.isHidden = !visible;sidebarDivider?.isHidden = !visible
        sidebarWidth.constant=visible ? MeetingSidebarSizing.effective(preferredSidebarWidth,window:width):0
        agentController?.layout();historyReader?.agentController?.layout()
        window.contentView?.layoutSubtreeIfNeeded();resizeTranscript();historyReader?.resizeTranscript();updateWorkspacePresentation()
    }
    func showTransientFeedback(_ message:String,nameUndo:Bool=false) {
        feedbackAllowsNameUndo=nameUndo;diagnostic.stringValue=message;feedbackExpiresAt=Date().addingTimeInterval(7)
        let deadline=feedbackExpiresAt;updateWorkspacePresentation()
        DispatchQueue.main.asyncAfter(deadline:.now()+7) { [weak self] in
            guard let self,self.feedbackExpiresAt==deadline else{return};self.updateWorkspacePresentation()
        }
    }
    @objc func showLibrarySearch(){sidebarManualVisible=true;librarySearch.isHidden=false;layoutWorkspace();window.makeFirstResponder(librarySearch)}
    @objc func showDocumentSearch(){let document=displayedDocument;document.cancelTranscriptReadingRestore();document.window.makeFirstResponder(document.output);let command=NSMenuItem();command.tag=Int(NSFindPanelAction.showFindPanel.rawValue);document.output.performFindPanelAction(command)}
    @objc func nameVisibleSegment(){displayedDocument.nameSegment()}
    @objc func undoVisibleName(){displayedDocument.undoName()}
    @objc func exportVisibleDocument(){displayedDocument.exportTranscript()}
    @objc func toggleSpeakerRanges(){showsSpeakerRanges=timelineToggle.state == .on;renderText()}
    func handleWorkspaceTextChange(_ notification:Notification)->Bool {
        if notification.object as? NSSearchField === librarySearch {filterLibrary();return true}
        if notification.object as? NSTextField === meetingTitleField {return true}
        return false
    }
    func controlTextDidEndEditing(_ notification:Notification){if notification.object as? NSTextField === meetingTitleField {renameMeeting(meetingTitleField.stringValue)}}
    func renameMeeting(_ title:String){
        let owner=workspaceOwner ?? self
        guard !owner.meetingDeletionBusy else{return}
        let value=title.trimmingCharacters(in:.whitespacesAndNewlines)
        let oldTitle=meetingTitle
        guard !value.isEmpty,let id=currentCacheID,UUID(uuidString:id) != nil else{meetingTitleField.stringValue=oldTitle;return}
        let generation=meetingDocumentGeneration,session=activeSession
        let item=owner.recoveries.first(where:{$0.id==id}) ?? CachedMeeting(id:id,directory:recoveryBase().appendingPathComponent(id),date:Date(),writtenBytes:0,pendingBytes:0,occupiedBytes:0,tracks:[],audioCleaned:false,warning:false,retiredBytes:0,customTitle:oldTitle)
        // The stored title remains authoritative while the write is pending.
        meetingTitleField.stringValue=oldTitle
        owner.saveLibraryMeetingTitle(item,title:value) { [weak self] result in
            guard let self,self.currentCacheID==id,self.activeSession==session,self.meetingDocumentGeneration==generation else{return}
            if case .failure=result {self.meetingTitleField.stringValue=self.meetingTitle;self.showTransientFeedback("名称未保存，请重试")}
        }
    }
    func reloadLibrary(selectRecent:Bool=false) {
        guard !isHistoryReader else{return}
        if libraryJob.busy {libraryReloadPending=true;librarySelectRecentPending=librarySelectRecentPending || selectRecent;return}
        libraryJob.onStateChange={ [weak self] in guard let self=self,!self.libraryJob.busy,self.libraryReloadPending else{return};DispatchQueue.main.async{[weak self] in guard let self=self,self.libraryReloadPending else{return};let recent=self.librarySelectRecentPending;self.libraryReloadPending=false;self.librarySelectRecentPending=false;self.reloadLibrary(selectRecent:recent)}}
        let base=recoveryBase();libraryStatus.stringValue="正在读取会议";libraryRetryButton.isHidden=true
        // Keep first paint to bounded directory/manifest metadata. Participant
        // summaries parse transcripts and projections; fill them sequentially
        // after first paint, with the selected meeting taking priority.
        libraryJob.run(timeout:15,work:{try cachedMeetings(in:base)}){[weak self] result in guard let self=self else{return};switch result {
        case .success(let items):
            self.librarySummaryGeneration &+= 1;self.librarySummaryPending=nil;self.librarySummaryLoaded=[]
            let ids=Set(items.map{$0.id});self.libraryParticipants=self.libraryParticipants.filter{ids.contains($0.key)}
            self.recoveries=items;self.reconcileRecoveredMeetingContexts(items);self.filterLibrary()
            if selectRecent,!self.recordingBusy,self.currentCacheID==nil,let first=items.first {self.openLibraryMeeting(first)}
            self.requestSelectedLibraryParticipantSummary()
        case .failure(let error):self.libraryStatus.stringValue=cacheFailureMessage(error);self.libraryRetryButton.isHidden=false
        }}
    }
    /// Library enumeration may repair an interrupted journal without opening
    /// its document. Reconcile only durable receipts into existing saved
    /// projections; the publisher transaction never activates or rewrites turns.
    private func reconcileRecoveredMeetingContexts(_ items:[CachedMeeting]) {
        guard !isHistoryReader,let publisher=contextPublisher else{return}
        func readSidecar(_ item:CachedMeeting,_ name:String,_ limit:Int)->[String:Any]? {
            let file=item.directory.appendingPathComponent(name)
            guard let attributes=try? file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]),attributes.isRegularFile==true,attributes.isSymbolicLink != true,(attributes.fileSize ?? Int.max)<=limit,
                  let data=try? Data(contentsOf:file),let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
                  value["schema"] as? Int==1,value["cache_id"] as? String==item.id else{return nil}
            return value
        }
        for item in items {
            guard let status=item.recoveryStatus,let state=status["state"] as? String,
                  ["recovered_unclean_shutdown","source_error"].contains(state),
                  let source=try? item.metadata(),let session=source["session"] as? String,
                  source["cache_id"] as? String==item.id else{continue}
            let receipt=readSidecar(item,"journal-recovery.json",128*1024)
            let diagnostic=readSidecar(item,"journal-recovery-diagnostic.json",16*1024)
            if state=="recovered_unclean_shutdown" {
                guard receipt?["state"] as? String==state else{continue}
            } else {guard diagnostic?["state"] as? String==state else{continue}}
            let sourceTracks=(receipt?["tracks"] as? [[String:Any]] ?? []).compactMap{row -> [String:Any]? in
                guard let track=row["track"] as? String,isMeetingAudioTrack(track),
                      let before=row["original_written_bytes"] as? Int,let after=row["verified_written_bytes"] as? Int,
                      let tail=row["verified_tail_bytes"] as? Int else{return nil}
                return ["track":track,"before_bytes":before,"verified_bytes":after,"verified_tail_bytes":tail]
            }
            let recovery:[String:Any] = ["kind":"interrupted_capture","state":state,"code":diagnostic?["code"] ?? NSNull(),
                "audio_files_preserved":true,"gapless_capture_verified":false,"transcript_modified":false,"transcription_started":false,
                "tracks":sourceTracks,"warnings":receipt?["warnings"] as? [String] ?? []]
            publisher.reconcileRecordingRecovery(session:session,cacheID:item.id,transcriptionComplete:state=="source_error" ? false:item.transcriptionComplete,metadata:recovery)
        }
    }
    @objc func retryLibraryLoad(){libraryRetryButton.isHidden=true;reloadLibrary()}
    func requestSelectedLibraryParticipantSummary() {
        guard !isHistoryReader else{return}
        if libraryVisible.indices.contains(libraryTable.selectedRow) {
            let item=libraryVisible[libraryTable.selectedRow]
            if !librarySummaryLoaded.contains(item.id) {librarySummaryPending=item}
        }
        librarySummaryJob.onStateChange={ [weak self] in
            guard let self,!self.librarySummaryJob.busy else{return}
            DispatchQueue.main.async{[weak self] in self?.loadNextLibraryParticipantSummary()}
        }
        loadNextLibraryParticipantSummary()
    }
    private func loadNextLibraryParticipantSummary() {
        guard !librarySummaryJob.busy else{return}
        let pending=librarySummaryPending;librarySummaryPending=nil
        let priority=pending.flatMap{item in recoveries.contains(where:{$0.id==item.id}) && !librarySummaryLoaded.contains(item.id) ? item:nil}
        guard let item=priority ?? libraryVisible.first(where:{!librarySummaryLoaded.contains($0.id)}) ?? recoveries.first(where:{!librarySummaryLoaded.contains($0.id)}) else{return}
        loadLibraryParticipantSummary(item,generation:librarySummaryGeneration)
    }
    private func loadLibraryParticipantSummary(_ item:CachedMeeting,generation:Int) {
        guard !librarySummaryJob.busy else{librarySummaryPending=item;return}
        librarySummaryJob.run(timeout:30,work:{meetingParticipantSummary(item)}){[weak self] result in
            guard let self,self.librarySummaryGeneration==generation,self.recoveries.contains(where:{$0.id==item.id}) else{return}
            self.librarySummaryLoaded.insert(item.id)
            if case .success(let names)=result {
                self.libraryParticipants[item.id]=names
                // Updating another row must not reset selection or restart the
                // selected meeting's management read while names fill in.
                if let row=self.libraryVisible.firstIndex(where:{$0.id==item.id}) {
                    self.libraryTable.reloadData(forRowIndexes:IndexSet(integer:row),columnIndexes:IndexSet(integer:0))
                }
            }
            else {self.libraryStatus.stringValue="会议记录已加载；参会人信息暂不可用"}
        }
    }
    func filterLibrary(){
        libraryFilterWork?.cancel();let query=librarySearch.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        if query.isEmpty {librarySearchJob.cancel();libraryVisible=recoveries;renderLibraryList();return}
        libraryStatus.stringValue="正在搜索"
        let work=DispatchWorkItem{[weak self] in guard let self=self else{return};if self.librarySearchJob.busy {self.filterLibrary();return};let items=self.recoveries
            self.librarySearchJob.run(timeout:15,work:{try items.filter {item in
                if item.displayTitle.localizedCaseInsensitiveContains(query){return true}
                let payload=try RecoveryPayload(item)
                return payload.events.contains{($0["text"] as? String ?? "").localizedCaseInsensitiveContains(query)} || (payload.archive?.localizedCaseInsensitiveContains(query) ?? false)
            }}){[weak self] result in guard let self=self,self.librarySearch.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)==query else{return};switch result {case .success(let items):self.libraryVisible=items;self.renderLibraryList();case .failure:self.libraryStatus.stringValue="搜索未完成，请重试"}}
        };libraryFilterWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.25,execute:work)
    }
    func renderLibraryList(){if recordingBusy,let id=currentCacheID,let index=libraryVisible.firstIndex(where:{$0.id==id}) {let current=libraryVisible.remove(at:index);libraryVisible.insert(current,at:0)};librarySelectionChanging=true;libraryTable.reloadData();let id=historyReader?.currentCacheID ?? currentCacheID;if let row=libraryVisible.firstIndex(where:{$0.id==id}) {libraryTable.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)};librarySelectionChanging=false;libraryStatus.stringValue=libraryVisible.isEmpty ? (librarySearch.stringValue.isEmpty ? "还没有会议记录":"没有找到会议") : "会议记录 · \(libraryVisible.count)";libraryRetryButton?.isHidden=true;updateLibraryManagement()}
    func numberOfRows(in tableView:NSTableView)->Int {libraryVisible.count}
    func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView? {MeetingListRow()}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        guard libraryVisible.indices.contains(row) else{return nil};let item=libraryVisible[row];let cell=MeetingLibraryCellView();cell.libraryTable=tableView;let title=label(item.id==currentCacheID ? meetingTitle:item.displayTitle,size:13,weight:.semibold);title.textColor=MeetingVisualStyle.ink;title.lineBreakMode = .byTruncatingTail;title.maximumNumberOfLines=1
        let mode=item.recordingMode == "local_only" ? "仅录音":item.recordingMode == "record_and_transcribe" ? "录音并转写":"模式未记录"
        let icon=NSImageView(image:NSImage(systemSymbolName:item.recordingMode == "local_only" ? "mic":item.recordingMode == "record_and_transcribe" ? "text.bubble":"doc",accessibilityDescription:mode)!)
        icon.contentTintColor=MeetingVisualStyle.muted;icon.translatesAutoresizingMaskIntoConstraints=false;icon.toolTip=mode;icon.setAccessibilityLabel(mode);cell.addSubview(icon)
        let duration=MeetingLibraryDate.duration(item.durationSeconds)
        let savedState=item.recordingMode == "local_only" ? " · 仅录音":item.pendingBytes>0 ? " · 待转写":""
        let subtitle=label(MeetingLibraryDate.label(item.date)+" · "+(item.id==currentCacheID && recordingBusy ? phase.time:duration+savedState),size:11);subtitle.textColor = MeetingVisualStyle.muted;subtitle.lineBreakMode = .byTruncatingTail;subtitle.maximumNumberOfLines=1
        let participants=MeetingParticipantLabel(names:libraryParticipants[item.id] ?? []);participants.translatesAutoresizingMaskIntoConstraints=false;cell.addSubview(participants)
        for view in [title,subtitle] {view.isSelectable=false;view.isEditable=false;view.setAccessibilityLabel(view.stringValue);view.translatesAutoresizingMaskIntoConstraints=false;cell.addSubview(view)}
        NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:8),icon.widthAnchor.constraint(equalToConstant:14),icon.heightAnchor.constraint(equalToConstant:14),icon.centerYAnchor.constraint(equalTo:title.centerYAnchor),title.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:6),title.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-8),title.topAnchor.constraint(equalTo:cell.topAnchor,constant:9),subtitle.leadingAnchor.constraint(equalTo:title.leadingAnchor),subtitle.trailingAnchor.constraint(equalTo:title.trailingAnchor),subtitle.topAnchor.constraint(equalTo:title.bottomAnchor,constant:3),participants.leadingAnchor.constraint(equalTo:title.leadingAnchor),participants.trailingAnchor.constraint(equalTo:title.trailingAnchor),participants.topAnchor.constraint(equalTo:subtitle.bottomAnchor,constant:3),participants.heightAnchor.constraint(equalToConstant:16)])
        cell.textField=title;cell.toolTip=item.displayTitle+" · "+mode;return cell
    }
    func tableViewSelectionDidChange(_ notification:Notification){guard !librarySelectionChanging,libraryVisible.indices.contains(libraryTable.selectedRow) else{updateLibraryManagement();return};updateLibraryManagement();requestSelectedLibraryParticipantSummary();openLibraryMeeting(libraryVisible[libraryTable.selectedRow])}
    func openLibraryMeeting(_ item:CachedMeeting){
        guard displayedDocument.notesController?.flushForClosing() != false else { return }
        guard !meetingDeletionBusy else{return}
        if item.id==currentCacheID {returnToCurrent();return}
        libraryOpenJob.cancel();pendingLibraryOpen=item
        libraryOpenJob.onStateChange={ [weak self] in guard let self=self,!self.libraryOpenJob.busy,self.pendingLibraryOpen != nil else{return};DispatchQueue.main.async{[weak self] in self?.openPendingLibraryMeeting()}}
        openPendingLibraryMeeting()
    }
    func openPendingLibraryMeeting(){
        guard !libraryOpenJob.busy,let item=pendingLibraryOpen else{return};pendingLibraryOpen=nil
        libraryStatus.stringValue="正在打开会议"
        libraryOpenJob.run(work:{try RecoveryPayload(item)}){[weak self] result in guard let self=self else{return};switch result {
        case .failure(let error):self.libraryStatus.stringValue=cacheFailureMessage(error)
        case .success(let payload):do {
            guard self.historyReader?.notesController?.flushForClosing() != false else { return }
            let reader=Delegate();reader.previewRenderOnly=true;reader.isHistoryReader=true;reader.workspaceOwner=self;reader.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));reader.recoveryRootOverride=self.recoveryBase();try reader.applyRecovery(item,payload:payload)
            reader.meetingTitle=item.displayTitle;reader.updateUI();let ownWindow=reader.window;reader.window=self.window
            self.historyReader?.agentController?.suspend();self.historyReader?.confirmationController?.cancelQuickInteraction();self.historyReader?.savedVoiceRecognitionJob.cancel();self.historyReader?.detachSavedCoarseRefinement();self.historyReader?.currentDocument.removeFromSuperview();self.historyReader=reader;self.historyReaderShell=ownWindow;self.currentDocument.isHidden=true
            reader.currentDocument.removeFromSuperview();self.documentHost.addSubview(reader.currentDocument);self.pin(reader.currentDocument,to:self.documentHost);self.documentHost.layoutSubtreeIfNeeded();reader.resizeTranscript();reader.renderText();reader.agentController?.layout();self.updateWorkspacePresentation();self.renderLibraryList();self.installMenus()
        }catch{self.libraryStatus.stringValue="无法打开会议，请重试"}}
        }
    }
    @objc func returnToCurrent(){guard historyReader?.notesController?.flushForClosing() != false else {return};pendingLibraryOpen=nil;libraryOpenJob.cancel();historyReader?.agentController?.suspend();historyReader?.confirmationController?.cancelQuickInteraction();historyReader?.savedVoiceRecognitionJob.cancel();historyReader?.detachSavedCoarseRefinement();historyReader?.currentDocument.removeFromSuperview();historyReader=nil;historyReaderShell=nil;currentDocument?.isHidden=false;resizeTranscript();updateWorkspacePresentation();if libraryTable != nil {renderLibraryList()}}
    @objc func resumeViewedMeeting(){
        guard !meetingDeletionBusy,!newMeetingRequested,let id=displayedDocument.currentCacheID else{
            NSLog("zaichang-append: click ignored deletion=%d newRequested=%d hasCache=%d",meetingDeletionBusy ? 1:0,newMeetingRequested ? 1:0,displayedDocument.currentCacheID==nil ? 0:1)
            if newMeetingRequested {diagnostic.stringValue="正在保存上一场，完成后会自动继续"}
            return
        }
        pendingAppendCaptureID=id
        requestNewMeeting()
        if !newMeetingRequested && pendingAppendCaptureID==id {
            NSLog("zaichang-append: save blocked preparing=%d credentialWaiting=%d deletion=%d assets=%d",preparingModels ? 1:0,credentialReadJob.waiting ? 1:0,meetingDeletionBusy ? 1:0,audioAssetOperationBusy ? 1:0)
            pendingAppendCaptureID=nil;diagnostic.stringValue="当前会议尚不能安全保存，请重试";updateUI()
        }
    }
    func openMeetingForCaptureAppend(_ id:String) {
        let base=recoveryBase();diagnostic.stringValue="正在打开原会议"
        cacheReadJob.run(work:{try cachedMeetings(in:base).first(where:{$0.id==id}).map{($0,try RecoveryPayload($0))}}){[weak self] result in
            guard let self else{return}
            switch result {
            case .success(let pair):
                guard let (item,payload)=pair else{NSLog("zaichang-append: meeting not found");self.diagnostic.stringValue="没有找到这场会议";self.updateUI();return}
                do {try self.applyRecovery(item,payload:payload);self.startAppendCapture(item,metadata:payload.metadata)}
                catch {NSLog("zaichang-append: open failed %@",String(describing:error));self.diagnostic.stringValue="原会议未能打开；已有内容保留";self.updateUI()}
            case .failure(let error):self.diagnostic.stringValue=cacheFailureMessage(error);self.updateUI()
            }
        }
    }
    func startAppendCapture(_ item:CachedMeeting,metadata:[String:Any]) {
        let qaFixture=Credential.offline && previewRenderOnly && startupWorkerFixture != nil
        guard (!Credential.offline && !previewRenderOnly) || qaFixture else {
            diagnostic.stringValue="离线环境不启动录音";updateUI();return
        }
        guard child==nil,!processingAudio,
              Bundle.main.object(forInfoDictionaryKey:"LocalRecordingAllowed") as? Bool==true,
              let session=metadata["session"] as? String,session==activeSession,
              let bundle=metadata["bundle"] as? String,["*system*","*microphone*","com.tencent.meeting"].contains(bundle) else {
            NSLog("zaichang-append: start refused child=%d processing=%d sessionMatch=%d",child==nil ? 0:1,processingAudio ? 1:0,(metadata["session"] as? String)==activeSession ? 1:0)
            diagnostic.stringValue="这场会议暂时无法继续录音；已有内容保留";updateUI();return
        }
        let local=metadata["capture_mode"] as? String=="local_only"
        // Same helper selection as a normal start: without candidate_mode the
        // worker falls back to a development helper path that is not shipped.
        var request:[String:Any]=["bundle":bundle,"mic_enabled":true,"source_scope_confirmed":true,
                                   "user_launch_confirmed":true,"append_capture_cache_id":item.id,
                                   "candidate_mode":trialCandidate]
        sourceBundle=bundle;sessionLocalOnly=local;phase.phase = .connecting;phase.error=nil
        diagnostic.stringValue="正在接续原会议录音";updateUI()
        if local {
            request["local_only"]=true;request["local_recording_confirmed"]=true;request["local_max_seconds"]=3600
            startWorker(nil,overrideRequest:request)
        } else {
            guard metadata["asr_destination"] as? String=="dashscope.aliyuncs.com",
                  metadata["capture_mode"] as? String != "local_only" else {
                phase.phase = .failed;phase.error="转写服务配置不可用；已有内容保留";updateUI();return
            }
            request["cloud_session_confirmed"]=true
            if qaFixture {request["key"]="offline-fixture";startWorker(nil,overrideRequest:request);return}
            credentialReadJob.onStateChange={ [weak self] in self?.updateUI() }
            credentialReadJob.run(timeout:15,work:{try Credential.load()}){[weak self] result in
                guard let self else{return}
                guard self.currentCacheID==item.id,self.phase.phase == .connecting else{
                    // Never drop a continue request silently: say so where the user looks.
                    NSLog("zaichang-append: credential result dropped cacheMatch=%d phase=%@",self.currentCacheID==item.id ? 1:0,String(describing:self.phase.phase))
                    if self.currentCacheID==item.id,self.phase.error==nil {
                        self.phase.phase = .failed;self.phase.error="继续录音未启动，请再点一次；已有内容保留";self.updateUI()
                    }
                    return
                }
                switch result {
                case .success(let value):
                    guard let secret=value,!secret.isEmpty else{self.phase.phase = .failed;self.phase.error="转写服务凭据不可用；已有内容保留";self.updateUI();return}
                    var start=request;start["key"]=secret;self.startWorker(nil,overrideRequest:start)
                case .failure:
                    self.phase.phase = .failed;self.phase.error="钥匙串读取未完成；已有内容保留";self.updateUI()
                }
            }
        }
    }
}

/// Sidebar dates read like a list of days: 今天 14:25 · 37 分钟.
enum MeetingLibraryDate {
    static func label(_ date:Date,now:Date=Date(),calendar:Calendar = .current)->String {
        let time=DateFormatter();time.dateFormat="HH:mm"
        if calendar.isDate(date,inSameDayAs:now) {return "今天 "+time.string(from:date)}
        if let yesterday=calendar.date(byAdding:.day,value:-1,to:now),calendar.isDate(date,inSameDayAs:yesterday) {return "昨天 "+time.string(from:date)}
        let day=DateFormatter();day.dateFormat=calendar.isDate(date,equalTo:now,toGranularity:.year) ? "M月d日 HH:mm":"yyyy年M月d日"
        return day.string(from:date)
    }
    static func duration(_ seconds:Double)->String {
        guard seconds.isFinite,seconds>=60 else{return "<1分钟"}
        let minutes=Int((seconds/60).rounded())
        return minutes<60 ? "\(minutes)分钟":"\(minutes/60)小时\(minutes%60)分"
    }
}
