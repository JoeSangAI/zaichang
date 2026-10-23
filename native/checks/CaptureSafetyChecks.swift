import Foundation
import AVFoundation
import Darwin

private final class CaptureFixtureWriterGate {
    private let lock=NSLock();private let released=DispatchSemaphore(value:0);private var blocked=false
    func block(){lock.lock();blocked=true;lock.unlock()}
    func waitIfBlocked(){lock.lock();let shouldWait=blocked;lock.unlock();if shouldWait{released.wait()}}
    func open(){lock.lock();blocked=false;lock.unlock();released.signal()}
}
private final class CaptureFixtureAsyncGate {
    private let lock=NSLock();private var continuation:CheckedContinuation<Bool,Never>?;private var released=false
    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {lock.unlock();continuation.resume(returning:true)}
            else {self.continuation=continuation;lock.unlock()}
        }
    }
    func isWaiting()->Bool {lock.lock();defer{lock.unlock()};return continuation != nil}
    func open(){lock.lock();released=true;let waiting=continuation;continuation=nil;lock.unlock();waiting?.resume(returning:true)}
}
private final class CaptureFixtureSocketInventory {
    private let lock=NSLock();private var sockets:[FixtureSocket]=[]
    func make()->ASRSocket {let socket=FixtureSocket(fail:false);lock.lock();sockets.append(socket);lock.unlock();return socket}
    func count()->Int {lock.lock();defer{lock.unlock()};return sockets.count}
    func socket(_ index:Int)->FixtureSocket? {lock.lock();defer{lock.unlock()};return index>=0 && index<sockets.count ? sockets[index]:nil}
}
private final class CaptureFixtureTickCounter {
    private let lock=NSLock();private var value=0;private var claimed=Set<Int>()
    func tick(){lock.lock();value+=1;lock.unlock()}
    func count()->Int{lock.lock();defer{lock.unlock()};return value}
    func claim(_ revision:Int)->Bool{lock.lock();defer{lock.unlock()};return claimed.insert(revision).inserted}
}

// Runs in a separate, real helper process. The Python integration test owns
// the inherited datagram socket and sends OS signals through CaptureSupervisor;
// only PCM production is synthetic, so this fixture never opens CoreAudio or
// an ASR/network connection.
func runCaptureControlProtocolFixture(directory:URL,session:String,ackFD:Int32)throws {
    guard Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true,
          let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,
          UUID(uuidString:session) != nil,
          directory.standardizedFileURL.path.hasPrefix(root+"/.runtime/capture-protocol-fixtures/") else {
        throw Failure(code:"capture_protocol_fixture_scope")
    }
    captureControlAckFD=try configureControlAcknowledgementDescriptor(ackFD)
    interrupted=0;capturePaused=0;captureUploadPaused=0;captureHardwareReady=1
    captureFinishing=0;captureTailDrainAllowed=0;captureControlRevision=0
    capturePauseAcknowledgedRevision = -1
    let store=try RecordingJournal(directory:directory,track:"mic-raw",freeSpace:{1_000_000_000})
    let writer=Mailbox(journal:store)
    let pcm=Data(repeating:0x31,count:3200)
    signal(SIGINT,interruptHandler);signal(SIGTERM,interruptHandler)
    signal(SIGUSR1,recordingPauseHandler);signal(SIGUSR2,recordingPauseHandler)
    signal(SIGWINCH,recordingFinishHandler)
    let ackState=CaptureFixtureTickCounter()
    let monitor=CapturePauseAcknowledgementMonitor {
        guard interrupted==0,captureFinishing==0,capturePaused != 0 else{return}
        let revision=captureControlRevision
        // Each pause revision is acknowledged once after the OS signal closed
        // capture admission. Hardware teardown is a no-op in this fixture.
        guard !captureAdmissionOpen(),captureHardwareReady==0,captureUploadPaused==0 else{return}
        let inventory=store.metadata()
        guard (inventory["pending_writer_bytes"] as? Int ?? 0)==0 else{return}
        guard ackState.claim(Int(revision)) else{return}
        emit(["type":"recording_paused","session":session,"capture":false,
              "capture_gate":"closed","upload_gate":"draining_saved_audio",
              "control_revision":revision,"draining_tracks":[],"hardware_teardown":"complete",
              "fixture_written_bytes":store.bytes()])
        capturePauseAcknowledgedRevision=revision
        ackState.tick()
    }
    defer {monitor.cancel();captureControlAckFD = -1}
    _=writeCapturedPCMIfAdmitted(pcm,at:ProcessInfo.processInfo.systemUptime,to:writer)
    store.wait()
    emit(["type":"started","session":session,"cache_id":directory.lastPathComponent,
          "capture":true,"fixture":true,"network":false,"fixture_written_bytes":store.bytes()])
    var locallyPaused=false
    var controlAcknowledgement=CaptureControlAcknowledgement()
    let deadline=ProcessInfo.processInfo.systemUptime+120
    while ProcessInfo.processInfo.systemUptime<deadline {
        if captureFinishing != 0 {
            monitor.cancel()
            store.wait()
            store.finish()
            store.wait()
            emit(["type":"capture_stopped","session":session,"reason":"user_finish",
                  "recording_elapsed_seconds":0,"capture":false,"processing_pending":false,
                  "fixture_written_bytes":store.bytes()])
            emit(["type":"stopped","session":session,"cache_id":directory.lastPathComponent,
                  "reason":"user_finish","transcription_complete":true,"raw_audio_saved":true,
                  "capture":false,"network":false,"fixture_written_bytes":store.bytes()])
            return
        }
        if interrupted != 0 {
            monitor.cancel();store.wait();store.finish();store.wait()
            emit(["type":"stopped","session":session,"cache_id":directory.lastPathComponent,
                  "reason":"user_stop","transcription_complete":false,"raw_audio_saved":true,
                  "capture":false,"network":false,"fixture_written_bytes":store.bytes()])
            return
        }
        let revision=captureControlRevision
        let requestedPaused=capturePaused != 0
        if requestedPaused {
            locallyPaused=true
            // Leave the writer open and the cache recoverable for same-process
            // resume. Wait for the monitor's gate-validated ACK before the
            // next outer turn can report an acknowledged pause.
        } else if locallyPaused {
            // Simulate completed hardware reinstallation, then require a fresh
            // synthetic PCM packet before returning the resume ACK.
            captureHardwareReady=1
            guard captureAdmissionOpen() else{Thread.sleep(forTimeInterval:0.005);continue}
            _=writeCapturedPCMIfAdmitted(pcm,at:ProcessInfo.processInfo.systemUptime,to:writer)
            store.wait()
            guard revision==captureControlRevision,capturePaused==0,captureFinishing==0,
                  controlAcknowledgement.accept(requestRevision:revision,requestedPaused:false,actualPaused:false) else {
                captureHardwareReady=0;Thread.sleep(forTimeInterval:0.005);continue
            }
            locallyPaused=false
            emit(["type":"recording_resumed","session":session,"control_revision":revision,
                  "capture":true,"capture_gate":"open","upload_gate":"open",
                  "hardware_teardown":"complete","fresh_synthetic_pcm":true,
                  "fixture_written_bytes":store.bytes()])
        } else if !requestedPaused {
            _=writeCapturedPCMIfAdmitted(pcm,at:ProcessInfo.processInfo.systemUptime,to:writer)
        }
        _=controlAcknowledgement.accept(requestRevision:revision,requestedPaused:requestedPaused,
                                        actualPaused:locallyPaused)
        Thread.sleep(forTimeInterval:0.01)
    }
    monitor.cancel();throw Failure(code:"capture_protocol_fixture_timeout")
}

