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
        child.arguments = ["-u", root + "/assistant_runtime.py", "--store", store.path, "--cwd", NSHomeDirectory()] + (offline ? ["--offline"] : [])
        var env = RuntimeConfiguration.childEnvironment()
        env["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
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
        do {
            guard let python=PythonRuntime.executable() else {throw Failure(code:"python_runtime_missing")}
            child.executableURL=python
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            try child.run(); process = child; input = stdin.fileHandleForWriting
        }
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
                self?.callbacks.removeValue(forKey: id)?(["ok": false, "error": ["message": "操作状态尚未确认；请勿重复提交，重新连接后核对任务。"]])
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
    private var binding = false
    private var boundCache: String?
    private var boundSession: String?
    private var fingerprint: Data?
    private var contextDirty = true
    private var lastTitle = ""
    private var lastNotes = ""
    private var width: NSLayoutConstraint!
    private let widthPreferenceKey = "MeetingAgentPanelWidth"
    private var preferredPanelWidth: CGFloat = 370
    private let minimumPanelWidth: CGFloat = 300
    private let maximumPanelWidth: CGFloat = 560
    private let minimumTranscriptWidth: CGFloat = 300
    private var manualVisible: Bool?
    private var draftReadOnly = false
    private var overviewActive = false
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
        let preferenceOwner = owner.workspaceOwner ?? owner
        if let saved = preferenceOwner.sidebarPreferences?.object(forKey: widthPreferenceKey) as? NSNumber,
           CFGetTypeID(saved) != CFBooleanGetTypeID() {
            let value = CGFloat(saved.doubleValue)
            if value.isFinite { preferredPanelWidth = min(maximumPanelWidth, max(minimumPanelWidth, value)) }
        }
        width = panel.widthAnchor.constraint(equalToConstant: 370)
        width.priority = NSLayoutConstraint.Priority(749)
        panel.onCommand = { [weak self] method, params in self?.command(method, params) }
        panel.onResize = { [weak self] proposed, persist in self?.resizePanel(to: proposed, persist: persist) }
        service.observers[token] = { [weak self] id, snapshot in
            guard let self, id == self.workspaceID || id.isEmpty else { return }
            if id.isEmpty { self.state["runtime_status"] = snapshot["runtime_status"]; self.state["runtime_message"] = snapshot["runtime_message"] }
            else { self.state = snapshot }
            self.state["workspaces"] = self.owner?.currentCacheID == nil ? self.workspaces : []
            self.panel.apply(self.state)
            let active=(self.state["tasks"] as? [[String:Any]] ?? []).filter{["running","waiting","queued","cancelling"].contains($0["status"] as? String ?? "")}.count
            self.owner?.agentSidebarButton?.toolTip = active > 0 ? "右侧栏 · \(active) 个任务进行中（收起不停止任务）" : "显示或隐藏右侧栏"
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sync() }
        bind()
    }
    deinit { timer?.invalidate(); service.observers.removeValue(forKey: token); if overviewActive { service.send("overview", workspace: workspaceID, params: ["active": false]) } }
    func installNotes(_ notes: MeetingNotesController) {
        notes.embeddedInAssistant = true; notes.panelWidth.isActive = false; notes.panel.isHidden = false
        panel.installNotes(notes.panel)
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
    func toggle() { manualVisible = !(manualVisible ?? expanded); layout(); owner?.window.contentView?.layoutSubtreeIfNeeded(); owner?.resizeTranscript() }
    func newWorkspace() {
        stopOverview()
        binding = false; workspaceID = UUID().uuidString; boundCache = nil; boundSession = nil; fingerprint = nil; contextDirty = true; state = [:]; draftReadOnly = false
        if let owner { let base = owner.agentStoreOverride ?? meetingCacheRoot().deletingLastPathComponent().appendingPathComponent(Credential.offline ? "DevelopmentQA/Assistant" : "Assistant"); UserDefaults.standard.set(workspaceID, forKey: "assistant.draft." + base.path) }
        panel.apply(state); bind()
    }
    private func bind() {
        guard !binding, let owner else { return }; binding = true
        let requested = workspaceID, cache = owner.currentCacheID, session = owner.activeSession
        var params: [String: Any] = ["title": owner.meetingTitle]
        if let cache { params["cache_id"] = cache }; if let session { params["session_id"] = session }
        if let database = owner.documentContextPublisher?.databaseURL, FileManager.default.fileExists(atPath:database.path) { params["context_database"] = database.path }
        service.send("bind", workspace: requested, params: params) { [weak self] response in
            guard let self, self.workspaceID == requested else { return }; self.binding = false
            if response["ok"] as? Bool == true {
                let result = response["result"] as? [String: Any] ?? [:]
                self.workspaceID = result["workspace_id"] as? String ?? requested
                self.boundCache = cache; self.boundSession = session
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
    func sync(force: Bool = false) {
        guard let owner, !binding, !owner.quitting else { return }
        if !draftReadOnly && (boundCache != owner.currentCacheID || boundSession != owner.activeSession) { bind(); return }
        if draftReadOnly, owner.currentCacheID != nil {draftReadOnly=false;bind();return}
        guard !draftReadOnly else { return }
        let notes=owner.notesController?.editor.string ?? ""
        guard force || contextDirty || lastTitle != owner.meetingTitle || lastNotes != notes else{return}
        contextDirty=false;lastTitle=owner.meetingTitle;lastNotes=notes
        let turns = owner.readingTurns(owner.sequence)
        let rows: [[String: Any]] = turns.filter { $0.item["final"] as? Bool == true }.map {
            ["id": $0.id, "revision": $0.item["revision"] ?? 0, "text": $0.item["text"] as? String ?? "", "speaker": owner.readingTurnLabel($0), "final": true]
        }
        var context: [String: Any] = ["title": owner.meetingTitle, "segments": rows, "notes": notes]
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
    private func stopOverview() {
        if overviewActive { service.send("overview", workspace: workspaceID, params: ["active": false]) }
        overviewActive = false
    }
    private func updateOverviewVisibility(refresh: Bool = false) {
        guard !binding else { return }
        let active = expanded && panel.selectedTab == "概览"
        guard active != overviewActive || refresh else { return }
        overviewActive = active
        if active { sync(force: true) }
        service.send("overview", workspace: workspaceID, params: ["active": active, "refresh": refresh])
    }
    func command(_ method: String, _ params: [String: Any]) {
        if method == "overview" { updateOverviewVisibility(refresh: params["refresh"] as? Bool ?? false); return }
        if method == "open_workspace" {
            guard owner?.currentCacheID == nil, let id = params["workspace_id"] as? String else { return }
            guard workspaces.contains(where:{$0["id"] as? String == id}) else{return}
            stopOverview()
            binding=true;workspaceID = id; draftReadOnly = true;fingerprint=nil;state=["runtime_status":"starting"];panel.apply(state)
            service.send("bind", workspace:id) { [weak self] response in
                guard let self,self.workspaceID == id else{return};self.binding=false
                if response["ok"] as? Bool != true {self.showError(response)} else {self.updateOverviewVisibility()}
            };return
        }
        guard !binding else {state["runtime_message"]="助理正在连接，请稍后发送。";panel.apply(state);if let text=params["text"] as? String {panel.restoreDraft(text)};return}
        sync(force: true)
        service.send(method, workspace: workspaceID, params: params) { [weak self] response in
            if response["ok"] as? Bool != true { self?.showError(response);if let text=params["text"] as? String {self?.panel.restoreDraft(text)} } else if method == "send" {self?.refreshWorkspaces()}
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
    @objc func showAssistantMore(_ sender:NSButton) {
        let menu=NSMenu();let details=NSMenuItem(title:"会议详情",action:#selector(showWorkspaceDetails),keyEquivalent:"");details.target=self;menu.addItem(details)
        NSMenu.popUpContextMenu(menu,with:NSApp.currentEvent ?? NSEvent(),for:sender)
    }
}
