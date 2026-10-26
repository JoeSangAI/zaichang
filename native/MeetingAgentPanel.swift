import AppKit

/// A self-contained right-side assistant workspace. The host owns runtime and
/// persistence; this view only renders snapshots and emits protocol commands.
final class MeetingAgentPanel: NSView {
    typealias CommandHandler = (String, [String: Any]) -> Void

    private enum Tab: Int, CaseIterable {
        case assistant, overview, notes
        var title: String { ["助理", "概览", "笔记"][rawValue] }
    }

    var onCommand: CommandHandler?
    var onResize: ((CGFloat, Bool) -> Void)?
    var referenceBaseURL = URL(fileURLWithPath: NSHomeDirectory())
    private(set) var selectedTab: String = "助理"
    private var state: [String: Any] = [:]
    private var suppressSwitchAction = false
    private var statusHeight: NSLayoutConstraint!
    private let moreButton = NSButton(title: "", target: nil, action: nil)
    private let overviewStatus = NSTextField(labelWithString: "")
    private let overviewRefresh = NSButton()
    private var overviewEvidence: [String: String] = [:]
    private var overviewRenderKey: Data?
    private weak var notesView: NSView?
    private var messageCells: [String: MessageCell] = [:]
    private var requestViews: [String: MeetingAgentRequestView] = [:]
    private var draftWorkspace = ""
    private var drafts: [String: String] = [:]
    private var draftAliases: [String: String] = [:]

