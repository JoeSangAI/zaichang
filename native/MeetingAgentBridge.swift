import AppKit

/// One service per data root. All documents share the scheduler, never a current-meeting pointer.
final class MeetingAgentBridge {
    static var services: [String: MeetingAgentBridge] = [:]
    static func shared(root: String, store: URL, offline: Bool) -> MeetingAgentBridge {
        if let service = services[store.path] { return service }
        let service = MeetingAgentBridge(root: root, store: store, offline: offline)
        services[store.path] = service; return service
    }
    private var process: Process?
    private var input: FileHandle?
    private let io = DispatchQueue(label: "meeting.assistant.io")
    private var buffer = Data()
    private var callbacks: [String: ([String: Any]) -> Void] = [:]
    var observers: [UUID: (String, [String: Any]) -> Void] = [:]
    private(set) var error: String?
    private var stopping = false
    init(root: String, store: URL, offline: Bool) {
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/local/bin/python3")
        child.arguments = ["-u", root + "/assistant_runtime.py", "--store", store.path, "--cwd", NSHomeDirectory()] + (offline ? ["--offline"] : [])
        var env = RuntimeConfiguration.childEnvironment()
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        child.environment = env; child.standardInput = stdin; child.standardOutput = stdout
        // Retain startup diagnostics locally; never send them into the chat.
        // Replaced on launch so repeated failures cannot grow an unbounded log.
        do {
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            let log = store.appendingPathComponent("runtime-startup.log")
            try Data().write(to: log, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
            child.standardError = try FileHandle(forWritingTo: log)
        } catch { child.standardError = FileHandle.nullDevice }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.io.async { [weak self] in self?.receive(data) }
        }
        child.terminationHandler = { [weak self] _ in DispatchQueue.main.async {
            guard let self else { return }; self.input = nil; self.process = nil
            if !self.stopping { self.error = "助理连接已断开，重新打开应用后可继续对话。" }
            let pending = self.callbacks; self.callbacks.removeAll()
            for callback in pending.values { callback(["ok": false, "error": ["message": self.error ?? "助理已关闭"]]) }
            for observer in self.observers.values { observer("", ["runtime_status": "unavailable", "runtime_message": self.error ?? "助理已关闭"]) }
        } }
        do { try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true); try child.run(); process = child; input = stdin.fileHandleForWriting }
        catch { self.error = "助理未能启动：\(error.localizedDescription)"; stdout.fileHandleForReading.readabilityHandler = nil }
    }
    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count < 16 * 1024 * 1024 else { buffer.removeAll(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let id = object["id"] as? String, let callback = self.callbacks.removeValue(forKey: id) { callback(object) }
                if object["type"] as? String == "assistant_state", let workspace = object["workspace_id"] as? String, let state = object["state"] as? [String: Any] {
                    for observer in self.observers.values { observer(workspace, state) }
                }
            }
        }
    }
    func send(_ method: String, workspace: String, params: [String: Any] = [:], completion: (([String: Any]) -> Void)? = nil) {
        guard let input else { completion?(["ok": false, "error": ["message": error ?? "助理连接不可用"]]); return }
        let id = UUID().uuidString
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "workspace_id": workspace, "params": params]) else { return }
        if let completion {
            callbacks[id] = completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in
                self?.callbacks.removeValue(forKey: id)?(["ok": false, "error": ["message": "操作状态尚未确认；请勿重复提交，重新连接后核对对话。"]])
            }
        }
        io.async { [weak self] in do { try input.write(contentsOf: data + Data([10])) } catch {
            DispatchQueue.main.async { self?.callbacks.removeValue(forKey: id)?(["ok": false, "error": ["message": "助理连接中断，操作状态尚未确认。"]]) }
        } }
    }
    func shutdown(_ completion: @escaping () -> Void) {
        guard let process, process.isRunning else { completion(); return }; stopping = true
        var finished = false
        let finish = { if !finished { finished = true; completion() } }
        send("shutdown", workspace: "", completion: { _ in finish() })
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if process.isRunning { process.terminate() }; finish() }
    }
}