// Pure fixture for the pause safety contract. Uses only synthetic PCM and the
// protocol FakeSocket; it never asks for audio permission or opens a network.
func captureSafetyChecks(directory:URL) async throws->[String:Any] {
    guard Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true,
          let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,
          directory.standardizedFileURL.path.hasPrefix(root+"/.runtime/") else {
        throw Failure(code:"capture_safety_fixture_scope")
    }
    let oldPaused=capturePaused,oldUploadPaused=captureUploadPaused,oldInterrupted=interrupted,oldHardware=captureHardwareReady,oldFinishing=captureFinishing,oldTail=captureTailDrainAllowed,oldPauseAck=capturePauseAcknowledgedRevision,oldRevision=captureControlRevision
    let oldControlAckFD=captureControlAckFD
    defer {capturePaused=oldPaused;captureUploadPaused=oldUploadPaused;interrupted=oldInterrupted;captureHardwareReady=oldHardware;captureFinishing=oldFinishing;captureTailDrainAllowed=oldTail;capturePauseAcknowledgedRevision=oldPauseAck;captureControlRevision=oldRevision}
    defer {captureControlAckFD=oldControlAckFD}
    interrupted=0;capturePaused=0;captureUploadPaused=0;captureHardwareReady=1;captureFinishing=0;captureTailDrainAllowed=0;capturePauseAcknowledgedRevision = -1;captureControlRevision=0
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    var checks:[String]=[]
    // Match the observed failure: the auxiliary raw track has a new chunk
    // whose on-disk manifest still says zero bytes while PCM has been written.
    do {
        let cache=directory.appendingPathComponent(UUID().uuidString)
        let raw=try RecordingJournal(directory:cache,track:"mic-raw",freeSpace:{1_000_000_000})
        let expected=320_000+121_732
        var offered=0
        while offered<expected {
            let count=min(3200,expected-offered)
            try raw.enqueue(Data(repeating:0x24,count:count),at:100+Double(offered)/32000)
            offered+=count
        }
        let until=ProcessInfo.processInfo.systemUptime+2
        while (raw.metadata()["pending_writer_bytes"] as? Int ?? 0)>0 && ProcessInfo.processInfo.systemUptime<until {try await Task.sleep(nanoseconds:1_000_000)}
        guard raw.bytes()==expected else{throw Failure(code:"pause_raw_fixture_write_timeout")}
        let manifestFile=cache.appendingPathComponent("mic-raw-manifest.json")
        let stale=try JSONSerialization.jsonObject(with:Data(contentsOf:manifestFile)) as! [String:Any]
        guard (stale["chunks"] as? [[String:Any]])?.last?["bytes"] as? Int==0 else{throw Failure(code:"pause_raw_fixture_not_stale")}
        let pcmFile=cache.appendingPathComponent("mic-raw-000001.pcm"),before=try Data(contentsOf:pcmFile)
        do {
            _=try SpeakerRefinementArtifact.snapshotSHA256(directory:cache,cacheID:cache.lastPathComponent,includeAuxiliaryAudio:true)
            throw Failure(code:"pause_stale_snapshot_accepted")
        } catch SpeakerRefinementArtifactError.invalidSnapshot { }
        let transition=CapturePauseTransition()
        finishCapturePauseWriter(raw,transition:transition,stop:{})
        transition.finishHardwarePart(nil);transition.finishHardwarePart(nil);transition.finishUploadDrain()
        let settled=try JSONSerialization.jsonObject(with:Data(contentsOf:manifestFile)) as! [String:Any]
        let first=try SpeakerRefinementArtifact.snapshotSHA256(directory:cache,cacheID:cache.lastPathComponent,includeAuxiliaryAudio:true)
        guard transition.snapshot().hardwareDone,transition.snapshot().failure==nil,
              settled["ended"] as? Bool==false,settled["written_bytes"] as? Int==expected,
              (settled["chunks"] as? [[String:Any]])?.last?["bytes"] as? Int==121732,
              try Data(contentsOf:pcmFile)==before else{throw Failure(code:"pause_raw_checkpoint_failed")}
        // A stable unsealed last chunk is allowed; corrupt lengths remain an
        // error. Never repair a snapshot by editing the recording under it.
        try (before+Data([0x24,0x24])).write(to:pcmFile)
        do {
            _=try SpeakerRefinementArtifact.snapshotSHA256(directory:cache,cacheID:cache.lastPathComponent,includeAuxiliaryAudio:true)
            throw Failure(code:"pause_corrupt_snapshot_accepted")
        } catch SpeakerRefinementArtifactError.invalidSnapshot { }
        try before.write(to:pcmFile)
        guard try SpeakerRefinementArtifact.snapshotSHA256(directory:cache,cacheID:cache.lastPathComponent,includeAuxiliaryAudio:true)==first else{throw Failure(code:"pause_snapshot_not_stable")}
        try raw.enqueue(Data(repeating:0x25,count:3200),at:100+Double(expected)/32000)
        raw.finish();raw.wait()
        guard raw.bytes()==expected+3200,try Data(contentsOf:pcmFile).prefix(before.count)==before else{throw Failure(code:"pause_resume_overwrote_raw_audio")}
        checks.append("pause_checkpoints_raw_tail_before_snapshot_preserves_pcm_and_resume_rejects_corruption")
    }
    _=try captureContinuityRegression(directory:directory)
    checks.append("journal_detects_periodic_short_audio_deficits_preserves_prefix_and_accepts_valid_rates_and_source_absence")
    _=try applicationTapFormatRegression()
    checks.append("aggregate_input_rate_prevents_periodic_two_thirds_padding_and_clock_change_is_rejected")
    var unlimited=Config(session:"unlimited-fixture",bundle:"*microphone*",key:"synthetic",confirmed:true,maxSeconds:7200,model:"qwen-audio-3.0-asr-flash-streaming",silenceMS:1300,micEnabled:true,localSpeakerDirectory:nil,localEmbeddingModel:nil,userLaunchConfirmed:true)
    unlimited.cloudSessionConfirmed=true;unlimited.unlimitedSession=true
    try unlimited.validate()
    var unapproved=unlimited;unapproved.cloudSessionConfirmed=false
    do {try unapproved.validate();throw Failure(code:"unlimited_scope_not_checked")}catch let error as Failure {guard error.code=="invalid_unlimited_scope" else{throw error}}
    let unlimitedMailbox=Mailbox(totalByteLimit:nil)
    precondition(unlimitedMailbox.totalByteLimit==nil)
    checks.append("unlimited_recording_keeps_explicit_launch_and_cloud_scope_without_pcm_duration_cap")
    let sessionDirectory=directory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:sessionDirectory,withIntermediateDirectories:false)

    let sealingLease=try SessionCacheWriterLease.acquire(directory:sessionDirectory)
    let releaseSealing=Task {try await Task.sleep(nanoseconds:100_000_000);sealingLease.release()}
    let recoveryLease=try await SessionCacheWriterLease.acquireForRecovery(directory:sessionDirectory,timeout:1)
    try await releaseSealing.value
    do {
        _ = try await SessionCacheWriterLease.acquireForRecovery(directory:sessionDirectory,timeout:0.05)
        throw Failure(code:"recovery_lease_timeout_not_checked")
    } catch let error as Failure {guard error.code=="cache_writer_active" else{throw error}}
    let cancelledLease=Task {try await SessionCacheWriterLease.acquireForRecovery(directory:sessionDirectory,timeout:1)}
    cancelledLease.cancel()
    do {_ = try await cancelledLease.value;throw Failure(code:"recovery_lease_cancellation_not_checked")}
    catch is CancellationError {}
    recoveryLease.release()
    checks.append("saved_tail_waits_for_sealing_lease_with_timeout_and_cancellation")

    let nestedFeatureJournal=try RecordingJournal(directory:sessionDirectory,track:"remote",freeSpace:{1_000_000_000})
    let featureEvent:[String:Any]=["type":"segment","text":"完整原文","identity_features":["values":[0.5]],"speaker_runs":[["text":"完整原文","speaker":["basis":"anonymous_cluster","cluster_id":0],"identity_features":["values":[0.5]]]]]
    nestedFeatureJournal.record(featureEvent);nestedFeatureJournal.wait()
    let savedFeatureText=try String(contentsOf:sessionDirectory.appendingPathComponent("remote-transcript.jsonl"),encoding:.utf8)
    precondition(!savedFeatureText.contains("identity_features") && savedFeatureText.contains("完整原文") && savedFeatureText.contains("anonymous_cluster"))
    checks.append("parent_and_child_voice_features_never_enter_transcript_log")

    let clock=CaptureBudgetClock()
    let journal=try RecordingJournal(directory:sessionDirectory,track:"mic-raw",freeSpace:{1_000_000_000})
    let writer=Mailbox(captureClock:clock,totalByteLimit:320_000,journal:journal)
    let pcm=Data(repeating:0x37,count:3_200)
    precondition(writeCapturedPCMIfAdmitted(pcm,at:100,to:writer))
    journal.wait();let before=journal.bytes();precondition(before==pcm.count)
    // This is the same signal-visible state set by SIGUSR1. It must close
    // producer admission before the capture loop or tap teardown can run.
    recordingPauseHandler(SIGUSR1);clock.pause(at:100.1)
    precondition(!captureAdmissionOpen() && !writeCapturedPCMIfAdmitted(pcm,at:100.1,to:writer))
    precondition(captureUploadPaused==0)
    journal.wait();precondition(journal.bytes()==before && abs(clock.elapsed(101)-0.1)<0.001)
    captureHardwareReady=0;recordingPauseHandler(SIGUSR2)
    precondition(!captureAdmissionOpen() && !writeCapturedPCMIfAdmitted(pcm,at:101,to:writer))
    clock.resume(at:101);captureHardwareReady=1
    precondition(captureAdmissionOpen() && writeCapturedPCMIfAdmitted(pcm,at:101,to:writer))
    writer.seal();journal.wait();precondition(journal.bytes()==before+pcm.count && journal.fault()==nil)
    checks.append("signal_and_hardware_latches_close_pcm_admission_before_teardown")

    // The production pause monitor must keep firing while its caller is
    // synchronously blocked; it no longer needs a Swift Task executor thread.
    let pauseTicks=CaptureFixtureTickCounter()
    let pauseMonitor=CapturePauseAcknowledgementMonitor{pauseTicks.tick()}
    Thread.sleep(forTimeInterval:0.04)
    pauseMonitor.cancel()
    precondition(pauseTicks.count()>=2)
    checks.append("pause_ack_timer_runs_independently_while_caller_is_blocked_and_cancels")

    // Exercise the production `emit` path with real local datagram sockets.
    // The ACK is a single packet, including inventories larger than 512 bytes.
    func makeSocketPair() throws -> (read:Int32,write:Int32) {
        var descriptors=[Int32](repeating:-1,count:2)
        let result=descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.socketpair(AF_UNIX, SOCK_DGRAM, 0, buffer.baseAddress!)
        }
        guard result==0 else{throw Failure(code:"control_ack_fixture_socket_create")}
        return(descriptors[0],descriptors[1])
    }
    do {
        _=try configureControlAcknowledgementDescriptor(Int32.max)
        throw Failure(code:"control_ack_fixture_invalid_fd_accepted")
    } catch let error as Failure {
        guard error.code=="control_ack_descriptor_invalid" else{throw error}
    }
    let notPipeURL=sessionDirectory.appendingPathComponent("control-ack-not-pipe")
    let notPipe=open(notPipeURL.path,O_CREAT|O_WRONLY,0o600)
    guard notPipe>=0 else{throw Failure(code:"control_ack_fixture_file_create")}
    defer { _=Darwin.close(notPipe) }
    do {
        _=try configureControlAcknowledgementDescriptor(notPipe)
        throw Failure(code:"control_ack_fixture_non_socket_accepted")
    } catch let error as Failure {
        guard error.code=="control_ack_descriptor_invalid" else{throw error}
    }
    let validSocket=try makeSocketPair()
    defer {_=Darwin.close(validSocket.read);_=Darwin.close(validSocket.write)}
    captureControlAckFD=try configureControlAcknowledgementDescriptor(validSocket.write)
    let flags=fcntl(validSocket.write,F_GETFL)
    precondition(flags>=0 && flags&O_NONBLOCK != 0)
    capturePaused=0;captureUploadPaused=0;captureHardwareReady=1;captureFinishing=0;interrupted=0
    captureControlRevision=40;capturePauseAcknowledgedRevision = -1
    recordingPauseHandler(SIGUSR1)
    precondition(capturePaused != 0 && captureHardwareReady==0 && captureUploadPaused==0)
    let manyTracks=(0..<32).map{"remote-generation-\($0)-source"}
    let controlAck:[String:Any]=["type":"recording_paused","session":"capture-safety-ack",
        "capture":false,"capture_gate":"closed","upload_gate":"draining_saved_audio",
        "control_revision":captureControlRevision,"draining_tracks":manyTracks]
    let encodedLargeAck=try JSONSerialization.data(withJSONObject:controlAck,options:[.sortedKeys])
    precondition(encodedLargeAck.count>512 && encodedLargeAck.count<=4096)
    let emitReturned=DispatchSemaphore(value:0)
    outputLock.lock()
    var outputLockHeld=true
    defer {if outputLockHeld {outputLock.unlock()}}
    DispatchQueue.global(qos:.userInitiated).async {emit(controlAck);emitReturned.signal()}
    var readPoll=pollfd(fd:validSocket.read,events:Int16(POLLIN),revents:0)
    let readable=poll(&readPoll,1,500)==1 && readPoll.revents & Int16(POLLIN) != 0
    let returnedWhileOutputLocked=emitReturned.wait(timeout: .now() + 0.2) == .success
    outputLock.unlock();outputLockHeld=false
    guard readable,returnedWhileOutputLocked else{throw Failure(code:"control_ack_blocked_by_output_lock")}
    var frame=[UInt8](repeating:0,count:4097)
    let count=frame.withUnsafeMutableBytes { Darwin.recv(validSocket.read,$0.baseAddress,$0.count,0) }
    guard count>512,let decoded=try JSONSerialization.jsonObject(with:Data(frame.prefix(count))) as? [String:Any] else {
        throw Failure(code:"control_ack_fixture_frame_invalid")
    }
    precondition(decoded["control_revision"] as? Int == Int(captureControlRevision) && decoded["capture_gate"] as? String=="closed" && (decoded["draining_tracks"] as? [String])?.count==manyTracks.count)
    checks.append("real_emit_routes_over_512_byte_gate_closed_ack_datagram_around_locked_stdout")

    let fullSocket=try makeSocketPair()
    defer {_=Darwin.close(fullSocket.read);_=Darwin.close(fullSocket.write)}
    captureControlAckFD=try configureControlAcknowledgementDescriptor(fullSocket.write)
    var filler=[UInt8](repeating:0x5a,count:512),packetCount=0
    while packetCount<2048 {
        let sent=filler.withUnsafeBytes { Darwin.send(fullSocket.write,$0.baseAddress,$0.count,MSG_DONTWAIT) }
        if sent>0 {packetCount+=1;continue}
        precondition(errno==EAGAIN || errno==EWOULDBLOCK || errno==ENOBUFS)
        break
    }
    precondition(packetCount>0 && packetCount<2048 && fcntl(fullSocket.write,F_GETFL)&O_NONBLOCK != 0)
    var fallbackPipe=[Int32](repeating:-1,count:2)
    guard Darwin.pipe(&fallbackPipe)==0 else{throw Failure(code:"control_ack_fixture_stdout_pipe")}
    let savedStdout=dup(STDOUT_FILENO)
    guard savedStdout>=0,dup2(fallbackPipe[1],STDOUT_FILENO)>=0 else{throw Failure(code:"control_ack_fixture_stdout_redirect")}
    _=Darwin.close(fallbackPipe[1])
    let fullSocketStart=ProcessInfo.processInfo.systemUptime
    emit(controlAck)
    let fullSocketElapsed=ProcessInfo.processInfo.systemUptime-fullSocketStart
    let stdoutRestored=dup2(savedStdout,STDOUT_FILENO)>=0
    _=Darwin.close(savedStdout)
    let fallbackData=FileHandle(fileDescriptor:fallbackPipe[0],closeOnDealloc:false).readDataToEndOfFile()
    _=Darwin.close(fallbackPipe[0])
    guard stdoutRestored,fullSocketElapsed<0.2,
          let fallbackEvent=try? JSONSerialization.jsonObject(with:Data(fallbackData.dropLast())) as? [String:Any],
          fallbackEvent["type"] as? String=="recording_paused",
          fallbackEvent["control_revision"] as? Int==Int(captureControlRevision) else{
        throw Failure(code:"control_ack_full_socket_stdout_fallback")
    }
    checks.append("full_nonblocking_ack_socket_falls_back_to_complete_stdout_event")

    let config=Config(session:"capture-safety",bundle:"*system*",key:"fixture-key",confirmed:true,
                      maxSeconds:450,model:"qwen-audio-3.0-asr-flash-streaming",silenceMS:1300,
                      micEnabled:true,localSpeakerDirectory:nil,localEmbeddingModel:nil,userLaunchConfirmed:true)

    recordingFinishHandler(SIGWINCH)
    let finishRevision=captureControlRevision
    recordingPauseHandler(SIGUSR1)
    precondition(captureFinishing != 0 && capturePaused==0 && captureHardwareReady==0 && captureControlRevision==finishRevision)
    checks.append("terminal_finish_ignores_late_pause_signal")
    captureFinishing=0;captureHardwareReady=1;captureUploadPaused=0;capturePaused=0;interrupted=0;captureControlRevision=0
    interruptHandler(SIGINT)
    let cancelRevision=captureControlRevision
    recordingPauseHandler(SIGUSR1)
    precondition(interrupted==1 && captureUploadPaused != 0 && capturePaused==0 && captureHardwareReady==0 && captureControlRevision==cancelRevision)
    recordingFinishHandler(SIGWINCH)
    precondition(interrupted==1 && captureUploadPaused != 0 && captureTailDrainAllowed==0 && captureFinishing==0 && captureControlRevision==cancelRevision)
    checks.append("terminal_cancel_ignores_late_pause_or_finish_signal")
    interrupted=0;captureUploadPaused=0;captureHardwareReady=1

    // Exercise the exact bounded wait used before terminal source cleanup
    // seals its raw journal. The synthetic producer's last admitted block is
    // written before the fake hardware worker reports completion.
    let cleanupDirectory=sessionDirectory.appendingPathComponent("pause-cleanup-barrier")
    let cleanupStore=try RecordingJournal(directory:cleanupDirectory,track:"mic-raw",freeSpace:{1_000_000_000})
    let cleanupProducer=Mailbox(journal:cleanupStore),cleanupTransition=CapturePauseTransition()
    let cleanupWorker=Task {
        try await Task.sleep(nanoseconds:30_000_000)
        cleanupProducer.put(pcm,at:125)
        cleanupTransition.finishHardwarePart(nil);cleanupTransition.finishHardwarePart(nil);cleanupTransition.finishHardwarePart(nil)
    }
    let cleanupStatus=await awaitCaptureHardwareStop(cleanupTransition,until:ProcessInfo.processInfo.systemUptime+1.5)
    precondition(cleanupStatus.hardwareDone && cleanupStatus.failure==nil)
    cleanupProducer.seal();cleanupStore.wait();try await cleanupWorker.value
    precondition(cleanupStore.isEnded() && cleanupStore.bytes()==pcm.count && cleanupStore.fault()==nil)
    let stuckTransition=CapturePauseTransition()
    let timeoutStatus=await awaitCaptureHardwareStop(stuckTransition,until:ProcessInfo.processInfo.systemUptime+0.03)
    precondition(!timeoutStatus.hardwareDone && timeoutStatus.failure==nil)
    let failedTransition=CapturePauseTransition()
    failedTransition.finishHardwarePart("fixture_stop_failed");failedTransition.finishHardwarePart(nil);failedTransition.finishHardwarePart(nil)
    let failedStatus=await awaitCaptureHardwareStop(failedTransition,until:ProcessInfo.processInfo.systemUptime+0.03)
    precondition(failedStatus.hardwareDone && failedStatus.failure=="fixture_stop_failed")
    checks.append("terminal_cleanup_waits_for_hardware_before_seal_and_propagates_timeout_or_failure")

    // A journal append is accepted synchronously but written on its serial
    // worker. Hold that worker after one committed packet to model a non-mic
    // producer whose final admitted packet is still being persisted at pause.
    let pauseGate=CaptureFixtureWriterGate(),pauseDirectory=sessionDirectory.appendingPathComponent("pause-writer-barrier")
    let pauseStore=try RecordingJournal(directory:pauseDirectory,track:"remote",freeSpace:{1_000_000_000},beforeWrite:{pauseGate.waitIfBlocked()})
    let pauseProducer=Mailbox(journal:pauseStore),pauseConsumer=Mailbox(journal:pauseStore,producer:false)
    pauseProducer.put(pcm,at:150);pauseStore.wait();pauseGate.block();pauseProducer.put(pcm,at:150.1)
    let pauseLane=Lane(track:"remote",config:config,socketFactory:{FixtureSocket(fail:false)})
    await pauseLane.attachJournal(pauseStore)
    capturePaused=0;captureUploadPaused=0;captureHardwareReady=1;captureFinishing=0;captureTailDrainAllowed=0;interrupted=0
    let pauseASR=Task {await runJournalASR(lane:pauseLane,box:pauseConsumer,store:pauseStore,track:"remote",origin:150,
        onCacheFailure:{_ in preconditionFailure()},retryLimit:1,retryDelay:0.01)}
    let pauseSentDeadline=ProcessInfo.processInfo.systemUptime+2
    var pauseSentSeconds=0.0
    while (pauseConsumer.readCursor<pcm.count || pauseSentSeconds<0.1) && ProcessInfo.processInfo.systemUptime<pauseSentDeadline {
        pauseSentSeconds=(await pauseLane.metrics(includeSpeakerDiagnostics:false))["sent_audio_seconds"] as? Double ?? 0
        try await Task.sleep(nanoseconds:5_000_000)
    }
    pauseSentSeconds=(await pauseLane.metrics(includeSpeakerDiagnostics:false))["sent_audio_seconds"] as? Double ?? 0
    precondition(pauseConsumer.readCursor==pcm.count && pauseSentSeconds>=0.1 && pauseStore.committed("asr")==0 &&
                 (pauseStore.metadata()["pending_writer_bytes"] as? Int ?? 0)>0)
    recordingPauseHandler(SIGUSR1);capturePauseAcknowledgedRevision=captureControlRevision
    try await Task.sleep(nanoseconds:80_000_000)
    let pauseFinishedEarly=await pauseLane.didFinish()
    precondition(pauseStore.bytes()==pcm.count && pauseStore.committed("asr")==0 && !pauseFinishedEarly)
    let finalWriterBarrier=Task {waitForFinalCaptureJournals([pauseStore])}
    try await Task.sleep(nanoseconds:30_000_000)
    precondition(pauseStore.bytes()==pcm.count && (pauseStore.metadata()["pending_writer_bytes"] as? Int ?? 0)>0,
                 "local_final_barrier_waits_for_admitted_app_audio")
    pauseGate.open()
    await finalWriterBarrier.value
    let pauseDrainDeadline=ProcessInfo.processInfo.systemUptime+2
    while pauseStore.committed("asr")<2*pcm.count && ProcessInfo.processInfo.systemUptime<pauseDrainDeadline {try await Task.sleep(nanoseconds:5_000_000)}
    precondition(pauseStore.bytes()==2*pcm.count && pauseStore.committed("asr")==2*pcm.count && pauseConsumer.readCursor==2*pcm.count)
    recordingFinishHandler(SIGWINCH);pauseProducer.seal();pauseStore.wait();try await pauseASR.value
    checks.append("pause_waits_for_admitted_non_mic_journal_write_before_tail_complete")

    // Normal finish can race a derived producer (the clean mic track) or a
    // queued direct-source writer. The provider must not finish its task in
    // the empty interval before that producer seals and exposes its final PCM.
    let finishGate=CaptureFixtureWriterGate(),finishDirectory=sessionDirectory.appendingPathComponent("finish-writer-barrier")
    let finishStore=try RecordingJournal(directory:finishDirectory,track:"remote",freeSpace:{1_000_000_000},beforeWrite:{finishGate.waitIfBlocked()})
    let finishProducer=Mailbox(journal:finishStore),finishConsumer=Mailbox(journal:finishStore,producer:false)
    finishProducer.put(pcm,at:175);finishStore.wait();let finishLane=Lane(track:"remote",config:config,socketFactory:{FixtureSocket(fail:false)})
    await finishLane.attachJournal(finishStore)
    capturePaused=0;captureUploadPaused=0;captureHardwareReady=1;captureFinishing=0;captureTailDrainAllowed=0;interrupted=0
    let finishASR=Task {await runJournalASR(lane:finishLane,box:finishConsumer,store:finishStore,track:"remote",origin:175,
        onCacheFailure:{_ in preconditionFailure()},retryLimit:1,retryDelay:0.01)}
    let finishSentDeadline=ProcessInfo.processInfo.systemUptime+2
    var finishSentSeconds=0.0
    while (finishConsumer.readCursor<pcm.count || finishSentSeconds<0.1) && ProcessInfo.processInfo.systemUptime<finishSentDeadline {
        finishSentSeconds=(await finishLane.metrics(includeSpeakerDiagnostics:false))["sent_audio_seconds"] as? Double ?? 0
        try await Task.sleep(nanoseconds:5_000_000)
    }
    finishSentSeconds=(await finishLane.metrics(includeSpeakerDiagnostics:false))["sent_audio_seconds"] as? Double ?? 0
    precondition(finishConsumer.readCursor==pcm.count && finishSentSeconds>=0.1 && finishStore.committed("asr")==0)
    finishGate.block();finishProducer.put(pcm,at:175.1);recordingFinishHandler(SIGWINCH);finishProducer.seal()
    try await Task.sleep(nanoseconds:80_000_000)
    let finishFinishedEarly=await finishLane.didFinish()
    precondition(finishStore.bytes()==pcm.count && finishStore.committed("asr")==0 && !finishFinishedEarly)
    finishGate.open()
    try await finishASR.value;finishStore.wait()
    precondition(finishStore.bytes()==2*pcm.count && finishStore.committed("asr")==2*pcm.count && finishConsumer.readCursor==2*pcm.count)
    capturePaused=0;captureUploadPaused=0;captureHardwareReady=1;captureFinishing=0;captureTailDrainAllowed=0;interrupted=0
    checks.append("normal_finish_waits_for_delayed_producer_tail_and_commits_each_packet_once")

    // If resume or finish supersedes pause while an active socket waits for
    // its capture-tail barrier, the old receive task must be retired before
    // runJournalASRLoop starts a replacement task from confirmedCursor.
    let resumedDirectory=sessionDirectory.appendingPathComponent("pause-quick-resume-reconnect")
    let resumedStore=try RecordingJournal(directory:resumedDirectory,track:"remote",freeSpace:{1_000_000_000})
    let resumedProducer=Mailbox(journal:resumedStore),resumedConsumer=Mailbox(journal:resumedStore,producer:false)
    resumedProducer.put(pcm,at:190);resumedStore.wait()
    let resumedSockets=CaptureFixtureSocketInventory()
    let resumedLane=Lane(track:"remote",config:config,socketFactory:{resumedSockets.make()})
    await resumedLane.attachJournal(resumedStore)
    capturePaused=0;captureUploadPaused=0;captureHardwareReady=1;captureFinishing=0;captureTailDrainAllowed=0;interrupted=0
    let resumedGate=CaptureFixtureAsyncGate()
    let resumedASR=Task {await runJournalASR(lane:resumedLane,box:resumedConsumer,store:resumedStore,track:"remote",origin:190,
        onCacheFailure:{_ in preconditionFailure()},retryLimit:1,retryDelay:0.01,pauseTailReady:{_ in await resumedGate.wait()})}
    let resumedSentDeadline=ProcessInfo.processInfo.systemUptime+2
    var resumedSent=0.0
    while (resumedConsumer.readCursor<pcm.count || resumedSent<0.1) && ProcessInfo.processInfo.systemUptime<resumedSentDeadline {
        resumedSent=(await resumedLane.metrics(includeSpeakerDiagnostics:false))["sent_audio_seconds"] as? Double ?? 0
        try await Task.sleep(nanoseconds:5_000_000)
    }
    precondition(resumedConsumer.readCursor==pcm.count && resumedSent>=0.1 && resumedStore.committed("asr")==0)
    recordingPauseHandler(SIGUSR1);capturePauseAcknowledgedRevision=captureControlRevision
    let resumedGateDeadline=ProcessInfo.processInfo.systemUptime+2
    while !resumedGate.isWaiting() && ProcessInfo.processInfo.systemUptime<resumedGateDeadline {try await Task.sleep(nanoseconds:5_000_000)}
    precondition(resumedGate.isWaiting() && resumedSockets.count()==1)
    recordingPauseHandler(SIGUSR2);captureHardwareReady=1;resumedGate.open()
    let reconnectedDeadline=ProcessInfo.processInfo.systemUptime+2
    while resumedSockets.count()<2 && ProcessInfo.processInfo.systemUptime<reconnectedDeadline {try await Task.sleep(nanoseconds:5_000_000)}
    let replayDeadline=ProcessInfo.processInfo.systemUptime+2
    while (resumedSockets.count()<2 || (resumedSockets.socket(1)?.sentBytes() ?? 0)<pcm.count) && ProcessInfo.processInfo.systemUptime<replayDeadline {try await Task.sleep(nanoseconds:5_000_000)}
    precondition(resumedSockets.count()==2 && resumedSockets.socket(0)?.isCanceled()==true && resumedSockets.socket(1)?.sentBytes()==pcm.count && resumedStore.committed("asr")==0)
    resumedProducer.put(pcm,at:190.1);recordingFinishHandler(SIGWINCH);resumedProducer.seal()
    try await resumedASR.value;resumedStore.wait()
    precondition(resumedSockets.count()==2 && resumedSockets.socket(1)?.isCanceled()==true && resumedStore.bytes()==2*pcm.count &&
                 resumedStore.committed("asr")==2*pcm.count && resumedConsumer.readCursor==2*pcm.count)

    let finishReconnectDirectory=sessionDirectory.appendingPathComponent("pause-finish-reconnect")
    let finishReconnectStore=try RecordingJournal(directory:finishReconnectDirectory,track:"remote",freeSpace:{1_000_000_000})
    let finishReconnectProducer=Mailbox(journal:finishReconnectStore),finishReconnectConsumer=Mailbox(journal:finishReconnectStore,producer:false)
    finishReconnectProducer.put(pcm,at:195);finishReconnectStore.wait()
    let finishReconnectSockets=CaptureFixtureSocketInventory()
    let finishReconnectLane=Lane(track:"remote",config:config,socketFactory:{finishReconnectSockets.make()})
    await finishReconnectLane.attachJournal(finishReconnectStore)
    capturePaused=0;captureUploadPaused=0;captureHardwareReady=1;captureFinishing=0;captureTailDrainAllowed=0;interrupted=0
    let finishReconnectGate=CaptureFixtureAsyncGate()
    let finishReconnectASR=Task {await runJournalASR(lane:finishReconnectLane,box:finishReconnectConsumer,store:finishReconnectStore,track:"remote",origin:195,
        onCacheFailure:{_ in preconditionFailure()},retryLimit:1,retryDelay:0.01,pauseTailReady:{_ in await finishReconnectGate.wait()})}
    let finishReconnectSentDeadline=ProcessInfo.processInfo.systemUptime+2
    var finishReconnectSent=0.0
    while (finishReconnectConsumer.readCursor<pcm.count || finishReconnectSent<0.1) && ProcessInfo.processInfo.systemUptime<finishReconnectSentDeadline {
        finishReconnectSent=(await finishReconnectLane.metrics(includeSpeakerDiagnostics:false))["sent_audio_seconds"] as? Double ?? 0
        try await Task.sleep(nanoseconds:5_000_000)
    }
    precondition(finishReconnectConsumer.readCursor==pcm.count && finishReconnectSent>=0.1 && finishReconnectStore.committed("asr")==0)
    recordingPauseHandler(SIGUSR1);capturePauseAcknowledgedRevision=captureControlRevision
    let finishGateDeadline=ProcessInfo.processInfo.systemUptime+2
    while !finishReconnectGate.isWaiting() && ProcessInfo.processInfo.systemUptime<finishGateDeadline {try await Task.sleep(nanoseconds:5_000_000)}
    precondition(finishReconnectGate.isWaiting() && finishReconnectSockets.count()==1)
    recordingFinishHandler(SIGWINCH);finishReconnectGate.open()
    let finishReconnectDeadline=ProcessInfo.processInfo.systemUptime+2
    while finishReconnectSockets.count()<2 && ProcessInfo.processInfo.systemUptime<finishReconnectDeadline {try await Task.sleep(nanoseconds:5_000_000)}
    let finishReplayDeadline=ProcessInfo.processInfo.systemUptime+2
    while (finishReconnectSockets.count()<2 || (finishReconnectSockets.socket(1)?.sentBytes() ?? 0)<pcm.count) && ProcessInfo.processInfo.systemUptime<finishReplayDeadline {try await Task.sleep(nanoseconds:5_000_000)}
    finishReconnectProducer.put(pcm,at:195.1);finishReconnectProducer.seal()
    try await finishReconnectASR.value;finishReconnectStore.wait()
    precondition(finishReconnectSockets.count()==2 && finishReconnectSockets.socket(0)?.isCanceled()==true && finishReconnectSockets.socket(1)?.isCanceled()==true &&
                 finishReconnectStore.bytes()==2*pcm.count && finishReconnectStore.committed("asr")==2*pcm.count &&
                 finishReconnectConsumer.readCursor==2*pcm.count)
    capturePaused=0;captureUploadPaused=0;captureHardwareReady=1;captureFinishing=0;captureTailDrainAllowed=0;interrupted=0
    checks.append("superseded_active_pause_closes_receiver_and_replays_from_confirmed_cursor_on_resume_and_finish")

    let heldSocket=FixtureSocket(fail:false,delay:2_000_000)
    let heldLane=Lane(track:"mic",config:config,socketFactory:{heldSocket})
    capturePaused=1;captureUploadPaused=0;captureHardwareReady=0
    let held=Task {try await heldLane.send(pcm,captureAt:100,sessionStart:100)}
    try await Task.sleep(nanoseconds:50_000_000)
    let heldMetrics=await heldLane.metrics(includeSpeakerDiagnostics:false)
    precondition((heldMetrics["attempted_audio_seconds"] as? Double ?? 0)>0 &&
                 (heldMetrics["sent_audio_seconds"] as? Double ?? 0)>0)
    capturePaused=0;captureHardwareReady=1;try await held.value
    let releasedMetrics=await heldLane.metrics(includeSpeakerDiagnostics:false)
    precondition((releasedMetrics["attempted_audio_seconds"] as? Double ?? 0)>0 &&
                 (releasedMetrics["sent_audio_seconds"] as? Double ?? 0)>0)
    checks.append("paused_capture_allows_only_already_saved_audio_to_drain")

    // Exercise the journal ASR consumer itself: while paused, its cursor and
    // committed cursor remain at zero; resume sends the exact saved backlog.
    let backlogDirectory=sessionDirectory.appendingPathComponent("asr-backlog")
    try FileManager.default.createDirectory(at:backlogDirectory,withIntermediateDirectories:false)
    let backlog=try RecordingJournal(directory:backlogDirectory,track:"mic",freeSpace:{1_000_000_000})
    let producer=Mailbox(journal:backlog)
    producer.put(pcm,at:200);producer.put(pcm,at:200.1);backlog.wait()
    let consumer=Mailbox(journal:backlog,producer:false)
    let socket=FixtureSocket(fail:false,delay:1_000_000)
    let lane=Lane(track:"mic",config:config,socketFactory:{socket});await lane.attachJournal(backlog)
    capturePaused=1;captureUploadPaused=0;captureHardwareReady=0;captureControlRevision &+= 1
    capturePauseAcknowledgedRevision=captureControlRevision
    let asr=Task {await runJournalASR(lane:lane,box:consumer,store:backlog,track:"mic",origin:200,
                                     onCacheFailure:{_ in},retryLimit:1,retryDelay:0.01)}
    try await Task.sleep(nanoseconds:100_000_000)
    let pausedMetrics=await lane.metrics(includeSpeakerDiagnostics:false)
    precondition(consumer.readCursor==backlog.bytes() && backlog.committed("asr")==backlog.bytes() &&
                 (pausedMetrics["attempted_audio_seconds"] as? Double ?? 0)>=0.2)
    let committedAtPause=backlog.committed("asr"),bytesAtPause=backlog.bytes()
    recordingFinishHandler(SIGWINCH)
    precondition(captureHardwareReady==0 && !writeCapturedPCMIfAdmitted(pcm,at:201,to:producer) && backlog.bytes()==bytesAtPause)
    producer.seal();backlog.wait()
    try await asr.value
    backlog.wait()
    let resumedMetrics=await lane.metrics(includeSpeakerDiagnostics:false)
    precondition(consumer.readCursor==backlog.bytes() && backlog.committed("asr")==backlog.bytes() && committedAtPause==bytesAtPause &&
                 (resumedMetrics["sent_audio_seconds"] as? Double ?? 0)>=0.2)
    checks.append("production_journal_asr_pause_then_finish_commits_all_without_new_pcm")

    capturePaused=1;captureUploadPaused=0;captureHardwareReady=0;captureFinishing=0;captureTailDrainAllowed=0;interrupted=0;captureControlRevision &+= 1
    capturePauseAcknowledgedRevision=captureControlRevision
    let derivedRevision=captureControlRevision,derivedBarrier=CapturePauseTailBarrier()
    derivedBarrier.begin(revision:derivedRevision,throughByte:pcm.count)
    derivedBarrier.finalize(revision:derivedRevision,throughByte:pcm.count)
    let derivedDirectory=sessionDirectory.appendingPathComponent("delayed-derived-write")
    let derivedStore=try RecordingJournal(directory:derivedDirectory,track:"mic",freeSpace:{1_000_000_000})
    let derivedProducer=Mailbox(journal:derivedStore),derivedConsumer=Mailbox(journal:derivedStore,producer:false)
    let derivedLane=Lane(track:"mic",config:config,socketFactory:{FixtureSocket(fail:false)})
    await derivedLane.attachJournal(derivedStore)
    let derivedASR=Task {await runJournalASR(lane:derivedLane,box:derivedConsumer,store:derivedStore,track:"mic",origin:225,
        onCacheFailure:{_ in preconditionFailure()},retryLimit:1,retryDelay:0.01,
        pauseTailReady:{revision in await derivedBarrier.wait(revision)})}
    try await Task.sleep(nanoseconds:40_000_000)
    precondition(derivedStore.bytes()==0 && derivedStore.committed("asr")==0)
    // Synthetic echo output arrives after pause ACK but before its raw-byte
    // barrier completes. The ASR consumer must not finish an empty task early.
    derivedProducer.put(pcm,at:225);derivedStore.wait();derivedBarrier.complete(derivedRevision)
    let derivedUntil=ProcessInfo.processInfo.systemUptime+2
    while derivedStore.committed("asr")<pcm.count && ProcessInfo.processInfo.systemUptime<derivedUntil {
        try await Task.sleep(nanoseconds:5_000_000)
    }
    precondition(derivedStore.committed("asr")==pcm.count && derivedConsumer.readCursor==pcm.count)
    recordingFinishHandler(SIGWINCH);derivedProducer.seal();derivedStore.wait();try await derivedASR.value
    checks.append("pause_tail_waits_for_delayed_echo_derived_write_before_asr_finish")

    capturePaused=1;captureUploadPaused=0;captureHardwareReady=0;captureFinishing=0;captureTailDrainAllowed=0;interrupted=0;captureControlRevision &+= 1;capturePauseAcknowledgedRevision=captureControlRevision
    let failedDirectory=sessionDirectory.appendingPathComponent("pause-failure")
    let failedStore=try RecordingJournal(directory:failedDirectory,track:"mic",freeSpace:{1_000_000_000})
    let failedProducer=Mailbox(journal:failedStore);failedProducer.put(pcm,at:250);failedStore.wait()
    let failedConsumer=Mailbox(journal:failedStore,producer:false)
    let failedLane=Lane(track:"mic",config:config,socketFactory:{FixtureSocket(fail:false,offline:true)})
    await failedLane.attachJournal(failedStore)
    let failedASR=Task {await runJournalASR(lane:failedLane,box:failedConsumer,store:failedStore,track:"mic",origin:250,
        onCacheFailure:{_ in preconditionFailure()},retryLimit:0,retryDelay:0.01)}
    try await Task.sleep(nanoseconds:80_000_000)
    precondition(failedStore.bytes()==pcm.count && failedStore.committed("asr")==0)
    interruptHandler(SIGINT);await failedASR.value
    precondition(failedStore.bytes()==pcm.count && failedStore.committed("asr")==0 && captureUploadPaused != 0)
    checks.append("pause_asr_failure_stays_pending_and_hard_cancel_closes_upload_gate")

    // A pause drains and finishes the current provider task, then keeps the
    // same journal consumer alive for later resume audio.
    capturePaused=0;captureUploadPaused=0;captureHardwareReady=1;interrupted=0;captureFinishing=0;captureTailDrainAllowed=0;capturePauseAcknowledgedRevision = -1
    let liveDirectory=sessionDirectory.appendingPathComponent("live-pause-resume")
    let liveStore=try RecordingJournal(directory:liveDirectory,track:"mic",freeSpace:{1_000_000_000})
    let liveProducer=Mailbox(journal:liveStore)
    let second=Data(repeating:0x28,count:32_000)
    liveProducer.put(second,at:400);liveProducer.put(second,at:401);liveStore.wait()
    let liveConsumer=Mailbox(journal:liveStore,producer:false)
    var socketCount=0
    let liveLane=Lane(track:"mic",config:config,socketFactory:{socketCount+=1;return FixtureSocket(fail:false,delay:10_000_000)})
    await liveLane.attachJournal(liveStore)
    let liveASR=Task {await runJournalASR(lane:liveLane,box:liveConsumer,store:liveStore,track:"mic",origin:400,onCacheFailure:{_ in},retryLimit:2,retryDelay:0.01)}
    let until=ProcessInfo.processInfo.systemUptime+2
    while ((await liveLane.metrics(includeSpeakerDiagnostics:false))["sent_audio_seconds"] as? Double ?? 0) < 1 && ProcessInfo.processInfo.systemUptime<until {
        try await Task.sleep(nanoseconds:2_000_000)
    }
    recordingPauseHandler(SIGUSR1)
    capturePauseAcknowledgedRevision=captureControlRevision
    let pausedUntil=ProcessInfo.processInfo.systemUptime+2
    while liveStore.committed("asr")<liveStore.bytes() && ProcessInfo.processInfo.systemUptime<pausedUntil {
        try await Task.sleep(nanoseconds:5_000_000)
    }
    let pausedSent=(await liveLane.metrics(includeSpeakerDiagnostics:false))["sent_audio_seconds"] as? Double ?? 0
    precondition(pausedSent>=2 && liveStore.committed("asr")==liveStore.bytes())
    try await Task.sleep(nanoseconds:80_000_000)
    let pausedAgain=(await liveLane.metrics(includeSpeakerDiagnostics:false))["sent_audio_seconds"] as? Double ?? -1
    precondition(pausedAgain==pausedSent)
    recordingPauseHandler(SIGUSR2);await liveLane.resumeUploads();captureHardwareReady=1;captureUploadPaused=0
    precondition(writeCapturedPCMIfAdmitted(second,at:402,to:liveProducer))
    liveProducer.seal();liveStore.wait()
    try await liveASR.value;liveStore.wait()
    precondition(socketCount>=2 && liveConsumer.readCursor==liveStore.bytes() && liveStore.committed("asr")==liveStore.bytes())
    checks.append("paused_live_socket_finishes_saved_audio_then_resumes_same_consumer")

    // Saturation on the microphone conversion queue requests one real pause,
    // records the frames it could not accept, and leaves the raw mailbox open
    // long enough to drain callbacks which already passed admission.
    do {
        capturePaused=0;captureUploadPaused=0;captureHardwareReady=1
        interrupted=0;captureFinishing=0;captureControlRevision=0
        let gate=MicrophoneBackpressurePauseGate(),routePause=CaptureInputDeviceChangePause()
        var requests=0
        let pause={()->Bool in requests+=1;return routePause.request(reason:"mic_conversion_backpressure")}
        let overflowBox=Mailbox()
        for _ in 0..<4 {
            guard handleMicrophoneConversionBackpressure(gate:gate,frames:2400,sampleRate:24_000,
                requestPause:pause,mailbox:overflowBox) else{throw Failure(code:"mic_backpressure_pause_rejected")}
        }
        guard requests==1 else{throw Failure(code:"mic_backpressure_pause_not_coalesced")}
        let pressure=gate.snapshot()
        guard pressure.requested,abs(pressure.intervalDroppedSeconds-0.4)<0.0001 else{
            throw Failure(code:"mic_backpressure_gap_not_counted")
        }
        guard let revision=routePause.applyPendingPause(),capturePaused==1,captureHardwareReady==0,
              routePause.takeReason(for:revision)=="mic_conversion_backpressure" else{
            throw Failure(code:"mic_backpressure_pause_not_acknowledgeable")
        }
        let drainDirectory=directory.appendingPathComponent(UUID().uuidString)
        let drainStore=try RecordingJournal(directory:drainDirectory,track:"mic-raw",freeSpace:{1_000_000_000})
        let pending=Data(repeating:0x31,count:3200)
        let pausedClock=CaptureBudgetClock();pausedClock.mark(499.0);pausedClock.pause(at:500.0)
        let drainBox=Mailbox(captureClock:pausedClock,journal:drainStore)
        guard pausedClock.isPaused,
              !writeCapturedPCMIfAdmitted(pending,at:500,to:drainBox),
              writeQueuedMicrophonePCM(pending,at:499.9,to:drainBox),
              !writeQueuedMicrophonePCM(pending,at:500.1,to:drainBox),
              !drainBox.put(pending,at:500.1) else{
            throw Failure(code:"mic_backpressure_boundary_failed")
        }
        drainStore.wait()
        guard drainStore.bytes()==pending.count else{throw Failure(code:"mic_backpressure_pending_audio_dropped")}
        recordingPauseHandler(SIGUSR2);captureHardwareReady=1
        gate.resetForResume()
        guard handleMicrophoneConversionBackpressure(gate:gate,frames:2400,sampleRate:24_000,
              requestPause:pause,mailbox:overflowBox),requests==2 else{
            throw Failure(code:"mic_backpressure_resume_not_reset")
        }
        guard let secondRevision=routePause.applyPendingPause(),
              routePause.takeReason(for:secondRevision)=="mic_conversion_backpressure" else{
            throw Failure(code:"mic_backpressure_second_pause_missing")
        }
        recordingPauseHandler(SIGUSR2);captureHardwareReady=1
        let fallbackGate=MicrophoneBackpressurePauseGate(),fallbackBox=Mailbox()
        guard !handleMicrophoneConversionBackpressure(gate:fallbackGate,frames:2400,sampleRate:24_000,
              requestPause:{false},mailbox:fallbackBox) else{throw Failure(code:"mic_backpressure_fallback_swallowed")}
        do {try fallbackBox.checkFault();throw Failure(code:"mic_backpressure_fallback_not_fatal")}
        catch let error as Failure where error.code=="mic_conversion_backpressure" {}
        checks.append("mic_conversion_backpressure_pauses_once_marks_exact_gap_drains_admitted_audio_and_resets_on_resume")
    }

    // One helper/cache/session must remain live through two user pause/resume
    // cycles. Both tracks share the same capture clock and each keeps its Lane
    // and speaker pipeline; only the provider task is reopened from the saved
    // journal cursor. This fixture uses no audio device or network socket.
    do {
        capturePaused=0;captureUploadPaused=0;captureHardwareReady=1;interrupted=0
        captureFinishing=0;captureTailDrainAllowed=0;capturePauseAcknowledgedRevision = -1
        captureControlRevision=0
        let cacheID=UUID().uuidString,session="pause-twice-same-session"
        let continuationConfig=Config(session:session,bundle:config.bundle,key:config.key,confirmed:config.confirmed,
            maxSeconds:config.maxSeconds,model:config.model,silenceMS:config.silenceMS,micEnabled:config.micEnabled,
            localSpeakerDirectory:config.localSpeakerDirectory,localEmbeddingModel:config.localEmbeddingModel,
            userLaunchConfirmed:config.userLaunchConfirmed)
        let cache=directory.appendingPathComponent(cacheID)
        let routeChangePause=CaptureInputDeviceChangePause()
        try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:["session":session,"cache_id":cacheID,"bundle":"*system*","capture_mode":"cloud","asr_destination":"dashscope.aliyuncs.com"])
            .write(to:cache.appendingPathComponent("meeting.json"))
        var uptime=500.0
        let clock=CaptureBudgetClock(wallTime:{10_000+uptime},uptime:{uptime})
        let tracks=["mic","remote"]
        var stores:[String:RecordingJournal]=[:],producers:[String:Mailbox]=[:],consumers:[String:Mailbox]=[:]
        var lanes:[String:Lane]=[:],pipelines:[String:SpeakerPipeline]=[:]
        let socketCounters=Dictionary(uniqueKeysWithValues:tracks.map{($0,CaptureFixtureTickCounter())})
        let speakerEpochs=Dictionary(uniqueKeysWithValues:tracks.map{($0,session+":"+$0+":"+UUID().uuidString)})
        for track in tracks {
            let store=try RecordingJournal(directory:cache,track:track,freeSpace:{1_000_000_000},alignCaptureTime:true)
            let producer=Mailbox(captureClock:clock,journal:store)
            let consumer=Mailbox(journal:store,producer:false)
            let pipeline=SpeakerPipeline(source:track,epoch:speakerEpochs[track]!,syntheticInput:true)
            let counter=socketCounters[track]!
            let lane=Lane(track:track,config:continuationConfig,prepared:pipeline,preparedEpoch:speakerEpochs[track]!,socketFactory:{counter.tick();return FixtureSocket(fail:false,delay:2_000_000)})
            await lane.attachJournal(store)
            stores[track]=store;producers[track]=producer;consumers[track]=consumer;lanes[track]=lane;pipelines[track]=pipeline
        }
        let origin=uptime
        let consumersRunning=tracks.map{track in
            Task {await runJournalASR(lane:lanes[track]!,box:consumers[track]!,store:stores[track]!,track:track,origin:origin,onCacheFailure:{_ in preconditionFailure("continuation_fixture_cache_write")},retryLimit:2,retryDelay:0.01)}
        }
        let packet=Data(repeating:0x31,count:32_000)
        func waitForASRDrain() async throws {
            let deadline=ProcessInfo.processInfo.systemUptime+3
            while tracks.contains(where:{stores[$0]!.committed("asr")<stores[$0]!.bytes()}) && ProcessInfo.processInfo.systemUptime<deadline {
                try await Task.sleep(nanoseconds:5_000_000)
            }
            guard tracks.allSatisfy({stores[$0]!.committed("asr")==stores[$0]!.bytes()}) else{throw Failure(code:"continuation_fixture_asr_drain_timeout")}
        }
        for segment in 0..<3 {
            for track in tracks {
                guard writeCapturedPCMIfAdmitted(packet,at:uptime,to:producers[track]!) else{throw Failure(code:"continuation_fixture_capture_gate_closed")}
                let frame=SpeakerFrame(sourceID:track,epoch:speakerEpochs[track]!,revision:segment+1,start:Double(segment),end:Double(segment+1),activeSlots:[0])
                _=try await pipelines[track]!.syntheticTimelineAppend([frame])
            }
            for store in stores.values {store.wait()}
            uptime+=1
            guard segment<2 else{continue}
            if segment==0 {
                precondition(routeChangePause.request(reason:"input_device_changed"))
                precondition(routeChangePause.request(reason:"input_device_changed"))
                let fatalMicrophoneFault=Mailbox()
                if !routeChangePause.request(reason:"microphone_engine_restart_failed") {
                    fatalMicrophoneFault.fail("microphone_engine_restart_failed")
                }
                do {try fatalMicrophoneFault.checkFault();throw Failure(code:"route_change_swallowed_other_fault")}
                catch let error as Failure {guard error.code=="microphone_engine_restart_failed" else{throw error}}
                let revalidated=try revalidateMicrophoneOrPause(routeChangePause:routeChangePause) {
                    throw Failure(code:"input_device_changed")
                }
                guard !revalidated,capturePaused != 0,captureHardwareReady==0 else{
                    throw Failure(code:"route_change_pause_not_applied")
                }
                let autoPauseRevision=captureControlRevision
                guard routeChangePause.applyPendingPause()==nil,captureControlRevision==autoPauseRevision else{
                    throw Failure(code:"route_change_pause_duplicated")
                }
                clock.pause(at:uptime)
            } else {
                clock.pause(at:uptime)
                recordingPauseHandler(SIGUSR1)
            }
            let pauseRevision=captureControlRevision
            if segment==0 {
                let reason=routeChangePause.takeReason(for:pauseRevision)
                let ack:[String:Any]=["type":"recording_paused","session":session,
                    "control_revision":pauseRevision,"capture_gate":"closed","reason":reason ?? ""]
                guard reason=="input_device_changed",ack["reason"] as? String=="input_device_changed" else{
                    throw Failure(code:"route_change_pause_reason_missing")
                }
                checks.append("input_device_change_is_reported_as_one_same_session_pause_with_reason")
            }
            capturePauseAcknowledgedRevision=pauseRevision
            let bytesBefore=Dictionary(uniqueKeysWithValues:tracks.map{($0,stores[$0]!.bytes())})
            guard tracks.allSatisfy({!writeCapturedPCMIfAdmitted(packet,at:uptime+0.25,to:producers[$0]!) && stores[$0]!.bytes()==bytesBefore[$0]}) else {
                throw Failure(code:"continuation_fixture_audio_admitted_while_paused")
            }
            try await waitForASRDrain()
            uptime+=15 // A long pause must not create a timeline gap or use budget.
            recordingPauseHandler(SIGUSR2)
            clock.resume(at:uptime)
            for lane in lanes.values {await lane.resumeUploads()}
            captureHardwareReady=1;captureUploadPaused=0
            guard captureAdmissionOpen() else{throw Failure(code:"continuation_fixture_resume_gate_closed")}
        }
        let effectiveSeconds=clock.elapsed(uptime)
        guard abs(effectiveSeconds-3)<0.0001 else{throw Failure(code:"continuation_fixture_elapsed_not_cumulative")}
        for producer in producers.values {producer.seal()}
        for task in consumersRunning {await task.value}
        for store in stores.values {store.wait()}
        let sameCache=cache.lastPathComponent==cacheID && tracks.allSatisfy({stores[$0]!.directory.standardizedFileURL==cache.standardizedFileURL})
        let allBytes=tracks.allSatisfy({stores[$0]!.bytes()==96_000 && stores[$0]!.metadata()["alignment_padding_bytes"] as? Int==0})
        let allTranscribed=tracks.allSatisfy({stores[$0]!.committed("asr")==96_000 && consumers[$0]!.readCursor==96_000})
        let allReconnected=tracks.allSatisfy({socketCounters[$0]!.count()>=3 && lanes[$0]!.config.session==session && lanes[$0]!.speakerEpoch==speakerEpochs[$0]!})
        var speakerContinuous=true
        for track in tracks {
            let frames=await pipelines[track]!.offlineFrames()
            speakerContinuous = speakerContinuous && frames.count==3 &&
                frames.map(\.epoch).allSatisfy{$0==speakerEpochs[track]!} &&
                frames.map(\.sourceID).allSatisfy{$0==track} &&
                frames.map(\.activeSlots).allSatisfy{$0==[0]} &&
                abs((frames.last?.end ?? -1)-3)<0.0001
        }
        guard sameCache,allBytes,allTranscribed,allReconnected,speakerContinuous else{throw Failure(code:"continuation_fixture_invariant_failed")}
        checks.append("two_pause_resume_cycles_keep_same_cache_session_dual_tracks_clock_asr_and_speaker_epoch")
    }

    // An orderly stop sets interrupted=1. Closed pause gates must still win,
    // while cache recovery with interrupted=1 and open gates remains allowed.
    capturePaused=1;captureUploadPaused=1;interrupted=1
    let stoppedLane=Lane(track:"mic",config:config,socketFactory:{FixtureSocket(fail:false)})
    do {
        try await stoppedLane.send(pcm,captureAt:300,sessionStart:300)
        preconditionFailure("paused send escaped after orderly stop")
    } catch {
        precondition((error as? Failure)?.code=="capture_interrupted")
    }
    let stoppedMetrics=await stoppedLane.metrics(includeSpeakerDiagnostics:false)
    precondition((stoppedMetrics["attempted_audio_seconds"] as? Double ?? -1)==0 &&
                 (stoppedMetrics["sent_audio_seconds"] as? Double ?? -1)==0)
    do {
        try await stoppedLane.start()
        preconditionFailure("paused ASR start escaped after orderly stop")
    } catch {
        precondition((error as? Failure)?.code=="capture_interrupted")
    }
    checks.append("orderly_stop_cannot_open_paused_lane_or_charge_backlog")

    // The same actor drain used during a paused/no-packet model loop must
    // publish a late embedding without reopening PCM or upload admission.
    let featurePipeline=SpeakerPipeline(source:"mic",epoch:"paused-feature",syntheticInput:true)
    let speakerFrame=SpeakerFrame(sourceID:"mic",epoch:"paused-feature",revision:1,start:0,end:9,activeSlots:[0])
    _=try await featurePipeline.syntheticTimelineRevision([speakerFrame],revision:1)
    let featureJournal=try RecordingJournal(directory:directory.appendingPathComponent(UUID().uuidString),track:"mic",freeSpace:{1_000_000_000})
    let featureLane=Lane(track:"mic",config:config,prepared:featurePipeline,preparedEpoch:"paused-feature",socketFactory:{FixtureSocket(fail:false)})
    await featureLane.attachJournal(featureJournal)
    let final:[String:Any]=["type":"segment","session":config.session,"segment_id":"paused-final","source_id":"mic","epoch":"paused-feature","revision":1,"start":0.0,"end":9.0,"end_time_known":true,"final":true,"text":"暂停前已提交的合成原文。"]
    await featureLane.publish(await featurePipeline.accept(final))
    let late=Task {
        try await Task.sleep(nanoseconds:20_000_000)
        let vector=EmbeddingVector(values:[Float](repeating:0.1,count:192),partition:SpeakerEmbeddingBackend.partition,inputKind:"synthetic_model_output")
        try await featurePipeline.syntheticFeatureEvidence(SpeakerFeatureEvidence(start:2,end:4,slot:0,vector:vector))
    }
    try await late.value
    let firstDrain=await featureLane.publishPendingSpeakerFeatures(),secondDrain=await featureLane.publishPendingSpeakerFeatures()
    featureJournal.finish();featureJournal.wait()
    let written=try String(contentsOf:featureJournal.directory.appendingPathComponent("mic-transcript.jsonl")).split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
    let featureMetrics=await featureLane.metrics(includeSpeakerDiagnostics:false)
    precondition(firstDrain==1 && secondDrain==0 && written.count==2 && written[1]["annotation_only"] as? Bool==true && written[1]["identity_features"]==nil && written[0]["text"] as? String==written[1]["text"] as? String)
    precondition(written[1]["revision"] as? Int==2 && featureJournal.bytes()==0 && (featureMetrics["attempted_audio_seconds"] as? Double ?? -1)==0 && capturePaused==1 && captureUploadPaused==1)
    _=try await featurePipeline.close(flush:false)
    checks.append("paused_lane_publishes_async_feature_once_without_new_pcm_upload_or_changed_words")

    var restarts=0
    func reconcile(_ admitted:Bool=true,_ current:UInt32=120,_ selected:UInt32=120,_ sameFormat:Bool=true,_ running:Bool=true,_ attempts:Int=0) throws->Bool {
        try reconcileMicrophoneConfiguration(admitted:admitted,expectedDevice:120,currentDevice:current,
            defaultDevice:selected,formatMatches:sameFormat,engineRunning:running,restartAttempts:attempts,restart:{restarts+=1})
    }
    // Replay the production sequence: startup graph notification, same route,
    // running engine; then PCM arrives. The former unconditional fault failed it.
    let startupBox=Mailbox()
    let unchanged=try reconcile();precondition(!unchanged)
    startupBox.put(pcm,at:500);try startupBox.checkFault()
    precondition(startupBox.signalMetrics()["hardware_pcm_frames"] as? Int==1 && restarts==0)
    let restarted=try reconcile(true,120,120,true,false);precondition(restarted && restarts==1)
    let pausedRestart=try reconcile(false,0,0,false,false);precondition(!pausedRestart && restarts==1)
    checks.append("startup_graph_notification_keeps_running_mic_and_pause_never_restarts")
    for (current,selected,sameFormat,attempts) in [(UInt32(121),UInt32(120),true,0),(120,121,true,0),(120,120,false,0),(120,120,true,3)] {
        do {_=try reconcile(true,current,selected,sameFormat,false,attempts);preconditionFailure("unsafe route restarted")}
        catch {precondition((error as? Failure)?.code == (attempts==3 ? "microphone_engine_restart_limit":"input_device_changed"))}
    }
    do {
        _=try reconcileMicrophoneConfiguration(admitted:true,expectedDevice:120,currentDevice:120,defaultDevice:120,
            formatMatches:true,engineRunning:false,restartAttempts:0,restart:{throw Failure(code:"fixture_restart_failed")})
        preconditionFailure("restart failure swallowed")
    } catch {precondition((error as? Failure)?.code=="fixture_restart_failed")}
    precondition(restarts==1)
    checks.append("changed_device_format_restart_failure_and_retry_limit_remain_explicit")

    // Resume must not acknowledge a merely running engine or old PCM.
    var fakeFrames=3,engineChecks=0
    let fresh=try await waitForMicrophoneResume(timeout:0.1,stillRequested:{true},validateEngine:{
        engineChecks+=1;if engineChecks==3 {fakeFrames+=1};return true
    },hasFreshFrame:{fakeFrames>3})
    precondition(fresh && engineChecks==3)
    checks.append("resume_waits_for_new_pcm_instead_of_accepting_running_engine_or_old_frames")
    do {
        _=try await waitForMicrophoneResume(timeout:0.02,stillRequested:{true},validateEngine:{true},hasFreshFrame:{false})
        preconditionFailure("resume without new PCM acknowledged")
    } catch {precondition((error as? Failure)?.code=="microphone_resume_no_frames")}
    checks.append("resume_without_fresh_pcm_fails_with_bounded_explicit_reason")
    var resumeRequested=true,reconciliationCalls=0
    let canceled=try await waitForMicrophoneResume(timeout:0.1,stillRequested:{resumeRequested},validateEngine:{
        reconciliationCalls+=1;resumeRequested=false;return true
    },hasFreshFrame:{true})
    precondition(!canceled && reconciliationCalls==1)
    let canceledBeforeStart=try await waitForMicrophoneResume(stillRequested:{false},validateEngine:{
        preconditionFailure("paused resume restarted hardware")
    },hasFreshFrame:{true})
    precondition(!canceledBeforeStart)
    checks.append("new_pause_or_revision_cancels_resume_before_ack_and_prevents_further_restart")
    do {try requireMicrophoneStartAvailable(installed:true);preconditionFailure("duplicate tap permitted")}
    catch {precondition((error as? Failure)?.code=="microphone_already_started")}
    try requireMicrophoneStartAvailable(installed:false)
    checks.append("duplicate_microphone_start_is_rejected_before_installing_second_tap")
    var recoveringEngine=false,resumeRestartCount=0
    let notificationDuringClosedGate=try reconcileMicrophoneConfiguration(admitted:false,expectedDevice:120,currentDevice:120,
        defaultDevice:120,formatMatches:true,engineRunning:recoveringEngine,restartAttempts:0,restart:{resumeRestartCount+=1;recoveringEngine=true})
    precondition(!notificationDuringClosedGate && !recoveringEngine && resumeRestartCount==0)
    let explicitResume=try reconcileMicrophoneConfiguration(admitted:true,expectedDevice:120,currentDevice:120,
        defaultDevice:120,formatMatches:true,engineRunning:recoveringEngine,restartAttempts:0,restart:{resumeRestartCount+=1;recoveringEngine=true})
    precondition(explicitResume && recoveringEngine && resumeRestartCount==1)
    checks.append("explicit_resume_reconciles_notification_deferred_by_closed_capture_gate")

    // Follow the system default (a new headset), but leave a device that only
    // gives silence for the last working microphone, else the built-in one.
    let alive:(AudioObjectID)->Bool={$0 != 0}
    var policy=MicrophoneDevicePolicy()
    precondition(policy.choose(defaultDevice:200,alive:alive,builtIn:120)==200)
    policy.confirmGood(120)
    precondition(policy.reject(200,alive:alive,builtIn:120))
    precondition(policy.choose(defaultDevice:200,alive:alive,builtIn:120)==120)
    precondition(policy.effectiveDefault(200,bound:120)==120 && policy.effectiveDefault(300,bound:120)==300)
    precondition(!policy.reject(120,alive:alive,builtIn:120))
    policy.observeDefault(120)
    precondition(policy.choose(defaultDevice:200,alive:alive,builtIn:120)==200)
    var unproven=MicrophoneDevicePolicy()
    precondition(unproven.reject(200,alive:alive,builtIn:120) && unproven.choose(defaultDevice:200,alive:alive,builtIn:120)==120)
    var noFallback=MicrophoneDevicePolicy()
    precondition(!noFallback.reject(120,alive:alive,builtIn:120) && noFallback.choose(defaultDevice:120,alive:alive,builtIn:120)==120)
    var watch=SilentMicrophoneWatch()
    let zeros:[String:Any]=["last_packet_age_seconds":0.01,"last_nonzero_age_seconds":20.0]
    let sound:[String:Any]=["last_packet_age_seconds":0.01,"last_nonzero_age_seconds":0.01]
    precondition(watch.observe(paused:false,now:0,signal:zeros) == .none && watch.observe(paused:false,now:2,signal:zeros) == .none)
    precondition(watch.observe(paused:false,now:3.5,signal:zeros) == .silent && watch.observe(paused:false,now:4,signal:zeros) == .none)
    precondition(watch.observe(paused:false,now:5,signal:sound) == .heard)
    precondition(watch.observe(paused:true,now:6,signal:zeros) == .none && watch.observe(paused:false,now:7,signal:[:]) == .none)
    precondition(watch.observe(paused:false,now:10.5,signal:[:]) == .silent)
    watch.rearm(now:11)
    precondition(watch.observe(paused:false,now:12,signal:zeros) == .none && watch.observe(paused:false,now:14.5,signal:zeros) == .silent)
    var strikes=MicrophoneDevicePolicy()
    precondition(strikes.retrySilent(200) && strikes.retrySilent(200) && !strikes.retrySilent(200))
    strikes.confirmGood(200)
    precondition(strikes.retrySilent(200))
    checks.append("silent_headset_is_restarted_twice_before_falling_back_to_working_microphone")

    var channelChecks=0
    for kind:AVAudioCommonFormat in [.pcmFormatFloat32,.pcmFormatFloat64,.pcmFormatInt16,.pcmFormatInt32] {
        for interleaved in [false,true] {
            for scenario in ["first","second","same","opposite","zero"] {
                let format=AVAudioFormat(commonFormat:kind,sampleRate:48000,channels:2,interleaved:interleaved)!
                let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4800)!;buffer.frameLength=4800
                let list=UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for channel in 0..<2 {for frame in 0..<4800 {
                    let x=sin(Double(frame)*0.1)*0.2
                    let v:Double=scenario=="zero" || (channel==0 && scenario=="second") || (channel==1 && scenario=="first") ? 0:(channel==1 && scenario=="opposite" ? -x:x)
                    let offset=interleaved ? frame*2+channel:frame,base=list[interleaved ? 0:channel].mData!
                    switch kind {
                    case .pcmFormatFloat32:base.assumingMemoryBound(to:Float.self)[offset]=Float(v)
                    case .pcmFormatFloat64:base.assumingMemoryBound(to:Double.self)[offset]=v
                    case .pcmFormatInt16:base.assumingMemoryBound(to:Int16.self)[offset]=Int16(v*32767)
                    case .pcmFormatInt32:base.assumingMemoryBound(to:Int32.self)[offset]=Int32(v*2147483647)
                    default:break
                    }
                }}
                let copy=clone(buffer)!,original=hardwareChannelEnergy(buffer),copied=hardwareChannelEnergy(copy)
                precondition(zip(original,copied).allSatisfy{$0.nonzero==$1.nonzero && abs($0.rms-$1.rms)<0.00000001})
                let converter=try PCMConverter(format,microphoneChannelSelection:true),result=PCM16Energy(try converter.convert(copy))
                precondition(scenario=="zero" ? result.nonzero==0:result.nonzero>0)
                precondition(scenario != "second" || converter.selectedInputChannel==1)
                channelChecks+=1
            }
        }
    }
    checks.append("forty_copy_and_conversion_cases_preserve_second_channel_same_phase_and_antiphase")
    let switchFormat=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48000,channels:2,interleaved:false)!
    let switchingConverter=try PCMConverter(switchFormat,microphoneChannelSelection:true)
    for active in [0,1,0,1] {
        var samples=0
        for _ in 0..<10 {
            let buffer=AVAudioPCMBuffer(pcmFormat:switchFormat,frameCapacity:4800)!;buffer.frameLength=4800
            for channel in 0..<2 {for frame in 0..<4800 {buffer.floatChannelData![channel][frame]=channel==active ? Float(sin(Double(frame)*0.1)*0.2):0}}
            samples+=PCM16Energy(try switchingConverter.convert(buffer)).nonzero
        }
        precondition(samples>10000 && switchingConverter.selectedInputChannel==active);channelChecks+=1
    }
    checks.append("existing_microphone_converter_can_follow_the_live_channel_without_silence")
    // Converter and journal signal evidence exercise only generated samples.
    for channels in [1,2] {
        let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48000,channels:AVAudioChannelCount(channels),interleaved:false)!
        let input=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4800)!
        input.frameLength=4800
        for channel in 0..<channels {for i in 0..<4800 {input.floatChannelData![channel][i]=Float(sin(Double(i)*0.1)*0.2)}}
        let copy=clone(input)!,converter=try PCMConverter(format,microphoneChannelSelection:true)
        let converted=try converter.convert(copy),energy=PCM16Energy(converted)
        precondition(energy.nonzero>0 && energy.peak>0.1 && energy.rms>0.05)
        let original=hardwareInputEnergy(copy)
        precondition(original.nonzero>0 && original.peak>0.1 && original.samples==4800*channels)
    }
    checks.append("generated_hardware_buffers_clone_and_convert_without_losing_signal")
    let signalStore=try RecordingJournal(directory:directory.appendingPathComponent(UUID().uuidString),track:"mic-raw",freeSpace:{1_000_000_000})
    signalStore.recordCaptureFormat(["tap_sample_rate":48000,"input_sample_rate":16000,"input_channels":2])
    let signalBox=Mailbox(journal:signalStore)
    signalBox.put(Data(repeating:0,count:3200),at:0)
    let silent=signalBox.signalMetrics(now:ProcessInfo.processInfo.systemUptime)
    precondition(silent["hardware_pcm_frames"] as? Int==1 && silent["nonzero_samples"] as? Int==0 && silent["signal_rms"] as? Double==0)
    signalBox.put(Data([0,128,255,127]),at:0.1)
    let measured=signalBox.signalMetrics();signalBox.seal();signalStore.wait()
    precondition(measured["nonzero_samples"] as? Int==2 && measured["nonzero_frames"] as? Int==1 && measured["signal_peak"] as? Double==1)
    precondition(PCM16Energy(Data()).samples==0 && PCM16Energy(Data([0])).samples==0)
    let signalManifest=try JSONSerialization.jsonObject(with:Data(contentsOf:signalStore.directory.appendingPathComponent("mic-raw-manifest.json"))) as! [String:Any]
    let inputFormat=signalManifest["capture_input_format"] as! [String:Any]
    precondition(inputFormat["tap_sample_rate"] as? Int==48000 && inputFormat["input_sample_rate"] as? Int==16000)
    checks.append("actual_aggregate_format_persists_with_original_audio_manifest")
    checks.append("journal_signal_counters_measure_actual_pcm_not_timeline_padding")

    let padded=try RecordingJournal(directory:directory.appendingPathComponent(UUID().uuidString),track:"mic-raw",freeSpace:{1_000_000_000},alignCaptureTime:true)
    let paddedBox=Mailbox(journal:padded)
    paddedBox.put(Data(repeating:0x17,count:3200),at:0);paddedBox.put(Data(repeating:0x17,count:3200),at:2);paddedBox.seal();padded.wait()
    let padding=padded.metadata(),activity=paddedBox.signalMetrics()
    precondition(padding["alignment_padding_bytes"] as? Int==60800 && padding["admitted_pcm_bytes"] as? Int==6400 && padded.bytes()==67200)
    precondition(pauseTailTargetByte(padded)==67200 && (padding["offered_bytes"] as? Int)==67200,
                 "pause_tail_target_uses_journal_timeline_including_padding")
    precondition(activity["signal_samples"] as? Int==3200 && activity["nonzero_samples"] as? Int==3200)
    checks.append("inserted_silence_and_admitted_audio_bytes_are_recorded_independently")

    checks += try recordingJournalReliabilityChecks(directory:directory)
    checks += try await sourceCaptureCancellationChecks(config:config,directory:directory)
    checks += try await echoReliabilityChecks(directory:directory)
    for frames in [480,4800] {
        let budget=MicrophoneConversionBudget()
        let count=480000/frames
        let tickets=(0..<count).map{_ in budget.acquire(frames:frames,sampleRate:48000,channels:2)!}
        precondition(budget.acquire(frames:frames,sampleRate:48000,channels:2)==nil)
        for ticket in tickets {budget.release(ticket)}
        let resumed=budget.acquire(frames:frames,sampleRate:48000,channels:2)!
        budget.release(resumed)
        precondition((budget.snapshot()["pending_bytes_upper_bound"] as? Int)==0)
    }
    let invalidBudget=MicrophoneConversionBudget()
    precondition(invalidBudget.acquire(frames:4800,sampleRate:0,channels:2)==nil)
    precondition(invalidBudget.acquire(frames:Int.max,sampleRate:48000,channels:2)==nil)
    checks.append("microphone_conversion_reservoir_is_duration_bounded_and_recovers_across_callback_sizes")

    return ["type":"capture_safety_checks","passed":checks.count,"checks":checks,
            "microphone_channel_matrix_cases":channelChecks,"synthetic_pcm":true,"network":false,"device":false,"microphone_permission":false]
}


