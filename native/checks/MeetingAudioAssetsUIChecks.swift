import AppKit
import CryptoKit

@MainActor func meetingAudioAssetsUIChecks(directory:URL) async throws->[String] {
    guard Credential.offline,directory.path.contains("/.runtime/") else{throw Failure(code:"audio_ui_fixture_scope")}
    _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    let fm=FileManager.default,base=directory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at:base,withIntermediateDirectories:true)
    var checks:[String]=[]
    func check(_ condition:Bool,_ name:String)throws {guard condition else{throw Failure(code:name)};checks.append(name);print("audio-ui-check: "+name)}
    func wait(_ condition:()->Bool) async throws {let limit=Date().addingTimeInterval(10);while !condition(),Date()<limit {try await Task.sleep(nanoseconds:10_000_000)};guard condition() else{throw Failure(code:"audio_ui_timeout")}}
    func json(_ value:[String:Any],_ file:URL)throws {try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:file)}
    func fixture(_ title:String)throws->CachedMeeting {
        let folder=base.appendingPathComponent(UUID().uuidString),session=UUID().uuidString
        let journal=try RecordingJournal(directory:folder,track:"mic",freeSpace:{1_000_000_000});try journal.enqueue(Data(repeating:0x37,count:3200),at:0);journal.finish();journal.wait()
        try json(["session":session,"cache_id":folder.lastPathComponent,"bundle":"*microphone*","capture_mode":"local_only","upload_authorized":false],folder.appendingPathComponent("meeting.json"));try MeetingLibraryInfo.saveTitle(title,in:folder)
        return try cachedMeetings(in:base).first{$0.id==folder.lastPathComponent}!
    }
    let first=try fixture("会议标题甲"),second=try fixture("会议标题乙"),store=MeetingAudioAssetsStore(cacheRoot:base)
    let app=Delegate();app.previewRenderOnly=true;app.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));app.recoveryRootOverride=base
    app.reloadLibrary();try await wait{!app.libraryJob.busy}
    let management=app.libraryManagementController;management.audioStoreOverride=store
    func select(_ item:CachedMeeting) async throws {
        app.libraryVisible=[first,second];app.librarySelectionChanging=true;app.libraryTable.reloadData();app.libraryTable.selectRowIndexes(IndexSet(integer:item.id==first.id ? 0:1),byExtendingSelection:false);app.librarySelectionChanging=false
        management.refresh(force:true);try await wait{management.loadedID==item.id && !management.readJob.busy}
    }
    try await select(first)
    try check(management.title(.rename)=="重命名会议" && management.title(.renameAudio)=="重命名录音","meeting_and_audio_names_are_distinct_actions")
    try check(management.enabled(.renameAudio) && management.enabled(.exportAudio),"sealed_local_recording_can_rename_and_export")
    let display=first.directory.appendingPathComponent("display-info.json"),displayBefore=try Data(contentsOf:display),pcm=first.directory.appendingPathComponent("mic-000000.pcm"),pcmBefore=try Data(contentsOf:pcm)
    management.audioRenameOverride={_,_ in nil};management.requestAudioRename(first)
    try check(!fm.fileExists(atPath:first.directory.appendingPathComponent("audio-export.json").path),"cancel_audio_rename_does_not_write_metadata")
    var renameDone=false,renameSucceeded=false
    management.renameAudio(first,to:"独立录音甲"){result in renameDone=true;if case .success=result{renameSucceeded=true}}
    try await wait{renameDone && !management.readJob.busy}
    try check(renameSucceeded && (try store.info(first)).name=="独立录音甲" && (try Data(contentsOf:display))==displayBefore,"audio_rename_preserves_meeting_title")
    var titleDone=false;management.rename(first,to:"会议新标题"){_ in titleDone=true};try await wait{titleDone && !management.readJob.busy}
    try check(try store.info(first).name=="独立录音甲","meeting_rename_preserves_audio_name")
    renameDone=false;renameSucceeded=false;management.renameAudio(first,to:"非法/名称"){result in renameDone=true;if case .success=result{renameSucceeded=true}};try await wait{renameDone && !management.readJob.busy}
    try check(!renameSucceeded && (try store.info(first)).name=="独立录音甲" && !management.audioAssetOperationInFlight,"invalid_audio_name_preserves_old_name_and_releases_busy")
    var opened:URL?,exportDone=false,exportSucceeded=false
    management.revealOverride={opened=$0;return true};management.exportAudio(first){result in exportDone=true;if case .success=result{exportSucceeded=true}};try await wait{exportDone && !management.readJob.busy}
    let info=try store.info(first)
    try check(exportSucceeded && opened==info.folder && info.urls.count==1 && info.urls[0].lastPathComponent.contains("独立录音甲"),"explicit_audio_export_opens_only_own_named_wav_folder")
    let wav=info.urls[0],wavBefore=try Data(contentsOf:wav),inode=(try fm.attributesOfItem(atPath:wav.path))[.systemFileNumber] as? NSNumber
    let displayAfter=try Data(contentsOf:display)
    store.beforeStep={if $0=="metadata"{throw Failure(code:"injected_audio_ui_failure")}}
    renameDone=false;renameSucceeded=false;management.renameAudio(first,to:"失败的新名称"){result in renameDone=true;if case .success=result{renameSucceeded=true}};try await wait{renameDone && !management.readJob.busy};store.beforeStep=nil
    try check(!renameSucceeded && (try store.info(first)).name=="独立录音甲" && (try Data(contentsOf:wav))==wavBefore && (try Data(contentsOf:display))==displayAfter,"failed_audio_rename_rolls_back_wav_and_leaves_meeting_title")
    renameDone=false;management.renameAudio(first,to:"最终录音名"){_ in renameDone=true};try await wait{renameDone && !management.readJob.busy}
    let renamed=try store.info(first).urls[0]
    try check((try Data(contentsOf:renamed))==wavBefore && ((try fm.attributesOfItem(atPath:renamed.path))[.systemFileNumber] as? NSNumber)==inode && (try Data(contentsOf:pcm))==pcmBefore,"successful_audio_rename_moves_same_wav_without_reencoding_pcm")
    // Hold a real write in its worker while selection changes and start is tried.
    let arrived=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
    store.beforeStep={if $0=="metadata" {arrived.signal();guard release.wait(timeout:.now()+8) == .success else{throw Failure(code:"audio_ui_hold_timeout")}}}
    renameDone=false;management.renameAudio(first,to:"原目标录音"){_ in renameDone=true}
    var arrivedSeen=false;try await wait{if !arrivedSeen {arrivedSeen=arrived.wait(timeout:.now()) == .success};return arrivedSeen}
    try check(app.audioAssetOperationBusy,"audio_write_exposes_owner_busy_state")
    app.toggle();try check(app.child==nil && app.phase.phase == .idle,"idle_start_cannot_race_audio_asset_write")
    app.librarySelectionChanging=true;app.libraryTable.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false);app.librarySelectionChanging=false;management.refresh();release.signal();try await wait{renameDone && !management.readJob.busy};store.beforeStep=nil
    try check((try store.info(first)).name=="原目标录音" && (try store.info(second)).name != "原目标录音" && app.selectedLibraryManagementItem?.id==second.id,"selection_change_during_write_preserves_frozen_target_and_new_selection")
    // A retired original cannot be newly exported; a previously exported WAV remains accessible.
    try await select(second)
    let secondInfo=try store.info(second)
    management.files=MeetingLibraryFiles(session:try second.metadata()["session"] as! String,localOnly:true,audioFolder:base.appendingPathComponent(".retired").appendingPathComponent(second.id),transcriptFolder:nil,audioAssets:secondInfo)
    try check(!management.enabled(.exportAudio) && management.disabledReason(.exportAudio).contains("恢复原音"),"retired_original_requires_restore_before_first_export")
    try await select(first)
    management.files=MeetingLibraryFiles(session:try first.metadata()["session"] as! String,localOnly:true,audioFolder:nil,transcriptFolder:nil,audioAssets:try store.info(first))
    try check(management.enabled(.exportAudio),"existing_export_remains_openable_without_original_pcm")
    app.window?.close()
    return checks
}
