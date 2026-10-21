import Foundation
import CryptoKit
import AVFoundation

func speakerAudioPreviewChecks(directory:URL)throws->[String] {
    let fm=FileManager.default
    guard directory.path.contains("/.runtime/"),directory.standardizedFileURL==directory.resolvingSymlinksInPath().standardizedFileURL else{throw Failure(code:"preview_fixture_scope")}
    let root=directory.appendingPathComponent(UUID().uuidString),id=UUID().uuidString,session=UUID().uuidString,folder=root.appendingPathComponent(id)
    try fm.createDirectory(at:folder,withIntermediateDirectories:true)
    func json(_ object:[String:Any],_ file:URL)throws {try JSONSerialization.data(withJSONObject:object,options:.sortedKeys).write(to:file,options:.atomic)}
    try json(["session":session,"cache_id":id,"capture_origin_uptime":100.0],folder.appendingPathComponent("meeting.json"))
    var pcm=Data(),chunks:[[String:Any]]=[]
    for i in 0..<4 {
        let data=Data((0..<320000).map{UInt8(($0+i)%251)});try data.write(to:folder.appendingPathComponent(String(format:"mic-%06d.pcm",i)))
        chunks.append(["index":i,"start_sample":i*160000,"bytes":data.count,"sha256":SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()]);pcm.append(data)
    }
    let manifest:[String:Any]=["schema":1,"track":"mic","format":"pcm_s16le","sample_rate":16000,"channels":1,"origin_uptime":101.0,"ended":true,"written_bytes":pcm.count,"chunks":chunks]
    try json(manifest,folder.appendingPathComponent("mic-manifest.json"))
    func row(_ start:Double,_ end:Double,source:String="mic",known:Bool=true)->[String:Any] {["session":session,"source_id":source,"start":start,"end":end,"end_time_known":known]}
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:name)};checks.append(name)}
    func reject(_ name:String,_ body:()throws->Void)throws {do{try body();throw Failure(code:"unexpected_"+name)}catch let e as Failure {guard !e.code.hasPrefix("unexpected_") else{throw e};checks.append(name)}}
    let before=try fm.contentsOfDirectory(atPath:folder.path)
    let clip=try SpeakerAudioPreview.read(root:root,cacheID:id,session:session,items:[row(10.5,11.5)])
    try check(clip.wav.dropFirst(44)==pcm[304000..<336000] && clip.duration==1 && !clip.truncated,"preview_clock_offset_and_cross_chunk_range_exact")
    let player=try AVAudioPlayer(data:clip.wav);player.volume=0
    try check(player.prepareToPlay() && player.play(),"preview_wav_decodes_and_plays_with_native_player_silent_synthetic")
    player.stop()
    var quietPCM=Data();for _ in 0..<1600 {var value=Int16(100).littleEndian;withUnsafeBytes(of:&value){quietPCM.append(contentsOf:$0)}}
    let quietWAV=MeetingAudioAssetsStore.wavHeader(quietPCM.count)+quietPCM,raised=SpeakerAudioPreview.listeningData(quietWAV)
    try check(raised.count==quietWAV.count && raised.prefix(44)==quietWAV.prefix(44) && raised[44]==64 && raised[45]==6 && quietWAV[44]==100,"preview_low_voice_gain_bounded_to_16_and_original_unchanged")
    let long=try SpeakerAudioPreview.read(root:root,cacheID:id,session:session,items:[row(1,40)])
    try check(long.wav.count==44+960000 && long.duration==30 && long.truncated,"preview_long_utterance_bounded_to_30_seconds")
    try reject("preview_wrong_session_rejected"){_=try SpeakerAudioPreview.read(root:root,cacheID:id,session:"foreign",items:[row(2,3)])}
    try reject("preview_unknown_end_rejected"){_=try SpeakerAudioPreview.read(root:root,cacheID:id,session:session,items:[row(2,3,known:false)])}
    try reject("preview_cross_source_selection_rejected"){_=try SpeakerAudioPreview.read(root:root,cacheID:id,session:session,items:[row(2,3),row(2,3,source:"remote")])}
    try reject("preview_negative_source_clock_range_rejected"){_=try SpeakerAudioPreview.read(root:root,cacheID:id,session:session,items:[row(0,0.5)])}
    var unsealed=manifest;unsealed["ended"]=false;try json(unsealed,folder.appendingPathComponent("mic-manifest.json"))
    try reject("preview_unsealed_recording_rejected"){_=try SpeakerAudioPreview.read(root:root,cacheID:id,session:session,items:[row(2,3)])}
    try json(manifest,folder.appendingPathComponent("mic-manifest.json"))
    // Mic previews select the original retained lane rather than an enhanced
    // or possibly empty ASR lane, preserving timing and recorded bytes.
    let raw=Data(repeating:17,count:320000);try raw.write(to:folder.appendingPathComponent("mic-raw-000000.pcm"))
    var rawManifest=manifest;rawManifest["track"]="mic-raw";rawManifest["written_bytes"]=raw.count
    rawManifest["chunks"]=[["index":0,"start_sample":0,"bytes":raw.count,"sha256":SHA256.hash(data:raw).map{String(format:"%02x",$0)}.joined()]]
    try json(rawManifest,folder.appendingPathComponent("mic-raw-manifest.json"))
    let original=try SpeakerAudioPreview.read(root:root,cacheID:id,session:session,items:[row(2,3)])
    try check(original.wav.dropFirst(44)==raw[32000..<64000],"preview_uses_original_mic_when_retained")
    try fm.removeItem(at:folder.appendingPathComponent("mic-raw-manifest.json"));try fm.removeItem(at:folder.appendingPathComponent("mic-raw-000000.pcm"))
    try check(try fm.contentsOfDirectory(atPath:folder.path)==before,"preview_creates_no_files_and_preserves_source")
    let corrupted=folder.appendingPathComponent("mic-000001.pcm");try Data(repeating:0,count:320000).write(to:corrupted)
    try reject("preview_corrupt_chunk_rejected"){_=try SpeakerAudioPreview.read(root:root,cacheID:id,session:session,items:[row(10.5,11.5)])}
    try pcm[320000..<640000].write(to:corrupted)
    let retired=root.appendingPathComponent(".retired").appendingPathComponent(id)
    try fm.createDirectory(at:retired,withIntermediateDirectories:true)
    for i in 0..<4 {let name=String(format:"mic-%06d.pcm",i);try fm.moveItem(at:folder.appendingPathComponent(name),to:retired.appendingPathComponent(name))}
    try json(["schema":1,"cache_id":id,"state":"trashed","recoverable":true,"destination":retired.path],folder.appendingPathComponent("audio-retirement.json"))
    let retained=try SpeakerAudioPreview.read(root:root,cacheID:id,session:session,items:[row(10.5,11.5)])
    try check(retained.wav==clip.wav && !fm.fileExists(atPath:corrupted.path),"preview_retired_source_read_only_without_restore")
    try json(["schema":1,"cache_id":id,"state":"trashed","recoverable":true,"destination":"/other"],folder.appendingPathComponent("audio-retirement.json"))
    try reject("preview_retired_scope_rejected"){_=try SpeakerAudioPreview.read(root:root,cacheID:id,session:session,items:[row(10.5,11.5)])}
    return checks
}
