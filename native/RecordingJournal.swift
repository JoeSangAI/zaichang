import Foundation
import CryptoKit
import Darwin

/// One process owns every manifest and transcript append for a SessionCache at
/// a time. Readers use the same nonblocking lease before repairing an abrupt
/// shutdown, so a live writer is never mistaken for a recoverable tail.
final class SessionCacheWriterLease {
    private let descriptor:Int32
    private let releaseLock=NSLock()
    private var released=false
    let directory:URL
    private init(descriptor:Int32,directory:URL){self.descriptor=descriptor;self.directory=directory}
    static func acquire(directory:URL)throws->SessionCacheWriterLease {
        let values=try directory.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard values.isDirectory==true,values.isSymbolicLink != true,
              UUID(uuidString:directory.lastPathComponent) != nil else{throw Failure(code:"cache_scope_invalid")}
        let path=directory.appendingPathComponent(".writer.lock").path
        let fd=open(path,O_CREAT|O_RDWR|O_CLOEXEC,S_IRUSR|S_IWUSR)
        guard fd>=0 else{throw Failure(code:"cache_writer_lock_unavailable")}
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else{close(fd);throw Failure(code:errno==EWOULDBLOCK || errno==EAGAIN ? "cache_writer_active":"cache_writer_lock_unavailable")}
        return SessionCacheWriterLease(descriptor:fd,directory:directory)
    }
    func release(){releaseLock.lock();defer{releaseLock.unlock()};guard !released else{return};released=true;flock(descriptor,LOCK_UN);close(descriptor)}
    // Library refresh may still be sealing the dead recorder's final chunks.
    // Wait only for that lease; validation failures remain terminal and no ASR
    // or audio capture starts before exclusive ownership has been obtained.
    static func acquireForRecovery(directory:URL,timeout:Double=5) async throws->SessionCacheWriterLease {
        let deadline=ProcessInfo.processInfo.systemUptime+timeout
        while true {
            try Task.checkCancellation()
            do {return try acquire(directory:directory)}
            catch let error as Failure where error.code=="cache_writer_active" {
                guard ProcessInfo.processInfo.systemUptime<deadline else{throw error}
                try await Task.sleep(nanoseconds:25_000_000)
            }
        }
    }
    deinit {release()}
}

struct SessionCacheRecoveryResult {
    let cacheID:String
    let state:String
    let tracks:[[String:Any]]
    let warnings:[String]
    var json:[String:Any] { ["type":"session_cache_recovery","cache_id":cacheID,"state":state,"tracks":tracks,"warnings":warnings,"capture":false,"network":false,"transcription_started":false] }
}

/// A cheap manifest-only gate for library enumeration. Full PCM hashing runs
/// only when at least one journal advertises an unsealed or inconsistent tail.
func sessionCacheMayNeedRecovery(at directory:URL)->Bool {
    let receipt=directory.appendingPathComponent("journal-recovery.json")
    if let data=try? Data(contentsOf:receipt),data.count<=128*1024,
       let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],value["schema"] as? Int==1,
       value["cache_id"] as? String==directory.lastPathComponent,value["state"] as? String=="prepared" {return true}
    guard let tracks=try? meetingAudioTracks(in:directory,transcriptOnly:false),!tracks.isEmpty else{return false}
    for track in tracks {
        let path=directory.appendingPathComponent(track+"-manifest.json")
        guard let data=try? Data(contentsOf:path),data.count<=2*1024*1024,
              let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let chunks=value["chunks"] as? [[String:Any]],let written=value["written_bytes"] as? Int else{return true}
        let declared=chunks.reduce(0){$0+max(0,$1["bytes"] as? Int ?? 0)}
        if value["ended"] as? Bool != true || written != declared || (value["offered_bytes"] as? Int ?? written)>written {return true}
        for (index,chunk) in chunks.enumerated() {
            guard let bytes=chunk["bytes"] as? Int else{return true}
            let file=directory.appendingPathComponent(track+String(format:"-%06d.pcm",index))
            guard let size=try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize,size==bytes else{return true}
        }
    }
    return false
}

/// Re-publish a completed recovery after process restart, including when its
/// manifest commit succeeded but the AgentContext projection did not. Exact
/// after-hashes are preferred; ASR/model cursors and the archive flag may move
/// later, so receipts created by this version also carry a stable hash with
/// those mutable fields excluded.
func verifiedSessionCacheRecoveryReceipt(at directory:URL)throws->[String:Any]? {
    let receiptURL=directory.appendingPathComponent("journal-recovery.json")
    guard FileManager.default.fileExists(atPath:receiptURL.path) else{return nil}
    let lease=try SessionCacheWriterLease.acquire(directory:directory)
    defer {lease.release()}
    let attrs=try receiptURL.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
    guard attrs.isRegularFile==true,attrs.isSymbolicLink != true,(attrs.fileSize ?? Int.max)<=128*1024,
          let data=try? Data(contentsOf:receiptURL),let receipt=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
          receipt["schema"] as? Int==1,receipt["cache_id"] as? String==directory.lastPathComponent,
          receipt["state"] as? String=="recovered_unclean_shutdown",
          let rows=receipt["tracks"] as? [[String:Any]],!rows.isEmpty,rows.count<=66 else{throw Failure(code:"cache_recovery_receipt_invalid")}
    func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    func stableHash(_ data:Data)throws->String {
        guard var value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{throw Failure(code:"cache_recovery_receipt_invalid")}
        value.removeValue(forKey:"asr_committed_bytes");value.removeValue(forKey:"model_committed_bytes");value.removeValue(forKey:"archived")
        value.removeValue(forKey:"processing_error");value.removeValue(forKey:"previous_processing_error")
        return hash(try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]))
    }
    var seen=Set<String>()
    for row in rows {
        guard let track=row["track"] as? String,isMeetingAudioTrack(track),seen.insert(track).inserted,
              let verified=row["verified_written_bytes"] as? Int,verified>=0,verified%2==0,
              let expectedAfter=row["after_sha256"] as? String else{throw Failure(code:"cache_recovery_receipt_invalid")}
        let manifestURL=directory.appendingPathComponent(track+"-manifest.json")
        let manifestAttrs=try manifestURL.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard manifestAttrs.isRegularFile==true,manifestAttrs.isSymbolicLink != true,(manifestAttrs.fileSize ?? Int.max)<=2*1024*1024,
              let manifest=try? Data(contentsOf:manifestURL),let value=(try? JSONSerialization.jsonObject(with:manifest)) as? [String:Any],
              value["schema"] as? Int==1,value["track"] as? String==track,value["ended"] as? Bool==true,
              value["error"] as? String=="cache_unclean_shutdown",value["written_bytes"] as? Int==verified,
              (value["asr_committed_bytes"] as? Int ?? -1)>=0,(value["asr_committed_bytes"] as? Int ?? Int.max)<=verified else{throw Failure(code:"cache_recovery_receipt_stale")}
        let exact=hash(manifest)==expectedAfter
        let stable=row["stable_after_sha256"] as? String
        guard exact || (stable != nil && (try? stableHash(manifest))==stable) else{throw Failure(code:"cache_recovery_receipt_stale")}
    }
    return ["type":"session_cache_recovery","cache_id":directory.lastPathComponent,"state":"recovered_unclean_shutdown","tracks":rows,
            "warnings":receipt["warnings"] as? [String] ?? [],"capture":false,"network":false,"transcription_started":false]
}

