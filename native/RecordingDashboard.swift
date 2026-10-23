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
    override var intrinsicContentSize:NSSize {NSSize(width:180,height:40)}
    override init(frame:NSRect) {super.init(frame:frame);setAccessibilityElement(true);setAccessibilityRole(.levelIndicator)}
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    func show(rms:Double,peak:Double,status:String) {
        let value=rms.isFinite ? min(1,max(0,rms)):0
        if value==0 {samples=Array(repeating:0,count:48)}
        else if value != self.rms || peak != self.peak {samples.append(value);samples.removeFirst(max(0,samples.count-48))}
        self.rms=value;self.peak=peak.isFinite ? min(1,max(0,peak)):0;self.status=status;toolTip=name+" · "+status
        setAccessibilityLabel(name);setAccessibilityValue(status+(self.rms>0 ? "，\(Int(20*log10(self.rms)))分贝":""));needsDisplay=true
    }
    override func draw(_ dirtyRect:NSRect) {
        var caption=name+" · "+(rms>0 ? "\(Int(max(-60,20*log10(rms)))) dB" : status)
        let font=NSFont.systemFont(ofSize:10.5,weight:.regular),attrs:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:MeetingVisualStyle.muted]
        if (caption as NSString).size(withAttributes:attrs).width > bounds.width { caption = name }
        let size=(caption as NSString).size(withAttributes:attrs)
        (caption as NSString).draw(at:NSPoint(x:max(0,(bounds.width-size.width)/2),y:0),withAttributes:attrs)
        let plot=NSRect(x:3,y:17,width:max(1,bounds.width-6),height:22)
        if samples.allSatisfy({$0<=0}) {
            // Idle: one quiet hairline instead of a row of dots.
            MeetingVisualStyle.border.setFill();NSBezierPath(roundedRect:NSRect(x:plot.minX,y:plot.midY-0.5,width:plot.width,height:1),xRadius:0.5,yRadius:0.5).fill()
            return
        }
        let step=plot.width/CGFloat(samples.count),barWidth=min(2.5,max(1,step*0.55))
        for (i,value) in samples.enumerated() {
            let normalized=value>0 ? min(1,max(0,(20*log10(value)+60)/54)):0
            let h=max(1.5,CGFloat(normalized)*plot.height)
            (value>0 ? MeetingVisualStyle.accent.withAlphaComponent(0.35+0.65*Double(i)/48):NSColor.tertiaryLabelColor.withAlphaComponent(0.35)).setFill()
            NSBezierPath(roundedRect:NSRect(x:plot.minX+CGFloat(i)*step,y:plot.midY-h/2,width:barWidth,height:h),xRadius:barWidth/2,yRadius:barWidth/2).fill()
        }
        if peak>=0.99 { ("声音过响" as NSString).draw(at:NSPoint(x:0,y:bounds.height-10),withAttributes:[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.systemOrange]) }
    }
}

