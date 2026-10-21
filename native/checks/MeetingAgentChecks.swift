import AppKit

@MainActor func meetingAgentChecks(directory: URL, live: Bool, overviewOnly: Bool = false) throws -> [String: Any] {
    guard Credential.offline, let root = Bundle.main.object(forInfoDictionaryKey: "AdapterRoot") as? String,
          directory.standardizedFileURL.path.hasPrefix(root + "/.runtime/") else { throw Failure(code: "assistant_check_scope") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let widthPreferenceKey = "MeetingAgentPanelWidth"
    let preferenceDomain = "MeetingAgentChecks-" + UUID().uuidString
    let panelPreferences = UserDefaults(suiteName: preferenceDomain)!
    let priorWidthPreference = panelPreferences.object(forKey: widthPreferenceKey)
    defer {
        if let priorWidthPreference { panelPreferences.set(priorWidthPreference, forKey: widthPreferenceKey) }
        else { panelPreferences.removeObject(forKey: widthPreferenceKey) }
        panelPreferences.removePersistentDomain(forName: preferenceDomain)
    }
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    var checks: [String] = []
    func check(_ value: Bool, _ name: String) throws { if !value { throw Failure(code: name) }; checks.append(name) }
    func wait(_ seconds: Double = 15, _ predicate: () -> Bool) throws {
        let end = Date().addingTimeInterval(seconds)
        while !predicate() && Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        try check(predicate(), "async_\(checks.count)")
    }
    func settle() { let end = Date().addingTimeInterval(0.2); while Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) } }
    let app = Delegate(); app.previewRenderOnly = true; app.agentFeatureOverride = true; app.agentLiveProbe = live
    app.sidebarPreferencesOverride = panelPreferences
    app.agentStoreOverride = directory.appendingPathComponent("store-" + UUID().uuidString)
    app.recoveryRootOverride = directory.appendingPathComponent("recordings")
    app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    app.window.setContentSize(NSSize(width: 1280, height: 820)); app.layoutWorkspace()
    guard let controller = app.agentController else { throw Failure(code: "assistant_not_attached") }
    defer { app.window.orderOut(nil) }
    try wait(40) { ["ready", "offline", "unavailable", "auth_required"].contains(controller.state["runtime_status"] as? String ?? "") }
    try check(controller.state["runtime_status"] as? String == (live ? "ready" : "offline"), "runtime_initialized_before_recording")
    try check(app.currentCacheID == nil && app.child == nil, "premeeting_without_capture")
    try check(controller.state["proactive"] as? Bool == false, "proactive_defaults_off")
    try check(app.notesController?.embeddedInAssistant == true, "existing_notes_embedded")
    func descendants(_ view:NSView)->[NSView] {view.subviews.flatMap{[$0]+descendants($0)}}
    let reference = directory.appendingPathComponent("在场 说明(中文).txt")
    try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("README.md")).write(to: reference)
    let linkedText = "项目说明：\n[在场说明](<\(reference.path)>)\n[源码](\(root)/native/MeetingAgentPanel.swift:12)"
    let parsed = MeetingAssistantLinks.references(in: linkedText)
    try check(parsed.count == 2 && parsed[0].target == reference.path, "reference_spaces_chinese_parentheses")
    try check(MeetingAssistantLinks.localURL(parsed[1].target, base: directory)?.lastPathComponent == "MeetingAgentPanel.swift", "reference_source_line_resolved")
    try check(MeetingAssistantLinks.localURL(reference.absoluteString, base: directory) == reference, "reference_file_url_resolved")
    try check(MeetingAssistantLinks.webURL("javascript:alert(1)") == nil && MeetingAssistantLinks.localURL("说明.txt", base: directory) == nil, "no_unsafe_scheme_or_guessed_filename")
    let missing = MeetingAssistantFileRow(label: "已移动的文件", url: directory.appendingPathComponent("not-present.txt"))
    var missingError: String?
    missing.onOpened = { missingError = $0 }; missing.openButton.performClick(nil)
    try check(missingError?.contains("文件已移动或不存在") == true, "missing_reference_explained_on_click")
    let commandHandler=controller.panel.onCommand
    var submitted:[String:Any] = [:]
    controller.panel.onCommand={ method,params in if method == "approval" {submitted=params} }
    var approvalState=controller.state
    approvalState["approvals"]=[["id":"command-check","kind":"command","title":"运行只读命令","detail":"pwd","task_id":"check"]]
    controller.panel.apply(approvalState)
    let accept=descendants(controller.panel).compactMap{$0 as? NSButton}.first{$0.title == "允许" && !$0.isHidden}
    try check(accept != nil,"native_command_approval_action_available")
    accept?.performClick(nil)
    try check(submitted["decision"] as? String == "accept","native_approval_submission")
    approvalState["approvals"]=[["id":"question-check","kind":"question","title":"选择资料范围","detail":"","task_id":"check","questions":[["id":"scope","question":"资料范围"]]]]
    controller.panel.apply(approvalState)
    let answer=descendants(controller.panel).compactMap{$0 as? NSTextField}.first{$0.placeholderString == "资料范围"}
    answer?.stringValue="公开资料"
    controller.panel.apply(approvalState)
    try check(answer?.stringValue == "公开资料","approval_answer_survives_streaming_snapshot")
    descendants(controller.panel).compactMap{$0 as? NSButton}.first{$0.title == "提交回答" && !$0.isHidden}?.performClick(nil)
    let answers=submitted["answers"] as? [String:[String:[String]]]
    try check(answers?["scope"]?["answers"] == ["公开资料"],"native_codex_question_answer_shape")
    controller.panel.onCommand=commandHandler;controller.panel.apply(controller.state)
    let first = controller.workspaceID
    controller.panel.chooseTab("笔记"); settle()
    try check(controller.panel.selectedTab == "笔记" && app.notesController?.panel.isHidden == false, "notes_tab_visible")
    controller.panel.chooseTab("概览"); settle()
    try check(controller.panel.selectedTab == "概览", "overview_independent_tab")
    controller.panel.chooseTab("助理"); settle()
    if live && !overviewOnly {
        controller.panel.submit(text: "请读取 \(root)/README.md，用两句话说明这个项目做什么、当前开发源码在哪里。这是接入验收，只读这份文件，不修改文件，不发消息，不调用其他模型。")
        try wait(180) {
            let tasks = controller.state["tasks"] as? [[String: Any]] ?? []
            return tasks.contains { $0["status"] as? String == "completed" || $0["status"] as? String == "failed" }
        }
        let tasks = controller.state["tasks"] as? [[String: Any]] ?? []
        try check(tasks.contains { $0["status"] as? String == "completed" }, "native_composer_to_real_codex_completion")
        let messages = controller.state["messages"] as? [[String: Any]] ?? []
        try check(messages.contains { $0["role"] as? String == "assistant" && !($0["text"] as? String ?? "").isEmpty }, "real_reply_in_native_panel")
    }
    if overviewOnly {
        // Synthetic project discussion; no customer or user meeting material.
        let source = ["团队讨论项目目标，并确认先处理最紧急的问题。",
                      "助理需要把主动跟进作为聊天消息展示，不能混入固定会议概览。",
                      "不同任务可以并行执行，但应共享会议和项目上下文。",
                      "下一步先验证多任务运行，再检查转写整理和说话人归并。"]
        app.segments = [:]
        for (index, text) in source.enumerated() {
            let id = "synthetic-review-\(index)"
            app.segments[id] = ["segment_id": id, "session": "requirements-review", "source_id": "mic", "track": "mic", "epoch": "review", "start": Double(index * 30), "end": Double(index * 30 + 20), "text": text, "revision": 1, "final": true,
                                "speaker": ["basis": "anonymous_cluster", "cluster_id": 0, "source_id": "mic", "epoch": "review"]]
        }
        app.sequence = source.indices.map { "synthetic-review-\($0)" }
        app.markAllTranscriptParentsDirty(); app.renderText(); controller.invalidateContext()
        controller.panel.chooseTab("概览")
        try wait(240) { ["ready", "failed", "interrupted"].contains((controller.state["meeting_overview"] as? [String: Any])?["status"] as? String ?? "") }
        let overview = controller.state["meeting_overview"] as? [String: Any] ?? [:]
        try check(overview["status"] as? String == "ready", "native_overview_real_codex_completion")
        try check(overview["stale"] as? Bool == false, "overview_matches_current_speech")
        let data = overview["data"] as? [String: Any] ?? [:]
        try check(!((data["current_topic"] as? [String: Any])?["text"] as? String ?? "").isEmpty, "overview_has_current_topic")
        try check(!(data["discussion_points"] as? [[String: Any]] ?? []).isEmpty, "overview_has_structured_points")
        try check((controller.state["messages"] as? [[String: Any]] ?? []).isEmpty, "overview_not_in_chat")
        try JSONSerialization.data(withJSONObject: controller.state, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("overview-state.json"))
        controller.panel.chooseTab("助理")
    }
    let priorCommandHandler = controller.panel.onCommand
    var panelCommand: (String, [String: Any])?
    controller.panel.onCommand = { panelCommand = ($0, $1) }
    let proactiveToggle = descendants(controller.panel).compactMap { $0 as? NSSwitch }.first
    try check(proactiveToggle != nil && proactiveToggle?.state == .off, "proactive_switch_is_visible_and_defaults_off")
    try check(!descendants(controller.panel).compactMap { $0 as? NSButton }.contains { $0.title.contains("新任务") },
              "manual_new_task_entry_removed")
    proactiveToggle?.performClick(nil)
    try check(panelCommand?.0 == "proactive" && panelCommand?.1["enabled"] as? Bool == true, "proactive_switch_sends_enabled_command")

    var noTaskState = controller.state; noTaskState["active_task_id"] = NSNull(); noTaskState["tasks"] = []
    controller.panel.apply(noTaskState); panelCommand = nil
    controller.panel.submit(text: "直接交给助理处理")
    try check(panelCommand?.0 == "send" && panelCommand?.1["text"] as? String == "直接交给助理处理" && panelCommand?.1["new_task"] == nil && panelCommand?.1["task_id"] == nil,
              "normal_send_uses_runtime_without_manual_new_task_mode")
    controller.panel.onCommand = priorCommandHandler; controller.panel.apply(controller.state)

    let transcriptPane = (controller.panel.superview as? NSStackView)?.views.first
    controller.resizePanel(to: 1, persist: false); app.window.contentView?.layoutSubtreeIfNeeded()
    try check(controller.requestedPanelWidth >= 300, "panel_resize_respects_minimum_width")
    try check(panelPreferences.object(forKey: widthPreferenceKey) == nil, "panel_drag_frames_do_not_persist_preferences")
    let availableWidth = app.window.contentLayoutRect.width - (app.sidebarWidth?.constant ?? 0)
    controller.resizePanel(to: 10_000); app.window.contentView?.layoutSubtreeIfNeeded()
    try check(controller.requestedPanelWidth <= min(560, availableWidth - 300) + 1 && (transcriptPane?.bounds.width ?? 0) >= 300,
              "panel_resize_preserves_transcript_minimum_width")
    try check(abs(panelPreferences.double(forKey: widthPreferenceKey) - controller.requestedPanelWidth) < 1,
              "panel_width_persists_after_resize")

    // A history document renders through a preview reader, but its persistent
    // workspace preferences belong to the real capture owner. Exercise both
    // sides of that path with the isolated suite above, then recreate a reader
    // controller to verify restart restoration without touching user defaults.
    func historyReaderController() throws -> (Delegate, MeetingAgentController) {
        let reader = Delegate()
        reader.previewRenderOnly = true; reader.isHistoryReader = true
        reader.workspaceOwner = app; reader.agentFeatureOverride = true; reader.agentLiveProbe = live
        reader.agentStoreOverride = app.agentStoreOverride
        reader.recoveryRootOverride = app.recoveryRootOverride
        reader.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        reader.window.setContentSize(NSSize(width: 1280, height: 820)); reader.layoutWorkspace()
        guard let readerController = reader.agentController else { throw Failure(code: "history_assistant_not_attached") }
        return (reader, readerController)
    }
    panelPreferences.set(380.0, forKey: widthPreferenceKey)
    do {
        let (reader, readerController) = try historyReaderController()
        try check(abs(readerController.requestedPanelWidth - 380) < 1,
                  "history_reader_loads_capture_owner_width_preference")
        readerController.resizePanel(to: 420, persist: true)
        try check(abs(panelPreferences.double(forKey: widthPreferenceKey) - 420) < 1,
                  "history_reader_writes_capture_owner_width_preference")
        reader.window.orderOut(nil)
    }
    do {
        let (reader, readerController) = try historyReaderController()
        try check(abs(readerController.requestedPanelWidth - 420) < 1,
                  "history_reader_restores_width_after_controller_recreation")
        reader.window.orderOut(nil)
    }
    func snapshot(_ name: String) throws {
        app.window.contentView?.layoutSubtreeIfNeeded()
        let target = app.window.contentView!
        guard let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { throw Failure(code: "assistant_bitmap") }
        target.effectiveAppearance.performAsCurrentDrawingAppearance { target.cacheDisplay(in: target.bounds, to: bitmap) }
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
    }
    try snapshot("assistant")
    controller.panel.chooseTab("概览"); settle(); try snapshot("overview")
    controller.panel.chooseTab("助理")
    app.window.setContentSize(NSSize(width: 640, height: 720)); app.layoutWorkspace(); settle()
    try check(!controller.expanded, "narrow_default_collapses_sidebar")
    controller.toggle(); settle()
    let narrowAvailable = app.window.contentLayoutRect.width - (app.sidebarWidth?.constant ?? 0)
    try check(controller.expanded && controller.requestedPanelWidth <= narrowAvailable - 300 + 1 &&
              (transcriptPane?.bounds.width ?? 0) >= 300, "narrow_explicit_sidebar_preserves_transcript_width")
    try snapshot("narrow")
    controller.newWorkspace()
    try wait { controller.workspaceID != first && controller.state["workspace_id"] as? String == controller.workspaceID }
    try check((controller.state["messages"] as? [[String: Any]] ?? []).isEmpty, "new_workspace_does_not_inherit_previous_chat")
    try wait { (controller.state["workspaces"] as? [[String:Any]] ?? []).contains{$0["id"] as? String == first} }
    controller.command("open_workspace",["workspace_id":first])
    try wait {controller.state["workspace_id"] as? String == first}
    try check(controller.workspaceID == first,"reopen_premeeting_conversation")
    app.currentCacheID=UUID().uuidString;app.activeSession=UUID().uuidString
    controller.sync()
    try wait {controller.state["cache_id"] as? String == app.currentCacheID}
    try check(controller.workspaceID == first,"recording_binds_existing_premeeting_conversation")
    var stopped = false; controller.shutdown { stopped = true }; try wait { stopped }
    return ["status": "passed", "checks": checks, "live_subscription": live, "capture": false, "keychain": false,
            "state": controller.state, "images": ["assistant.png", "overview.png", "narrow.png"].map { directory.appendingPathComponent($0).path }]
}