/// Conservatively seals a dead writer's journals after verifying every byte.
/// It never edits transcripts, ASR cursors, speaker labels or PCM. Only an
/// unsealed final chunk listed in the manifest may absorb a complete PCM tail.
func recoverInterruptedSessionCache(at directory:URL)throws->SessionCacheRecoveryResult {
    let lease=try SessionCacheWriterLease.acquire(directory:directory)
    defer {lease.release()}
    do {
    let tracks=try meetingAudioTracks(in:directory,transcriptOnly:false)
    guard !tracks.isEmpty,tracks.count<=66 else{throw Failure(code:"cache_recovery_tracks_invalid")}
    let sessionFiles=try FileManager.default.contentsOfDirectory(atPath:directory.path)
    let knownPCMTracks=Set(sessionFiles.compactMap{name->String? in
        guard let range=name.range(of:"-[0-9]{6}\\.pcm$",options:.regularExpression) else{return nil}
        let track=String(name[..<range.lowerBound]);return isMeetingAudioTrack(track) ? track:nil
    })
    guard knownPCMTracks.isSubset(of:Set(tracks)) else{throw Failure(code:"cache_recovery_unowned_track_audio")}
    struct Plan {let track:String;let old:Data;let next:Data;let originalWritten:Int;let recoveredWritten:Int;let tailBytes:Int;let hadUncleanEnd:Bool}
    func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    func stableManifestHash(_ data:Data)throws->String {
        guard var value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{throw Failure(code:"cache_recovery_manifest_invalid")}
        value.removeValue(forKey:"asr_committed_bytes");value.removeValue(forKey:"model_committed_bytes");value.removeValue(forKey:"archived")
        value.removeValue(forKey:"processing_error");value.removeValue(forKey:"previous_processing_error")
        return hash(try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]))
    }
    var plans:[Plan]=[];var warnings:[String]=[];var anyChange=false
    for track in tracks {
        let manifestURL=directory.appendingPathComponent(track+"-manifest.json")
        let old=try Data(contentsOf:manifestURL)
        guard old.count<=2*1024*1024,let value=try JSONSerialization.jsonObject(with:old) as? [String:Any],
              value["schema"] as? Int==1,value["track"] as? String==track,
              value["format"] as? String=="pcm_s16le",value["sample_rate"] as? Int==16000,
              value["channels"] as? Int==1,let entries=value["chunks"] as? [[String:Any]],
              let written=value["written_bytes"] as? Int,written>=0,written%2==0,
              let committed=value["asr_committed_bytes"] as? Int,committed>=0,committed%2==0,committed<=written else {
            throw Failure(code:"cache_recovery_manifest_invalid")
        }
        let error=value["error"] as? String
        guard error==nil || error=="cache_unclean_shutdown" else{throw Failure(code:"cache_recovery_existing_fault")}
        guard value["audio_cleaned"] as? Bool != true else{throw Failure(code:"cache_recovery_audio_retired")}
        var verified:[[String:Any]]=[];var offset=0;var tailBytes=0
        for (index,entry) in entries.enumerated() {
            guard entry["index"] as? Int==index,let declared=entry["bytes"] as? Int,
                  declared>=0,declared%2==0,declared<=320000,
                  (entry["start_sample"] as? Int ?? offset/2)==offset/2 else{throw Failure(code:"cache_recovery_chunk_index_invalid")}
            let file=directory.appendingPathComponent(track+String(format:"-%06d.pcm",index))
            let attrs=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard attrs.isRegularFile==true,attrs.isSymbolicLink != true,let size=attrs.fileSize,size>=declared,size<=320000 else{throw Failure(code:"cache_recovery_chunk_size_invalid")}
            let data=try Data(contentsOf:file,options:.mappedIfSafe)
            guard data.count==size,data.count%2==0 else{throw Failure(code:"cache_recovery_pcm_alignment_invalid")}
            let hasDigest=entry["sha256"] as? String
            if let hasDigest {
                guard size==declared,hash(data)==hasDigest else{throw Failure(code:"cache_recovery_chunk_integrity")}
            } else {
                guard index==entries.count-1 else{throw Failure(code:"cache_recovery_unsealed_middle_chunk")}
                tailBytes=size-declared
            }
            var repaired=entry;repaired["bytes"]=size;repaired["sha256"]=hash(data);verified.append(repaired);offset+=size
        }
        let names=try FileManager.default.contentsOfDirectory(atPath:directory.path)
        let indexed=Set(entries.indices.map{track+String(format:"-%06d.pcm",$0)})
        let owned=Set(names.filter{$0.range(of:"^"+NSRegularExpression.escapedPattern(for:track)+"-[0-9]{6}\\.pcm$",options:.regularExpression) != nil})
        guard owned==indexed else{throw Failure(code:"cache_recovery_orphan_chunk")}
        guard offset>=written,offset%2==0 else{throw Failure(code:"cache_recovery_written_bytes_mismatch")}
        let offered=value["offered_bytes"] as? Int ?? written
        // offered_bytes includes work admitted to the asynchronous journal
        // queue. If it exceeds bytes recoverable from disk, the lost queued
        // audio is known, so do not seal the cache or imply completeness.
        // A newer PCM tail may have reached disk after the last manifest
        // snapshot, so offered can lag verified bytes. The reverse means the
        // journal admitted bytes that are absent from disk and is unrecoverable.
        guard offered<=offset,offered%2==0 else{throw Failure(code:"cache_recovery_offered_bytes_mismatch")}
        let ended=value["ended"] as? Bool==true
        let needsRepair = !ended || offset != written
        var nextValue=value
        if needsRepair {
            nextValue["chunks"]=verified;nextValue["written_bytes"]=offset;nextValue["offered_bytes"]=max(offered,offset)
            nextValue["ended"]=true;nextValue["error"]="cache_unclean_shutdown"
            nextValue["recovery"]=["schema":1,"method":"verified_unsealed_journal_recovery","tail_bytes":tailBytes,"verified_at":Date().timeIntervalSince1970,"writer_lock":"exclusive","transcription_started":false,"transcript_modified":false]
            anyChange=true
            warnings.append(track+":"+(tailBytes>0 ? "verified_unsealed_tail_\(tailBytes)_bytes; source_gap_or_interruption_possible":"unclean_shutdown; no_pcm_tail_added"))
        }
        let next=needsRepair ? try JSONSerialization.data(withJSONObject:nextValue,options:[.sortedKeys]):old
        plans.append(Plan(track:track,old:old,next:next,originalWritten:written,recoveredWritten:offset,tailBytes:tailBytes,hadUncleanEnd:!ended))
    }
    let receiptURL=directory.appendingPathComponent("journal-recovery.json")
    let prior=(try? Data(contentsOf:receiptURL)).flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
    let incompleteReceipt=prior?["state"] as? String=="prepared"
    if incompleteReceipt {
        for recorded in prior?["tracks"] as? [[String:Any]] ?? [] {
            guard let track=recorded["track"] as? String,isMeetingAudioTrack(track),
                  let expectedBefore=recorded["before_sha256"] as? String,let expectedAfter=recorded["after_sha256"] as? String,
                  let plan=plans.first(where:{$0.track==track}) else{throw Failure(code:"cache_recovery_receipt_invalid")}
            let currentHash=hash(plan.old)
            guard currentHash==expectedBefore || currentHash==expectedAfter else{throw Failure(code:"cache_recovery_receipt_conflict")}
        }
    }
    guard anyChange || incompleteReceipt else{
        try markSessionCacheRecoveryDiagnostic(directory:directory,state:"resolved",code:nil)
        return SessionCacheRecoveryResult(cacheID:directory.lastPathComponent,state:"unchanged",tracks:plans.map{["track":$0.track,"written_bytes":$0.originalWritten,"verified_bytes":$0.recoveredWritten,"tail_bytes":$0.tailBytes]},warnings:[])
    }
    // Validate the entire session before touching any manifest. Preserve exact
    // originals, then atomically replace each small manifest for retry safety.
    let backupDir=directory.appendingPathComponent(".journal-recovery-backups",isDirectory:true)
    try FileManager.default.createDirectory(at:backupDir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    for plan in plans where plan.old != plan.next {
        let backup=backupDir.appendingPathComponent(plan.track+"-"+hash(plan.old)+".json")
        if !FileManager.default.fileExists(atPath:backup.path) {try plan.old.write(to:backup,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path)}
    }
    var receiptTracks=prior?["tracks"] as? [[String:Any]] ?? []
    for plan in plans where plan.old != plan.next {
        receiptTracks.removeAll{$0["track"] as? String==plan.track}
        let stable=try stableManifestHash(plan.next)
        receiptTracks.append(["track":plan.track,"before_sha256":hash(plan.old),"after_sha256":hash(plan.next),"stable_after_sha256":stable,"original_written_bytes":plan.originalWritten,"verified_written_bytes":plan.recoveredWritten,"verified_tail_bytes":plan.tailBytes,"ended_was_false":plan.hadUncleanEnd,"transcription_started":false,"transcript_modified":false])
    }
    let priorWarnings=prior?["warnings"] as? [String] ?? []
    warnings=Array(Set(priorWarnings+warnings)).sorted()
    let prepared:[String:Any] = ["schema":1,"cache_id":directory.lastPathComponent,"state":"prepared","created_at":prior?["created_at"] as? Double ?? Date().timeIntervalSince1970,"tracks":receiptTracks,"warnings":warnings]
    let preparedData=try JSONSerialization.data(withJSONObject:prepared,options:[.sortedKeys]);try preparedData.write(to:receiptURL,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:receiptURL.path)
    for plan in plans where plan.old != plan.next {
        let url=directory.appendingPathComponent(plan.track+"-manifest.json")
        guard try Data(contentsOf:url)==plan.old else{throw Failure(code:"cache_recovery_manifest_changed")}
        try plan.next.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    let receipt:[String:Any] = ["schema":1,"cache_id":directory.lastPathComponent,"state":"recovered_unclean_shutdown","created_at":prior?["created_at"] as? Double ?? Date().timeIntervalSince1970,"tracks":receiptTracks,"warnings":warnings]
    let receiptData=try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys]);try receiptData.write(to:receiptURL,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:receiptURL.path)
    try markSessionCacheRecoveryDiagnostic(directory:directory,state:"resolved",code:nil)
    return SessionCacheRecoveryResult(cacheID:directory.lastPathComponent,state:"recovered_unclean_shutdown",tracks:plans.map{["track":$0.track,"written_bytes":$0.originalWritten,"verified_bytes":$0.recoveredWritten,"tail_bytes":$0.tailBytes]},warnings:warnings)
    } catch {
        let code=(error as? Failure)?.code ?? "cache_recovery_read_failed"
        try? markSessionCacheRecoveryDiagnostic(directory:directory,state:"source_error",code:code)
        throw error
    }
}

