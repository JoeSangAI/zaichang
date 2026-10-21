import AppKit
import Darwin

/// Public, fictional product walkthrough rendered by the real views.
/// This is presentation content, not a recording or an AI quality benchmark.
@MainActor func publicDemoRender(directory: URL) throws -> [String: Any] {
    signal(SIGPIPE, SIG_IGN)
    guard Credential.offline, let root = Bundle.main.object(forInfoDictionaryKey: "AdapterRoot") as? String,
          directory.standardizedFileURL.path.hasPrefix(root + "/.runtime/") else { throw Failure(code: "public_demo_scope") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); NSApp.appearance = NSAppearance(named: .aqua)
    let app = Delegate(); app.previewRenderOnly = true; app.agentFeatureOverride = true
    app.agentStoreOverride = directory.appendingPathComponent("assistant")
    app.recoveryRootOverride = directory.appendingPathComponent("recordings")
    let prefs = UserDefaults(suiteName: "ZaichangPublicDemo")!
    prefs.set(430, forKey: "MeetingAgentPanelWidth"); app.sidebarPreferencesOverride = prefs
    defer { prefs.removePersistentDomain(forName: "ZaichangPublicDemo") }
    app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    defer { app.window.orderOut(nil) }
    app.window.appearance = NSApp.appearance
    app.window.setContentSize(NSSize(width: 1160, height: 760))
    app.sidebarManualVisible = false; app.layoutWorkspace()
    guard let controller = app.agentController else { throw Failure(code: "public_demo_assistant") }
    var stopped = false
    controller.shutdown { stopped = true }
    let deadline = Date().addingTimeInterval(10)
    while !stopped && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    controller.panel.onCommand = nil
    app.meetingTitle = "新品试用 · 用户访谈复盘"
    app.receive(["type":"started", "session":"public-walkthrough", "mock":true, "capture":false])
    let turns: [(String, String)] = [
        ("林溪", "这次先讨论试用反馈。大家都喜欢一键开始，但第一次进来，还不知道应该先准备什么。"),
        ("陈默", "上周访谈里也有这个问题。我们先把新手引导缩短，第一次只让用户完成一个动作。"),
        ("林溪", "对，先完成第一次记录。项目资料可以稍后补充，不要挡住开始。"),
        ("陈默", "那首页先保留开始按钮。我明天整理两个文案方案，周五再邀请几位用户试用。"),
        ("林溪", "还要把没有讨论到的风险补一下：用户中途退出后，已经记录的内容是否还能找回来？")
    ]
    for (index, turn) in turns.enumerated() {
        let id = "demo-\(index)"
        app.receive(["type":"segment", "segment_id":id, "session":"public-walkthrough", "track":"mic", "text":turn.1,
                     "start":Double(index * 36 + 20), "end":Double(index * 36 + 40), "final":true, "revision":1,
                     "speaker":["basis":"anonymous_cluster", "cluster_id":index % 2]])
        app.naming.set(segment:id, name:turn.0)
    }
    app.phase.phase = .paused; app.phase.elapsed = 220
    app.renderText(); try app.settleTranscriptForOfflineReview(); app.updateUI()
    let snapshot: [String: Any] = [
        "runtime_status":"ready", "proactive":false,
        "tasks":[["id":"question", "title":"整理试用安排", "status":"completed", "origin":"user"]],
        "messages":[
            ["id":"user", "role":"user", "task_id":"question", "text":"结合刚才的讨论，整理一下这周的试用安排。"],
            ["id":"reply", "role":"assistant", "task_id":"question", "status":"completed", "text":"这周可以分两步推进：\n\n明天：陈默准备两个首页文案方案，重点解释怎样开始第一次记录。\n\n周五：邀请用户试用，观察能否独立完成第一次记录。\n\n还有一项尚未定：中途退出后如何找回记录。建议把它加入试用检查。"]
        ],
        "meeting_overview":["status":"ready", "data":[
            "current_topic":["text":"降低第一次使用的门槛"],
            "discussion_points":[["text":"用户喜欢一键开始，但不清楚会前需要准备什么。"],["text":"项目资料可以稍后补充。"]],
            "decisions":[["text":"首页聚焦开始记录，缩短首次引导。"]],
            "actions":[["text":"准备两个首页文案方案", "owner":"陈默", "deadline":"明天"],["text":"邀请用户参加试用", "deadline":"周五"]],
            "open_questions":[["text":"中途退出后，用户如何找回已有记录？"]]
        ]]
    ]
    controller.panel.apply(snapshot)
    func save(_ name: String) throws {
        app.window.contentView!.layoutSubtreeIfNeeded()
        let end = Date().addingTimeInterval(0.2)
        while Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        // Runtime shutdown notifications can arrive while the run loop settles.
        // Apply the labelled demonstration state after those callbacks finish.
        controller.panel.apply(snapshot)
        app.window.contentView!.layoutSubtreeIfNeeded()
        let target = app.window.contentView!
        guard let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { throw Failure(code: "public_demo_bitmap") }
        target.effectiveAppearance.performAsCurrentDrawingAppearance { target.cacheDisplay(in:target.bounds, to:bitmap) }
        try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name + ".png"))
    }
    controller.panel.chooseTab("助理"); try save("meeting-assistant")
    controller.panel.chooseTab("概览"); try save("meeting-overview")
    return ["images":["meeting-assistant.png","meeting-overview.png"], "content":"fictional public walkthrough", "render":"actual AppKit product views", "network":false, "capture":false, "private_records":false]
}
