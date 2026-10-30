import AppKit

struct CoarseProcessingProgress {
    let runID:String
    let stage:String
    let completed:Int
    let total:Int
}

/// Small status row shared by the recording dashboard and speaker review window.
/// It only renders progress supplied by the existing refinement job; it does not
/// persist state or infer percentages from elapsed time.
final class CoarseProcessingStatusView:NSStackView {
    let progressIndicator=NSProgressIndicator()
    let statusLabel=NSTextField(labelWithString:"")
    private var indicatorWidth:NSLayoutConstraint!

    override init(frame:NSRect) {
        super.init(frame:frame)
        orientation = .horizontal;alignment = .centerY;distribution = .fill;spacing=7
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped=false
        progressIndicator.setAccessibilityLabel("整理进度")
        statusLabel.font = .systemFont(ofSize:11,weight:.medium)
        statusLabel.textColor=MeetingVisualStyle.muted
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        addArrangedSubview(progressIndicator);addArrangedSubview(statusLabel)
        indicatorWidth=progressIndicator.widthAnchor.constraint(equalToConstant:14);indicatorWidth.isActive=true
        isHidden=true
        setAccessibilityElement(true)
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}

    func show(_ progress:CoarseProcessingProgress?,summary:String?,isRecording:Bool,fallbackRunning:Bool) {
        let stage=progress?.stage
        let active=(stage == "preparing" || stage == "audio" || stage == "speakers") || (progress == nil && fallbackRunning)
        let finished=stage == "complete"
        let failed=stage == "failed"
        guard active || finished || failed || summary?.isEmpty==false else {isHidden=true;stopIndicator();return}
        isHidden=false
        if active {
            let text:String
            switch stage {
            case "audio":text="正在整理暂停前的文字"
            case "speakers":text="正在整理暂停前的发言人"
            default:text="正在准备暂停前内容"
            }
            statusLabel.stringValue=text+(isRecording ? " · 录音可继续":"")
            configureIndicator(progress)
        } else {
            stopIndicator()
            let result=failed ? (summary?.isEmpty==false ? summary!:"上一段整理未完成，可重试") : finished ? (summary?.isEmpty==false ? summary!:"上一段已整理，可标记发言人") : (summary ?? "")
            statusLabel.stringValue=result+(isRecording ? " · 录音中":"")
        }
        setAccessibilityLabel(statusLabel.stringValue)
        setAccessibilityValue(active ? progressValue(progress):(failed ? "未完成":statusLabel.stringValue))
    }

    private func configureIndicator(_ progress:CoarseProcessingProgress?) {
        progressIndicator.isHidden=false
        progressIndicator.stopAnimation(nil)
        let valid=progress.map{$0.total>0 && $0.completed>=0 && $0.completed<=$0.total} ?? false
        if valid,let progress=progress {
            progressIndicator.style = .bar;progressIndicator.isIndeterminate=false;progressIndicator.isDisplayedWhenStopped=true
            progressIndicator.minValue=0;progressIndicator.maxValue=Double(progress.total)
            progressIndicator.doubleValue=Double(progress.completed)
            indicatorWidth.constant=92
        } else {
            progressIndicator.style = .spinning;progressIndicator.isIndeterminate=true;progressIndicator.isDisplayedWhenStopped=false
            indicatorWidth.constant=14
            progressIndicator.startAnimation(nil)
        }
    }
    private func stopIndicator() {
        progressIndicator.isHidden=true
        progressIndicator.stopAnimation(nil);progressIndicator.isIndeterminate=false
        progressIndicator.doubleValue=0;progressIndicator.isDisplayedWhenStopped=false;indicatorWidth.constant=14
    }
    private func progressValue(_ progress:CoarseProcessingProgress?)->String {
        guard let progress=progress,progress.total>0,progress.completed>=0,progress.completed<=progress.total else{return "处理中"}
        return "\(progress.completed) / \(progress.total)"
    }
}

