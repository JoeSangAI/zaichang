import AppKit

private struct MinimalFixtureTitleProvider:MeetingTitleProvider {
    func title(for transcript:String) async throws->String {
        transcript.contains("最终结论") ? "会议原文｜人物纠错最终方案":"会议原文｜人物纠错方案"
    }
}

@MainActor func minimalUIFlowChecks(directory:URL) async throws->[String:Any] {
    guard Credential.offline,directory.path.contains("/.runtime/") else {throw Failure(code:"minimal_ui_scope")}
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    var checks:[String]=[]
    func check(_ value:Bool,_ key:String)throws {guard value else {throw Failure(code:key)};checks.append(key)}
    let detailsChecks = try meetingRecordDetailsChecks()
    try check(detailsChecks >= 27, "meeting_details_status_source_fee_and_audio_evidence")
    let owner=Delegate();owner.previewRenderOnly=true;owner.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));owner.recoveryRootOverride=directory
    let session="minimal-ui-fixture",cache=UUID().uuidString
    owner.activeSession=session;owner.currentCacheID=cache
    let folder=directory.appendingPathComponent(cache);let journal=try RecordingJournal(directory:folder,track:"mic",freeSpace:{1_000_000_000});try journal.enqueue(Data(repeating:0,count:3200),at:0);journal.finish();journal.wait();try JSONSerialization.data(withJSONObject:["session":session,"cache_id":cache,"bundle":"*system*"]).write(to:folder.appendingPathComponent("meeting.json"))
    var commands:[String]=[]
    owner.mockRecordingControlHandler={command in commands.append(command["action"] as? String ?? "")}
    owner.phase.phase = .recording;owner.updateUI()
    let button=owner.action!
    try check(button.title=="暂停录音" && button.isEnabled && !button.isHiddenOrHasHiddenAncestor && owner.newButton?.isHiddenOrHasHiddenAncestor==false && !(owner.toolbarAllowedItemIdentifiers(owner.window.toolbar!).contains(NSToolbarItem.Identifier("new"))),"one_prominent_control_and_sidebar_new_meeting_entry")
    button.performClick(nil)
    try check(commands==["pause"] && !button.isEnabled && owner.phase.phase == .recording,"single_button_pause_waits_for_ack")
    owner.receive(["type":"recording_paused","session":session])
    try check(button===owner.action && button.title=="继续录音" && button.isEnabled,"same_button_becomes_resume")
    let history=Delegate();history.previewRenderOnly=true;history.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));history.isHistoryReader=true;history.workspaceOwner=owner;owner.historyReader=history;history.meetingTitle="历史会议";history.updateUI()
    try check(history.historyLiveButton.title.contains(owner.meetingTitle) && history.historyLiveButton.isHidden==false,"history_names_the_meeting_controlled_by_record_button")
    history.action.performClick(nil)
    try check(commands==["pause"] && owner.activeSession==session && owner.phase.phase == .paused && !history.action.isHidden && history.action.title=="继续这场录音","invalid_history_target_cannot_control_another_conversations_recording")
    owner.action.performClick(nil)
    try check(commands==["pause","resume"],"return_to_current_then_resume_targets_current_conversation")
    owner.receive(["type":"recording_resumed","session":session]);owner.updateUI()
    try check(owner.action.title=="暂停录音" && !owner.action.isHiddenOrHasHiddenAncestor,"current_conversation_has_one_control_state")
    owner.historyReader=nil
    var cutoffRequests=0;owner.mockStopHandler={cutoffRequests+=1;owner.receive(["type":"stopped","reason":"capture_control_timeout_pause","session":session,"transcription_complete":false])}
    owner.recordingControlTimeoutSeconds=0.05;owner.sendRecordingControl("pause");try await Task.sleep(nanoseconds:100_000_000)
    try check(cutoffRequests==0 && owner.recordingControlInFlight=="pause" && owner.phase.phase == .recording && owner.currentCacheID==cache,"ui_timeout_waits_for_worker_safety_owner_without_stopping_capture")
    owner.receive(["type":"stopped","reason":"capture_control_timeout_pause","session":session,"transcription_complete":false])
    try check(owner.recordingControlInFlight==nil && owner.phase.phase == .failed && owner.currentCacheID==cache,"worker_safety_cutoff_remains_explicit_and_preserves_cache")
    owner.receive(["type":"recording_paused","session":session]);try check(owner.phase.phase == .failed,"late_pause_ack_cannot_revive_cutoff_session")
    owner.mockStopHandler=nil
    owner.recordingControlInFlight="resume";owner.receive(["type":"error","code":"fixture_failure"]);try check(owner.recordingControlInFlight==nil,"worker_failure_releases_control")
    owner.phase.phase = .recording;owner.phase.error=nil;owner.updateUI()
    for (id,start,slot) in [("a1",0.0,0),("b1",4.0,1),("a2",8.0,0)] {
        let event:[String:Any]=["type":"segment","session":session,"segment_id":id,"source_id":"mic","track":"mic","epoch":"fixture","start":start,"end":start+3,"text":id+"这是一整轮有语义的发言。","revision":1,"final":true,"speaker":["basis":"anonymous_cluster","source_id":"mic","epoch":"fixture","cluster_id":slot]]
        journal.record(event);owner.receive(event)
    }
    try owner.settleTranscriptForOfflineReview()
    let original=owner.transcriptExport()
    let index=SpeakerReviewIndex.build(session:session,turns:owner.readingTurns(),names:owner.naming)
    try check(index.people.count==2 && index.people.first?.entries.count==2,"speaker_review_preserves_complete_turns")
    let person=index.people[0]
    try check(owner.naming.renameSpeaker(key:person.key,name:"主讲人"),"whole_person_rename")
    owner.markAllTranscriptParentsDirty();try owner.settleTranscriptForOfflineReview()
    try check(owner.transcriptExport().contains("主讲人") && owner.transcriptExport().contains("b1这是一整轮"),"rename_keeps_full_export_scope")
    owner.undoName();try owner.settleTranscriptForOfflineReview()
    try check(owner.transcriptExport()==original,"batch_undo_restores_export")
    let oldKey=index.people[0].key,newKey=index.people[1].key
    try check(owner.naming.mergeSpeaker(from:oldKey,to:newKey,humanConfirmed:true),"explicit_merge_groups")
    owner.markAllTranscriptParentsDirty();try owner.settleTranscriptForOfflineReview()
    try check(SpeakerReviewIndex.build(session:session,turns:owner.readingTurns(),names:owner.naming).people.count==1,"merged_group_aggregates_both_people")
    owner.undoName();try owner.settleTranscriptForOfflineReview()
    try check(SpeakerReviewIndex.build(session:session,turns:owner.readingTurns(),names:owner.naming).people.count==2,"merge_undo_restores_groups")
    owner.window.setContentSize(NSSize(width:640,height:480));owner.layoutWorkspace();owner.window.contentView!.layoutSubtreeIfNeeded()
    let compactControl = owner.action.convert(owner.action.bounds, to: owner.window.contentView!)
    try check(owner.action.frame.width>=34 && owner.action.frame.height>=34 &&
              owner.window.contentView!.bounds.contains(compactControl) && !owner.action.isHiddenOrHasHiddenAncestor &&
              owner.sidebar.isHidden,"compact_primary_control_visible")
    journal.wait();owner.previewRenderOnly=false;owner.titleProvider=MinimalFixtureTitleProvider();owner.titleTextAllowed=true
    owner.receive(["type":"recording_paused","session":session])
    let deadline=Date().addingTimeInterval(5);while owner.meetingTitle != "会议原文｜人物纠错方案" && Date()<deadline {try await Task.sleep(nanoseconds:20_000_000)}
    try check(owner.meetingTitle=="会议原文｜人物纠错方案" && owner.action.title=="继续录音" && owner.action.isEnabled,"pause_generates_title_without_blocking_record_control")
    try check(try MeetingLibraryInfo.loadTitle(in:folder)==owner.meetingTitle,"auto_title_reopens_in_library")
    let finalEvent:[String:Any]=["type":"segment","session":session,"segment_id":"final-title","source_id":"mic","track":"mic","epoch":"fixture","start":12.0,"end":15.0,"text":"最终结论：原文与人物纠错方案已经确认。","revision":1,"final":true,"speaker":["basis":"unknown"]]
    journal.record(finalEvent);journal.wait();owner.receive(finalEvent)
    owner.receive(["type":"stopped","session":session,"reason":"user_stop","transcription_complete":true])
    let finalDeadline=Date().addingTimeInterval(5);while owner.meetingTitle != "会议原文｜人物纠错最终方案" && Date()<finalDeadline {try await Task.sleep(nanoseconds:20_000_000)}
    try check(owner.meetingTitle=="会议原文｜人物纠错最终方案" &&
              (try MeetingLibraryInfo.loadTitle(in:folder))==owner.meetingTitle &&
              owner.transcriptExport().contains("会议：会议原文｜人物纠错最终方案"),
              "stop_refreshes_title_with_final_text_and_export")
    owner.previewRenderOnly=true;owner.invalidateAutoTitle()
    let contrastChecks=try meetingVisualStyleContrastChecks();try check(contrastChecks>0,"primary_button_all_states_contrast")
    let cardChecks=try meetingCardSummaryChecks(directory:directory);checks.append("participant_card_summary")
    let reviewUI=try await minimalSpeakerUIChecks(owner:owner,directory:directory);checks.append("speaker_ui_edits_and_narrow_layout")
    try owner.settleTranscriptForOfflineReview()
    try await meetingAutoTitleFixture();checks.append("auto_title_offline_mock")
    owner.phase.phase = .recording;owner.updateUI();owner.openSpeakerReview()
    let reviewWindow=owner.speakerReviewWindow
    let commandsBeforeClose=commands
    owner.closeWindowTarget(reviewWindow)
    try check(reviewWindow != nil && owner.speakerReviewWindow==nil && owner.phase.phase == .recording && owner.activeSession==session && commands==commandsBeforeClose && owner.action.title=="暂停录音","closing_speaker_window_preserves_current_recording")
    owner.historyReader=history;history.activeSession="history-review-fixture";history.openSpeakerReview()
    let historyReviewWindow=history.speakerReviewWindow
    owner.closeWindowTarget(historyReviewWindow)
    try check(historyReviewWindow != nil && history.speakerReviewWindow==nil && owner.phase.phase == .recording && owner.activeSession==session && commands==commandsBeforeClose && owner.historyReader === history,"closing_history_speaker_window_preserves_live_recording")
    owner.historyReader=nil
    owner.window.orderOut(nil);history.window.orderOut(nil)
    return ["type":"minimal_ui_flow_checks","passed":checks.count,"checks":checks,"capture":false,"cloud":false,"keychain":false,"offscreen":true,"speaker_ui":reviewUI,"card_checks":cardChecks]
}
