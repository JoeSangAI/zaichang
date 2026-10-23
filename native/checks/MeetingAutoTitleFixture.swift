import Foundation
import AppKit

private actor FixtureTitleCallCounter {
    private var calls = 0
    func record() { calls += 1 }
    func count() -> Int { calls }
}

private struct FixtureTitleProvider: MeetingTitleProvider {
    let titleText: String
    let delayNanoseconds: UInt64
    let counter: FixtureTitleCallCounter?
    init(titleText: String, delayNanoseconds: UInt64, counter: FixtureTitleCallCounter? = nil) {
        self.titleText = titleText; self.delayNanoseconds = delayNanoseconds; self.counter = counter
    }
    func title(for transcript: String) async throws -> String {
        precondition(transcript.contains("品牌营销"))
        await counter?.record()
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        return titleText
    }
}

private actor SequenceTitleProvider:MeetingTitleProvider {
    let value:String;let delay:UInt64;let failures:Int
    private(set) var calls=0
    init(_ value:String,delay:UInt64=0,failures:Int=0){self.value=value;self.delay=delay;self.failures=failures}
    func title(for transcript:String) async throws->String {
        calls+=1
        if delay>0 {try await Task.sleep(nanoseconds:delay)}
        if calls<=failures {throw MeetingAutoTitleError.providerFailure}
        return value
    }
}

private actor RotatingTitleProvider:MeetingTitleProvider {
    let titles:[String];let delay:UInt64
    private(set) var transcripts:[String]=[]
    var calls:Int {transcripts.count}
    init(_ titles:[String],delay:UInt64=0){self.titles=titles;self.delay=delay}
    func title(for transcript:String) async throws->String {
        let index=transcripts.count
        transcripts.append(transcript)
        if delay>0 {try await Task.sleep(nanoseconds:delay)}
        return titles[min(index,titles.count-1)]
    }
}

private struct GroundedTermTitleProvider:MeetingTitleProvider {
    let output:String
    func title(for transcript:String) async throws->String {
        guard !transcript.contains("原文中出现的识别词") && transcript.contains("简知") && transcript.contains("我最近在减脂") else {
            throw MeetingAutoTitleError.invalidResponse
        }
        return output
    }
}

