import AppKit

@MainActor func meetingTranslationChecks(directory: URL) throws -> [String: Any] {
    guard Credential.offline else { throw Failure(code:"offline_only") }
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let root=directory.appendingPathComponent("translation-"+UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:name)};checks.append(name)}
    func wait(_ condition:()->Bool)throws {
        let end=Date().addingTimeInterval(5)
        while !condition(),Date()<end {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}
        try check(condition(),"async_\(checks.count)")
    }
    let first=UUID().uuidString,second=UUID().uuidString
    for id in [first,second] {try FileManager.default.createDirectory(at:root.appendingPathComponent(id),withIntermediateDirectories:true)}
    let source="We should send the revised plan on Friday.",translated="我们应该在周五发送修订后的计划。"
    let store=MeetingTranslationStore(meetingDirectory:root.appendingPathComponent(first))
    try store.saveEnabled(false)
    let service=MeetingTranslationService()
    service.credentialLoader={"offline-fixture"}
    var restored=0,calls:[String]=[],notifications:[String]=[]
    service.onRestored={restored+=1};service.onTranslated={notifications.append($0)}
    service.translator={text,_ in calls.append(text);try await Task.sleep(nanoseconds:20_000_000);return text==source ? translated:"修订后的译文"}
    service.bind(cacheID:first,root:root);try wait{restored==1}
    try check(!service.enabled && calls.isEmpty,"default_off_no_provider_request")
    func item(_ text:String,_ final:Bool=true)->[String:Any] {["text":text,"final":final]}
    try check(!MeetingTranslationPolicy.eligible(item("这是中文。")),"chinese_not_retranslated")
    try check(!MeetingTranslationPolicy.eligible(item(source,false)),"partial_not_translated")
    try check(!MeetingTranslationPolicy.eligible(["text":source,"final":true,"quality_flags":["source_needs_review"]]),"flagged_source_not_translated")
    try check(!MeetingTranslationPolicy.eligible(["text":source,"final":true,"quality_flags":"invalid"]),"malformed_quality_fails_closed")
    try check(!MeetingTranslationPolicy.eligible(["text":source,"final":true,"text_quality":"needs_review"]),"review_source_not_translated")
    try service.setEnabled(true,apiKey:"offline-fixture")
    service.accept(segmentID:"sentence",item:item(source));service.accept(segmentID:"sentence",item:item(source))
    try wait{service.translated(segmentID:"sentence",source:source)==translated}
    try check(calls==[source] && notifications==["sentence"],"one_request_per_sentence_hash_and_visible_notification")
    let loaded=try store.load()
    try check(loaded.1["sentence:"+MeetingTranslationService.hash(source)]==translated,"translation_persisted_by_source_hash")
    try service.setEnabled(false,apiKey:nil)
    try check(service.translated(segmentID:"sentence",source:source)==nil,"off_hides_cached_translation")
    try service.setEnabled(true,apiKey:"offline-fixture");service.accept(segmentID:"sentence",item:item(source))
    try check(calls.count==1 && service.translated(segmentID:"sentence",source:source)==translated,"re_enable_reuses_saved_translation")
    let revised="The revised plan is due next Monday."
    try check(service.translated(segmentID:"sentence",source:revised)==nil,"revised_source_cannot_reuse_stale_translation")
    service.accept(segmentID:"sentence",item:item(revised));try wait{service.translated(segmentID:"sentence",source:revised) != nil}
    service.accept(segmentID:"late",item:item("This request belongs to the first meeting."))
    service.bind(cacheID:second,root:root);try wait{restored==2}
    try check(!service.enabled && service.texts.isEmpty,"switch_meeting_cancels_requests_and_isolates_cache")
    service.bind(cacheID:first,root:root);try wait{restored==3}
    try check(service.enabled && service.translated(segmentID:"sentence",source:source)==translated,"reopen_restores_enabled_setting_and_saved_translation")
    let savedCalls=calls.count;service.accept(segmentID:"sentence",item:item(revised))
    try check(calls.count==savedCalls,"reopen_does_not_repeat_completed_translation")
    service.accept(segmentID:"cancelled",item:item("This request is cancelled when translation is off."))
    try service.setEnabled(false,apiKey:nil)
    let end=Date().addingTimeInterval(0.1)
    while Date()<end {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}
    try check(!service.texts.keys.contains(where:{$0.hasPrefix("cancelled:")}),"off_does_not_publish_inflight_result")
    let restoredService=MeetingTranslationService();restoredService.credentialLoader={"offline-fixture"}
    var restoredOff=false;restoredService.onRestored={restoredOff=true};restoredService.bind(cacheID:first,root:root);try wait{restoredOff}
    try check(!restoredService.enabled,"off_setting_survives_reopen")
    return ["type":"meeting_translation_checks","checks":checks,"network":false,"capture":false,"keychain":false,"passed":checks.count]
}

