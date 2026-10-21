import Foundation
import CoreAudio
import Darwin

// The source-aware path is intentionally separate from the legacy selected-app
// trial. Each routed source generation owns a journal and, in cloud mode, a Lane.
// Raw microphone and playback reference never enter an ASR Lane.
@available(macOS 14.2, *)
private final class SourceCaptureEntry {
    let sourceID: String
    let store: RecordingJournal
    var producer: Mailbox
    let asrBox: Mailbox
    let modelBox: Mailbox
    private let resourcesLock = NSLock()
    private var retainedLane: Lane?
    var lane: Lane? {
        get { resourcesLock.lock(); defer { resourcesLock.unlock() }; return retainedLane }
        set { resourcesLock.lock(); retainedLane = newValue; resourcesLock.unlock() }
    }
    private(set) var consumersStarted = false
    private var retainedTasks: [Task<Void, Never>] = []
    var tasks: [Task<Void, Never>] {
        get { resourcesLock.lock(); defer { resourcesLock.unlock() }; return retainedTasks }
        set { resourcesLock.lock(); retainedTasks = newValue; resourcesLock.unlock() }
    }
    private var drainTask: Task<Void, Never>?
    private(set) var captureEnded = false
    init(id: String, directory: URL, clock: CaptureBudgetClock, limit: Int?) throws {
        sourceID = id
        store = try RecordingJournal(directory: directory, track: id, alignCaptureTime: true)
        producer = Mailbox(captureClock: clock, totalByteLimit: limit, journal: store)
        asrBox = Mailbox(journal: store, producer: false)
        modelBox = Mailbox(journal: store, producer: false)
    }
    init(id: String, store: RecordingJournal, producer: Mailbox) {
        sourceID = id
        self.store = store
        self.producer = producer
        asrBox = Mailbox(journal: store, producer: false)
        modelBox = Mailbox(journal: store, producer: false)
    }
    func endCapture() {
        guard !captureEnded else { return }
        captureEnded = true
        producer.seal()
        drainWhenReady()
    }
    func drainWhenReady() {
        guard captureEnded, drainTask == nil, let lane else { return }
        let pending = tasks
        drainTask = Task { [weak self] in
            for task in pending { await task.value }
            await lane.stop() // Releases this generation's SDK/model and socket.
            self?.lane = nil
            self?.tasks = []
        }
    }
    func attach(_ lane: Lane) { self.lane = lane; consumersStarted = true }
    func awaitDrain() async { if let drainTask { await drainTask.value } }
}

// CoreAudio routes keep their stable source ID. Each confirmed departure or
// failed tap retires one journal; a later appearance gets a new ASR time base.
final class AudioTrackGenerations {
    private var numbers: [String: Int] = [:]
    private(set) var active: [String: String] = [:]
    init(existing:[String]=[]) {
        for track in existing {
            guard let core=audioSourceCoreID(track),core != "mic" else{continue}
            let suffix=track.replacingOccurrences(of:core+"-g",with:"")
            let number=Int(suffix) ?? 0
            numbers[core]=max(numbers[core] ?? 0,number)
        }
    }
    func current(_ coreID: String) -> String? { active[coreID] }
    func open(_ coreID: String) throws -> String {
        if let id = active[coreID] { return id }
        let number = (numbers[coreID] ?? 0) + 1
        guard let id = sourceGenerationTrackID(coreID, generation: number) else {
            throw Failure(code: "source_generation_limit")
        }
        numbers[coreID] = number
        active[coreID] = id
        return id
    }
    @discardableResult func retire(_ coreID: String) -> String? { active.removeValue(forKey: coreID) }
}

private struct ReferencePacket {
    let audio: Data
    let at: Double
    var end: Double { at + Double(audio.count) / 32_000 }
}

private final class EchoResetControl {
    private let lock = NSLock()
    private var generation = 0
    private var referenceIntervals: [(start: Double, end: Double?)] = []
    func request() { lock.lock(); generation += 1; lock.unlock() }
    func current() -> Int { lock.lock(); defer { lock.unlock() }; return generation }
    func referenceStarted(at time: Double) {
        lock.lock(); defer { lock.unlock() }
        if referenceIntervals.last?.end == nil && !referenceIntervals.isEmpty { return }
        referenceIntervals.append((time, nil))
    }
    func referenceStopped(at time: Double) {
        lock.lock(); defer { lock.unlock() }
        guard !referenceIntervals.isEmpty, referenceIntervals[referenceIntervals.count - 1].end == nil else { return }
        let index = referenceIntervals.count - 1
        referenceIntervals[index].end = max(referenceIntervals[index].start, time)
    }
    func referenceCovers(_ start: Double, end: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        referenceIntervals.removeAll { ($0.end ?? .infinity) < start - 1 }
        return referenceIntervals.contains { interval in
            start >= interval.start - 0.010 && end <= (interval.end ?? .infinity) + 0.010
        }
    }
}

// Hardware teardown and upload drain are independent. The capture loop never
// waits on a CoreAudio stop call; it only reads this bounded state for resume.
final class CapturePauseTransition {
    private let lock=NSLock()
    private var hardwarePending=3
    private var uploadDone=false
    private var failure:String?
    func finishHardwarePart(_ code:String?) {lock.lock();hardwarePending=max(0,hardwarePending-1);if failure==nil {failure=code};lock.unlock()}
    func finishUploadDrain() {lock.lock();uploadDone=true;lock.unlock()}
    func snapshot()->(hardwareDone:Bool,uploadDone:Bool,failure:String?) {lock.lock();defer{lock.unlock()};return(hardwarePending==0,uploadDone,failure)}
}

// Pause receipts have a safety deadline in the parent process. Run the small
// state poll on a private libdispatch queue so blocked cooperative Tasks cannot
// starve control acknowledgements. The timer is cancelled at session teardown.
final class CapturePauseAcknowledgementMonitor {
    private let timer: DispatchSourceTimer
    init(poll: @escaping () -> Void) {
        let queue=DispatchQueue(label:"meeting.capture.pause-ack",qos:.userInitiated)
        timer=DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now(),repeating:.milliseconds(5),leeway:.milliseconds(2))
        timer.setEventHandler(handler:poll)
        timer.resume()
    }
    func cancel(){timer.cancel()}
    deinit {timer.cancel()}
}

// CoreAudio notifications run outside the capture loop. Record only the
// recoverable route-change signal there; the capture loop owns pause state,
// revisions and acknowledgements. Repeated notifications collapse into one
// request, and its cause is attached to the resulting pause revision.
final class CaptureInputDeviceChangePause {
    private let lock=NSLock()
    private var pending=false
    private var pendingReason:String?
    private var reasons:[sig_atomic_t:String]=[:]

    @discardableResult func request(reason:String)->Bool {
        guard ["input_device_changed","mic_conversion_backpressure"].contains(reason) else{return false}
        lock.lock();defer{lock.unlock()}
        pending=true
        // If two independent faults race, expose the lost-input condition to
        // the person before the less destructive route-change explanation.
        if pendingReason == nil || reason == "mic_conversion_backpressure" {pendingReason=reason}
        return true
    }

    func applyPendingPause()->sig_atomic_t? {
        lock.lock();defer{lock.unlock()}
        guard pending else{return nil}
        pending=false
        let reason=pendingReason ?? "input_device_changed"
        pendingReason=nil
        guard capturePaused==0,captureFinishing==0,interrupted==0 else{return nil}
        recordingPauseHandler(SIGUSR1)
        let revision=captureControlRevision
        reasons[revision]=reason
        return revision
    }

    func takeReason(for revision:sig_atomic_t)->String? {
        lock.lock();defer{lock.unlock()}
        return reasons.removeValue(forKey:revision)
    }
}

/// Detects a microphone that runs but delivers no sound: no packets, or only
/// digital zeros. A real microphone in a quiet room still yields non-zero
/// noise, so this does not fire on ordinary silence.
struct SilentMicrophoneWatch {
    enum Verdict {case none,heard,silent}
    static let grace=3.0,silentAfter=3.0,stalledAfter=4.0
    private var liveSince:Double?
    private var reported=false
    /// Gives a restarted device a fresh grace period.
    mutating func rearm(now:Double) {liveSince=now;reported=false}
    mutating func observe(paused:Bool,now:Double,signal:[String:Any])->Verdict {
        if paused {liveSince=nil;reported=false;return .none}
        guard let since=liveSince else {liveSince=now;return .none}
        let packetAge=signal["last_packet_age_seconds"] as? Double ?? .infinity
        let soundAge=signal["last_nonzero_age_seconds"] as? Double ?? .infinity
        if packetAge<0.5 && soundAge<0.5 {reported=false;return .heard}
        guard !reported,now-since>=Self.grace else {return .none}
        let live=now-since
        if (packetAge<0.5 && soundAge>=min(live,Self.silentAfter)) || packetAge>=max(min(live,Self.stalledAfter),Self.grace) {
            reported=true;return .silent
        }
        return .none
    }
}

func revalidateMicrophoneOrPause(routeChangePause:CaptureInputDeviceChangePause,
                                 validate:() throws->Bool) throws->Bool {
    do {return try validate()}
    catch let error as Failure where error.code=="input_device_changed" {
        // Revalidation can discover the route change before the main loop gets
        // another turn. Let the capture loop's existing resume defer tear the
        // hardware down after the same revision/gate pause is requested.
        _=routeChangePause.request(reason:error.code)
        _=routeChangePause.applyPendingPause()
        return false
    }
}

// Used by terminal cleanup after finish closes capture admission. Waiting is
// bounded by the original pause deadline and stays asynchronous so the helper
// can still react to cancellation/watchdog tasks while hardware teardown runs.
func awaitCaptureHardwareStop(_ transition:CapturePauseTransition,until deadline:Double) async -> (hardwareDone:Bool,failure:String?) {
    while !transition.snapshot().hardwareDone && ProcessInfo.processInfo.systemUptime<deadline && !Task.isCancelled {
        try? await Task.sleep(nanoseconds:5_000_000)
    }
    let status=transition.snapshot()
    return(status.hardwareDone,status.failure)
}

final class CapturePauseTailBarrier {
    private let lock=NSLock()
    private var targets:[sig_atomic_t:Int]=[:]
    private var finalized=Set<sig_atomic_t>()
    private var completed=Set<sig_atomic_t>()
    func begin(revision:sig_atomic_t,throughByte:Int) {lock.lock();targets[revision]=max(0,throughByte);lock.unlock()}
    // The target is finalized only after every capture writer has stopped.
    // This includes callbacks which passed admission just before the pause gate
    // closed, so the echo consumer cannot declare a shorter tail complete.
    func finalize(revision:sig_atomic_t,throughByte:Int) {
        lock.lock();targets[revision]=max(targets[revision] ?? 0,max(0,throughByte));finalized.insert(revision);lock.unlock()
    }
    func waitForCaptureStop(_ revision:sig_atomic_t) async -> Bool {
        while !isFinalized(revision) && !Task.isCancelled {
            if interrupted>=2 || capturePaused==0 || captureControlRevision != revision {return false}
            try? await Task.sleep(nanoseconds:5_000_000)
        }
        return isFinalized(revision) && !Task.isCancelled && capturePaused != 0 && captureControlRevision==revision
    }
    private func isFinalized(_ revision:sig_atomic_t)->Bool {lock.lock();defer{lock.unlock()};return finalized.contains(revision)}
    func pending()->(sig_atomic_t,Int)? {
        lock.lock();defer{lock.unlock()}
        guard let revision=targets.keys.filter({finalized.contains($0) && !completed.contains($0)}).min(),let target=targets[revision] else{return nil}
        return(revision,target)
    }
    func complete(_ revision:sig_atomic_t) {lock.lock();completed.insert(revision);lock.unlock()}
    func isComplete(_ revision:sig_atomic_t)->Bool {lock.lock();defer{lock.unlock()};return completed.contains(revision)}
    func wait(_ revision:sig_atomic_t) async -> Bool {
        while !isComplete(revision) && !Task.isCancelled {
            if interrupted>=2 || (interrupted>0 && captureTailDrainAllowed==0) || capturePaused==0 || captureControlRevision != revision {return false}
            try? await Task.sleep(nanoseconds:5_000_000)
        }
        return isComplete(revision) && !Task.isCancelled
    }
}