    private let tabs = MeetingAgentTabs()
    private let content = NSView()
    private let assistantPage = NSView()
    private let overviewPage = NSView()
    private let notesPage = NSView()
    private let statusLabel = NSTextField(labelWithString: "正在连接助理…")
    private let transcript = NSStackView()
    private let transcriptBottomSpacer = NSView()
    private let activityRow = NSStackView()
    private let activityContainer = NSView()
    private var activityHeight: NSLayoutConstraint!
    private let activitySpinner = NSProgressIndicator()
    private let activityLabel = NSTextField(labelWithString: "正在思考…")
    private let transcriptScroll = NSScrollView()
    private let proactiveSwitch = MeetingTintedSwitch()
    private let proactiveLabel = NSTextField(labelWithString: "旁听")
    private let resizeHandle = MeetingAgentResizeHandle()
    private let composer = NSTextView()
    private let composerScroll = NSScrollView()
    private let composerPlaceholder = NSTextField(labelWithString: "有什么想问的？")
    private let sendButton = AgentSendButton(title: "发送", target: nil, action: nil)
    private let overviewTextView = NSTextView()
    private let greeting = NSTextField(wrappingLabelWithString: "嗨，今天开什么会？\n可以先告诉我项目和目标，或让我查找相关资料。")
    private let notesPlaceholder = NSTextField(labelWithString: "会议笔记尚未接入。")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func installNotes(_ view: NSView) {
        if let previous = notesView, previous !== view { previous.removeFromSuperview() }
        notesView = view
        view.removeFromSuperview()
        notesPlaceholder.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        notesPage.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: notesPage.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: notesPage.trailingAnchor),
            view.topAnchor.constraint(equalTo: notesPage.topAnchor),
            view.bottomAnchor.constraint(equalTo: notesPage.bottomAnchor)
        ])
    }

    func apply(_ snapshot: [String: Any]) {

        state = snapshot
        renderOverview(snapshot["meeting_overview"] as? [String: Any] ?? [:])
        renderRuntimeStatus(snapshot)
        renderMessages(snapshot["messages"] as? [[String: Any]] ?? [])
        let enabled = snapshot["proactive"] as? Bool ?? false
        suppressSwitchAction = true
        proactiveSwitch.state = enabled ? .on : .off
        proactiveSwitch.needsDisplay = true
        suppressSwitchAction = false
    }

    /// Test seam: submits text through the same composer/send path as the UI.
    func submit(text: String) {
        composer.string = text
        composerPlaceholder.isHidden = !text.isEmpty
        sendMessage()
    }

    /// Test seam: switches tabs through the same state update as the segmented control.
    func chooseTab(_ title: String) {
        guard let tab = Tab.allCases.first(where: { $0.title == title }) else { return }
        showTab(tab)
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = MeetingVisualStyle.border.cgColor
        layer?.cornerRadius = 0
        translatesAutoresizingMaskIntoConstraints = false

        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(changeTab(_:))
        tabs.controlSize = .large
        tabs.font = .systemFont(ofSize: 14, weight: .medium)
        tabs.setAccessibilityLabel("助理工作区")
        addSubview(tabs)
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.isBordered = false
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多助理操作")
        moreButton.contentTintColor = MeetingVisualStyle.muted
        moreButton.target = self; moreButton.action = #selector(showMore)
        moreButton.setAccessibilityLabel("更多助理操作")
        addSubview(moreButton)

        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.onResize = { [weak self] width, persist in self?.onResize?(width, persist) }
        resizeHandle.setAccessibilityLabel("拖动调整助理面板宽度")
        addSubview(resizeHandle)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let divider=NSBox();divider.boxType = .separator;divider.translatesAutoresizingMaskIntoConstraints=false;addSubview(divider)
        NSLayoutConstraint.activate([divider.leadingAnchor.constraint(equalTo:leadingAnchor),divider.topAnchor.constraint(equalTo:topAnchor),divider.bottomAnchor.constraint(equalTo:bottomAnchor),divider.widthAnchor.constraint(equalToConstant:1)])
        let rule = NSBox(); rule.boxType = .separator; rule.translatesAutoresizingMaskIntoConstraints = false; addSubview(rule)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rule.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            tabs.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -10),
            tabs.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            tabs.heightAnchor.constraint(equalToConstant: 34),
            moreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            moreButton.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 24),
            moreButton.heightAnchor.constraint(equalToConstant: 28),
            resizeHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
            resizeHandle.topAnchor.constraint(equalTo: topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 8),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        [assistantPage, overviewPage, notesPage].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
            NSLayoutConstraint.activate([
                $0.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                $0.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                $0.topAnchor.constraint(equalTo: content.topAnchor),
                $0.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
        buildAssistantPage()
        buildOverviewPage()
        buildNotesPage()
        showTab(.assistant)
        addSubview(resizeHandle, positioned: .above, relativeTo: nil)
    }

    private func buildAssistantPage() {
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = MeetingVisualStyle.muted
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        assistantPage.addSubview(statusLabel)
        statusHeight = statusLabel.heightAnchor.constraint(equalToConstant: 0)

        proactiveLabel.font = .systemFont(ofSize: 11, weight: .regular)
        proactiveLabel.textColor = MeetingVisualStyle.muted
        proactiveLabel.translatesAutoresizingMaskIntoConstraints = false
        proactiveSwitch.translatesAutoresizingMaskIntoConstraints = false
        proactiveSwitch.target = self; proactiveSwitch.action = #selector(toggleProactive(_:))
        proactiveSwitch.setAccessibilityLabel("旁听")
        assistantPage.addSubview(proactiveLabel); assistantPage.addSubview(proactiveSwitch)

        transcript.orientation = .vertical; transcript.alignment = .leading
        activitySpinner.style = .spinning; activitySpinner.controlSize = .small
        activitySpinner.isIndeterminate = true
        activitySpinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        activitySpinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        activityLabel.font = .systemFont(ofSize: 12); activityLabel.textColor = MeetingVisualStyle.muted
        let stop = NSButton(title: "停止", target: self, action: #selector(cancelCurrentTask))
        stop.isBordered = false; stop.font = .systemFont(ofSize: 12)
        activityRow.orientation = .horizontal; activityRow.spacing = 8
        [activitySpinner, activityLabel, stop].forEach { activityRow.addArrangedSubview($0) }
        activityContainer.translatesAutoresizingMaskIntoConstraints = false
        activityRow.translatesAutoresizingMaskIntoConstraints = false
        assistantPage.addSubview(activityContainer); activityContainer.addSubview(activityRow)
        activityHeight = activityContainer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([activityHeight,
            activityRow.leadingAnchor.constraint(equalTo: activityContainer.leadingAnchor),
            activityRow.centerYAnchor.constraint(equalTo: activityContainer.centerYAnchor),
            activityRow.trailingAnchor.constraint(lessThanOrEqualTo: activityContainer.trailingAnchor)])
        transcript.spacing = 18
        transcript.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 22, right: 22)
        transcript.translatesAutoresizingMaskIntoConstraints = false
        let document = TranscriptDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        transcript.distribution = .fill
        transcriptBottomSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        transcriptBottomSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        transcript.addArrangedSubview(transcriptBottomSpacer); document.addSubview(transcript)
        transcriptScroll.documentView = document
        NSLayoutConstraint.activate([
            transcript.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            transcript.topAnchor.constraint(equalTo: document.topAnchor),
            transcript.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: transcriptScroll.contentView.widthAnchor)
        ])
        transcriptScroll.hasVerticalScroller = true; transcriptScroll.autohidesScrollers = true
        transcriptScroll.drawsBackground = false; transcriptScroll.borderType = .noBorder
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false
        assistantPage.addSubview(transcriptScroll)

        composer.font = .systemFont(ofSize: 14); composer.textColor = MeetingVisualStyle.ink
        composer.drawsBackground = false; composer.isRichText = false
        composer.isVerticallyResizable = true; composer.isHorizontallyResizable = false
        composer.minSize = NSSize(width: 0, height: 44)
        composer.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        composer.autoresizingMask = [.width]; composer.isAutomaticQuoteSubstitutionEnabled = false
        composer.textContainerInset = NSSize(width: 10, height: 8)
        composer.textContainer?.widthTracksTextView = true
        composer.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        composer.delegate = self
        composerScroll.documentView = composer; composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true; composerScroll.drawsBackground = false
        composerScroll.borderType = .noBorder; composerScroll.translatesAutoresizingMaskIntoConstraints = false
        composerPlaceholder.stringValue = "有什么想问的？"
        composerPlaceholder.font = .systemFont(ofSize: 14); composerPlaceholder.textColor = MeetingVisualStyle.faint
        composerPlaceholder.translatesAutoresizingMaskIntoConstraints = false

        let composerBox = NSView(); composerBox.translatesAutoresizingMaskIntoConstraints = false
        composerBox.wantsLayer = true; composerBox.layer?.cornerRadius = 14
        composerBox.layer?.borderWidth = 0.5; composerBox.layer?.borderColor = MeetingVisualStyle.border.cgColor
        assistantPage.addSubview(composerBox); composerBox.addSubview(composerScroll); composerBox.addSubview(composerPlaceholder)
        sendButton.title = ""; sendButton.bezelStyle = .regularSquare; sendButton.isBordered = false
        sendButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "发送")?.withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        sendButton.contentTintColor = .white; sendButton.wantsLayer = true
        sendButton.layer?.backgroundColor = MeetingVisualStyle.ink.cgColor; sendButton.layer?.cornerRadius = 15
        sendButton.target = self; sendButton.action = #selector(sendMessage)
        sendButton.toolTip = "发送 · 回车发送，Shift＋回车换行"; sendButton.setAccessibilityLabel("发送")
        sendButton.translatesAutoresizingMaskIntoConstraints = false; composerBox.addSubview(sendButton)
        let attach = NSButton(image: NSImage(systemSymbolName: "paperclip", accessibilityDescription: "添加参考文件")!, target: self, action: #selector(attachReference))
        attach.isBordered = false; attach.contentTintColor = MeetingVisualStyle.muted
        attach.translatesAutoresizingMaskIntoConstraints = false; composerBox.addSubview(attach)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: assistantPage.leadingAnchor, constant: 22),
            statusLabel.trailingAnchor.constraint(equalTo: assistantPage.trailingAnchor, constant: -22),
            statusLabel.topAnchor.constraint(equalTo: assistantPage.topAnchor, constant: 2), statusHeight,
            proactiveLabel.leadingAnchor.constraint(equalTo: assistantPage.leadingAnchor, constant: 22),
            proactiveLabel.centerYAnchor.constraint(equalTo: proactiveSwitch.centerYAnchor),
            proactiveSwitch.trailingAnchor.constraint(equalTo: assistantPage.trailingAnchor, constant: -20),
            proactiveSwitch.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            proactiveSwitch.widthAnchor.constraint(equalToConstant: 38),
            proactiveSwitch.heightAnchor.constraint(equalToConstant: 22),
            transcriptScroll.leadingAnchor.constraint(equalTo: assistantPage.leadingAnchor),
            transcriptScroll.trailingAnchor.constraint(equalTo: assistantPage.trailingAnchor),
            transcriptScroll.topAnchor.constraint(equalTo: proactiveSwitch.bottomAnchor),
            transcriptScroll.bottomAnchor.constraint(equalTo: activityContainer.topAnchor, constant: -8),
            activityContainer.leadingAnchor.constraint(equalTo: assistantPage.leadingAnchor, constant: 22),
            activityContainer.trailingAnchor.constraint(equalTo: assistantPage.trailingAnchor, constant: -22),
            activityContainer.bottomAnchor.constraint(equalTo: composerBox.topAnchor, constant: -6),
            composerBox.leadingAnchor.constraint(equalTo: assistantPage.leadingAnchor, constant: 16),
            composerBox.trailingAnchor.constraint(equalTo: assistantPage.trailingAnchor, constant: -16),
            composerBox.bottomAnchor.constraint(equalTo: assistantPage.bottomAnchor, constant: -18),
            composerBox.heightAnchor.constraint(equalToConstant: 100),
            composerScroll.leadingAnchor.constraint(equalTo: composerBox.leadingAnchor, constant: 5),
            composerScroll.trailingAnchor.constraint(equalTo: composerBox.trailingAnchor, constant: -5),
            composerScroll.topAnchor.constraint(equalTo: composerBox.topAnchor, constant: 5),
            composerScroll.heightAnchor.constraint(equalToConstant: 48),
            composerPlaceholder.leadingAnchor.constraint(equalTo: composerBox.leadingAnchor, constant: 16),
            composerPlaceholder.topAnchor.constraint(equalTo: composerBox.topAnchor, constant: 14),
            sendButton.trailingAnchor.constraint(equalTo: composerBox.trailingAnchor, constant: -12),
            sendButton.bottomAnchor.constraint(equalTo: composerBox.bottomAnchor, constant: -11),
            sendButton.widthAnchor.constraint(equalToConstant: 30), sendButton.heightAnchor.constraint(equalToConstant: 30),
            attach.leadingAnchor.constraint(equalTo: composerBox.leadingAnchor, constant: 10),
            attach.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            attach.widthAnchor.constraint(equalToConstant: 28), attach.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    @objc private func attachReference() {
        guard let window else { return }
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = true
        picker.allowsMultipleSelection = true; picker.prompt = "添加参考"
        picker.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let self else { return }
            let paths = picker.urls.map { $0.path }.joined(separator: "\n")
            self.composer.string += (self.composer.string.isEmpty ? "" : "\n") + paths
            self.composerPlaceholder.isHidden = true; window.makeFirstResponder(self.composer)
        }
    }

    @objc private func showMore() {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item); return item
        }
        let stop = item("停止回答", #selector(cancelCurrentTask)); stop.isEnabled = state["conversation_status"] as? String == "running"
        let recent = NSMenu(); for workspace in state["workspaces"] as? [[String:Any]] ?? [] {
            guard let id = workspace["id"] as? String else { continue }
            let item = NSMenuItem(title: workspace["title"] as? String ?? "会前对话", action: #selector(openRecentMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id; recent.addItem(item)
        }
        if !recent.items.isEmpty { let history = NSMenuItem(title: "最近对话", action: nil, keyEquivalent: ""); history.submenu = recent; menu.addItem(history) }
        menu.addItem(.separator()); let status = NSMenuItem(title: statusLabel.stringValue, action: nil, keyEquivalent: ""); menu.addItem(status)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.minY), in: moreButton)
    }
    @objc private func openRecentMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { onCommand?("open_workspace", ["workspace_id": id]) } }

    private func buildOverviewPage() {
        overviewTextView.isEditable = false
        overviewTextView.isSelectable = true
        overviewTextView.drawsBackground = false
        overviewTextView.isVerticallyResizable = true
        overviewTextView.isHorizontallyResizable = false
        overviewTextView.minSize = .zero
        overviewTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        overviewTextView.autoresizingMask = [.width]
        overviewTextView.textColor = MeetingVisualStyle.ink
        overviewTextView.font = .systemFont(ofSize: 14)
        overviewTextView.textContainerInset = NSSize(width: 18, height: 18)
        overviewTextView.textContainer?.widthTracksTextView = true
        overviewTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        overviewTextView.delegate = self
        overviewTextView.linkTextAttributes = [.foregroundColor: MeetingVisualStyle.faint]
        overviewStatus.font = .systemFont(ofSize: 11); overviewStatus.textColor = MeetingVisualStyle.muted
        overviewStatus.lineBreakMode = .byTruncatingTail; overviewStatus.translatesAutoresizingMaskIntoConstraints = false
        overviewPage.addSubview(overviewStatus)
        overviewRefresh.isBordered = false; overviewRefresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "更新概览")
        overviewRefresh.contentTintColor = MeetingVisualStyle.muted; overviewRefresh.target = self; overviewRefresh.action = #selector(refreshOverview)
        overviewRefresh.toolTip = "更新概览"; overviewRefresh.translatesAutoresizingMaskIntoConstraints = false
        overviewPage.addSubview(overviewRefresh)
        let scroll = NSScrollView()
        scroll.documentView = overviewTextView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        overviewPage.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: overviewPage.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: overviewPage.trailingAnchor),
            overviewStatus.leadingAnchor.constraint(equalTo: overviewPage.leadingAnchor, constant: 22),
            overviewStatus.trailingAnchor.constraint(equalTo: overviewRefresh.leadingAnchor, constant: -8),
            overviewStatus.topAnchor.constraint(equalTo: overviewPage.topAnchor, constant: 12),
            overviewRefresh.trailingAnchor.constraint(equalTo: overviewPage.trailingAnchor, constant: -18),
            overviewRefresh.centerYAnchor.constraint(equalTo: overviewStatus.centerYAnchor),
            overviewRefresh.widthAnchor.constraint(equalToConstant: 24), overviewRefresh.heightAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: overviewStatus.bottomAnchor, constant: 2),
            scroll.bottomAnchor.constraint(equalTo: overviewPage.bottomAnchor),
            overviewTextView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
    }

    private func buildNotesPage() {
        notesPlaceholder.textColor = MeetingVisualStyle.muted
        notesPlaceholder.font = .systemFont(ofSize: 13)
        notesPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        notesPage.addSubview(notesPlaceholder)
        NSLayoutConstraint.activate([
            notesPlaceholder.centerXAnchor.constraint(equalTo: notesPage.centerXAnchor),
            notesPlaceholder.centerYAnchor.constraint(equalTo: notesPage.centerYAnchor)
        ])
    }

    @objc private func refreshOverview() { onCommand?("overview", ["active": true, "refresh": true]) }

    private func renderOverview(_ overview: [String: Any]) {
        let key = try? JSONSerialization.data(withJSONObject: overview, options: [.sortedKeys])
        guard key != overviewRenderKey else { return }; overviewRenderKey = key
        let status = overview["status"] as? String ?? "inactive"
        let busy = ["queued", "running"].contains(status)
        let error = overview["error"] as? String ?? ""
        overviewStatus.stringValue = busy ? "正在整理会议内容…" : status == "failed" || status == "interrupted" ?
            (error == "overview_no_reliable_evidence" ? "原文待核实，暂不生成概览" : "暂时无法更新 · 可点击重试") :
            error == "overview_evidence_filtered" ? "缺少依据的判断已排除 · 请核对原文" :
            error == "overview_source_needs_review" ? "仅依据可用原文整理 · 部分片段待核实" :
            overview["stale"] as? Bool == true ? "会议有新内容 · 等待更新" : status == "ready" ? "根据本场会议整理" : "会议概览"
        if overview["stale"] as? Bool == true && !busy {
            let previous = overviewStatus.stringValue
            let freshness = "会议有新内容 · 等待更新"
            overviewStatus.stringValue = (previous == freshness || previous == "根据本场会议整理")
                ? freshness : "会议有新内容 · " + previous
        }
        overviewStatus.toolTip = error.isEmpty ? overviewStatus.stringValue : overviewStatus.stringValue + "\n" + error
        overviewRefresh.isEnabled = !busy
        let data = overview["data"] as? [String: Any] ?? [:]
        let rich = NSMutableAttributedString(string: "")
        overviewEvidence.removeAll()
        func paragraph(_ text: String, size: CGFloat = 14, weight: NSFont.Weight = .regular, color: NSColor = MeetingVisualStyle.ink, after: CGFloat = 10) {
            let style = NSMutableParagraphStyle(); style.lineSpacing = 5; style.paragraphSpacing = after
            rich.append(NSAttributedString(string: text + "\n", attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style]))
        }
        func evidence(_ item: [String: Any]) {
            let refs = item["evidence"] as? [[String: Any]] ?? []
            let quotes = refs.compactMap { $0["quote"] as? String }.filter { !$0.isEmpty }
            guard !quotes.isEmpty else { return }
            let id = String(overviewEvidence.count); overviewEvidence[id] = quotes.map { "“\($0)”" }.joined(separator: "\n\n")
            let style = NSMutableParagraphStyle(); style.paragraphSpacing = 14
            rich.append(NSAttributedString(string: "查看原话 ↗\n", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: MeetingVisualStyle.faint, .paragraphStyle: style, .link: URL(string: "zaichang-evidence://quote/\(id)")!]))
        }
        if let topic = data["current_topic"] as? [String: Any], let text = topic["text"] as? String, !text.isEmpty {
            paragraph("当前议题", size: 11, color: MeetingVisualStyle.muted, after: 6)
            paragraph(text, size: 19, weight: .semibold, after: 8); evidence(topic)
        }
        for (key, title) in [("discussion_points", "讨论要点"), ("decisions", "已定事项"), ("actions", "接下来"), ("open_questions", "待讨论")] {
            let items = data[key] as? [[String: Any]] ?? []
            guard !items.isEmpty else { continue }
            paragraph(title, size: 14, weight: .semibold, after: 10)
            for item in items {
                guard let text = item["text"] as? String, !text.isEmpty else { continue }
                paragraph(text, after: 4)
                let metadata = [item["owner"] as? String, item["deadline"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
                if !metadata.isEmpty { paragraph(metadata.joined(separator: " · "), size: 12, color: MeetingVisualStyle.muted, after: 4) }
                evidence(item)
            }
        }

        if rich.length == 0 {
            paragraph(busy ? "稍等，正在梳理议题和要点。" : status == "failed" || status == "interrupted" ? "尚未生成概览。" : "开始讨论后，这里会整理议题、要点和明确的下一步。", color: MeetingVisualStyle.muted)
        }
        let scroll = overviewTextView.enclosingScrollView?.contentView.bounds.origin ?? .zero
        overviewTextView.textStorage?.setAttributedString(rich)
        overviewTextView.enclosingScrollView?.contentView.scroll(to: scroll)
    }

    @objc private func changeTab(_ sender: MeetingAgentTabs) {
        guard let tab = Tab(rawValue: sender.selectedSegment) else { return }
        showTab(tab)
    }

    private func showTab(_ tab: Tab) {
        selectedTab = tab.title
        tabs.selectedSegment = tab.rawValue
        assistantPage.isHidden = tab != .assistant
        overviewPage.isHidden = tab != .overview
        notesPage.isHidden = tab != .notes
    }

    @objc private func cancelCurrentTask() {
        onCommand?("cancel", [:])
    }

    @objc private func toggleProactive(_ sender: NSSwitch) {
        guard !suppressSwitchAction else { return }
        let enabled = sender.state == .on
        sender.needsDisplay = true
        onCommand?("proactive", ["enabled": enabled])
    }

    @objc private func sendMessage() {
        let text = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var params: [String: Any] = ["text": text]
        composer.string = ""
        composerPlaceholder.isHidden = false
        // Cover connection/startup latency before the first service snapshot.
        state["awaiting_response"] = true; state["activity"] = "正在发送…"
        renderMessages(state["messages"] as? [[String: Any]] ?? [])
        onCommand?("send", params)
    }

    private func renderRuntimeStatus(_ snapshot: [String: Any]) {
        let status = snapshot["runtime_status"] as? String ?? "starting"
        let message = (snapshot["runtime_message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback: [String: String] = [
            "ready": "助理已就绪", "starting": "正在连接助理…", "unavailable": "助理暂不可用",
            "offline": "离线模式", "auth_required": "需要登录"
        ]
        statusLabel.stringValue = message.isEmpty ? (fallback[status] ?? "助理状态未知") : message
        statusLabel.textColor = MeetingVisualStyle.muted
        let interrupted = ["failed", "interrupted"].contains(snapshot["conversation_status"] as? String ?? "")
        if interrupted { statusLabel.stringValue = "助理已中断，发送消息或重新开启旁听可继续" }
        if snapshot["listening"] as? Bool == true { statusLabel.stringValue = "正在旁听" }
        let needsAttention = ["unavailable", "auth_required"].contains(status) || interrupted || snapshot["listening"] as? Bool == true
        statusLabel.isHidden = !needsAttention; statusHeight.constant = needsAttention ? 24 : 0
        moreButton.toolTip = statusLabel.stringValue
    }

    func activateWorkspace(_ id: String) {
        guard id != draftWorkspace else { return }
        drafts[draftWorkspace] = composer.string
        draftWorkspace = id
        composer.string = drafts[id] ?? ""
        composerPlaceholder.isHidden = !composer.string.isEmpty
    }

    func restoreDraft(_ text: String, workspace: String? = nil) {
        var id = workspace ?? draftWorkspace
        while let canonical = draftAliases[id] { id = canonical }
        let existing = id == draftWorkspace ? composer.string : (drafts[id] ?? "")
        // Preserve a new draft typed while the preceding send was in flight.
        let recovered = existing == text ? existing : text + (existing.isEmpty ? "" : "\n\n" + existing)
        drafts[id] = recovered
        if id == draftWorkspace {
            composer.string = recovered
            composerPlaceholder.isHidden = recovered.isEmpty
        }
    }

    var draftText: String { composer.string }

    /// A first bind can resolve a temporary ID to an existing meeting workspace.
    /// Carry the in-flight draft (and late failed sends) to that canonical ID.
    func resolveDraftWorkspace(from temporary: String, to canonical: String) {
        guard temporary != canonical else { return }
        let pending = draftWorkspace == temporary ? composer.string : (drafts[temporary] ?? "")
        draftAliases[temporary] = canonical
        drafts.removeValue(forKey: temporary)
        if draftWorkspace == temporary {
            draftWorkspace = canonical
            composer.string = drafts[canonical] ?? ""
        }
        if !pending.isEmpty { restoreDraft(pending, workspace: canonical) }
        composerPlaceholder.isHidden = !composer.string.isEmpty
    }

    private func renderMessages(_ messages: [[String: Any]]) {
        let newRequest = (state["requests"] as? [[String: Any]] ?? []).contains { requestViews[$0["id"] as? String ?? ""] == nil }
        let shouldFollow = newRequest || (transcriptScroll.documentView.map { $0.bounds.height - transcriptScroll.contentView.bounds.maxY < 60 } ?? true)
        let live = Set(messages.compactMap { $0["id"] as? String })
        for id in messageCells.keys.filter({ !live.contains($0) }) {
            guard let cell = messageCells[id] else { continue }
            if transcript.arrangedSubviews.contains(where:{$0 === cell}) {transcript.removeArrangedSubview(cell)}
            cell.removeFromSuperview()
            messageCells.removeValue(forKey: id)
        }
        var order: [NSView] = []
        if messages.isEmpty {greeting.font = .systemFont(ofSize:14);greeting.textColor=MeetingVisualStyle.muted;order.append(greeting)}
        for (index, message) in messages.enumerated() {
            let id = message["id"] as? String ?? "message-\(index)"
            let cell = messageCells[id] ?? MessageCell()
            if messageCells[id] == nil { messageCells[id] = cell }
            cell.referenceBaseURL = referenceBaseURL
            cell.apply(message)
            order.append(cell)
        }
        let requests = state["requests"] as? [[String: Any]] ?? []
        let requestIDs = Set(requests.compactMap { $0["id"] as? String })
        for id in requestViews.keys.filter({ !requestIDs.contains($0) }) { requestViews.removeValue(forKey: id) }
        for request in requests {
            guard let id = request["id"] as? String else { continue }
            let view = requestViews[id] ?? MeetingAgentRequestView(request: request)
            requestViews[id] = view
            view.onResponse = { [weak self] response in self?.onCommand?("respond", response) }
            order.append(view)
        }
        let busy = state["awaiting_response"] as? Bool == true
        activityContainer.isHidden = !busy; activityHeight.constant = busy ? 26 : 0
        if busy {
            activityLabel.stringValue = !requests.isEmpty ? "等待你确认" : state["conversation_status"] as? String == "cancelling" ? "正在停止…" : (state["activity"] as? String ?? "正在思考…")
            activitySpinner.isHidden = !requests.isEmpty
            if requests.isEmpty { activitySpinner.startAnimation(nil) } else { activitySpinner.stopAnimation(nil) }
        } else { activitySpinner.stopAnimation(nil) }
        order.append(transcriptBottomSpacer)
        reconcileStack(transcript, order: order)
        if shouldFollow {
            layoutSubtreeIfNeeded()
            if let document = transcriptScroll.documentView { transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - transcriptScroll.contentSize.height))) }
        }
    }

    private func reconcileStack(_ stack: NSStackView, order: [NSView]) {
        let current = stack.arrangedSubviews
        guard current.count != order.count || zip(current, order).contains(where: { $0 !== $1 }) else { return }
        for view in current where !order.contains(where:{$0 === view}) {stack.removeArrangedSubview(view);view.removeFromSuperview()}
        for (index,view) in order.enumerated() {
            if index >= stack.arrangedSubviews.count || stack.arrangedSubviews[index] !== view {
                if stack.arrangedSubviews.contains(where:{$0 === view}) {stack.removeArrangedSubview(view)}
                stack.insertArrangedSubview(view,at:index)
            }
            if stack === transcript, let cell = view as? MessageCell { cell.constrainWidth(to: transcript) }
            if stack === transcript, let request = view as? MeetingAgentRequestView { request.constrainWidth(to: transcript) }
        }
    }
}

