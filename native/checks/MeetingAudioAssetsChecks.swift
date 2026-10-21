import Foundation
import CryptoKit

func meetingAudioAssetsChecks(directory:URL)throws->[String] {
    let fm=FileManager.default
    guard directory.path.contains("/.runtime/"),directory.standardizedFileURL==directory.resolvingSymlinksInPath().standardizedFileURL else{throw Failure(code:"audio_assets_fixture_scope")}
    try fm.createDirectory(at:directory,withIntermediateDirectories:true)
    let sandbox=directory.appendingPathComponent(UUID().uuidString),cache=sandbox.appendingPathComponent("SessionCache"),exports=sandbox.appendingPathComponent("MeetingExports")
    try fm.createDirectory(at:cache,withIntermediateDirectories:true)
    var checks:[String]=[]
    func check(_ value:@autoclosure ()throws->Bool,_ name:String)throws {guard try value() else{throw Failure(code:name)};checks.append(name)}
    func json(_ value:[String:Any],_ url:URL)throws {try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:url,options:.atomic)}
    func object(_ url:URL)throws->[String:Any] {try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]}
    func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    func fixture(_ tracks:[String]=["mic","remote"])throws->CachedMeeting {
        let id=UUID().uuidString,folder=cache.appendingPathComponent(id);try fm.createDirectory(at:folder,withIntermediateDirectories:true)
        try json(["session":UUID().uuidString,"cache_id":id],folder.appendingPathComponent("meeting.json"))
        try json(["title":"原会议名","schema":1],folder.appendingPathComponent("display-info.json"))
        var written=0
        for (lane,track) in tracks.enumerated() {
            var chunks:[[String:Any]]=[],offset=0
            let sizes:[Int]=lane==0 ? [320000,5000]:[3200]
            for index in sizes.indices {
                let size=sizes[index]
                let data=Data((0..<size).map{UInt8(($0+lane+index)%251)})
                try data.write(to:folder.appendingPathComponent(String(format:"%@-%06d.pcm",track,index)))
                chunks.append(["index":index,"start_sample":offset/2,"bytes":size,"sha256":digest(data)]);offset+=size
            }
            try json(["schema":1,"track":track,"format":"pcm_s16le","sample_rate":16000,"channels":1,"ended":true,"written_bytes":offset,"chunks":chunks,"asr_committed_bytes":0],folder.appendingPathComponent(track+"-manifest.json"));written+=offset
        }
        return CachedMeeting(id:id,directory:folder,date:Date(timeIntervalSince1970:1780000000),writtenBytes:written,pendingBytes:written,occupiedBytes:written,tracks:tracks,audioCleaned:false,warning:false,retiredBytes:0,customTitle:"会议甲")
    }
    func snapshot(_ folder:URL,suffix:String)throws->[String:String] {
        var result:[String:String]=[:]
        for file in try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) where file.lastPathComponent.hasSuffix(suffix) {
            result[file.lastPathComponent]=String((try fm.attributesOfItem(atPath:file.path)[.systemFileNumber] as! NSNumber).uint64Value)+":"+digest(try Data(contentsOf:file))
        };return result
    }
    func expectFailure(_ name:String,code:String?=nil,_ body:()throws->Void)throws {
        do{try body();throw Failure(code:"unexpected_success_"+name)}catch let error as Failure {guard !error.code.hasPrefix("unexpected_success_"),code==nil || error.code==code else{throw error};checks.append(name)}
    }
    let store=MeetingAudioAssetsStore(cacheRoot:cache),item=try fixture(),pcm=try snapshot(item.directory,suffix:".pcm"),titleData=try Data(contentsOf:item.directory.appendingPathComponent("display-info.json"))
    let fallback=try store.info(item).name
    var alternate=item;alternate.customTitle="完全不同的会议标题"
    try check(try store.info(alternate).name==fallback && fallback.hasSuffix(" 录音") && fallback.contains("2026-") && !fallback.contains(item.id),"default_audio_name_uses_readable_local_date_independent_of_meeting_title")
    var localMode=item;localMode.recordingMode="local_only"
    var transcribedMode=item;transcribedMode.recordingMode="record_and_transcribe"
    try check(try store.info(localMode).name.hasPrefix("🎙️ ") && store.info(transcribedMode).name.hasPrefix("📝 "),"new_audio_filenames_distinguish_recording_modes_with_icons")
    try check(!fm.fileExists(atPath:exports.path) && !fm.fileExists(atPath:item.directory.appendingPathComponent("audio-export.json").path),"info_does_not_create_metadata_or_audio_exports")
    _=try store.rename(item,to:"独立录音甲",active:false)
    try check(try store.info(alternate).name=="独立录音甲" && Data(contentsOf:item.directory.appendingPathComponent("display-info.json"))==titleData,"audio_rename_is_independent_of_meeting_title")
    try json(["schema":1,"title":"新会议名"],item.directory.appendingPathComponent("display-info.json"))
    try check(try store.info(item).name=="独立录音甲" && !store.info(item).exported,"meeting_title_write_preserves_audio_name_without_implicit_export")
    for name in ["", "../escape", "a/b", "a\\b", "a:b", ".hidden", "x\ny", "x.", String(repeating:"中",count:81)] {
        try expectFailure("invalid_audio_name_"+String(checks.count),code:"audio_asset_name_invalid"){_=try store.rename(item,to:name,active:false)}
    }
    try expectFailure("active_audio_rename_rejected",code:"audio_asset_active"){_=try store.rename(item,to:"活动",active:true)}
    try expectFailure("active_audio_export_rejected",code:"audio_asset_active"){_=try store.export(item,active:true)}
    let folder=try store.export(item,active:false),info=try store.info(item)
    try check(info.exported && info.urls.count==2 && info.urls.contains{$0.lastPathComponent=="独立录音甲－麦克风.wav"} && info.urls.contains{$0.lastPathComponent=="独立录音甲－电脑声音1.wav"},"explicit_export_creates_readable_per_source_wav_names")
    let receipt=try object(folder.appendingPathComponent("meeting-owner.json"))
    try check(receipt["cache_id"] as? String==item.id && receipt["session"] as? String==item.metadata()["session"] as? String,"exports_owner_receipt_matches_deletion_contract")
    for (track,label) in [("mic","麦克风"),("remote","电脑声音1")] {
        let files=try fm.contentsOfDirectory(at:item.directory,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix(track+"-") && $0.pathExtension=="pcm"}.sorted{$0.lastPathComponent<$1.lastPathComponent}
        var expected=Data();for file in files{expected.append(try Data(contentsOf:file))}
        let wav=try Data(contentsOf:folder.appendingPathComponent("独立录音甲－"+label+".wav"))
        try check(wav.prefix(44)==MeetingAudioAssetsStore.wavHeader(expected.count) && wav.dropFirst(44)==expected,"wav_"+track+"_header_and_payload_preserve_pcm_exactly")
    }
    let originalWAV=try snapshot(folder,suffix:".wav"),originalIDs=Set(originalWAV.values)
    _=try store.export(item,active:false)
    try check(try snapshot(folder,suffix:".wav")==originalWAV,"repeat_export_reuses_existing_wav_inodes_and_bytes")
    _=try store.rename(item,to:"ALPHA",active:false);_=try store.rename(item,to:"alpha",active:false)
    try check(try Set(snapshot(folder,suffix:".wav").values)==originalIDs,"existing_wav_case_only_rename_moves_without_copy_or_reencode")
    let renamed=try snapshot(folder,suffix:".wav"),namedMetadata=try Data(contentsOf:item.directory.appendingPathComponent("audio-export.json"))
    _=try store.rename(item,to:"alpha",active:false)
    try check(try snapshot(folder,suffix:".wav")==renamed && Data(contentsOf:item.directory.appendingPathComponent("audio-export.json"))==namedMetadata,"repeat_rename_is_idempotent")
    let collision=folder.appendingPathComponent("BETA－麦克风.wav");try Data("external collision".utf8).write(to:collision)
    try expectFailure("case_insensitive_collision_rejected",code:"audio_asset_collision"){_=try store.rename(item,to:"beta",active:false)}
    try check(try Data(contentsOf:collision)==Data("external collision".utf8) && Data(contentsOf:item.directory.appendingPathComponent("audio-export.json"))==namedMetadata,"collision_preserves_unrelated_file_and_previous_metadata")
    try fm.removeItem(at:collision)
    let unicodeCollision=folder.appendingPathComponent("Cafe\u{301}－麦克风.wav");try Data("unicode collision".utf8).write(to:unicodeCollision)
    try expectFailure("unicode_canonical_case_collision_rejected",code:"audio_asset_collision"){_=try store.rename(item,to:"CAFÉ",active:false)}
    try fm.removeItem(at:unicodeCollision)
    for step in ["staged","rename_1","metadata","publish","published"] {
        store.beforeStep={if $0==step {throw Failure(code:"fixture_injected")}}
        try expectFailure("rename_rollback_"+step,code:"fixture_injected"){_=try store.rename(item,to:"失败名称",active:false)}
        try check(try snapshot(folder,suffix:".wav")==renamed && Data(contentsOf:item.directory.appendingPathComponent("audio-export.json"))==namedMetadata,"rename_rollback_preserves_inodes_and_metadata_"+step)
    };store.beforeStep=nil
    for step in ["staged","export_1","metadata","publish","published"] {
        let failed=try fixture(),failedPCM=try snapshot(failed.directory,suffix:".pcm")
        store.beforeStep={if $0==step {throw Failure(code:"fixture_injected")}}
        try expectFailure("first_export_rollback_"+step,code:"fixture_injected"){_=try store.export(failed,active:false)}
        try check(!fm.fileExists(atPath:exports.appendingPathComponent(failed.id).path) && !fm.fileExists(atPath:failed.directory.appendingPathComponent("audio-export.json").path) && (try snapshot(failed.directory,suffix:".pcm"))==failedPCM,"first_export_failure_leaves_no_orphan_owner_or_changed_pcm_"+step)
    };store.beforeStep=nil
    let unfinished=try fixture();let manifest=unfinished.directory.appendingPathComponent("mic-manifest.json");var unsealed=try object(manifest);unsealed["ended"]=false;try json(unsealed,manifest)
    try expectFailure("unfinished_source_export_rejected",code:"audio_asset_unsealed"){_=try store.export(unfinished,active:false)}
    try expectFailure("unfinished_source_rename_rejected",code:"audio_asset_unsealed"){_=try store.rename(unfinished,to:"未封存",active:false)}
    unsealed["ended"]=true;var chunks=unsealed["chunks"] as! [[String:Any]];chunks[0].removeValue(forKey:"sha256");unsealed["chunks"]=chunks;try json(unsealed,manifest)
    try expectFailure("missing_chunk_seal_rejected",code:"audio_asset_unsealed"){_=try store.export(unfinished,active:false)}
    let corrupted=try fixture();try Data(repeating:3,count:320000).write(to:corrupted.directory.appendingPathComponent("mic-000000.pcm"))
    try expectFailure("source_digest_mismatch_rejected",code:"audio_asset_hash_mismatch"){_=try store.export(corrupted,active:false)}
    try check(!fm.fileExists(atPath:exports.appendingPathComponent(corrupted.id).path),"corrupt_source_leaves_no_published_assets")
    let rawItem=try fixture(["mic"]),rawPCM=Data(repeating:9,count:6400)
    try rawPCM.write(to:rawItem.directory.appendingPathComponent("mic-raw-000000.pcm"))
    try json(["schema":1,"track":"mic-raw","format":"pcm_s16le","sample_rate":16000,"channels":1,"ended":true,"written_bytes":rawPCM.count,"chunks":[["index":0,"start_sample":0,"bytes":rawPCM.count,"sha256":digest(rawPCM)]]],rawItem.directory.appendingPathComponent("mic-raw-manifest.json"))
    let rawFolder=try store.export(rawItem,active:false),rawInfo=try store.info(rawItem)
    try check(rawInfo.urls.count==1 && Data(contentsOf:rawInfo.urls[0]).dropFirst(44)==rawPCM,"wav_export_prefers_original_mic_raw_without_echo_processing_or_reencoding")
    let rawBefore=try snapshot(rawFolder,suffix:".wav");_=try store.export(rawItem,active:false)
    try check(try snapshot(rawFolder,suffix:".wav")==rawBefore,"original_mic_wav_repeat_preserves_inode_and_bytes")
    let linked=try fixture(),linkedPCM=linked.directory.appendingPathComponent("mic-000000.pcm"),external=sandbox.appendingPathComponent("outside.pcm")
    try fm.moveItem(at:linkedPCM,to:external);try fm.createSymbolicLink(at:linkedPCM,withDestinationURL:external)
    try expectFailure("source_symlink_escape_rejected",code:"audio_asset_path_invalid"){_=try store.export(linked,active:false)}
    let wrongOwner=try fixture(),wrongFolder=exports.appendingPathComponent(wrongOwner.id);try fm.createDirectory(at:wrongFolder,withIntermediateDirectories:true);try json(["cache_id":wrongOwner.id,"session":"another-session"],wrongFolder.appendingPathComponent("meeting-owner.json"))
    try expectFailure("cross_session_export_owner_rejected",code:"audio_asset_owner"){_=try store.export(wrongOwner,active:false)}
    let outside=CachedMeeting(id:item.id,directory:sandbox,date:item.date,writtenBytes:0,pendingBytes:0,occupiedBytes:0,tracks:[],audioCleaned:false,warning:false,retiredBytes:0)
    try expectFailure("cache_directory_escape_rejected",code:"audio_asset_scope"){_=try store.info(outside)}
    let nested=MeetingAudioAssetsStore(cacheRoot:cache,exportsRoot:item.directory)
    try expectFailure("nested_export_root_rejected",code:"audio_asset_scope"){_=try nested.info(item)}
    // Simulate process termination during a multi-file rename, not a catch path.
    let stageName=".audio-txn-"+UUID().uuidString,stage=exports.appendingPathComponent(stageName),oldObject=try object(item.directory.appendingPathComponent("audio-export.json"))
    var newObject=oldObject;newObject["name"]="中断的新名";var newAssets=oldObject["assets"] as! [[String:Any]]
    for i in newAssets.indices {newAssets[i]["file"]="中断的新名－"+(newAssets[i]["label"] as! String)+".wav"};newObject["assets"]=newAssets
    try json(["schema":1,"cacheID":item.id,"session":try item.metadata()["session"]!,"stage":stageName,"kind":"rename","hadFolder":true,"oldData":namedMetadata.base64EncodedString(),"old":oldObject,"new":newObject],item.directory.appendingPathComponent(".audio-export-transaction.json"))
    try fm.moveItem(at:folder,to:stage)
    let firstOld=(oldObject["assets"] as! [[String:Any]])[0]["file"] as! String
    try fm.moveItem(at:stage.appendingPathComponent(firstOld),to:stage.appendingPathComponent(".audio-rename-0"))
    try check(try store.info(item).needsRecovery && !store.info(item).exported && fm.fileExists(atPath:stage.path),"pending_transaction_info_is_read_only_and_exposes_recovery")
    _=try store.rename(item,to:"alpha",active:false)
    try check(try snapshot(folder,suffix:".wav")==renamed && !fm.fileExists(atPath:stage.path) && !store.info(item).needsRecovery,"next_explicit_operation_recovers_interrupted_rename_without_inode_change")
    try check(try snapshot(item.directory,suffix:".pcm")==pcm,"all_export_and_rename_paths_preserve_original_pcm_hashes_and_inodes")
    let userExport=sandbox.appendingPathComponent("本人另存.wav");try Data("independent user asset".utf8).write(to:userExport)
    _=try store.rename(item,to:"录音最终名称",active:false)
    try check(try Data(contentsOf:userExport)==Data("independent user asset".utf8),"user_saved_audio_filename_and_bytes_are_not_renamed")
    // Archived source audio is not implicitly restored; existing WAV stays usable.
    let retired=try fixture();try json(["state":"trashed"],retired.directory.appendingPathComponent("audio-retirement.json"))
    try expectFailure("new_export_of_retired_source_requires_explicit_restore",code:"audio_asset_retired"){_=try store.export(retired,active:false)}
    let retained=try fixture();let retainedFolder=try store.export(retained,active:false),retainedIDs=try snapshot(retainedFolder,suffix:".wav")
    for pcmFile in try fm.contentsOfDirectory(at:retained.directory,includingPropertiesForKeys:nil) where pcmFile.pathExtension=="pcm" {try fm.moveItem(at:pcmFile,to:sandbox.appendingPathComponent(retained.id+pcmFile.lastPathComponent))}
    try json(["state":"trashed"],retained.directory.appendingPathComponent("audio-retirement.json"))
    let reusedFolder=try store.export(retained,active:false),reusedIDs=try snapshot(retainedFolder,suffix:".wav")
    try check(reusedFolder==retainedFolder && reusedIDs==retainedIDs,"existing_wav_reused_after_pcm_retirement_without_source_read")
    _=try store.rename(retained,to:"退役原音的录音",active:false)
    try check(try Set(snapshot(retainedFolder,suffix:".wav").values)==Set(retainedIDs.values),"existing_wav_rename_does_not_require_pcm_to_be_present")
    let deletion=MeetingDeletionStore(cacheRoot:cache,binRoot:sandbox.appendingPathComponent("DeletedMeetings"),exportsRoot:exports),beforeDelete=try snapshot(folder,suffix:".wav")
    let deletionOld=try object(item.directory.appendingPathComponent("audio-export.json")),deletionBytes=try Data(contentsOf:item.directory.appendingPathComponent("audio-export.json"))
    let deletionStageName=".audio-txn-"+UUID().uuidString,deletionStage=exports.appendingPathComponent(deletionStageName)
    try json(["schema":1,"cacheID":item.id,"session":try item.metadata()["session"]!,"stage":deletionStageName,"kind":"rename","hadFolder":true,"oldData":deletionBytes.base64EncodedString(),"old":deletionOld,"new":deletionOld],item.directory.appendingPathComponent(".audio-export-transaction.json"))
    try fm.moveItem(at:folder,to:deletionStage)
    try store.recoverPending(item);try store.recoverPending(item)
    try check(try snapshot(folder,suffix:".wav")==beforeDelete && !fm.fileExists(atPath:deletionStage.path),"deletion_preflight_recovers_staged_assets_idempotently")
    let deletionReceipt=try deletion.trash(item)
    try check(!fm.fileExists(atPath:folder.path) && !fm.fileExists(atPath:item.directory.path),"meeting_delete_moves_recording_metadata_and_owned_wav_assets_together")
    try deletion.restore(deletionReceipt)
    try check(try snapshot(folder,suffix:".wav")==beforeDelete && store.info(item).name=="录音最终名称","meeting_restore_preserves_recording_name_and_wav_inodes")
    return checks
}
