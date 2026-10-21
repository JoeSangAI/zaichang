import AppKit
import SQLite3

@MainActor func meetingContextChecks(directory:URL) async throws->[String:Any] {
    guard Credential.offline,directory.path.contains("/.runtime/") else{throw Failure(code:"context_fixture_scope")}
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let folder=directory.appendingPathComponent(UUID().uuidString)
    let publisher=MeetingContextPublisher(directory:folder)
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    let view=Delegate();view.previewRenderOnly=true;view.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));view.contextPublisher=publisher
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:name)};checks.append(name)}
    let file=folder.appendingPathComponent("context.sqlite")
    func rows(_ sql:String)throws->[[String]] {
        var db:OpaquePointer?,statement:OpaquePointer?
        guard sqlite3_open_v2(file.path,&db,SQLITE_OPEN_READONLY,nil)==SQLITE_OK else{throw Failure(code:"fixture_context_open")}
        defer{sqlite3_finalize(statement);sqlite3_close(db)}
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK else{throw Failure(code:"fixture_context_query")}
        var result:[[String]]=[]
        while sqlite3_step(statement)==SQLITE_ROW {result.append((0..<sqlite3_column_count(statement)).map{index in sqlite3_column_text(statement,index).map{String(cString:$0)} ?? ""})}
        return result
    }
    func object(_ sql:String)throws->[String:Any] {let text=try rows(sql).first?.first ?? "{}";return try JSONSerialization.jsonObject(with:Data(text.utf8)) as! [String:Any]}
    var readerMS:[Double]=[]
    func readCLI(_ args:[String])throws->[String:Any] {
        let task=Process(),pipe=Pipe();task.executableURL=PythonRuntime.executable()!
        task.arguments=[view.root+"/meeting_context.py","--database",file.path]+args
        task.standardOutput=pipe;task.standardError=FileHandle.nullDevice
        let start=ProcessInfo.processInfo.systemUptime;try task.run()
        let data=pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit()
        readerMS.append((ProcessInfo.processInfo.systemUptime-start)*1000)
        guard task.terminationStatus==0 else{throw Failure(code:"context_cli_failed")}
        return try JSONSerialization.jsonObject(with:data) as! [String:Any]
    }
    func state()throws->[String:Any] {try object("SELECT value FROM state WHERE key='current'")}
    func metadata()throws->[String:Any] {try object("SELECT metadata FROM meetings WHERE session='context-meeting'")}
    func event(_ id:String,_ text:String,_ start:Double,_ final:Bool=true)->[String:Any] {
        ["type":"segment","session":"context-meeting","segment_id":id,"revision":1,"track":"mic","source_id":"mic","epoch":"context-epoch","start":start,"end":start+3,"end_time_known":true,"final":final,"text":text,"speaker":["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":"context-epoch"],"identity_features":["never_export":"VOICE_PRIVATE_FIXTURE"]]
    }
    publisher.flushForChecks()
    try check(try rows("PRAGMA user_version")[0][0]=="2","notes_projection_schema_two")
    for _ in 0..<3 {_ = try MeetingContextStore(directory:folder)}
    try check(try rows("PRAGMA user_version")[0][0]=="2","notes_projection_reopen_is_idempotent")
    try check(try state()["session"] is NSNull,"launch_has_no_current_meeting")
    view.receive(["type":"started","session":"context-meeting","cache_id":UUID().uuidString,"mode":"cloud","absolute_clock":["schema":1,"basis":"capture_clock","time_zone":"Asia/Shanghai","anchors":[["relative_start":0.0,"unix_time":1791200000.0]]]])
    view.receive(event("first","讨论示例产品的使用反馈和支持成本。",10));try view.settleTranscriptForOfflineReview()
    let flushed=await withCheckedContinuation { continuation in view.flushMeetingContext{continuation.resume(returning:$0)} }
    try check(flushed,"async_context_flush_confirms_wal_commit")
    try check(try state()["session"] as? String=="context-meeting","recording_owner_activates_current_session")
    let payload=try rows("SELECT payload FROM segments WHERE parent='first'")[0][0]
    try check(payload.contains("示例产品") && !payload.contains("VOICE_PRIVATE") && !payload.contains("identity_features"),"context_whitelist_excludes_voice_features")
    try check(payload.contains("absolute_start") && payload.contains("+08:00"),"actual_audio_time_is_preserved")
    let live=try readCLI(["current","--query","示例产品"])
    try check(live["status"] as? String=="ok" && live["response_mode"] as? String=="live_meeting" && live["session"] as? String=="context-meeting","actual_cli_reads_live_delegate_projection")
    try check(readerMS.last!<1000,"cold_cli_returns_within_one_second")
    let originalRevision=try rows("SELECT updated_revision FROM segments WHERE parent='first'")[0][0]
    let sameRows=try JSONSerialization.jsonObject(with:Data(payload.utf8)) as! [[String:Any]]
    publisher.replace(session:"context-meeting",parent:"first",rows:sameRows);publisher.flushForChecks()
    try check(try rows("SELECT updated_revision FROM segments WHERE parent='first'")[0][0]==originalRevision,"unchanged_projection_keeps_continuation_revision")
    view.receive(event("second","刚才这个数据需要核实",15,false));try view.settleTranscriptForOfflineReview();publisher.flushForChecks()
    try check(try rows("SELECT updated_revision FROM segments WHERE parent='first'")[0][0]==originalRevision,"new_segment_does_not_rewrite_prior_meeting")
    try check(try rows("SELECT payload FROM segments WHERE parent='second'")[0][0].contains("\"final\":false"),"partial_text_is_not_final")
    let before=try rows("SELECT revision FROM meetings WHERE session='context-meeting'")[0][0]
    view.naming.setSpeaker(segment:"first",name:"合成说话人乙");view.markAllTranscriptParentsDirty();try view.settleTranscriptForOfflineReview();publisher.flushForChecks()
    try check(try rows("SELECT payload FROM segments WHERE parent='first'")[0][0].contains("合成说话人乙"),"manual_speaker_correction_reaches_reader")
    try check(try rows("SELECT revision FROM meetings WHERE session='context-meeting'")[0][0] != before,"manual_change_advances_revision")
    try check(try metadata()["projection_updating"] as? Bool==false,"completed_projection_releases_reader")
    let shared=SharedPersonReference(id:"person:1234567890abcdef1234",name:"合成说话人乙",evidence:["/synthetic/people.md"])
    view.naming.attachConfirmation(segmentIDs:["first"],name:shared.name,person:shared,learn:false)
    view.markAllTranscriptParentsDirty();try view.settleTranscriptForOfflineReview();publisher.flushForChecks()
    try check(try rows("SELECT payload FROM segments WHERE parent='first'")[0][0].contains(shared.id),"actual_producer_exports_explicit_shared_person_identity")
    let sharedRead=try readCLI(["read","--session","context-meeting"])
    let sharedJSON=String(data:try JSONSerialization.data(withJSONObject:sharedRead),encoding:.utf8)!
    try check(sharedJSON.contains(shared.id),"actual_python_reader_preserves_producer_shared_identity")
    view.receive(["type":"asr_replay","session":"context-meeting","discard_segment_ids":["second"]]);try view.settleTranscriptForOfflineReview();publisher.flushForChecks()
    try check(try rows("SELECT deleted FROM segments WHERE parent='second'")[0][0]=="1","retracted_text_has_delta_tombstone")
    view.phase.phase = .paused;view.updateUI();publisher.flushForChecks()
    try check(try state()["phase"] as? String=="paused","pause_publication_does_not_wait_for_agent")
    // The owning view republishes its own cache's notes on every UI update, so
    // the fixture must be that same cache: recoveryBase()/<currentCacheID>.
    guard let noteCacheID=view.currentCacheID else{throw Failure(code:"note_fixture_missing_cache_id")}
    view.recoveryRootOverride=folder
    let noteCache=folder.appendingPathComponent(noteCacheID)
    try FileManager.default.createDirectory(at:noteCache,withIntermediateDirectories:true)
    let noteStore=MeetingNotesStore(directory:noteCache)
    publisher.trackNotes(session:"context-meeting",directory:noteCache);publisher.flushForChecks()
    try check(!FileManager.default.fileExists(atPath:noteStore.notes.path),"empty_projection_does_not_create_notes_source")
    let note=try MeetingNotesStore.queue.sync {try noteStore.create(text:"笔记投影初稿",anchor:MeetingNoteAnchor(relative:15,state:"recording"))}
    publisher.flushForChecks()
    try check(try rows("SELECT text,rev,state,anchor_relative FROM notes WHERE id='\(note.note_id)'")[0]==["笔记投影初稿","1","recording","15.0"],"durable_note_create_reaches_projection")
    try MeetingNotesStore.queue.sync {_ = try noteStore.change(note.note_id,text:"笔记修订",starred:true,archive:false)}
    publisher.flushForChecks()
    try check(try rows("SELECT text,rev,starred,archive FROM notes WHERE id='\(note.note_id)'")[0]==["笔记修订","2","1","0"],"note_edit_star_and_reference_flag_reach_projection")
    try MeetingNotesStore.queue.sync {_ = try noteStore.change(note.note_id,op:"delete")}
    publisher.flushForChecks()
    try check(try rows("SELECT deleted FROM notes WHERE id='\(note.note_id)'")[0][0]=="1","note_delete_projects_tombstone")
    try MeetingNotesStore.queue.sync {_ = try noteStore.change(note.note_id,op:"restore")}
    publisher.flushForChecks()
    try check(try rows("SELECT rev,deleted FROM notes WHERE id='\(note.note_id)'")[0]==["4","0"],"note_restore_projects_current_revision")
    let stableNoteRevision=try rows("SELECT revision FROM meetings WHERE session='context-meeting'")[0][0]
    publisher.flushForChecks()
    try check(try rows("SELECT revision FROM meetings WHERE session='context-meeting'")[0][0]==stableNoteRevision,"unchanged_note_poll_does_not_advance_revision")
    // Hold only the derived OCR job: durable note publication must remain free.
    let ocrGate=DispatchSemaphore(value:0)
    noteStore.recognize={_ in ocrGate.wait();return "本机OCR完成"}
    defer {ocrGate.signal()}
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:8,bitsPerPixel:32)!
    let imageData=bitmap.representation(using:.png,properties:[:])!
    let imageNote=try MeetingNotesStore.queue.sync {try noteStore.create(images:[imageData],anchor:nil)}
    publisher.flushForChecks()
    let beforeOCR=try rows("SELECT images FROM notes WHERE id='\(imageNote.note_id)'")[0][0]
    try check(beforeOCR.contains("ocr_text") && !beforeOCR.contains("本机OCR完成"),"image_projection_does_not_wait_for_ocr")
    let otherCache=folder.appendingPathComponent("other-note-cache")
    try FileManager.default.createDirectory(at:otherCache,withIntermediateDirectories:true)
    publisher.update(["schema":1,"session":"other-notes","phase":"paused","local_only":false,"projection_updating":false])
    publisher.trackNotes(session:"other-notes",directory:otherCache)
    ocrGate.signal()
    try check(noteStore.ocrTasks.wait(timeout:.now()+5) == .success,"derived_ocr_finishes")
    publisher.flushForChecks()
    try check(try rows("SELECT images FROM notes WHERE id='\(imageNote.note_id)'")[0][0].contains("本机OCR完成"),"ocr_completion_refreshes_original_session_after_switch")
    try check(try rows("SELECT COUNT(*) FROM notes WHERE session='other-notes'")[0][0]=="0","notes_never_cross_sessions")
    try check(try rows("SELECT state,anchor_relative FROM notes WHERE id='\(imageNote.note_id)'")[0]==["after",""],"after_meeting_note_has_no_capture_anchor")
    let history=Delegate();history.previewRenderOnly=true;history.isHistoryReader=true;history.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));history.contextPublisher=publisher
    history.receive(["type":"started","session":"wrong-history","cache_id":UUID().uuidString]);publisher.flushForChecks()
    try check(try state()["session"] as? String=="context-meeting","history_reader_cannot_steal_current_meeting")
    view.phase.phase = .stopped;view.updateUI();publisher.flushForChecks()
    try check(try state()["phase"] as? String=="stopped","stopped_is_not_reported_live")
    try check(try readCLI(["current"])["status"] as? String=="no_current_meeting","actual_cli_does_not_read_stopped_meeting")
    view.activeSession=nil;view.phase.phase = .connecting;view.updateUI();publisher.flushForChecks()
    try check(try state()["session"] is NSNull,"new_start_never_falls_back_to_previous_meeting")
    let previousTitle="历史会谈名称"
    view.activeSession="previous-title-session";view.contextSession="previous-title-session";view.currentCacheID=UUID().uuidString
    view.meetingTitle=previousTitle;view.phase.phase = .stopped
    publisher.activate(["schema":1,"session":"previous-title-session","title":previousTitle,"phase":"stopped","local_only":false,"projection_updating":false,"recording_elapsed_seconds":0,"asr_states":[:],"transcription_complete":true,"response_mode":"live_meeting"])
    publisher.flushForChecks()
    view.newMeeting();publisher.flushForChecks()
    let previousMetadata=try object("SELECT metadata FROM meetings WHERE session='previous-title-session'")
    let afterNewMeetingState=try state()
    try check(previousMetadata["title"] as? String==previousTitle && view.activeSession==nil && view.contextSession==nil &&
              afterNewMeetingState["session"] is NSNull,"new_meeting_clears_old_context_before_changing_visible_title")
    let recoveredSession="recovered-context-session",recoveredCache=UUID().uuidString
    publisher.activate(["schema":1,"session":recoveredSession,"cache_id":recoveredCache,"title":"已恢复的会议","phase":"stopped","local_only":false,"projection_updating":false,"recording_elapsed_seconds":20,"asr_states":[:],"transcription_complete":false,"response_mode":"live_meeting"])
    publisher.flushForChecks()
    let turnsBefore=try rows("SELECT COUNT(*) FROM segments WHERE session='\(recoveredSession)'")[0][0]
    let recoveryInfo:[String:Any] = ["kind":"interrupted_capture","state":"recovered_unclean_shutdown","audio_files_preserved":true,"gapless_capture_verified":false,"transcript_modified":false,"transcription_started":false,"tracks":[],"warnings":["source_gap_or_interruption_possible"]]
    publisher.reconcileRecordingRecovery(session:recoveredSession,cacheID:recoveredCache,transcriptionComplete:true,metadata:recoveryInfo);publisher.flushForChecks()
    let reconciled=try object("SELECT metadata FROM meetings WHERE session='\(recoveredSession)'")
    let recoveryRevision=try rows("SELECT revision FROM meetings WHERE session='\(recoveredSession)'")[0][0]
    try check(reconciled["transcription_complete"] as? Bool==true && (reconciled["recording_recovery"] as? [String:Any])?["state"] as? String=="recovered_unclean_shutdown","library_recovery_updates_existing_context_without_opening_meeting")
    try check(try rows("SELECT COUNT(*) FROM segments WHERE session='\(recoveredSession)'")[0][0]==turnsBefore,"recovery_reconciliation_never_rewrites_turns")
    publisher.reconcileRecordingRecovery(session:recoveredSession,cacheID:recoveredCache,transcriptionComplete:true,metadata:recoveryInfo);publisher.flushForChecks()
    try check(try rows("SELECT revision FROM meetings WHERE session='\(recoveredSession)'")[0][0]==recoveryRevision,"recovery_reconciliation_is_idempotent")
    let errorInfo:[String:Any] = ["kind":"interrupted_capture","state":"source_error","code":"cache_recovery_chunk_integrity","audio_files_preserved":true,"gapless_capture_verified":false,"transcript_modified":false,"transcription_started":false,"tracks":[],"warnings":[]]
    publisher.reconcileRecordingRecovery(session:recoveredSession,cacheID:recoveredCache,transcriptionComplete:false,metadata:errorInfo);publisher.flushForChecks()
    let errored=try object("SELECT metadata FROM meetings WHERE session='\(recoveredSession)'")
    try check(errored["transcription_complete"] as? Bool==false && (errored["recording_recovery"] as? [String:Any])?["state"] as? String=="source_error","source_error_withdraws_stale_complete_projection")
    let activeSession="active-recovery-context",activeCache=UUID().uuidString
    publisher.activate(["schema":1,"session":activeSession,"cache_id":activeCache,"phase":"recording","projection_updating":false,"transcription_complete":false])
    publisher.flushForChecks()
    publisher.reconcileRecordingRecovery(session:activeSession,cacheID:activeCache,transcriptionComplete:true,metadata:recoveryInfo);publisher.flushForChecks()
    try check(try object("SELECT metadata FROM meetings WHERE session='\(activeSession)'")["transcription_complete"] as? Bool==false,"active_recording_projection_is_not_reconciled")
    try check((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue==0o600,"context_projection_is_owner_only")
    var blocker:OpaquePointer?;sqlite3_open(file.path,&blocker);sqlite3_exec(blocker,"BEGIN IMMEDIATE",nil,nil,nil)
    try MeetingNotesStore.queue.sync {_ = try noteStore.change(note.note_id,text:"锁住期间旧修订")}
    let start=ProcessInfo.processInfo.systemUptime
    publisher.update(try metadata());publisher.replace(session:"context-meeting",parent:"blocked",rows:[["id":"blocked","parent":"blocked","text":"保存稍慢也不影响暂停","start":20.0,"final":true]])
    let enqueueMS=(ProcessInfo.processInfo.systemUptime-start)*1000
    try check(enqueueMS<50,"locked_database_cannot_block_recording_owner")
    publisher.flushForChecks();try check(publisher.lastError != nil,"publication_failure_is_detected")
    try MeetingNotesStore.queue.sync {_ = try noteStore.change(note.note_id,text:"锁住期间最新修订")}
    sqlite3_exec(blocker,"ROLLBACK",nil,nil,nil);sqlite3_close(blocker);publisher.flushForChecks()
    try check(try rows("SELECT COUNT(*) FROM segments WHERE parent='blocked'")[0][0]=="1","failed_projection_retries_without_loss")
    try check(try rows("SELECT text FROM notes WHERE id='\(note.note_id)'")[0][0]=="锁住期间最新修订","failed_note_write_retries_latest_durable_revision")
    // Exercise scheduled rendering, not the direct-render test helper: the
    // previous 120 ms delay per 24 parents hid multi-minute bulk rebuilds.
    let large=Delegate();large.previewRenderOnly=true
    large.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    large.contextPublisher=MeetingContextPublisher(directory:folder.appendingPathComponent("bulk"))
    large.receive(["type":"started","session":"context-meeting","cache_id":UUID().uuidString,"mode":"cloud"])
    large.deferPresentation=true
    let bulkRows=min(50000,max(1200,Int(ProcessInfo.processInfo.environment["MEETING_CONTEXT_BENCH_ROWS"] ?? "1200") ?? 1200))
    for index in 0..<bulkRows {large.receive(event("bulk-\(index)","这是第\(index)段合成讨论。",Double(index*4)))}
    large.markAllTranscriptParentsDirty();large.deferPresentation=false
    let bulkStart=ProcessInfo.processInfo.systemUptime
    large.scheduleTranscriptRender()
    var pauseMS:Double?
    DispatchQueue.main.async {large.phase.phase = .paused;large.updateUI();pauseMS=(ProcessInfo.processInfo.systemUptime-bulkStart)*1000}
    while large.fullTranscriptRefreshPending || large.fullRefreshBuildInFlight || large.dirtyTranscriptQueueIndex<large.dirtyTranscriptQueue.count {
        if ProcessInfo.processInfo.systemUptime-bulkStart>30 {throw Failure(code:"bulk_projection_deadline")}
        try await Task.sleep(nanoseconds:2_000_000)
    }
    large.contextPublisher?.flushForChecks()
    let bulkMS=(ProcessInfo.processInfo.systemUptime-bulkStart)*1000
    try check(pauseMS != nil && pauseMS!<500,"pause_runs_during_scheduled_bulk_projection")
    try check(bulkMS<30000,"scheduled_bulk_projection_does_not_idle_between_batches")
    let evidence:[String:Any]=["type":"meeting_context_checks","passed":checks.count,"checks":checks,"enqueue_under_db_lock_ms":enqueueMS,"cold_cli_ms":readerMS,"bulk_parent_count":bulkRows,"bulk_rebuild_ms":bulkMS,"pause_during_bulk_ms":pauseMS!,"database":file.path,"capture":false,"cloud":false,"keychain":false]
    try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("checks.json"),options:.atomic)
    return evidence
}