/// Pending interactions are ephemeral and tied to one live turn. Keep fields
/// alive across progress snapshots so typing is never reset by a refresh.
private final class MeetingAgentRequestView: NSStackView {
    var onResponse: (([String: Any]) -> Void)?
    private let requestID: String
    private var fields: [String: NSTextField] = [:]
    private var requiredFields = Set<String>()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var widthConstraint: NSLayoutConstraint?
    init(request: [String: Any]) {
        requestID = request["id"] as? String ?? ""
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        let title = NSTextField(labelWithString: request["title"] as? String ?? "需要你确认")
        title.font = .systemFont(ofSize: 13, weight: .semibold); addArrangedSubview(title)
        if let detail = request["detail"] as? String, !detail.isEmpty {
            let label = NSTextField(wrappingLabelWithString: detail)
            label.font = .systemFont(ofSize: 12); label.isSelectable = true
            addArrangedSubview(label); label.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        for question in request["questions"] as? [[String: Any]] ?? [] {
            guard let id = question["id"] as? String else { continue }
            let required = question["required"] as? Bool ?? true
            if required { requiredFields.insert(id) }
            let label = NSTextField(wrappingLabelWithString: question["question"] as? String ?? "")
            label.font = .systemFont(ofSize: 13)
            addArrangedSubview(label); label.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            let input: NSTextField = question["isSecret"] as? Bool == true ? NSSecureTextField() : NSTextField()
            input.placeholderString = required ? "输入回答" : "选填"; fields[id] = input
            for option in question["options"] as? [[String: Any]] ?? [] {
                let button = MeetingAgentOptionButton(title: option["label"] as? String ?? "", target: nil, action: nil)
                button.field = input; button.target = button; button.action = #selector(MeetingAgentOptionButton.choose)
                button.bezelStyle = .inline; button.toolTip = option["description"] as? String
                button.lineBreakMode = .byTruncatingTail
                addArrangedSubview(button); button.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
            }
            addArrangedSubview(input); input.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        let accept = NSButton(title: fields.isEmpty ? "允许这次" : "提交", target: self, action: #selector(acceptRequest))
        let decline = NSButton(title: fields.isEmpty ? "拒绝" : "跳过", target: self, action: #selector(declineRequest))
        let actions = NSStackView(views: [accept, decline]); actions.spacing = 8
        addArrangedSubview(actions)
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .secondaryLabelColor
        addArrangedSubview(errorLabel); errorLabel.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func constrainWidth(to stack: NSStackView) {
        if widthConstraint == nil { widthConstraint = widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44) }
        widthConstraint?.isActive = true
    }
    @objc private func acceptRequest() {
        let answers = fields.mapValues { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !requiredFields.contains(where: { answers[$0, default: ""].isEmpty }) else {
            errorLabel.stringValue = "请填写回答"; errorLabel.isHidden = false; return
        }
        onResponse?(["request_id": requestID, "accepted": true, "answers": answers])
    }
    @objc private func declineRequest() { onResponse?(["request_id": requestID, "accepted": false]) }
}

private final class MeetingAgentOptionButton: NSButton {
    weak var field: NSTextField?
    @objc func choose() { field?.stringValue = title }
}

/// Keeps the native switch's activation and accessibility behavior while
/// drawing the requested green-on / neutral-gray-off treatment.
private final class AgentSendButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
}

private final class MeetingAgentTabs: NSControl {
    var selectedSegment = 0 { didSet { refresh() } }
    private var buttons: [NSButton] = []
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.cornerRadius = 9; layer?.backgroundColor = MeetingVisualStyle.faint.withAlphaComponent(0.10).cgColor
        let row = NSStackView(); row.orientation = .horizontal; row.distribution = .fillEqually; row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        for (i, title) in ["助理", "概览", "笔记"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(selectTab(_:)))
            button.tag = i; button.bezelStyle = .regularSquare; button.isBordered = false
            button.wantsLayer = true; button.layer?.cornerRadius = 7
            button.setAccessibilityLabel(title); row.addArrangedSubview(button); buttons.append(button)
            button.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        }
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),row.topAnchor.constraint(equalTo: topAnchor, constant: 2),row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func refresh() {
        for button in buttons {
            let selected = button.tag == selectedSegment
            button.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
            button.contentTintColor = selected ? MeetingVisualStyle.ink : MeetingVisualStyle.muted
            button.layer?.backgroundColor = selected ? NSColor.textBackgroundColor.cgColor : NSColor.clear.cgColor
            button.layer?.borderColor = MeetingVisualStyle.border.cgColor; button.layer?.borderWidth = selected ? 0.5 : 0
            button.setAccessibilityValue(selected ? "已选择" : "未选择")
        }
    }
    @objc private func selectTab(_ sender: NSButton) { selectedSegment = sender.tag; sendAction(action, to: target) }
}

private final class TranscriptDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class MeetingAgentResizeHandle: NSView {
    var onResize: ((CGFloat, Bool) -> Void)?
    private var initialMouseX: CGFloat = 0
    private var initialWidth: CGFloat = 0
    private var hovering = false
    private var dragging = false
    private var hoverTracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.splitter); setAccessibilityLabel("调整助理面板宽度")
        toolTip = "拖动调整助理面板宽度；方向键微调，双击恢复默认"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func accessibilityValue() -> Any? { NSNumber(value: Double(superview?.bounds.width ?? 370)) }
    override func accessibilityPerformIncrement() -> Bool { adjust(by: 12); return true }
    override func accessibilityPerformDecrement() -> Bool { adjust(by: -12); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking); hoverTracking = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true; NSCursor.resizeLeftRight.set() }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true; NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { dragging = false; onResize?(370, true); return }
        initialMouseX = event.locationInWindow.x
        initialWidth = superview?.bounds.width ?? 0
        dragging = true; needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let delta = event.locationInWindow.x - initialMouseX
        onResize?(initialWidth - delta, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onResize?(initialWidth - (event.locationInWindow.x - initialMouseX), true)
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func keyDown(with event: NSEvent) {
        if [123, 124].contains(event.keyCode) { adjust(by: event.keyCode == 123 ? 12 : -12) }
        else { super.keyDown(with: event) }
    }

    private func adjust(by amount: CGFloat) {
        onResize?((superview?.bounds.width ?? 370) + amount, true)
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = hovering || dragging || window?.firstResponder === self
        let color = highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.45) : MeetingVisualStyle.border.withAlphaComponent(0.72)
        color.setStroke()
        let rail = NSBezierPath()
        rail.lineWidth = highlighted ? 1.5 : 1
        rail.move(to: NSPoint(x: 4, y: 12)); rail.line(to: NSPoint(x: 4, y: bounds.height - 12)); rail.stroke()
        let center = NSPoint(x: 4, y: bounds.midY)
        MeetingVisualStyle.muted.withAlphaComponent(highlighted ? 0.92 : 0.58).setFill()
        for offset in [-5.0, 0, 5.0] {
            NSBezierPath(ovalIn: NSRect(x: center.x - 1, y: center.y + offset - 1, width: 2, height: 2)).fill()
        }
    }
}