@MainActor func meetingTitleSequenceChecks(directory:URL) async throws->[String:Any] {
    guard Credential.offline,directory.path.contains("/.runtime/") else{throw Failure(code:"title_sequence_fixture_scope")}
    _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let view=Delegate();view.previewRenderOnly=true;view.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));view.recoveryRootOverride=directory
    let bridge=directory.appendingPathComponent("bridge");view.contextPublisher=MeetingContextPublisher(directory:bridge)
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:name)};checks.append(name)}
    func prepare(_ session:String,provider:MeetingTitleProvider)throws->URL {
        let id=UUID().uuidString,folder=directory.appendingPathComponent(id)
        let journal=try RecordingJournal(directory:folder,track:"mic",freeSpace:{1_000_000_000})
        try journal.enqueue(Data(repeating:0,count:3200),at:0);journal.finish();journal.wait()
        try JSONSerialization.data(withJSONObject:["session":session,"cache_id":id,"bundle":"*microphone*"]).write(to:folder.appendingPathComponent("meeting.json"))
        view.activeSession=session;view.currentCacheID=id;view.meetingTitle="默认会议名称";view.phase.phase = .paused
        view.lastRecordingControlRevision = -1;view.pausedTailRevision=nil;view.pausedTailStates=[:]
        let event:[String:Any]=["type":"segment","session":session,"segment_id":"title-input","source_id":"mic","track":"mic","epoch":"title-sequence","revision":1,"start":0.0,"end":3.0,"final":true,"text":"这场合成会议讨论产品人物标注、名称保存和下一轮验收计划。","speaker":["basis":"unknown"]]
        journal.record(event);journal.wait();view.receive(event)
        view.beginMeetingContext();view.previewRenderOnly=false;view.titleProvider=provider;view.titleTextAllowed=true
        return folder
    }
    func wait(_ predicate:()->Bool) async throws {
        let until=Date().addingTimeInterval(4)
        while !predicate(),Date()<until {try await Task.sleep(nanoseconds:10_000_000)}
        guard predicate() else{throw Failure(code:"title_sequence_deadline")}
    }
    func bridgeTitle(_ session:String)throws->String? {
        view.contextPublisher?.flushForChecks()
        let proc=Process(),pipe=Pipe();proc.executableURL=URL(fileURLWithPath:"/usr/local/bin/python3");proc.arguments=[view.root+"/meeting_context.py","--database",bridge.appendingPathComponent("context.sqlite").path,"read","--session",session];proc.standardOutput=pipe;proc.standardError=FileHandle.nullDevice
        try proc.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();proc.waitUntilExit();guard proc.terminationStatus==0 else{throw Failure(code:"title_bridge_read_failed")}
        let value=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        return (value["meeting"] as? [String:Any])?["title"] as? String
    }
    func ageTitle(_ folder:URL) throws {
        let file=folder.appendingPathComponent("display-info.json")
        var value=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        value["attempted_at"]=Date().timeIntervalSince1970-301
        try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:file,options:.atomic)
    }
    func append(_ event:[String:Any],to folder:URL)throws {
        let file=folder.appendingPathComponent("mic-transcript.jsonl")
        var bytes=try Data(contentsOf:file)
        bytes.append(try JSONSerialization.data(withJSONObject:event,options:.sortedKeys));bytes.append(10)
        try bytes.write(to:file,options:.atomic)
        view.receive(event)
    }
    let firstProvider=SequenceTitleProvider("产品标注｜验收计划",delay:200_000_000)
    let first=try prepare("title-first",provider:firstProvider)
    view.scheduleAutoTitle();try await Task.sleep(nanoseconds:30_000_000)
    view.receive(["type":"stopped","session":"title-first","reason":"capture_owner_exited","transcription_complete":false])
    view.newMeeting()
    let second=try prepare("title-second",provider:SequenceTitleProvider("独立会议｜验收计划"))
    view.receive(["type":"stopped","session":"title-second","reason":"user_stop","transcription_complete":false])
    try await wait({view.finalTitleTasks.isEmpty})
    try check(try MeetingLibraryInfo.loadTitle(in:first)=="产品标注｜验收计划","previous_failed_session_final_title_survives_new_meeting")
    try check(view.meetingTitle=="独立会议｜验收计划" && (try MeetingLibraryInfo.loadTitle(in:second))==view.meetingTitle,"late_first_title_never_changes_second_meeting")
    try check(try bridgeTitle("title-first")=="产品标注｜验收计划" && bridgeTitle("title-second")==view.meetingTitle,"saved_and_current_bridge_titles_match_sidecars")
    view.newMeeting()
    let liveProvider=RotatingTitleProvider(["实时转写｜讨论方案","示例项目推进｜产品命名与用户调研"],delay:100_000_000)
    let live=try prepare("title-live",provider:liveProvider);view.phase.phase = .recording
    view.scheduleAutoTitle();view.scheduleAutoTitle();view.scheduleAutoTitle()
    try await wait({view.meetingTitle=="实时转写｜讨论方案" && view.titleTask==nil})
    let liveCalls=await liveProvider.calls
    try check(liveCalls==1 && (try MeetingDisplayInfoStore.load(in:live))?.state == .ready,
              "recording_generates_one_provisional_title_after_final_text_threshold")
    view.scheduleAutoTitle();try await Task.sleep(nanoseconds:50_000_000)
    try check(await liveProvider.calls==1,"recording_keeps_provisional_title")
    try ageTitle(live)
    view.scheduleAutoTitle();try await Task.sleep(nanoseconds:30_000_000)
    try check(await liveProvider.calls==1,"elapsed_time_without_new_text_does_not_refresh_title")
    // Synthetic later topics are absorbed at pause, not during recording.
    let laterText="""
    示例项目接下来讨论用户调研。第一阶段的问卷收集完成了一半，团队正在检查提交格式是否一致。现阶段的数据不足以说明最终偏好，所以先记录发现的问题，不把初步意见当成最终结论。第二阶段需要确认参与范围和统计口径，并把待确认内容写到项目说明中。
    新产品的命名方案也需要继续比较。每个候选名称都应当有明确来源，团队会检查是否容易理解、是否和其他产品混淆。没有确认的名称暂时只保留在正文中，不加入正式术语表。下次讨论时再根据书面材料决定采用哪个写法。
    渠道分析将按同一时间范围汇总公开数据。不同平台的受众、展示方式和衡量指标可能存在差异，所以不能只比较单个数字。团队会先记录数据条件，再讨论哪些结果可以支持当前方案。涉及预算和时间安排的决定仍需负责人员确认。
    最后还需要区分品牌传播和日常触达。两个方案分别描述目标、证据与验证方法，并在项目材料中保留修改依据。今天只明确下一轮需要补充哪些材料，不增加未经讨论的承诺。以上内容均为公开测试示例，不涉及真实客户或会议。
    """
    var progressEvent:[String:Any]=["type":"segment","session":"title-live","segment_id":"title-progress",
        "source_id":"mic","track":"mic","epoch":"title-sequence","revision":1,"start":609.0,"end":1641.0,
        "final":false,"text":laterText,"speaker":["basis":"unknown"]]
    try append(progressEvent,to:live);view.scheduleAutoTitle();try await Task.sleep(nanoseconds:30_000_000)
    try check(await liveProvider.calls==1,"new_partial_text_does_not_refresh_live_title")
    progressEvent["final"]=true;progressEvent["revision"]=2
    try append(progressEvent,to:live);try await Task.sleep(nanoseconds:30_000_000)
    try ageTitle(live);view.scheduleAutoTitle()
    try await Task.sleep(nanoseconds:30_000_000)
    try check(await liveProvider.calls==1 && view.meetingTitle=="实时转写｜讨论方案",
              "substantial_new_final_text_does_not_rename_during_recording")
    view.receive(["type":"recording_paused","session":"title-live","control_revision":1,"draining_tracks":[]])
    try await wait({view.titleTask==nil})
    try check(await liveProvider.calls==2
              && view.meetingTitle=="示例项目推进｜产品命名与用户调研",
              "pause_without_pending_tail_calibrates_title_once")
    try check(try bridgeTitle("title-live")==view.meetingTitle,"pause_refresh_publishes_saved_title")
    view.window.setContentSize(NSSize(width:1050,height:780));view.updateUI()
    view.previewRenderOnly=true
    try view.settleTranscriptForOfflineReview()
    view.previewRenderOnly=false
    let content=view.window.contentView!;content.layoutSubtreeIfNeeded()
    guard let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) else{throw Failure(code:"title_progress_render_failed")}
    content.cacheDisplay(in:content.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("title-progress.png"))
    view.receive(["type":"recording_resumed","session":"title-live","control_revision":2])
    progressEvent["segment_id"]="title-resumed";progressEvent["start"]=1674.75;progressEvent["end"]=1680.0
    progressEvent["text"]="还有一个示例事项需要确认，请负责同事在下次讨论前补充公开材料。"
    try ageTitle(live);try append(progressEvent,to:live);try await Task.sleep(nanoseconds:30_000_000)
    try check(await liveProvider.calls==2,"resumed_recording_keeps_previous_title")
    view.receive(["type":"recording_paused","session":"title-live","control_revision":3,"draining_tracks":[]])
    try await wait({view.titleTask==nil})
    let resumedInputs=await liveProvider.transcripts
    try check(resumedInputs.count==3 && resumedInputs[2].contains("示例事项需要确认"),"next_pause_includes_resumed_content")
    view.renameMeeting("本人确认的会议范围");view.cacheWriteQueue.sync{};try ageTitle(live)
    view.scheduleAutoTitle();try await Task.sleep(nanoseconds:30_000_000)
    try check(await liveProvider.calls==3 && view.meetingTitle=="本人确认的会议范围","pause_refresh_respects_manual_title")
    view.newMeeting()
    let tailProvider=RotatingTitleProvider(["直播标题｜初始主题","直播标题｜尾段议题"],delay:120_000_000)
    let tailFolder=try prepare("title-pause-tail",provider:tailProvider);view.phase.phase = .recording
    view.scheduleAutoTitle()
    try await wait({view.titleTask==nil && view.meetingTitle=="直播标题｜初始主题"})
    view.coarseRefinementExecutorOverride={_,token,done in done(token,.failure(MeetingAutoTitleError.providerFailure))}
    view.receive(["type":"recording_paused","session":"title-pause-tail","control_revision":1,"draining_tracks":["mic"]])
    let tailEvent:[String:Any]=["type":"segment","session":"title-pause-tail","segment_id":"title-tail",
        "source_id":"mic","track":"mic","epoch":"title-sequence","revision":1,"start":4.0,"end":6.0,
        "final":true,"text":"暂停后补齐的尾段确认了新的验收议题。","speaker":["basis":"unknown"]]
    let tailTranscript=tailFolder.appendingPathComponent("mic-transcript.jsonl")
    var tailBytes=try Data(contentsOf:tailTranscript)
    tailBytes.append(try JSONSerialization.data(withJSONObject:tailEvent,options:[.sortedKeys]));tailBytes.append(10)
    try tailBytes.write(to:tailTranscript,options:.atomic)
    view.receive(tailEvent)
    // Exercise the production coarse-refinement branch instead of directly
    // calling scheduleAutoTitle (which previously hid the missing trigger).
    try await Task.sleep(nanoseconds:30_000_000)
    try check(await tailProvider.calls==1 && view.titleTask==nil,"pause_waits_for_tail_without_intermediate_title_request")
    view.receive(["type":"recording_pause_tail","session":"title-pause-tail","pause_revision":1,"track":"mic","state":"complete"])
    try await wait({view.meetingTitle=="直播标题｜尾段议题" && view.titleTask==nil})
    let tailTranscripts=await tailProvider.transcripts
    try check(tailTranscripts.count==2 && tailTranscripts[1].contains("暂停后补齐的尾段确认了新的验收议题"),
              "pause_and_tail_completion_queue_latest_changed_snapshot_once")
    view.coarseRefinementExecutorOverride=nil
    view.newMeeting()
    let retryProvider=SequenceTitleProvider("中断会议｜准确重试主题",failures:1)
    let third=try prepare("title-retry",provider:retryProvider);view.phase.phase = .failed;view.updateUI();view.finalizeSessionTitle()
    try await wait({view.finalTitleTasks.isEmpty})
    let calls=await retryProvider.calls
    try check(calls==2 && (try MeetingDisplayInfoStore.load(in:third))?.state == .ready && view.meetingTitle=="中断会议｜准确重试主题","failed_final_title_gets_one_bounded_retry_and_visible_result")
    try check(try bridgeTitle("title-retry")==view.meetingTitle,"retry_title_updates_bridge_after_failure")
    view.renameMeeting("本人确认的最终会议名称");view.cacheWriteQueue.sync{}
    try check((try MeetingLibraryInfo.loadTitle(in:third))=="本人确认的最终会议名称" && (try bridgeTitle("title-retry"))=="本人确认的最终会议名称","manual_title_and_bridge_remain_authoritative")
    view.previewRenderOnly=true;view.window.orderOut(nil)
    return ["type":"title_sequence_checks","passed":checks.count,"checks":checks,"provider_calls_after_one_failure":calls,"capture":false,"cloud":false,"keychain":false]
}