private final class CaptureASRConsumerInventory {
    struct Snapshot {
        let tracks:[String]
        let completed:[(String,String)]
    }
    private struct ConsumerState {let hasSavedAudio:()->Bool;var finished=false;var complete=false}
    private let lock=NSLock();private var sources:[String:ConsumerState]=[:]
    // The callback is a bounded Mailbox counter read (NSLock only), not a
    // journal or actor wait. Register at source creation so a pause racing
    // startConsumers still sees bytes already admitted to that source.
    func register(_ track:String,hasSavedAudio:@escaping()->Bool){lock.lock();sources[track]=ConsumerState(hasSavedAudio:hasSavedAudio);lock.unlock()}
    func finished(_ track:String,complete:Bool){lock.lock();if var state=sources[track] {state.finished=true;state.complete=complete;sources[track]=state};lock.unlock()}
    // Every saved track is named in the ACK so the UI can settle even when all
    // sources were retired before the pause. Finished consumers are replayed
    // immediately after the ACK; live consumers report when their tail drains.
    func snapshot(revision:sig_atomic_t)->Snapshot {
        lock.lock();let current=sources;lock.unlock()
        var tracks:[String]=[],completed:[(String,String)]=[],waiting=Set<String>()
        for (track,state) in current.sorted(by:{$0.key<$1.key}) {
            tracks.append(track)
            if state.finished {completed.append((track,state.complete ? "complete":"pending"))}
            else {waiting.insert(track)}
        }
        lock.lock();defer{lock.unlock()}
        pendingByRevision[revision]=waiting
        if pendingByRevision.count>4 {
            for key in pendingByRevision.keys.sorted().dropLast(4) {pendingByRevision.removeValue(forKey:key)}
        }
        return Snapshot(tracks:tracks,completed:completed)
    }
    // Called only after device stop and the mic echo-tail barrier. At that
    // point a track with no admitted bytes cannot gain a late callback, and
    // needs a terminal report even though no ASR consumer was necessary.
    func finishEmpty(revision:sig_atomic_t)->[String] {
        lock.lock();let current=sources,pending=pendingByRevision[revision] ?? [];lock.unlock()
        let empty=pending.filter{track in current[track]?.hasSavedAudio()==false}.sorted()
        lock.lock();defer{lock.unlock()}
        var completed:[String]=[]
        for track in empty {
            guard let state=sources[track],!state.finished,
                  pendingByRevision[revision]?.contains(track)==true else{continue}
            // Empty for this pause only: it can receive audio after resume.
            pendingByRevision[revision]?.remove(track)
            completed.append(track)
        }
        return completed
    }
    private var pendingByRevision:[sig_atomic_t:Set<String>]=[:]
    func shouldReport(_ track:String,revision:sig_atomic_t)->Bool {lock.lock();defer{lock.unlock()};return pendingByRevision[revision]?.contains(track)==true}
    func resolved(_ track:String,revision:sig_atomic_t){lock.lock();pendingByRevision[revision]?.remove(track);lock.unlock()}
}

// RecordingJournal.wait() synchronizes on its serial writer queue. Keep that
// blocking synchronization off Swift's cooperative executor when an ASR task
// retires a sealed source.
private func waitForSourceJournal(_ store:RecordingJournal) async {
    await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
        DispatchQueue.global(qos:.utility).async {store.wait();continuation.resume()}
    }
}

func waitForFinalCaptureJournals(_ stores:[RecordingJournal]) {
    for store in stores {store.wait()}
}

// Once hardware is closed, cancellation of optional enhancement must not
// silently discard the portion of the microphone journal it never consumed.
// This is local PCM only; it neither restarts inference nor uploads audio.
func preserveUnprocessedMicrophoneTail(raw:RecordingJournal,cleaned:Mailbox,cursor:Int) async throws -> Int {
    let deadline=ProcessInfo.processInfo.systemUptime+5
    while !raw.isEnded() && ProcessInfo.processInfo.systemUptime<deadline {
        await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
            DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+0.01) {continuation.resume()}
        }
    }
    guard raw.isEnded() else{throw Failure(code:"echo_raw_tail_not_sealed")}
    await waitForSourceJournal(raw)
    var position=cursor
    while let (pcm,at)=try raw.read(position) {
        let before=cleaned.journal?.metadata()["admitted_pcm_bytes"] as? Int ?? -1
        guard cleaned.put(pcm,at:at),
              let after=cleaned.journal?.metadata()["admitted_pcm_bytes"] as? Int,
              before>=0,after-before==pcm.count else{
            let code=cleaned.journal?.fault() ?? "echo_tail_write_incomplete"
            cleaned.journal?.setProcessingError(code)
            throw Failure(code:code)
        }
        position+=pcm.count
        if (cleaned.journal?.metadata()["pending_writer_bytes"] as? Int ?? 0)>=320000 {
            if let store=cleaned.journal {await waitForSourceJournal(store)}
        }
    }
    if let store=cleaned.journal {await waitForSourceJournal(store)}
    try cleaned.checkFault()
    return position
}

// Replace only a failed hardware writer. Readers and the journal remain alive,
// so PCM accepted before the fault is still consumed in order after recovery.
func renewOptionalCaptureWriter(_ box: inout Mailbox) -> String? {
    guard let code = box.captureCallbackError(), let replacement = box.replacementAfterCaptureFailure() else { return nil }
    box = replacement
    return code
}

// Retain only the small window needed for the next mic packet. This neither
// attributes reference audio to a person nor forwards it to cloud ASR.
private func referenceForMic(_ packets: [ReferencePacket], at micAt: Double, bytes: Int) -> ReferencePacket? {
    let micEnd = micAt + Double(bytes) / 32_000
    var start: Double?
    var result = Data()
    var expected: Double?
    for packet in packets where packet.end > micAt && packet.at < micEnd {
        let drop = max(0, Int(((micAt - packet.at) * 16_000).rounded(.up)))
        let offset = min(packet.audio.count, drop * 2)
        let packetStart = packet.at + Double(offset) / 32_000
        if let expected, abs(packetStart - expected) > 0.002 { return nil }
        if start == nil { start = packetStart }
        result.append(packet.audio.dropFirst(offset))
        expected = packet.end
        if result.count >= bytes { break }
    }
    guard let start, start <= micAt + 0.010, start >= micAt - 0.010,
          result.count >= bytes * 4 / 5 else { return nil }
    return ReferencePacket(audio: Data(result.prefix(bytes)), at: start)
}

@inline(__always)
private func referenceWindowReady(_ packets: [ReferencePacket], at micAt: Double, bytes: Int,
                                  resetControl: EchoResetControl) -> Bool {
    resetControl.referenceCovers(micAt, end: micAt + Double(bytes) / 32_000) &&
        referenceForMic(packets, at: micAt, bytes: bytes) != nil
}

@inline(__always)
private func referencePacketIsPending(_ packets: [ReferencePacket], at micAt: Double, bytes: Int,
                                      resetControl: EchoResetControl) -> Bool {
    resetControl.referenceCovers(micAt, end: micAt + Double(bytes) / 32_000) &&
        referenceForMic(packets, at: micAt, bytes: bytes) == nil
}

@inline(__always)
func pauseTailTargetByte(_ store: RecordingJournal) -> Int {
    store.metadata()["offered_bytes"] as? Int ?? store.bytes()
}

@discardableResult
private func resumeCaptureTimeline(clock: CaptureBudgetClock, resetControl: EchoResetControl,
                                   referenceAvailable: Bool, hardwareReady: Bool,
                                   at uptime: Double) -> Bool {
    guard hardwareReady else { return false }
    clock.resume(at: uptime)
    if referenceAvailable { resetControl.referenceStarted(at: clock.timestamp(uptime)) }
    resetControl.request()
    return true
}

@inline(__always)
private func needsMissedPauseResumeReconciliation(requestedPaused: Bool, locallyPaused: Bool,
                                                  transitionPending: Bool, hardwareReady: Bool,
                                                  uploadPaused: Bool) -> Bool {
    !requestedPaused && !locallyPaused && !transitionPending && !hardwareReady && !uploadPaused
}

@inline(__always)
private func captureControlGatesMatch(requestedPaused: Bool, capturePaused: Bool,
                                      hardwareReady: Bool, uploadPaused: Bool) -> Bool {
    requestedPaused ? (capturePaused && !hardwareReady && !uploadPaused) :
        (!capturePaused && hardwareReady && !uploadPaused)
}

