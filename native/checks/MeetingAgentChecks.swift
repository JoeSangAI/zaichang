import AppKit
import SQLite3

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
    checks += try meetingMarkdownChecks()
    checks += try meetingListenerPanelChecks(directory: directory)
    checks += try meetingAssistantReminderExportChecks(directory: directory)
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
    let firstReply="布局检查：短回复。",secondReply="布局检查：这是一段较长的助理回复，用来检查不同文字长度都从同一条左边线开始，内容能够正常换行。",userReply="查看方案"
    var layoutState=controller.state
    layoutState["messages"]=[
        ["id":"layout-user","role":"user","text":userReply,"status":"completed"],
        ["id":"layout-first","role":"assistant","text":firstReply,"status":"completed"],
        ["id":"layout-second","role":"assistant","text":secondReply,"status":"completed"]]
    // The live controller can publish another snapshot during RunLoop settling.
    // Isolate the visual fixture while exercising the same production panel.
    let layoutWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:370,height:643),styleMask:[.titled],backing:.buffered,defer:false)
    layoutWindow.isReleasedWhenClosed=false
    let layoutPanel=MeetingAgentPanel();let layoutHost=layoutWindow.contentView!;layoutHost.addSubview(layoutPanel)
    NSLayoutConstraint.activate([layoutPanel.leadingAnchor.constraint(equalTo:layoutHost.leadingAnchor),layoutPanel.trailingAnchor.constraint(equalTo:layoutHost.trailingAnchor),layoutPanel.topAnchor.constraint(equalTo:layoutHost.topAnchor),layoutPanel.bottomAnchor.constraint(equalTo:layoutHost.bottomAnchor)])
    layoutHost.layoutSubtreeIfNeeded();layoutPanel.apply(layoutState);settle();layoutHost.layoutSubtreeIfNeeded()
    let labels=descendants(layoutPanel).compactMap{$0 as? MeetingMarkdownTextView}
    guard let firstLabel=labels.first(where:{$0.string.trimmingCharacters(in: .whitespacesAndNewlines)==firstReply}),let secondLabel=labels.first(where:{$0.string.trimmingCharacters(in: .whitespacesAndNewlines)==secondReply}),let userLabel=labels.first(where:{$0.string.trimmingCharacters(in: .whitespacesAndNewlines)==userReply}) else {throw Failure(code:"chat_layout_labels_missing")}
    let firstFrame=firstLabel.convert(firstLabel.bounds,to:layoutPanel),secondFrame=secondLabel.convert(secondLabel.bounds,to:layoutPanel),userFrame=userLabel.convert(userLabel.bounds,to:layoutPanel)
    try check(abs(firstFrame.minX-secondFrame.minX)<1 && firstFrame.minX>=14 && firstFrame.minX<=26,"assistant_short_and_long_replies_share_left_margin")
    try check(userFrame.width>20 && userFrame.minX>firstFrame.minX+20 && userFrame.maxX<layoutPanel.bounds.width-12,"short_user_message_visible_and_right_aligned")
    layoutWindow.orderOut(nil)
    let first = controller.workspaceID
    controller.panel.chooseTab("笔记"); settle()
    try check(controller.panel.selectedTab == "笔记" && app.notesController?.panel.isHidden == false, "notes_tab_visible")
    controller.panel.chooseTab("概览"); settle()
    try check(controller.panel.selectedTab == "概览", "overview_independent_tab")
    controller.panel.chooseTab("助理"); settle()
    if live && !overviewOnly {
        controller.panel.submit(text: "请读取 \(root)/README.md，用两句话说明这个项目做什么、当前开发源码在哪里。这是接入验收，只读这份文件，不修改文件，不发消息，不调用其他模型。")
        try wait(180) {
            return ["completed", "failed"].contains(controller.state["conversation_status"] as? String ?? "")
        }
        try check(controller.state["conversation_status"] as? String == "completed", "native_composer_to_real_codex_completion")
        let messages = controller.state["messages"] as? [[String: Any]] ?? []
        try check(messages.contains { $0["role"] as? String == "assistant" && !($0["text"] as? String ?? "").isEmpty }, "real_reply_in_native_panel")
    }
    if overviewOnly {
        // Public synthetic requirements, used only by the explicit live probe.
        let source = ["旁听功能默认关闭，用户有需要时再打开。",
                      "助理的研究结果留在对话中，概览只总结本场原话。独立任务共享会议背景，分别显示进展。",
                      "助理可以查用户已授权的项目目录，但引用资料时必须给出真实来源。",
                      "先验证本机连接与任务恢复，再检查转写、整理和人物纠错是否保留原始记录。"]
        app.activeSession = "requirements-review"
        app.segments = [:]
        for (index, text) in source.enumerated() {
            let id = "user-confirmed-\(index)"
            app.segments[id] = ["segment_id": id, "session": "requirements-review", "source_id": "mic", "track": "mic", "epoch": "review", "start": Double(index * 30), "end": Double(index * 30 + 20), "text": text, "revision": 1, "final": true,
                                "speaker": ["basis": "anonymous_cluster", "cluster_id": 0, "source_id": "mic", "epoch": "review"]]
        }
        app.sequence = source.indices.map { "user-confirmed-\($0)" }
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

@MainActor func meetingListenerPanelChecks(directory: URL) throws -> [String] {
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 370, height: 643), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.orderOut(nil) }
    let panel = MeetingAgentPanel(), host = window.contentView!
    host.addSubview(panel)
    NSLayoutConstraint.activate([panel.leadingAnchor.constraint(equalTo: host.leadingAnchor), panel.trailingAnchor.constraint(equalTo: host.trailingAnchor), panel.topAnchor.constraint(equalTo: host.topAnchor), panel.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
    host.layoutSubtreeIfNeeded()
    panel.apply(["workspace_id": "listener", "runtime_status": "ready", "proactive": true, "listening": true,
                 "messages": [["id": "u", "role": "user", "text": "请看项目背景", "status": "completed"],
                              ["id": "a", "role": "assistant", "text": "这项前提需要核实", "origin": "say", "status": "completed"]]])
    let labels = descendants(panel).compactMap { $0 as? NSTextField }.map { $0.stringValue }
    guard labels.contains("旁听"), labels.contains("正在旁听") else { throw Failure(code: "listener_labels") }
    let texts = descendants(panel).compactMap { $0 as? NSTextView }.map { $0.string.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard texts.contains("请看项目背景"), texts.contains("这项前提需要核实") else { throw Failure(code: "single_conversation_text") }
    guard !descendants(panel).compactMap({ $0 as? NSButton }).contains(where: { $0.title.contains("任务") }) else { throw Failure(code: "task_list_removed") }
    panel.chooseTab("概览")
    guard !descendants(panel).compactMap({ $0 as? NSTextView }).contains(where: { $0.string.contains("这项前提需要核实") && !$0.isHiddenOrHasHiddenAncestor }) else { throw Failure(code: "overview_excludes_reminders") }
    panel.chooseTab("助理"); host.layoutSubtreeIfNeeded()
    guard let reminder = descendants(panel).compactMap({ $0 as? MeetingMarkdownTextView }).first(where: { $0.string.trimmingCharacters(in: .whitespacesAndNewlines) == "这项前提需要核实" }),
          reminder.bounds.height > 0, !reminder.isHiddenOrHasHiddenAncestor,
          reminder.convert(reminder.bounds, to: panel).maxY <= panel.bounds.maxY else { throw Failure(code: "say_visible_in_panel") }
    if let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
        panel.cacheDisplay(in: panel.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("listener-panel.png"))
    }
    return ["listener_switch_label", "listening_hint", "single_conversation", "no_task_list", "overview_excludes_reminders", "say_visible_in_panel"]
}

func meetingAssistantReminderExportChecks(directory: URL) throws -> [String] {
    let fm = FileManager.default, root = directory.appendingPathComponent("reminder-export-" + UUID().uuidString)
    let cache = root.appendingPathComponent("SessionCache"), assistant = root.appendingPathComponent("Assistant")
    let id = UUID().uuidString, session = UUID().uuidString, folder = cache.appendingPathComponent(id)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try fm.createDirectory(at: assistant, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["schema": 1, "cache_id": id, "session": session]).write(to: folder.appendingPathComponent("meeting.json"))
    var db: OpaquePointer?
    guard sqlite3_open(assistant.appendingPathComponent("assistant.sqlite3").path, &db) == SQLITE_OK else { throw Failure(code: "reminder_export_fixture") }
    defer { sqlite3_close(db) }
    func sql(_ text: String) throws { guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw Failure(code: "reminder_export_fixture_sql") } }
    try sql("CREATE TABLE workspace(id,cache_id); CREATE TABLE task(id,workspace_id,kind); CREATE TABLE message(text,task_id,role,created,id,origin);")
    try sql("INSERT INTO workspace VALUES('w','\(id)'); INSERT INTO task VALUES('t','w','chat');")
    for index in 0..<2 {
        try sql("INSERT INTO message VALUES('第\(index)条助理提醒','t','assistant',\(1792700000 + index),'m\(index)','say');")
    }
    try sql("INSERT INTO message VALUES('用户回答不导出','t','assistant',1792700002,'answer','user');")
    let originalDB = try Data(contentsOf: assistant.appendingPathComponent("assistant.sqlite3"))
    let text = try meetingAssistantReminderExport(cacheID: id, assistantDirectory: assistant)
    guard text.contains("第0条助理提醒"), text.contains("第1条助理提醒"), text.contains("2026-"), !text.contains("用户回答不导出") else { throw Failure(code: "reminder_export_all_evidence") }
    guard try meetingAssistantReminderExport(cacheID: "other", assistantDirectory: assistant).isEmpty else { throw Failure(code: "reminder_export_cross_meeting") }
    guard try Data(contentsOf: assistant.appendingPathComponent("assistant.sqlite3")) == originalDB else { throw Failure(code: "reminder_export_wrote_database") }
    var item = CachedMeeting(id: id, directory: folder, date: Date(), writtenBytes: 0, pendingBytes: 0, occupiedBytes: 0, tracks: [], audioCleaned: false, warning: true, retiredBytes: 0)
    item.customTitle = "助理导出验证"
    let library = try MeetingLibraryFiles.read(item, root: cache)
    let result = try MeetingFilesExportStore(cacheRoot: cache).build(item, library: library, audioStore: MeetingAudioAssetsStore(cacheRoot: cache))
    let exported = try String(contentsOf: result.folder.appendingPathComponent("助理导出验证－转写原文.txt"), encoding: .utf8)
    guard exported.components(separatedBy: "\n").filter({ $0 == "助理提醒" }).count == 1, exported.contains("第1条助理提醒") else { throw Failure(code: "reminder_export_actual_text_path") }
    guard !fm.fileExists(atPath: result.folder.appendingPathComponent("助理导出验证－AI整理稿.txt").path) else { throw Failure(code: "reminder_export_no_spurious_cleanup_file") }
    return ["reminder_export_now_later_with_evidence", "reminder_export_exact_meeting", "reminder_export_database_read_only", "reminder_export_actual_file_path", "reminder_export_no_extra_cleanup_file"]
}