func markSessionCacheRecoveryDiagnostic(directory:URL,state:String,code:String?)throws {
    let path=directory.appendingPathComponent("journal-recovery-diagnostic.json")
    let value:[String:Any]=["schema":1,"cache_id":directory.lastPathComponent,"state":state,"code":code.map{$0 as Any} ?? NSNull(),"updated_at":Date().timeIntervalSince1970,"audio_files_preserved":true,"gapless_capture_verified":false,"transcription_started":false,"transcript_modified":false]
    let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]);try data.write(to:path,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
}

// Own-session audio only. Support directory survives ordinary temp/cache cleanup.
// A serialized writer runs away from capture callbacks; backlog is bounded.
final class RecordingJournal {
    let directory:URL;let track:String;let alignCaptureTime:Bool;let chunkBytes=320000;let maxBytes:Int
    private let queue:DispatchQueue;private let transcriptQueue:DispatchQueue;private let lock=NSLock()
    // Admission is measured in PCM bytes, not callback count (10 ms callbacks
    // previously exhausted 256 slots in 2.56 seconds). Consumers never share
    // this writer queue. Keep a bounded 65 second reservoir per active source.
    private let maxPendingPCMBytes=2*1024*1024
    private var pendingPCMBytes=0;private var pendingPackets=0;private var peakPendingPCMBytes=0
    private var closing=false;private var checkpointScheduled=false;private var checkpointWrites=0
    private var processingError:String?;private var previousProcessingError:String?
    private var pendingTranscriptBytes=0;private var pendingTranscriptEvents=0
    private var alignmentPaddingBytes=0;private var admittedPCMBytes=0;private var paddingCountersKnown=true
    private var written=0;private var offered=0;private var pending=0;private var ended=false;private var error:String?
    private var origin:Double?;private var chunks:[[String:Any]]=[];private var handle:FileHandle?;private var chunkIndex=0;private var chunkCount=0
    private var asrCommit=0;private var modelCommit=0;private var transcriptChecked=false;private var archived=false;private var audioCleaned=false
    private var recoveryInfo:[String:Any]?
    private let freeSpace:()->Int64;private let beforeWrite:(()->Void)?
    private var lastSpaceCheck = -Double.infinity;private var bytesSinceSpaceCheck=0
    init(directory:URL,track:String,maxBytes:Int=512*1024*1024,freeSpace:(()->Int64)?=nil,alignCaptureTime:Bool=false,beforeWrite:(()->Void)?=nil)throws {
        guard isMeetingAudioTrack(track),maxBytes>0 else{throw Failure(code:"cache_scope_invalid")}
        self.directory=directory;self.track=track;self.alignCaptureTime=alignCaptureTime;self.maxBytes=maxBytes;queue=DispatchQueue(label:"meeting.record-journal."+track,qos:.userInitiated)
        transcriptQueue=DispatchQueue(label:"meeting.transcript-journal."+track,qos:.utility)
        self.beforeWrite=beforeWrite
        self.freeSpace=freeSpace ?? {let values=try? FileManager.default.attributesOfFileSystem(forPath:directory.path);return (values?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if FileManager.default.fileExists(atPath:directory.appendingPathComponent(track+"-manifest.json").path){try recover()}else{try saveManifest()}
    }
    private func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private func saveManifest() throws {
        lock.lock();var value:[String:Any]=["schema":1,"track":track,"format":"pcm_s16le","sample_rate":16000,"channels":1,"written_bytes":written,"offered_bytes":offered,"origin_uptime":origin.map{$0 as Any} ?? NSNull(),"ended":ended,"error":error.map{$0 as Any} ?? NSNull(),"chunks":chunks,"asr_committed_bytes":asrCommit,"model_committed_bytes":modelCommit,"archived":archived,"audio_cleaned":audioCleaned,"contains_voiceprint_embeddings":false,"alignment_padding_bytes":alignmentPaddingBytes,"admitted_pcm_bytes":admittedPCMBytes,"padding_counters_known":paddingCountersKnown];if let recoveryInfo {value["recovery"]=recoveryInfo};lock.unlock()
        lock.lock();value["processing_error"]=processingError.map{$0 as Any} ?? NSNull();value["previous_processing_error"]=previousProcessingError.map{$0 as Any} ?? NSNull();lock.unlock()
        let file=directory.appendingPathComponent(track+"-manifest.json");try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        lock.lock();checkpointWrites+=1;lock.unlock()
    }
    private func requestCheckpoint() {
        lock.lock();guard !checkpointScheduled else{lock.unlock();return};checkpointScheduled=true;lock.unlock()
        queue.asyncAfter(deadline:.now()+1) {[self] in
            lock.lock();checkpointScheduled=false;lock.unlock()
            do {try saveManifest()}catch{setProcessingError("cache_checkpoint_write_failed")}
        }
    }
    func setProcessingError(_ code:String) {lock.lock();let first=processingError==nil;if first {processingError=code};lock.unlock();if first {requestCheckpoint()}}
    func processingFault()->String? {lock.lock();defer{lock.unlock()};return processingError}
    private func recover() throws {
        guard let value=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent(track+"-manifest.json"))) as? [String:Any] else{throw Failure(code:"cache_manifest_invalid")}
        guard value["schema"] as? Int==1,value["track"] as? String==track,value["format"] as? String=="pcm_s16le",value["sample_rate"] as? Int==16000,value["channels"] as? Int==1,let stored=value["chunks"] as? [[String:Any]] else{throw Failure(code:"cache_manifest_invalid")}
        alignmentPaddingBytes=value["alignment_padding_bytes"] as? Int ?? 0;admittedPCMBytes=value["admitted_pcm_bytes"] as? Int ?? 0;paddingCountersKnown=value["padding_counters_known"] as? Bool ?? false
        recoveryInfo=value["recovery"] as? [String:Any]
        error=value["error"] as? String;origin=value["origin_uptime"] as? Double;asrCommit=value["asr_committed_bytes"] as? Int ?? 0;modelCommit=value["model_committed_bytes"] as? Int ?? 0;archived=value["archived"] as? Bool ?? false
        previousProcessingError=value["processing_error"] as? String ?? value["previous_processing_error"] as? String
        if let old=error,["cache_transcript_write_failed","cache_transcript_capacity","cache_checkpoint_write_failed"].contains(old) {previousProcessingError=old;error=nil}
        let receiptFile=directory.appendingPathComponent("audio-retirement.json")
        let retirement=(try? Data(contentsOf:receiptFile)).flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
        let retired=retirement?["schema"] as? Int==1 && retirement?["cache_id"] as? String==directory.lastPathComponent && retirement?["state"] as? String=="trashed" && (retirement?["tracks"] as? [String] ?? []).contains(track)
        if value["audio_cleaned"] as? Bool==true || retired {
            guard archived,value["ended"] as? Bool==true,FileManager.default.fileExists(atPath:directory.appendingPathComponent("archived-transcript.txt").path),let count=value["written_bytes"] as? Int,count>=0,count%2==0,asrCommit>=count else{throw Failure(code:"cache_archive_invalid")}
            audioCleaned=true;ended=true;written=count;offered=count;return
        }
        var offset=0
        for entry in stored {
            guard let index=entry["index"] as? Int,index==chunks.count,let count=entry["bytes"] as? Int,count>=0,count%2==0,count<=chunkBytes else{throw Failure(code:"cache_manifest_invalid")}
            let file=directory.appendingPathComponent(track+String(format:"-%06d.pcm",index));let data=try Data(contentsOf:file)
            guard data.count>=count else{throw Failure(code:"cache_audio_truncated")}
            if let hash=entry["sha256"] as? String {guard data.count==count,digest(data)==hash else{throw Failure(code:"cache_audio_integrity")}}
            // Unsealed tail may contain writes newer than the last manifest. Keep
            // and recover the even-byte prefix; flag an unclean ending, never claim gapless.
            let usable=min(chunkBytes,data.count-data.count%2);var recovered=entry;recovered["bytes"]=usable;chunks.append(recovered);offset+=usable
        }
        let indexed=Set(chunks.indices.map{track+String(format:"-%06d.pcm",$0)})
        let owned=try FileManager.default.contentsOfDirectory(atPath:directory.path).filter{$0.range(of:"^"+track+"-[0-9]{6}\\.pcm$",options:.regularExpression) != nil}
        if !Set(owned).subtracting(indexed).isEmpty {error="cache_unindexed_audio_retained"}
        written=offset;offered=max(offset,value["offered_bytes"] as? Int ?? offset);ended=true
        if value["ended"] as? Bool != true,error==nil {error="cache_unclean_shutdown"}
        asrCommit=min(max(0,asrCommit),written);modelCommit=min(max(0,modelCommit),written)
    }
    func enqueue(_ data:Data,at stamp:Double)throws {
        guard !data.isEmpty,data.count%2==0,data.count<=32768,stamp.isFinite else{throw Failure(code:"cache_invalid_pcm")}
        lock.lock()
        if closing || ended || error != nil || data.count>maxBytes-offered {let code=error ?? ((closing || ended) ? "cache_after_stop":"cache_size_limit");lock.unlock();throw Failure(code:code)}
        guard pendingPCMBytes<=maxPendingPCMBytes-data.count,pendingPackets<65536 else{error="cache_writer_backpressure";lock.unlock();throw Failure(code:"cache_writer_backpressure")}
        if origin==nil{origin=stamp}
        let expectedSamples=alignCaptureTime ? max(0,Int(((stamp-(origin ?? stamp))*16000).rounded())):offered/2
        // A disappeared app can return later. Preserve its meeting position with
        // silence instead of pulling its later speech backwards in time.
        let gap=max(0,expectedSamples-offered/2)
        let gapBytes=gap>160 ? gap*2:0
        guard gapBytes<=maxBytes-offered-data.count else{lock.unlock();setError("cache_size_limit");throw Failure(code:"cache_size_limit")}
        let pendingBytes=data.count+gapBytes;alignmentPaddingBytes+=gapBytes;admittedPCMBytes+=data.count;offered+=pendingBytes;pending+=pendingBytes;pendingPCMBytes+=data.count;pendingPackets+=1;peakPendingPCMBytes=max(peakPendingPCMBytes,pendingPCMBytes)
        // Enqueue while holding admission lock so concurrent callbacks preserve
        // their assigned offsets, including against a simultaneous finish.
        queue.async{[self] in defer{lock.lock();pending-=pendingBytes;pendingPCMBytes-=data.count;pendingPackets-=1;lock.unlock()}
            do {var remaining=gapBytes;while remaining>0 {let n=min(32768,remaining);try append(Data(repeating:0,count:n));remaining-=n};try append(data)}catch{setError((error as? Failure)?.code ?? "cache_write_failed")}
        }
        lock.unlock()
    }
    private func append(_ input:Data)throws {
        beforeWrite?()
        let now=ProcessInfo.processInfo.systemUptime
        if now-lastSpaceCheck>=1 || bytesSinceSpaceCheck>=320000 {
            guard freeSpace()>=32*1024*1024 else{throw Failure(code:"cache_disk_space_low")}
            lastSpaceCheck=now;bytesSinceSpaceCheck=0
        }
        bytesSinceSpaceCheck+=input.count
        var position=0
        while position<input.count {
            if handle==nil {
                let file=directory.appendingPathComponent(track+String(format:"-%06d.pcm",chunkIndex))
                guard !FileManager.default.fileExists(atPath:file.path) else{throw Failure(code:"cache_chunk_collision")}
                guard FileManager.default.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw Failure(code:"cache_create_failed")}
                handle=try FileHandle(forWritingTo:file);chunkCount=0
                lock.lock();chunks.append(["index":chunkIndex,"start_sample":written/2,"bytes":0]);lock.unlock();try saveManifest()
            }
            let count=min(input.count-position,chunkBytes-chunkCount);try handle!.write(contentsOf:input[position..<position+count]);position+=count;chunkCount+=count
            lock.lock();written+=count;chunks[chunkIndex]["bytes"]=chunkCount;lock.unlock()
            if chunkCount==chunkBytes {try sealChunk()}
        }
    }
    private func sealChunk()throws {
        guard let fileHandle=handle else{return};try fileHandle.synchronize();try fileHandle.close();handle=nil
        let data=try Data(contentsOf:directory.appendingPathComponent(track+String(format:"-%06d.pcm",chunkIndex)))
        lock.lock();chunks[chunkIndex]["sha256"]=digest(data);lock.unlock();try saveManifest();chunkIndex+=1;chunkCount=0
    }
    func finish(){lock.lock();guard !closing else{lock.unlock();return};closing=true;queue.async{[self] in do {try sealChunk();lock.lock();ended=true;lock.unlock();try saveManifest()}catch{setError("cache_finish_failed");lock.lock();ended=true;lock.unlock()}};lock.unlock()}
    func wait(){queue.sync{};transcriptQueue.sync{};queue.sync{do {try saveManifest()}catch{setProcessingError("cache_checkpoint_write_failed")}}}
    func setError(_ code:String){lock.lock();if error==nil || error=="cache_unclean_shutdown" {error=code};lock.unlock()}
    func fault()->String? {lock.lock();defer{lock.unlock()};return error}
    // Saved audio can be fully transcribed after an interrupted capture. Keep
    // the interruption warning and stricter audio cleanup policy independent.
    static func transcriptionIsComplete(ended:Bool,written:Int,committed:Int,error:String?)->Bool {
        ended && written>=0 && committed>=written && (error==nil || error=="cache_unclean_shutdown" || error=="cache_writer_backpressure")
    }
    func transcriptionIsComplete()->Bool {
        lock.lock();defer{lock.unlock()}
        return processingError==nil && Self.transcriptionIsComplete(ended:ended,written:written,committed:asrCommit,error:error)
    }
    func isEnded()->Bool {lock.lock();defer{lock.unlock()};return ended}
    func bytes()->Int {lock.lock();defer{lock.unlock()};return written}
    func firstOrigin()->Double? {lock.lock();defer{lock.unlock()};return origin}
    func read(_ cursor:Int,limit:Int=3200)throws->(Data,Double)? {
        lock.lock();let available=written;let base=origin;lock.unlock()
        guard !audioCleaned else{throw Failure(code:"cache_audio_already_archived")};guard cursor>=0,cursor%2==0,cursor<=available else{throw Failure(code:"cache_cursor_invalid")}
        guard cursor<available,let base=base else{return nil}
        let index=cursor/chunkBytes;let offset=cursor%chunkBytes;let count=min(limit,available-cursor,chunkBytes-offset)
        let file=directory.appendingPathComponent(track+String(format:"-%06d.pcm",index));let input=try FileHandle(forReadingFrom:file);defer{try? input.close()};try input.seek(toOffset:UInt64(offset));let data=try input.read(upToCount:count) ?? Data()
        guard data.count==count else{throw Failure(code:"cache_audio_short_read")};return(data,base+Double(cursor)/32000)
    }
    func commit(_ consumer:String,cursor:Int)throws {guard ["asr","model"].contains(consumer),cursor>=0,cursor%2==0,cursor<=bytes() else{throw Failure(code:"cache_cursor_invalid")}
        if consumer=="asr" {commitAfterTranscript(cursor);return}
        lock.lock();modelCommit=max(modelCommit,cursor);lock.unlock();requestCheckpoint()
    }
    func record(_ event:[String:Any]) {var safe=event;safe.removeValue(forKey:"identity_features");if let runs=safe["speaker_runs"] as? [[String:Any]] {safe["speaker_runs"]=runs.map {row -> [String:Any] in var value=row;value.removeValue(forKey:"identity_features");return value}};safe.removeValue(forKey:"previous_partial")
        guard let data=try? JSONSerialization.data(withJSONObject:safe,options:[.sortedKeys]),data.count<=1024*1024 else{setProcessingError("cache_transcript_capacity");return}
        lock.lock();guard processingError==nil,pendingTranscriptBytes<=8*1024*1024-data.count,pendingTranscriptEvents<4096 else{lock.unlock();setProcessingError("cache_transcript_capacity");return};pendingTranscriptBytes+=data.count;pendingTranscriptEvents+=1
        transcriptQueue.async{[self] in defer{lock.lock();pendingTranscriptBytes-=data.count;pendingTranscriptEvents-=1;lock.unlock()};do {
            let file=directory.appendingPathComponent(track+"-transcript.jsonl")
            if !FileManager.default.fileExists(atPath:file.path){guard FileManager.default.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw Failure(code:"cache_transcript_write_failed")}}
            let attributes=try FileManager.default.attributesOfItem(atPath:file.path);guard (attributes[.type] as? FileAttributeType) == .typeRegular,((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 32*1024*1024-data.count-1 else{throw Failure(code:"cache_transcript_capacity")}
            if !transcriptChecked {transcriptChecked=true;let previous=try Data(contentsOf:file);if !previous.isEmpty,previous.last != 10 {let position=previous.lastIndex(of:10).map{$0+1} ?? 0;let backup=directory.appendingPathComponent(track+"-transcript-incomplete-tail.bin");try Data(previous[position...]).write(to:backup,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path);let repair=try FileHandle(forWritingTo:file);try repair.truncate(atOffset:UInt64(position));try repair.close()}}
            let output=try FileHandle(forWritingTo:file);defer{try? output.close()};try output.seekToEnd();try output.write(contentsOf:data+Data([10]))
        }catch{setProcessingError((error as? Failure)?.code ?? "cache_transcript_write_failed")}}
        lock.unlock()
    }
    func commitAfterTranscript(_ cursor:Int){
        // Retain the old admission-order contract: a caller may commit a final
        // packet while its accepted PCM is still on the writer queue. This
        // lightweight barrier does no transcript I/O on the audio queue.
        queue.async{[self] in transcriptQueue.async{[self] in
            lock.lock();if cursor>=0,cursor%2==0,cursor<=written,processingError==nil,(error==nil || error=="cache_unclean_shutdown" || error=="cache_writer_backpressure") {asrCommit=max(asrCommit,cursor)};lock.unlock();requestCheckpoint()
        }}
    }
    func committed(_ consumer:String)->Int {lock.lock();defer{lock.unlock()};return consumer=="asr" ? asrCommit:modelCommit}
    func markArchived()throws {wait();lock.lock();guard processingError==nil,Self.transcriptionIsComplete(ended:ended,written:written,committed:asrCommit,error:error) else{lock.unlock();throw Failure(code:"cache_not_complete")};archived=true;lock.unlock();try saveManifest()}
    func audioIsCleaned()->Bool {lock.lock();defer{lock.unlock()};return audioCleaned}
    func markAudioCleaned()throws {lock.lock();guard archived,ended,error==nil,processingError==nil,previousProcessingError==nil,asrCommit>=written else{lock.unlock();throw Failure(code:"cache_not_complete")};audioCleaned=true;lock.unlock();try saveManifest()}
    func eligibleForCleanup()->Bool {lock.lock();defer{lock.unlock()};return archived && !audioCleaned && ended && error==nil && processingError==nil && previousProcessingError==nil && asrCommit>=written}
    func metadata()->[String:Any]{lock.lock();defer{lock.unlock()};return ["written_bytes":written,"offered_bytes":offered,"pending_writer_bytes":pending,"asr_committed_bytes":asrCommit,"model_committed_bytes":modelCommit,"ended":ended,"incomplete":!ended || asrCommit<written || error != nil || processingError != nil,"processing_error":processingError.map{$0 as Any} ?? NSNull(),"cleanup_eligible":archived && ended && error==nil && processingError==nil && previousProcessingError==nil && asrCommit>=written,"disk_capacity_bytes":maxBytes,"disk_near_full":offered>=maxBytes*4/5,"alignment_padding_bytes":alignmentPaddingBytes,"admitted_pcm_bytes":admittedPCMBytes,"padding_counters_known":paddingCountersKnown,"pending_pcm_bytes":pendingPCMBytes,"peak_pending_pcm_bytes":peakPendingPCMBytes,"writer_capacity_bytes":maxPendingPCMBytes,"checkpoint_writes":checkpointWrites]}
}