@available(macOS 14.2, *)
private func consumeEcho(
    config: Config, raw: RecordingJournal, reference: RecordingJournal,
    cleaned: Mailbox, resetControl: EchoResetControl, pauseTail:CapturePauseTailBarrier,
    failure: @escaping (String) -> Void, processorOverride: EchoPreprocessor? = nil,
    onReferenceWait: (() -> Void)? = nil, onEmptyRawPoll: (() -> Void)? = nil
) async {
    let modelPath = (config.echoModelDirectory ?? config.localSpeakerDirectory).map(URL.init(fileURLWithPath:)) ??
        URL(fileURLWithPath: (Bundle.main.object(forInfoDictionaryKey: "AdapterRoot") as? String ?? "") + "/native/local-speaker-install/runtime-models")
    let processor:EchoPreprocessor
    if let processorOverride {processor=processorOverride}
    else {processor=await EchoPreprocessor.load(modelDirectory:modelPath)}
    var micCursor = 0
    var referenceCursor = 0
    var window: [ReferencePacket] = []
    var referenceUsable = true
    var lastStatus: String?
    var cleanedWriteFailureReported = false
    var seenReset = resetControl.current()
    func reportCleanedWriteFailure() -> Bool {
        guard let code=cleaned.journal?.processingFault() ?? cleaned.journal?.fault() else{return false}
        if !cleanedWriteFailureReported {
            cleanedWriteFailureReported=true
            emit(["type":"processing_failed","session":config.session,"consumer":"echo",
                  "track":"mic","reason":code,"audio_retained":true,"retry_available":true])
        }
        return true
    }
    func writeCleaned(_ audio:Data,at captureTime:Double) {
        guard !audio.isEmpty else{return}
        let before=cleaned.journal?.metadata()["admitted_pcm_bytes"] as? Int ?? -1
        let accepted=cleaned.put(audio,at:captureTime)
        let after=cleaned.journal?.metadata()["admitted_pcm_bytes"] as? Int ?? -1
        if !accepted || before<0 || after-before != audio.count {
            cleaned.journal?.setProcessingError("echo_output_write_incomplete")
            _ = reportCleanedWriteFailure()
        }
    }
    func completePauseIfReady() async {
        guard let (revision,target)=pauseTail.pending(),micCursor>=target else{return}
        if let tail=await processor.reset(reason:"recording_pause_tail"),!tail.audio.isEmpty {
            writeCleaned(tail.audio,at:tail.captureTime)
        }
        cleaned.journal?.wait()
        _ = reportCleanedWriteFailure()
        window.removeAll()
        pauseTail.complete(revision)
    }
    do {
        while !Task.isCancelled && interrupted < 2 {
            if reportCleanedWriteFailure() {break}
            let reset = resetControl.current()
            if reset != seenReset {
                if let tail = await processor.reset(reason: "recording_pause_boundary"), !tail.audio.isEmpty {
                    writeCleaned(tail.audio,at:tail.captureTime)
                }
                if reportCleanedWriteFailure() {break}
                window.removeAll()
                seenReset = reset
            }
            await completePauseIfReady()
            guard let (mic, stamp) = try raw.read(micCursor) else {
                if raw.isEnded() { break }
                onEmptyRawPoll?()
                try await Task.sleep(nanoseconds: 5_000_000)
                continue
            }
            micCursor += mic.count
            var currentPacketConsumed=false
            let targetEnd = stamp + Double(mic.count) / 32_000
            if referenceUsable && referencePacketIsPending(window, at: stamp, bytes: mic.count, resetControl: resetControl) {
                let deadline = ProcessInfo.processInfo.systemUptime + 0.040
                repeat {
                    do {
                        if let (packet, at) = try reference.read(referenceCursor) {
                            referenceCursor += packet.count
                            window.append(ReferencePacket(audio: packet, at: at))
                            if window.last!.end >= targetEnd - 0.010 { break }
                        } else if reference.isEnded() || ProcessInfo.processInfo.systemUptime >= deadline { break }
                        else {onReferenceWait?();try await Task.sleep(nanoseconds: 2_000_000)}
                    } catch is CancellationError {
                        break
                    } catch {
                        referenceUsable=false;window.removeAll()
                        emit(["type":"echo_status","session":config.session,"track":"mic",
                              "state":"reference_unavailable","detail":"reference_journal_read_failed",
                              "enhanced":false,"raw_audio_retained":true,"reference_uploaded":false])
                        break
                    }
                } while true
            }
            if Task.isCancelled {
                if !currentPacketConsumed {micCursor -= mic.count}
                break
            }
            window.removeAll { $0.end < stamp - 0.3 }
            let aligned = resetControl.referenceCovers(stamp, end: targetEnd) ?
                referenceForMic(window, at: stamp, bytes: mic.count) : nil
            let output = await processor.process(microphone: mic, at: stamp,
                                                 reference: aligned?.audio ?? Data(),
                                                 at: aligned?.at ?? stamp)
            currentPacketConsumed=true
            if !output.audio.isEmpty {writeCleaned(output.audio,at:output.captureTime)}
            if reportCleanedWriteFailure() {break}
            let status = aligned == nil && output.status != .modelUnavailable ?
                "reference_unavailable" : output.status.rawValue
            if status != lastStatus {
                lastStatus = status
                emit(["type": "echo_status", "track": "mic", "state": status,
                      "detail": aligned == nil && output.status != .modelUnavailable ?
                          "reference_missing_or_misaligned_raw_microphone_used" : (output.detail ?? ""),
                      "enhanced": output.wasEnhanced,
                      "raw_audio_retained": true, "reference_uploaded": false])
            }
            try cleaned.checkFault()
        }
        if let tail = await processor.flush(), !tail.audio.isEmpty {
            writeCleaned(tail.audio,at:tail.captureTime)
        }
        cleaned.journal?.wait()
        _ = reportCleanedWriteFailure()
    } catch is CancellationError {
        // Cancellation is an expected lifecycle event. The current packet is
        // either already processed or its cursor was rewound before exit.
    } catch {
        let code=(error as? Failure)?.code ?? "echo_processing_failed"
        cleaned.journal?.setProcessingError(code)
        if let audioFault=raw.fault() {failure(audioFault)}
        else {
            emit(["type":"processing_failed","session":config.session,"consumer":"echo",
                  "track":"mic","reason":code,"audio_retained":true,"retry_available":false])
        }
    }
    // A forced stop can leave seconds of already-recorded PCM behind the
    // enhancement cursor. Preserve that suffix after flushing model latency.
    if (Task.isCancelled || interrupted>=2),cleaned.journal?.fault()==nil {
        if let tail=await processor.flush(),!tail.audio.isEmpty {writeCleaned(tail.audio,at:tail.captureTime)}
        do {micCursor=try await preserveUnprocessedMicrophoneTail(raw:raw,cleaned:cleaned,cursor:micCursor)}
        catch {
            let code=(error as? Failure)?.code ?? "echo_tail_incomplete"
            cleaned.journal?.setProcessingError(code)
            emit(["type":"processing_failed","session":config.session,"consumer":"echo","track":"mic",
                  "reason":code,"audio_retained":true,"retry_available":true])
        }
    }
    cleaned.seal()
}