// Deterministic fault injection: no microphone, network or private meeting.
func recordingJournalReliabilityChecks(directory:URL)throws->[String] {
    var checks:[String]=[]
    let root=directory.appendingPathComponent("writer-reliability-"+UUID().uuidString)
    let blocked=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
    var first=true,spaceQueries=0
    let store=try RecordingJournal(directory:root,track:"mic",freeSpace:{spaceQueries+=1;return 1_000_000_000},beforeWrite:{if first {first=false;blocked.signal();release.wait()}})
    let pcm=Data((0..<320).map{UInt8($0%251)})
    try store.enqueue(pcm,at:0)
    precondition(blocked.wait(timeout:.now()+2) == .success)
    // 10 seconds of small callbacks while disk writing is stalled. The former
    // 256-packet admission reliably failed this path after 2.56 seconds.
    for i in 1..<1000 {try store.enqueue(pcm,at:Double(i)/100)}
    precondition(store.fault()==nil && store.metadata()["pending_writer_bytes"] as? Int==320000)
    store.commitAfterTranscript(320000)
    precondition(store.committed("asr")==0)
    release.signal();store.wait()
    precondition(store.committed("asr")==320000)
    var restored=Data(),cursor=0
    while let (data,_)=try store.read(cursor) {restored.append(data);cursor+=data.count}
    var expected=Data();for _ in 0..<1000 {expected.append(pcm)}
    precondition(restored==expected && spaceQueries<10)
    for _ in 0..<10000 {try store.commit("model",cursor:store.bytes())}
    for _ in 0..<1000 {store.commitAfterTranscript(store.bytes())}
    store.finish();store.wait()
    precondition(store.fault()==nil && store.processingFault()==nil && store.transcriptionIsComplete())
    precondition((store.metadata()["checkpoint_writes"] as? Int ?? 10000)<30)
    do {try store.enqueue(pcm,at:10);preconditionFailure("write after finish admitted")}catch{}
    precondition(store.fault()==nil)
    let reopened=try RecordingJournal(directory:root,track:"mic")
    precondition(reopened.bytes()==expected.count && reopened.committed("model")==expected.count && reopened.committed("asr")==expected.count)
    checks.append("ten_second_writer_stall_preserves_every_sample_and_coalesces_consumer_checkpoints")

    let failureRoot=directory.appendingPathComponent(UUID().uuidString)
    let isolated=try RecordingJournal(directory:failureRoot,track:"mic",freeSpace:{1_000_000_000})
    let transcript=failureRoot.appendingPathComponent("mic-transcript.jsonl")
    try FileManager.default.createDirectory(at:transcript,withIntermediateDirectories:true)
    isolated.record(["type":"transcript","text":"已保存原音继续录制"]);isolated.wait()
    precondition(isolated.processingFault() != nil && isolated.fault()==nil)
    for i in 0..<1000 {try isolated.enqueue(pcm,at:Double(i)/100)}
    isolated.commitAfterTranscript(320000);isolated.finish();isolated.wait()
    precondition(isolated.bytes()==320000 && isolated.committed("asr")==0 && !isolated.transcriptionIsComplete() && !isolated.eligibleForCleanup())
    // Only remove the deliberately invalid test directory to permit a retry.
    try FileManager.default.removeItem(at:transcript)
    let retry=try RecordingJournal(directory:failureRoot,track:"mic",freeSpace:{1_000_000_000})
    retry.record(["type":"transcript","text":"恢复后重试"]);retry.commitAfterTranscript(320000);retry.wait()
    precondition(retry.processingFault()==nil && retry.transcriptionIsComplete())
    let receipt=try JSONSerialization.jsonObject(with:Data(contentsOf:failureRoot.appendingPathComponent("mic-manifest.json"))) as! [String:Any]
    precondition(receipt["previous_processing_error"] is String)
    let archivedAfterRetry=try archiveAndCleanSessionAt(failureRoot,text:"恢复后的完整原文",retire:{_ in preconditionFailure("recovered audio must stay in place")})
    precondition(!archivedAfterRetry && FileManager.default.fileExists(atPath:failureRoot.appendingPathComponent("mic-000000.pcm").path))
    let archivedRetry=try RecordingJournal(directory:failureRoot,track:"mic")
    precondition(archivedRetry.transcriptionIsComplete() && !archivedRetry.eligibleForCleanup() && !archivedRetry.audioIsCleaned())
    let archivedText=try String(contentsOf:failureRoot.appendingPathComponent("archived-transcript.txt"),encoding:.utf8)
    precondition(archivedText=="恢复后的完整原文")
    checks.append("transcript_disk_error_does_not_stop_pcm_and_retry_retains_failure_history")

    let low=try RecordingJournal(directory:directory.appendingPathComponent("disk-full-"+UUID().uuidString),track:"mic",freeSpace:{0})
    try low.enqueue(pcm,at:0);low.finish();low.wait()
    precondition(low.fault()=="cache_disk_space_low" && low.bytes()==0 && !low.transcriptionIsComplete())
    checks.append("real_storage_failure_remains_explicit_and_never_reports_complete")
    return checks
}


