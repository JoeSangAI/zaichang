import Foundation
import CryptoKit
struct CachedMeeting {
    let id:String;let directory:URL;let date:Date;let writtenBytes:Int;let pendingBytes:Int;let occupiedBytes:Int;let tracks:[String];let audioCleaned:Bool;let warning:Bool;let retiredBytes:Int
    var customTitle:String?
    var displayTitle:String {customTitle ?? MeetingLibraryInfo.defaultTitle(date)}
    var durationSeconds=0.0
    var independentCloudBudget=false
    var audioRestored=false
    var retiredLocation:String?
    var recordingMode:String?
    var recoveryStatus:[String:Any]?
    // Populated from every persisted transcript track; synthetic callers may
    // retain the conservative legacy default without inventing a clean capture.
    var savedAudioTranscriptionComplete:Bool?
    var transcriptionComplete:Bool {savedAudioTranscriptionComplete ?? (pendingBytes==0 && !warning)}
    var label:String {let formatter=DateFormatter();formatter.dateFormat="MM-dd HH:mm";return formatter.string(from:date)+" · 待转 "+String(format:"%.1f",Double(pendingBytes)/32000)+" 秒"}
    var details:String {"录音约 "+String(format:"%.1f",durationSeconds)+" 秒 · 待转 "+String(format:"%.1f",Double(pendingBytes)/32000)+" 音频秒 · 本地 "+String(format:"%.1f",Double(occupiedBytes)/1048576)+" MB"+(retiredBytes>0 ? "\n可恢复录音 "+String(format:"%.1f",Double(retiredBytes)/1048576)+" MB；清空后才释放空间":"")+(audioRestored ? "\n录音已恢复":"")+(warning ? "\n上次录音意外中断，内容可能不完整":"")+(recoveryStatus?["state"] as? String=="source_error" ? "\n尾部恢复核验未通过（\(recoveryStatus?["code"] as? String ?? "未知原因")）；原音保留":"")}
    func transcriptHashes()throws->[String:String] {
        var hashes:[String:String]=[:]
        for track in tracks {
            let file=directory.appendingPathComponent(track+"-transcript.jsonl")
            guard FileManager.default.fileExists(atPath:file.path) else{continue}
            let attrs=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard attrs.isRegularFile==true,attrs.isSymbolicLink != true,(attrs.fileSize ?? 0)<=32*1024*1024 else{throw Failure(code:"cache_transcript_invalid")}
            hashes[file.lastPathComponent]=MeetingSpeakerReconciliation.hash(try Data(contentsOf:file))
        }
        return hashes
    }
    func events(includeAutomaticRefinement:Bool=true,includeCoarseRefinement:Bool=true)throws->[[String:Any]] {
        var timeline=TranscriptTimeline();var sourceHashes:[String:String]=[:]
        for track in tracks {
            let file=directory.appendingPathComponent(track+"-transcript.jsonl")
            guard FileManager.default.fileExists(atPath:file.path) else{continue}
            let data=try Data(contentsOf:file);guard data.count<=32*1024*1024 else{throw Failure(code:"cache_transcript_capacity")}
            sourceHashes[file.lastPathComponent]=MeetingSpeakerReconciliation.hash(data)
            let lines=data.split(separator:10)
            for (index,line) in lines.enumerated() {
                guard let event=(try? JSONSerialization.jsonObject(with:Data(line))) as? [String:Any] else {
                    if index==lines.count-1,data.last != 10 {break};throw Failure(code:"cache_transcript_invalid")
                }
                if event["type"] as? String=="asr_replay" {timeline.discard(Set(event["discard_segment_ids"] as? [String] ?? []))}
                else if event["type"] as? String=="segment",let text=event["text"] as? String,text.utf8.count<=2*1024*1024,timeline.accepts(event) {
                    var safe=event;safe.removeValue(forKey:"identity_features");timeline.put(safe)
                }
                guard timeline.records.count<=50_000 else{throw Failure(code:"cache_transcript_capacity")}
            }
        }
        let original=timeline.orderedIDs.compactMap{timeline.records[$0]}
        let legacy=MeetingSpeakerReconciliation.apply(in:directory,cacheID:id,events:original,sourceHashes:sourceHashes)
        let refined=includeAutomaticRefinement ? SpeakerRefinementArtifact.loadApply(events:legacy,sourceHashes:sourceHashes,directory:directory,cacheID:id):legacy
        let projected:[[String:Any]]
        if includeAutomaticRefinement,includeCoarseRefinement,let session=refined.first?["session"] as? String {
            projected=MeetingCoarseRefinement.loadApply(events:refined,directory:directory,session:session,cacheID:id,transcriptHashes:sourceHashes)
        } else {projected=refined}
        let metadata=try self.metadata()
        guard metadata["archive_only_before_append"] as? Bool==true,
              let session=metadata["session"] as? String,
              let archive=try? String(contentsOf:directory.appendingPathComponent("archived-preappend.txt"),encoding:.utf8),
              !archive.isEmpty else{return projected}
        // Capture IDs begin with a UUID. This reserved prefix keeps the saved
        // text before new time-zero speech without inventing its old duration.
        let prelude:[String:Any]=["type":"segment","session":session,"segment_id":"!archive-prelude-"+id,
            "source_id":"mic","track":"mic","epoch":"archive-text-only","start":0.0,"end":0.001,
            "revision":1,"final":true,"end_time_known":true,"text":archive,
            "quality_flags":["archive_text_only"],"speaker":["basis":"unknown","reason":"archive_text_only"]]
        return [prelude]+projected
    }
    func metadata()throws->[String:Any] {let file=directory.appendingPathComponent("meeting.json");guard FileManager.default.fileExists(atPath:file.path) else{return [:]};guard let value=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any] else{throw Failure(code:"cache_manifest_invalid")};return value}
}
func offlineQACacheRoot()->URL {
    if Bundle.main.object(forInfoDictionaryKey:"DevelopmentWorkspace") as? Bool==true {
        // A directly launched QA app should not need Desktop/Documents access
        // merely to enumerate its own synthetic meetings.
        return RuntimeConfiguration.dataRoot().appendingPathComponent("DevelopmentQA/SessionCache")
    }
    return RuntimeConfiguration.dataRoot().appendingPathComponent("OfflineQA/SessionCache")
}
func meetingCacheRoot()->URL {RuntimeConfiguration.dataRoot().appendingPathComponent("SessionCache")}
func prepareMeetingCacheRoot(at root:URL=meetingCacheRoot())throws->URL {
    let fm=FileManager.default,standard=root.standardizedFileURL
    let parent=standard.deletingLastPathComponent()
    if !fm.fileExists(atPath:parent.path) {
        do {try fm.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        catch {guard fm.fileExists(atPath:parent.path) else{throw error}}
    }
    let parentValues=try parent.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
    guard parentValues.isDirectory==true,parentValues.isSymbolicLink != true else{throw Failure(code:"cache_root_parent_invalid")}
    if !fm.fileExists(atPath:standard.path) {
        do {try fm.createDirectory(at:standard,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
        catch {guard fm.fileExists(atPath:standard.path) else{throw error}}
    }
    let values=try standard.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
    guard values.isDirectory==true,values.isSymbolicLink != true else{throw Failure(code:"cache_root_invalid")}
    try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:standard.path)
    return standard
}
func cachedMeetings(in root:URL,recoverInterrupted:Bool=true)throws->[CachedMeeting] {
    guard FileManager.default.fileExists(atPath:root.path) else{return []}
    var result:[CachedMeeting]=[]
    let folders=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey,.creationDateKey],options:[.skipsHiddenFiles])
    for folder in folders where UUID(uuidString:folder.lastPathComponent) != nil {
        let props=try folder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey,.creationDateKey]);guard props.isDirectory==true,props.isSymbolicLink != true else{continue}
        // Manifest-only gate keeps ordinary library refresh cheap. Recovery
        // takes the same exclusive lease as all current capture writers and
        // makes no transcript or network request.
        var recoveryStatus:[String:Any]?
        if recoverInterrupted,sessionCacheMayNeedRecovery(at:folder) {
            do {recoveryStatus=try recoverInterruptedSessionCache(at:folder).json}
            catch {
                let code=(error as? Failure)?.code ?? "cache_recovery_read_failed"
                recoveryStatus=["state":code=="cache_writer_active" ? "writer_active":"source_error","code":code,"audio_files_preserved":true,"gapless_capture_verified":false,"transcription_started":false]
            }
        }
        if recoveryStatus?["state"] as? String=="unchanged" {recoveryStatus=nil}
        if recoverInterrupted,recoveryStatus==nil {
            do {recoveryStatus=try verifiedSessionCacheRecoveryReceipt(at:folder)?.merging(["audio_files_preserved":true,"gapless_capture_verified":false,"transcript_modified":false],uniquingKeysWith:{$1})}
            catch {
                let code=(error as? Failure)?.code ?? "cache_recovery_read_failed"
                recoveryStatus=["state":code=="cache_writer_active" ? "writer_active":"source_error","code":code,"audio_files_preserved":true,"gapless_capture_verified":false,"transcription_started":false]
                if code != "cache_writer_active" {try? markSessionCacheRecoveryDiagnostic(directory:folder,state:"source_error",code:code)}
            }
        }
        if recoveryStatus==nil,let path=try? folder.appendingPathComponent("journal-recovery-diagnostic.json").resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]),path.isRegularFile==true,path.isSymbolicLink != true,(path.fileSize ?? Int.max)<=16*1024,
           let data=try? Data(contentsOf:folder.appendingPathComponent("journal-recovery-diagnostic.json")),let diagnostic=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],diagnostic["schema"] as? Int==1,diagnostic["cache_id"] as? String==folder.lastPathComponent,diagnostic["state"] as? String=="source_error" {recoveryStatus=diagnostic}
        let receipt=(try? Data(contentsOf:folder.appendingPathComponent("audio-retirement.json"))).flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
        let retired=receipt?["schema"] as? Int==1 && receipt?["cache_id"] as? String==folder.lastPathComponent && receipt?["state"] as? String=="trashed"
        let metadata=(try? Data(contentsOf:folder.appendingPathComponent("meeting.json"))).flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
        let captureOrigin=metadata?["capture_origin_uptime"] as? Double
        // A restored or merged folder has a new filesystem birth date; the
        // recording's persisted creation time remains the library chronology.
        let createdAt=metadata?["created_at"] as? Double
        let recordingDate=createdAt.flatMap{$0.isFinite && $0>0 && $0<253402300800 ? Date(timeIntervalSince1970:$0):nil} ?? props.creationDate ?? .distantPast
        var written=0;var pending=0;var duration=0.0;var tracks:[String]=[];var cleaned=true;var warning=false;var transcriptionComplete=true
        for track in try meetingAudioTracks(in:folder) {let file=folder.appendingPathComponent(track+"-manifest.json");guard FileManager.default.fileExists(atPath:file.path) else{continue};guard let value=try? JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any],value["schema"] as? Int==1,value["track"] as? String==track,let bytes=value["written_bytes"] as? Int,bytes>=0,bytes<=512*1024*1024 else{warning=true;transcriptionComplete=false;continue};tracks.append(track);let audioDuration=Double(bytes)/32000;var trackDuration=audioDuration;if let captureOrigin,let trackOrigin=value["origin_uptime"] as? Double,captureOrigin.isFinite,trackOrigin.isFinite,trackOrigin>=captureOrigin,trackOrigin-captureOrigin<=86400 {trackDuration+=trackOrigin-captureOrigin};duration=max(duration,trackDuration);written+=bytes;pending+=max(0,bytes-(value["asr_committed_bytes"] as? Int ?? 0));cleaned=cleaned && (value["audio_cleaned"] as? Bool==true || (retired && (receipt?["tracks"] as? [String] ?? []).contains(track)));warning=warning || value["ended"] as? Bool != true || value["error"] is String || value["processing_error"] is String;transcriptionComplete=transcriptionComplete && !(value["processing_error"] is String) && RecordingJournal.transcriptionIsComplete(ended:value["ended"] as? Bool==true,written:bytes,committed:value["asr_committed_bytes"] as? Int ?? 0,error:value["error"] as? String)}
        if metadata?["audio_sources_complete"] as? Bool==false {warning=true}
        if recoveryStatus?["state"] as? String=="source_error" {warning=true;transcriptionComplete=false}
        guard !tracks.isEmpty else{continue};var occupied=0
        for file in try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey]) {let attrs=try file.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey]);if attrs.isRegularFile==true,attrs.isSymbolicLink != true {occupied+=attrs.fileSize ?? 0}}
        if let elapsed=metadata?["recording_elapsed_seconds"] as? Double,elapsed.isFinite,elapsed>=0,elapsed<=86400 {duration=max(duration,elapsed)}
        let mode=metadata?["capture_mode"] as? String=="local_only" && metadata?["upload_authorized"] as? Bool != true ? "local_only":metadata?["asr_destination"] as? String != nil ? "record_and_transcribe":nil
        result.append(CachedMeeting(id:folder.lastPathComponent,directory:folder,date:recordingDate,writtenBytes:written,pendingBytes:pending,occupiedBytes:occupied,tracks:tracks,audioCleaned:cleaned,warning:warning,retiredBytes:retired ? (receipt?["audio_bytes"] as? Int ?? 0):0,durationSeconds:duration,independentCloudBudget:metadata?["cloud_session_authorized"] as? Bool==true,audioRestored:receipt?["state"] as? String=="restored" && receipt?["keep_audio"] as? Bool==true,retiredLocation:retired ? receipt?["destination"] as? String:nil,recordingMode:mode,recoveryStatus:recoveryStatus,savedAudioTranscriptionComplete:transcriptionComplete));guard result.count<=1000 else{throw Failure(code:"cache_session_capacity")}
        result[result.count-1].customTitle=try? MeetingLibraryInfo.loadTitle(in:folder)
    };return result.sorted{$0.date>$1.date}
}

