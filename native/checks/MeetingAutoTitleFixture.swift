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
        precondition(transcript.contains("示例产品规划"))
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
        guard transcript.contains("原文中出现的识别词") && transcript.contains("示例平台") && transcript.contains("我最近在跑步") else {
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
    let proc=Process(),pipe=Pipe();proc.executableURL=PythonRuntime.executable()!;proc.arguments=[view.root+"/meeting_context.py","--database",bridge.appendingPathComponent("context.sqlite").path,"read","--session",session];proc.standardOutput=pipe;proc.standardError=FileHandle.nullDevice
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
    let liveProvider=RotatingTitleProvider(["实时转写｜讨论方案","示例产品｜定位与验收安排"],delay:100_000_000)
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
    // Synthetic later passages prove that new topics are absorbed at pause,
    // not during recording.
    let laterText="""
    目前内部测试已经完成一半，今天又补了一轮样本。大家对新界面的名称还有不同意见，先把反馈归类。
    新版还没有开始试用，因为团队正在收集测试结果。明天汇总完以后，再决定哪些流程进入下一轮验证。
    我们要比较两种使用路径，确认新用户能否顺利完成第一次操作，并找出在哪一步容易停下来。
    同时需要确认测试范围，核心功能保持一致，其他细节可以按不同人群分别观察。
    这轮主要看实际完成率和用户反馈，不急着扩大范围。等数据完整后，再讨论后续安排。
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
              && view.meetingTitle=="示例产品｜定位与验收安排",
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
    progressEvent["text"]="还有，哈哈，你你那个测试负责人计划怎么怎么，我们需要怎么推进吗？"
    try ageTitle(live);try append(progressEvent,to:live);try await Task.sleep(nanoseconds:30_000_000)
    try check(await liveProvider.calls==2,"resumed_recording_keeps_previous_title")
    view.receive(["type":"recording_paused","session":"title-live","control_revision":3,"draining_tracks":[]])
    try await wait({view.titleTask==nil})
    let resumedInputs=await liveProvider.transcripts
    try check(resumedInputs.count==3 && resumedInputs[2].contains("测试负责人计划"),"next_pause_includes_resumed_content")
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
        ["segment_id": "a", "start": 0.0, "final": true, "text": "示例产品规划小组讨论了新功能需求和上线节奏，先整理试用反馈。"],
        ["segment_id": "b", "start": 5.0, "final": true, "text": "团队决定下周检查验收范围，优先级和分工仍待确认。"]
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
    let mock = FixtureTitleProvider(titleText: "会议标题：**示例产品规划｜服务方向讨论。**", delayNanoseconds: 0, counter: counter)
    let first = await service.generate(cacheID: id, session: session, directory: folder,
                                       events: events, provider: mock, cloudTextAllowed: true)
    guard case .saved("示例产品规划｜服务方向讨论") = first else { throw MeetingAutoTitleError.invalidResponse }
    guard let saved = try MeetingDisplayInfoStore.load(in: folder), saved.provenance == .automatic,
          saved.state == .ready, saved.session == session, saved.cacheID == id,
          saved.sourceDigest == MeetingTitleInput(events: events)?.digest else { throw MeetingAutoTitleError.invalidSidecar }
    let duplicate = await service.generate(cacheID: id, session: session, directory: folder,
                                           events: events, provider: mock, cloudTextAllowed: true, finalized: true)
    guard case .unchanged = duplicate, await counter.count() == 1 else { throw MeetingAutoTitleError.invalidResponse }

    // Verify compact title formatting, ASCII separator normalization, and
    // rejection of provider output that is a sentence or list.
    let formatEvents: [[String: Any]] = [
        ["segment_id": "format", "start": 0.0,
         "text": "示例产品规划团队讨论两种流程对比，确认试用边界和四周验证安排。"]
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
    let asciiProvider = FixtureTitleProvider(titleText: "试用方案 | 两种流程对比与四周验证", delayNanoseconds: 0)
    let formatted = await service.generate(cacheID: formatID, session: session, directory: formatFolder,
                                            events: formatEvents, provider: asciiProvider, cloudTextAllowed: true)
    guard case .saved("试用方案｜两种流程对比与四周验证") = formatted else {
        throw MeetingAutoTitleError.invalidResponse
    }
    let groundedFolder=try makeFormatFolder(),groundedID=groundedFolder.lastPathComponent
    try JSONSerialization.data(withJSONObject:["session":session,"cache_id":groundedID,
        "asr_vocabulary_confirmed":true,"asr_vocabulary":["示例平台":2]],options:[.sortedKeys])
        .write(to:groundedFolder.appendingPathComponent("meeting.json"),options:.atomic)
    let groundedEvents:[[String:Any]]=[["segment_id":"grounded","start":0.0,
        "text":"这次会议聊到示例平台的功能，也有人说我最近在跑步，随后还会比较不同流程的使用体验。"]]
    guard try ASRTermVocabulary.confirmedVocabulary(in:groundedFolder,session:session)==["示例平台"] else {
        throw Failure(code:"title_grounded_term_fixture")
    }
    guard let groundedInput=MeetingTitleInput(events:groundedEvents,termHints:["示例平台"]),
          groundedInput.transcript.contains("原文中出现的识别词") else {
        throw Failure(code:"title_grounded_input_fixture")
    }
    let grounded=await service.generate(cacheID:groundedID,session:session,directory:groundedFolder,
        events:groundedEvents,provider:GroundedTermTitleProvider(output:"示例平台｜平台试投"),cloudTextAllowed:true)
    guard case .saved("示例平台｜平台试投")=grounded,
          MeetingTitleInput(events:groundedEvents,termHints:["示例平台"])?.digest != MeetingTitleInput(events:groundedEvents)?.digest else {
        throw MeetingAutoTitleError.invalidResponse
    }
    // Unrelated saved ASR terms must not enter the title prompt or its digest.
    let syntheticEvents:[[String:Any]]=[["segment_id":"synthetic-call","start":28.0,"final":true,
        "text":"我们准备比较两个示例产品的使用体验，再听取一线同事的反馈。"]]
    let relevantHints=["示例产品甲","示例产品乙"]
    let pollutedHints=relevantHints+["示例设备","虚构品牌","示例测试"]
    guard let actual=MeetingTitleInput(events:syntheticEvents,termHints:pollutedHints),
          actual.digest==MeetingTitleInput(events:syntheticEvents,termHints:relevantHints)?.digest,
          !actual.transcript.contains("虚构品牌"),!actual.transcript.contains("示例测试"),
          actual.transcript.contains("示例产品"),
          MeetingTitleInput(events:syntheticEvents,termHints:["示例设备"])?.digest==MeetingTitleInput(events:syntheticEvents)?.digest else {
        throw Failure(code:"title_shared_vocabulary_must_not_invent_meeting_topics")
    }
    let invalidFolder = try makeFormatFolder()
    let invalidID = invalidFolder.lastPathComponent
    let invalidProvider = FixtureTitleProvider(titleText: "试用方案讨论两种流程对比与四周验证。", delayNanoseconds: 0)
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
                                 "text": "示例产品规划最终确定先做可用性测试，再核对验收范围和安排。"]]
    let refreshed = await service.generate(cacheID: id, session: session, directory: folder,
                                           events: finalEvents, provider: mock, cloudTextAllowed: true, refresh:true)
    guard case .saved = refreshed,
          try MeetingDisplayInfoStore.load(in: folder)?.sourceDigest == MeetingTitleInput(events: finalEvents)?.digest,
          await counter.count() == 2 else { throw MeetingAutoTitleError.invalidResponse }
    let repeatedFinal = await service.generate(cacheID: id, session: session, directory: folder,
                                               events: finalEvents, provider: mock, cloudTextAllowed: true, finalized: true)
    guard case .unchanged = repeatedFinal, await counter.count() == 2 else { throw MeetingAutoTitleError.invalidResponse }

    try MeetingDisplayInfoStore.saveManual("人工确认：产品试用范围", in: folder)
    let manual = await service.generate(cacheID: id, session: session, directory: folder,
                                        events: finalEvents, provider: mock, cloudTextAllowed: true, finalized: true)
    guard case .manual = manual,
          try MeetingDisplayInfoStore.load(in: folder)?.title == "人工确认：产品试用范围",
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
    let delayed = FixtureTitleProvider(titleText: "示例产品规划｜迟到标题不应写入", delayNanoseconds: 200_000_000, counter: pendingCounter)
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
         "text": "开始讨论示例产品规划。" + String(repeating: "中段分析操作体验和试用反馈。", count: 5000) + "末尾决定复核验收安排。"]
    ]
    guard let sampled = MeetingTitleInput(events: longEvents),
          sampled.transcript.count <= 30_000,
          sampled.transcript.contains("开始讨论示例产品规划"),
          sampled.transcript.contains("末尾决定复核验收安排") else {
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
    let slow = FixtureTitleProvider(titleText: "示例产品规划｜恢复后最终标题", delayNanoseconds: 200_000_000,
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
    guard case .saved("示例产品规划｜恢复后最终标题") = recovered,
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

    // Synthetic successive topics prove changed transcripts remain eligible
    // after the former lifetime seven-call ceiling.
    let progressFolder=try makeFormatFolder(),progressID=progressFolder.lastPathComponent
    let progressProvider=SequenceTitleProvider("示例产品｜定位与验收安排")
    let passages=[
        "大家先过一下这几个测试项，当前的样例项目进展到哪里了？",
        "这轮先选一个小范围进行试用，再与另一个相近场景做比较。",
        "目标是先验证关键流程，不要把试用范围扩得太大。",
        "目前核心页面已经完成，接下来要检查首次使用路径是否清楚。",
        "已有一部分反馈，今天补充了新样本，后续统一整理问题。",
        "产品名称先按当前版本记录，避免测试资料里出现不同写法。",
        "需要了解新用户和熟悉用户在操作上的主要差异。",
        "下一轮比较两种引导方式，并记录每一步的完成情况。",
        "范围确认后再决定是否扩大测试，先把主要问题解决。"
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
    progress.append(["segment_id":"closing","start":1674.75,"text":"还有，哈哈，你你那个测试负责人计划怎么怎么，我们需要怎么推进吗？","final":true])
    let uncapped=await service.generate(cacheID:progressID,session:session,directory:progressFolder,
        events:progress,provider:progressProvider,cloudTextAllowed:true,refresh:true)
    guard case .saved=uncapped,try MeetingDisplayInfoStore.load(in:progressFolder)?.attempts==1 else{
        throw Failure(code:"title_legacy_lifetime_cap_recovers_on_new_text")
    }
    let failureFolder=try makeFormatFolder(),failureID=failureFolder.lastPathComponent
    let failingProvider=SequenceTitleProvider("示例产品｜定位与验收安排",failures:10)
    for _ in 0..<5 {
        _=await service.generate(cacheID:failureID,session:session,directory:failureFolder,
            events:progress,provider:failingProvider,cloudTextAllowed:true,finalized:true)
    }
    guard await failingProvider.calls==3,try MeetingDisplayInfoStore.load(in:failureFolder)?.state == .failed else{
        throw Failure(code:"title_failure_retries_are_bounded_per_snapshot")
    }
}