private actor FailingEchoFixture:EchoInferenceStream {
    let invalid:Bool;var calls=0
    init(invalid:Bool){self.invalid=invalid}
    func enhance(mic:[Float],reference:[Float]) async throws -> [Float] {
        calls+=1
        if calls==1 {return []}
        if calls==2 {if invalid {return [Float.nan]};throw Failure(code:"fixture_inference_failure")}
        return mic
    }
    func flush() async throws -> [Float] {return []}
    func reset() async throws {}
}
func echoReliabilityChecks(directory:URL) async throws -> [String] {
    let first=Data(repeating:0x13,count:3200),second=Data(repeating:0x27,count:3200)
    for invalid in [false,true] {
        let processor=EchoPreprocessor(stream:FailingEchoFixture(invalid:invalid))
        let pending=await processor.process(microphone:first,at:10,reference:first,at:10)
        precondition(pending.audio.isEmpty)
        let failed=await processor.process(microphone:second,at:10.1,reference:second,at:10.1)
        precondition(failed.audio==first+second && failed.captureTime==10 && failed.status == .processingFailed)
        let flushed=await processor.flush();precondition(flushed==nil)
        let next=await processor.process(microphone:first,at:10.2,reference:first,at:10.2)
        precondition(next.audio==first && next.captureTime==10.2)
    }
    let diagnostics=EchoCaptureDiagnostics()
    let unavailable=EchoPreprocessor(stream:nil,unavailableDetail:"model_file_missing")
    diagnostics.setModel(await unavailable.diagnostics())
    let bypass=EchoProcessResult(audio:first,captureTime:10,status:.modelUnavailable,detail:"model_file_missing")
    diagnostics.recordFrame(microphone:first,reference:nil,result:bypass,referenceAligned:false,
                            referenceFailure:"reference_missing_or_misaligned")
    diagnostics.recordOutput(first)
    let snapshot=diagnostics.snapshot(micTrack:"mic-g1",rawTrack:"mic-raw-g1",referenceTrack:"reference-g1")
    let counts=snapshot["status_counts"] as? [String:Int] ?? [:]
    let micEnergy=snapshot["microphone_input"] as? [String:Any] ?? [:]
    let outputEnergy=snapshot["processed_output"] as? [String:Any] ?? [:]
    precondition(snapshot["model_available"] as? Bool==false && snapshot["model_detail"] as? String=="model_file_missing")
    precondition(snapshot["frames"] as? Int==1 && snapshot["bypass_frames"] as? Int==1 &&
                 snapshot["reference_missing_frames"] as? Int==1 && counts[EchoPreprocessorStatus.modelUnavailable.rawValue]==1)
    precondition(micEnergy["samples"] as? Int==1600 && (micEnergy["rms"] as? Double ?? 0)>0 &&
                 outputEnergy["samples"] as? Int==1600)
    let folder=directory.appendingPathComponent("echo-unread-tail-"+UUID().uuidString)
    let raw=try RecordingJournal(directory:folder,track:"mic-raw",freeSpace:{1_000_000_000})
    let clean=try RecordingJournal(directory:folder,track:"mic",freeSpace:{1_000_000_000})
    let output=Mailbox(journal:clean)
    for i in 0..<81 {try raw.enqueue(i==0 ? first:second,at:20+Double(i)/10)}
    raw.finish();raw.wait()
    precondition(output.put(first,at:20));clean.wait()
    let drain=Task {try await preserveUnprocessedMicrophoneTail(raw:raw,cleaned:output,cursor:first.count)}
    drain.cancel()
    let cursor=try await drain.value
    output.seal();clean.wait()
    precondition(cursor==raw.bytes() && clean.bytes()==raw.bytes() && clean.fault()==nil && clean.processingFault()==nil)
    var position=0
    while let (original,at)=try raw.read(position) {
        let restored=try clean.read(position)!
        precondition(original==restored.0 && at==restored.1);position+=original.count
    }
    let limited=try RecordingJournal(directory:folder,track:"mic-g1",freeSpace:{1_000_000_000})
    let limitedOutput=Mailbox(totalByteLimit:1600,journal:limited)
    do {_ = try await preserveUnprocessedMicrophoneTail(raw:raw,cleaned:limitedOutput,cursor:0);preconditionFailure("short tail admission accepted")}
    catch {precondition((error as? Failure)?.code=="echo_tail_write_incomplete")}
    limitedOutput.seal();limited.wait()
    precondition(limited.bytes()==1600 && limited.processingFault()=="echo_tail_write_incomplete" && !limited.transcriptionIsComplete())
    return ["echo_model_failure_preserves_buffered_and_current_pcm_exactly_once",
            "echo_diagnostics_snapshot_is_bounded_and_explains_model_bypass_and_energy",
            "cancelled_echo_consumer_preserves_eight_second_unread_raw_tail",
            "partially_admitted_echo_tail_is_persistently_incomplete"]
}


