import Foundation
struct Failure: Error {let code:String}
// Measure admitted hardware PCM, before journal timeline padding. Silence is
// not speech or a permission diagnosis; counters remain separate per source.
struct PCM16Energy {
    let samples:Int
    let nonzero:Int
    let peak:Double
    let rms:Double
    init(_ data:Data) {
        var count=0,nonzero=0,peak=0.0,sum=0.0
        data.withUnsafeBytes { (raw:UnsafeRawBufferPointer) in
            for offset in stride(from:0,to:max(0,data.count-1),by:2) {
                let sample=Int16(littleEndian:raw.loadUnaligned(fromByteOffset:offset,as:Int16.self))
                let value=Double(sample)/32768
                count+=1;if sample != 0 {nonzero+=1};peak=max(peak,abs(value));sum+=value*value
            }
        }
        self.samples=count;self.nonzero=nonzero;self.peak=peak;self.rms=count>0 ? sqrt(sum/Double(count)):0
    }
}
// Recording time begins at the first delivered hardware PCM timestamp, never at
// model loading, ASR setup or a permission dialog. The origin is set only once.
final class CaptureBudgetClock {
    private let lock=NSLock();private var start:Double?;private var pausedAt:Double?;private var pausedSeconds=0.0
    private var anchors:[[String:Double]]=[]
    private let continuationOrigin:Double?
    private let continuationElapsed:Double
    private var rawOffset=0.0
    private let wallTime:()->Double;private let uptime:()->Double;private let zone:TimeZone
    init(wallTime:@escaping()->Double={Date().timeIntervalSince1970},uptime:@escaping()->Double={ProcessInfo.processInfo.systemUptime},zone:TimeZone = .current,
         continuationOrigin:Double?=nil,continuationElapsed:Double=0,priorAnchors:[[String:Double]]=[] ) {
        self.wallTime=wallTime;self.uptime=uptime;self.zone=zone
        self.continuationOrigin=continuationOrigin;self.continuationElapsed=continuationElapsed;anchors=priorAnchors
    }
    func mark(_ timestamp:Double) {guard timestamp.isFinite,timestamp>=0 else{return};lock.lock();if start==nil {
        if let continuationOrigin {
            start=continuationOrigin;rawOffset=continuationOrigin+continuationElapsed-timestamp
            anchors.append(["relative_start":continuationElapsed,"unix_time":wallTime()+timestamp-uptime()])
        } else {start=timestamp;anchors=[["relative_start":0,"unix_time":wallTime()+timestamp+pausedSeconds-uptime()]]}
    };lock.unlock()}
    func origin()->Double? {lock.lock();defer{lock.unlock()};return start}
    func pause(at now:Double) {lock.lock();defer{lock.unlock()};if pausedAt==nil {pausedAt=now}}
    func resume(at now:Double) {lock.lock();defer{lock.unlock()};if let paused=pausedAt {if let start {anchors.append(["relative_start":max(0,paused-pausedSeconds+rawOffset-start),"unix_time":wallTime()+now-uptime()])};pausedSeconds+=max(0,now-paused);pausedAt=nil}}
    func absoluteClock()->[String:Any] {lock.lock();defer{lock.unlock()};return ["schema":1,"basis":"capture_clock","time_zone":zone.identifier,"anchors":anchors]}
    // While paused, wall uptime keeps moving but capture time must stay fixed.
    // This also lets an asynchronously acknowledged pause close source intervals
    // at the correct capture timestamp even if the control loop was blocked.
    func timestamp(_ raw:Double)->Double {lock.lock();defer{lock.unlock()};return min(raw,pausedAt ?? raw)-pausedSeconds+rawOffset}
    // Initialize the continuation offset and return the first admitted stamp
    // under one lock, before the journal sees that frame.
    func admissionTimestamp(_ raw:Double)->Double {
        guard raw.isFinite,raw>=0 else{return raw}
        lock.lock();defer{lock.unlock()}
        if start==nil {
            if let continuationOrigin {
                start=continuationOrigin;rawOffset=continuationOrigin+continuationElapsed-raw+pausedSeconds
                anchors.append(["relative_start":continuationElapsed,"unix_time":wallTime()+raw-uptime()])
            } else {start=raw-pausedSeconds;anchors=[["relative_start":0,"unix_time":wallTime()+raw-uptime()]]}
        }
        return min(raw,pausedAt ?? raw)-pausedSeconds+rawOffset
    }
    // A converter may finish work for PCM that passed capture admission before
    // the pause. Permit only timestamps at or before that pause boundary; newer
    // frames must go through normal capture admission after resume.
    func timestampForPreviouslyAdmitted(_ raw:Double)->Double? {
        guard raw.isFinite,raw>=0 else{return nil}
        lock.lock();defer{lock.unlock()}
        guard let pausedAt=pausedAt,raw<=pausedAt else{return nil}
        return raw-pausedSeconds+rawOffset
    }
    var isPaused:Bool {lock.lock();defer{lock.unlock()};return pausedAt != nil}
    func elapsed(_ now:Double)->Double {lock.lock();defer{lock.unlock()};return start.map{max(0,(pausedAt ?? now)-pausedSeconds+rawOffset-$0)} ?? 0}
}
struct CaptureContinuation {
    let origin:Double
    let elapsed:Double
    let anchors:[[String:Double]]
    let zone:TimeZone
}
func captureContinuation(in directory:URL,metadata:[String:Any])->CaptureContinuation {
    let clock=metadata["absolute_clock"] as? [String:Any] ?? [:]
    let anchors=clock["anchors"] as? [[String:Double]] ?? []
    let zone=(clock["time_zone"] as? String).flatMap(TimeZone.init(identifier:)) ?? .current
    let tracks=(try? meetingAudioTracks(in:directory,transcriptOnly:false)) ?? []
    var origins:[Double]=[]
    var elapsed=max(0,(metadata["recording_elapsed_seconds"] as? Double) ?? 0)
    var manifests:[(Double,Int)]=[]
    for track in tracks {
        let path=directory.appendingPathComponent(track+"-manifest.json")
        guard let data=try? Data(contentsOf:path),let row=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{continue}
        if let origin=row["origin_uptime"] as? Double,origin.isFinite {origins.append(origin)}
        if let origin=row["origin_uptime"] as? Double,origin.isFinite,
           let bytes=row["written_bytes"] as? Int,bytes>=0 {manifests.append((origin,bytes))}
    }
    let origin=(metadata["capture_origin_uptime"] as? Double).flatMap{$0.isFinite ? $0:nil} ?? origins.min() ?? 0
    for (trackOrigin,bytes) in manifests {elapsed=max(elapsed,max(0,trackOrigin-origin)+Double(bytes)/32000)}
    // A retired PCM track can leave only its transcript. Those persisted
    // segment ends are measured timeline offsets, never inferred speech length.
    for track in reservedMeetingAudioTracks(in:directory,metadata:metadata) where isTranscriptAudioTrack(track) {
        let path=directory.appendingPathComponent(track+"-transcript.jsonl")
        guard let attrs=try? path.resourceValues(forKeys:[.fileSizeKey]),
              let size=attrs.fileSize,size>0,size<=64*1024*1024,
              let contents=try? String(contentsOf:path,encoding:.utf8) else{continue}
        for line in contents.split(separator:"\n") {
            guard let row=(try? JSONSerialization.jsonObject(with:Data(line.utf8))) as? [String:Any],
                  row["type"] as? String=="segment",row["final"] as? Bool==true,
                  let end=row["end"] as? Double,end.isFinite,end>=0,end<=86400 else{continue}
            elapsed=max(elapsed,end)
        }
    }
    return CaptureContinuation(origin:origin,elapsed:elapsed,anchors:anchors,zone:zone)
}
func appendCaptureClockChecks() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("append-clock-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
    defer {try? FileManager.default.removeItem(at:directory)}
    let clock=CaptureBudgetClock(wallTime:{2_000_000_000},uptime:{10},zone:TimeZone(identifier:"Asia/Shanghai")!,continuationOrigin:1000,continuationElapsed:15)
    let store=try RecordingJournal(directory:directory,track:"mic-g1",freeSpace:{1_000_000_000},alignCaptureTime:true)
    let box=Mailbox(captureClock:clock,journal:store)
    precondition(box.put(Data(repeating:1,count:320),at:10))
    precondition(box.put(Data(repeating:1,count:320),at:10.01))
    store.finish();store.wait()
    let row=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("mic-g1-manifest.json"))) as! [String:Any]
    precondition(row["origin_uptime"] as? Double==1015)
    precondition(row["written_bytes"] as? Int==640)
    precondition(row["alignment_padding_bytes"] as? Int==0)
    let absolute=MeetingAbsoluteTime(clock.absoluteClock())!
    precondition(absolute.iso(0)==nil && absolute.iso(15) != nil)
    for continuationOrigin:Double? in [nil,1000] {
        let delayed=CaptureBudgetClock(wallTime:{2_000_000_000},uptime:{10},continuationOrigin:continuationOrigin,continuationElapsed:15)
        delayed.pause(at:1);delayed.resume(at:6)
        let delayedTrack=continuationOrigin==nil ? "mic-g2":"mic-g3"
        let delayedStore=try RecordingJournal(directory:directory,track:delayedTrack,freeSpace:{1_000_000_000},alignCaptureTime:true)
        let delayedBox=Mailbox(captureClock:delayed,journal:delayedStore)
        precondition(delayedBox.put(Data(repeating:1,count:320),at:10))
        precondition(delayedBox.put(Data(repeating:1,count:320),at:10.01))
        delayedStore.finish();delayedStore.wait()
        let delayedManifest=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent(delayedTrack+"-manifest.json"))) as! [String:Any]
        precondition(delayedManifest["origin_uptime"] as? Double==(continuationOrigin==nil ? 5:1015))
        precondition(delayedManifest["written_bytes"] as? Int==640 && delayedManifest["alignment_padding_bytes"] as? Int==0)
        precondition(abs(delayed.elapsed(10.01)-(continuationOrigin==nil ? 0.01:15.01))<0.00001)
    }
    let retired=directory.appendingPathComponent("retired")
    try FileManager.default.createDirectory(at:retired,withIntermediateDirectories:false)
    let transcript:[String:Any]=["type":"segment","final":true,"end":42.0]
    try (JSONSerialization.data(withJSONObject:transcript)+Data([10])).write(to:retired.appendingPathComponent("mic-transcript.jsonl"))
    let continuation=captureContinuation(in:retired,metadata:["capture_origin_uptime":700.0])
    precondition(continuation.origin==700 && continuation.elapsed==42)
    let reserved=reservedMeetingAudioTracks(in:retired,metadata:["audio_sources":[["source_id":"app-0123456789abcdef-g2"]],
        "raw_microphone_track":"mic-raw-g3","playback_reference_track":"reference-g3"])
    precondition(["mic","app-0123456789abcdef-g2","mic-raw-g3","reference-g3"].allSatisfy{reserved.contains($0)})
    let archived=directory.appendingPathComponent("archived")
    try FileManager.default.createDirectory(at:archived,withIntermediateDirectories:false)
    let metadata:[String:Any]=["session":"synthetic","archive_only_before_append":true]
    try JSONSerialization.data(withJSONObject:metadata).write(to:archived.appendingPathComponent("meeting.json"))
    try "旧归档原文".write(to:archived.appendingPathComponent("archived-preappend.txt"),atomically:true,encoding:.utf8)
    let item=CachedMeeting(id:UUID().uuidString,directory:archived,date:Date(),writtenBytes:0,pendingBytes:0,occupiedBytes:0,tracks:[],audioCleaned:false,warning:false,retiredBytes:0)
    let projected=try item.events()
    precondition(projected.first?["text"] as? String=="旧归档原文")
}
// Bounded PCM mailbox. Overflow stops the trial rather than silently losing audio.
final class Mailbox {
    let captureClock:CaptureBudgetClock?
    let journal:RecordingJournal?;let producer:Bool;var readCursor=0
    let maxBytes:Int;let maxFrames:Int;let mirror:Mailbox?;let totalByteLimit:Int?;var boundaryTrimmedBytes=0
    init(captureClock:CaptureBudgetClock?=nil,maxBytes:Int=64000,maxFrames:Int=1024,mirror:Mailbox?=nil,totalByteLimit:Int?=nil,journal:RecordingJournal?=nil,producer:Bool=true) {self.journal=journal;self.producer=producer;self.captureClock=captureClock;self.maxBytes=maxBytes;self.maxFrames=maxFrames;self.mirror=mirror;self.totalByteLimit=totalByteLimit}
    let lock = NSLock()
    var frames: [(Data, Double)] = []
    var error: String?
    private var callbackFailed = false
    private var callbackFailureAt: Double?
    var closed = false
    var totalBytes = 0
    var totalFrames = 0
    var nonzeroFrames = 0
    var signalSamples=0;var signalNonzeroSamples=0;var signalPeak=0.0;var signalRMS=0.0
    var lastPacketUptime:Double?;var lastNonzeroUptime:Double?
    var queuedBytes = 0
    var discardedBytes = 0
    var maxQueuedBytes = 0
    @discardableResult func put(_ input: Data, at raw: Double)->Bool {
        if captureClock?.isPaused==true {return false}
        return append(input,at:raw,rawTimestamp:true)
    }
    // Narrow drain path for conversion work whose hardware buffers were already
    // admitted before pause. It cannot admit new/post-boundary microphone PCM.
    @discardableResult func putPreviouslyAdmitted(_ input:Data,at raw:Double)->Bool {
        guard let captureClock=captureClock,
              let at=captureClock.timestampForPreviouslyAdmitted(raw) else{return false}
        return append(input,at:at)
    }
    @discardableResult private func append(_ input:Data,at:Double,rawTimestamp:Bool=false)->Bool {
        guard !input.isEmpty else{return false}
        lock.lock(); defer { lock.unlock() }
        if closed { return false }
        let allowed=totalByteLimit.map{max(0,min(input.count,$0-totalBytes))} ?? input.count
        let data=allowed==input.count ? input:Data(input.prefix(allowed));boundaryTrimmedBytes+=input.count-allowed
        if data.isEmpty {return false}
        let at=rawTimestamp ? (captureClock?.admissionTimestamp(at) ?? at) : at
        if !rawTimestamp {captureClock?.mark(at)}
        let energy=PCM16Energy(data),now=ProcessInfo.processInfo.systemUptime
        signalSamples+=energy.samples;signalNonzeroSamples+=energy.nonzero
        signalPeak=energy.peak;signalRMS=energy.rms;lastPacketUptime=now
        if energy.nonzero>0 {nonzeroFrames+=1;lastNonzeroUptime=now}
        if let journal=journal {
            do {try journal.enqueue(data,at:at)}catch{self.error=(error as? Failure)?.code ?? "cache_write_failed";closed=true;return false}
            totalFrames+=1;totalBytes+=data.count;return true
        }
        totalFrames += 1; totalBytes += data.count; queuedBytes += data.count
        if frames.count >= maxFrames || queuedBytes > maxBytes || data.count > 32768 {
            error = "audio_backpressure"; closed = true; discardedBytes += queuedBytes
            queuedBytes = 0; frames.removeAll(); return false
        }
        maxQueuedBytes = max(maxQueuedBytes, queuedBytes)
        frames.append((data, at));mirror?.put(data,at:at);return true
    }
    func fail(_ code: String) {
        let at = captureClock?.timestamp(ProcessInfo.processInfo.systemUptime)
        lock.lock()
        if error == nil { error = code; callbackFailed = true; callbackFailureAt = at }
        closed = true; discardedBytes += queuedBytes; queuedBytes = 0; frames.removeAll()
        lock.unlock()
    }
    // Only a hardware callback failure is recoverable. Journal admission and
    // storage failures must still stop the session instead of hiding a gap.
    func captureCallbackError() -> String? { lock.lock(); defer { lock.unlock() }; return callbackFailed ? error : nil }
    func captureCallbackFailureTime() -> Double? { lock.lock(); defer { lock.unlock() }; return callbackFailureAt }
    func replacementAfterCaptureFailure() -> Mailbox? {
        guard producer, let journal, journal.fault() == nil else { return nil }
        lock.lock()
        guard callbackFailed, error != nil else { lock.unlock(); return nil }
        let bytes = totalBytes, frames = totalFrames, nonzero = nonzeroFrames, trimmed = boundaryTrimmedBytes
        let signal=(signalSamples,signalNonzeroSamples,signalPeak,signalRMS,lastPacketUptime,lastNonzeroUptime)
        lock.unlock()
        let next = Mailbox(captureClock: captureClock, maxBytes: maxBytes, maxFrames: maxFrames,
                           mirror: mirror, totalByteLimit: totalByteLimit, journal: journal)
        next.totalBytes = bytes
        next.totalFrames = frames
        next.nonzeroFrames = nonzero
        next.boundaryTrimmedBytes = trimmed
        next.signalSamples=signal.0;next.signalNonzeroSamples=signal.1;next.signalPeak=signal.2;next.signalRMS=signal.3;next.lastPacketUptime=signal.4;next.lastNonzeroUptime=signal.5
        return next
    }
    func take() throws -> (Data, Double)? {
        lock.lock(); defer { lock.unlock() }
        if let e = error { throw Failure(code: e) }
        if frames.isEmpty { return nil }
        let frame = frames.removeFirst(); queuedBytes -= frame.0.count; return frame
    }
    func hasFrames() -> Bool {if let journal=journal{return journal.bytes()>readCursor}; lock.lock(); defer { lock.unlock() }; return !frames.isEmpty }
    func rewind(_ cursor:Int)throws {guard let journal=journal,cursor>=0,cursor<=journal.bytes(),cursor%2==0 else{throw Failure(code:"cache_cursor_invalid")};readCursor=cursor}
    func checkpoint(_ consumer:String)throws {try journal?.commit(consumer,cursor:readCursor)}
    func takePacket(now: Double, flush: Bool = false) throws -> (Data, Double)? {
        if let journal=journal {if let value=try journal.read(readCursor){readCursor+=value.0.count;return value};return nil}
        lock.lock(); defer { lock.unlock() }
        if let e = error { throw Failure(code: e) }
        guard let first = frames.first else { return nil }
        // 100ms PCM16/16k mono = 3200 bytes. Flush an older partial without waiting indefinitely.
        if !flush && queuedBytes < 3200 && now - first.1 < 0.1 { return nil }
        var packet = Data()
        while !frames.isEmpty && packet.count < 3200 {
            let frame = frames.removeFirst()
            let count = min(frame.0.count, 3200 - packet.count)
            packet.append(frame.0.prefix(count)); queuedBytes -= count
            if count < frame.0.count {
                frames.insert((Data(frame.0.dropFirst(count)), frame.1 + Double(count) / 32000), at: 0)
            }
        }
        return (packet, first.1)
    }
    func seal(){lock.lock();closed=true;lock.unlock();if producer {journal?.finish()}}
    func isSealed()->Bool {if let journal=journal{return journal.isEnded()};lock.lock();defer{lock.unlock()};return closed}
    func checkFault() throws {if let code=journal?.fault(){throw Failure(code:code)}; lock.lock(); defer { lock.unlock() }; if let e = error { throw Failure(code: e) } }
    func signalMetrics(now:Double=ProcessInfo.processInfo.systemUptime)->[String:Any] {
        lock.lock();defer{lock.unlock()}
        var value:[String:Any]=["hardware_pcm_frames":totalFrames,"signal_samples":signalSamples,
            "nonzero_samples":signalNonzeroSamples,"nonzero_frames":nonzeroFrames,
            "signal_peak":signalPeak,"signal_rms":signalRMS,"signal_basis":"admitted_pcm_before_padding"]
        if let lastPacketUptime {value["last_packet_age_seconds"]=max(0,now-lastPacketUptime)}
        if let lastNonzeroUptime {value["last_nonzero_age_seconds"]=max(0,now-lastNonzeroUptime)}
        return value
    }
    func metrics() -> [String: Any] {
        if let journal=journal {
            var value=journal.metadata();let backlog=max(0,journal.bytes()-readCursor)
            lock.lock();maxQueuedBytes=max(maxQueuedBytes,backlog);let peak=maxQueuedBytes;lock.unlock()
            value.merge(["pcm_bytes":journal.bytes(),"queued_bytes":backlog,"max_queued_bytes":peak,"buffered_audio_seconds":Double(backlog)/32000,"discarded_bytes":0,"coverage_gap":journal.fault() != nil,"buffer_near_full":false]){_,new in new}
            value.merge(signalMetrics()){_,new in new};return value
        }
        let signal=signalMetrics()
        lock.lock(); defer { lock.unlock() }
        return ["pcm_frames": totalFrames, "pcm_bytes": totalBytes, "nonzero_frames": nonzeroFrames,
                "queued_bytes": queuedBytes, "max_queued_bytes": maxQueuedBytes,
                "boundary_trimmed_bytes":boundaryTrimmedBytes,"buffer_capacity_bytes":maxBytes,"buffered_audio_seconds":Double(queuedBytes)/32000,"buffer_near_full":queuedBytes>=maxBytes*4/5,
                "discarded_bytes": discardedBytes, "coverage_gap": discardedBytes > 0].merging(signal){_,new in new}
    }
    func clear() {if journal != nil{return}; lock.lock(); closed = true; discardedBytes += queuedBytes; queuedBytes = 0; frames.removeAll(); lock.unlock() }
}