final class MeetingAgentController: NSObject {
    weak var owner: Delegate?
    let panel = MeetingAgentPanel()
    private(set) var workspaceID: String
    private(set) var state: [String: Any] = [:]
    private var service: MeetingAgentBridge
    private let token = UUID()
    private var timer: Timer?
    private var profileObserver: NSObjectProtocol?
    private var binding = false
    private var bindingSucceeded = false
    private var bindGeneration = 0
    private var suspended = false
    private var boundCache: String?
    private var boundSession: String?
    private var fingerprint: Data?
    private var contextDirty = true
    private var lastTitle = ""
    private var lastNotes = ""
    private var lastMeetingState = ""
    private var width: NSLayoutConstraint!
    private let widthPreferenceKey = "MeetingAgentPanelWidth"
    private var preferredPanelWidth: CGFloat = 370
    private let minimumPanelWidth: CGFloat = 300
    private let maximumPanelWidth: CGFloat = 560
    private let minimumTranscriptWidth: CGFloat = 300
    private var manualVisible: Bool?
    private var draftReadOnly = false
    private var workspaces: [[String: Any]] = []
    var expanded = true
    init(owner: Delegate) {
        self.owner = owner
        let base = owner.agentStoreOverride ?? meetingCacheRoot().deletingLastPathComponent().appendingPathComponent(Credential.offline ? "DevelopmentQA/Assistant" : "Assistant")
        let key = "assistant.draft." + base.path
        workspaceID = owner.isHistoryReader ? UUID().uuidString : (UserDefaults.standard.string(forKey: key) ?? UUID().uuidString)
        if !owner.isHistoryReader { UserDefaults.standard.set(workspaceID, forKey: key) }
        service = MeetingAgentBridge.shared(root: owner.root, store: base, offline: Credential.offline && !owner.agentLiveProbe)
        super.init()
        panel.activateWorkspace(workspaceID)
        let preferenceOwner = owner.workspaceOwner ?? owner
        if let saved = preferenceOwner.sidebarPreferences?.object(forKey: widthPreferenceKey) as? NSNumber,
           CFGetTypeID(saved) != CFBooleanGetTypeID() {
            let value = CGFloat(saved.doubleValue)
            if value.isFinite { preferredPanelWidth = min(maximumPanelWidth, max(minimumPanelWidth, value)) }
        }
        width = panel.widthAnchor.constraint(equalToConstant: 370)
        width.priority = NSLayoutConstraint.Priority(999)
        panel.onCommand = { [weak self] method, params in self?.command(method, params) }
        panel.onResize = { [weak self] proposed, persist in self?.resizePanel(to: proposed, persist: persist) }
        service.observers[token] = { [weak self] id, snapshot in
            guard let self, id == self.workspaceID || id.isEmpty else { return }
            if id.isEmpty { self.state["runtime_status"] = snapshot["runtime_status"]; self.state["runtime_message"] = snapshot["runtime_message"] }
            else { self.state = snapshot }
            self.state["workspaces"] = self.owner?.currentCacheID == nil ? self.workspaces : []
            self.panel.apply(self.state)
            self.owner?.showAgentListening(self.state["listening"] as? Bool == true)
        }
        // A renamed assistant shows at once in every open window.
        profileObserver = NotificationCenter.default.addObserver(forName: AssistantProfile.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.panel.apply(self.state); self.owner?.showAgentListening(self.state["listening"] as? Bool == true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.sync(); self?.updateOverviewVisibility()
        }
        bind()
    }
    deinit { timer?.invalidate(); service.observers.removeValue(forKey: token); if let profileObserver { NotificationCenter.default.removeObserver(profileObserver) } }
    func installNotes(_ notes: MeetingNotesController) {
        notes.embeddedInAssistant = true; notes.panelWidth.isActive = false; notes.panel.isHidden = false
        panel.installNotes(notes.panel)
        owner?.installTransportNotes(notes)
    }
    func layout() {
        guard let owner else { return }
        let available = panelAvailableWidth
        let canFitPanelAndTranscript = available >= minimumPanelWidth + minimumTranscriptWidth
        expanded = canFitPanelAndTranscript && (manualVisible ?? (available >= 730))
        if expanded { width.constant = clampedPanelWidth(preferredPanelWidth, available: available) }
        width.isActive = expanded; panel.isHidden = !expanded
        updateOverviewVisibility()
    }
    private var panelAvailableWidth: CGFloat {
        guard let owner else { return 0 }
        return owner.window.contentLayoutRect.width - (owner.sidebarWidth?.constant ?? 0)
    }
    private func clampedPanelWidth(_ proposed: CGFloat, available: CGFloat) -> CGFloat {
        let maximum = min(maximumPanelWidth, available - minimumTranscriptWidth)
        return min(maximum, max(minimumPanelWidth, proposed))
    }
    func resizePanel(to proposed: CGFloat, persist: Bool = true) {
        guard expanded, let owner else { return }
        let value = clampedPanelWidth(proposed.isFinite ? proposed : preferredPanelWidth, available: panelAvailableWidth)
        preferredPanelWidth = value
        width.constant = value
        if persist { (owner.workspaceOwner ?? owner).sidebarPreferences?.set(Double(value), forKey: widthPreferenceKey) }
        owner.window.contentView?.layoutSubtreeIfNeeded()
        owner.resizeTranscript()
    }
    var requestedPanelWidth: CGFloat { width.constant }
    func openNotes() {manualVisible=true;layout();panel.chooseTab("笔记");owner?.window.contentView?.layoutSubtreeIfNeeded();owner?.resizeTranscript()}
    func toggle() { manualVisible = !(manualVisible ?? expanded); layout(); owner?.window.contentView?.layoutSubtreeIfNeeded(); owner?.resizeTranscript() }
    func newWorkspace() {

        binding = false; bindingSucceeded = false; workspaceID = UUID().uuidString; boundCache = nil; boundSession = nil; fingerprint = nil; contextDirty = true; state = [:]; draftReadOnly = false
        if let owner { let base = owner.agentStoreOverride ?? meetingCacheRoot().deletingLastPathComponent().appendingPathComponent(Credential.offline ? "DevelopmentQA/Assistant" : "Assistant"); UserDefaults.standard.set(workspaceID, forKey: "assistant.draft." + base.path) }
        panel.activateWorkspace(workspaceID); panel.apply(state); bind()
    }
    private func bind() {
        guard !suspended, !binding, let owner else { return }; binding = true
        bindingSucceeded = false

        bindGeneration += 1; let generation = bindGeneration
        let resolvesTemporary = boundCache == nil && boundSession == nil && !draftReadOnly
        let requested = workspaceID, cache = owner.currentCacheID, session = owner.activeSession
        var params: [String: Any] = ["title": owner.meetingTitle]
        if let cache { params["cache_id"] = cache }; if let session { params["session_id"] = session }
        if let database = owner.documentContextPublisher?.databaseURL, FileManager.default.fileExists(atPath:database.path) { params["context_database"] = database.path }
        service.send("bind", workspace: requested, params: params) { [weak self] response in
            guard let self, !self.suspended, self.bindGeneration == generation, self.workspaceID == requested else { return }; self.binding = false
            if response["ok"] as? Bool == true {
                let result = response["result"] as? [String: Any] ?? [:]
                self.workspaceID = result["workspace_id"] as? String ?? requested
                if resolvesTemporary { self.panel.resolveDraftWorkspace(from: requested, to: self.workspaceID) }
                self.panel.activateWorkspace(self.workspaceID)
                self.boundCache = cache; self.boundSession = session
                self.bindingSucceeded = true
                if cache != nil, let owner = self.owner, !owner.isHistoryReader {
                    let base = owner.agentStoreOverride ?? meetingCacheRoot().deletingLastPathComponent().appendingPathComponent(Credential.offline ? "DevelopmentQA/Assistant" : "Assistant")
                    UserDefaults.standard.removeObject(forKey: "assistant.draft." + base.path)
                }
                self.service.send("snapshot", workspace: self.workspaceID)
                self.sync(force: true);self.refreshWorkspaces();self.updateOverviewVisibility()
            } else { self.showError(response) }
        }
    }
    func invalidateContext() {contextDirty=true}
    private var currentBindingReady: Bool {
        guard !suspended, !binding, bindingSucceeded, let owner else { return false }
        if draftReadOnly { return owner.currentCacheID == nil }
        return boundCache == owner.currentCacheID && boundSession == owner.activeSession
    }
    func sync(force: Bool = false) {
        guard let owner, !suspended, !binding, !owner.quitting else { return }
        if !bindingSucceeded { bind(); return }
        if !draftReadOnly && (boundCache != owner.currentCacheID || boundSession != owner.activeSession) { bind(); return }
        if draftReadOnly, owner.currentCacheID != nil {draftReadOnly=false;bind();return}
        guard !draftReadOnly else { return }
        let notes=owner.notesController?.editor.string ?? ""
        let meetingState = owner.phase.phase.rawValue
        guard force || contextDirty || lastTitle != owner.meetingTitle || lastNotes != notes || lastMeetingState != meetingState else{return}
        lastMeetingState = meetingState
        contextDirty=false;lastTitle=owner.meetingTitle;lastNotes=notes
        let rows = meetingAssistantSegments(owner: owner, turns: owner.readingTurns(owner.sequence))
        var context: [String: Any] = ["title": owner.meetingTitle, "segments": rows, "notes": notes, "meeting_state": meetingState]
        if let cache = owner.currentCacheID { context["cache_id"] = cache }; if let session = owner.activeSession { context["session_id"] = session }
        guard let data = try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]), force || data != fingerprint else { return }
        fingerprint = data; service.send("context", workspace: workspaceID, params: context)

    }
    private func refreshWorkspaces() {
        service.send("list_workspaces", workspace: workspaceID) { [weak self] response in
            guard let self, let result=response["result"] as? [String:Any] else{return}
            self.workspaces=(result["workspaces"] as? [[String:Any]] ?? []).filter { $0["cache_id"] is NSNull || $0["cache_id"] == nil }
            self.state["workspaces"]=self.owner?.currentCacheID == nil ? self.workspaces : [];self.panel.apply(self.state)
        }
    }
    func suspend() {
        suspended = true; bindGeneration += 1; binding = false; bindingSucceeded = false
        timer?.invalidate();
    }
    private func updateOverviewVisibility(refresh: Bool = false) {
        guard refresh, !suspended, !binding else { return }
        sync(force: true)
        guard currentBindingReady else { return }
        service.send("overview", workspace: workspaceID, params: ["refresh": true])
    }
    func command(_ method: String, _ params: [String: Any]) {
        if method == "overview" { updateOverviewVisibility(refresh: params["refresh"] as? Bool ?? false); return }
        if method == "open_workspace" {
            guard owner?.currentCacheID == nil, let id = params["workspace_id"] as? String else { return }
            guard workspaces.contains(where:{$0["id"] as? String == id}) else{return}

            bindGeneration += 1; let generation = bindGeneration
            binding=true;bindingSucceeded=false;workspaceID = id; panel.activateWorkspace(id); draftReadOnly = true;fingerprint=nil;state=["runtime_status":"starting"];panel.apply(state)
            service.send("bind", workspace:id) { [weak self] response in
                guard let self,!self.suspended,self.bindGeneration == generation,self.workspaceID == id else{return};self.binding=false
                if response["ok"] as? Bool != true {self.showError(response)} else {self.bindingSucceeded=true;self.updateOverviewVisibility()}
            };return
        }
        guard !binding else {state["runtime_message"]="助理正在连接，请稍后发送。";panel.apply(state);if let text=params["text"] as? String {panel.restoreDraft(text)};return}
        sync(force: true)
        // sync may start a bind after the user switches the visible meeting.
        // Do not send this input with the preceding meeting's binding.
        guard currentBindingReady else {
            if let text = params["text"] as? String { panel.restoreDraft(text) }
            state["runtime_message"] = "助理尚未连接到当前会议，输入已保留，请连接后发送。"
            panel.apply(state)
            return
        }
        let requestedWorkspace = workspaceID
        service.send(method, workspace: requestedWorkspace, params: params) { [weak self] response in
            guard let self else { return }
            if response["ok"] as? Bool != true {
                if let text = params["text"] as? String { self.panel.restoreDraft(text, workspace: requestedWorkspace) }
                if self.workspaceID == requestedWorkspace { self.showError(response) }
            } else if method == "send", self.workspaceID == requestedWorkspace { self.refreshWorkspaces() }
        }
    }
    private func showError(_ response: [String: Any]) {
        let error = response["error"] as? [String: Any]
        state["runtime_message"] = error?["message"] as? String ?? "助理暂时不可用"; state["runtime_status"] = "unavailable"; panel.apply(state)
    }
    func shutdown(_ completion: @escaping () -> Void) { timer?.invalidate(); service.shutdown(completion) }
}