// Replays the reported 1:2 audio/padding failure with generated PCM and the real
// platform converter. Does not create an audio device, capture, or call ASR.
// Device-free production journal/converter check. No CoreAudio device or network.
func captureContinuityRegression(directory:URL)throws->[String:Any] {
    var healthy=CaptureContinuityCheck(),gapped=CaptureContinuityCheck(),broken=CaptureContinuityCheck()
    var rejectedAt:Int?
    for k in 0..<200 {
        precondition(healthy.accepts(bytes:640,at:100+Double(k)*0.02))
        precondition(gapped.accepts(bytes:640,at:100+Double(k)*0.02+(k>=50 ? 2:0)))
        if rejectedAt==nil && !broken.accepts(bytes:212,at:100+Double(k)*0.02) {rejectedAt=k}
    }
    precondition(rejectedAt != nil && rejectedAt!<50)
    var largerPackets=CaptureContinuityCheck(),largerRejected=false
    for k in 0..<20 {
        if !largerPackets.accepts(bytes:1066,at:100+Double(k)*0.1) {largerRejected=true;break}
    }
    precondition(largerRejected)
    var reverse=CaptureContinuityCheck()
    precondition(reverse.accepts(bytes:640,at:100) && !reverse.accepts(bytes:640,at:99))
    func replay(rate:Double,frames:Int,name:String)throws->[String:Any] {
        let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:rate,channels:2,interleaved:false)!
        let converter=try PCMConverter(format)
        let folder=directory.appendingPathComponent(name+"-"+UUID().uuidString)
        let journal=try RecordingJournal(directory:folder,track:"remote",freeSpace:{1_000_000_000},alignCaptureTime:true)
        journal.recordCaptureFormat(["input_sample_rate":rate,"input_channels":2])
        var failure:String?
        for k in 0..<500 {
            let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(frames))!
            buffer.frameLength=AVAudioFrameCount(frames)
            for c in 0..<2 {for i in 0..<frames {buffer.floatChannelData![c][i]=Float(sin(Double(k*frames+i)*2*Double.pi*440/16000)*0.2)}}
            let pcm=try converter.convert(buffer)
            if !pcm.isEmpty {
                do {try journal.enqueue(pcm,at:100+Double(k)*0.02)}
                catch let error as Failure {failure=error.code;break}
            }
        }
        journal.finish();journal.wait()
        let file=folder.appendingPathComponent("remote-manifest.json")
        let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        if failure != nil {precondition(((manifest["capture_timing_failure"] as? [String:Any])?["gap_fraction"] as? Double ?? 0) > 0.20)}
        let reopened=try RecordingJournal(directory:folder,track:"remote",freeSpace:{1_000_000_000},alignCaptureTime:true)
        precondition(reopened.bytes()==journal.bytes() && reopened.fault()==journal.fault())
        if failure != nil {
            reopened.wait()
            let persisted=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
            precondition(persisted["capture_timing_failure"] as? [String:Double]==manifest["capture_timing_failure"] as? [String:Double])
        }
        return ["error":failure as Any? ?? NSNull(),"written":journal.bytes(),"padding":manifest["alignment_padding_bytes"]!,
                "incomplete":journal.metadata()["incomplete"]!,"failure_persisted":failure==manifest["error"] as? String]
    }
    let wrong=try replay(rate:48000,frames:320,name:"wrong")
    precondition(wrong["error"] as? String=="cache_audio_timing_mismatch" && wrong["failure_persisted"] as? Bool==true)
    precondition((wrong["written"] as! Int)<32000)
    var rates:[[String:Any]]=[]
    for (rate,frames) in [(8000.0,160),(16000.0,320),(44100.0,882),(48000.0,960)] {
        let result=try replay(rate:rate,frames:frames,name:"valid")
        precondition(result["error"] is NSNull && result["padding"] as? Int==0 && abs((result["written"] as! Int)-320000)<2000)
        rates.append(["rate":rate,"result":result])
    }
    return ["wrong_format":wrong,"valid_rates":rates,"detected_packet":rejectedAt!,"long_source_gap_allowed":true,"capture":false,"cloud":false]
}