// Measured PCM levels only. No microphone is opened by this view.
final class RecordingLevelView:NSView {
    var name="麦克风"
    private(set) var rms=0.0
    private var peak=0.0
    private(set) var status="未开始"
    private var samples=[Double](repeating:0,count:48)
    override var intrinsicContentSize:NSSize {NSSize(width:150,height:28)}
    override init(frame:NSRect) {super.init(frame:frame);setAccessibilityElement(true);setAccessibilityRole(.levelIndicator)}
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    func show(rms:Double,peak:Double,status:String) {
        let value=rms.isFinite ? min(1,max(0,rms)):0
        if value==0 {samples=Array(repeating:0,count:48)}
        else if value != self.rms || peak != self.peak {samples.append(value);samples.removeFirst(max(0,samples.count-48))}
        self.rms=value;self.peak=peak.isFinite ? min(1,max(0,peak)):0;self.status=status;toolTip=name+" · "+status
        setAccessibilityLabel(name);setAccessibilityValue(status+(self.rms>0 ? "，\(Int(20*log10(self.rms)))分贝":""));needsDisplay=true
    }
    /// Bar tone on the charcoal capsule: the microphone reads brighter than computer audio.
    var barColor=MeetingVisualStyle.capsulePaper
    override func draw(_ dirtyRect:NSRect) {
        // Drawn on the charcoal capsule. Name and status live in the tooltip and
        // accessibility value; the plot itself is the visible state.
        let iconSize:CGFloat=14
        if let symbol=NSImage(systemSymbolName:name=="麦克风" ? "mic":"desktopcomputer",accessibilityDescription:nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:12,weight:.medium).applying(NSImage.SymbolConfiguration(paletteColors:[NSColor.white.withAlphaComponent(0.72)]))) {
            symbol.draw(in:NSRect(x:0,y:bounds.midY-iconSize/2,width:iconSize,height:iconSize))
        }
        let plot=NSRect(x:iconSize+8,y:bounds.midY-12,width:max(1,bounds.width-iconSize-10),height:24)
        let step:CGFloat=5,barWidth:CGFloat=3
        let count=max(1,Int(plot.width/step)),recent=Array(samples.suffix(count))
        let silent=recent.allSatisfy{$0<=0}
        let clipping=peak>=0.99
        for i in 0..<count {
            // Newest samples sit on the right; a silent source is a row of flat dots.
            let index=recent.count-count+i,value=index>=0 ? recent[index]:0
            let normalized=value>0 ? min(1,max(0,(20*log10(value)+60)/54)):0
            let h=max(3,CGFloat(normalized)*plot.height)
            (silent || value<=0 ? NSColor.white.withAlphaComponent(0.22):clipping ? NSColor.systemOrange:barColor).setFill()
            NSBezierPath(roundedRect:NSRect(x:plot.minX+CGFloat(i)*step,y:plot.midY-h/2,width:barWidth,height:h),xRadius:barWidth/2,yRadius:barWidth/2).fill()
        }
        toolTip=name+" · "+(clipping ? "声音过响":rms>0 ? "\(Int(max(-60,20*log10(rms)))) dB":status)
    }
}

/// The charcoal capsule that holds the recording controls.
final class RecordingTransportSurface:NSView {
    override init(frame:NSRect) {
        super.init(frame:frame);wantsLayer=true;layer?.masksToBounds=false
        layer?.borderWidth=MeetingVisualStyle.charcoalBorderWidth;layer?.shadowOpacity=0.2;layer?.shadowRadius=14;layer?.shadowOffset=CGSize(width:0,height:-6)
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    override var wantsUpdateLayer:Bool {true}
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor=MeetingVisualStyle.charcoal.cgColor;self.layer?.borderColor=MeetingVisualStyle.charcoalBorder.cgColor
            self.layer?.shadowColor=NSColor.black.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {super.viewDidChangeEffectiveAppearance();needsDisplay=true}
    override func layout() {
        super.layout();layer?.cornerRadius=bounds.height/2
        layer?.shadowPath=CGPath(roundedRect:bounds,cornerWidth:bounds.height/2,cornerHeight:bounds.height/2,transform:nil)
    }
}

/// Breathing dot beside the timer; static when Reduce Motion is on.
final class RecordingLiveDot:NSView {
    enum Tone {case live,idle,hidden}
    private(set) var tone:Tone = .hidden
    override init(frame:NSRect) {super.init(frame:frame);wantsLayer=true;setAccessibilityElement(false)}
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    override var intrinsicContentSize:NSSize {NSSize(width:8,height:8)}
    override func layout() {super.layout();layer?.cornerRadius=bounds.height/2}
    func show(_ next:Tone) {
        guard next != tone else{return}
        tone=next;isHidden=next == .hidden
        layer?.backgroundColor=(next == .live ? MeetingVisualStyle.capsuleLive:MeetingVisualStyle.capsuleIdleDot).cgColor
        layer?.removeAnimation(forKey:"breathe")
        guard next == .live,!MeetingVisualStyle.reducesMotion else{return}
        let breathe=CABasicAnimation(keyPath:"opacity");breathe.fromValue=1;breathe.toValue=0.35
        breathe.duration=0.8;breathe.autoreverses=true;breathe.repeatCount = .infinity
        breathe.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut);layer?.add(breathe,forKey:"breathe")
    }
}