// Cancellation abandons the result, not a kernel filesystem syscall. At most one
// blocked read exists; retries are rejected until it returns. Never block AppKit.
final class CacheReadJob {
    var busy=false;var waiting:Bool {token != nil};var onStateChange:(()->Void)?;private var token:UUID?;private var deadline:DispatchWorkItem?
    func cancel(){token=nil;deadline?.cancel();onStateChange?()}
    func run<T>(timeout:Double=5,work:@escaping()throws->T,done:@escaping(Result<T,Error>)->Void){
        precondition(Thread.isMainThread)
        guard !busy else{done(.failure(Failure(code:"cache_io_still_waiting")));return}
        busy=true;let id=UUID();token=id;onStateChange?()
        let timer=DispatchWorkItem{[weak self] in guard let self=self,self.token==id else{return};self.token=nil;self.onStateChange?();done(.failure(Failure(code:"cache_io_timeout")))};deadline=timer;DispatchQueue.main.asyncAfter(deadline:.now()+timeout,execute:timer)
        DispatchQueue.global(qos:.userInitiated).async{let result=Result{try work()};DispatchQueue.main.async{self.busy=false;guard self.token==id else{self.onStateChange?();return};self.token=nil;timer.cancel();self.onStateChange?();done(result)}}
    }
}
struct RecoveryPayload {
    let events:[[String:Any]];let metadata:[String:Any];let names:Data?;let archive:String?;let usage:[String:Any]?;let coarseStatus:[String:Any]?
    init(_ item:CachedMeeting)throws {events=try item.events();metadata=try item.metadata();coarseStatus={
            let file=item.directory.appendingPathComponent("coarse-refinement-status.json")
            guard let attrs=try? file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]),
                  attrs.isRegularFile==true,attrs.isSymbolicLink != true,(attrs.fileSize ?? Int.max)<=64*1024,
                  let data=try? Data(contentsOf:file) else{return nil as [String:Any]?}
            return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
        }();let usageFile=item.directory.appendingPathComponent("session-usage.json");usage=(try? Data(contentsOf:usageFile)).flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]};let path=item.directory.appendingPathComponent("session-names.json");names=FileManager.default.fileExists(atPath:path.path) ? try Data(contentsOf:path):nil;archive=item.audioCleaned ? try String(contentsOf:item.directory.appendingPathComponent("archived-transcript.txt"),encoding:.utf8):nil}
}