/// Native NSSwitch retains tracking, keyboard and accessibility behavior. A
/// display-only child paints the app's green/gray treatment over system accent.
final class MeetingTintedSwitch: NSSwitch {
    var backgroundColor=NSColor.textBackgroundColor {didSet {surface.needsDisplay=true}}
    private lazy var surface=MeetingSwitchSurface(owner:self)
    override var state:NSControl.StateValue {didSet {surface.needsDisplay=true}}
    override var isEnabled:Bool {didSet {surface.needsDisplay=true}}
    override init(frame frameRect:NSRect) {
        super.init(frame:frameRect);focusRingType = .none
        surface.frame=bounds;surface.autoresizingMask=[.width,.height];addSubview(surface)
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    override func layout() {super.layout();surface.frame=bounds}
    override func viewDidChangeEffectiveAppearance() {super.viewDidChangeEffectiveAppearance();surface.needsDisplay=true}
}
private final class MeetingSwitchSurface:NSView {
    weak var owner:MeetingTintedSwitch?
    init(owner:MeetingTintedSwitch) {self.owner=owner;super.init(frame:.zero);setAccessibilityElement(false)}
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    override func draw(_ dirtyRect:NSRect) {
        guard let owner,bounds.width>0,bounds.height>0 else{return}
        owner.backgroundColor.setFill();NSBezierPath(rect:bounds).fill()
        let track=bounds.insetBy(dx:1,dy:2),active=owner.state == .on
        let color=active ? NSColor.systemGreen:NSColor(calibratedWhite:0.78,alpha:1)
        color.withAlphaComponent(owner.isEnabled ? 1:0.4).setFill()
        NSBezierPath(roundedRect:track,xRadius:track.height/2,yRadius:track.height/2).fill()
        let diameter=max(1,track.height-4)
        let x=active ? track.maxX-diameter-2:track.minX+2
        NSColor.white.setFill();NSBezierPath(ovalIn:NSRect(x:x,y:track.minY+2,width:diameter,height:diameter)).fill()
    }
}

extension MeetingAgentPanel: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if textView === overviewTextView, let url = link as? URL, url.isFileURL {
            MeetingAssistantLinks.open(url) { [weak self] error in
                if let error { self?.overviewStatus.stringValue = error }
            }
            return true
        }
        guard textView === overviewTextView, let url = link as? URL, url.scheme == "zaichang-evidence",
              let quote = overviewEvidence[url.lastPathComponent] else { return false }
        let popover = NSPopover(), controller = NSViewController()
        let label = NSTextField(wrappingLabelWithString: quote)
        label.font = .systemFont(ofSize: 13); label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100)); controller.view.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 14), label.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -14), label.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 14), label.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -14), controller.view.widthAnchor.constraint(equalToConstant: 300)])
        popover.contentViewController = controller; popover.behavior = .transient
        let screen = textView.firstRect(forCharacterRange: NSRange(location: charIndex, length: 1), actualRange: nil)
        let rect = textView.convert(textView.window?.convertFromScreen(screen) ?? .zero, from: nil)
        popover.show(relativeTo: rect, of: textView, preferredEdge: .minX)
        return true
    }
    func textDidChange(_ notification: Notification) {
        composerPlaceholder.isHidden = !composer.string.isEmpty
    }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
        if commandSelector == #selector(insertNewline(_:)) { sendMessage(); return true }
        return false
    }
}