// Physical sources and model lanes are separate from speaker identities.
func activeCaptureTracks(bundle:String,useMic:Bool)->[String] {bundle=="*microphone*" ? (useMic ? ["mic"]:[]) : useMic ? ["mic","remote"]:["remote"]}

// Session text remains only in memory. Rendering is separate from admission.
struct TranscriptCapacity {
    let maxSegments:Int;let maxTextBytes:Int;let maxEventBytes:Int
    private var entries:[String:(Int,Int)]=[:];private(set) var textBytes=0;private(set) var eventBytes=0
    init(maxSegments:Int=50_000,maxTextBytes:Int=16*1024*1024,maxEventBytes:Int=128*1024*1024){self.maxSegments=maxSegments;self.maxTextBytes=maxTextBytes;self.maxEventBytes=maxEventBytes}
    mutating func reserve(_ id:String,textBytes:Int,eventBytes:Int)->Bool {
        guard textBytes>=0,eventBytes>=0 else{return false};let previous=entries[id] ?? (0,0)
        guard entries.count+(entries[id]==nil ? 1:0)<=maxSegments,textBytes<=min(maxTextBytes,2*1024*1024),eventBytes<=maxEventBytes,
              self.textBytes-previous.0<=maxTextBytes-textBytes,self.eventBytes-previous.1<=maxEventBytes-eventBytes else{return false}
        self.textBytes+=textBytes-previous.0;self.eventBytes+=eventBytes-previous.1;entries[id]=(textBytes,eventBytes);return true
    }
    mutating func remove(_ id:String){if let previous=entries.removeValue(forKey:id){textBytes-=previous.0;eventBytes-=previous.1}}
    mutating func reset(){entries=[:];textBytes=0;eventBytes=0}
    var count:Int {entries.count}
}

final class CaptureRunState {
    private let lock=NSLock();private var endedAt:Double?;private var stopReason="user_stop";private var failure:String?
    func end(reason:String,elapsed:Double)->Bool {lock.lock();defer{lock.unlock()};guard endedAt==nil else{return false};endedAt=elapsed;stopReason=reason;return true}
    func fault(_ code:String){lock.lock();if failure==nil {failure=code};lock.unlock()}
    func snapshot()->(Double?,String,String?) {lock.lock();defer{lock.unlock()};return(endedAt,stopReason,failure)}
}