func cacheFailureMessage(_ error:Error)->String {
    let e=error as NSError
    if e.domain==NSCocoaErrorDomain && e.code==NSFileReadNoPermissionError || e.domain==NSPOSIXErrorDomain && [Int(EACCES),Int(EPERM)].contains(e.code) {return "无法访问会议文件，请检查文件权限"}
    if (error as? Failure)?.code=="cache_io_still_waiting" {return "正在等待文件访问，请处理系统权限提示"}
    if (error as? Failure)?.code=="cache_io_timeout" {return "读取超时，请重试；若持续失败，再检查文件访问权限"}
    return "无法读取会议文件，请重试"
}

struct MeetingLibraryInfo {
    static func defaultTitle(_ date:Date)->String {let f=DateFormatter();f.dateFormat="MM月dd日 HH:mm 会议";return f.string(from:date)}
    static func loadTitle(in folder:URL)throws->String? {
        let path=folder.appendingPathComponent("display-info.json")
        guard FileManager.default.fileExists(atPath:path.path) else{return nil}
        let attributes=try path.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey]);guard attributes.isSymbolicLink != true,(attributes.fileSize ?? 0)<=4096 else{throw Failure(code:"meeting_title_invalid")}
        let data=try Data(contentsOf:path);guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],[1,2].contains(value["schema"] as? Int ?? 0),let title=value["title"] as? String,!title.isEmpty,title.count<=80 else{throw Failure(code:"meeting_title_invalid")}
        if value["schema"] as? Int==2 {let metadata=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("meeting.json"))) as? [String:Any];guard value["cache_id"] as? String==folder.lastPathComponent,value["session"] as? String==metadata?["session"] as? String else{throw Failure(code:"meeting_title_scope")}}
        return title
    }
    static func saveTitle(_ title:String,in folder:URL)throws {
        let attributes=try folder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);guard attributes.isDirectory==true,attributes.isSymbolicLink != true,UUID(uuidString:folder.lastPathComponent) != nil else{throw Failure(code:"meeting_title_scope")}
        let normalized=String(title.trimmingCharacters(in:.whitespacesAndNewlines).prefix(80));guard !normalized.isEmpty else{throw Failure(code:"meeting_title_invalid")}
        let path=folder.appendingPathComponent("display-info.json");if FileManager.default.fileExists(atPath:path.path),try path.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink==true {throw Failure(code:"meeting_title_scope")}
        try JSONSerialization.data(withJSONObject:["schema":1,"title":normalized],options:[.sortedKeys]).write(to:path,options:.atomic)
    }
}