private final class MessageCell: NSView {
    private var transcriptWidthConstraint: NSLayoutConstraint?
    private let bubble = NSView()
    private let body = MeetingMarkdownTextView(frame: .zero)
    private let detail = NSTextField(labelWithString: "")
    private let files = NSStackView()
    var referenceBaseURL = URL(fileURLWithPath: NSHomeDirectory())
    private var renderedText: String?
    private var renderedPlain = false
    private var renderedBasePath = ""
    private var inset: NSLayoutConstraint!
    private var userInset: NSLayoutConstraint!
    private var userWidth: NSLayoutConstraint!
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bubble.translatesAutoresizingMaskIntoConstraints = false; bubble.wantsLayer = true; bubble.layer?.cornerRadius = 14
        addSubview(bubble)
        body.font = .systemFont(ofSize: 14); body.textColor = MeetingVisualStyle.ink
        detail.font = .systemFont(ofSize: 10); detail.textColor = MeetingVisualStyle.faint
        files.orientation = .vertical; files.alignment = .leading; files.spacing = 16
        let stack = NSStackView(views: [body, files, detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; bubble.addSubview(stack)
        body.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true
        detail.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true
        files.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        files.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        inset = bubble.leadingAnchor.constraint(equalTo: leadingAnchor)
        userInset = bubble.leadingAnchor.constraint(greaterThanOrEqualTo:leadingAnchor,constant:32)
        userWidth=bubble.widthAnchor.constraint(equalToConstant:56);userWidth.priority = NSLayoutConstraint.Priority(750)
        NSLayoutConstraint.activate([inset, bubble.trailingAnchor.constraint(equalTo: trailingAnchor), bubble.topAnchor.constraint(equalTo: topAnchor), bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func constrainWidth(to stack: NSStackView) {
        if let constraint = transcriptWidthConstraint { constraint.isActive = true; return }
        transcriptWidthConstraint = widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44)
        transcriptWidthConstraint?.isActive = true
    }
    func apply(_ message: [String: Any]) {
        let user = message["role"] as? String == "user"
        let text = message["text"] as? String ?? ""
        if renderedText != text || renderedPlain != user || renderedBasePath != referenceBaseURL.path {
            for view in files.arrangedSubviews { files.removeArrangedSubview(view); view.removeFromSuperview() }
            let rich = MeetingMarkdown.render(user ? text : "", plain: user)
            body.apply(rich); body.isHidden = !user || text.isEmpty
            if user {
                var seen = Set<String>()
                for ref in MeetingAssistantLinks.references(in: text) {
                    guard let url = MeetingAssistantLinks.localURL(ref.target, base: referenceBaseURL), seen.insert(url.path).inserted else { continue }
                    let row = MeetingAssistantFileRow(label: ref.label, url: url)
                    files.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: files.widthAnchor).isActive = true
                }
            } else {
                let content = MeetingAssistantLinks.content(in: text, base: referenceBaseURL)
                let hasImages = content.contains { if case .file(_, let url) = $0 { return MeetingAssistantLinks.isBitmap(url) }; return false }
                var attachments: [MeetingAssistantFileRow] = []
                for part in content {
                    let view: NSView
                    switch part {
                    case .text(let prose):
                        let paragraph = MeetingMarkdownTextView(frame: .zero)
                        paragraph.apply(MeetingMarkdown.render(prose, plain: false)); view = paragraph
                    case .file(let label, let url):
                        let row = MeetingAssistantFileRow(label: label, url: url)
                        if hasImages && !MeetingAssistantLinks.isBitmap(url) { attachments.append(row); continue }
                        view = row
                    }
                    files.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: files.widthAnchor).isActive = true
                }
                if !attachments.isEmpty {
                    let disclosure = MeetingAssistantAttachments(rows: attachments)
                    files.addArrangedSubview(disclosure); disclosure.widthAnchor.constraint(equalTo: files.widthAnchor).isActive = true
                }
            }
            renderedText = text
            renderedPlain = user
            renderedBasePath = referenceBaseURL.path
            // Only user bubbles need a preferred width. Measuring a table
            // without a text-container width on every status update is costly.
            if user { userWidth.constant = max(56, ceil(rich.size().width) + 24) }
        }
        files.isHidden = files.arrangedSubviews.isEmpty
        let status = message["status"] as? String ?? ""
        let failed = ["failed", "interrupted"].contains(status)
        detail.stringValue = failed ? "发送未完成" : ""
        detail.isHidden = detail.stringValue.isEmpty
        inset.isActive = !user; userInset.isActive = user; inset.constant = -12
        userWidth.isActive=user
        bubble.layer?.backgroundColor = user ? MeetingVisualStyle.quietFill.cgColor : NSColor.clear.cgColor
        setAccessibilityLabel((user ? "你：" : "助理：") + text)
    }
}
