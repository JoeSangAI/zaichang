import Foundation
import CryptoKit

func sessionCacheRecoveryChecks(base:URL)throws->[String:Any] {
    try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    func manifest(_ directory:URL,track:String,bytes:Int,fileBytes:Int,committed:Int,ended:Bool,hash:String?=nil,offered:Int?=nil)throws->Data {
        let audio=Data((0..<fileBytes).map{UInt8(($0*7+track.utf8.count)%251)})
        try audio.write(to:directory.appendingPathComponent(track+"-000000.pcm"),options:.atomic)
        var chunk:[String:Any] = ["index":0,"start_sample":0,"bytes":bytes]
        if let hash {chunk["sha256"]=hash}
        let value:[String:Any] = ["schema":1,"track":track,"format":"pcm_s16le","sample_rate":16000,"channels":1,"written_bytes":bytes,"offered_bytes":offered ?? max(bytes,fileBytes),"origin_uptime":1,"ended":ended,"error":NSNull(),"chunks":[chunk],"asr_committed_bytes":committed,"model_committed_bytes":0,"archived":false,"audio_cleaned":false,"contains_voiceprint_embeddings":false,"alignment_padding_bytes":0,"admitted_pcm_bytes":bytes,"padding_counters_known":true]
        let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
        try data.write(to:directory.appendingPathComponent(track+"-manifest.json"),options:.atomic)
        return data
    }
    func folder()->URL {base.appendingPathComponent(UUID().uuidString,isDirectory:true)}
    func expectFailure(_ id:String,_ code:String,_ operation:()throws->Void)throws {
        do {try operation();throw Failure(code:"check_expected_\(code)")}
        catch let failure as Failure {guard failure.code==code else{throw failure}}
    }
    var checks:[String]=[]

    let valid=folder();try FileManager.default.createDirectory(at:valid,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    let micData=Data((0..<3200).map{UInt8(($0*7+3)%251)})
    _ = try manifest(valid,track:"mic",bytes:3200,fileBytes:3200,committed:0,ended:false,hash:digest(micData))
    _ = try manifest(valid,track:"mic-raw",bytes:3200,fileBytes:4800,committed:0,ended:false,offered:3200)
    _ = try manifest(valid,track:"reference",bytes:3200,fileBytes:4800,committed:0,ended:false,offered:3200)
    let remotePCM=Data((0..<3200).map{UInt8(($0*7+"remote".utf8.count)%251)})
    let healthyBefore=try manifest(valid,track:"remote",bytes:3200,fileBytes:3200,committed:3200,ended:true,hash:digest(remotePCM))
    try (healthyBefore+Data([10])).write(to:valid.appendingPathComponent("remote-manifest.json"),options:.atomic)
    let transcript=Data("{\"type\":\"segment\",\"final\":false,\"text\":\"保留不确定尾句\"}\n".utf8)
    try transcript.write(to:valid.appendingPathComponent("mic-transcript.jsonl"),options:.atomic)
    let originalAudio=try Data(contentsOf:valid.appendingPathComponent("mic-raw-000000.pcm"))
    let active=try SessionCacheWriterLease.acquire(directory:valid)
    try expectFailure(valid.lastPathComponent,"cache_writer_active"){_ = try recoverInterruptedSessionCache(at:valid)}
    active.release();checks.append("live_writer_lock_blocks_recovery")
    let recovered=try recoverInterruptedSessionCache(at:valid)
    guard recovered.state=="recovered_unclean_shutdown",recovered.tracks.count==4,
          try Data(contentsOf:valid.appendingPathComponent("mic-transcript.jsonl"))==transcript,
          try Data(contentsOf:valid.appendingPathComponent("mic-raw-000000.pcm"))==originalAudio,
          try Data(contentsOf:valid.appendingPathComponent("remote-manifest.json"))==healthyBefore+Data([10]) else{throw Failure(code:"cache_recovery_fixture_not_preserved")}
    let raw=try JSONSerialization.jsonObject(with:Data(contentsOf:valid.appendingPathComponent("mic-raw-manifest.json"))) as! [String:Any]
    let mic=try JSONSerialization.jsonObject(with:Data(contentsOf:valid.appendingPathComponent("mic-manifest.json"))) as! [String:Any]
    guard raw["written_bytes"] as? Int==4800,raw["asr_committed_bytes"] as? Int==0,
          raw["ended"] as? Bool==true,raw["error"] as? String=="cache_unclean_shutdown",
          mic["asr_committed_bytes"] as? Int==0,mic["error"] as? String=="cache_unclean_shutdown",
          recovered.warnings.contains(where:{$0.contains("source_gap_or_interruption_possible")}) else{throw Failure(code:"cache_recovery_provenance_missing")}
    let second=try recoverInterruptedSessionCache(at:valid)
    guard second.state=="unchanged" else{throw Failure(code:"cache_recovery_not_idempotent")}
    let firstReceipt=try JSONSerialization.jsonObject(with:Data(contentsOf:valid.appendingPathComponent("journal-recovery.json"))) as! [String:Any]
    guard (firstReceipt["tracks"] as? [[String:Any]])?.count==3 else{throw Failure(code:"cache_recovery_receipt_includes_healthy_track")}
    checks += ["sealed_audio_cursor_preserved","stale_manifest_tails_adopted_with_gap_warning","transcript_and_pcm_unchanged","unclean_error_retained","retry_is_idempotent"]
    let receiptURL=valid.appendingPathComponent("journal-recovery.json")
    var prepared=try JSONSerialization.jsonObject(with:Data(contentsOf:receiptURL)) as! [String:Any]
    prepared["state"]="prepared";prepared["warnings"]=["interrupted_before_final_receipt"]
    try JSONSerialization.data(withJSONObject:prepared,options:[.sortedKeys]).write(to:receiptURL,options:.atomic)
    guard sessionCacheMayNeedRecovery(at:valid) else{throw Failure(code:"cache_recovery_prepared_not_scheduled")}
    let finalized=try recoverInterruptedSessionCache(at:valid)
    guard finalized.state=="recovered_unclean_shutdown",finalized.warnings.contains("interrupted_before_final_receipt") else{throw Failure(code:"cache_recovery_prepared_not_finalized")}
    checks.append("prepared_receipt_retries_after_all_manifest_writes")
    var progressedMic=try JSONSerialization.jsonObject(with:Data(contentsOf:valid.appendingPathComponent("mic-manifest.json"))) as! [String:Any]
    progressedMic["asr_committed_bytes"]=1600
    try JSONSerialization.data(withJSONObject:progressedMic,options:[.sortedKeys]).write(to:valid.appendingPathComponent("mic-manifest.json"),options:.atomic)
    let meetingMetadata:[String:Any] = ["session":"receipt-session","cache_id":valid.lastPathComponent,"created_at":Date().timeIntervalSince1970]
    try JSONSerialization.data(withJSONObject:meetingMetadata,options:[.sortedKeys]).write(to:valid.appendingPathComponent("meeting.json"),options:.atomic)
    let listed=try cachedMeetings(in:base).first{$0.id==valid.lastPathComponent}
    guard !sessionCacheMayNeedRecovery(at:valid),listed?.recoveryStatus?["state"] as? String=="recovered_unclean_shutdown" else{throw Failure(code:"cache_recovery_receipt_not_replayed")}
    checks.append("completed_receipt_replayed_after_cursor_progress")
    let resumedJournal=try RecordingJournal(directory:valid,track:"mic",freeSpace:{1_000_000_000})
    try resumedJournal.commit("asr",cursor:resumedJournal.bytes());resumedJournal.wait()
    guard try verifiedSessionCacheRecoveryReceipt(at:valid)?["state"] as? String=="recovered_unclean_shutdown" else{throw Failure(code:"cache_recovery_provenance_lost_after_checkpoint")}
    checks.append("real_asr_checkpoint_preserves_verified_recovery_provenance")
    resumedJournal.setProcessingError("cache_transcript_write_failed");resumedJournal.wait()
    guard try verifiedSessionCacheRecoveryReceipt(at:valid)?["state"] as? String=="recovered_unclean_shutdown" else{throw Failure(code:"cache_recovery_provenance_lost_after_processing_failure")}
    let retriedJournal=try RecordingJournal(directory:valid,track:"mic",freeSpace:{1_000_000_000});retriedJournal.wait()
    guard retriedJournal.processingFault()==nil,try verifiedSessionCacheRecoveryReceipt(at:valid)?["state"] as? String=="recovered_unclean_shutdown" else{throw Failure(code:"cache_recovery_provenance_lost_after_processing_retry")}
    checks.append("processing_failure_and_retry_preserve_audio_recovery_provenance")


    let corrupt=folder();try FileManager.default.createDirectory(at:corrupt,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    let micBefore=try manifest(corrupt,track:"mic",bytes:3200,fileBytes:4800,committed:3200,ended:false)
    let wrong=Data(repeating:0x55,count:3200)
    _ = try manifest(corrupt,track:"remote",bytes:3200,fileBytes:3200,committed:0,ended:false,hash:digest(wrong))
    try expectFailure(corrupt.lastPathComponent,"cache_recovery_chunk_integrity"){_ = try recoverInterruptedSessionCache(at:corrupt)}
    guard try Data(contentsOf:corrupt.appendingPathComponent("mic-manifest.json"))==micBefore else{throw Failure(code:"cache_recovery_partial_session_mutation")}
    checks.append("all_tracks_validated_before_any_manifest_write")

    let orphan=folder();try FileManager.default.createDirectory(at:orphan,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    _ = try manifest(orphan,track:"mic",bytes:3200,fileBytes:3200,committed:0,ended:false)
    try Data(repeating:0,count:1600).write(to:orphan.appendingPathComponent("mic-000001.pcm"),options:.atomic)
    try expectFailure(orphan.lastPathComponent,"cache_recovery_orphan_chunk"){_ = try recoverInterruptedSessionCache(at:orphan)}
    checks.append("orphan_chunks_are_never_guessed")

    let truncated=folder();try FileManager.default.createDirectory(at:truncated,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    _ = try manifest(truncated,track:"mic",bytes:4800,fileBytes:3200,committed:0,ended:false)
    try expectFailure(truncated.lastPathComponent,"cache_recovery_chunk_size_invalid"){_ = try recoverInterruptedSessionCache(at:truncated)}
    checks.append("truncated_chunks_are_never_sealed")

    let queuedLoss=folder();try FileManager.default.createDirectory(at:queuedLoss,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    let queuedBefore=try manifest(queuedLoss,track:"mic-raw",bytes:3200,fileBytes:3200,committed:0,ended:true,offered:4800)
    guard sessionCacheMayNeedRecovery(at:queuedLoss) else{throw Failure(code:"cache_recovery_ended_queued_loss_not_scheduled")}
    try expectFailure(queuedLoss.lastPathComponent,"cache_recovery_offered_bytes_mismatch"){_ = try recoverInterruptedSessionCache(at:queuedLoss)}
    guard try Data(contentsOf:queuedLoss.appendingPathComponent("mic-raw-manifest.json"))==queuedBefore else{throw Failure(code:"cache_recovery_offered_loss_mutated")}
    checks.append("known_queued_bytes_missing_reject_sealing")
    return ["type":"session_cache_recovery_checks","assertions":checks.count,"checks":checks,"capture":false,"network":false,"cloud_asr":false,"transcription_started":false,"pcm_mutated":false,"transcript_mutated":false]
}