func applicationTapFormatRegression()throws->[String:Any] {
    func replay(declaredRate:Double)throws->(pcm:Int,padding:Int) {
        let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:declaredRate,channels:2,interleaved:false)!
        let converter=try PCMConverter(format)
        var offered=0,padding=0,pcm=0
        for packet in 0..<500 {
            let input=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:320)!;input.frameLength=320
            for channel in 0..<2 {for frame in 0..<320 {input.floatChannelData![channel][frame]=Float(sin(Double(packet*320+frame)*2*Double.pi*440/16000)*0.2)}}
            let data=try converter.convert(input)
            // Same time-alignment contract as RecordingJournal.enqueue: each
            // hardware packet is 20 ms at the actual aggregate rate of 16 kHz.
            let expectedSamples=Int((Double(packet)*0.02*16000).rounded())
            let gap=max(0,expectedSamples-offered/2),gapBytes=gap>160 ? gap*2:0
            offered+=data.count+gapBytes;padding+=gapBytes;pcm+=data.count
        }
        return(pcm,padding)
    }
    let wrong=try replay(declaredRate:48000),correct=try replay(declaredRate:16000)
    let fraction=Double(wrong.padding)/Double(wrong.pcm+wrong.padding)
    precondition(abs(fraction-2.0/3.0)<0.002)
    precondition(correct.pcm==320000 && correct.padding==0)
    var matching=ApplicationTapClockCheck(),mismatching=ApplicationTapClockCheck(),rejected=false
    for packet in 0..<20 {
        var timestamp=AudioTimeStamp();timestamp.mFlags=[.hostTimeValid,.sampleTimeValid]
        timestamp.mHostTime=AVAudioTime.hostTime(forSeconds:100+Double(packet)*0.02)
        timestamp.mSampleTime=Double(packet*320)
        precondition(matching.accepts(timestamp,sampleRate:16000))
        if !mismatching.accepts(timestamp,sampleRate:48000) {rejected=true}
    }
    precondition(rejected)
    var invalid=ApplicationTapClockCheck(),reverse=AudioTimeStamp();reverse.mFlags=[.hostTimeValid,.sampleTimeValid]
    reverse.mHostTime=AVAudioTime.hostTime(forSeconds:100);reverse.mSampleTime=320
    precondition(invalid.accepts(reverse,sampleRate:16000))
    reverse.mHostTime=AVAudioTime.hostTime(forSeconds:100.02);reverse.mSampleTime=0
    precondition(!invalid.accepts(reverse,sampleRate:16000))
    return ["old_padding_fraction":fraction,"correct_pcm_bytes":correct.pcm,"correct_padding_bytes":correct.padding,
            "same_device_rate_change_rejected":rejected,"synthetic_pcm":true,"capture":false,"network":false]
}