// Called only after successful user-selected full text export. No active-session
// cleanup, no unrelated directory traversal, no biometric storage.
@discardableResult func archiveAndCleanSession(_ id:String,text:String)throws->Bool {
    guard UUID(uuidString:id) != nil else{throw Failure(code:"cache_scope_invalid")}
    let root=meetingCacheRoot().appendingPathComponent(id)
    return try archiveAndCleanSessionAt(root,text:text)
}
@discardableResult func archiveAndCleanSessionAt(_ root:URL,text:String,retire:((URL)throws->URL)?=nil)throws->Bool {
    let writerLease=try SessionCacheWriterLease.acquire(directory:root)
    defer {writerLease.release()}
    let files=try FileManager.default.contentsOfDirectory(atPath:root.path)
    let tracks=try meetingAudioTracks(in:root)
    guard !tracks.isEmpty else{throw Failure(code:"cache_not_complete")}
    let stores=try tracks.map{try RecordingJournal(directory:root,track:$0)}
    guard stores.allSatisfy({$0.transcriptionIsComplete()}) else{throw Failure(code:"cache_not_complete")}
    if stores.allSatisfy({$0.audioIsCleaned()}) {return true}
    let archive=root.appendingPathComponent("archived-transcript.txt");try text.write(to:archive,atomically:true,encoding:.utf8)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:archive.path)
    for store in stores {try store.markArchived()}
    // A successful retry can archive its text while retaining the original
    // audio and its fault history. Check this before moving any PCM files.
    guard stores.allSatisfy({$0.eligibleForCleanup()}) else{return false}
    let protection=(try? Data(contentsOf:root.appendingPathComponent("audio-retirement.json"))).flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
    if protection?["state"] as? String=="restored",protection?["keep_audio"] as? Bool==true {return false}
    // An earlier archive may already own a recoverable retirement receipt.
    // Keep newly appended PCM in place rather than overwrite that receipt.
    if protection?["state"] as? String=="trashed" {return false}
    let names=files.filter{name in tracks.contains(where:{name.hasPrefix($0+"-")}) && name.range(of:"^(mic(?:-g[1-9][0-9]{0,2})?|remote(?:-g[1-9][0-9]{0,2})?|app-[a-f0-9]{16}(?:-g[1-9][0-9]{0,2})?)-[0-9]{6}\\.pcm$",options:.regularExpression) != nil}
    guard !names.isEmpty else{throw Failure(code:"cache_audio_missing")}
    let stage=root.appendingPathComponent(".audio-retirement-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    var moved:[String]=[]
    do {
        for name in names {try FileManager.default.moveItem(at:root.appendingPathComponent(name),to:stage.appendingPathComponent(name));moved.append(name)}
        let destination:URL
        if let retire=retire {destination=try retire(stage)}else{destination=try retireFixtureAudio(stage,base:root.deletingLastPathComponent(),id:root.lastPathComponent)}
        let receipt:[String:Any]=["schema":1,"cache_id":root.lastPathComponent,"state":"trashed","tracks":tracks,"audio_bytes":stores.reduce(0){$0+$1.bytes()},"destination":destination.path,"recoverable":true,"disk_space_released":false]
        let file=root.appendingPathComponent("audio-retirement.json");try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys]).write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        for store in stores {try store.markAudioCleaned()};return true
    }catch{
        // Before the move to Trash succeeds, restore every staged chunk. Never
        // delete a failure case or touch unrelated paths.
        for name in moved where FileManager.default.fileExists(atPath:stage.appendingPathComponent(name).path) {if !FileManager.default.fileExists(atPath:root.appendingPathComponent(name).path){try? FileManager.default.moveItem(at:stage.appendingPathComponent(name),to:root.appendingPathComponent(name))}}
        if FileManager.default.fileExists(atPath:stage.path),(try? FileManager.default.contentsOfDirectory(atPath:stage.path).isEmpty)==true {try? FileManager.default.removeItem(at:stage)}
        throw error
    }
}
func retireFixtureAudio(_ stage:URL,base:URL,id:String)throws->URL {
    guard UUID(uuidString:id) != nil else{throw Failure(code:"offline_cache_scope_invalid")}
    guard base.standardizedFileURL.path==base.resolvingSymlinksInPath().path,stage.standardizedFileURL.path==stage.resolvingSymlinksInPath().path,stage.deletingLastPathComponent().lastPathComponent==id else{throw Failure(code:"cache_retirement_scope_invalid")}
    let folder=base.appendingPathComponent(".retired");guard folder.standardizedFileURL.path==folder.resolvingSymlinksInPath().path else{throw Failure(code:"cache_retirement_scope_invalid")};try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let destination=folder.appendingPathComponent(id);guard !FileManager.default.fileExists(atPath:destination.path) else{throw Failure(code:"cache_retirement_collision")};try FileManager.default.moveItem(at:stage,to:destination);return destination
}

