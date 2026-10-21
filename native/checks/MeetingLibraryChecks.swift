import AppKit
import CryptoKit

// Controlled offline I/O boundary: no capture, network, or actual user records.
private final class MeetingLibraryReadProbe {
    let blockedID:String;let release=DispatchSemaphore(value:0)
    private let lock=NSLock();private var counts:[String:Int]=[:]
    init(_ id:String){blockedID=id}
    func count(_ id:String)->Int {lock.lock();defer{lock.unlock()};return counts[id] ?? 0}
    func read(_ item:CachedMeeting,root:URL)throws->MeetingLibraryFiles {
        lock.lock();counts[item.id,default:0]+=1;let index=counts[item.id]!;lock.unlock()
        if item.id==blockedID,index==1 {guard release.wait(timeout:.now()+4) == .success else{throw Failure(code:"library_probe_release_timeout")}}
        return try MeetingLibraryFiles.read(item,root:root)
    }
}

private final class MeetingLibraryExportGate {
    private let lock=NSLock();private var didEnter=false;private var didRelease=false
    private let releaseSignal=DispatchSemaphore(value:0)
    func enterAndWait() {
        lock.lock();didEnter=true;lock.unlock()
        _ = releaseSignal.wait(timeout:.now()+30)
    }
    func hasEntered()->Bool {lock.lock();defer{lock.unlock()};return didEnter}
    func release() {
        lock.lock();let shouldSignal = !didRelease;didRelease=true;lock.unlock()
        if shouldSignal {releaseSignal.signal()}
    }
}

