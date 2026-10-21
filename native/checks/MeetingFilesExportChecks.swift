import Foundation
import CryptoKit

func meetingFilesExportChecks(directory:URL)throws->[String] {
    let fm=FileManager.default
    guard directory.path.contains("/.runtime/"),directory.standardizedFileURL==directory.resolvingSymlinksInPath().standardizedFileURL else{throw Failure(code:"meeting_files_fixture_scope")}
    try fm.createDirectory(at:directory,withIntermediateDirectories:true)
    let sandbox=directory.appendingPathComponent(UUID().uuidString),cache=sandbox.appendingPathComponent("SessionCache"),exports=sandbox.appendingPathComponent("MeetingExports")
    try fm.createDirectory(at:cache,withIntermediateDirectories:true)
    var checks:[String]=[]
    func check(_ value:@autoclosure ()throws->Bool,_ name:String)throws {guard try value() else{throw Failure(code:name)};checks.append(name)}
    func json(_ value:[String:Any],_ url:URL)throws {try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:url,options:.atomic)}
    func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    func fixture(title:String="项目讨论",transcript:Bool=true,committed:Bool=true,final:Bool=true,audioEnded:Bool=true)throws->CachedMeeting {
        let id=UUID().uuidString,session=UUID().uuidString,folder=cache.appendingPathComponent(id)
        try fm.createDirectory(at:folder,withIntermediateDirectories:true)
        try json(["schema":1,"cache_id":id,"session":session,"bundle":"*system*","capture_mode":"local_only","capture_origin_uptime":100.0],folder.appendingPathComponent("meeting.json"))
        try json(["schema":1,"title":title,"cache_id":id,"session":session],folder.appendingPathComponent("display-info.json"))
        let pcm=Data((0..<3200).map{UInt8($0%251)});try pcm.write(to:folder.appendingPathComponent("mic-000000.pcm"))
        let hash=digest(pcm)
        try json(["schema":1,"track":"mic","format":"pcm_s16le","sample_rate":16000,"channels":1,"ended":audioEnded,"written_bytes":pcm.count,"origin_uptime":105.0,"asr_committed_bytes":committed ? pcm.count:0,"chunks":[["index":0,"start_sample":0,"bytes":pcm.count,"sha256":hash]]],folder.appendingPathComponent("mic-manifest.json"))
        if transcript {
            let segmentID="sentence-1:turn:100"
            let event:[String:Any]=["type":"segment","session":session,"segment_id":segmentID,"parent_segment_id":"sentence-1","track":"mic","source_id":"mic","epoch":"synthetic","start":0.1,"end":0.2,"end_time_known":true,"text":"讨论继续推进。","revision":1,"final":final,"speaker":["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":"synthetic"]]
            var data=try JSONSerialization.data(withJSONObject:event,options:[.sortedKeys]);data.append(10);try data.write(to:folder.appendingPathComponent("mic-transcript.jsonl"))
            var names=SessionNames();names.register(segment:segmentID,item:event);names.setSpeaker(segment:segmentID,name:"人工姓名")
            try names.snapshot(session:session).write(to:folder.appendingPathComponent("session-names.json"),options:.atomic)
        }
        return try cachedMeetings(in:cache).first(where:{$0.id==id})!
    }
    func addRawMicrophone(_ item:CachedMeeting,origin:Double,seed:UInt8)throws {
        let pcm=Data((0..<3200).map{UInt8(($0+Int(seed))%251)}),hash=digest(pcm)
        try pcm.write(to:item.directory.appendingPathComponent("mic-raw-000000.pcm"))
        try json(["schema":1,"track":"mic-raw","format":"pcm_s16le","sample_rate":16000,"channels":1,"ended":true,"written_bytes":pcm.count,"origin_uptime":origin,"chunks":[["index":0,"start_sample":0,"bytes":pcm.count,"sha256":hash]]],item.directory.appendingPathComponent("mic-raw-manifest.json"))
    }
    let audioStore=MeetingAudioAssetsStore(cacheRoot:cache,exportsRoot:exports),builder=MeetingFilesExportStore(cacheRoot:cache,exportsRoot:exports)
    let complete=try fixture(),completeLibrary=try MeetingLibraryFiles.read(complete,root:cache),savedElsewhere=sandbox.appendingPathComponent("用户另存的 WAV.wav")
    try Data("user-owned-export".utf8).write(to:savedElsewhere);let savedHash=digest(try Data(contentsOf:savedElsewhere))
    let first=try builder.build(complete,library:completeLibrary,audioStore:audioStore)
    let wavs=try fm.contentsOfDirectory(at:first.folder,includingPropertiesForKeys:nil).filter{$0.pathExtension.lowercased()=="wav"}
    let readable=try fm.contentsOfDirectory(at:first.folder,includingPropertiesForKeys:[.isHiddenKey]).filter{try $0.resourceValues(forKeys:[.isHiddenKey]).isHidden != true}.map(\.lastPathComponent)
    let text=try String(contentsOf:first.folder.appendingPathComponent("项目讨论－转写原文.txt"),encoding:.utf8)
    let guideText=try String(contentsOf:first.folder.appendingPathComponent("会议说明.txt"),encoding:.utf8)
    try check(first.transcriptState=="转写完整" && first.audioCount==1 && wavs.first?.lastPathComponent.hasSuffix("－麦克风.wav")==true && first.folder==audioStore.exportsRoot.appendingPathComponent(complete.id),"complete_meeting_reuses_transaction_owned_labeled_wav_folder")
    try check(guideText.contains("来自麦克风") && guideText.contains("起于 00:00:05") && guideText.contains("完整 WAV"),"guide_maps_each_wav_to_verified_source_start_and_duration")
    let oldExport=try fixture(title:"旧麦克风导出");_=try audioStore.export(oldExport,active:false);try addRawMicrophone(oldExport,origin:112,seed:9)
    let oldPackage=try builder.build(oldExport,library:try MeetingLibraryFiles.read(oldExport,root:cache),audioStore:audioStore)
    let oldGuide=try String(contentsOf:oldPackage.folder.appendingPathComponent("会议说明.txt"),encoding:.utf8)
    try check(oldGuide.contains("起于 00:00:05"),"existing_logical_mic_export_keeps_its_original_manifest_start")
    let rawExport=try fixture(title:"原始麦克风导出");try addRawMicrophone(rawExport,origin:112,seed:17)
    let rawPackage=try builder.build(rawExport,library:try MeetingLibraryFiles.read(rawExport,root:cache),audioStore:audioStore)
    let rawGuide=try String(contentsOf:rawPackage.folder.appendingPathComponent("会议说明.txt"),encoding:.utf8)
    try check(rawGuide.contains("起于 00:00:12"),"new_original_mic_wav_uses_raw_manifest_start")
    try check(text.contains("人工姓名") && text.contains("讨论继续推进。") && readable.contains("会议说明.txt") && readable.allSatisfy{!$0.hasSuffix(".json") && !$0.hasSuffix(".pcm") && !$0.hasSuffix(".jsonl")},"human_files_use_current_transcript_projection_and_hide_internal_files")
    var renamed=complete;renamed.customTitle="改名后的讨论"
    let second=try builder.build(renamed,library:try MeetingLibraryFiles.read(renamed,root:cache),audioStore:audioStore)
    try check(second.folder==first.folder && fm.fileExists(atPath:second.folder.appendingPathComponent("改名后的讨论－转写原文.txt").path) && !fm.fileExists(atPath:second.folder.appendingPathComponent("项目讨论－转写原文.txt").path),"rename_updates_generated_transcript_within_same_meeting_folder")
    try check(digest(try Data(contentsOf:savedElsewhere))==savedHash && second.audioCount==1 && wavs.first.map{(try? Data(contentsOf:second.folder.appendingPathComponent($0.lastPathComponent))) != nil}==true,"renaming_preserves_separately_saved_user_file_and_reuses_wav_assets")
    let editedGuide=second.folder.appendingPathComponent("会议说明.txt");try Data("用户手动补充的说明".utf8).write(to:editedGuide)
    do{_=try builder.build(renamed,library:try MeetingLibraryFiles.read(renamed,root:cache),audioStore:audioStore);throw Failure(code:"meeting_files_user_edit_overwritten")}catch let error as Failure {guard error.code=="meeting_files_user_file_collision" else{throw error}}
    try check(try String(contentsOf:editedGuide,encoding:.utf8)=="用户手动补充的说明","user_edited_generated_file_is_never_overwritten")
    let partial=try fixture(title:"部分转写",committed:false),partialPackage=try builder.build(partial,library:try MeetingLibraryFiles.read(partial,root:cache),audioStore:audioStore)
    let partialText=try String(contentsOf:partialPackage.folder.appendingPathComponent("部分转写－转写原文.txt"),encoding:.utf8)
    try check(partialPackage.transcriptState=="部分转写，仍有内容待核对或录音待处理" && partialText.contains("转写未完成"),"partial_transcription_is_never_labeled_complete")
    let empty=try fixture(title:"尚未转写",transcript:false,committed:false),emptyPackage=try builder.build(empty,library:try MeetingLibraryFiles.read(empty,root:cache),audioStore:audioStore)
    try check(emptyPackage.transcriptState=="尚未转写" && emptyPackage.audioCount==1,"untranscribed_meeting_still_has_recording_and_explicit_status")
    let interrupted=try fixture(title:"中断录音",committed:true,audioEnded:false),interruptedPackage=try builder.build(interrupted,library:try MeetingLibraryFiles.read(interrupted,root:cache),audioStore:audioStore)
    let interruptedGuide=try String(contentsOf:interruptedPackage.folder.appendingPathComponent("会议说明.txt"),encoding:.utf8)
    let interruptedWavs=try fm.contentsOfDirectory(at:interruptedPackage.folder,includingPropertiesForKeys:nil).filter{$0.pathExtension.lowercased()=="wav"}
    try check(interruptedPackage.audioCount==0 && interruptedWavs.isEmpty && interruptedGuide.contains("录音未完整保存") && interruptedGuide.contains("没有可播放的 WAV 录音") && !interruptedGuide.contains("完整 WAV"),"unsealed_audio_is_not_exported_or_described_as_complete")
    let retired=try fixture(title:"录音已退役"),retiredLibrary=try MeetingLibraryFiles.read(retired,root:cache)
    let retiredFolder=cache.appendingPathComponent(".retired",isDirectory:true).appendingPathComponent(retired.id,isDirectory:true)
    try fm.createDirectory(at:retiredFolder,withIntermediateDirectories:true)
    for name in ["mic-000000.pcm","mic-manifest.json"] {try fm.moveItem(at:retired.directory.appendingPathComponent(name),to:retiredFolder.appendingPathComponent(name))}
    try json(["schema":1,"cache_id":retired.id,"state":"trashed","recoverable":true,"destination":retiredFolder.path],retired.directory.appendingPathComponent("audio-retirement.json"))
    let retiredPackage=try builder.build(retired,library:retiredLibrary,audioStore:audioStore)
    let guide=try String(contentsOf:retiredPackage.folder.appendingPathComponent("会议说明.txt"),encoding:.utf8)
    try check(retiredPackage.audioCount==0 && guide.contains("原始录音已移入回收区") && !fm.fileExists(atPath:retired.directory.appendingPathComponent("mic-000000.pcm").path) && retiredPackage.folder==audioStore.exportsRoot.appendingPathComponent(retired.id),"retired_audio_keeps_session_owned_readable_files_without_moving_or_faking_original")
    let deletion=MeetingDeletionStore(cacheRoot:cache,binRoot:sandbox.appendingPathComponent("RecycleBin"),exportsRoot:exports)
    let beforeDelete=try fm.contentsOfDirectory(at:second.folder,includingPropertiesForKeys:nil).filter{$0.pathExtension=="txt" || $0.pathExtension=="wav"}.reduce(into:[String:String]()) {result,file in result[file.lastPathComponent]=(try? Data(contentsOf:file)).map(digest)}
    let receipt=try deletion.trash(complete)
    try check(!fm.fileExists(atPath:second.folder.path),"meeting_file_bundle_follows_session_into_recycle_bin")
    try deletion.restore(receipt)
    let afterRestore=try fm.contentsOfDirectory(at:second.folder,includingPropertiesForKeys:nil).filter{$0.pathExtension=="txt" || $0.pathExtension=="wav"}.reduce(into:[String:String]()) {result,file in result[file.lastPathComponent]=(try? Data(contentsOf:file)).map(digest)}
    try check(beforeDelete==afterRestore && fm.fileExists(atPath:second.folder.appendingPathComponent("meeting-owner.json").path),"restored_meeting_recovers_readable_files_under_same_session_id")
    return checks
}