// Derived annotations remain reversible and cannot change provider text, PCM,
// clock or manual names. A source/model mismatch restores the original evidence
// with a visible warning; it never prevents reading the saved transcript.
enum MeetingSpeakerReconciliation {
    // Exact installed Nemotron low CoreML tree (four relative file/hash pairs,
    // sorted JSON). Word-context corrections use diarization, not embeddings.
    static let diarizationModelHash="a4fb04337562b6097324a4aa4c2531f94fcf2079c9551b8b3896942a99fb8cf3"
    static let diarizationDescriptor="nemotron3-low:25a90f97f254428d4b30374b76af9c74fdee8327"
    static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func apply(in directory:URL,cacheID:String,events:[[String:Any]],sourceHashes:[String:String])->[[String:Any]] {
        let file=directory.appendingPathComponent("speaker-reconciliation.json")
        guard FileManager.default.fileExists(atPath:file.path) else{return events}
        do {
            let attrs=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey])
            guard attrs.isSymbolicLink != true,(attrs.fileSize ?? 0)<=2*1024*1024 else{throw Failure(code:"speaker_reconciliation_invalid")}
            let data=try Data(contentsOf:file)
            let object=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            guard let object=object,object["schema"] as? Int==1,object["cache_id"] as? String==cacheID,
                  let session=object["session"] as? String,events.allSatisfy({$0["session"] as? String==session}),
                  object["source_sha256"] as? [String:String]==sourceHashes,
                  ((object["model_kind"] == nil && object["model_sha256"] as? String==SpeakerEmbeddingBackend.modelHash) ||
                   (object["model_kind"] as? String=="nemotron3-low" && object["model_sha256"] as? String==diarizationModelHash &&
                    object["method"] as? String=="timed_word_context_v1")),
                  let rawRoster=object["roster"] as? [[String:Any]],(1...8).contains(rawRoster.count),
                  let rawRecords=object["records"] as? [[String:Any]],rawRecords.count<=50_000 else{throw Failure(code:"speaker_reconciliation_invalid")}
            let roster=try rawRoster.map {try JSONDecoder().decode(SessionSpeakerKey.self,from:JSONSerialization.data(withJSONObject:$0))}
            guard Set(roster).count==roster.count,roster.allSatisfy({$0.session==session && isTranscriptAudioTrack($0.source) && !$0.epoch.isEmpty && $0.epoch.count<=160}) else{throw Failure(code:"speaker_reconciliation_invalid")}
            let namesData=try Data(contentsOf:directory.appendingPathComponent("session-names.json"))
            guard let names=try JSONSerialization.jsonObject(with:namesData) as? [String:Any],names["session"] as? String==session,
                  let named=names["speakers"] as? [[String:Any]] else{throw Failure(code:"speaker_reconciliation_invalid")}
            let namedKeys=Set(try named.map {row -> SessionSpeakerKey in
                guard let key=row["key"] as? [String:Any] else{throw Failure(code:"speaker_reconciliation_invalid")}
                return try JSONDecoder().decode(SessionSpeakerKey.self,from:JSONSerialization.data(withJSONObject:key))
            })
            guard Set(roster).isSubset(of:namedKeys) else{throw Failure(code:"speaker_reconciliation_invalid")}
            func validSpeaker(_ speaker:[String:Any],event:[String:Any])->Bool {
                var leaf=event;leaf["speaker"]=speaker
                switch speaker["basis"] as? String {
                case "anonymous_cluster","meeting_reconciliation":return SessionSpeakerKey.from(leaf).map{roster.contains($0)} ?? false
                case "unknown","multiple":return true
                default:return false
                }
            }
            let originals=Dictionary(uniqueKeysWithValues:events.compactMap{e in (e["segment_id"] as? String).map{($0,e)}})
            var replacements:[String:[String:Any]]=[:]
            for record in rawRecords {
                guard let id=record["segment_id"] as? String,replacements[id]==nil,let original=originals[id],
                      original["final"] as? Bool==true,original["end_time_known"] as? Bool==true,
                      record["revision"] as? Int==original["revision"] as? Int,
                      let text=original["text"] as? String,
                      record["text_sha256"] as? String==hash(Data(text.utf8)),
                      let start=original["start"] as? Double,let end=original["end"] as? Double,
                      record["start"] as? Double==start,record["end"] as? Double==end,
                      let speaker=record["speaker"] as? [String:Any],validSpeaker(speaker,event:original),
                      let runs=record["speaker_runs"] as? [[String:Any]],!runs.isEmpty,runs.count<=1000 else{throw Failure(code:"speaker_reconciliation_invalid")}
                if object["model_kind"] as? String=="nemotron3-low" {
                    guard original["local_speaker_model"] as? String==diarizationDescriptor else{throw Failure(code:"speaker_reconciliation_invalid")}
                }
                var joined="";var cursor=start
                // Preserve actual provider boundaries; the correction cannot
                // introduce new word cuts, omit characters or move a timestamp.
                let originalRuns=original["speaker_runs"] as? [[String:Any]] ?? [original]
                guard runs.count==originalRuns.count else{throw Failure(code:"speaker_reconciliation_invalid")}
                for (run,prior) in zip(runs,originalRuns) {
                    guard let lo=run["start"] as? Double,let hi=run["end"] as? Double,
                          lo.isFinite,hi.isFinite,lo>=cursor-0.001,hi>lo,hi<=end+0.001,
                          lo==prior["start"] as? Double,hi==prior["end"] as? Double,
                          let body=run["text"] as? String,body==prior["text"] as? String,
                          let who=run["speaker"] as? [String:Any],validSpeaker(who,event:original) else{throw Failure(code:"speaker_reconciliation_invalid")}
                    joined+=body;cursor=hi
                }
                guard joined==text else{throw Failure(code:"speaker_reconciliation_invalid")}
                var replacement=original;replacement["speaker"]=speaker
                if runs.count>1 {replacement["speaker_runs"]=runs}else{replacement.removeValue(forKey:"speaker_runs")}
                replacement["speaker_reconciliation_applied"]=true;replacements[id]=replacement
            }
            return events.map{replacements[$0["segment_id"] as? String ?? ""] ?? $0}
        } catch {
            var result=events
            if !result.isEmpty {result[0]["speaker_reconciliation_warning"]="人物修正已失效，已恢复原始识别；原音和文字保留"}
            return result
        }
    }
}