@MainActor func meetingLibraryChecks(directory:URL) async throws->[String:Any] {
    guard Credential.offline,directory.path.contains("/.runtime/") else{throw Failure(code:"library_fixture_scope")}
    _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    let fm=FileManager.default,base=directory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at:base,withIntermediateDirectories:true)
    var checks:[String]=[]
    func check(_ condition:Bool,_ name:String)throws{guard condition else{throw Failure(code:name)};checks.append(name);print("library-check: "+name)}
    func wait(_ condition:()->Bool) async throws {let until=Date().addingTimeInterval(8);while !condition(),Date()<until {try await Task.sleep(nanoseconds:10_000_000)};guard condition() else{throw Failure(code:"library_fixture_timeout")}}
    func json(_ value:[String:Any],_ file:URL)throws{try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:file)}
    func fixture(_ title:String="同名会议")throws->CachedMeeting {
        let folder=base.appendingPathComponent(UUID().uuidString),session=UUID().uuidString
        let journal=try RecordingJournal(directory:folder,track:"mic",freeSpace:{1_000_000_000});try journal.enqueue(Data(repeating:0x37,count:3200),at:0);journal.finish();journal.wait()
        journal.record(["type":"segment","session":session,"segment_id":"original","track":"mic","source_id":"mic","epoch":"fixture","start":0,"end":0.1,"text":"原文必须完整保留","revision":1,"final":true,"speaker":["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":"fixture"]]);journal.wait()
        try json(["session":session,"cache_id":folder.lastPathComponent,"bundle":"*microphone*"],folder.appendingPathComponent("meeting.json"));try MeetingLibraryInfo.saveTitle(title,in:folder)
        return try cachedMeetings(in:base).first{$0.id==folder.lastPathComponent}!
    }
    func hashes(_ folder:URL)throws->[String:String] {var result:[String:String]=[:];for case let f as URL in fm.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey])! {if try f.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true {result[String(f.path.dropFirst(folder.path.count))]=SHA256.hash(data:try Data(contentsOf:f)).map{String(format:"%02x",$0)}.joined()}};return result}
    let store=MeetingDeletionStore(cacheRoot:base,binRoot:directory.appendingPathComponent("bin"),exportsRoot:directory.appendingPathComponent("exports"))
    let first=try fixture(),second=try fixture(),firstHash=try hashes(first.directory),secondHash=try hashes(second.directory)
    let shared=directory.appendingPathComponent("voices.json"),external=directory.appendingPathComponent("独立项目归档.txt")
    try Data("shared voice archive".utf8).write(to:shared);try Data("user-owned export".utf8).write(to:external)
    let context=MeetingContextPublisher(directory:directory.appendingPathComponent("context")),session=try first.metadata()["session"] as! String,otherSession=try second.metadata()["session"] as! String
    context.activate(["session":otherSession,"title":"其他录音","phase":"recording"]);context.update(["session":session,"title":"待删除","phase":"stopped"]);context.replace(session:session,parent:"p",rows:[["start":0,"text":"旧投影"]]);context.flushForChecks()
    let receipt=try store.trash(first,afterMove:{try context.deleteSession($0)})
    try check(!fm.fileExists(atPath:first.directory.path) && (try hashes(store.folder(receipt).appendingPathComponent("cache")))==firstHash,"all_session_files_move_together_unchanged")
    try check(try hashes(second.directory)==secondHash,"same_title_other_session_untouched")
    context.update(["session":session,"title":"迟到标题"]);context.replace(session:session,parent:"p",rows:[["start":0,"text":"迟到修订"]]);context.flushForChecks()
    let db=try MeetingContextStore(directory:directory.appendingPathComponent("context"));try check(try db.revision(session)==0 && db.revision(otherSession)>0,"deleted_projection_cannot_resurrect_or_clear_other_current")
    var duplicateRejected=false;do{_=try store.trash(first)}catch{duplicateRejected=true};try check(duplicateRejected,"duplicate_delete_preserves_recycle_payload")
    try fm.createDirectory(at:first.directory,withIntermediateDirectories:true);var collision=false;do{try store.restore(receipt)}catch{collision=true};try check(collision && fm.fileExists(atPath:try store.folder(receipt).appendingPathComponent("cache").path),"restore_collision_never_overwrites")
    try fm.removeItem(at:first.directory);try store.restore(receipt,afterMove:{try context.restoreSession($0)});try check(try hashes(first.directory)==firstHash,"restore_preserves_original_cache_id_and_all_hashes")
    context.update(["session":session,"title":"恢复"]);context.flushForChecks();try check(try db.revision(session)>0,"restored_projection_can_rebuild")
    let third=try fixture("退役录音"),retired=base.appendingPathComponent(".retired").appendingPathComponent(third.id);try fm.createDirectory(at:retired,withIntermediateDirectories:true);try Data([1,2,3,4]).write(to:retired.appendingPathComponent("mic-000001.pcm"))
    try json(["schema":1,"cache_id":third.id,"state":"trashed","destination":retired.path,"recoverable":true],third.directory.appendingPathComponent("audio-retirement.json"))
    let thirdHash=try hashes(third.directory),retiredHash=try hashes(retired)
    store.beforeMove={index in if index==1 {throw Failure(code:"synthetic_move_failure")}}
    var rolledBack=false;do{_=try store.trash(third)}catch{rolledBack=true};try check(rolledBack && (try hashes(third.directory))==thirdHash && (try hashes(retired))==retiredHash,"mid_delete_failure_rolls_back_retired_and_cache")
    store.beforeMove=nil
    let exportFolder=store.exportsRoot.appendingPathComponent(third.id);try fm.createDirectory(at:exportFolder,withIntermediateDirectories:true);try json(["cache_id":third.id,"session":try third.metadata()["session"]!],exportFolder.appendingPathComponent("meeting-owner.json"));try Data("app owned export".utf8).write(to:exportFolder.appendingPathComponent("原文.txt"));let exportHash=try hashes(exportFolder)
    let thirdReceipt=try store.trash(third);try check(!fm.fileExists(atPath:retired.path) && !fm.fileExists(atPath:exportFolder.path),"exact_retired_audio_and_owned_exports_follow_session")
    store.beforeMove={index in if index==1 {throw Failure(code:"synthetic_restore_failure")}};var restoreFailed=false;do{try store.restore(thirdReceipt)}catch{restoreFailed=true};try check(restoreFailed && !fm.fileExists(atPath:retired.path),"mid_restore_failure_returns_all_payloads_to_bin")
    store.beforeMove=nil;try store.restore(thirdReceipt);try check(try hashes(retired)==retiredHash && hashes(exportFolder)==exportHash,"restored_retired_audio_and_exports_keep_hashes")
    let linked=try fixture();try fm.createSymbolicLink(at:linked.directory.appendingPathComponent("escape"),withDestinationURL:shared);var symlinkRejected=false;do{_=try store.trash(linked)}catch{symlinkRejected=true};try check(symlinkRejected && fm.fileExists(atPath:linked.directory.path),"symlink_escape_rejected_before_any_move")
    let bad=try fixture();try json(["state":"trashed","cache_id":bad.id,"destination":directory.path,"recoverable":true],bad.directory.appendingPathComponent("audio-retirement.json"));var wrongRetirement=false;do{_=try store.trash(bad)}catch{wrongRetirement=true};try check(wrongRetirement,"cross_session_retirement_path_rejected")
    let legacyRoot=directory.appendingPathComponent("legacy-trash"),legacyAudio=legacyRoot.appendingPathComponent(".audio-retirement-"+UUID().uuidString)
    try fm.createDirectory(at:legacyAudio,withIntermediateDirectories:true);try Data([9,8,7]).write(to:legacyAudio.appendingPathComponent("mic.pcm"))
    let legacyStore=MeetingDeletionStore(cacheRoot:base,binRoot:store.binRoot,exportsRoot:store.exportsRoot,legacyAudioTrashRoot:legacyRoot),legacyItem=try fixture("旧版已移走原音")
    try json(["state":"trashed","cache_id":legacyItem.id,"destination":legacyAudio.path,"recoverable":true],legacyItem.directory.appendingPathComponent("audio-retirement.json"))
    let legacyHash=try hashes(legacyItem.directory),legacyAudioHash=try hashes(legacyAudio),legacyReceipt=try legacyStore.trash(legacyItem)
    try check(legacyReceipt.resources==["cache"] && (try hashes(legacyAudio))==legacyAudioHash && (try hashes(legacyStore.folder(legacyReceipt).appendingPathComponent("cache")))==legacyHash,"legacy_trash_reference_preserved_without_moving_external_audio")
    try legacyStore.restore(legacyReceipt);try check(try hashes(legacyItem.directory)==legacyHash && hashes(legacyAudio)==legacyAudioHash,"legacy_restore_preserves_original_metadata_and_external_audio")
    try fm.removeItem(at:legacyAudio)
    let missingLegacyReceipt=try legacyStore.trash(legacyItem);try legacyStore.restore(missingLegacyReceipt)
    try check(try hashes(legacyItem.directory)==legacyHash,"missing_legacy_audio_does_not_block_cache_delete_or_restore")
    try json(["state":"trashed","cache_id":legacyItem.id,"destination":legacyRoot.appendingPathComponent("unrelated").path,"recoverable":true],legacyItem.directory.appendingPathComponent("audio-retirement.json"))
    var legacyShapeRejected=false;do{_=try legacyStore.trash(legacyItem)}catch{legacyShapeRejected=true};try check(legacyShapeRejected,"unrecognized_external_audio_reference_still_rejected")
    let failedProjection=try fixture(),failedHash=try hashes(failedProjection.directory);var failed=false;do{_=try store.trash(failedProjection,afterMove:{_ in throw Failure(code:"synthetic_sql_failure")})}catch{failed=true};try check(failed && (try hashes(failedProjection.directory))==failedHash,"projection_failure_restores_original_files")
    try check(try Data(contentsOf:shared)==Data("shared voice archive".utf8) && Data(contentsOf:external)==Data("user-owned export".utf8),"shared_voiceprints_and_project_archives_unchanged")
    let nested=MeetingDeletionStore(cacheRoot:base,binRoot:directory.appendingPathComponent("nested-bin"),exportsRoot:directory)
    var nestedRejected=false;do{_=try nested.trash(first)}catch{nestedRejected=true};try check(nestedRejected && fm.fileExists(atPath:first.directory.path),"overlapping_export_cache_roots_rejected")
    let dangling=try fixture();try fm.createSymbolicLink(at:dangling.directory.appendingPathComponent("missing-link"),withDestinationURL:directory.appendingPathComponent("absent"));var danglingRejected=false;do{_=try store.trash(dangling)}catch{danglingRejected=true};try check(danglingRejected && fm.fileExists(atPath:dangling.directory.path),"dangling_symlink_rejected_without_moving_original")
    let projected=try fixture(),projectedHash=try hashes(projected.directory),projectedReceipt=try store.trash(projected)
    var restoreProjectionFailed=false;do{try store.restore(projectedReceipt,afterMove:{_ in throw Failure(code:"synthetic_restore_sql_failure")})}catch{restoreProjectionFailed=true}
    try check(restoreProjectionFailed && !fm.fileExists(atPath:projected.directory.path) && (try hashes(store.folder(projectedReceipt).appendingPathComponent("cache")))==projectedHash,"restore_projection_failure_rolls_back_all_original_bytes")
    try store.restore(projectedReceipt)
    let crash=try fixture(),crashHash=try hashes(crash.directory),crashReceipt=try store.trash(crash)
    var prepared=crashReceipt;prepared.state="prepared";try JSONEncoder().encode(prepared).write(to:store.folder(crashReceipt).appendingPathComponent("receipt.json"))
    try store.restore(prepared);try check(try hashes(crash.directory)==crashHash,"interrupted_prepared_transaction_can_restore_original_bytes")
    let dbAfterRestart=try MeetingContextStore(directory:directory.appendingPathComponent("context"));try dbAfterRestart.deleteSession(session);try dbAfterRestart.write(metadata:["session":session,"title":"迟到旧窗口"],parents:[:],current:nil)
    try check(try dbAfterRestart.revision(session)==0,"persistent_tombstone_blocks_other_writer_after_restart");try dbAfterRestart.restoreSession(session)
    let app=Delegate();app.previewRenderOnly=true;app.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));app.recoveryRootOverride=base;app.deletionStoreOverride=store;app.reloadLibrary();try await wait{!app.libraryJob.busy}
    app.deletionConfirmationOverride={_ in false};app.requestDeleteMeeting(second);try check(!app.meetingDeletionBusy && fm.fileExists(atPath:second.directory.path),"cancel_actual_delete_handler_keeps_meeting")
    app.deletionConfirmationOverride={_ in true};app.currentCacheID=first.id;app.activeSession=session;app.phase.phase = .recording;let stoppedFlag=NSMutableArray();app.mockStopHandler={stoppedFlag.add(true)}
    app.requestDeleteMeeting(second);app.requestDeleteMeeting(second);try await wait{!app.meetingDeletionBusy}
    try check(!fm.fileExists(atPath:second.directory.path) && stoppedFlag.count==0 && app.phase.phase == .recording && app.currentCacheID==first.id,"actual_historical_delete_does_not_stop_other_live_meeting")
    let secondReceipt=try store.receipts().first{$0.cacheID==second.id}!;app.restoreDeletedMeeting(secondReceipt);try await wait{!app.meetingDeletionBusy};try check(try hashes(second.directory)==secondHash,"actual_restore_handler_restores_original_meeting")
    app.phase.phase = .paused;app.qaStore=nil;app.mock=true;app.mockStopHandler={stoppedFlag.add(true)}
    app.deletionConfirmationOverride={_ in false};app.requestDeleteMeeting(first)
    try check(app.canDeleteCurrentMeeting && !app.meetingDeletionBusy && app.phase.phase == .paused && fm.fileExists(atPath:first.directory.path) && stoppedFlag.count==0,"cancel_paused_delete_keeps_connection_and_recording")
    app.deletionConfirmationOverride={_ in app.phase.phase = .recording;return true};app.requestDeleteMeeting(first)
    try check(!app.meetingDeletionBusy && stoppedFlag.count==0 && fm.fileExists(atPath:first.directory.path),"resume_during_delete_confirmation_rechecks_recording_gate")
    app.phase.phase = .paused;app.deletionConfirmationOverride={_ in true}
    let pausedAudio=try Data(contentsOf:first.directory.appendingPathComponent("mic-000000.pcm")),pausedText=try Data(contentsOf:first.directory.appendingPathComponent("mic-transcript.jsonl"))
    app.requestDeleteMeeting(first);app.requestDeleteMeeting(first)
    try check(app.meetingDeletionBusy && app.phase.phase == .stopping && stoppedFlag.count==1 && fm.fileExists(atPath:first.directory.path),"paused_delete_internally_finishes_once_before_moving_files")
    app.buffer=Data("waiting for final event\n".utf8)
    app.receive(["type":"stopped","reason":"user_finish","transcription_complete":true])
    try await Task.sleep(nanoseconds:60_000_000)
    try check(app.meetingDeletionBusy && fm.fileExists(atPath:first.directory.path),"paused_delete_waits_for_buffered_final_events")
    app.buffer.removeAll()
    try await wait{!app.meetingDeletionBusy}
    try check(app.currentCacheID==nil && app.phase.phase == .idle && !fm.fileExists(atPath:first.directory.path),"paused_current_delete_saves_and_clears_owner_without_end_button")
    let pausedReceipt=try store.receipts().first{$0.cacheID==first.id}!,pausedPayload=try store.folder(pausedReceipt).appendingPathComponent("cache")
    try check(try Data(contentsOf:pausedPayload.appendingPathComponent("mic-000000.pcm"))==pausedAudio && Data(contentsOf:pausedPayload.appendingPathComponent("mic-transcript.jsonl"))==pausedText,"paused_delete_preserves_original_audio_and_transcript_bytes")
    app.mock=false
    app.restoreDeletedMeeting(try store.receipts().first{$0.cacheID==first.id}!);try await wait{!app.meetingDeletionBusy};try check(fm.fileExists(atPath:first.directory.path) && app.currentCacheID==nil,"restoration_does_not_implicitly_start_capture")
    let failureItem=try fixture("失败重试会议"),failureHash=try hashes(failureItem.directory)
    store.beforeMove={_ in throw Failure(code:"ui_delete_fixture_failure")};app.requestDeleteMeeting(failureItem);try await wait{!app.meetingDeletionBusy}
    try check(try hashes(failureItem.directory)==failureHash,"actual_delete_failure_keeps_all_files_and_reenables_retry")
    store.beforeMove=nil;app.requestDeleteMeeting(failureItem);try await wait{!app.meetingDeletionBusy}
    let failureReceipt=try store.receipts().first{$0.cacheID==failureItem.id}!
    app.restoreSelectionOverride={_ in nil};app.showDeletedMeetings();try await wait{!app.meetingDeletionBusy};try check(!fm.fileExists(atPath:failureItem.directory.path),"cancel_actual_restore_picker_keeps_deleted_payload");app.restoreSelectionOverride=nil
    store.beforeMove={_ in throw Failure(code:"ui_restore_fixture_failure")};app.restoreDeletedMeeting(failureReceipt);try await wait{!app.meetingDeletionBusy}
    try check(!fm.fileExists(atPath:failureItem.directory.path),"actual_restore_failure_keeps_recycle_payload")
    store.beforeMove=nil
    let reopenedStore=MeetingDeletionStore(cacheRoot:base,binRoot:store.binRoot,exportsRoot:store.exportsRoot)
    let reopenedReceipt=try reopenedStore.receipts().first{$0.id==failureReceipt.id}!
    app.restoreDeletedMeeting(reopenedReceipt);try await wait{!app.meetingDeletionBusy}
    try check(try hashes(failureItem.directory)==failureHash,"restore_after_restart_and_failure_retry_preserves_hashes")
    try app.applyRecovery(failureItem,payload:RecoveryPayload(failureItem));app.phase.phase = .recording;app.mockStopHandler={}
    app.requestDeleteMeeting(failureItem)
    try check(!app.meetingDeletionBusy && fm.fileExists(atPath:failureItem.directory.path) && app.phase.phase == .recording,"active_writer_rejected_without_any_stop_or_move")
    let management=app.libraryManagementController
    func selectManaged(_ item:CachedMeeting) async throws {
        app.libraryVisible=[item];app.librarySelectionChanging=true;app.libraryTable.reloadData();app.libraryTable.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);app.librarySelectionChanging=false
        management.refresh();try await wait{management.loadedID==item.id && !management.readJob.busy}
    }
    try await selectManaged(failureItem)
    app.libraryMenuTarget=failureItem;let menu=NSMenu();menu.autoenablesItems=false;app.populateLibraryActions(menu)
    func operation(_ op:MeetingLibraryOperation)->NSMenuItem? {menu.items.first{($0.representedObject as? [String:Any])?["operation"] as? Int==op.rawValue}}
    try check(operation(.delete)?.isEnabled==false && !menu.items.contains{$0.action == #selector(Delegate.showDeletedMeetings)},"actual_menu_disables_active_delete_without_duplicate_recycle_entry")
    app.phase.phase = .paused;app.populateLibraryActions(menu)
    try check(operation(.delete)?.isEnabled==true && operation(.delete)?.toolTip==nil,"paused_menu_allows_delete_without_nonexistent_end_instruction")
    app.recordingControlInFlight="pause";app.populateLibraryActions(menu)
    try check(operation(.delete)?.isEnabled==false,"pending_pause_confirmation_blocks_delete_until_capture_acknowledges")
    app.recordingControlInFlight=nil
    app.meetingDeletionBusy=true;app.automaticTailRecoveryAttempted=[]
    app.startAutomaticTailRecovery(reason:"capture_control_timeout_finish",cacheID:failureItem.id,session:app.activeSession!)
    try check(app.automaticTailRecoveryAttempted.isEmpty && !app.cacheReadJob.busy,"deletion_does_not_restart_automatic_tail_upload")
    app.meetingDeletionBusy=false
    app.phase.phase = .stopped;app.populateLibraryActions(menu)
    try check(operation(.delete)?.isEnabled==true && (operation(.delete)?.representedObject as? [String:Any])?["id"] as? String==failureItem.id,"actual_delete_menu_freezes_cache_target")
    try check(MeetingLibraryOperation.visibleOperations.allSatisfy{operation($0) != nil} && operation(.audioFolder)==nil && operation(.transcriptFolder)==nil && operation(.meetingFiles) != nil,"context_menu_exposes_one_meeting_files_action_without_duplicate_folders")
    try check(management.enabled(.audioFolder) && management.enabled(.transcriptFolder),"existing_original_record_folders_are_available")
    let nameBefore=failureItem.displayTitle,rawBefore=try Data(contentsOf:failureItem.directory.appendingPathComponent("mic-000000.pcm"))
    management.renameOverride={_ in nil};management.requestRename(failureItem)
    try check(!management.busy && (try MeetingLibraryInfo.loadTitle(in:failureItem.directory))==nameBefore,"cancel_rename_keeps_original_title")
    management.beforeWrite={_ in throw Failure(code:"synthetic_name_failure")};var nameResult:Result<Void,Error>?
    app.saveLibraryMeetingTitle(failureItem,title:"不能保存的新名"){nameResult=$0};try await wait{nameResult != nil}
    if case .success?=nameResult {throw Failure(code:"rename_failure_was_success")}
    try check(app.meetingTitle==nameBefore && (try MeetingLibraryInfo.loadTitle(in:failureItem.directory))==nameBefore,"rename_write_failure_preserves_view_and_disk_title")
    management.beforeWrite=nil;nameResult=nil;app.phase.phase = .recording
    app.saveLibraryMeetingTitle(failureItem,title:"本场统一新名称"){nameResult=$0};try await selectManaged(second);try await wait{nameResult != nil}
    try check(app.selectedLibraryManagementItem?.id==second.id && management.loadedID==second.id,"completed_rename_preserves_new_selection_and_management_target")
    try check((try MeetingLibraryInfo.loadTitle(in:failureItem.directory))=="本场统一新名称" && (try MeetingLibraryInfo.loadTitle(in:second.directory))==second.displayTitle,"rename_stays_pinned_when_selection_changes")
    try check(app.phase.phase == .recording && app.meetingTitle=="本场统一新名称" && (try Data(contentsOf:failureItem.directory.appendingPathComponent("mic-000000.pcm")))==rawBefore,"active_rename_preserves_recording_pcm_and_updates_only_after_save")
    try check((try MeetingDisplayInfoStore.load(in:failureItem.directory))?.provenance == .manual,"manual_rename_prevents_late_automatic_title_overwrite")
    let local=try fixture("仅录音测试"),localSession=try local.metadata()["session"] as! String
    try json(["session":localSession,"cache_id":local.id,"bundle":"*microphone*","capture_mode":"local_only","asr_model":"qwen-audio-3.0-asr-flash-streaming","asr_destination":"dashscope.aliyuncs.com"],local.directory.appendingPathComponent("meeting.json"))
    try fm.removeItem(at:local.directory.appendingPathComponent("mic-transcript.jsonl"));try await selectManaged(local)
    try check(management.title(.rename)=="重命名会议" && management.title(.renameAudio)=="重命名录音" && management.title(.transcribe)=="转写录音","local_only_has_distinct_meeting_and_audio_rename_actions")
    try check(!management.enabled(.transcribe) && !management.enabled(.transcriptFolder),"other_live_recording_blocks_transcribe_and_no_text_has_no_folder")
    app.phase.phase = .stopped;management.refresh();try check(management.enabled(.transcribe),"local_recording_can_transcribe_after_current_recording_finishes")
    var revealed:URL?;management.revealOverride={revealed=$0;return true}
    management.perform(.audioFolder,item:local);try await selectManaged(second);try await wait{!management.busy}
    try check(revealed==local.directory,"folder_reveal_retains_original_clicked_target_after_selection_change")
    let absent=try fixture("无音频测试");try fm.removeItem(at:absent.directory.appendingPathComponent("mic-000000.pcm"));try await selectManaged(absent)
    try check(!management.enabled(.audioFolder),"missing_pcm_disables_audio_folder_without_fabricated_export")
    let unsafe=try fixture("链接测试");try fm.createSymbolicLink(at:unsafe.directory.appendingPathComponent("mic-999999.pcm"),withDestinationURL:external)
    var rejected=false;do{_=try MeetingLibraryFiles.read(unsafe,root:base)}catch{rejected=true};try check(rejected,"management_folder_reader_rejects_audio_symlink")
    app.recoveries.append(local);try await selectManaged(local);app.recoveryBudgetOverride=10
    var resumedID:String?;app.recoveryRunnerOverride={resumedID=$0.id}
    management.perform(.transcribe,item:local);try await wait{resumedID != nil}
    try check(resumedID==local.id && app.resumeBusy && app.processingAudio,"transcribe_action_reuses_existing_offline_recovery_gate_for_exact_item")
    app.resumeBusy=false;app.processingAudio=false;app.phase.phase = .stopped;app.recoveryRunnerOverride=nil
    try await selectManaged(second);app.libraryMenuTarget=second;app.populateLibraryActions(menu);let frozenDelete=operation(.delete)!
    app.libraryMenuTarget=local;var confirmedID:String?;app.deletionConfirmationOverride={confirmedID=$0.id;return false};app.performLibraryManagementMenu(frozenDelete)
    try check(confirmedID==second.id,"context_action_does_not_follow_mutated_global_menu_target")
    let retry=try fixture("单条记录重试");try await selectManaged(retry)
    let retryMetadata=retry.directory.appendingPathComponent("meeting.json"),goodMetadata=try Data(contentsOf:retryMetadata)
    try Data("invalid fixture metadata".utf8).write(to:retryMetadata);management.refresh(force:true);try await wait{management.loadedID==retry.id && !management.readJob.busy}
    try check(management.files==nil && !management.enabled(.rename),"unreadable_record_disables_unsafe_management_actions")
    try goodMetadata.write(to:retryMetadata);management.refresh()
    try check(management.files==nil && !management.readJob.busy,"failed_record_does_not_retry_on_presentation_ticks")
    app.libraryMenuTarget=retry;app.menuWillOpen(app.libraryTable.menu!);try await wait{management.files != nil && !management.readJob.busy};app.menuDidClose(app.libraryTable.menu!)
    try check(management.enabled(.rename) && management.enabled(.audioFolder),"reopening_context_menu_retries_same_single_record_after_repair")
    try check(app.makeLibraryRecycleButton().title=="回收站" && app.makeLibraryRecycleButton().accessibilityLabel()=="查看并恢复已删除会议","compact_recycle_entry_is_named_and_accessible")
    let fastA=try fixture("快速切换A"),fastB=try fixture("快速切换B"),blocked=MeetingLibraryReadProbe(fastA.id)
    defer{blocked.release.signal()}
    func selectWithoutWaiting(_ item:CachedMeeting) {
        app.libraryVisible=[item];app.librarySelectionChanging=true;app.libraryTable.reloadData();app.libraryTable.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);app.librarySelectionChanging=false;management.refresh()
    }
    management.readOverride={try blocked.read($0,root:$1)}
    selectWithoutWaiting(fastA);try await wait{blocked.count(fastA.id)==1}
    selectWithoutWaiting(fastB);selectWithoutWaiting(fastA)
    try check(management.readJob.busy && management.loadedID==nil,"rapid_A_B_A_cancels_old_result_while_actual_read_is_blocked")
    blocked.release.signal();try await wait{management.loadedID==fastA.id && management.files != nil && !management.readJob.busy}
    try check(blocked.count(fastA.id)==2 && blocked.count(fastB.id)==0,"cancelled_A_B_A_reissues_exactly_one_fresh_A_read")
    let menuProbe=MeetingLibraryReadProbe(fastA.id);defer{menuProbe.release.signal()};management.readOverride={try menuProbe.read($0,root:$1)}
    let contextMenu=app.libraryTable.menu!;app.libraryMenuTarget=fastA;app.populateLibraryActions(contextMenu)
    let renameEntry=contextMenu.items.first{($0.representedObject as? [String:Any])?["operation"] as? Int==MeetingLibraryOperation.rename.rawValue}!
    try check(renameEntry.isEnabled,"loaded_context_menu_rename_is_enabled_before_open")
    app.menuWillOpen(contextMenu)
    try check(!management.readJob.busy && menuProbe.count(fastA.id)==0 && management.enabled(.rename),"opening_loaded_menu_keeps_snapshot_and_does_not_start_redundant_read")
    app.menuDidClose(contextMenu);var renamedFromMenu:String?;management.renameOverride={renamedFromMenu=$0.id;return nil}
    app.performLibraryManagementMenu(renameEntry)
    try check(renamedFromMenu==fastA.id,"loaded_menu_click_after_close_reaches_rename_without_silent_drop")
    management.readOverride=nil
    let visibleOnly=try fixture("仅存在可见列表的合成记录");try await selectManaged(visibleOnly)
    try check(!app.recoveries.contains{$0.id==visibleOnly.id},"visible_only_fixture_exercises_lookup_fallback_without_claiming_production_desync")
    let visibleFolder=NSMenuItem(title:"录音文件夹",action:nil,keyEquivalent:"");visibleFolder.representedObject=["id":visibleOnly.id,"operation":MeetingLibraryOperation.audioFolder.rawValue]
    revealed=nil;management.revealOverride={revealed=$0;return true};app.performLibraryManagementMenu(visibleFolder);try await wait{!management.busy}
    try check(revealed==visibleOnly.directory,"fixed_id_visible_record_fallback_reveals_only_its_own_folder")
    app.phase.phase = .recording;management.perform(.transcribe,item:visibleOnly)
    try check(app.displayedDocument.diagnostic.stringValue.contains("当前会议仍在处理") && !app.displayedDocument.diagnostic.isHidden,"disabled_transcribe_reports_actual_recording_reason")
    management.refresh()
    try check(management.status.stringValue.contains("录音尚未封存，暂不能导出或整理文件") && !management.status.stringValue.contains("其他操作可用") && !management.enabled(.meetingFiles),"history_management_copy_matches_recording_file_gate")
    app.phase.phase = .stopped;management.busy=true;management.perform(.audioFolder,item:visibleOnly)
    try check(app.displayedDocument.diagnostic.stringValue.contains("正在处理记录") && !app.displayedDocument.diagnostic.isHidden,"disabled_action_reports_busy_instead_of_silent_return")
    management.busy=false
    try await selectManaged(second)
    let readableStore=MeetingAudioAssetsStore(cacheRoot:base,exportsRoot:store.exportsRoot),exportGate=MeetingLibraryExportGate()
    defer {exportGate.release()}
    readableStore.beforeStep={step in if step=="export_0" {exportGate.enterAndWait()}}
    management.audioStoreOverride=readableStore;var meetingFilesOpened:URL?
    management.revealOverride={meetingFilesOpened=$0;return true}
    try check(management.buttons[.meetingFiles] != nil && management.buttons[.audioFolder]==nil && management.buttons[.transcriptFolder]==nil,"management_view_has_only_the_merged_folder_action")
    management.perform(.meetingFiles,item:second)
    try await wait{exportGate.hasEntered()}
    app.updateUI()
    try check(management.busy && management.audioAssetOperationInFlight && app.newButton?.isEnabled==false,"first_meeting_files_generation_runs_in_background_and_disables_new_meeting")
    let phaseBeforeMeetingFiles=app.phase.phase;app.beginNewMeeting()
    try check(app.phase.phase==phaseBeforeMeetingFiles && !app.newMeetingRequested,"new_meeting_handler_is_blocked_during_meeting_files_generation")
    exportGate.release();try await wait{!management.busy && !management.audioAssetOperationInFlight}
    let completeFolder=store.exportsRoot.appendingPathComponent(second.id)
    let generatedText=try String(contentsOf:completeFolder.appendingPathComponent(second.displayTitle+"－转写原文.txt"),encoding:.utf8)
    let guideText=try String(contentsOf:completeFolder.appendingPathComponent("会议说明.txt"),encoding:.utf8)
    try check(meetingFilesOpened==completeFolder && generatedText.contains("原文必须完整保留") && guideText.contains("麦克风") && guideText.contains("转写状态："),"first_meeting_files_action_opens_current_session_bundle_with_status")
    try check(app.newButton?.isEnabled==true && app.phase.phase==phaseBeforeMeetingFiles,"meeting_files_completion_releases_busy_gate_without_starting_recording")
    management.renameOverride=nil;management.revealOverride=nil
    try app.applyRecovery(local,payload:RecoveryPayload(local));app.phase.phase = .paused;app.mock=true;app.qaStore=nil
    app.mockStopHandler={app.receive(["type":"stopped","reason":"user_stop","transcription_complete":false])}
    let localAudioBefore=try Data(contentsOf:local.directory.appendingPathComponent("mic-000000.pcm"))
    app.deletionConfirmationOverride={_ in true};app.requestDeleteMeeting(local);try await wait{!app.meetingDeletionBusy}
    guard let localReceipt=try store.receipts().first(where:{$0.cacheID==local.id}) else{throw Failure(code:"paused_local_only_delete_receipt_missing")}
    let localPayload=try store.folder(localReceipt).appendingPathComponent("cache")
    try check(app.currentCacheID==nil && !fm.fileExists(atPath:local.directory.path) && !fm.fileExists(atPath:localPayload.appendingPathComponent("mic-transcript.jsonl").path) && (try Data(contentsOf:localPayload.appendingPathComponent("mic-000000.pcm")))==localAudioBefore,"paused_local_only_delete_preserves_audio_without_creating_transcript")
    app.restoreDeletedMeeting(localReceipt);try await wait{!app.meetingDeletionBusy};app.mock=false
    app.phase.phase = .stopped;app.renderLibraryList();app.window.contentView?.layoutSubtreeIfNeeded()
    if let target=app.window.contentView,let bitmap=target.bitmapImageRepForCachingDisplay(in:target.bounds) {target.cacheDisplay(in:target.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("meeting-list-delete-entry.png"))}
    checks += try await meetingRecycleBinChecks(directory:directory.appendingPathComponent("recycle-bin"))
    return ["type":"meeting_library_checks","passed":checks.count,"checks":checks,"capture":false,"cloud":false,"keychain":false,"fixture_root":base.path]
}