/// Recording-mode choice shown inside the capsule before a meeting starts.
final class RecordingModeChip:NSButton {
    var onSelect:((Int)->Void)?
    var selectedIndex=0 {didSet {refreshTitle()}}
    private let titles=["录音并转写","仅录音"]
    override init(frame:NSRect) {
        super.init(frame:frame);isBordered=false;bezelStyle = .regularSquare;wantsLayer=true;focusRingType = .default
        target=self;action=#selector(showChoices);setAccessibilityLabel("记录模式")
        setAccessibilityHelp("录音并转写使用云服务；仅录音只保存在本机。开始录音后，本场模式不可切换。")
        toolTip="录音并转写：音频送云端识别；仅录音：只存本机，不上传。";refreshTitle()
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    private func refreshTitle() {
        let text=NSMutableAttributedString(string:titles[selectedIndex]+" ",attributes:[.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:NSColor.white.withAlphaComponent(0.86)])
        text.append(NSAttributedString(string:"⌄",attributes:[.font:NSFont.systemFont(ofSize:11,weight:.semibold),.foregroundColor:NSColor.white.withAlphaComponent(0.62),.baselineOffset:2]))
        attributedTitle=text;setAccessibilityValue(titles[selectedIndex]);invalidateIntrinsicContentSize()
    }
    override var intrinsicContentSize:NSSize {let size=attributedTitle.size();return NSSize(width:ceil(size.width)+22,height:26)}
    override func layout() {super.layout();layer?.cornerRadius=bounds.height/2;layer?.backgroundColor=NSColor.white.withAlphaComponent(isEnabled ? 0.10:0.05).cgColor}
    @objc private func showChoices() {
        let menu=NSMenu()
        for (index,title) in titles.enumerated() {
            let item=NSMenuItem(title:title,action:#selector(choose(_:)),keyEquivalent:"");item.target=self;item.tag=index;item.state=index==selectedIndex ? .on:.off;menu.addItem(item)
        }
        menu.popUp(positioning:menu.item(at:selectedIndex),at:NSPoint(x:0,y:bounds.height),in:self)
    }
    @objc private func choose(_ sender:NSMenuItem) {selectedIndex=sender.tag;onSelect?(sender.tag)}
}

extension Delegate {
    var canSelectRecordingMode:Bool {
        !isHistoryReader && currentCacheID==nil && child==nil && !preparingModels && !processingAudio && !credentialReadJob.waiting && !newMeetingRequested && [.idle,.stopped,.failed,.ended].contains(phase.phase)
    }
    var displayedLocalMode:Bool {currentCacheID != nil || activeSession != nil ? sessionLocalOnly:localOnlyMode}
    func makeRecordingDashboard()->NSView {
        let panel=stack(.vertical,spacing:7);panel.alignment = .leading
        let row=stack(.horizontal,spacing:12);row.distribution = .fill
        let switcher=NSSegmentedControl(labels:["录音并转写","仅录音"],trackingMode:.selectOne,target:self,action:#selector(selectDashboardMode(_:)))
        switcher.segmentStyle = .rounded;switcher.controlSize = .regular;switcher.selectedSegment=localOnlyMode ? 1:0
        switcher.toolTip="录音并转写：音频送云端识别；仅录音：只存本机，不上传。"
        switcher.setWidth(116,forSegment:0);switcher.setWidth(82,forSegment:1);switcher.setAccessibilityLabel("记录模式");switcher.setAccessibilityHelp("录音并转写使用云服务；仅录音只保存在本机。开始录音后，本场模式不可切换。")
        recordingModeSwitch=switcher;row.addArrangedSubview(switcher)
        let spacer=NSView();spacer.setContentHuggingPriority(.defaultLow,for:.horizontal);row.addArrangedSubview(spacer)
        let stop=NSButton(title:"停止整理",target:self,action:#selector(toggleCoarseRefinement));stop.bezelStyle = .inline;stop.toolTip="停止后台整理，保留已录音频和现有文字";coarseStopButton=stop;row.addArrangedSubview(stop);panel.addArrangedSubview(row)
        let hint=label("",size:11);hint.textColor = .secondaryLabelColor;hint.lineBreakMode = .byWordWrapping;hint.maximumNumberOfLines=2;recordingModeHint=hint;panel.addArrangedSubview(hint)
        let progress=CoarseProcessingStatusView();progress.identifier=NSUserInterfaceItemIdentifier("recording-coarse-progress");panel.addArrangedSubview(progress)
        for item in [row,hint,progress] as [NSView] {item.widthAnchor.constraint(equalTo:panel.widthAnchor).isActive=true}
        return panel
    }
    func makeRecordingTransport()->NSView {
        // A floating capsule centred under the transcript. The outer row keeps
        // the full document width, so no fixed width reaches the window.
        let container=NSView();container.translatesAutoresizingMaskIntoConstraints=false
        let surface=RecordingTransportSurface();surface.translatesAutoresizingMaskIntoConstraints=false;container.addSubview(surface);recordingTransportView=container
        let row=stack(.horizontal,spacing:16);row.alignment = .centerY;row.distribution = .fill;row.translatesAutoresizingMaskIntoConstraints=false;surface.addSubview(row)
        // Controls resolve as on a dark surface; the surface itself follows the window so its charcoal tracks light/dark.
        row.appearance=NSAppearance(named:.darkAqua)
        let mic=RecordingLevelView(),computer=RecordingLevelView();mic.name="麦克风";computer.name="电脑声音";computer.barColor=MeetingVisualStyle.capsuleComputerBar;microphoneLevel=mic;computerLevel=computer
        // The waveforms take all spare width so the controls stay pinned to the capsule ends.
        mic.setContentHuggingPriority(.defaultLow-1,for:.horizontal);computer.setContentHuggingPriority(.defaultLow-1,for:.horizontal)
        // Left: live dot + timer over the state line, or 开始录音 + mode chip before a meeting.
        let dot=RecordingLiveDot();recordingLiveDot=dot
        let clock=label("00:00",size:21,weight:.semibold);clock.font = .monospacedDigitSystemFont(ofSize:21,weight:.semibold);clock.textColor = .white;recordingTimeLabel=clock
        heading.textColor=MeetingVisualStyle.capsuleSecondary;heading.font = .systemFont(ofSize:11)
        let chip=RecordingModeChip();chip.onSelect={[weak self] index in self?.selectRecordingModeFromChip(index)};recordingModeChip=chip
        let titleLine=stack(.horizontal,spacing:10);titleLine.alignment = .centerY;titleLine.addArrangedSubview(clock);titleLine.addArrangedSubview(chip)
        let timing=stack(.vertical,spacing:1);timing.alignment = .leading;timing.addArrangedSubview(titleLine);timing.addArrangedSubview(heading)
        heading.widthAnchor.constraint(lessThanOrEqualToConstant:220).isActive=true
        let lead=stack(.horizontal,spacing:10);lead.alignment = .centerY;lead.addArrangedSubview(dot);lead.addArrangedSubview(timing)
        lead.setContentHuggingPriority(.defaultHigh,for:.horizontal)
        // Waveforms shrink to their minimum before the state line truncates.
        heading.setContentCompressionResistancePriority(.defaultLow+1,for:.horizontal);clock.setContentCompressionResistancePriority(.required,for:.horizontal)
        // Right: notes, then the primary control.
        let trailing=stack(.horizontal,spacing:10);trailing.alignment = .centerY;trailing.setContentHuggingPriority(.defaultHigh,for:.horizontal);notesTransportStack=trailing
        if let notes=notesController {installTransportNotes(notes)}
        trailing.addArrangedSubview(action)
        // The button title and tooltip already say what it does.
        let caption=label("开始录音",size:10.5);caption.textColor = .secondaryLabelColor;caption.isHidden=true;recordingActionCaption=caption
        row.addArrangedSubview(lead);row.addArrangedSubview(mic);row.addArrangedSubview(computer);row.addArrangedSubview(trailing)
        let preferred=surface.widthAnchor.constraint(equalToConstant:600);preferred.priority = .defaultLow
        NSLayoutConstraint.activate([surface.centerXAnchor.constraint(equalTo:container.centerXAnchor),surface.topAnchor.constraint(equalTo:container.topAnchor,constant:6),surface.bottomAnchor.constraint(equalTo:container.bottomAnchor,constant:-14),
                                     surface.widthAnchor.constraint(lessThanOrEqualTo:container.widthAnchor,constant:-24),preferred,surface.heightAnchor.constraint(equalToConstant:66),
                                     row.leadingAnchor.constraint(equalTo:surface.leadingAnchor,constant:22),row.trailingAnchor.constraint(equalTo:surface.trailingAnchor,constant:-10),row.centerYAnchor.constraint(equalTo:surface.centerYAnchor),
                                     mic.widthAnchor.constraint(equalTo:computer.widthAnchor),mic.heightAnchor.constraint(equalToConstant:28),computer.heightAnchor.constraint(equalToConstant:28)])
        return container
    }
    func installTransportNotes(_ notes:MeetingNotesController) {
        // With the assistant panel, notes are its 笔记 tab; the capsule gets a button only without that panel.
        guard !assistantEnabled else {return}
        let toggle=notes.toggle
        toggle.title="";toggle.toolTip="记笔记：在右栏「笔记」记录，随本场一起保存";toggle.image=NSImage(systemSymbolName:"note.text",accessibilityDescription:"笔记")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:15,weight:.medium))
        toggle.isBordered=false;toggle.bezelStyle = .regularSquare;toggle.imagePosition = .imageOnly;toggle.contentTintColor = .white
        toggle.wantsLayer=true;toggle.layer?.cornerRadius=20;toggle.layer?.backgroundColor=NSColor.white.withAlphaComponent(0.09).cgColor
        if toggle.constraints.isEmpty {NSLayoutConstraint.activate([toggle.widthAnchor.constraint(equalToConstant:40),toggle.heightAnchor.constraint(equalToConstant:40)])}
        if let center=notesTransportStack {center.insertArrangedSubview(notes.toggle,at:center.arrangedSubviews.firstIndex(where:{$0 === action}) ?? center.arrangedSubviews.count)}
    }
    private func emptyMeetingItem()->CachedMeeting? {(workspaceOwner ?? self).recoveries.first{$0.id==currentCacheID}}
    func refreshEmptyMeetingActions() {
        let owner=workspaceOwner ?? self
        guard let item=emptyMeetingItem(),let management=owner.libraryManagement else {emptyFilesButton?.isEnabled=false;emptyTranscribeButton?.isEnabled=false;return}
        emptyFilesButton?.isEnabled=management.enabled(.meetingFiles,for:item)
        emptyTranscribeButton?.isEnabled=management.enabled(.transcribe,for:item)
    }
    @objc func openEmptyMeetingFiles() {guard let item=emptyMeetingItem() else{return};(workspaceOwner ?? self).libraryManagementController.perform(.meetingFiles,item:item)}
    @objc func transcribeEmptyMeeting() {guard let item=emptyMeetingItem() else{return};(workspaceOwner ?? self).libraryManagementController.perform(.transcribe,item:item)}
    func selectRecordingModeFromChip(_ index:Int) {
        guard canSelectRecordingMode,let switcher=recordingModeSwitch else {updateRecordingDashboard();return}
        switcher.selectedSegment=index;selectDashboardMode(switcher)
    }
    @objc func selectDashboardMode(_ sender:NSSegmentedControl) {
        guard canSelectRecordingMode else {updateRecordingDashboard();return}
        recordingModePicker?.selectItem(at:sender.selectedSegment);changeRecordingMode()
    }
    func receiveAudioLevels(_ event:[String:Any],now:Double=ProcessInfo.processInfo.systemUptime) {
        guard phase.phase == .recording,event["session"] as? String==activeSession,
              let levels=event["levels"] as? [String:[String:Any]] else{return}
        latestAudioLevels=levels;latestAudioLevelAt=now;refreshAudioLevels(now:now);historyReader?.refreshAudioLevels(now:now)
    }
    func refreshAudioLevels(now:Double=ProcessInfo.processInfo.systemUptime) {
        let owner=isHistoryReader ? (workspaceOwner ?? self):self
        let live=owner.phase.phase == .recording && now-owner.latestAudioLevelAt<1
        let state=owner.phase.phase == .paused ? "已暂停":owner.phase.phase == .recording ? "等待声音":owner.phase.phase == .connecting ? "等待启动":"未在录音"
        func measurement(_ key:String)->(Double,Double) {
            guard live,let v=owner.latestAudioLevels[key],(v["last_packet_age_seconds"] as? Double ?? 0)<0.5 else{return (0,0)}
            return(v["signal_rms"] as? Double ?? 0,v["signal_peak"] as? Double ?? 0)
        }
        let mic=measurement("mic"),remote=measurement("computer")
        microphoneLevel?.show(rms:mic.0,peak:mic.1,status:state);computerLevel?.show(rms:remote.0,peak:remote.1,status:state)
    }
    func updateRecordingDashboard() {
        guard let switcher=recordingModeSwitch else{return}
        recordingTransportView?.isHidden=false
        // Keep both flexible sides in the stack when browsing history. Hiding
        // arranged views detaches them and leaves only the fixed-width center,
        // which propagates a maximum width to the entire NSWindow.
        for level in [microphoneLevel,computerLevel].compactMap({$0}) {
            level.isHidden=false;level.alphaValue=isHistoryReader ? 0:1
            level.setAccessibilityHidden(isHistoryReader)
        }
        let current=displayedLocalMode,live=[.connecting,.recording,.paused,.stopping].contains(phase.phase)
        switcher.selectedSegment=(live || isHistoryReader) ? (current ? 1:0):(localOnlyMode ? 1:0)
        switcher.isEnabled=canSelectRecordingMode
        // Only offer the choice while it can still be made; otherwise the hint line states the mode.
        // The choice is made with the chip inside the capsule; the segmented control stays as its model.
        switcher.isHidden=true
        let owner=isHistoryReader ? (workspaceOwner ?? self):self
        coarseStopButton?.isHidden = !hasRunningCoarseRefinement
        // An empty row would keep only its flexible spacer and swallow the window height.
        switcher.superview?.isHidden = switcher.isHidden && (coarseStopButton?.isHidden ?? true)
        recordingModeHint?.stringValue = ""
        recordingModeHint?.isHidden=true
        let startDate=absoluteTime?.date(0) ?? (workspaceOwner ?? self).recoveries.first{$0.id==currentCacheID}?.date
        let startText=startDate.map{MeetingLibraryDate.label($0)+" 开始"} ?? "新会议"
        let eyebrowStatus:String
        if phase.phase == .recording {eyebrowStatus=current ? "仅录音":"实时转写"}
        else if owner.hasPendingTranscriptionWork {eyebrowStatus="正在补齐已录文字"}
        else if isHistoryReader || currentCacheID != nil && [.stopped,.ended,.failed].contains(phase.phase) {
            eyebrowStatus=current ? "仅录音 · 未转写":cachedTranscriptionComplete ? "录音与文字已保存":"转写尚未完成"
        } else {eyebrowStatus=current ? "仅录音":"实时转写"}
        meetingEyebrow?.stringValue=startText+" · "+eyebrowStatus
        let progressView=(recordingModeHint?.superview?.subviews.first{$0.identifier==NSUserInterfaceItemIdentifier("recording-coarse-progress")} as? CoarseProcessingStatusView)
        progressView?.show(owner.coarseProcessingProgress,summary:owner.coarseProcessingSummary,isRecording:owner.phase.phase == .recording,fallbackRunning:owner.hasRunningCoarseRefinement)
        if phase.error==nil && !microphoneSignalAlertVisible {
            let mode=current ? "仅录音":"录音并转写"
            var text="准备就绪 · "+(localOnlyMode ? "仅录音":"录音并转写")
            switch phase.phase {
            case .connecting:text=credentialReadJob.waiting ? "正在连接转写服务":"正在启动收音"
            case .recording:
                text=current ? "仅录音中":"录音中 · 实时转写"
                if !current {
                    if asrNetworkStates.values.contains("pending") {text="录音中 · 待补转写"}
                    else if asrNetworkStates.values.contains("waiting") {text="录音中 · 转写等待网络"}
                    else if asrNetworkStates.values.contains("catching") {text="录音中 · 正在补全转写"}
                }
            case .paused:
                text="已暂停 · "+mode
                if !current,!pausedTailStates.isEmpty {
                    text=pausedTailStates.values.contains("processing") ? "录音已暂停 · 正在补齐文字":pausedTailStates.values.contains("pending") ? "录音已暂停 · 转写未完成":"录音已暂停 · 已录内容已转写"
                }
            case .stopping:text=resumeBusy ? "录音已保存 · 正在补转":processingAudio ? "录音已结束 · 正在完成转写":"正在结束并保存"
            case .stopped,.ended:
                text=current ? "录音已保存 · 未转写":cachedTranscriptionComplete ? "录音与文字已保存":"录音已保存 · 待转写"
                // "Nothing saved" only when nothing was recorded; a timed or
                // reopened meeting must not contradict its own duration.
                if currentCacheID==nil && phase.elapsed<=0 && !isHistoryReader {text="已停止 · 尚无保存的录音"}
            case .failed:break
            case .idle:break
            }
            if [.paused,.stopped].contains(phase.phase),!current {
                let prefix=phase.phase == .paused ? "录音已暂停":"录音已保存"
                if let message=speakerRefinementMessage,owner.coarseProcessingSummary==nil {text=prefix+" · "+message}
            }
            heading.stringValue=text
            heading.font = .systemFont(ofSize:11,weight:.regular)
            heading.textColor=MeetingVisualStyle.capsuleSecondary
        }
        // Before a meeting the capsule offers 开始录音 + mode chip; afterwards the timer and state line.
        let choosing=canSelectRecordingMode && currentCacheID==nil && !isHistoryReader
        recordingModeChip?.isHidden = !choosing;recordingModeChip?.isEnabled=choosing;recordingModeChip?.selectedIndex=localOnlyMode ? 1:0
        heading.isHidden=choosing
        recordingLiveDot?.show(owner.phase.phase == .recording ? .live:choosing ? .hidden:.idle)
        (action as? RecordingPrimaryButton)?.resumeStyle = !choosing && owner.phase.phase != .recording && owner.phase.phase != .connecting
        if sequence.isEmpty && recoveredArchiveText==nil {
            if showsMissingCredentialHint && currentCacheID==nil && !localOnlyMode {
                empty.stringValue="去设置里填写百炼密钥"
            } else if current || (phase.phase == .idle && localOnlyMode) {
                empty.stringValue=phase.phase == .recording ? "正在保存声音，下方波形显示收音状态":phase.phase == .paused ? "录音已暂停，声音保存在本机":currentCacheID != nil ? "录音已保存，可打开会议文件查看":"点击开始录音，声音将保存在本机"
            } else {
                switch phase.phase {
                case .recording:empty.stringValue="正在收音，识别出的文字会出现在这里"
                case .paused:
                    empty.stringValue=pausedTailStates.values.contains("pending") ? "录音已暂停，转写尚未完成；原音保存在本机":!pausedTailStates.isEmpty && !pausedTailStates.values.contains("processing") ? "录音已暂停，已录内容已转写；暂未识别到文字":"录音已暂停，正在补齐已录内容的文字"
                case .stopping:empty.stringValue="录音已结束，正在补齐文字并保存"
                default:
                    if currentCacheID != nil {
                        empty.stringValue=cachedTranscriptionComplete ? "本场没有识别到文字，可打开会议文件查看录音":"录音已保存，转写尚未完成"
                    } else {empty.stringValue="开始后，会议文字会出现在这里"}
                }
            }
        }
        let emptySaved=sequence.isEmpty && recoveredArchiveText==nil && currentCacheID != nil && !live
        emptyFilesButton?.isHidden = !emptySaved
        emptyTranscribeButton?.isHidden = !emptySaved || current || cachedTranscriptionComplete
        refreshEmptyMeetingActions()
        let startPrompt=choosing && phase.phase != .failed
        recordingTimeLabel?.stringValue=startPrompt ? "开始录音":phase.time
        recordingTimeLabel?.font=startPrompt ? .systemFont(ofSize:15,weight:.semibold):.monospacedDigitSystemFont(ofSize:21,weight:.semibold)
        recordingTimeLabel?.textColor=owner.phase.phase == .paused ? NSColor.white.withAlphaComponent(0.8):.white
        recordingActionCaption?.stringValue=action.title
        refreshAudioLevels()
        if phase.phase == .recording && audioLevelTimer==nil && !previewRenderOnly {
            audioLevelTimer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){[weak self] _ in self?.refreshAudioLevels();self?.historyReader?.refreshAudioLevels()}
        } else if phase.phase != .recording {audioLevelTimer?.invalidate();audioLevelTimer=nil;latestAudioLevels=[:]}
    }
}