extension Delegate {
    var assistantEnabled: Bool { agentFeatureOverride || !Credential.offline && !documentIsPreview }
    func attachMeetingAssistant(to transcript: NSView) -> NSView {
        guard assistantEnabled else { return attachMeetingNotes(to: transcript) }
        let notes = MeetingNotesController(owner: self); notesController = notes; notes.bind(currentCacheID)
        let assistant = MeetingAgentController(owner: self); agentController = assistant; assistant.installNotes(notes)
        let body = NSStackView(views: [transcript, assistant.panel]); body.orientation = .horizontal; body.alignment = .top; body.distribution = .fill; body.spacing = 0
        transcript.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let transcriptMinimum = transcript.widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
        transcriptMinimum.priority = NSLayoutConstraint.Priority(750)
        transcriptMinimum.isActive = true
        transcript.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        assistant.panel.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        assistant.layout(); return body
    }
    @objc func toggleAssistantPanel() { agentController?.toggle() }
    @objc func toggleVisibleAssistant() {displayedDocument.agentController?.toggle()}
    /// The toolbar's right-panel button doubles as the listening indicator, so
    /// listening stays visible while the panel is closed.
    func showAgentListening(_ listening:Bool) {
        guard let button=agentSidebarButton else{return}
        let name=AssistantProfile.name
        button.toolTip=listening ? name+"正在旁听 · 收起右栏不停止旁听":"显示或隐藏右侧栏"
        button.setAccessibilityLabel(listening ? name+"旁听中，显示或隐藏右侧栏":"显示或隐藏右侧栏")
        button.wantsLayer=true;button.layer?.cornerRadius=13
        // The toolbar sizes its item once, from the icon; give the pill an explicit
        // size that follows its label so it is never clipped to "● …".
        func constraint(_ id:String,_ make:()->NSLayoutConstraint)->NSLayoutConstraint {
            if let existing=button.constraints.first(where:{$0.identifier==id}) {return existing}
            let value=make();value.identifier=id;value.isActive=true;return value
        }
        button.translatesAutoresizingMaskIntoConstraints=false
        let width=constraint("agent-pill-width"){button.widthAnchor.constraint(equalToConstant:30)}
        let height=constraint("agent-pill-height"){button.heightAnchor.constraint(equalToConstant:26)}
        height.constant=26
        if listening {
            let title=NSAttributedString(string:" "+name+"旁听中",attributes:[.font:NSFont.systemFont(ofSize:12,weight:.semibold),.foregroundColor:MeetingVisualStyle.accentText])
            button.image=MeetingVisualStyle.listeningDot;button.imagePosition = .imageLeading
            button.attributedTitle=title;width.constant=ceil(title.size().width)+12+24
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                button.layer?.backgroundColor=MeetingVisualStyle.accentTint.cgColor;button.layer?.borderColor=MeetingVisualStyle.accentTintBorder.cgColor
            }
            button.layer?.borderWidth=1
        } else {
            button.attributedTitle=NSAttributedString(string:"");button.image=NSImage(systemSymbolName:"sidebar.right",accessibilityDescription:"显示或隐藏右侧栏");button.imagePosition = .imageOnly
            button.layer?.backgroundColor=nil;button.layer?.borderWidth=0;width.constant=30
        }
        button.superview?.needsLayout=true
    }
    @objc func showAssistantMore(_ sender:NSButton) {
        let menu=NSMenu()
        let search=NSMenuItem(title:"搜索原文",action:#selector(showDocumentSearch),keyEquivalent:"");search.target=self;menu.addItem(search)
        let details=NSMenuItem(title:"会议详情",action:#selector(showWorkspaceDetails),keyEquivalent:"");details.target=self;menu.addItem(details)
        let document=displayedDocument
        let archive=NSMenuItem(title:"归档",action:#selector(openMeetingArchive),keyEquivalent:"");archive.target=document;archive.isEnabled=document.meetingArchiveEligible
        menu.autoenablesItems=false;menu.addItem(.separator());menu.addItem(archive)
        NSMenu.popUpContextMenu(menu,with:NSApp.currentEvent ?? NSEvent(),for:sender)
    }
}

/// Shared by the live bridge and read-only replay projection.
func meetingAssistantSegments(owner: Delegate, turns: [ReadingTurn]) -> [[String: Any]] {
        return turns.filter { $0.item["final"] as? Bool == true }.map {
            var flags=($0.item["quality_flags"] as? [String] ?? []) + $0.parts.flatMap { part in part.1["quality_flags"] as? [String] ?? [] }
            if $0.parts.contains(where:{$0.1["final"] as? Bool==false}) {flags.append("contains_nonfinal_part")}
            if $0.parts.contains(where:{["unreliable","needs_review"].contains($0.1["text_quality"] as? String ?? "")}) {flags.append("text_needs_review")}
            return ["id": $0.id, "revision": $0.item["revision"] ?? 0, "text": $0.item["text"] as? String ?? "", "speaker": owner.readingTurnLabel($0), "speaker_uncertain": $0.uncertain, "quality_flags": Array(Set(flags)).sorted(), "text_quality": $0.item["text_quality"] ?? NSNull(), "final": true, "start": $0.item["start"] ?? 0, "end": $0.item["end"] ?? 0]
        }
}