// Restore only receipt-listed chunks belonging to this UUID. Never overwrite,
// access system Trash or unrelated sessions, or delete the retirement directory.
func restoreRetiredAudioAt(_ root:URL,sessionBase:URL,allowedRetiredBase:URL)throws {
    let fm=FileManager.default;let id=root.lastPathComponent
    guard UUID(uuidString:id) != nil,root.deletingLastPathComponent().standardizedFileURL.path==sessionBase.standardizedFileURL.path,root.standardizedFileURL.path==root.resolvingSymlinksInPath().path else{throw Failure(code:"cache_restore_scope_invalid")}
    let file=root.appendingPathComponent("audio-retirement.json");guard file.path==file.resolvingSymlinksInPath().path else{throw Failure(code:"cache_restore_scope_invalid")};let originalReceipt=try Data(contentsOf:file)
    guard var receipt=try JSONSerialization.jsonObject(with:originalReceipt) as? [String:Any],receipt["schema"] as? Int==1,receipt["cache_id"] as? String==id,["trashed","restored"].contains(receipt["state"] as? String ?? ""),receipt["recoverable"] as? Bool==true,let path=receipt["destination"] as? String,let tracks=receipt["tracks"] as? [String],!tracks.isEmpty,Set(tracks).count==tracks.count,tracks.allSatisfy({isMeetingAudioTrack($0)}) else{throw Failure(code:"cache_restore_receipt_invalid")}
    let alreadyRestored=receipt["state"] as? String=="restored"
    if alreadyRestored {guard receipt["keep_audio"] as? Bool==true,receipt["restored_destination"] as? String==root.path else{throw Failure(code:"cache_restore_receipt_invalid")}}
    let source=URL(fileURLWithPath:path).standardizedFileURL;let base=allowedRetiredBase.standardizedFileURL
    guard source.deletingLastPathComponent().path==base.path,source.path==source.resolvingSymlinksInPath().path,source.path != root.path else{throw Failure(code:"cache_restore_scope_invalid")}
    guard base.path==sessionBase.standardizedFileURL.appendingPathComponent(".retired").path,source.lastPathComponent==id else{throw Failure(code:"cache_restore_scope_invalid")}
    let props=try (alreadyRestored ? root:source).resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);guard props.isDirectory==true,props.isSymbolicLink != true else{throw Failure(code:"cache_restore_scope_invalid")}
    var manifests:[URL:Data]=[:];var updated:[URL:[String:Any]]=[:];var names:[String]=[];var total=0
    for track in tracks {
        let url=root.appendingPathComponent(track+"-manifest.json");guard url.path==url.resolvingSymlinksInPath().path else{throw Failure(code:"cache_restore_scope_invalid")};let data=try Data(contentsOf:url)
        guard var manifest=try JSONSerialization.jsonObject(with:data) as? [String:Any],manifest["schema"] as? Int==1,manifest["track"] as? String==track,manifest["format"] as? String=="pcm_s16le",manifest["channels"] as? Int==1,manifest["sample_rate"] as? Int==16000,manifest["archived"] as? Bool==true,manifest["ended"] as? Bool==true,manifest["audio_cleaned"] as? Bool == !alreadyRestored,let bytes=manifest["written_bytes"] as? Int,bytes>0,bytes<=512*1024*1024,(manifest["asr_committed_bytes"] as? Int ?? -1)>=bytes,let chunks=manifest["chunks"] as? [[String:Any]],!chunks.isEmpty,chunks.count<=2000 else{throw Failure(code:"cache_restore_manifest_invalid")}
        var sum=0
        for (index,chunk) in chunks.enumerated() {
            guard chunk["index"] as? Int==index,chunk["start_sample"] as? Int==sum/2,let length=chunk["bytes"] as? Int,length>0,length<=320000,length%2==0,let hash=chunk["sha256"] as? String else{throw Failure(code:"cache_restore_manifest_invalid")}
            let name=String(format:"%@-%06d.pcm",track,index);let destination=root.appendingPathComponent(name)
            if !alreadyRestored {var existingStat=stat();guard lstat(destination.path,&existingStat) != 0,errno==ENOENT else{throw Failure(code:"cache_restore_conflict")}}
            let pcm=(alreadyRestored ? root:source).appendingPathComponent(name);let attrs=try pcm.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]);guard attrs.isRegularFile==true,attrs.isSymbolicLink != true,attrs.fileSize==length else{throw Failure(code:"cache_restore_chunk_invalid")}
            let original=try Data(contentsOf:pcm);let digest=SHA256.hash(data:original).map{String(format:"%02x",$0)}.joined();guard digest==hash else{throw Failure(code:"cache_restore_hash_mismatch")};sum+=length;names.append(name)
        }
        guard sum==bytes else{throw Failure(code:"cache_restore_manifest_invalid")};total+=bytes;manifests[url]=data;manifest["audio_cleaned"]=false;updated[url]=manifest
    }
    guard total==receipt["audio_bytes"] as? Int else{throw Failure(code:"cache_restore_receipt_invalid")}
    if alreadyRestored {return}
    var moved:[String]=[]
    do {
        for name in names {try fm.moveItem(at:source.appendingPathComponent(name),to:root.appendingPathComponent(name));moved.append(name)}
        for (url,manifest) in updated {try JSONSerialization.data(withJSONObject:manifest,options:.sortedKeys).write(to:url,options:.atomic)}
        receipt["state"]="restored";receipt["keep_audio"]=true;receipt["restored_at"]=Date().timeIntervalSince1970;receipt["restored_destination"]=root.path
        try JSONSerialization.data(withJSONObject:receipt,options:.sortedKeys).write(to:file,options:.atomic)
    }catch{
        // Best-effort rollback preserves every file even if the filesystem fails.
        for (url,data) in manifests {try? data.write(to:url,options:.atomic)};try? originalReceipt.write(to:file,options:.atomic)
        for name in moved where fm.fileExists(atPath:root.appendingPathComponent(name).path) && !fm.fileExists(atPath:source.appendingPathComponent(name).path) {try? fm.moveItem(at:root.appendingPathComponent(name),to:source.appendingPathComponent(name))}
        throw Failure(code:"cache_restore_io_failed_files_preserved")
    }
}