// Synthetic, offline only. Call from the model self-test without credentials.
func meetingAutoTitleFixture() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-title-fixture-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let id = UUID().uuidString
    let folder = root.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let session = "fixture-session"
    try JSONSerialization.data(withJSONObject: ["session": session, "cache_id": id])
        .write(to: folder.appendingPathComponent("meeting.json"))
    let events: [[String: Any]] = [
        ["segment_id": "a", "start": 0.0, "final": true, "text": "品牌营销超能体讨论了客户需求与课程方向，先整理学员访谈。"],
        ["segment_id": "b", "start": 5.0, "final": true, "text": "团队决定下周核对服务交付范围，报价和分工仍待确认。"]
    ]
    let liveEvents=events+[["segment_id":"partial","start":8.0,"final":false,
                            "text":"这段尚未完成的实时转写不能进入录音中标题。"]]
    guard let liveInput=MeetingTitleInput(events:liveEvents,finalOnly:true),
          !liveInput.transcript.contains("尚未完成"),
          MeetingTitleInput(events:liveEvents)?.transcript.contains("尚未完成")==true else {
        throw Failure(code:"title_live_input_must_use_final_text_only")
    }
    let service = MeetingAutoTitle()
    let counter = FixtureTitleCallCounter()
    let mock = FixtureTitleProvider(titleText: "会议标题：**品牌营销｜服务方向讨论。**", delayNanoseconds: 0, counter: counter)
    let first = await service.generate(cacheID: id, session: session, directory: folder,
                                       events: events, provider: mock, cloudTextAllowed: true)
    guard case .saved("品牌营销｜服务方向讨论") = first else { throw MeetingAutoTitleError.invalidResponse }
    guard let saved = try MeetingDisplayInfoStore.load(in: folder), saved.provenance == .automatic,
          saved.state == .ready, saved.session == session, saved.cacheID == id,
          saved.sourceDigest == MeetingTitleInput(events: events)?.digest else { throw MeetingAutoTitleError.invalidSidecar }
    let duplicate = await service.generate(cacheID: id, session: session, directory: folder,
                                           events: events, provider: mock, cloudTextAllowed: true, finalized: true)
    guard case .unchanged = duplicate, await counter.count() == 1 else { throw MeetingAutoTitleError.invalidResponse }

    // The requested examples define the compact title shape. Normalize an
    // ASCII separator, and reject provider output that is a sentence or list.
    let formatEvents: [[String: Any]] = [
        ["segment_id": "format", "start": 0.0,
         "text": "品牌营销团队讨论客户投放，比较青浦奥莱选点与广佛效果验证，并确认采购边界和四周试投安排。"]
    ]
    func makeFormatFolder() throws -> URL {
        let formatID = UUID().uuidString, formatFolder = root.appendingPathComponent(formatID)
        try FileManager.default.createDirectory(at: formatFolder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["session": session, "cache_id": formatID])
            .write(to: formatFolder.appendingPathComponent("meeting.json"))
        return formatFolder
    }
    let formatFolder = try makeFormatFolder()
    let formatID = formatFolder.lastPathComponent
    let asciiProvider = FixtureTitleProvider(titleText: "客户投放 | 青浦奥莱选点与广佛效果验证", delayNanoseconds: 0)
    let formatted = await service.generate(cacheID: formatID, session: session, directory: formatFolder,
                                            events: formatEvents, provider: asciiProvider, cloudTextAllowed: true)
    guard case .saved("客户投放｜青浦奥莱选点与广佛效果验证") = formatted else {
        throw MeetingAutoTitleError.invalidResponse
    }
    let groundedFolder=try makeFormatFolder(),groundedID=groundedFolder.lastPathComponent
    try JSONSerialization.data(withJSONObject:["session":session,"cache_id":groundedID,
        "asr_vocabulary_confirmed":true,"asr_vocabulary":["简知":2]],options:[.sortedKeys])
        .write(to:groundedFolder.appendingPathComponent("meeting.json"),options:.atomic)
    let groundedEvents:[[String:Any]]=[["segment_id":"grounded","start":0.0,
        "text":"这次会议聊到简知这个中老年教育平台的课程，也有人说我最近在减脂。"]]
    let grounded=await service.generate(cacheID:groundedID,session:session,directory:groundedFolder,
        events:groundedEvents,provider:GroundedTermTitleProvider(output:"简知｜平台试投"),cloudTextAllowed:true)
    guard case .saved("简知｜平台试投")=grounded else {
        throw MeetingAutoTitleError.invalidResponse
    }
    // Regression from the 2026-10-20 call: unrelated global ASR terms must
    // neither enter the title prompt nor change its digest.
    let reportedEvents:[[String:Any]]=[["segment_id":"reported-call","start":28.0,"final":true,
        "text":"我们还是想找到，比方说千问办公和codex这些产品的差异化。所以我就想听一听你在一线的感受是怎么样子。"]]
    let invalidFolder = try makeFormatFolder()
    let invalidID = invalidFolder.lastPathComponent
    let invalidProvider = FixtureTitleProvider(titleText: "客户投放讨论青浦奥莱选点与广佛效果验证。", delayNanoseconds: 0)
    let invalid = await service.generate(cacheID: invalidID, session: session, directory: invalidFolder,
                                         events: formatEvents, provider: invalidProvider, cloudTextAllowed: true)
    guard case .failed = invalid,
          try MeetingDisplayInfoStore.load(in: invalidFolder)?.state == .failed,
          try MeetingDisplayInfoStore.load(in: invalidFolder)?.title.isEmpty == true else {
        throw MeetingAutoTitleError.invalidResponse
    }

    // Stopped transcription can add a final sentence immediately after the pause.
    // It gets one updated title despite the ordinary 60-second pause cooldown.
    let finalEvents = events + [["segment_id": "c", "start": 10.0,
                                 "text": "品牌营销最终确定先做客户访谈，再核对服务范围和报价。"]]
    let refreshed = await service.generate(cacheID: id, session: session, directory: folder,
                                           events: finalEvents, provider: mock, cloudTextAllowed: true, refresh:true)
    guard case .saved = refreshed,
          try MeetingDisplayInfoStore.load(in: folder)?.sourceDigest == MeetingTitleInput(events: finalEvents)?.digest,
          await counter.count() == 2 else { throw MeetingAutoTitleError.invalidResponse }
    let repeatedFinal = await service.generate(cacheID: id, session: session, directory: folder,
                                               events: finalEvents, provider: mock, cloudTextAllowed: true, finalized: true)
    guard case .unchanged = repeatedFinal, await counter.count() == 2 else { throw MeetingAutoTitleError.invalidResponse }

    try MeetingDisplayInfoStore.saveManual("人工确认：客户需求与课程", in: folder)
    let manual = await service.generate(cacheID: id, session: session, directory: folder,
                                        events: finalEvents, provider: mock, cloudTextAllowed: true, finalized: true)
    guard case .manual = manual,
          try MeetingDisplayInfoStore.load(in: folder)?.title == "人工确认：客户需求与课程",
          await counter.count() == 2 else {
        throw MeetingAutoTitleError.invalidResponse
    }

    // An in-flight result cannot overwrite a manual edit or cross a resume boundary.
    let nextID = UUID().uuidString
    let nextFolder = root.appendingPathComponent(nextID)
    try FileManager.default.createDirectory(at: nextFolder, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["session": session, "cache_id": nextID])
        .write(to: nextFolder.appendingPathComponent("meeting.json"))
    let pendingCounter = FixtureTitleCallCounter()
    let delayed = FixtureTitleProvider(titleText: "品牌营销｜迟到标题不应写入", delayNanoseconds: 200_000_000, counter: pendingCounter)
    let pending = Task { await service.generate(cacheID: nextID, session: session, directory: nextFolder,
                                                events: events, provider: delayed, cloudTextAllowed: true) }
    try await Task.sleep(nanoseconds: 50_000_000)
    let samePending = await service.generate(cacheID: nextID, session: session, directory: nextFolder,
                                             events: events, provider: delayed, cloudTextAllowed: true, finalized: true)
    guard case .unchanged = samePending, await pendingCounter.count() == 1 else {
        throw MeetingAutoTitleError.invalidResponse
    }
    await service.invalidate(cacheID: nextID)
    let late = await pending.value
    guard case .stale = late,
          try MeetingDisplayInfoStore.load(in: nextFolder)?.title.isEmpty == true else {
        throw MeetingAutoTitleError.invalidResponse
    }
    let wrong = await service.generate(cacheID: nextID, session: "another-session", directory: nextFolder,
                                       events: events, provider: mock, cloudTextAllowed: true)
    guard case .failed = wrong,
          try MeetingDisplayInfoStore.load(in: nextFolder)?.title.isEmpty == true else {
        throw MeetingAutoTitleError.invalidResponse
    }

    let noService = await service.generate(cacheID: nextID, session: session, directory: nextFolder,
                                           events: events, provider: nil, cloudTextAllowed: false)
    guard case .unavailable = noService,
          try MeetingDisplayInfoStore.load(in: nextFolder)?.state == .unavailable else {
        throw MeetingAutoTitleError.invalidResponse
    }
    let short = await service.generate(cacheID: nextID, session: session, directory: nextFolder,
                                       events: [["segment_id": "short", "start": 0.0, "text": "好。"]],
                                       provider: mock, cloudTextAllowed: true)
    guard case .insufficientText = short,
          try MeetingDisplayInfoStore.load(in: nextFolder)?.state == .insufficientText else {
        throw MeetingAutoTitleError.invalidResponse
    }
    let longEvents: [[String: Any]] = [
        ["segment_id": "long", "start": 0.0,
         "text": "开始讨论品牌营销。" + String(repeating: "中段分析客户与课程。", count: 5000) + "末尾决定复核报价。"]
    ]
    guard let sampled = MeetingTitleInput(events: longEvents),
          sampled.transcript.count <= 30_000,
          sampled.transcript.contains("开始讨论品牌营销"),
          sampled.transcript.contains("末尾决定复核报价") else {
        throw MeetingAutoTitleError.invalidResponse
    }

    // Resume can cancel the pause request after it reserved its digest. A final
    // pass must recover that abandoned pending record even when text is unchanged.
    let abandonedID = UUID().uuidString
    let abandonedFolder = root.appendingPathComponent(abandonedID)
    try FileManager.default.createDirectory(at: abandonedFolder, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["session": session, "cache_id": abandonedID])
        .write(to: abandonedFolder.appendingPathComponent("meeting.json"))
    let abandonedCounter = FixtureTitleCallCounter()
    let slow = FixtureTitleProvider(titleText: "品牌营销｜恢复后最终标题", delayNanoseconds: 200_000_000,
                                    counter: abandonedCounter)
    let abandoned = Task { await service.generate(cacheID: abandonedID, session: session,
                                                  directory: abandonedFolder, events: events,
                                                  provider: slow, cloudTextAllowed: true,
                                                  requestRevision: 1) }
    try await Task.sleep(nanoseconds: 50_000_000)
    abandoned.cancel()
    let recovered = await service.generate(cacheID: abandonedID, session: session,
                                           directory: abandonedFolder, events: events,
                                           provider: slow, cloudTextAllowed: true, finalized: true,
                                           requestRevision: 2)
    guard case .saved("品牌营销｜恢复后最终标题") = recovered,
          case .stale = await abandoned.value,
          await abandonedCounter.count() == 2,
          try MeetingDisplayInfoStore.load(in: abandonedFolder)?.state == .ready else {
        throw MeetingAutoTitleError.invalidResponse
    }

    let editID = UUID().uuidString
    let editFolder = root.appendingPathComponent(editID)
    try FileManager.default.createDirectory(at: editFolder, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["session": session, "cache_id": editID])
        .write(to: editFolder.appendingPathComponent("meeting.json"))
    let editing = Task { await service.generate(cacheID: editID, session: session, directory: editFolder,
                                                events: events, provider: delayed, cloudTextAllowed: true) }
    try await Task.sleep(nanoseconds: 50_000_000)
    try MeetingDisplayInfoStore.saveManual("人工会议标题", in: editFolder)
    let edited = await editing.value
    guard case .stale = edited,
          try MeetingDisplayInfoStore.load(in: editFolder)?.title == "人工会议标题" else {
        throw MeetingAutoTitleError.invalidResponse
    }

    // Synthetic successive topics preserve the nine-update regression boundary.
    let progressFolder=try makeFormatFolder(),progressID=progressFolder.lastPathComponent
    let progressProvider=SequenceTitleProvider("示例项目推进｜产品命名与用户调研")
    let passages=[
        "我们先讨论示例项目的安排。请大家核对本周目标，列出还需要确认的材料，今天先把讨论范围说明清楚。",
        "试点范围暂定为一个示例区域。我们会比较两组匿名数据，记录条件差异，再判断是否需要扩大范围。",
        "预算需要单独确认。先把可选方案和所需资源列出来，今天不承诺具体金额，等负责人核对后再讨论。",
        "接下来讨论用户调研。问卷初稿已经形成，但样本覆盖还不够，团队需要确认哪些问题可以继续简化。",
        "调研进度目前完成一半。下一轮先检查重复提交和缺失字段，确保数据可靠，再汇总不同意见。",
        "产品命名还没有定稿。大家提供了几种写法，需要对照正式材料核验，确认前统一使用示例产品这个名称。",
        "买方和卖方可能关注不同的问题。我们计划分别整理需求，不把两类反馈混在一起得出总体结论。",
        "渠道比较先使用公开数据。对每个渠道记录相同的指标和时间范围，避免用不同口径比较结果。",
        "最后讨论品牌呈现与日常触达。两者的目标和受众不同，后续方案应分别说明依据，并保留检验方法。"
    ]
    var progress:[[String:Any]]=[]
    for (index,text) in passages.enumerated() {
        progress.append(["segment_id":"progress-\(index)","start":Double(index*180),"text":text,"final":true])
        let outcome=await service.generate(cacheID:progressID,session:session,directory:progressFolder,
            events:progress,provider:progressProvider,cloudTextAllowed:true,refresh:true)
        guard case .saved=outcome else{throw Failure(code:"title_new_snapshot_must_not_hit_lifetime_cap")}
    }
    guard await progressProvider.calls==9 else{throw Failure(code:"title_progress_snapshot_count")}
    let duplicateProgress=await service.generate(cacheID:progressID,session:session,directory:progressFolder,
        events:progress,provider:progressProvider,cloudTextAllowed:true,finalized:true)
    guard case .unchanged=duplicateProgress,await progressProvider.calls==9 else{throw Failure(code:"title_progress_deduplicates_final_snapshot")}

    // Old sidecars at the previous cap are readable and recover on new text.
    let progressFile=progressFolder.appendingPathComponent("display-info.json")
    var capped=try JSONSerialization.jsonObject(with:Data(contentsOf:progressFile)) as! [String:Any]
    capped["attempts"]=7
    try JSONSerialization.data(withJSONObject:capped).write(to:progressFile,options:.atomic)
    progress.append(["segment_id":"closing","start":1674.75,"text":"还有一个示例事项需要确认，请负责同事在下次讨论前补充公开材料。","final":true])
    let uncapped=await service.generate(cacheID:progressID,session:session,directory:progressFolder,
        events:progress,provider:progressProvider,cloudTextAllowed:true,refresh:true)
    guard case .saved=uncapped,try MeetingDisplayInfoStore.load(in:progressFolder)?.attempts==1 else{
        throw Failure(code:"title_legacy_lifetime_cap_recovers_on_new_text")
    }
    let failureFolder=try makeFormatFolder(),failureID=failureFolder.lastPathComponent
    let failingProvider=SequenceTitleProvider("示例项目推进｜产品命名与用户调研",failures:10)
    for _ in 0..<5 {
        _=await service.generate(cacheID:failureID,session:session,directory:failureFolder,
            events:progress,provider:failingProvider,cloudTextAllowed:true,finalized:true)
    }
    guard await failingProvider.calls==3,try MeetingDisplayInfoStore.load(in:failureFolder)?.state == .failed else{
        throw Failure(code:"title_failure_retries_are_bounded_per_snapshot")
    }
}
