import AppKit

/// A self-contained right-side assistant workspace. The host owns runtime and
/// persistence; this view only renders snapshots and emits protocol commands.
final class MeetingAgentPanel: NSView {
    typealias CommandHandler = (String, [String: Any]) -> Void

    private enum Tab: Int, CaseIterable {
        case overview, assistant, notes
        var title: String { ["概览", "助理", "笔记"][rawValue] }
    }

    var onCommand: CommandHandler?
    var onResize: ((CGFloat, Bool) -> Void)?
    /// 导出纪要／原文／录音 for the meeting on screen, built by the workspace that owns those files.
    var exportItems: (() -> [NSMenuItem])?
    private var listCloseToStatus: NSLayoutConstraint!
    private var listBelowPresence: NSLayoutConstraint!
    var referenceBaseURL = URL(fileURLWithPath: NSHomeDirectory())
    private(set) var selectedTab: String = "概览"
    private(set) var state: [String: Any] = [:]
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
    /// 概览 · 助理 · 笔记 and 「···」, shown in the title bar row above the panel.
    let headerBar = NSView()
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
    private let proactiveLabel = NSTextField(labelWithString: "旁听已关闭")
    private let presenceCard = MeetingListeningCard()
    /// What the presence card last saw, so a new name or a newly finished task shows once.
    private var presenceWake: Int?, presenceFinished: String?
    private var heardAt: Date?, finishedAt: Date?, finishedTitle = ""
    private var presenceRefresh: DispatchWorkItem?
    private var workCards: [String: MeetingWorkCard] = [:]
    private let resizeHandle = MeetingAgentResizeHandle()
    private let composer = MeetingComposerTextView()
    private let composerScroll = NSScrollView()
    private let composerPlaceholder = NSTextField(labelWithString: "问小满，或直接在会上交办")
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
        let name = AssistantProfile.name
        composerPlaceholder.stringValue = "问\(name)，或直接在会上交办"
        let tools = snapshot["engine"] as? String != "bailian"
        presenceCard.isHidden = !tools
        listBelowPresence.isActive = tools; listCloseToStatus.isActive = !tools
        renderPresence(snapshot, enabled: enabled, name: name)
    }

    private func refreshPresence(after seconds: TimeInterval) {
        presenceRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.renderPresence(self.state, enabled: self.state["proactive"] as? Bool ?? false, name: AssistantProfile.name)
        }
        presenceRefresh = item; DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, seconds), execute: item)
    }

    /// The listening card follows one call through: heard → on it → done.
    private func renderPresence(_ snapshot: [String: Any], enabled: Bool, name: String) {
        let now = Date()
        let wake = (snapshot["wake"] as? [String: Any])?["serial"] as? Int ?? 0
        if wake != presenceWake { if presenceWake != nil && wake > 0 { heardAt = now; finishedAt = nil }; presenceWake = wake }
        let finished = snapshot["finished"] as? [String: Any]
        let finishedID = finished?["id"] as? String ?? ""
        if finishedID != presenceFinished {
            if presenceFinished != nil, finished?["status"] as? String == "completed" {
                finishedAt = now; finishedTitle = finished?["title"] as? String ?? ""
            }
            presenceFinished = finishedID
        }
        let work = snapshot["work"] as? [[String: Any]] ?? []
        let heard = heardAt.map { now.timeIntervalSince($0) < 8 } ?? false
        let done = finishedAt.map { now.timeIntervalSince($0) < 20 } ?? false
        if !enabled {
            presenceCard.show(on: false, title: "旁听已关闭", detail: "开启后，会上叫「\(name)」就能交办")
        } else if let latest = work.last {
            let activity = (latest["activity"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            presenceCard.show(on: true, title: "收到：" + (latest["title"] as? String ?? ""),
                              detail: (activity.isEmpty ? "正在做" : activity) + (work.count > 1 ? " · 共 \(work.count) 件" : ""), busy: true)
        } else if heard {
            presenceCard.show(on: true, title: "听到了", detail: "\(name)在想怎么帮你", busy: true)
            refreshPresence(after: 8.1 - now.timeIntervalSince(heardAt ?? now))
        } else if done {
            presenceCard.show(on: true, title: "做好了：" + finishedTitle, detail: "结果在下面", busy: false)
            refreshPresence(after: 20.1 - now.timeIntervalSince(finishedAt ?? now))
        } else {
            presenceCard.show(on: true, title: "\(name)正在旁听", detail: "会上叫「\(name)」就能交办")
        }
    }

    /// Test seam: submits text through the same composer/send path as the UI.
    func submit(text: String) {
        composer.string = text
        composerPlaceholder.isHidden = !text.isEmpty
        sendMessage()
    }

    /// Test seam: composes uncommitted input-method text and reports whether the hint was hidden meanwhile.
    func composeMarkedTextForChecks(_ text: String) -> Bool {
        composer.string = ""; composerPlaceholder.isHidden = false
        composer.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let hidden = composerPlaceholder.isHidden
        composer.unmarkText(); composer.string = ""; composerPlaceholder.isHidden = false
        return hidden
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
        headerBar.addSubview(tabs)
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.isBordered = false
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "导出和助理")
        moreButton.contentTintColor = MeetingVisualStyle.muted
        moreButton.target = self; moreButton.action = #selector(showMore)
        moreButton.setAccessibilityLabel("导出和助理")
        headerBar.addSubview(moreButton)
        // The tabs and 「···」 sit in the window's title bar row, over this panel; the workspace hosts `headerBar` there.
        headerBar.translatesAutoresizingMaskIntoConstraints = false

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
            rule.topAnchor.constraint(equalTo: topAnchor, constant: MeetingVisualStyle.chromeHeight - 1),
            headerBar.heightAnchor.constraint(equalToConstant: MeetingVisualStyle.chromeHeight - 8),
            tabs.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 14),
            tabs.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -10),
            tabs.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            tabs.heightAnchor.constraint(equalToConstant: MeetingVisualStyle.chromeHeight - 8),
            moreButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -2),
            moreButton.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 24),
            moreButton.heightAnchor.constraint(equalToConstant: 28),
            resizeHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
            resizeHandle.topAnchor.constraint(equalTo: topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 8),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor, constant: MeetingVisualStyle.chromeHeight + 2),
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
        showTab(.overview)
        addSubview(resizeHandle, positioned: .above, relativeTo: nil)
    }

    private func buildAssistantPage() {
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = MeetingVisualStyle.muted
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        assistantPage.addSubview(statusLabel)
        statusHeight = statusLabel.heightAnchor.constraint(equalToConstant: 0)

        // Listening is a presence, not a settings row: one card with its own switch.
        proactiveLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        proactiveLabel.textColor = MeetingVisualStyle.ink
        proactiveSwitch.target = self; proactiveSwitch.action = #selector(toggleProactive(_:))
        proactiveSwitch.setAccessibilityLabel("旁听")
        presenceCard.install(title: proactiveLabel, toggle: proactiveSwitch)
        // Listening needs Codex's tools: without them the card isn't there at all.
        listBelowPresence = transcriptScroll.topAnchor.constraint(equalTo: presenceCard.bottomAnchor, constant: 4)
        listCloseToStatus = transcriptScroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4)
        presenceCard.translatesAutoresizingMaskIntoConstraints = false
        assistantPage.addSubview(presenceCard)

        transcript.orientation = .vertical; transcript.alignment = .leading
        activitySpinner.style = .spinning; activitySpinner.controlSize = .small
        activitySpinner.isIndeterminate = true
        activitySpinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        activitySpinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        activityLabel.font = .systemFont(ofSize: 12); activityLabel.textColor = MeetingVisualStyle.muted
        activityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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

        composer.font = MeetingVisualStyle.textFont(14); composer.textColor = MeetingVisualStyle.ink
        composer.drawsBackground = false; composer.isRichText = false
        composer.isVerticallyResizable = true; composer.isHorizontallyResizable = false
        composer.minSize = NSSize(width: 0, height: 44)
        composer.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        composer.autoresizingMask = [.width]; composer.isAutomaticQuoteSubstitutionEnabled = false
        composer.textContainerInset = NSSize(width: 10, height: 8)
        composer.textContainer?.widthTracksTextView = true
        composer.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        composer.delegate = self
        // Input-method composition sends no textDidChange; hide the hint as soon as it starts.
        composer.onMarkedTextChange = { [weak self] in
            guard let self else { return }
            self.composerPlaceholder.isHidden = !self.composer.string.isEmpty || self.composer.hasMarkedText()
        }
        composerScroll.documentView = composer; composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true; composerScroll.drawsBackground = false
        composerScroll.borderType = .noBorder; composerScroll.translatesAutoresizingMaskIntoConstraints = false
        composerPlaceholder.stringValue = "问\(AssistantProfile.name)，或直接在会上交办"
        composerPlaceholder.font = .systemFont(ofSize: 14); composerPlaceholder.textColor = MeetingVisualStyle.muted
        composerPlaceholder.translatesAutoresizingMaskIntoConstraints = false

        let composerBox = NSView(); composerBox.translatesAutoresizingMaskIntoConstraints = false
        composerBox.wantsLayer = true; composerBox.layer?.cornerRadius = 14
        composerBox.layer?.borderWidth = 0.5; composerBox.layer?.borderColor = MeetingVisualStyle.border.cgColor
        assistantPage.addSubview(composerBox); composerBox.addSubview(composerScroll); composerBox.addSubview(composerPlaceholder)
        sendButton.title = ""; sendButton.bezelStyle = .regularSquare; sendButton.isBordered = false
        sendButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "发送")?.withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        sendButton.contentTintColor = .white; sendButton.wantsLayer = true
        sendButton.layer?.backgroundColor = MeetingVisualStyle.charcoal.cgColor; sendButton.layer?.cornerRadius = 15
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
            presenceCard.leadingAnchor.constraint(equalTo: assistantPage.leadingAnchor, constant: 16),
            presenceCard.trailingAnchor.constraint(equalTo: assistantPage.trailingAnchor, constant: -16),
            presenceCard.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            transcriptScroll.leadingAnchor.constraint(equalTo: assistantPage.leadingAnchor),
            transcriptScroll.trailingAnchor.constraint(equalTo: assistantPage.trailingAnchor),
            listBelowPresence,
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
        let menu = NSMenu(); menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item); return item
        }
        // Exports first; stopping an answer is the 「停止」 beside the answer itself.
        for entry in exportItems?() ?? [] { menu.addItem(entry) }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let recent = NSMenu(); for workspace in state["workspaces"] as? [[String:Any]] ?? [] {
            guard let id = workspace["id"] as? String else { continue }
            let item = NSMenuItem(title: workspace["title"] as? String ?? "会前对话", action: #selector(openRecentMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id; recent.addItem(item)
        }
        if !recent.items.isEmpty { let history = NSMenuItem(title: "最近对话", action: nil, keyEquivalent: ""); history.submenu = recent; menu.addItem(history) }
        _ = item("助理名字…", #selector(renameAssistant))
        menu.addItem(.separator()); let status = NSMenuItem(title: statusLabel.stringValue, action: nil, keyEquivalent: ""); status.isEnabled = false; menu.addItem(status)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.minY), in: moreButton)
    }
    @objc private func renameAssistant() {
        let alert = NSAlert(); alert.messageText = "给助理起个名字"
        alert.informativeText = "界面里会这样称呼它，会上叫这个名字交办，它也知道是在叫自己。留空恢复默认「\(AssistantProfile.defaultName)」。"
        let field = NSTextField(string: AssistantProfile.name); field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        field.placeholderString = AssistantProfile.defaultName; field.setAccessibilityLabel("助理名字")
        alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.isEmpty || AssistantProfile.validated(raw) != nil else {
                self?.statusLabel.stringValue = "名字最多 \(AssistantProfile.maxNameLength) 个字，且不能含换行"; return
            }
            do { try AssistantProfile.save(name: raw) } catch { self?.statusLabel.stringValue = "名字没能保存，请重试" }
            if let self { self.apply(self.state) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: apply) } else { apply(alert.runModal()) }
    }
    /// Who said a transcript line, by the overview's segment ID; set by the bridge.
    var speakerOfSegment: ((String) -> String?)?
    /// The time shown beside an agenda entry, as the transcript shows it.
    var timeOfSegment: ((String) -> String?)?
    /// Scrolls the transcript to where a segment is.
    var revealSegment: ((String) -> Void)?
    /// Whether this meeting is being recorded now: the last agenda entry is then the one under way.
    var isLive: (() -> Bool)?
    /// Each speaker's share of the talking, largest first; anyone not yet named is `unknownSpeaker`.
    var speakingShare: (() -> [(String, Double)])?
    static let unknownSpeaker = "未确认"
    var overviewTextForChecks: String { overviewTextView.string }
    @objc private func openRecentMenu(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { onCommand?("open_workspace", ["workspace_id": id]) } }

    private func buildOverviewPage() {
        // Cards are text blocks, which only TextKit 1 draws; switch while the view is empty.
        _ = overviewTextView.layoutManager
        overviewTextView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: overviewTextView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.renderOverview(self.state["meeting_overview"] as? [String: Any] ?? [:]) }
        }
        overviewTextView.isEditable = false
        overviewTextView.isSelectable = true
        overviewTextView.drawsBackground = false
        overviewTextView.isVerticallyResizable = true
        overviewTextView.isHorizontallyResizable = false
        overviewTextView.minSize = .zero
        overviewTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        overviewTextView.autoresizingMask = [.width]
        overviewTextView.textColor = MeetingVisualStyle.ink
        overviewTextView.font = MeetingVisualStyle.textFont(14)
        overviewTextView.textContainerInset = NSSize(width: 18, height: 18)
        overviewTextView.textContainer?.widthTracksTextView = true
        overviewTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        overviewTextView.delegate = self
        // Each item is its own link to the words behind it: same colour as the text, a hand under the pointer.
        overviewTextView.linkTextAttributes = [.underlineStyle: 0, .cursor: NSCursor.pointingHand]
        overviewStatus.font = .systemFont(ofSize: 11); overviewStatus.textColor = MeetingVisualStyle.muted
        overviewStatus.lineBreakMode = .byTruncatingTail; overviewStatus.translatesAutoresizingMaskIntoConstraints = false
        overviewPage.addSubview(overviewStatus)
        overviewRefresh.isBordered = false; overviewRefresh.bezelStyle = .inline
        overviewRefresh.attributedTitle = NSAttributedString(string: "重新整理", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.linkColor])
        overviewRefresh.target = self; overviewRefresh.action = #selector(refreshOverview); overviewRefresh.setAccessibilityLabel("重新整理概览")
        overviewRefresh.toolTip = "按目前的原文重新整理概览"; overviewRefresh.translatesAutoresizingMaskIntoConstraints = false
        overviewRefresh.setContentHuggingPriority(.required, for: .horizontal); overviewRefresh.setContentCompressionResistancePriority(.required, for: .horizontal)
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
            overviewRefresh.heightAnchor.constraint(equalToConstant: 24),
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

    static let readyHint = "点任意一条可看原话"
    private func renderOverview(_ overview: [String: Any]) {
        // Cards and the share bar are laid out for the panel's width, so a new width redraws them.
        let lineWidth = floor((overviewTextView.textContainer?.size.width ?? 300) - 2 * (overviewTextView.textContainer?.lineFragmentPadding ?? 5))
        let key = try? JSONSerialization.data(withJSONObject: ["overview": overview, "live": isLive?() ?? false, "width": lineWidth], options: [.sortedKeys])
        guard key != overviewRenderKey else { return }; overviewRenderKey = key
        let status = overview["status"] as? String ?? "inactive"
        let busy = ["queued", "running"].contains(status)
        let error = overview["error"] as? String ?? ""
        overviewStatus.stringValue = busy ? "正在整理会议内容…" : status == "failed" || status == "interrupted" ?
            (error == "overview_no_reliable_evidence" ? "原文待核实，暂不生成概览" :
             error == "overview_key_missing" ? "去设置里填写百炼密钥后可用" :
             error == "overview_key_rejected" ? "百炼密钥无效或账户欠费 · 去设置检查" :
             error == "overview_content_rejected" ? "百炼拒绝处理这段内容，概览未更新" : "暂时无法更新 · 可点击重试") :
            error == "overview_evidence_filtered" ? "缺少依据的判断已排除 · 请核对原文" :
            error == "overview_source_needs_review" ? "仅依据可用原文整理 · 部分片段待核实" :
            overview["stale"] as? Bool == true ? "会议有新内容 · 等待更新" : status == "ready" ? Self.readyHint : "会议概览"
        if overview["stale"] as? Bool == true && !busy {
            let previous = overviewStatus.stringValue
            let freshness = "会议有新内容 · 等待更新"
            overviewStatus.stringValue = (previous == freshness || previous == Self.readyHint)
                ? freshness : "会议有新内容 · " + previous
        }
        overviewStatus.toolTip = error.isEmpty ? overviewStatus.stringValue : overviewStatus.stringValue + "\n" + error
        overviewRefresh.isEnabled = !busy
        let data = overview["data"] as? [String: Any] ?? [:]
        let rich = NSMutableAttributedString(string: "")
        overviewEvidence.removeAll()
        func paragraph(_ text: String, size: CGFloat = 14, weight: NSFont.Weight = .regular, color: NSColor = MeetingVisualStyle.ink, before: CGFloat = 0, after: CGFloat = 10) {
            let style = NSMutableParagraphStyle(); style.lineSpacing = 4; style.paragraphSpacingBefore = before; style.paragraphSpacing = after
            rich.append(NSAttributedString(string: text + "\n", attributes: [.font: MeetingVisualStyle.textFont(size, weight: weight), .foregroundColor: color, .paragraphStyle: style]))
        }
        // Clicking anywhere on an item shows the words it came from; no extra glyph to decode.
        func linkEvidence(_ item: [String: Any], from start: Int) {
            let refs = item["evidence"] as? [[String: Any]] ?? []
            let quotes = refs.compactMap { $0["quote"] as? String }.filter { !$0.isEmpty }
            guard !quotes.isEmpty, rich.length > start else { return }
            let id = String(overviewEvidence.count); overviewEvidence[id] = quotes.map { "“\($0)”" }.joined(separator: "\n\n")
            rich.addAttributes([.link: URL(string: "zaichang-evidence://quote/\(id)")!, .toolTip: "查看原话"], range: NSRange(location: start, length: rich.length - start))
        }
        // Read top to bottom like the mainstream meeting tools: the gist, the agenda in time order,
        // then what was decided, who does what, what is still open, and (after the meeting) who spoke.
        func keyword(_ raw: String) -> (String, String) {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = text.firstIndex(where: { $0 == "：" || $0 == ":" }),
                  (2...12).contains(text.distance(from: text.startIndex, to: colon)) else { return ("", text) }
            return (String(text[..<colon]), String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        func header(_ title: String, _ count: Int?) {
            paragraph(count.map { "\(title)  \($0)" } ?? title, size: 12, weight: .semibold, color: MeetingVisualStyle.quietAccent, before: rich.length == 0 ? 0 : 16, after: 6)
        }
        func items(_ key: String) -> [[String: Any]] { (data[key] as? [[String: Any]] ?? []).filter { !(($0["text"] as? String) ?? "").isEmpty } }
        let ink = MeetingVisualStyle.ink, muted = MeetingVisualStyle.muted
        if let summary = data["summary"] as? [String: Any], let text = summary["text"] as? String, !text.isEmpty {
            let style = NSMutableParagraphStyle(); style.lineSpacing = 4; style.paragraphSpacing = 4
            let start = rich.length
            rich.append(NSAttributedString(string: text, attributes: [.font: MeetingVisualStyle.textFont(16, weight: .semibold), .foregroundColor: ink, .paragraphStyle: style]))
            linkEvidence(summary, from: start)
            rich.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
        }
        let agenda = items("agenda"), live = isLive?() ?? false
        if !agenda.isEmpty {
            header("议程", agenda.count)
            for (index, item) in agenda.enumerated() {
                let (title, gist) = keyword(item["text"] as? String ?? "")
                let current = live && index == agenda.count - 1
                let first = (item["evidence"] as? [[String: Any]])?.first?["segment_id"] as? String
                let style = NSMutableParagraphStyle(); style.lineSpacing = 2; style.paragraphSpacing = 1
                style.headIndent = 18; style.tabStops = [NSTextTab(textAlignment: .left, location: 18)]
                rich.append(NSAttributedString(string: (current ? "●" : "○") + "\t", attributes: [.font: MeetingVisualStyle.textFont(11), .foregroundColor: current ? MeetingVisualStyle.accent : MeetingVisualStyle.faint, .paragraphStyle: style]))
                let start = rich.length
                if let first, let time = timeOfSegment?(first) {
                    rich.append(NSAttributedString(string: time + "  ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: muted, .paragraphStyle: style]))
                }
                rich.append(NSAttributedString(string: title.isEmpty ? gist : title, attributes: [.font: MeetingVisualStyle.textFont(14, weight: .semibold), .foregroundColor: ink, .paragraphStyle: style]))
                if current { rich.append(NSAttributedString(string: "  进行中", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: MeetingVisualStyle.accent, .paragraphStyle: style])) }
                let detail = NSMutableParagraphStyle(); detail.lineSpacing = 2; detail.paragraphSpacing = 10; detail.firstLineHeadIndent = 18; detail.headIndent = 18
                if !title.isEmpty && !gist.isEmpty {
                    rich.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
                    rich.append(NSAttributedString(string: gist, attributes: [.font: MeetingVisualStyle.textFont(13), .foregroundColor: muted, .paragraphStyle: detail]))
                }
                // An agenda entry takes you to where that part of the meeting starts.
                if let first { rich.addAttributes([.link: URL(string: "zaichang-agenda://segment/" + (first.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? first))!, .toolTip: "跳到原文这里"], range: NSRange(location: start, length: rich.length - start)) }
                rich.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: detail]))
            }
        } else if let topic = data["current_topic"] as? [String: Any], let text = topic["text"] as? String, !text.isEmpty {
            // Overviews made before the agenda: the topic line, as before.
            paragraph("当前议题", size: 11, color: muted, after: 4)
            let style = NSMutableParagraphStyle(); style.lineSpacing = 3; style.paragraphSpacing = 6
            let start = rich.length
            rich.append(NSAttributedString(string: text, attributes: [.font: MeetingVisualStyle.textFont(19, weight: .semibold), .foregroundColor: ink, .paragraphStyle: style]))
            linkEvidence(topic, from: start)
            rich.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
        }
        // Decisions and to-dos are cards: one box per item, a coloured edge for decisions, the owner's face for to-dos.
        func card(edge: NSColor?) -> NSTextBlock {
            let block = NSTextBlock(); block.backgroundColor = MeetingVisualStyle.cardFill
            // A text block is only as wide as its words unless told; fill the line, less padding and edges.
            block.setValue(max(80, lineWidth - 12 - 9 - (edge == nil ? 1 : 3.5) - 2), type: .absoluteValueType, for: .width)
            block.setWidth(9, type: .absoluteValueType, for: .padding); block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(0.5, type: .absoluteValueType, for: .border); block.setBorderColor(MeetingVisualStyle.border)
            if let edge { block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX); block.setBorderColor(edge, for: .minX) }
            return block
        }
        // The gap between cards is a thin line of its own: a block's margin is painted with its background.
        func cardGap() {
            let gap = NSMutableParagraphStyle(); gap.minimumLineHeight = 6; gap.maximumLineHeight = 6
            rich.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 2), .paragraphStyle: gap]))
        }
        func cardStyle(_ block: NSTextBlock, after: CGFloat = 0) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle(); style.textBlocks = [block]; style.lineSpacing = 3; style.paragraphSpacing = after; return style
        }
        let decisions = items("decisions")
        if !decisions.isEmpty {
            header("已定", decisions.count)
            for item in decisions {
                let style = cardStyle(card(edge: MeetingVisualStyle.decidedEdge)), (lead, text) = keyword(item["text"] as? String ?? "")
                let start = rich.length
                if !lead.isEmpty { rich.append(NSAttributedString(string: lead + "：", attributes: [.font: MeetingVisualStyle.textFont(14, weight: .semibold), .foregroundColor: ink, .paragraphStyle: style])) }
                rich.append(NSAttributedString(string: text, attributes: [.font: MeetingVisualStyle.textFont(14), .foregroundColor: ink, .paragraphStyle: style]))
                linkEvidence(item, from: start)
                rich.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style])); cardGap()
            }
        }
        let actions = items("actions")
        if !actions.isEmpty {
            header("待办", actions.count)
            for item in actions {
                let block = card(edge: nil), style = cardStyle(block)
                var owner = (item["owner"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                // "我" is whoever said it; show that person's name.
                if owner == "我", let said = (item["evidence"] as? [[String: Any]])?.first?["segment_id"] as? String, let speaker = speakerOfSegment?(said) { owner = speaker }
                var (lead, text) = keyword(item["text"] as? String ?? "")
                if !owner.isEmpty && lead == owner { lead = "" }
                if !owner.isEmpty && text.hasPrefix(owner) { text = String(text.dropFirst(owner.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ：:，,")) }
                let start = rich.length
                if !owner.isEmpty {
                    let face = NSTextAttachment(); face.image = MeetingVisualStyle.speakerAvatar(MeetingVisualStyle.speakerInitial(owner), color: MeetingVisualStyle.speakerColor(owner), diameter: 20)
                    face.bounds = NSRect(x: 0, y: -5, width: 20, height: 20)
                    let avatar = NSMutableAttributedString(attachment: face); avatar.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: avatar.length))
                    rich.append(avatar); rich.append(NSAttributedString(string: "  ", attributes: [.paragraphStyle: style]))
                }
                if !lead.isEmpty { rich.append(NSAttributedString(string: lead + "：", attributes: [.font: MeetingVisualStyle.textFont(14, weight: .semibold), .foregroundColor: ink, .paragraphStyle: style])) }
                rich.append(NSAttributedString(string: text, attributes: [.font: MeetingVisualStyle.textFont(14), .foregroundColor: ink, .paragraphStyle: style]))
                let deadline = (item["deadline"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let who = [owner.isEmpty ? "未定负责人" : owner, deadline].filter { !$0.isEmpty }.joined(separator: " · ")
                rich.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
                let meta = NSMutableParagraphStyle(); meta.setParagraphStyle(style); meta.firstLineHeadIndent = owner.isEmpty ? 0 : 26; meta.headIndent = meta.firstLineHeadIndent
                rich.append(NSAttributedString(string: who, attributes: [.font: MeetingVisualStyle.textFont(12), .foregroundColor: muted, .paragraphStyle: meta]))
                linkEvidence(item, from: start)
                rich.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: meta])); cardGap()
            }
        }
        // Open questions, and the discussion points of overviews made before the agenda, stay plain lines.
        for (key, title, bullet) in [("open_questions", "待讨论", "?"), ("discussion_points", "讨论要点", "•")] where key != "discussion_points" || agenda.isEmpty {
            let list = items(key)
            guard !list.isEmpty else { continue }
            header(title, list.count)
            let style = NSMutableParagraphStyle(); style.lineSpacing = 4; style.paragraphSpacing = 8
            style.headIndent = 18; style.tabStops = [NSTextTab(textAlignment: .left, location: 18)]
            for item in list {
                let (lead, text) = keyword(item["text"] as? String ?? "")
                rich.append(NSAttributedString(string: bullet + "\t", attributes: [.font: MeetingVisualStyle.textFont(13), .foregroundColor: muted, .paragraphStyle: style]))
                let start = rich.length
                if !lead.isEmpty { rich.append(NSAttributedString(string: lead + "：", attributes: [.font: MeetingVisualStyle.textFont(14, weight: .semibold), .foregroundColor: ink, .paragraphStyle: style])) }
                rich.append(NSAttributedString(string: text, attributes: [.font: MeetingVisualStyle.textFont(14), .foregroundColor: ink, .paragraphStyle: style]))
                linkEvidence(item, from: start)
                rich.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
            }
        }
        // Who spoke how much: only once the meeting is over, where it helps and embarrasses nobody.
        let shares = rich.length > 0 && !live ? (speakingShare?() ?? []) : []
        if shares.count > 1 {
            header("谁说得多", nil)
            let width = max(120, lineWidth - 4)
            let bar = NSImage(size: NSSize(width: width, height: 8), flipped: false) { rect in
                var x: CGFloat = 0
                for (index, share) in shares.enumerated() {
                    let w = index == shares.count - 1 ? rect.width - x : (rect.width * share.1).rounded()
                    MeetingVisualStyle.speakerColor(share.0 == Self.unknownSpeaker ? nil : share.0).setFill()
                    NSBezierPath(rect: NSRect(x: x, y: 0, width: max(0, w - 2), height: rect.height)).fill(); x += w
                }
                return true
            }
            let attachment = NSTextAttachment(); attachment.image = bar; attachment.bounds = NSRect(x: 0, y: 0, width: width, height: 8)
            let style = NSMutableParagraphStyle(); style.paragraphSpacing = 6
            let line = NSMutableAttributedString(attachment: attachment); line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            rich.append(line); rich.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
            let legend = NSMutableAttributedString()
            for share in shares {
                legend.append(NSAttributedString(string: "● ", attributes: [.font: MeetingVisualStyle.textFont(10), .foregroundColor: MeetingVisualStyle.speakerColor(share.0 == Self.unknownSpeaker ? nil : share.0)]))
                legend.append(NSAttributedString(string: "\(share.0) \(Int((share.1 * 100).rounded()))%    ", attributes: [.font: MeetingVisualStyle.textFont(12), .foregroundColor: muted]))
            }
            let legendStyle = NSMutableParagraphStyle(); legendStyle.lineSpacing = 4
            legend.addAttribute(.paragraphStyle, value: legendStyle, range: NSRange(location: 0, length: legend.length))
            rich.append(legend); rich.append(NSAttributedString(string: "\n"))
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
        // Stopping background work must not also switch listening off.
        if state["awaiting_response"] as? Bool != true, !(state["work"] as? [[String: Any]] ?? []).isEmpty {
            onCommand?("cancel_work", [:]); return
        }
        onCommand?("cancel", [:])
    }

    @objc private func toggleProactive(_ sender: MeetingTintedSwitch) {
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
        // A connection problem outranks what the assistant was doing when it hit it.
        if status != "unavailable" {
            if interrupted { statusLabel.stringValue = "助理已中断，发送消息或重新开启旁听可继续" }
            if snapshot["listening"] as? Bool == true { statusLabel.stringValue = "正在旁听" }
        }
        // Listening shows in the presence card; this line is only for problems.
        let needsAttention = ["unavailable", "auth_required"].contains(status) || interrupted
        statusLabel.isHidden = !needsAttention; statusHeight.constant = needsAttention ? 24 : 0
        moreButton.toolTip = "导出、最近对话、助理名字"
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
        let workItems = state["work"] as? [[String: Any]] ?? []
        let workIDs = Set(workItems.compactMap { $0["id"] as? String })
        for id in workCards.keys where !workIDs.contains(id) { workCards.removeValue(forKey: id) }
        for item in workItems {
            guard let id = item["id"] as? String else { continue }
            let card = workCards[id] ?? MeetingWorkCard()
            workCards[id] = card; card.apply(item); order.append(card)
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
        // Background work runs beside the conversation; the row names it when nothing else is pending.
        let work = (state["work"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }.filter { !$0.isEmpty }
        // Background work now has its own cards in the feed; this row is for the user's own requests.
        let shown = busy
        activityContainer.isHidden = !shown; activityHeight.constant = shown ? 26 : 0
        if shown {
            activityLabel.stringValue = !requests.isEmpty ? "等待你确认" : busy ? (state["conversation_status"] as? String == "cancelling" ? "正在停止…" : (state["activity"] as? String ?? "正在思考…"))
                : "后台：" + work.joined(separator: "、")
            activityLabel.lineBreakMode = .byTruncatingTail
            activityLabel.toolTip = work.isEmpty ? nil : "后台正在做：\n" + work.joined(separator: "\n")
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
            if stack === transcript, let card = view as? MeetingWorkCard { card.constrainWidth(to: transcript) }
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
/// Reports input-method composition, which AppKit does not announce through textDidChange.
private final class MeetingComposerTextView: NSTextView {
    var onMarkedTextChange: (() -> Void)?
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange); onMarkedTextChange?()
    }
    override func unmarkText() { super.unmarkText(); onMarkedTextChange?() }
}

private final class AgentSendButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
}

private final class MeetingAgentTabs: NSControl {
    var selectedSegment = 0 { didSet { refresh() } }
    private var buttons: [NSButton] = []
    private var marks: [NSView] = []
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let row = NSStackView(); row.orientation = .horizontal; row.distribution = .fill; row.spacing = 22
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        for (i, title) in ["概览", "助理", "笔记"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(selectTab(_:)))
            button.tag = i; button.bezelStyle = .regularSquare; button.isBordered = false
            button.setAccessibilityLabel(title); row.addArrangedSubview(button); buttons.append(button)
            button.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
            let mark = NSView(); mark.wantsLayer = true; mark.layer?.cornerRadius = 1; mark.translatesAutoresizingMaskIntoConstraints = false
            addSubview(mark); marks.append(mark)
            NSLayoutConstraint.activate([mark.centerXAnchor.constraint(equalTo: button.centerXAnchor), mark.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
                                         mark.widthAnchor.constraint(equalToConstant: 16), mark.heightAnchor.constraint(equalToConstant: 2)])
        }
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),row.topAnchor.constraint(equalTo: topAnchor, constant: 2),row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func refresh() {
        for button in buttons {
            let selected = button.tag == selectedSegment
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: selected ? .semibold : .regular),
                                                                                          .foregroundColor: selected ? MeetingVisualStyle.ink : MeetingVisualStyle.muted])
            if marks.indices.contains(button.tag) { marks[button.tag].layer?.backgroundColor = MeetingVisualStyle.accent.cgColor; marks[button.tag].isHidden = !selected }
            button.setAccessibilityValue(selected ? "已选择" : "未选择")
        }
    }
    @objc private func selectTab(_ sender: NSButton) { selectedSegment = sender.tag; sendAction(action, to: target) }
}