/// A fictional meeting matching the approved toolbar mock. The screenshot uses
/// production AppKit views and an injected translator; no recording/provider runs.
@MainActor func meetingTranslationUIChecks(directory:URL)throws->[String:Any] {
    guard Credential.offline,let adapterRoot=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,
          directory.standardizedFileURL.path.hasPrefix(adapterRoot+"/.runtime/") else {throw Failure(code:"translation_ui_scope")}
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:name)};checks.append(name)}
    func wait(_ condition:()->Bool)throws {
        let end=Date().addingTimeInterval(10)
        while !condition(),Date()<end {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}
        try check(condition(),"ui_async_\(checks.count)")
    }
    func settle() {let end=Date().addingTimeInterval(0.15);while Date()<end {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}}
    let fixtures=directory.appendingPathComponent("fixtures-"+UUID().uuidString,isDirectory:true)
    let id=UUID().uuidString;try FileManager.default.createDirectory(at:fixtures.appendingPathComponent(id),withIntermediateDirectories:true)
    let app=Delegate();app.previewRenderOnly=true;app.agentFeatureOverride=true
    app.recoveryRootOverride=fixtures;app.agentStoreOverride=directory.appendingPathComponent("assistant-"+UUID().uuidString)
    app.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    // configureOfflineQA installs the default QA cache during launch. Bind the
    // explicitly created fixture root afterwards, as the other UI checks do.
    app.recoveryRootOverride=fixtures
    try check(app.recoveryBase().standardizedFileURL==fixtures.standardizedFileURL,"fixture_root_survives_qa_startup")
    defer{app.window.orderOut(nil)}
    app.window.appearance=NSAppearance(named:.aqua)
    app.window.setContentSize(NSSize(width:1280,height:776));app.layoutWorkspace()
    app.meetingTitle="新加坡合作｜试点范围与预算";app.activeSession="translation-ui-fixture"
    app.translationService.credentialLoader={"offline-fixture"}
    var restored=false;let onRestored=app.translationService.onRestored
    app.translationService.onRestored={restored=true;onRestored?()}
    let sources=[
        "Let's confirm the pilot scope before we discuss pricing, location and implementation. Let's go through the requirements together so every participant understands the proposed agreement.",
        "We can start with two teams in Singapore next month.",
        "The budget is 25,000 dollars for the first three months.",
        "Alice will send the timeline by Friday.",
        "We still need a clear definition of success."]
    let translations=[
        "我们先确认试点范围，再讨论价格、地点和实施。一起核对需求，确保每位参会者都理解拟议的协议。",
        "下个月可以先从新加坡的两个团队开始。",
        "前三个月的预算是 25,000 美元。",
        "Alice 会在周五前发出时间表。",
        "我们还需要明确定义成功的衡量标准。"]
    app.translationService.translator={source,_ in
        guard let index=sources.firstIndex(of:source) else{throw Failure(code:"unexpected_translation_fixture")}
        return translations[index]
    }
    app.currentCacheID=id;try wait{restored}
    for (index,source) in sources.enumerated() {
        app.receive(["type":"segment","session":"translation-ui-fixture","segment_id":"english-\(index)","revision":1,"source_id":"remote","track":"remote","text":source,"final":true,"start":Double(index*15),"end":Double(index*15+12)])
    }
    app.phase.phase = .paused;app.phase.elapsed=125;app.cachedTranscriptionComplete=true;app.updateUI()
    try app.settleTranscriptForOfflineReview();settle()
    try check(app.translationSwitch != nil && app.translationSwitch?.state == .off,"translation_control_present_and_off")
    try check(!app.output.string.contains(translations[1]),"off_shows_original_only")
    try app.translationService.setEnabled(true,apiKey:"offline-fixture")
    app.translationService.enqueueExisting(app.readingTurns())
    try wait{app.translationService.texts.count==sources.count}
    try app.settleTranscriptForOfflineReview();settle()
    try check(app.output.string.contains(sources[1]) && app.output.string.contains(translations[1]),"translation_completion_refreshes_native_transcript")
    try check(app.transcriptExport().contains("中译：") && app.transcriptExport().contains(translations[1]),"export_includes_visible_translations")
    try check(app.segments["english-1"]?["text"] as? String==sources[1],"translation_does_not_modify_raw_transcript")
    guard let controller=app.agentController else {throw Failure(code:"translation_ui_assistant_missing")}
    controller.resizePanel(to:340,persist:false)
    // Reference-only panel copy, explicitly separate from runtime/model output.
    let previousCommand=controller.panel.onCommand;controller.panel.onCommand=nil
    controller.panel.chooseTab("概览")
    controller.panel.apply(["runtime_status":"offline","meeting_overview":["status":"ready","stale":false,"data":[
        "current_topic":["text":"试点范围与启动时间"],
        "discussion_points":[["text":"先从新加坡的两个团队开始，逐项核对范围、预算与实施。"]],
        "decisions":[["text":"先做两个团队的试点。"]],
        "actions":[["text":"发送试点时间表。","owner":"Alice","deadline":"周五前"]],
        "open_questions":[["text":"明确成功的衡量标准。"]]]]])
    settle();app.window.contentView?.layoutSubtreeIfNeeded()
    var images:[String]=[]
    func snapshot(_ name:String)throws {
        guard let target=app.window.contentView,let bitmap=target.bitmapImageRepForCachingDisplay(in:target.bounds) else {throw Failure(code:"translation_ui_bitmap")}
        target.effectiveAppearance.performAsCurrentDrawingAppearance {target.cacheDisplay(in:target.bounds,to:bitmap)}
        let file=directory.appendingPathComponent(name+".png")
        try bitmap.representation(using:.png,properties:[:])!.write(to:file);images.append(file.path)
    }
    try check(abs(controller.panel.bounds.width-340)<1,"panel_actual_width_matches_requested_width")
    try snapshot("bilingual-overview")
    controller.panel.chooseTab("助理");settle();try snapshot("bilingual-assistant")
    try app.translationService.setEnabled(false,apiKey:nil);try app.settleTranscriptForOfflineReview();settle()
    try check(!app.output.string.contains(translations[1]) && !app.transcriptExport().contains("中译："),"off_refreshes_native_view_and_export")
    try snapshot("translation-off")
    app.window.setContentSize(NSSize(width:640,height:720));app.layoutWorkspace();settle()
    try check(!controller.expanded && app.translationSwitch?.isHiddenOrHasHiddenAncestor==false,"narrow_keeps_translation_and_collapses_assistant")
    try snapshot("narrow")
    controller.panel.onCommand=previousCommand
    var stopped=false;controller.shutdown{stopped=true};try wait{stopped}
    return ["type":"meeting_translation_ui_checks","checks":checks,"passed":checks.count,"images":images,"fixture_content":true,"overview_copy_is_reference_only":true,"network":false,"capture":false,"keychain":false]
}