@available(macOS 14.2, *)
func runSourceCaptureSession(config: Config) async throws {
    guard config.bundle == "*system*", config.useMic, config.resumeCacheID == nil else {
        throw Failure(code: "source_capture_scope_invalid")
    }
    let cloud = !config.isLocalOnly
    let cacheID = config.appendCaptureCacheID ?? UUID().uuidString
    let directory = meetingCacheRoot().appendingPathComponent(cacheID)
    if config.appendCaptureCacheID == nil {_ = try prepareMeetingCacheRoot();try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
    let writerLease=try SessionCacheWriterLease.acquire(directory:directory)
    defer {writerLease.release()}
    let existingMetadata:[String:Any]
    let existingTracks:[String]
    let reservedTracks:Set<String>
    if config.appendCaptureCacheID != nil {
        let file=directory.appendingPathComponent("meeting.json")
        guard let value=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any],
              value["session"] as? String==config.session,value["bundle"] as? String==config.bundle,
              (value["capture_mode"] as? String=="local_only")==config.isLocalOnly else{throw Failure(code:"append_capture_scope_invalid")}
        existingMetadata=value;existingTracks=try meetingAudioTracks(in:directory,transcriptOnly:false)
        reservedTracks=reservedMeetingAudioTracks(in:directory,metadata:value)
    } else {existingMetadata=[:];existingTracks=[];reservedTracks=[]}
    let cohort=["mic","mic-raw","reference"]
    let generation:Int? = config.appendCaptureCacheID == nil && cohort.allSatisfy({!reservedTracks.contains($0)}) ? 0:
        (1...999).first{index in cohort.allSatisfy{!reservedTracks.contains($0+"-g"+String(index))}}
    let rawTrack=generation.map{$0==0 ? "mic-raw":"mic-raw-g"+String($0)} ?? ""
    let referenceTrack=generation.map{$0==0 ? "reference":"reference-g"+String($0)} ?? ""
    // In a continued meeting the microphone is "mic-gN"; compare with micTrack,
    // never the literal "mic", when telling the microphone apart from app sources.
    let micTrack=generation.map{$0==0 ? "mic":"mic-g"+String($0)} ?? ""
    guard !rawTrack.isEmpty,!referenceTrack.isEmpty,!micTrack.isEmpty else{throw Failure(code:"source_generation_limit")}
    let continuation=captureContinuation(in:directory,metadata:existingMetadata)
    let clock = CaptureBudgetClock(zone:continuation.zone,
                                   continuationOrigin:config.appendCaptureCacheID == nil ? nil:continuation.origin,
                                   continuationElapsed:continuation.elapsed,priorAnchors:continuation.anchors)
    let state = CaptureRunState()
    let limit:Int? = config.unlimitedSession==true ? nil:Int(config.maxSeconds * 32_000)
    let rawStore = try RecordingJournal(directory: directory, track: rawTrack, alignCaptureTime: true)
    let referenceStore = try RecordingJournal(directory: directory, track: referenceTrack, alignCaptureTime: true)
    let micStore = try RecordingJournal(directory: directory, track: micTrack, alignCaptureTime: true)
    let rawBox = Mailbox(captureClock: clock, totalByteLimit: limit, journal: rawStore)
    var referenceBox = Mailbox(captureClock: clock, totalByteLimit: limit, journal: referenceStore)
    // Echo output timestamps have already been normalized by the raw input
    // mailboxes. A second CaptureBudgetClock would subtract pauses twice.
    let cleanBox = Mailbox(totalByteLimit: limit, journal: micStore)
    let routeChangePause=CaptureInputDeviceChangePause()
    let microphone = Microphone()
    microphone.recoverableFaultHandler={routeChangePause.request(reason:$0)}
    let referenceTap = ApplicationTap()
    let routes = ProcessAudioSourceController()
    let uploadBudget = cloud && config.unlimitedSession != true ? SessionUploadBudget(maxSeconds: 14_400) : nil
    let launcher = getppid()
    var entries: [String: SourceCaptureEntry] = [:]
    let generations = AudioTrackGenerations(existing:Array(reservedTracks))
    var sourceMetadata: [String: [String: Any]] = [:]
    for value in existingMetadata["audio_sources"] as? [[String:Any]] ?? [] {
        if let id=value["source_id"] as? String,isTranscriptAudioTrack(id) {sourceMetadata[id]=value}
    }
    var echoTask: Task<Void, Never>?
    var pauseTransition:CapturePauseTransition?
    var pauseTransitionStarted=0.0
    var pauseTransitionRevision:sig_atomic_t = -1
    var captureReason = "user_stop"
    var paused = false
    var referenceAvailable = false
    let echoReset = EchoResetControl()
    var origin: Double?
    var lastRouteCheck = 0.0
    var lastHealth = 0.0
    var lastRouteFailure: String?
    var lastSourceFailures: [String: String] = [:]
    var sourceCaptureGaps: [String: String] = [:]
    for gap in existingMetadata["source_capture_gaps"] as? [[String:Any]] ?? [] {
        if let core=gap["core_source_id"] as? String,let reason=gap["reason"] as? String {
            sourceCaptureGaps[core]=reason
        }
    }
    var lastReferenceFailure: String?
    var lastReferenceAttempt = 0.0
    let pauseTail=CapturePauseTailBarrier()
    let asrInventory=CaptureASRConsumerInventory()
    func admittedBytes(_ box:Mailbox)->Int {box.lock.lock();defer{box.lock.unlock()};return box.totalBytes}

    // Used when a newer pause/stop supersedes a partially prepared resume.
    // Do not leave installed taps behind for the next resume to install twice.
    func revokeResume() {
        captureHardwareReady=0;capturePaused=captureFinishing != 0 ? 0:1;captureUploadPaused=0
        let at=ProcessInfo.processInfo.systemUptime
        echoReset.referenceStopped(at:clock.timestamp(at));clock.pause(at:at);echoReset.request()
        paused=true;referenceAvailable=false;lastReferenceAttempt=0
        let transition=CapturePauseTransition();pauseTransition=transition;pauseTransitionStarted=at
        pauseTransitionRevision=captureControlRevision
        DispatchQueue.global(qos:.userInitiated).async {microphone.stop();transition.finishHardwarePart(nil)}
        DispatchQueue.global(qos:.userInitiated).async {do {try referenceTap.stopChecked();transition.finishHardwarePart(nil)} catch {transition.finishHardwarePart((error as? Failure)?.code ?? "reference_tap_stop_failed")}}
        DispatchQueue.global(qos:.userInitiated).async {do {try routes.stopChecked();transition.finishHardwarePart(nil)} catch {transition.finishHardwarePart((error as? Failure)?.code ?? "source_tap_stop_failed")}}
        transition.finishUploadDrain()
    }
    func prepareMicrophoneForResume(revision:sig_atomic_t) throws->Bool {
        try revalidateMicrophoneOrPause(routeChangePause:routeChangePause) {
            try microphone.prepareForResume(revision:revision)
        }
    }
    func confirmResumedMicrophone(revision:sig_atomic_t,after hostTime:Double,baseline:Int) async throws->Bool {
        try await waitForMicrophoneResume(stillRequested:{captureControlRevision==revision && capturePaused==0 && interrupted==0 && captureFinishing==0},
            validateEngine:{try rawBox.checkFault();return try prepareMicrophoneForResume(revision:revision)},
            hasFreshFrame:{let evidence=microphone.frameEvidence();return evidence.count>baseline && evidence.hostTime>=hostTime})
    }

    var metadata: [String: Any] = existingMetadata.isEmpty ? [
        "session": config.session, "cache_id": cacheID, "bundle": config.bundle,
        "mic_enabled": true, "created_at": Date().timeIntervalSince1970,
        "capture_mode": cloud ? "cloud" : "local_only", "upload_authorized": cloud,
        "asr_destination": cloud ? "dashscope.aliyuncs.com" : "", "asr_model": config.model,
        "source_tracking": "per_application", "raw_microphone_track": rawTrack,
        "playback_reference_track": referenceTrack
    ] : existingMetadata
    metadata["raw_microphone_track"]=rawTrack
    metadata["playback_reference_track"]=referenceTrack
    if config.appendCaptureCacheID != nil,metadata["archive_only_before_append"] as? Bool != true,
       FileManager.default.fileExists(atPath:directory.appendingPathComponent("archived-transcript.txt").path),
       existingTracks.filter({isTranscriptAudioTrack($0)}).allSatisfy({track in
           let file=directory.appendingPathComponent(track+"-transcript.jsonl")
           return (try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)==0
       }) {
        let prefix=directory.appendingPathComponent("archived-preappend.txt")
        if !FileManager.default.fileExists(atPath:prefix.path) {
            try FileManager.default.copyItem(at:directory.appendingPathComponent("archived-transcript.txt"),to:prefix)
        }
        metadata["archive_only_before_append"]=true
    }
    if cloud,let words=config.asrVocabulary,!words.isEmpty {metadata["asr_vocabulary"]=words;metadata["asr_vocabulary_confirmed"]=config.asrVocabularyConfirmed==true}
    if config.cloudSessionConfirmed == true {
        metadata["cloud_session_authorized"] = true
        metadata["unlimited_session"] = config.unlimitedSession==true
        if config.unlimitedSession != true {metadata["cloud_audio_ceiling_seconds"] = 14_400;metadata["cloud_budget_yuan"] = 5}
    }
    let metadataFile = directory.appendingPathComponent("meeting.json")
    func persistMetadata() throws {
        metadata["absolute_clock"] = clock.absoluteClock()
        metadata["audio_sources"] = sourceMetadata.values.sorted {
            ($0["source_id"] as? String ?? "") < ($1["source_id"] as? String ?? "")
        }
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: metadataFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataFile.path)
    }
    try persistMetadata()
    interrupted = 0;capturePaused = 0;captureUploadPaused=0;captureControlRevision = 0;capturePauseAcknowledgedRevision = -1;captureHardwareReady=0;captureFinishing=0;captureTailDrainAllowed=0
    signal(SIGINT, interruptHandler)
    signal(SIGTERM, interruptHandler)
    signal(SIGUSR1, recordingPauseHandler);signal(SIGUSR2, recordingPauseHandler)
    signal(SIGWINCH,recordingFinishHandler)
    // Keep control acknowledgement off Swift's cooperative executor. Capture
    // teardown and synchronous SDK work can occupy cooperative threads; the
    // pause receipt must still run independently while capture is stopped.
    var observedPauseRevision: sig_atomic_t = 0
    let pauseAckMonitor=CapturePauseAcknowledgementMonitor {
        guard interrupted == 0 else { return }
        let revision = captureControlRevision
        guard revision != observedPauseRevision else { return }
        guard capturePaused != 0 else { observedPauseRevision = revision; return }
        let acknowledgedAt = ProcessInfo.processInfo.systemUptime
        clock.pause(at: acknowledgedAt)
        guard revision == captureControlRevision && capturePaused != 0 &&
              captureHardwareReady == 0 && captureUploadPaused == 0 else { return }
        observedPauseRevision = revision
        let pauseSnapshot=cloud ? asrInventory.snapshot(revision:revision):CaptureASRConsumerInventory.Snapshot(tracks:[],completed:[])
        var event:[String:Any] = ["type":"recording_paused","session":config.session,
              "recording_elapsed_seconds":clock.elapsed(acknowledgedAt),
              "capture":false,"capture_gate":"closed","upload_gate":"draining_saved_audio",
              "control_revision":revision,
              "draining_tracks":cloud ? pauseSnapshot.tracks:[],
              "hardware_teardown":"pending"]
        if let reason=routeChangePause.takeReason(for:revision) {
            event["reason"]=reason
            if reason=="mic_conversion_backpressure" {
                let pressure=microphone.diagnostics()
                event["coverage_gap"]=true
                event["gap_reason"]=reason
                event["gap_seconds"]=pressure["conversion_backpressure_dropped_seconds"] as? Double ?? 0
                event["raw_audio_retained"]=true
                event["continue_available"]=true
            }
        }
        emit(event)
        // Replay consumers that finished immediately before this pause.
        if cloud {for (track,state) in pauseSnapshot.completed {
            emit(["type":"recording_pause_tail","session":config.session,
                  "track":track,"pause_revision":revision,"state":state])
        }}
        capturePauseAcknowledgedRevision=revision
    }
    defer { pauseAckMonitor.cancel() }

    func ensureSource(_ source: ProcessAudioSource) throws -> Mailbox {
        let track = try generations.open(source.sourceID)
        var attrs = source.metadata
        attrs["source_id"] = track
        attrs["core_source_id"] = source.sourceID
        if track != source.sourceID,
           let number = Int(track.dropFirst(source.sourceID.count + 2)) { attrs["capture_generation"] = number }
        sourceMetadata[track] = attrs
        try persistMetadata()
        if let entry = entries[track] { return entry.producer }
        let entry = try SourceCaptureEntry(id: track, directory: directory, clock: clock, limit: limit)
        entries[track] = entry
        asrInventory.register(track,hasSavedAudio:{admittedBytes(entry.producer)>0})
        emit(["type": "audio_source", "session": config.session, "source_id": track,
              "core_source_id": source.sourceID,
              "application_name": source.applicationName, "bundle_id": source.bundleID as Any? ?? NSNull(),
              "state": "detected", "audio_objects": source.audioObjectIDs.count])
        return entry.producer
    }

    func retireSource(_ coreID: String) {
        guard let track = generations.retire(coreID), let entry = entries[track] else { return }
        entry.endCapture()
        emit(["type": "audio_source", "session": config.session, "source_id": track,
              "core_source_id": coreID, "state": "inactive", "audio_retained": true])
    }

    func startConsumers(for entry: SourceCaptureEntry, at sessionOrigin: Double) async {
        guard cloud, isTranscriptAudioTrack(entry.sourceID), !entry.consumersStarted, entry.store.bytes() > 0 else { return }
        let attrs = sourceMetadata[entry.sourceID] ?? [:]
        let lane = Lane(track: entry.sourceID, config: config, metadata: attrs, budget: uploadBudget)
        entry.attach(lane)
        await lane.attachJournal(entry.store)
        let track = entry.sourceID
        let tailReady:(sig_atomic_t) async -> Bool = {revision in
            if track != micTrack {return await pauseTail.waitForCaptureStop(revision)}
            return await pauseTail.wait(revision)
        }
        func pauseAcknowledged(_ revision:sig_atomic_t) async -> Bool {
            while capturePaused != 0 && captureControlRevision==revision &&
                  capturePauseAcknowledgedRevision != revision && interrupted<2 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds:5_000_000)
            }
            return capturePaused != 0 && captureControlRevision==revision && capturePauseAcknowledgedRevision==revision
        }
        func journalWritesSettled(_ revision:sig_atomic_t) async -> Bool {
            while (entry.store.metadata()["pending_writer_bytes"] as? Int ?? 0)>0 {
                if Task.isCancelled || interrupted>=2 || captureUploadPaused != 0 ||
                   capturePaused==0 || captureControlRevision != revision {return false}
                try? await Task.sleep(nanoseconds:5_000_000)
            }
            return !Task.isCancelled && interrupted<2 && captureUploadPaused==0 &&
                capturePaused != 0 && captureControlRevision==revision
        }
        entry.tasks.append(Task {
            do {
                guard config.localSpeakerDirectory != nil else { return }
                try await lane.prepareSpeakers()
                while !Task.isCancelled && interrupted < 2 {
                    if let (packet, stamp) = try entry.modelBox.takePacket(now: ProcessInfo.processInfo.systemUptime,
                                                                           flush: entry.modelBox.isSealed()) {
                        try await lane.ingestSpeakers(packet, captureAt: stamp, sessionStart: sessionOrigin)
                        try entry.modelBox.checkpoint("model")
                    } else if entry.modelBox.isSealed() { break }
                    else { try await Task.sleep(nanoseconds: 5_000_000) }
                }
            } catch {
                emit(["type":"speaker_model","state":"failed","track":entry.sourceID,"session":config.session,
                      "reason":(error as? Failure)?.code ?? "speaker_model_failed","audio_retained":true,"asr_continues":true])
            }
            await lane.finishSpeakerInput()
        })
        entry.tasks.append(Task {
            await runJournalASR(lane: lane, box: entry.asrBox, store: entry.store, track: track,
                                origin: sessionOrigin, onCacheFailure: { code in
                                    emit(["type":"processing_failed","session":config.session,"consumer":"asr","track":track,"reason":entry.store.fault() ?? code,"audio_retained":true,"retry_available":true])
                                },
                                retryAfterLimit: true, stopReconnectOnCaptureStop: true,
                                pauseTailReady:tailReady)
            await waitForSourceJournal(entry.store)
            let complete=entry.store.transcriptionIsComplete()
            asrInventory.finished(track,complete:complete)
            // Sealed sources finish through runJournalASR's terminal branch,
            // which predates pause-tail reporting. If this source was present
            // in the ACK snapshot, bridge that completion into the same event
            // contract used by live sources.
            // A fatal ASR exit also leaves no reader, even if capture was open.
            guard capturePaused != 0 else{return}
            let revision=captureControlRevision
            guard await pauseAcknowledged(revision),
                  asrInventory.shouldReport(track,revision:revision),
                  await tailReady(revision),
                  await journalWritesSettled(revision),
                  asrInventory.shouldReport(track,revision:revision) else{return}
            let nowComplete=entry.store.transcriptionIsComplete()
            emit(["type":"recording_pause_tail","session":config.session,
                  "track":track,"pause_revision":revision,
                  "state":nowComplete ? "complete":"pending"])
            asrInventory.resolved(track,revision:revision)
        })
        entry.drainWhenReady()
    }

    func refreshRoutes(at sessionOrigin: Double?) async throws {
        let previouslyActive = Dictionary(uniqueKeysWithValues: routes.sources.map { ($0.sourceID, $0) })
        let change = try routes.refresh { source in
            if previouslyActive[source.sourceID] != nil {
                // A live tap is being rebuilt (process or output route change).
                // Paused taps are absent from previouslyActive and keep their era.
                retireSource(source.sourceID)
            }
            return try ensureSource(source)
        }
        let routed = Set(routes.sources.map(\.sourceID))
        let failed = Set(change.failed.keys)
        // Also catch disappearance across pause: routes.stop() deliberately
        // leaves the generation open, then the first resumed inventory decides.
        for coreID in Array(generations.active.keys) where !routed.contains(coreID) && !failed.contains(coreID) {
            retireSource(coreID)
        }
        for (id, code) in change.failed {
            sourceCaptureGaps[id] = sourceCaptureGaps[id] ?? code
            let failedTrack=generations.current(id) ?? id
            if generations.current(id) != nil {retireSource(id)}
            if lastSourceFailures[id] != code {
                emit(["type": "audio_source", "session": config.session,
                      "source_id": failedTrack, "core_source_id": id,
                      "state": "capture_unavailable", "reason": code,
                      "raw_microphone_retained": true])
                lastSourceFailures[id] = code
            }
        }
        for source in routes.sources where lastSourceFailures.removeValue(forKey: source.sourceID) != nil {
            emit(["type": "audio_source", "session": config.session,
                  "source_id": generations.current(source.sourceID) ?? source.sourceID,
                  "core_source_id": source.sourceID,
                  "state": "capture_recovered",
                  "had_capture_gap":sourceCaptureGaps[source.sourceID] != nil])
        }
        for source in change.changed {
            emit(["type": "audio_source", "session": config.session,
                  "source_id": generations.current(source.sourceID) ?? source.sourceID,
                  "core_source_id": source.sourceID,
                  "application_name": source.applicationName, "bundle_id": source.bundleID as Any? ?? NSNull(),
                  "state": "changed"])
        }
        if let sessionOrigin {
            for entry in entries.values where !entry.consumersStarted { await startConsumers(for: entry, at: sessionOrigin) }
        }
    }

    func refreshRoutesSafely(at sessionOrigin: Double?) async {
        do {
            try await refreshRoutes(at: sessionOrigin)
            if lastRouteFailure != nil {
                emit(["type": "audio_source", "session": config.session, "state": "routing_recovered"])
                lastRouteFailure = nil
            }
        } catch {
            let code = (error as? Failure)?.code ?? "source_routing_failed"
            if code != lastRouteFailure {
                emit(["type": "audio_source", "session": config.session,
                      "state": "routing_unavailable", "reason": code,
                      "raw_microphone_retained": true])
                lastRouteFailure = code
            }
        }
    }

    func isolateFailedSourceTaps() -> Bool {
        var failed: [(core: String, track: String, entry: SourceCaptureEntry)] = []
        for (core, track) in generations.active {
            if let entry = entries[track],
               entry.producer.captureCallbackError() != nil || entry.store.fault() != nil {
                failed.append((core, track, entry))
            }
        }
        guard !failed.isEmpty else { return true }
        for item in failed {
            let code = item.entry.producer.captureCallbackError() ?? item.entry.store.fault() ?? "app_tap_failed"
            sourceCaptureGaps[item.core] = sourceCaptureGaps[item.core] ?? code
            if lastSourceFailures[item.core] != code {
                emit(["type": "audio_source", "session": config.session,
                      "source_id": item.track, "core_source_id": item.core,
                      "state": "capture_unavailable", "reason": code,
                      "raw_microphone_retained": true])
                lastSourceFailures[item.core] = code
            }
        }
        let failedIDs = Set(failed.map(\.core))
        do {
            // Computer audio is a core meeting source. Retire only its damaged
            // generation; the same control-loop turn refreshes the inventory
            // and opens a replacement generation when the source is still live.
            let retained = routes.sources.filter { !failedIDs.contains($0.sourceID) }
            if retained.count != routes.sources.count {
                let previouslyActive = Set(routes.sources.map(\.sourceID))
                _ = try routes.reconcile(retained) { source in
                    if previouslyActive.contains(source.sourceID) { retireSource(source.sourceID) }
                    return try ensureSource(source)
                }
            }
            for item in failed { retireSource(item.core) }
            return true
        } catch {
            let code = (error as? Failure)?.code ?? "source_routing_failed"
            if code != lastRouteFailure {
                emit(["type": "audio_source", "session": config.session,
                      "state": "routing_unavailable", "reason": code,
                      "raw_microphone_retained": true])
                lastRouteFailure = code
            }
            return false
        }
    }

    func isolateFailedReferenceTap() {
        guard referenceBox.captureCallbackError() != nil || referenceStore.fault() != nil else { return }
        echoReset.referenceStopped(at: referenceBox.captureCallbackFailureTime() ??
                                   clock.timestamp(ProcessInfo.processInfo.systemUptime))
        referenceTap.stop()
        referenceAvailable = false
        echoReset.request()
        let code=referenceBox.captureCallbackError() ?? referenceStore.fault() ?? "reference_capture_failed"
        lastReferenceAttempt = ProcessInfo.processInfo.systemUptime
        if referenceBox.captureCallbackError() != nil { _ = renewOptionalCaptureWriter(&referenceBox) }
        if code != lastReferenceFailure {
            emit(["type": "echo_status", "track": "mic", "state": "reference_unavailable",
                  "detail": code, "enhanced": false,
                  "raw_audio_retained": true, "reference_uploaded": false])
            lastReferenceFailure = code
        }
    }

    func emitHealth(_ elapsed: Double, includeSpeakerDiagnostics:Bool=true) async {
        var health: [String: Any] = ["type": "health", "session": config.session,
                                     "elapsed_seconds": elapsed, "paused": paused,
                                     "source_count": routes.sources.count]
        for (id, entry) in entries {
            var values = entry.producer.metrics()
            if let lane = entry.lane { values.merge(await lane.metrics(includeSpeakerDiagnostics:includeSpeakerDiagnostics)) { _, new in new } }
            values.merge(sourceMetadata[id] ?? [:]) { _, new in new }
            values["speaker_backlog_seconds"] = entry.modelBox.metrics()["buffered_audio_seconds"]
            health[id] = values
        }
        var micValues = cleanBox.metrics()
        micValues["raw_audio_bytes"] = rawStore.bytes()
        micValues["reference_audio_bytes"] = referenceStore.bytes()
        if let mic=entries[micTrack],let lane=mic.lane {
            micValues.merge(await lane.metrics(includeSpeakerDiagnostics:includeSpeakerDiagnostics)) { _, new in new }
        }
        let microphoneDiagnostics=microphone.diagnostics()
        let rawSignal=rawBox.signalMetrics().merging(rawStore.metadata()){_,new in new}
        micValues["raw_signal"]=rawSignal
        micValues["input_diagnostics"]=microphoneDiagnostics
        micValues["clean_signal"]=cleanBox.signalMetrics()
        health["mic"] = micValues
        metadata["microphone_capture_diagnostics"]=microphoneDiagnostics
        metadata["capture_signal_health"]=health
        do {try persistMetadata()} catch {state.fault("cache_metadata_write_failed")}
        emit(health)
    }

    func refreshReference(force: Bool = false, deferIntervalStart: Bool = false) {
        isolateFailedReferenceTap()
        if referenceStore.fault() != nil {return}
        let now = ProcessInfo.processInfo.systemUptime
        if !force && !referenceAvailable && now - lastReferenceAttempt < 5 { return }
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        var output: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let outputOK = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                   &property, 0, nil, &size, &output) == noErr
        let selfObjects = audioObjects(for: selfAudioPIDs())
        guard !referenceAvailable || selfObjects != referenceTap.excludedAudioObjects ||
              !outputOK || output != referenceTap.outputClock else { return }
        lastReferenceAttempt = now
        echoReset.referenceStopped(at: clock.timestamp(now))
        referenceTap.stop()
        referenceAvailable = false
        do {
            guard outputOK else { throw Failure(code: "reference_output_clock_unavailable") }
            try referenceTap.start(bundle: "*system*", micEnabled: true, box: referenceBox, announce: false)
            referenceAvailable = true
            if !deferIntervalStart {
                echoReset.referenceStarted(at: clock.timestamp(ProcessInfo.processInfo.systemUptime))
            }
            echoReset.request()
            if lastReferenceFailure != nil {
                emit(["type": "echo_status", "track": "mic", "state": "reference_recovered",
                      "enhanced": false, "raw_audio_retained": true, "reference_uploaded": false])
                lastReferenceFailure = nil
            }
        } catch {
            let code = (error as? Failure)?.code ?? "reference_capture_failed"
            if lastReferenceFailure != code {
                emit(["type": "echo_status", "track": "mic", "state": "reference_unavailable",
                      "detail": code, "enhanced": false,
                      "raw_audio_retained": true, "reference_uploaded": false])
                lastReferenceFailure = code
            }
        }
    }

    do {
        // Physical recording starts before model load or network setup.
        captureHardwareReady=1
        try microphone.start(rawBox)
        metadata["microphone_capture_diagnostics"]=microphone.diagnostics()
        try persistMetadata()
        refreshReference()
        await refreshRoutesSafely(at: nil)
        let firstDeadline = ProcessInfo.processInfo.systemUptime + 5
        while (clock.origin() == nil || (rawBox.signalMetrics()["hardware_pcm_frames"] as? Int ?? 0)==0) && interrupted == 0 && ProcessInfo.processInfo.systemUptime < firstDeadline {
            try rawBox.checkFault()
            if referenceBox.captureCallbackError() == nil { try referenceBox.checkFault() }
            else if let code = referenceStore.fault() { throw Failure(code: code) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let start = clock.origin(), interrupted == 0 else {
            throw Failure(code: interrupted != 0 ? "user_stopped_before_capture" : "no_sound")
        }
        guard (rawBox.signalMetrics()["hardware_pcm_frames"] as? Int ?? 0)>0 else {throw Failure(code:"microphone_no_frames")}
        origin = start
        metadata["microphone_capture_diagnostics"]=microphone.diagnostics()
        metadata["capture_origin_uptime"] = start
        try persistMetadata()
        echoTask = Task { await consumeEcho(config: config, raw: rawStore, reference: referenceStore,
                                            cleaned: cleanBox, resetControl: echoReset,pauseTail:pauseTail,
                                            failure: { state.fault($0) }) }
        if cloud {
            let mic = SourceCaptureEntry(id: micTrack, store: micStore, producer: cleanBox)
            // The cleaned mic producer is owned by the echo task, so this
            // entry contributes only ASR/model readers of the same store.
            entries[micTrack] = mic
            asrInventory.register(micTrack,hasSavedAudio:{admittedBytes(cleanBox)>0})
            sourceMetadata[micTrack] = ["source_id": micTrack, "application_name": "我的麦克风"]
            try persistMetadata()
            emit(["type": "started", "audio_frames_received":true, "session": config.session, "cache_id": cacheID,
                  "mode": cloud ? "cloud" : "local_only", "destination": cloud ? "dashscope.aliyuncs.com" : "local_device",
                  "capture_origin_uptime": start, "audio_storage": "local_segmented_recoverable",
                  "absolute_clock": clock.absoluteClock(),
                  "source_tracking": true, "raw_microphone_recording": true,
                  "reference_recording": referenceAvailable,
                  "network": cloud,"append_capture":config.appendCaptureCacheID != nil])
            await startConsumers(for: mic, at: start)
        } else {
            emit(["type": "started", "audio_frames_received":true, "session": config.session, "cache_id": cacheID,
                  "mode": "local_only", "destination": "local_device",
                  "capture_origin_uptime": start, "audio_storage": "local_segmented_recoverable",
                  "absolute_clock": clock.absoluteClock(),
                  "source_tracking": true, "raw_microphone_recording": true,
                  "reference_recording": referenceAvailable,"network":false,"append_capture":config.appendCaptureCacheID != nil])
        }
        for entry in entries.values where !entry.consumersStarted { await startConsumers(for: entry, at: start) }

        var lastLevelEmission=0.0
        var silentMicrophone=SilentMicrophoneWatch()
        var controlAcknowledgement = CaptureControlAcknowledgement()
    while interrupted == 0 && captureFinishing == 0 && state.snapshot().2 == nil {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = clock.elapsed(now)
        if captureFinishing != 0 {captureReason="user_finish";break}
            // CoreAudio callbacks only enqueue a recoverable route-change
            // request. Apply it here so the normal revision, gate, teardown,
            // tail-drain and same-session resume path owns the transition.
            _ = routeChangePause.applyPendingPause()
            if getppid() != launcher { captureReason = "launcher_exited"; break }
            if config.unlimitedSession != true && elapsed >= config.maxSeconds { captureReason = cloud ? "cloud_duration_limit" : "local_duration_limit"; break }
            let requestRevision = captureControlRevision
            let requestedPaused = capturePaused != 0
            if requestRevision != captureControlRevision { continue }
            if paused,let failure=pauseTransition?.snapshot().failure {
                state.fault("capture_pause_teardown_failed:"+failure);interrupted=2
                emit(["type":"recording_control_failed","session":config.session,"action":"pause","reason":"capture_pause_teardown_failed","audio_retained":true])
                break
            }
            if paused,let transition=pauseTransition {
                let status=transition.snapshot()
                if status.hardwareDone && pauseTransitionRevision==requestRevision {
                    pauseTail.finalize(revision:requestRevision,throughByte:pauseTailTargetByte(rawStore))
                    if cloud && pauseTail.isComplete(requestRevision) && capturePauseAcknowledgedRevision==requestRevision {
                        // A source may have received its last in-flight packet
                        // after the ACK inventory snapshot. Start its consumer
                        // once the final journal bytes exist, then settle empty
                        // tracks as complete so neither side waits on silence.
                        for entry in entries.values where !entry.consumersStarted {
                            await startConsumers(for:entry,at:start)
                        }
                        for track in asrInventory.finishEmpty(revision:requestRevision) {
                            emit(["type":"recording_pause_tail","session":config.session,
                                  "track":track,"pause_revision":requestRevision,"state":"complete"])
                        }
                    }
                }
                if !(status.hardwareDone && status.uploadDone) && now-pauseTransitionStarted>=1.5 {
                    state.fault("capture_pause_teardown_timeout");interrupted=2
                    emit(["type":"recording_control_failed","session":config.session,"action":"pause","reason":"capture_pause_teardown_timeout","audio_retained":true])
                    break
                }
            }
            if requestedPaused && !paused {
                echoReset.referenceStopped(at: clock.timestamp(now))
                // Close timestamp admission before any synchronous hardware
                // teardown. Signal-aware tap callbacks and Lane.send also gate
                // immediately, even if route inventory or stop is blocked.
                captureHardwareReady=0
                clock.pause(at: now)
                echoReset.request()
                pauseTail.begin(revision:requestRevision,throughByte:pauseTailTargetByte(rawStore))
                paused = true
                referenceAvailable = false
                lastReferenceAttempt = 0
                let transition=CapturePauseTransition();pauseTransition=transition;pauseTransitionStarted=now
                pauseTransitionRevision=requestRevision
                DispatchQueue.global(qos:.userInitiated).async { microphone.stop();transition.finishHardwarePart(nil) }
                DispatchQueue.global(qos:.userInitiated).async { do { try referenceTap.stopChecked();transition.finishHardwarePart(nil) } catch { transition.finishHardwarePart((error as? Failure)?.code ?? "reference_tap_stop_failed") } }
                DispatchQueue.global(qos:.userInitiated).async { do { try routes.stopChecked();transition.finishHardwarePart(nil) } catch { transition.finishHardwarePart((error as? Failure)?.code ?? "source_tap_stop_failed") } }
                // Saved audio continues draining while paused; no upload
                // shutdown is pending and no actor/task round trip is needed.
                transition.finishUploadDrain()
            } else if !requestedPaused && paused {
                if let transition=pauseTransition {
                    let status=transition.snapshot()
                    if let failure=status.failure {
                        state.fault("capture_pause_teardown_failed:"+failure);interrupted=2
                        emit(["type":"recording_control_failed","session":config.session,"action":"resume","reason":"capture_pause_teardown_failed","audio_retained":true])
                        break
                    }
                    guard status.hardwareDone && status.uploadDone else {
                        if now-pauseTransitionStarted>=1.5 {
                            state.fault("capture_pause_teardown_timeout");interrupted=2
                            emit(["type":"recording_control_failed","session":config.session,"action":"resume","reason":"capture_pause_teardown_timeout","audio_retained":true])
                            break
                        }
                        try await Task.sleep(nanoseconds:20_000_000);continue
                    }
                }
                // The prior teardown is complete. Any failed/superseded attempt
                // below gets a new teardown before another start is permitted.
                pauseTransition=nil
                var resumeCommitted=false
                defer {if !resumeCommitted {revokeResume()}}
                try microphone.start(rawBox)
                // Keep the reference interval unopened until the paused budget
                // clock has been resumed. Otherwise uptime spent paused leaks
                // into the new interval and mic/reference packets no longer align.
                refreshReference(force: true, deferIntervalStart: true)
                guard isolateFailedSourceTaps() else {
                    throw Failure(code: "capture_resume_source_isolation_failed")
                }
                await refreshRoutesSafely(at: start)
                // This flow never closes per-lane upload gates on pause.
                // Resuming hardware must not wait behind ASR/model actor work.
                guard requestRevision == captureControlRevision && capturePaused == 0 && captureFinishing == 0 else { continue }
                guard try prepareMicrophoneForResume(revision:requestRevision) else{continue}
                let resumedMicAt=ProcessInfo.processInfo.systemUptime
                let priorMicFrames=microphone.frameEvidence().count
                guard resumeCaptureTimeline(clock: clock, resetControl: echoReset,
                                            referenceAvailable: referenceAvailable, hardwareReady: true,
                                            at: ProcessInfo.processInfo.systemUptime) else {
                    throw Failure(code: "capture_resume_hardware_unavailable")
                }
                do { try persistMetadata() }
                catch {
                    let failedAt = ProcessInfo.processInfo.systemUptime
                    echoReset.referenceStopped(at: clock.timestamp(failedAt))
                    clock.pause(at: failedAt)
                    echoReset.request()
                    throw error
                }
                guard requestRevision == captureControlRevision && capturePaused == 0 && captureFinishing == 0 else {
                    let failedAt = ProcessInfo.processInfo.systemUptime
                    echoReset.referenceStopped(at: clock.timestamp(failedAt))
                    clock.pause(at: failedAt)
                    echoReset.request()
                    continue
                }
                captureHardwareReady=1
                guard try await confirmResumedMicrophone(revision:requestRevision,after:resumedMicAt,baseline:priorMicFrames) else{continue}
                guard requestRevision==captureControlRevision,capturePaused==0,interrupted==0,captureFinishing==0 else{continue}
                captureUploadPaused=0
                paused = false
                pauseTransition=nil
                resumeCommitted=true
            }
            // SIGUSR1/SIGUSR2 can arrive while this task is awaiting synchronous
            // route inventory. If the final request is resume and no teardown
            // transition began, reconcile the clock boundary and reopen gates.
            // The signal gates still protect callbacks/sends if a newer pause
            // races this block; ACK below is conditional on the final gate state.
            if needsMissedPauseResumeReconciliation(requestedPaused: requestedPaused, locallyPaused: paused,
                                                    transitionPending: pauseTransition != nil,
                                                    hardwareReady: captureHardwareReady != 0,
                                                    uploadPaused: captureUploadPaused != 0) {
                var resumeCommitted=false
                defer {if !resumeCommitted {revokeResume()}}
                guard requestRevision == captureControlRevision && capturePaused == 0 && captureFinishing == 0 else { continue }
                guard try prepareMicrophoneForResume(revision:requestRevision) else{continue}
                let priorMicFrames=microphone.frameEvidence().count
                let resumedAt = ProcessInfo.processInfo.systemUptime
                echoReset.referenceStopped(at: clock.timestamp(resumedAt))
                guard resumeCaptureTimeline(clock: clock, resetControl: echoReset,
                                            referenceAvailable: referenceAvailable, hardwareReady: true,
                                            at: resumedAt) else {
                    throw Failure(code: "capture_resume_hardware_unavailable")
                }
                do { try persistMetadata() }
                catch {
                    let failedAt = ProcessInfo.processInfo.systemUptime
                    echoReset.referenceStopped(at: clock.timestamp(failedAt))
                    clock.pause(at: failedAt)
                    echoReset.request()
                    throw error
                }
                guard requestRevision == captureControlRevision && capturePaused == 0 && captureFinishing == 0 else {
                    let failedAt = ProcessInfo.processInfo.systemUptime
                    echoReset.referenceStopped(at: clock.timestamp(failedAt))
                    clock.pause(at: failedAt)
                    echoReset.request()
                    continue
                }
                captureHardwareReady=1
                guard try await confirmResumedMicrophone(revision:requestRevision,after:resumedAt,baseline:priorMicFrames) else{continue}
                guard requestRevision==captureControlRevision,capturePaused==0,interrupted==0,captureFinishing==0 else{continue}
                captureUploadPaused=0
                resumeCommitted=true
            }
            if requestRevision == captureControlRevision && requestedPaused == (capturePaused != 0) &&
               captureControlGatesMatch(requestedPaused: requestedPaused, capturePaused: capturePaused != 0,
                                        hardwareReady: captureHardwareReady != 0,
                                        uploadPaused: captureUploadPaused != 0) &&
               controlAcknowledgement.accept(requestRevision: requestRevision,
                                             requestedPaused: requestedPaused, actualPaused: paused) {
                if !requestedPaused { emit(["type": "recording_resumed",
                      "session": config.session,
                      "control_revision": requestRevision,
                      "absolute_clock": clock.absoluteClock(),
                      "recording_elapsed_seconds": clock.elapsed(ProcessInfo.processInfo.systemUptime),
                      "capture": true,"capture_gate":"open","upload_gate":"open",
                      "hardware_teardown":"complete"]) }
            }
            if !paused && now - lastRouteCheck >= 0.5 {
                refreshReference()
                if isolateFailedSourceTaps() { await refreshRoutesSafely(at: start) }
                lastRouteCheck = now
            }
            if cloud {
                for entry in entries.values where !entry.consumersStarted {
                    await startConsumers(for: entry, at: start)
                }
            }
            // The mic raw journal is the primary capture contract. The cleaned
            // mic/reference path is derived work; application taps are core
            // meeting sources whose failed generation is isolated and reopened.
            // Neither kind of secondary failure may stop the raw microphone.
            try rawBox.checkFault()
            switch silentMicrophone.observe(paused:paused,now:now,signal:rawBox.signalMetrics(now:now)) {
            case .heard: microphone.confirmSignal()
            case .silent:
                // The followed device (often a just-connected headset) gives no
                // sound. Reject it and reuse the device-change pause/auto-resume
                // so recording continues on the last microphone that worked.
                switch microphone.handleSilentDevice() {
                case .restarted:
                    emit(["type":"diagnostic","session":config.session,"code":"microphone_silent_restart"])
                    silentMicrophone.rearm(now:now)
                case .fallback:
                    emit(["type":"diagnostic","session":config.session,"code":"microphone_silent_fallback"])
                    routeChangePause.request(reason:"input_device_changed")
                case .none: break
                }
            case .none: break
            }
            if !paused && now-lastLevelEmission>=0.1 {
                let mic=rawBox.signalMetrics(now:now)
                let appSignals=entries.values.filter{$0.sourceID != micTrack}.map{$0.producer.signalMetrics(now:now)}
                let fresh=appSignals.filter{($0["last_packet_age_seconds"] as? Double ?? 10)<0.5}
                let computer:[String:Any]=["signal_rms":fresh.compactMap{$0["signal_rms"] as? Double}.max() ?? 0,
                    "signal_peak":fresh.compactMap{$0["signal_peak"] as? Double}.max() ?? 0,
                    "last_packet_age_seconds":fresh.isEmpty ? 10.0:0.0]
                emit(["type":"audio_levels","session":config.session,"levels":["mic":mic,"computer":computer]])
                lastLevelEmission=now
            }
            if !paused && now - lastHealth >= 1 {
                // Do not let speaker-model diagnostics hold the capture control
                // loop. Full diagnostics are collected after capture has ended.
                await emitHealth(elapsed, includeSpeakerDiagnostics:false)
                if !cloud {
                    emit(["type": "meter", "session": config.session,
                          "elapsed_seconds": elapsed, "estimated_yuan": "0", "mode": "local_only",
                          "paused": paused])
                }
                lastHealth = now
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if captureFinishing != 0 { captureReason="user_finish" }
        if let failure = state.snapshot().2 { captureReason = failure }
    } catch {
        captureReason = (error as? Failure)?.code ?? "source_capture_failed"
        state.fault(captureReason)
    }

    pauseAckMonitor.cancel()
    let endTime = ProcessInfo.processInfo.systemUptime
    captureHardwareReady=0
    if let transition=pauseTransition {
        // Below the supervisor's 6 s pause deadline; Bluetooth teardown can exceed 1.5 s.
        let status=await awaitCaptureHardwareStop(transition,until:pauseTransitionStarted+4.0)
        guard status.hardwareDone,status.failure==nil else {
            captureReason=status.failure.map{"capture_pause_teardown_failed:"+$0} ??
                (Task.isCancelled ? "capture_pause_teardown_cancelled":"capture_pause_teardown_timeout")
            state.fault(captureReason);interrupted=2
            metadata["recording_elapsed_seconds"]=clock.elapsed(endTime)
            metadata["capture_stop_reason"]=captureReason
            metadata["microphone_capture_diagnostics"]=microphone.diagnostics()
            metadata["microphone_final_signal"]=rawBox.signalMetrics()
            try? persistMetadata()
            // Do not seal writers or emit capture_stopped: hardware may still
            // own an in-flight callback. The launcher receives a failure and
            // process teardown closes the devices; the journals remain marked
            // incomplete for recovery.
            throw Failure(code:captureReason)
        }
        pauseTail.finalize(revision:pauseTransitionRevision,throughByte:pauseTailTargetByte(rawStore))
    } else {
        microphone.stop();referenceTap.stop();routes.stop()
    }
    let elapsed = clock.elapsed(endTime)
    metadata["recording_elapsed_seconds"] = elapsed
    metadata["capture_stop_reason"]=captureReason
    metadata["microphone_capture_diagnostics"]=microphone.diagnostics()
    metadata["microphone_final_signal"]=rawBox.signalMetrics()
    do { try persistMetadata() } catch { state.fault("cache_metadata_write_failed") }
    _ = state.end(reason: captureReason, elapsed: elapsed)
    echoReset.referenceStopped(at: clock.timestamp(endTime))
    rawBox.seal(); referenceBox.seal()
    for entry in entries.values where entry.sourceID != micTrack { entry.endCapture() }
    if (microphone.diagnostics()["conversion_backpressure_dropped_seconds_total"] as? Double ?? 0)>0 {
        sourceCaptureGaps["mic"]="mic_conversion_backpressure"
    }
    func sourceCompleteness()->[String:Any] {
        let events:[[String:Any]]=sourceCaptureGaps.keys.sorted().map { coreID in
            var value:[String:Any]=["core_source_id":coreID,"reason":sourceCaptureGaps[coreID] ?? "source_capture_failed"]
            if coreID=="mic" {value["application_name"]="麦克风"}
            if let attrs=sourceMetadata.values.first(where:{$0["core_source_id"] as? String==coreID}),
               let name=attrs["application_name"] as? String {value["application_name"]=name}
            return value
        }
        return ["audio_sources_complete":events.isEmpty,"source_capture_gaps":events]
    }
    var finalSourceCompleteness=sourceCompleteness()
    metadata.merge(finalSourceCompleteness){_,new in new}
    do {try persistMetadata()} catch {state.fault("cache_metadata_write_failed")}
    if cloud {
        emit(["type": "capture_stopped", "session": config.session, "reason": captureReason,
              "recording_elapsed_seconds": elapsed, "capture": false,
              "capture_gate":"closed","upload_gate":"draining_saved_audio",
              "processing_pending": true].merging(finalSourceCompleteness){_,new in new})
    }
    if interrupted == 0 { interrupted = 1 }
    if interrupted < 2 { captureHardwareReady=0 }
    // A user stop while paused still drains already recorded audio to the
    // confirmed cloud session; capturePaused is no longer an active pause.
    for entry in entries.values { if let lane=entry.lane { await lane.resumeUploads() } }
    let processingWatch = Task {
        try? await Task.sleep(nanoseconds: 180_000_000_000)
        if !Task.isCancelled {
            state.fault("processing_timeout")
            interrupted = 2
            echoTask?.cancel()
            for entry in entries.values { if let lane = entry.lane { await lane.cancelTransport() } }
        }
    }
    let parentWatch = Task {
        while !Task.isCancelled {
            if getppid() != launcher {
                state.fault("launcher_exited")
                interrupted = 2
                echoTask?.cancel()
                for entry in entries.values { if let lane = entry.lane { await lane.cancelTransport() } }
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
    if let echoTask { await echoTask.value }
    if cloud, let origin {
        for entry in entries.values where !entry.consumersStarted {
            await startConsumers(for: entry, at: origin)
        }
    }
    func rawAudioSaved()->Bool {rawStore.isEnded() && rawStore.fault()==nil && rawStore.bytes()>0}
    func retainFinalCaptureFault() {
        // A final admitted packet or fsync can fail after hardware has stopped.
        // Report that failure instead of turning a user stop into false success.
        if let code=rawStore.fault() {
            sourceCaptureGaps["mic"]=code
            state.fault(code);metadata["capture_stop_reason"]=code
        }
        for entry in entries.values where entry.sourceID != micTrack {
            guard let code=entry.store.fault() else{continue}
            let attrs=sourceMetadata[entry.sourceID] ?? [:]
            let coreID=attrs["core_source_id"] as? String ?? audioSourceCoreID(entry.sourceID) ?? entry.sourceID
            sourceCaptureGaps[coreID]=code
            state.fault(code)
            metadata["capture_stop_reason"]=code
        }
    }
    if !cloud {
        processingWatch.cancel(); parentWatch.cancel()
        waitForFinalCaptureJournals([rawStore,referenceStore,micStore]+entries.values.map(\.store))
        retainFinalCaptureFault()
        finalSourceCompleteness=sourceCompleteness()
        metadata.merge(finalSourceCompleteness){_,new in new}
        do {try persistMetadata()} catch {state.fault("cache_metadata_write_failed")}
        emit(["type": "capture_stopped", "session": config.session,
              "reason": state.snapshot().2 ?? captureReason,
              "recording_elapsed_seconds": elapsed, "capture": false,
              "capture_gate":"closed","upload_gate":"closed","processing_pending":false]
              .merging(finalSourceCompleteness){_,new in new})
        emit(["type": "meter", "session": config.session, "elapsed_seconds": elapsed,
              "estimated_yuan": "0", "mode": "local_only"])
        emit(["type": "stopped", "session": config.session, "cache_id": cacheID,
              "reason": state.snapshot().2 ?? captureReason, "recording_elapsed_seconds": elapsed,
              "received_at": elapsed, "transcription_complete": false,
              "raw_audio_saved": rawAudioSaved(), "network": false, "mode": "local_only",
              "application": config.bundle, "capture": false,"capture_gate":"closed","upload_gate":"closed"].merging(finalSourceCompleteness){_,new in new})
        return
    }
    emit(["type": "processing_started", "session": config.session,
          "recording_elapsed_seconds": elapsed, "capture": false, "deadline_seconds": 180])
    for entry in entries.values { for task in entry.tasks { await task.value }; await entry.awaitDrain() }
    processingWatch.cancel(); parentWatch.cancel()
    for entry in entries.values { if let lane = entry.lane { await lane.stop() } }
    for store in [rawStore, referenceStore, micStore] { store.wait() }
    for entry in entries.values { entry.store.wait() }
    retainFinalCaptureFault()
    finalSourceCompleteness=sourceCompleteness()
    metadata.merge(finalSourceCompleteness){_,new in new}
    do {try persistMetadata()} catch {state.fault("cache_metadata_write_failed")}
    await emitHealth(elapsed)
    let transcriptStores = [micStore] + entries.values.filter { $0.sourceID != micTrack }.map(\.store)
    let complete = transcriptStores.allSatisfy { $0.transcriptionIsComplete() }
    emit(["type": "stopped", "session": config.session, "cache_id": cacheID,
          "reason": state.snapshot().2 ?? captureReason, "recording_elapsed_seconds": elapsed,
          "received_at": clock.elapsed(ProcessInfo.processInfo.systemUptime),
          "transcription_complete": complete, "raw_audio_saved": rawAudioSaved(),
          "audio_storage": "local_segmented_recoverable", "application": config.bundle,
          "capture": false,"capture_gate":"closed","upload_gate":"closed"].merging(finalSourceCompleteness){_,new in new})
}

// Timestamp alignment regression only: no device, model, socket, or audio file.
func sourceCaptureSessionSyntheticChecks() -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ name: String) { if !condition { failures.append(name) } }
    let first = ReferencePacket(audio: Data(repeating: 0x11, count: 3_200), at: 10)
    let second = ReferencePacket(audio: Data(repeating: 0x22, count: 3_200), at: 10.1)
    let joined = referenceForMic([first, second], at: 10.02, bytes: 3_200)
    expect(joined?.audio.count == 3_200 && abs((joined?.at ?? 0) - 10.02) < 0.0001,
           "reference_cross_packet_alignment")
    expect(joined?.audio.prefix(2) == Data([0x11, 0x11]) &&
           joined?.audio.suffix(2) == Data([0x22, 0x22]), "reference_samples_not_rewritten")
    let gap = ReferencePacket(audio: second.audio, at: 10.105)
    expect(referenceForMic([first, gap], at: 10.02, bytes: 3_200) == nil,
           "reference_gap_falls_back")
    expect(referenceForMic([ReferencePacket(audio: first.audio, at: 10.03)],
                           at: 10, bytes: 3_200) == nil, "late_reference_falls_back")
    let availability = EchoResetControl()
    availability.referenceStarted(at: 10)
    expect(availability.referenceCovers(10.02, end: 10.08), "active_reference_covers_mic")
    availability.referenceStopped(at: 10.1)
    expect(!availability.referenceCovers(10.12, end: 10.18), "reference_failure_excludes_gap")
    availability.referenceStarted(at: 10.3)
    expect(!availability.referenceCovers(10.18, end: 10.32), "reference_gap_not_hidden_by_recovery")
    expect(availability.referenceCovers(10.32, end: 10.38), "reference_recovery_same_timeline")

    // A long pause must be removed from both microphone and loopback timestamps.
    var syntheticUptime = 1_000.0
    let pausedClock = CaptureBudgetClock(wallTime: { 2_000.0 }, uptime: { syntheticUptime })
    pausedClock.mark(1_000)
    let resumedReference = EchoResetControl()
    resumedReference.referenceStarted(at: pausedClock.timestamp(1_000))
    pausedClock.pause(at: 1_010)
    resumedReference.referenceStopped(at: pausedClock.timestamp(1_010))
    syntheticUptime = 1_100 // 90 seconds without capture
    expect(abs(pausedClock.timestamp(syntheticUptime) - 1_010) < 0.0001,
           "capture_timestamp_freezes_during_pause")
    expect(abs(pausedClock.elapsed(syntheticUptime) - 10) < 0.0001,
           "pause_does_not_consume_recording_budget")
    expect(resumeCaptureTimeline(clock: pausedClock, resetControl: resumedReference,
                                 referenceAvailable: true, hardwareReady: true,
                                 at: syntheticUptime), "long_pause_resume_ready")
    let resumedMicAt = pausedClock.timestamp(1_100.02)
    let resumedLoopback = ReferencePacket(audio: Data(repeating: 0x33, count: 3_200), at: resumedMicAt)
    expect(referenceWindowReady([resumedLoopback], at: resumedMicAt, bytes: 3_200,
                                resetControl: resumedReference),
           "ninety_second_pause_reference_realigns")
    let unavailableReference=EchoResetControl()
    unavailableReference.referenceStarted(at:resumedMicAt)
    unavailableReference.referenceStopped(at:resumedMicAt+0.01)
    expect(!referencePacketIsPending([],at:resumedMicAt+1,bytes:3_200,resetControl:unavailableReference),
           "unavailable_reference_does_not_wait_for_uncovered_interval")
    expect(referencePacketIsPending([],at:resumedMicAt,bytes:3_200,resetControl:resumedReference),
           "covered_reference_interval_waits_briefly_for_packet")
    // Failed hardware restart must leave both gates and the budget clock shut.
    var failedUptime = 10.0
    let failedClock = CaptureBudgetClock(wallTime: { 0 }, uptime: { failedUptime })
    failedClock.mark(10)
    let failedReference = EchoResetControl()
    failedReference.referenceStarted(at: 10)
    failedClock.pause(at: 20)
    failedReference.referenceStopped(at: failedClock.timestamp(20))
    failedUptime = 110
    expect(!resumeCaptureTimeline(clock: failedClock, resetControl: failedReference,
                                  referenceAvailable: true, hardwareReady: false, at: failedUptime),
           "failed_hardware_restart_refused")
    expect(failedClock.isPaused && abs(failedClock.elapsed(failedUptime) - 10) < 0.0001 &&
           !failedReference.referenceCovers(20.1, end: 20.2),
           "failed_resume_stays_paused_without_budget_or_reference")

    // Invoke the real signal handler twice without letting the 5ms ACK watcher
    // poll between calls. This reproduces the route-refresh fast-toggle window.
    do {
        let savedPaused = capturePaused
        let savedUploadPaused = captureUploadPaused
        let savedHardwareReady = captureHardwareReady
        let savedRevision = captureControlRevision
        let savedInterrupted = interrupted
        defer {
            capturePaused = savedPaused
            captureUploadPaused = savedUploadPaused
            captureHardwareReady = savedHardwareReady
            captureControlRevision = savedRevision
            interrupted = savedInterrupted
        }
        interrupted = 0
        capturePaused = 0
        captureUploadPaused = 0
        captureHardwareReady = 1
        captureControlRevision = 0
        var routeUptime = 80.0
        let routeClock = CaptureBudgetClock(wallTime: { 0 }, uptime: { routeUptime })
        routeClock.mark(50)
        let routeReference = EchoResetControl()
        routeReference.referenceStarted(at: 50)
        recordingPauseHandler(SIGUSR1)
        recordingPauseHandler(SIGUSR2)
        let unpolledResumeRevision = captureControlRevision
        expect(!routeClock.isPaused && capturePaused == 0 && captureHardwareReady == 0 &&
               captureUploadPaused == 0,
               "rapid_pause_resume_keeps_saved_audio_upload_gate_open")
        expect(!captureControlGatesMatch(requestedPaused: false, capturePaused: capturePaused != 0,
                                         hardwareReady: captureHardwareReady != 0,
                                         uploadPaused: captureUploadPaused != 0),
               "resume_ack_before_device_restart_rejected")
        if needsMissedPauseResumeReconciliation(requestedPaused: capturePaused != 0,
                                                locallyPaused: false, transitionPending: false,
                                                hardwareReady: captureHardwareReady != 0,
                                                uploadPaused: captureUploadPaused != 0) {
            routeReference.referenceStopped(at: routeClock.timestamp(routeUptime))
            let reconciled = resumeCaptureTimeline(clock: routeClock, resetControl: routeReference,
                                                    referenceAvailable: true, hardwareReady: true,
                                                    at: routeUptime)
            if reconciled { captureHardwareReady = 1; captureUploadPaused = 0 }
        }
        expect(unpolledResumeRevision == 2 && !routeClock.isPaused && captureAdmissionOpen() &&
               captureControlGatesMatch(requestedPaused: false, capturePaused: capturePaused != 0,
                                        hardwareReady: captureHardwareReady != 0,
                                        uploadPaused: captureUploadPaused != 0),
               "rapid_pause_resume_reconciles_clock_gates_and_ack")
        expect(captureControlGatesMatch(requestedPaused: true, capturePaused: true,
                                        hardwareReady: false, uploadPaused: false),
               "pause_ack_requires_closed_capture_and_draining_upload_gate")
        expect(!needsMissedPauseResumeReconciliation(requestedPaused: true, locallyPaused: false,
                                                     transitionPending: false, hardwareReady: false,
                                                     uploadPaused: true),
               "newer_pause_cannot_be_reopened_by_resume_reconciliation")
    }

    let cachedCoverage = EchoResetControl()
    cachedCoverage.referenceStarted(at: 10)
    expect(referenceWindowReady([first, second], at: 10.02, bytes: 3_200,
                                resetControl: cachedCoverage),
           "cached_reference_satisfies_mic_window_without_wait")

    // The ACK inventory stays complete when a source's ASR consumer retires
    // before pause, and a consumer retiring after the snapshot still owns its
    // one pause-tail completion report.
    do {
        let inventory=CaptureASRConsumerInventory()
        inventory.register("remote-g1",hasSavedAudio:{true})
        inventory.finished("remote-g1",complete:true)
        let beforePause=inventory.snapshot(revision:41)
        expect(beforePause.tracks==["remote-g1"] && beforePause.completed.count==1 &&
               beforePause.completed[0].0=="remote-g1" && beforePause.completed[0].1=="complete" &&
               !inventory.shouldReport("remote-g1",revision:41),
               "retired_before_pause_is_replayed_after_ack")
        var lateAudio=false
        inventory.register("remote-g2",hasSavedAudio:{lateAudio})
        lateAudio=true
        let duringPause=inventory.snapshot(revision:42)
        inventory.finished("remote-g2",complete:true)
        expect(duringPause.tracks.contains("remote-g2") &&
               inventory.shouldReport("remote-g2",revision:42),
               "retired_during_pause_keeps_tail_report_owner")
        inventory.resolved("remote-g2",revision:42)
        expect(!inventory.shouldReport("remote-g2",revision:42),
               "retired_during_pause_tail_resolves_once")
        inventory.register("remote-g3",hasSavedAudio:{true})
        inventory.finished("remote-g3",complete:false)
        let failedBeforePause=inventory.snapshot(revision:43)
        expect(failedBeforePause.tracks.contains("remote-g3") &&
               failedBeforePause.completed.contains(where:{$0.0=="remote-g3" && $0.1=="pending"}),
               "retired_pending_source_is_replayed_as_pending")
        var emptyHasAudio=false
        inventory.register("remote-empty",hasSavedAudio:{emptyHasAudio})
        let emptyDuringPause=inventory.snapshot(revision:44)
        let settledEmpty=inventory.finishEmpty(revision:44)
        expect(emptyDuringPause.tracks.contains("remote-empty") &&
               settledEmpty==["remote-empty"] && !inventory.shouldReport("remote-empty",revision:44),
               "empty_source_settles_after_capture_stop")
        emptyHasAudio=true
        let afterResume=inventory.snapshot(revision:45)
        expect(afterResume.tracks.contains("remote-empty") &&
               !afterResume.completed.contains(where:{$0.0=="remote-empty"}) &&
               inventory.shouldReport("remote-empty",revision:45) &&
               inventory.finishEmpty(revision:45).isEmpty,
               "empty_pause_does_not_finish_future_resumed_audio")
    }
    return failures
}

private actor CaptureCancellationEchoFixture:EchoInferenceStream {
    func enhance(mic:[Float],reference:[Float]) async throws -> [Float] {mic}
    func flush() async throws -> [Float] {[]}
    func reset() async throws {}
}

private final class EchoWaitProbe {
    private let lock=NSLock();private var didWait=false
    func mark(){lock.lock();didWait=true;lock.unlock()}
    func value()->Bool{lock.lock();defer{lock.unlock()};return didWait}
}

// Drives the real consumer with journal fixtures so cancellation is exercised
// after cursor advance, while reference is pending, and during an empty read.
func sourceCaptureCancellationChecks(config:Config,directory:URL) async throws->[String] {
    let oldInterrupted=interrupted
    interrupted=0
    defer {interrupted=oldInterrupted}
    let pcm=Data(repeating:0x31,count:3_200)
    let waitFolder=directory.appendingPathComponent("echo-reference-cancel-"+UUID().uuidString)
    let raw=try RecordingJournal(directory:waitFolder,track:"mic-raw",freeSpace:{1_000_000_000})
    let reference=try RecordingJournal(directory:waitFolder,track:"reference",freeSpace:{1_000_000_000})
    let cleaned=try RecordingJournal(directory:waitFolder,track:"mic",freeSpace:{1_000_000_000})
    try raw.enqueue(pcm,at:30);raw.finish();raw.wait()
    let reset=EchoResetControl();reset.referenceStarted(at:30)
    let probe=EchoWaitProbe(),output=Mailbox(journal:cleaned)
    let consumer=Task {
        await consumeEcho(config:config,raw:raw,reference:reference,cleaned:output,
                          resetControl:reset,pauseTail:CapturePauseTailBarrier(),
                          failure:{_ in preconditionFailure("reference cancellation must not report an audio fault")},
                          processorOverride:EchoPreprocessor(stream:CaptureCancellationEchoFixture()),
                          onReferenceWait:{probe.mark()})
    }
    let deadline=ProcessInfo.processInfo.systemUptime+2
    while !probe.value() && ProcessInfo.processInfo.systemUptime<deadline {
        try await Task.sleep(nanoseconds:1_000_000)
    }
    guard probe.value() else {consumer.cancel();await consumer.value;throw Failure(code:"echo_reference_wait_fixture_not_reached")}
    consumer.cancel();await consumer.value
    reference.finish();reference.wait();cleaned.wait()
    let rawPacket=try raw.read(0),cleanPacket=try cleaned.read(0)
    guard cleaned.bytes()==pcm.count,cleaned.fault()==nil,cleaned.processingFault()==nil,
          rawPacket?.0==pcm,cleanPacket?.0==pcm else {
        throw Failure(code:"echo_cancelled_reference_packet_not_preserved")
    }

    let emptyFolder=directory.appendingPathComponent("echo-empty-cancel-"+UUID().uuidString)
    let emptyRaw=try RecordingJournal(directory:emptyFolder,track:"mic-raw",freeSpace:{1_000_000_000})
    let emptyReference=try RecordingJournal(directory:emptyFolder,track:"reference",freeSpace:{1_000_000_000})
    let emptyClean=try RecordingJournal(directory:emptyFolder,track:"mic",freeSpace:{1_000_000_000})
    let emptyProbe=EchoWaitProbe(),emptyOutput=Mailbox(journal:emptyClean)
    let emptyConsumer=Task {
        await consumeEcho(config:config,raw:emptyRaw,reference:emptyReference,cleaned:emptyOutput,
                          resetControl:EchoResetControl(),pauseTail:CapturePauseTailBarrier(),
                          failure:{_ in preconditionFailure("empty consumer cancellation must not report an audio fault")},
                          processorOverride:EchoPreprocessor(stream:CaptureCancellationEchoFixture()),
                          onEmptyRawPoll:{emptyProbe.mark()})
    }
    let emptyDeadline=ProcessInfo.processInfo.systemUptime+2
    while !emptyProbe.value() && ProcessInfo.processInfo.systemUptime<emptyDeadline {
        try await Task.sleep(nanoseconds:1_000_000)
    }
    guard emptyProbe.value() else {
        emptyConsumer.cancel();emptyRaw.finish();await emptyConsumer.value
        throw Failure(code:"echo_empty_poll_fixture_not_reached")
    }
    emptyConsumer.cancel();emptyRaw.finish();await emptyConsumer.value
    emptyReference.finish();emptyReference.wait();emptyClean.wait()
    guard emptyClean.bytes()==0,emptyClean.fault()==nil,emptyClean.processingFault()==nil else {
        throw Failure(code:"echo_empty_cancel_reported_failure")
    }
    return ["cancelled_reference_wait_rewinds_cursor_and_preserves_current_packet",
            "cancelled_empty_raw_poll_does_not_report_processing_failure"]
}