/// The listening presence: dark voice mark, state and its switch.
private final class MeetingListeningCard: NSView {
    private let mark = MeetingListeningMark()
    private let detail = NSTextField(labelWithString: "")
    private var on = false
    private weak var titleField: NSTextField?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 14; layer?.borderWidth = 1
        layer?.backgroundColor = (on ? MeetingVisualStyle.accentTint : MeetingVisualStyle.quietFill).cgColor
        layer?.borderColor = (on ? MeetingVisualStyle.accentTintBorder : MeetingVisualStyle.border).cgColor
    }
    func install(title: NSTextField, toggle: MeetingTintedSwitch) {
        titleField = title; detail.font = .systemFont(ofSize: 12); detail.lineBreakMode = .byTruncatingTail
        let words = NSStackView(views: [title, detail]); words.orientation = .vertical; words.alignment = .leading; words.spacing = 2
        for view in [mark, words, toggle] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: 60),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: 30), mark.heightAnchor.constraint(equalToConstant: 30),
            words.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 12), words.centerYAnchor.constraint(equalTo: centerYAnchor),
            words.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: 38), toggle.heightAnchor.constraint(equalToConstant: 22)])
    }
    func show(on: Bool, title: String, detail text: String, busy: Bool = false) {
        if titleField?.stringValue != title { titleField?.stringValue = title }
        detail.stringValue = text; detail.textColor = on ? MeetingVisualStyle.accentText : MeetingVisualStyle.muted
        if self.on != on { self.on = on; needsDisplay = true; mark.live = on }
        mark.busy = busy
        setAccessibilityLabel(title + "，" + text)
    }
}