final class RecordingTransportSurface:NSVisualEffectView {
    override init(frame:NSRect) {
        super.init(frame:frame);material = .popover;blendingMode = .withinWindow;state = .active
        wantsLayer=true;layer?.cornerRadius=30;layer?.masksToBounds=true;layer?.borderWidth=0.5
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    override func updateLayer() {super.updateLayer();effectiveAppearance.performAsCurrentDrawingAppearance {self.layer?.borderColor=MeetingVisualStyle.border.cgColor}}
    override func layout() {super.layout();layer?.cornerRadius=min(30,bounds.height/2)}
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
        let row=stack(.horizontal,spacing:18);row.alignment = .centerY;row.distribution = .fill;row.translatesAutoresizingMaskIntoConstraints=false;surface.addSubview(row)
        let mic=RecordingLevelView(),computer=RecordingLevelView();mic.name="麦克风";computer.name="电脑声音";microphoneLevel=mic;computerLevel=computer
        mic.setContentHuggingPriority(.defaultLow,for:.horizontal);computer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let center=stack(.horizontal,spacing:12);center.alignment = .centerY
        let clock=label("00:00",size:16,weight:.semibold);clock.font = .monospacedDigitSystemFont(ofSize:16,weight:.semibold);clock.textColor=MeetingVisualStyle.ink;recordingTimeLabel=clock;center.addArrangedSubview(clock)
        center.addArrangedSubview(action)
        // The button title and tooltip already say what it does.
        let caption=label("开始录音",size:10.5);caption.textColor = .secondaryLabelColor;caption.isHidden=true;recordingActionCaption=caption
        row.addArrangedSubview(mic);row.addArrangedSubview(center);row.addArrangedSubview(computer)
        let preferred=surface.widthAnchor.constraint(equalToConstant:620);preferred.priority = .defaultLow
        NSLayoutConstraint.activate([surface.centerXAnchor.constraint(equalTo:container.centerXAnchor),surface.topAnchor.constraint(equalTo:container.topAnchor,constant:4),surface.bottomAnchor.constraint(equalTo:container.bottomAnchor,constant:-4),
                                     surface.widthAnchor.constraint(lessThanOrEqualTo:container.widthAnchor),preferred,
                                     row.leadingAnchor.constraint(equalTo:surface.leadingAnchor,constant:24),row.trailingAnchor.constraint(equalTo:surface.trailingAnchor,constant:-24),row.topAnchor.constraint(equalTo:surface.topAnchor,constant:8),row.bottomAnchor.constraint(equalTo:surface.bottomAnchor,constant:-8),
                                     mic.widthAnchor.constraint(equalTo:computer.widthAnchor),mic.heightAnchor.constraint(equalToConstant:40),computer.heightAnchor.constraint(equalToConstant:40)])
        return container
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
        switcher.isHidden = !canSelectRecordingMode
        let selectedLocal=switcher.selectedSegment==1
        let owner=isHistoryReader ? (workspaceOwner ?? self):self
        coarseStopButton?.isHidden = !hasRunningCoarseRefinement
        // An empty row would keep only its flexible spacer and swallow the window height.
        switcher.superview?.isHidden = switcher.isHidden && (coarseStopButton?.isHidden ?? true)
        recordingModeHint?.stringValue = owner.hasPendingTranscriptionWork ? "正在补齐已录文字":isHistoryReader ? (current ? "仅录音 · 未转写":cachedTranscriptionComplete ? "录音与文字已保存":"转写尚未完成") : selectedLocal ? "仅录音 · 只存本机，不上传":""
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
            heading.stringValue=text+(currentCacheID != nil || phase.elapsed>0 ? " · "+phase.time:"")
            heading.font = .systemFont(ofSize:12,weight:.regular)
            heading.textColor=phase.phase == .recording ? MeetingVisualStyle.accent:MeetingVisualStyle.muted
        }
        if sequence.isEmpty && recoveredArchiveText==nil {
            if showsMissingCredentialHint && currentCacheID==nil && !localOnlyMode {
                empty.stringValue="去设置里填写百炼密钥"
            } else if current || (phase.phase == .idle && localOnlyMode) {
                empty.stringValue=phase.phase == .recording ? "正在保存声音，下方波形显示收音状态":phase.phase == .paused ? "录音已暂停，声音保存在本机":currentCacheID != nil ? "录音已保存，右键会议选择“打开会议文件…”即可查看":"点击开始录音，声音将保存在本机"
            } else {
                switch phase.phase {
                case .recording:empty.stringValue="正在收音，识别出的文字会出现在这里"
                case .paused:
                    empty.stringValue=pausedTailStates.values.contains("pending") ? "录音已暂停，转写尚未完成；原音保存在本机":!pausedTailStates.isEmpty && !pausedTailStates.values.contains("processing") ? "录音已暂停，已录内容已转写；暂未识别到文字":"录音已暂停，正在补齐已录内容的文字"
                case .stopping:empty.stringValue="录音已结束，正在补齐文字并保存"
                default:
                    if currentCacheID != nil {
                        empty.stringValue=cachedTranscriptionComplete ? "本场没有识别到文字，右键会议选择“打开会议文件…”可查看录音":"录音已保存，转写尚未完成；右键会议可补转剩余录音或打开会议文件"
                    } else {empty.stringValue="开始后，会议文字会出现在这里"}
                }
            }
        }
        recordingTimeLabel?.stringValue=phase.time
        recordingActionCaption?.stringValue=action.title
        refreshAudioLevels()
        if phase.phase == .recording && audioLevelTimer==nil && !previewRenderOnly {
            audioLevelTimer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){[weak self] _ in self?.refreshAudioLevels();self?.historyReader?.refreshAudioLevels()}
        } else if phase.phase != .recording {audioLevelTimer?.invalidate();audioLevelTimer=nil;latestAudioLevels=[:]}
    }
}
