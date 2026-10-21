import Foundation
import Darwin
import CoreAudio
// No Lane, ASRSocket, URLSession, model or credential exists in this execution path.
func localRecordingMetadata(_ config:Config,id:String)->[String:Any] {
    ["session":config.session,"cache_id":id,"bundle":config.bundle,"mic_enabled":config.useMic,"created_at":Date().timeIntervalSince1970,"capture_mode":"local_only","upload_authorized":false,"asr_destination":"","asr_model":config.model]
}
func writeLocalMetadata(_ config:Config,id:String,directory:URL)throws {
    let path=directory.appendingPathComponent("meeting.json");try JSONSerialization.data(withJSONObject:localRecordingMetadata(config,id:id),options:[.sortedKeys]).write(to:path,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
}
final class LocalRecordingSession {
    let id:String;let directory:URL;let writerLease:SessionCacheWriterLease;let clock:CaptureBudgetClock;var stores:[String:RecordingJournal]=[:];var boxes:[String:Mailbox]=[:]
    init(config:Config,base:URL=meetingCacheRoot())throws {
        try config.validate();guard config.isLocalOnly,config.localRecordingConfirmed==true else{throw Failure(code:"local_recording_not_confirmed")}
        id=config.appendCaptureCacheID ?? UUID().uuidString;directory=base.appendingPathComponent(id)
        if config.appendCaptureCacheID == nil {_ = try prepareMeetingCacheRoot(at:base);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
        writerLease=try SessionCacheWriterLease.acquire(directory:directory)
        let old:[String:Any]
        let tracks:[String]
        if config.appendCaptureCacheID != nil {
            guard let metadata=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("meeting.json"))) as? [String:Any],
                  metadata["session"] as? String==config.session,metadata["bundle"] as? String==config.bundle,
                  metadata["capture_mode"] as? String=="local_only" else{throw Failure(code:"append_capture_scope_invalid")}
            old=metadata;tracks=try meetingAudioTracks(in:directory,transcriptOnly:false)
        } else {old=[:];tracks=[]}
        let existingDirectory=directory
        let reserved=reservedMeetingAudioTracks(in:existingDirectory,metadata:old)
        let continuation=captureContinuation(in:existingDirectory,metadata:old)
        clock=CaptureBudgetClock(zone:continuation.zone,continuationOrigin:config.appendCaptureCacheID == nil ? nil:continuation.origin,continuationElapsed:continuation.elapsed,priorAnchors:continuation.anchors)
        for logical in activeCaptureTracks(bundle:config.bundle,useMic:config.useMic) {
            let track:String
            if config.appendCaptureCacheID == nil && !reserved.contains(logical) {track=logical}
            else {track=(1...999).map{logical+"-g"+String($0)}.first{!reserved.contains($0)} ?? ""}
            guard !track.isEmpty else{throw Failure(code:"source_generation_limit")}
            let store=try RecordingJournal(directory:directory,track:track);stores[logical]=store
            boxes[logical]=Mailbox(captureClock:clock,totalByteLimit:config.unlimitedSession==true ? nil:Int(config.maxSeconds*32000),journal:store)
        }
        if old.isEmpty {try writeLocalMetadata(config,id:id,directory:directory)}
        else if old["archive_only_before_append"] as? Bool != true,
                FileManager.default.fileExists(atPath:directory.appendingPathComponent("archived-transcript.txt").path),
                tracks.filter({isTranscriptAudioTrack($0)}).allSatisfy({track in
                    let file=directory.appendingPathComponent(track+"-transcript.jsonl")
                    return ((try? file.resourceValues(forKeys:[.fileSizeKey]))?.fileSize ?? 0)==0
                }) {
            let prefix=directory.appendingPathComponent("archived-preappend.txt")
            if !FileManager.default.fileExists(atPath:prefix.path) {
                try FileManager.default.copyItem(at:directory.appendingPathComponent("archived-transcript.txt"),to:prefix)
            }
            var metadata=old;metadata["archive_only_before_append"]=true
            try JSONSerialization.data(withJSONObject:metadata,options:[.sortedKeys]).write(to:directory.appendingPathComponent("meeting.json"),options:.atomic)
        }
    }
    func finish(){for box in boxes.values {box.seal()};for store in stores.values {store.wait()}}
}
func runLocalRecording(config:Config)async throws {
    try config.validate();guard config.isLocalOnly,config.localRecordingConfirmed==true,config.resumeCacheID==nil else{throw Failure(code:"local_recording_not_confirmed")}
    guard config.bundle != "*microphone*" || config.useMic else{throw Failure(code:"microphone_mode_requires_mic")}
    guard ["*system*","*microphone*"].contains(config.bundle) || !processes(bundle:config.bundle).isEmpty else{throw Failure(code:"selected_application_not_running")}
    let recorder=try LocalRecordingSession(config:config);let parent=getppid();let id=recorder.id;let clock=recorder.clock;let stores=recorder.stores;let boxes=recorder.boxes
    let mic=Microphone();let tap=ApplicationTap()
    func persistClock(elapsed:Double?=nil)throws {
        let file=recorder.directory.appendingPathComponent("meeting.json")
        var metadata=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        metadata["absolute_clock"]=clock.absoluteClock()
        if let origin=clock.origin() {metadata["capture_origin_uptime"]=origin}
        if let elapsed {metadata["recording_elapsed_seconds"]=elapsed}
        try JSONSerialization.data(withJSONObject:metadata,options:[.sortedKeys]).write(to:file,options:.atomic)
    }
    capturePaused=0;captureControlRevision=0
    signal(SIGINT,interruptHandler);signal(SIGTERM,interruptHandler)
    signal(SIGUSR1,recordingPauseHandler);signal(SIGUSR2,recordingPauseHandler)
    var reason="user_stop";var elapsed=0.0;var paused=false
    var controlAcknowledgement=CaptureControlAcknowledgement()
    var firstPCMDeadline=ProcessInfo.processInfo.systemUptime+5
    var pauseBegan:Double?
    func startHardware() throws {
        if let remote=boxes["remote"] {try tap.start(bundle:config.bundle,micEnabled:config.useMic,box:remote)}
        if let microphone=boxes["mic"] {try mic.start(microphone)}
    }
    func stopHardware() {mic.stop();tap.stop()}
    func applyRecordingControl() throws {
        let requestRevision=captureControlRevision
        let requestedPaused=capturePaused != 0
        guard requestRevision == captureControlRevision else{return}
        if requestedPaused && !paused {
            stopHardware()
            let now=ProcessInfo.processInfo.systemUptime
            clock.pause(at:now);pauseBegan=now;paused=true
        } else if !requestedPaused && paused {
            let now=ProcessInfo.processInfo.systemUptime
            firstPCMDeadline += max(0,now-(pauseBegan ?? now))
            clock.resume(at:now)
            try persistClock()
            try startHardware()
            pauseBegan=nil;paused=false
        }
        if controlAcknowledgement.accept(requestRevision:requestRevision,
                                         requestedPaused:requestedPaused,actualPaused:paused) {
            emit(["type":requestedPaused ? "recording_paused":"recording_resumed",
                  "session":config.session,
                  "control_revision":requestRevision,
                  "absolute_clock":clock.absoluteClock(),
                  "recording_elapsed_seconds":clock.elapsed(ProcessInfo.processInfo.systemUptime),
                  "capture":!requestedPaused,
                  "capture_gate":requestedPaused ? "closed":"open",
                  "upload_gate":requestedPaused ? "draining_saved_audio":"open",
                  "draining_tracks":[]])
        }
    }
    do {
        if capturePaused == 0 { try startHardware() }
        else {
            let now=ProcessInfo.processInfo.systemUptime
            clock.pause(at:now);pauseBegan=now;paused=true
        }
        while clock.origin()==nil && interrupted==0 {
            if getppid() != parent {throw Failure(code:"launcher_exited")}
            try applyRecordingControl()
            if !paused && ProcessInfo.processInfo.systemUptime>=firstPCMDeadline {break}
            for box in boxes.values {try box.checkFault()}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        guard let origin=clock.origin(),interrupted==0 else{throw Failure(code:interrupted>0 ? "user_stopped_before_capture":"no_sound")}
        try persistClock()
        emit(["type":"started","audio_frames_received":true,"session":config.session,"cache_id":id,"mode":"local_only","destination":"local_device","capture_origin_uptime":origin,"absolute_clock":clock.absoluteClock(),"audio_storage":"local_segmented_recoverable","network":false,"append_capture":config.appendCaptureCacheID != nil])
        var last=0.0;var processCheck=0.0
        // Same in-place repair as the cloud capture path: an output-device or
        // helper-PID change rebuilds the application tap instead of ending the
        // recording; only repeated failed rebuilds stop it.
        var tapNeedsRebuild=false;var tapRebuildReason="";var rebuildAttempts=0;var lastRebuildAt: Double = -1000
        func routeChangeReason() throws -> String? {
            if config.bundle != "*system*",processes(bundle:config.bundle) != tap.selectedPIDs {return "selected_application_process_changed"}
            if config.bundle=="*system*",audioObjects(for:selfAudioPIDs()) != tap.excludedAudioObjects {return "self_audio_process_changed"}
            var property=address(kAudioHardwarePropertyDefaultOutputDevice);var output:AudioObjectID=0;var size=UInt32(MemoryLayout<AudioObjectID>.size);try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&property,0,nil,&size,&output),"output_clock_check");return output==tap.outputClock ? nil:"output_device_changed"
        }
        func rebuildApplicationTap(reason:String) throws {
            // The clock keeps running and the microphone keeps recording; only the
            // application track has a short gap while its tap is rebuilt.
            if paused {tapNeedsRebuild=false;return}
            guard let remote=boxes["remote"] else{tapNeedsRebuild=false;return}
            let now=ProcessInfo.processInfo.systemUptime
            if tapNeedsRebuild && now-lastRebuildAt<2 {return}  // give the device time to settle
            if now-lastRebuildAt>30 {rebuildAttempts=0}
            rebuildAttempts+=1;lastRebuildAt=now
            guard rebuildAttempts<=3 else{throw Failure(code:reason)}
            emit(["type":"audio_source","session":config.session,"state":"rerouting","reason":reason,"raw_microphone_retained":true])
            tap.stop()
            do {try tap.start(bundle:config.bundle,micEnabled:config.useMic,box:remote)}
            catch {
                tapNeedsRebuild=true;tapRebuildReason=reason
                emit(["type":"audio_source","session":config.session,"state":"capture_unavailable","reason":reason,"raw_microphone_retained":true])
                return
            }
            tapNeedsRebuild=false
            emit(["type":"audio_source","session":config.session,"state":"capture_recovered","reason":reason])
        }
        while interrupted==0 {
            let now=ProcessInfo.processInfo.systemUptime
            elapsed=clock.elapsed(now)
            if getppid() != parent {reason="launcher_exited";break}
            if config.unlimitedSession != true && elapsed>=config.maxSeconds {reason="local_duration_limit";break}
            for box in boxes.values {try box.checkFault()}
            try applyRecordingControl()
            if tapNeedsRebuild || (!paused && elapsed-processCheck>=0.5 && config.bundle != "*microphone*") {
                if !tapNeedsRebuild {processCheck=elapsed}
                let reason = try tapNeedsRebuild ? tapRebuildReason : routeChangeReason()
                if let reason {try rebuildApplicationTap(reason:reason)}
            }
            if elapsed-last>=1 {last=elapsed;emit(["type":"meter","session":config.session,"elapsed_seconds":elapsed,"estimated_yuan":"0","mode":"local_only","paused":paused])}
            try await Task.sleep(nanoseconds:20_000_000)
        }
    }catch{reason=(error as? Failure)?.code ?? "local_capture_failed"}
    elapsed=clock.elapsed(ProcessInfo.processInfo.systemUptime);stopHardware();recorder.finish();try? persistClock(elapsed:elapsed)
    emit(["type":"capture_stopped","session":config.session,"recording_elapsed_seconds":elapsed,"reason":reason,"capture":false])
    for store in stores.values {store.wait()}
    emit(["type":"meter","elapsed_seconds":elapsed,"estimated_yuan":"0","mode":"local_only"])
    emit(["type":"stopped","session":config.session,"reason":reason,"recording_elapsed_seconds":elapsed,"received_at":elapsed,"transcription_complete":false,"raw_audio_saved":true,"cache_id":id,"mode":"local_only","network":false])
}

