import Foundation
import AppKit

@MainActor func meetingArchiveUIChecks() throws -> [String] {
    var checks:[String]=[]
    func check(_ condition:@autoclosure()->Bool,_ name:String)throws {
        guard condition() else{throw Failure(code:"meeting_archive_check_"+name)}
        checks.append(name)
    }

    func allows(_ phase:RecordingPhase,transcription:Bool=true,localOnly:Bool=false,history:Bool=false,automatic:Bool=false,busy:Bool=false,pending:Bool=false,coarse:Bool=true,qa:Bool=false,resume:Bool=false)->Bool {
        MeetingArchiveEligibility.allows(phase:phase,transcriptionComplete:transcription,localOnly:localOnly,historyReader:history,automatic:automatic,refinementBusy:busy,projectionPending:pending,coarseSettled:coarse,qaOrMock:qa,resumePending:resume)
    }
    try check(allows(.paused),"paused_complete_meeting_is_ready")
    try check(allows(.stopped),"stopped_complete_meeting_is_ready")
    for phase:RecordingPhase in [.idle,.recording,.stopping,.failed,.ended] {
        try check(!allows(phase),"phase_\(phase.rawValue)_is_not_ready")
    }
    try check(!allows(.paused,transcription:false),"incomplete_transcript_is_not_ready")
    try check(!allows(.paused,localOnly:true),"local_only_is_not_uploaded")
    try check(!allows(.paused,history:true,automatic:true),"history_view_does_not_auto_prepare")
    try check(!allows(.paused,history:true,automatic:true) && allows(.paused,history:true),"history_meeting_remains_manual_archiveable")
    try check(!allows(.paused,busy:true),"speaker_refinement_must_finish")
    try check(!allows(.paused,pending:true),"projection_must_be_synced")
    try check(!allows(.paused,coarse:false),"coarse_result_must_be_settled")
    try check(!allows(.paused,automatic:true,qa:true) && allows(.paused,qa:true),"qa_and_mock_block_auto_but_allow_explicit_archive")
    try check(!allows(.paused,resume:true),"resume_request_invalidates_pending_archive_prepare")
    try check(MeetingArchiveEligibility.transcriptComplete(phase:.paused,cachedComplete:false,pausedTail:["mic":"complete"]),"pause_tail_completion_unlocks_archive")
    try check(!MeetingArchiveEligibility.transcriptComplete(phase:.paused,cachedComplete:true,pausedTail:["mic":"processing"]),"active_pause_tail_blocks_archive")
    try check(!MeetingArchiveEligibility.transcriptComplete(phase:.paused,cachedComplete:true,pausedTail:[:]),"unknown_pause_tail_blocks_archive")
    try check(MeetingArchiveEligibility.transcriptComplete(phase:.stopped,cachedComplete:true,pausedTail:[:]),"stopped_complete_transcript_unlocks_archive")
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    let deviceFailure=Delegate();deviceFailure.previewRenderOnly=true;deviceFailure.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    deviceFailure.phase.phase = .stopping;deviceFailure.activeSession="device-change-complete";deviceFailure.suppressAutomaticRefinementAfterStop=true
    deviceFailure.receive(["type":"stopped","session":"device-change-complete","reason":"input_device_changed","transcription_complete":true])
    try check(deviceFailure.phase.phase == .stopped && deviceFailure.phase.error?.contains("输入设备") == true &&
              MeetingArchiveEligibility.allows(phase:deviceFailure.phase.phase,transcriptionComplete:deviceFailure.cachedTranscriptionComplete,localOnly:false,historyReader:false,refinementBusy:false,projectionPending:false,coarseSettled:true,qaOrMock:false,resumePending:false),
              "complete_input_device_failure_keeps_error_and_unlocks_archive")
    let incompleteDeviceFailure=Delegate();incompleteDeviceFailure.previewRenderOnly=true;incompleteDeviceFailure.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    incompleteDeviceFailure.phase.phase = .stopping;incompleteDeviceFailure.activeSession="device-change-incomplete";incompleteDeviceFailure.suppressAutomaticRefinementAfterStop=true
    incompleteDeviceFailure.receive(["type":"stopped","session":"device-change-incomplete","reason":"input_device_changed","transcription_complete":false])
    try check(incompleteDeviceFailure.phase.phase == .failed && incompleteDeviceFailure.phase.error?.contains("输入设备") == true &&
              !MeetingArchiveEligibility.allows(phase:incompleteDeviceFailure.phase.phase,transcriptionComplete:incompleteDeviceFailure.cachedTranscriptionComplete,localOnly:false,historyReader:false,refinementBusy:false,projectionPending:false,coarseSettled:true,qaOrMock:false,resumePending:false),
              "incomplete_input_device_failure_stays_failed_and_blocks_archive")
    let archiveOwner=Delegate();archiveOwner.previewRenderOnly=true;archiveOwner.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    let archiveReader=Delegate();archiveReader.previewRenderOnly=true;archiveReader.isHistoryReader=true;archiveReader.workspaceOwner=archiveOwner
    archiveReader.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    archiveReader.activeSession="archive-running-fixture";archiveReader.currentCacheID="archive-running-cache"
    archiveReader.phase.phase = .stopped;archiveReader.cachedTranscriptionComplete=true
    archiveOwner.savedCoarseJobs["archive-running-cache"]=SpeakerRefinementJob()
    try check(!archiveReader.meetingArchiveEligible,"history_archive_is_blocked_while_its_saved_coarse_job_runs")
    archiveOwner.savedCoarseJobs.removeValue(forKey:"archive-running-cache")
    try check(archiveReader.meetingArchiveEligible,"history_archive_unlocks_after_saved_coarse_job_finishes")
    archiveReader.window.orderOut(nil);archiveOwner.window.orderOut(nil)
    try check(MeetingArchiveEligibility.coarseSettled(hasArtifact:false,errorCode:"coarse_audio_missing") && !MeetingArchiveEligibility.coarseSettled(hasArtifact:false,errorCode:"provider_http_500"),"only_explicit_no_coarse_cases_bypass_result")
    let currentToken=MeetingArchiveEligibility.coarseTokenMatches(cacheID:"cache",session:"session",generation:3,revision:2,sourceSHA256:"source",snapshotSHA256:"snapshot",currentCacheID:"cache",currentSession:"session",currentGeneration:3,currentRevision:2,artifactExists:true)
    let staleToken=MeetingArchiveEligibility.coarseTokenMatches(cacheID:"cache",session:"session",generation:3,revision:2,sourceSHA256:"source",snapshotSHA256:"snapshot",currentCacheID:"cache",currentSession:"session",currentGeneration:4,currentRevision:2,artifactExists:true)
    try check(currentToken && !staleToken,"old_coarse_artifact_cannot_unlock_new_session_revision")

    // Exercise the actual history-cache recovery -> workspace button route.
    // The offline fixture uses a synthetic cache only; it never calls the archive API.
    let root=URL(fileURLWithPath:CommandLine.arguments.count>2 ? CommandLine.arguments[2]:NSTemporaryDirectory(),isDirectory:true)
    let fixtureRoot=root.appendingPathComponent("archive-history-"+UUID().uuidString,isDirectory:true)
    let cacheID=UUID().uuidString,session=UUID().uuidString,folder=fixtureRoot.appendingPathComponent(cacheID,isDirectory:true)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:fixtureRoot)}
    let event:[String:Any] = ["type":"segment","session":session,"segment_id":"history-line","track":"mic","source_id":"mic","epoch":"archive-fixture","start":0.0,"end":0.5,"end_time_known":true,"text":"历史会议合成原文。","revision":1,"final":true,"speaker":["basis":"unknown"]]
    try JSONSerialization.data(withJSONObject:["schema":1,"session":session,"capture_mode":"cloud","upload_authorized":true],options:.sortedKeys).write(to:folder.appendingPathComponent("meeting.json"),options:.atomic)
    var line=try JSONSerialization.data(withJSONObject:event,options:.sortedKeys);line.append(10)
    try line.write(to:folder.appendingPathComponent("mic-transcript.jsonl"),options:.atomic)
    var item=CachedMeeting(id:cacheID,directory:folder,date:Date(),writtenBytes:0,pendingBytes:0,occupiedBytes:0,tracks:["mic"],audioCleaned:false,warning:false,retiredBytes:0)
    item.savedAudioTranscriptionComplete=true
    let rootDelegate=Delegate();rootDelegate.previewRenderOnly=true;rootDelegate.deferPresentation=true;rootDelegate.recoveryRootOverride=fixtureRoot
    rootDelegate.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    let reader=Delegate();reader.previewRenderOnly=true;reader.deferPresentation=false;reader.isHistoryReader=true;reader.workspaceOwner=rootDelegate;reader.recoveryRootOverride=fixtureRoot
    reader.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    try reader.applyRecovery(item,payload:RecoveryPayload(item))
    rootDelegate.historyReader=reader
    try reader.settleTranscriptForOfflineReview()
    guard let historyButton=reader.archiveButton else{throw Failure(code:"meeting_archive_history_button_missing")}
    try check(historyButton !== rootDelegate.archiveButton,"history_workspace_uses_its_own_visible_archive_button")
    reader.updateWorkspacePresentation()
    rootDelegate.updateWorkspacePresentation()
    reader.updateWorkspacePresentation()
    try check(reader.currentCacheID==cacheID && reader.activeSession==session && reader.cachedTranscriptionComplete && reader.phase.phase == .stopped,"history_cache_recovery_restores_archived_meeting_identity_and_completion")
    try check(historyButton.isEnabled,"history_cache_recovery_enables_workspace_archive_button")
    try check(historyButton.isEnabled,"history_archive_button_stays_enabled_after_normal_workspace_repaints")
    try check(!MeetingArchiveEligibility.allows(phase:reader.phase.phase,transcriptionComplete:true,localOnly:false,historyReader:true,automatic:true,refinementBusy:false,projectionPending:false,coarseSettled:true,qaOrMock:false,resumePending:false),"history_cache_recovery_never_auto_prepares")
    reader.window=rootDelegate.window
    reader.presentMeetingArchiveSheetForChecks()
    guard let closeButton=reader.meetingArchiveSheetCloseButtonForChecks,let buttonSheet=rootDelegate.window.attachedSheet else{throw Failure(code:"meeting_archive_close_button_sheet_missing")}
    try check(closeButton.title=="关闭" && closeButton.isEnabled,"archive_sheet_has_visible_close_action")
    closeButton.performClick(nil)
    try check(buttonSheet.sheetParent==nil && rootDelegate.window.attachedSheet==nil,"archive_close_button_ends_attached_sheet")
    reader.presentMeetingArchiveSheetForChecks()
    guard let escapeSheet=rootDelegate.window.attachedSheet else{throw Failure(code:"meeting_archive_escape_sheet_missing")}
    reader.sendMeetingArchiveEscapeForChecks()
    try check(escapeSheet.sheetParent==nil && rootDelegate.window.attachedSheet==nil,"archive_escape_ends_attached_sheet")
    reader.window.orderOut(nil);rootDelegate.window.orderOut(nil)

    let archiveEnvironment=["ZAICHANG_ARCHIVE_ORIGIN":"https://archive.example.test"]
    try check(MeetingArchiveRequest.bootstrapURL(environment:[:])==nil,"remote_archive_is_disabled_without_user_configuration")
    let page=try MeetingArchiveRequest.pageURL(session:"meeting / 1",environment:archiveEnvironment)
    let pageParts=URLComponents(url:page,resolvingAgainstBaseURL:false)
    try check(page.host=="archive.example.test" && pageParts?.queryItems?.first(where:{$0.name=="page"})?.value=="archive" && pageParts?.queryItems?.first(where:{$0.name=="session"})?.value=="meeting / 1","archive_page_keeps_session_as_query_data")
    let request=try MeetingArchiveRequest.prepareRequest(session:"meeting-1",csrfToken:"synthetic-csrf",environment:archiveEnvironment)
    try check(request.httpMethod=="POST" && request.url?.path=="/api/meeting-archives/meeting-1/prepare" && request.value(forHTTPHeaderField:"X-CSRF-Token")=="synthetic-csrf" && request.value(forHTTPHeaderField:"Origin")==archiveEnvironment["ZAICHANG_ARCHIVE_ORIGIN"] && request.httpBody==Data("{}".utf8),"prepare_request_uses_origin_csrf_and_shared_route")
    try check(MeetingArchiveRequest.acceptedMessage.contains("已发起") && !MeetingArchiveRequest.acceptedMessage.contains("已准备好"),"accepted_prepare_is_not_reported_as_ready")
    try check(MeetingArchiveRequest.requestTimeout<=10 && MeetingArchiveRequest.resourceTimeout<=20,"archive_requests_have_bounded_timeouts")
    let bootstrapData=Data("{\"app_id\":\"zaichang-workbench\",\"csrf_token\":\"synthetic-csrf\"}".utf8)
    let bootstrapURL=MeetingArchiveRequest.bootstrapURL(environment:archiveEnvironment)!
    try check(bootstrapURL.path=="/api/meeting-archives-bootstrap","archive_uses_lightweight_bootstrap_route")
    let bootstrapResponse=HTTPURLResponse(url:bootstrapURL,statusCode:200,httpVersion:nil,headerFields:nil)
    let token=try MeetingArchiveRequest.validatedCSRFToken(data:bootstrapData,response:bootstrapResponse,error:nil)
    try check(token=="synthetic-csrf","bootstrap_requires_zaichang_workbench_identity")
    do {
        let wrongApp=Data("{\"app_id\":\"other-service\",\"csrf_token\":\"synthetic-csrf\"}".utf8)
        _=try MeetingArchiveRequest.validatedCSRFToken(data:wrongApp,response:bootstrapResponse,error:nil)
        throw Failure(code:"wrong_bootstrap_app_was_accepted")
    } catch let error as Failure {try check(error.code=="meeting_archive_bootstrap_invalid","wrong_bootstrap_app_is_rejected")}
    do { _=try MeetingArchiveRequest.prepareRequest(session:"meeting-1",csrfToken:"");throw Failure(code:"empty_csrf_was_accepted") }
    catch let error as Failure {try check(error.code=="meeting_archive_csrf_missing","missing_csrf_is_rejected")}
    return checks
}
