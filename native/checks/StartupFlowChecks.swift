import AppKit

@MainActor func startupFlowChecks(directory:URL) async throws->[String:Any] {
    guard Credential.offline,directory.path.contains("/.runtime/") else{throw Failure(code:"startup_fixture_scope")}
    _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    var checks:[String]=[],views:[Delegate]=[]
    func check(_ ok:Bool,_ key:String)throws {guard ok else{throw Failure(code:key)};checks.append(key)}
    func wait(_ done:()->Bool)async throws {let end=Date().addingTimeInterval(5);while !done(),Date()<end{try await Task.sleep(nanoseconds:10_000_000)};guard done() else{throw Failure(code:"startup_fixture_timeout")}}
    func owner()->Delegate {
        let v=Delegate();v.previewRenderOnly=true;v.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));v.recoveryRootOverride=directory;v.qaStore=nil;views.append(v);return v
    }
    func captured(_ v:Delegate,_ request:[String:Any],warm:Bool=false)throws->String {
        let id=UUID().uuidString,session="one-click-"+id,folder=directory.appendingPathComponent(id)
        let store=try RecordingJournal(directory:folder,track:"mic",freeSpace:{1_000_000_000})
        try store.enqueue(Data(repeating:0x29,count:3200),at:1);store.finish();store.wait()
        try JSONSerialization.data(withJSONObject:["session":session,"cache_id":id,"bundle":request["bundle"]!,"fixture":true,"audio_is_synthetic":true]).write(to:folder.appendingPathComponent("meeting.json"))
        v.receive(["type":"started","session":session,"cache_id":id,"mode":request["local_only"] as? Bool==true ? "local_only":"cloud","capture":false,"mock":true,"audio_frames_received":true])
        v.receive(["type":"speaker_model","state":warm ? "ready":"loading","track":"mic"])
        v.mockStopHandler={v.receive(["type":"stopped","session":session,"reason":"user_stop","transcription_complete":false])}
        return id
    }
    let cloud=owner();var cloudRequests:[[String:Any]]=[],cloudReads=0,coldID:String?,workerFailure:Error?
    cloud.startupCredentialFixture={cloudReads+=1;return "synthetic-key"}
    cloud.startupWorkerFixture={r in cloudRequests.append(r);do{coldID=try captured(cloud,r)}catch{workerFailure=error}}
    try check(cloud.phase.phase == .idle && cloudRequests.isEmpty && cloudReads==0 && cloud.sheet.sheetParent==nil && NSApp.modalWindow==nil,"open_is_ready_without_capture_credential_read_or_modal")
    cloud.action.performClick(nil);try await wait{!cloud.credentialReadJob.waiting};if let error=workerFailure{throw error}
    try check(cloudRequests.count==1 && cloudReads==1 && cloud.phase.phase == .recording && cloud.sheet.sheetParent==nil && NSApp.modalWindow==nil,"one_click_cold_cloud_starts_without_app_confirmation")
    try check(cloud.speakerLoading && cloud.heading.stringValue.contains("录音中"),"cold_model_loading_does_not_gate_recording")
    try check(try Data(contentsOf:directory.appendingPathComponent(coldID!).appendingPathComponent("mic-000000.pcm")).count==3200,"cold_started_status_follows_saved_synthetic_pcm")
    let request=cloudRequests[0]
    try check(request["cloud_session_confirmed"] as? Bool==true && request["user_launch_confirmed"] as? Bool==true && request["source_scope_confirmed"] as? Bool==true && request["bundle"] as? String=="*system*" && request["mic_enabled"] as? Bool==true && request["cloud_budget_yuan"]==nil,"one_click_preserves_dual_scope_without_monetary_cap")
    cloud.beginRecordingModeFlow();try check(cloudRequests.count==1,"duplicate_start_request_cannot_launch_a_second_worker")
    cloud.end()
    var warmID:String?;cloud.startupWorkerFixture={r in cloudRequests.append(r);do{warmID=try captured(cloud,r,warm:true)}catch{workerFailure=error}}
    cloud.newButton!.performClick(nil);try await wait{!cloud.newMeetingRequested && cloud.phase.phase == .idle}
    try check(cloudRequests.count==1 && cloudReads==1 && cloud.currentCacheID==nil,"new_dialog_waits_for_explicit_start_without_credentials_or_capture")
    cloud.action.performClick(nil);try await wait{cloudRequests.count==2 && !cloud.credentialReadJob.waiting};if let error=workerFailure{throw error}
    try check(cloudRequests.count==2 && cloud.phase.phase == .recording && !cloud.speakerLoading && warmID != coldID,"one_click_warm_start_creates_one_distinct_meeting")
    try check(FileManager.default.fileExists(atPath:directory.appendingPathComponent(coldID!).appendingPathComponent("mic-000000.pcm").path),"warm_start_keeps_previous_session_audio")

    let missing=owner();var missingRequests:[[String:Any]]=[];missing.startupCredentialFixture={nil};missing.startupWorkerFixture={missingRequests.append($0)}
    missing.action.performClick(nil);try await wait{!missing.credentialReadJob.waiting}
    try check(missing.phase.phase == .failed && missingRequests.isEmpty && missing.action.isEnabled && missing.sheet.sheetParent==nil,"missing_key_shows_retryable_inline_failure_without_capture_or_modal")
    missing.recordingModePicker!.selectItem(at:1);missing.changeRecordingMode();missing.action.performClick(nil)
    try check(missingRequests.count==1 && missingRequests[0]["local_only"] as? Bool==true && missingRequests[0]["key"] as? String=="" && missingRequests[0]["local_max_seconds"] as? Int==7200,"selected_local_mode_starts_in_one_click_without_cloud_key")

    let denied=owner();var deniedRequests=0;denied.startupCredentialFixture={"synthetic-key"};denied.startupWorkerFixture={_ in deniedRequests+=1;denied.receive(["type":"error","code":"microphone_permission_denied"])}
    denied.action.performClick(nil);try await wait{!denied.credentialReadJob.waiting}
    try check(denied.phase.phase == .failed && deniedRequests==1 && denied.action.isEnabled && !denied.heading.stringValue.contains("录音中"),"permission_denial_remains_a_real_retryable_blocker")
    denied.startupWorkerFixture={_ in deniedRequests+=1};denied.mockStopHandler={denied.receive(["type":"stopped","reason":"user_stop"])};denied.action.performClick(nil);try await wait{!denied.credentialReadJob.waiting}
    try check(denied.phase.phase == .connecting && !denied.heading.stringValue.contains("录音中"),"pending_first_permission_cannot_claim_recording_or_frames")
    denied.action.performClick(nil);try check(denied.phase.phase == .stopped,"permission_wait_start_can_be_cancelled")

    let blocked=owner();let gate=DispatchSemaphore(value:0);var blockedRequests=0
    blocked.startupCredentialFixture={_ = gate.wait(timeout:.now()+3);return "synthetic-key"};blocked.startupWorkerFixture={_ in blockedRequests+=1}
    blocked.action.performClick(nil);try check(blocked.credentialReadJob.waiting && blocked.action.isEnabled,"credential_wait_keeps_cancel_action_enabled")
    blocked.beginRecordingModeFlow();try check(blockedRequests==0,"duplicate_click_during_credential_read_cannot_start")
    blocked.action.performClick(nil);gate.signal();try await wait{!blocked.credentialReadJob.busy}
    try check(blockedRequests==0 && blocked.phase.phase == .stopped,"cancelled_credential_result_cannot_later_start_recording")
    blocked.startupCredentialFixture={"synthetic-key"};blocked.action.performClick(nil);try await wait{!blocked.credentialReadJob.waiting}
    try check(blockedRequests==1 && blocked.phase.phase == .connecting,"cancelled_start_can_retry_once_without_new_confirmation")

    let failed=owner();var failedRequests=0,fail=true;failed.startupCredentialFixture={"synthetic-key"};failed.startupWorkerFixture={r in failedRequests+=1;if fail{failed.receive(["type":"error","code":"capture_cache_write_failed"])}else{do{_ = try captured(failed,r)}catch{workerFailure=error}}}
    failed.action.performClick(nil);try await wait{!failed.credentialReadJob.waiting}
    try check(failed.phase.phase == .failed && failed.action.isEnabled && failed.currentCacheID==nil,"storage_start_failure_does_not_claim_recording")
    fail=false;failed.action.performClick(nil);try await wait{!failed.credentialReadJob.waiting};if let error=workerFailure{throw error}
    try check(failedRequests==2 && failed.phase.phase == .recording,"failed_start_retries_in_one_click")

    let budget=owner();var budgetRequests:[[String:Any]]=[];budget.startupCredentialFixture={"synthetic-key"};budget.startupWorkerFixture={r in budgetRequests.append(r);budget.receive(["type":"error","code":"audio_budget_limit"])}
    budget.action.performClick(nil);try await wait{!budget.credentialReadJob.waiting}
    try check(budget.phase.phase == .failed && budgetRequests.count==1 && budgetRequests[0]["cloud_budget_yuan"]==nil && budget.currentCacheID==nil,"provider_limit_failure_stops_without_automatic_retry")
    try await Task.sleep(nanoseconds:50_000_000);try check(budgetRequests.count==1,"budget_failure_does_not_auto_retry_or_recharge")

    let offline=owner();offline.startWorker(nil,overrideRequest:["local_only":true]);try check(offline.child==nil && offline.phase.phase == .failed,"offline_fixture_cannot_start_production_worker")
    checks += try await recordingDashboardChecks(directory:directory.appendingPathComponent("dashboard",isDirectory:true))
    for v in views {v.timer?.invalidate();v.window.orderOut(nil)}
    return ["type":"startup_flow_checks","passed":checks.count,"checks":checks,"actual_AppKit_primary_buttons":true,"synthetic_saved_pcm":true,"capture":false,"cloud":false,"keychain":false,"offscreen":true,"actual_macOS_permission_dialog_or_paid_provider_verified":false]
}