private final class MeetingListeningMark: NSView {
    var live = false { didSet { needsDisplay = true } }
    /// Breathes while the assistant has heard its name or is working on what it was asked.
    var busy = false {
        didSet {
            guard busy != oldValue else { return }
            wantsLayer = true
            if busy {
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 1; breathe.toValue = 0.45; breathe.duration = 0.8
                breathe.autoreverses = true; breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer?.add(breathe, forKey: "busy")
            } else { layer?.removeAnimation(forKey: "busy") }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        MeetingVisualStyle.charcoal.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        MeetingVoiceGlyph.draw(in: bounds.insetBy(dx: 7, dy: 8), color: live ? MeetingVisualStyle.capsuleLive : MeetingVisualStyle.capsuleIdleDot)
    }
}

/// One running background task: who started it, its title and what it is doing now.
/// Only fields the runtime reports are shown; there is no invented progress.
private final class MeetingWorkCard: NSView {
    private let source = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let title = NSTextField(wrappingLabelWithString: "")
    private let activity = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var widthConstraint: NSLayoutConstraint?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); wantsLayer = true; translatesAutoresizingMaskIntoConstraints = false
        source.font = .systemFont(ofSize: 12, weight: .semibold); source.textColor = MeetingVisualStyle.accentText
        state.font = .systemFont(ofSize: 12, weight: .medium); state.textColor = MeetingVisualStyle.ink
        title.font = MeetingVisualStyle.taskTitleFont; title.textColor = MeetingVisualStyle.ink
        activity.font = .systemFont(ofSize: 13); activity.textColor = MeetingVisualStyle.muted
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isIndeterminate = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [source, spacer, spinner, state]); top.orientation = .horizontal; top.spacing = 6; top.alignment = .centerY
        let column = NSStackView(views: [top, title, activity]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false; addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                                     column.topAnchor.constraint(equalTo: topAnchor, constant: 14), column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
                                     top.widthAnchor.constraint(equalTo: column.widthAnchor), spinner.widthAnchor.constraint(equalToConstant: 12), spinner.heightAnchor.constraint(equalToConstant: 12)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 14; layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor; layer?.borderColor = MeetingVisualStyle.border.cgColor
    }
    func apply(_ item: [String: Any]) {
        source.stringValue = item["origin"] as? String == "user" ? "交办" : "旁听发现"
        let status = item["status"] as? String ?? ""
        state.stringValue = ["queued": "排队中", "running": "进行中", "waiting": "等待确认", "cancelling": "正在停止"][status] ?? "进行中"
        title.stringValue = item["title"] as? String ?? ""
        let now = (item["activity"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        activity.stringValue = now; activity.isHidden = now.isEmpty
        if status == "running" { spinner.isHidden = false; spinner.startAnimation(nil) } else { spinner.stopAnimation(nil); spinner.isHidden = true }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel(source.stringValue + "：" + title.stringValue + "，" + state.stringValue + (now.isEmpty ? "" : "，" + now))
    }
    func constrainWidth(to stack: NSStackView) {
        if widthConstraint == nil { widthConstraint = widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32) }
        widthConstraint?.isActive = true
        title.preferredMaxLayoutWidth = 0; activity.preferredMaxLayoutWidth = 0
    }
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

/// Drawn whole rather than painted over NSSwitch: inside a layer-backed card the
/// system knob shows above any child view. Keeps click, keyboard and VoiceOver.
final class MeetingTintedSwitch: NSControl {
    var state:NSControl.StateValue = .off {didSet {if state != oldValue {needsLayout=true;needsDisplay=true}}}
    private var interactive=true,placedBounds=NSRect.zero
    private weak var storedTarget:AnyObject?
    private var storedAction:Selector?
    private let track=CALayer(),knob=CALayer()
    override var target:AnyObject? {get {storedTarget} set {storedTarget=newValue}}
    override var action:Selector? {get {storedAction} set {storedAction=newValue}}
    override var isEnabled:Bool {get {interactive} set {interactive=newValue;needsDisplay=true}}
    override var intrinsicContentSize:NSSize {NSSize(width:38,height:22)}
    override var wantsUpdateLayer:Bool {true}
    override var acceptsFirstResponder:Bool {interactive}
    override var needsPanelToBecomeKey:Bool {false}
    override init(frame frameRect:NSRect) {
        super.init(frame:frameRect);wantsLayer=true
        knob.backgroundColor=NSColor.white.cgColor;knob.shadowOpacity=0.2;knob.shadowRadius=1;knob.shadowOffset=CGSize(width:0,height:-0.5)
        layer?.addSublayer(track);layer?.addSublayer(knob)
        setAccessibilityElement(true);setAccessibilityRole(.checkBox);setAccessibilitySubrole(.switch)
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    override func layout() {
        super.layout()
        let frame=bounds.insetBy(dx:1,dy:2),diameter=max(1,frame.height-4)
        let x=state == .on ? frame.maxX-diameter-2:frame.minX+2
        CATransaction.begin()
        CATransaction.setDisableActions(placedBounds != bounds || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        track.frame=frame;track.cornerRadius=frame.height/2
        knob.frame=NSRect(x:x,y:frame.minY+2,width:diameter,height:diameter);knob.cornerRadius=diameter/2
        CATransaction.commit();placedBounds=bounds
    }
    override func updateLayer() {
        track.backgroundColor=(state == .on ? MeetingVisualStyle.accent:NSColor(calibratedWhite:0.78,alpha:1)).cgColor
        track.opacity=interactive ? 1:0.4
    }
    override func drawFocusRingMask() {NSBezierPath(roundedRect:track.frame,xRadius:track.cornerRadius,yRadius:track.cornerRadius).fill()}
    override var focusRingMaskBounds:NSRect {bounds}
    override func mouseDown(with event:NSEvent) {}
    override func mouseUp(with event:NSEvent) {if bounds.contains(convert(event.locationInWindow,from:nil)) {toggle()}}
    override func keyDown(with event:NSEvent) {if event.charactersIgnoringModifiers == " " {toggle()} else {super.keyDown(with:event)}}
    override func performClick(_ sender:Any?) {toggle()}
    override func accessibilityPerformPress()->Bool {toggle();return true}
    override func accessibilityValue()->Any? {state == .on ? 1:0}
    private func toggle() {
        guard interactive else{return}
        state=state == .on ? .off:.on
        _=sendAction(storedAction,to:storedTarget)
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
        if textView === overviewTextView, let url = link as? URL, url.scheme == "zaichang-agenda" {
            revealSegment?(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent); return true
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
        composerPlaceholder.isHidden = !composer.string.isEmpty || composer.hasMarkedText()
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
        body.font = MeetingVisualStyle.textFont(14); body.textColor = MeetingVisualStyle.ink
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