func localRecordingFixture(base:URL)async throws->[String:Any] {
    try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
    let firstRunData=base.appendingPathComponent(".first-run-"+UUID().uuidString,isDirectory:true)
    let firstRunBase=firstRunData.appendingPathComponent("SessionCache",isDirectory:true)
    defer {try? FileManager.default.removeItem(at:firstRunData)}
    var ids:[String]=[];var total=0
    for bundle in ["*microphone*","*system*"] {
        let raw:[String:Any]=["session":"local-fixture-"+UUID().uuidString,"bundle":bundle,"key":"","confirmed":true,"maxSeconds":3600,"model":"qwen-audio-3.0-asr-flash-streaming","silenceMS":1300,"micEnabled":true,"localOnly":true,"localRecordingConfirmed":true,"userLaunchConfirmed":true]
        let config=try JSONDecoder().decode(Config.self,from:JSONSerialization.data(withJSONObject:raw));let recorder=try LocalRecordingSession(config:config,base:bundle=="*microphone*" ? firstRunBase:base);ids.append(recorder.id)
        let packet=Data(repeating:0,count:3200)
        let originalStores=recorder.stores
        for index in 0..<35 {for box in recorder.boxes.values {box.put(packet,at:100+Double(index)/10)}}
        precondition(recorder.clock.origin()==100)
        recorder.clock.pause(at:103.5)
        precondition(recorder.clock.isPaused && recorder.clock.elapsed(108)==3.5)
        for box in recorder.boxes.values {box.put(Data(repeating:0x7f,count:3200),at:108)}
        recorder.clock.resume(at:110)
        for index in 0..<35 {for box in recorder.boxes.values {box.put(packet,at:110+Double(index)/10)}}
        precondition(recorder.clock.origin()==100 && recorder.clock.elapsed(113.5)==7)
        precondition(recorder.stores.allSatisfy { originalStores[$0.key] === $0.value })
        recorder.finish()
        for store in recorder.stores.values {precondition(store.bytes()==224000 && store.isEnded() && store.committed("asr")==0);var bytes=Data();var cursor=0;while let (data,_)=try store.read(cursor) {bytes.append(data);cursor+=data.count};precondition(bytes==Data(repeating:0,count:224000));total+=bytes.count}
        let metadata=try JSONSerialization.jsonObject(with:Data(contentsOf:recorder.directory.appendingPathComponent("meeting.json"))) as! [String:Any];precondition(metadata["upload_authorized"] as? Bool==false && metadata["asr_destination"] as? String=="")
        var denied=raw;denied["localRecordingConfirmed"]=false;let bad=try JSONDecoder().decode(Config.self,from:JSONSerialization.data(withJSONObject:denied));var rejected=false;do {try bad.validate()}catch{rejected=true};precondition(rejected)
    }
    let recovered=(try cachedMeetings(in:base)+cachedMeetings(in:firstRunBase)).filter{ids.contains($0.id)};precondition(recovered.count==2 && recovered.allSatisfy{$0.pendingBytes==$0.writtenBytes && !$0.audioCleaned})
    let first=recovered.first(where:{$0.id==ids[0]})!;let metadata=try first.metadata();let config=Config(session:metadata["session"] as! String,bundle:"*microphone*",key:"",confirmed:true,maxSeconds:90,model:"qwen-audio-3.0-asr-flash-streaming",silenceMS:1300,micEnabled:true,localSpeakerDirectory:nil,localEmbeddingModel:nil,userLaunchConfirmed:true)
    var sockets=0;var rejected=false;do {try await resumeCachedMeeting(config:config,id:first.id,base:firstRunBase,factory:{sockets+=1;return FixtureSocket(fail:false)})}catch{rejected=(error as? Failure)?.code=="local_audio_upload_not_confirmed"};precondition(rejected && sockets==0)
    return ["type":"local_recording_fixture","two_isolated_sessions":true,"first_run_cache_root_created":FileManager.default.fileExists(atPath:firstRunBase.path),"mic_and_system_plus_mic_tracks":true,"same_session_pause_resume":true,"paused_audio_excluded":true,"pcm_bytes":total,"recoverable":true,"asr_committed_zero":true,"upload_authorized":false,"unapproved_resume_created_no_socket":true,"no_device_created":true,"cloud_asr":false,"network":false,"keychain":false,"capture":false]
}
