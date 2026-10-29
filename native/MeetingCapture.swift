import Foundation
import CoreFoundation
import AppKit
import AVFoundation
import CoreAudio
import AudioToolbox
import Darwin

func check(_ status: OSStatus, _ code: String) throws { if status != noErr { throw Failure(code: "\(code):\(status)") } }
let outputLock = NSLock()
var captureControlAckFD: Int32 = -1
func configureControlAcknowledgementDescriptor(_ descriptor: Int32?) throws -> Int32 {
    guard let descriptor else { return -1 }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
        throw Failure(code: "control_ack_descriptor_invalid")
    }
    var socketType: Int32 = 0
    var socketTypeLength = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &socketType, &socketTypeLength) == 0,
          socketType == SOCK_DGRAM else { throw Failure(code: "control_ack_descriptor_invalid") }
    var address = sockaddr_storage()
    var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let addressStatus = withUnsafeMutablePointer(to: &address) { storage in
        storage.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &addressLength)
        }
    }
    guard addressStatus == 0, address.ss_family == sa_family_t(AF_UNIX) else {
        throw Failure(code: "control_ack_descriptor_invalid")
    }
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
        throw Failure(code: "control_ack_descriptor_unavailable")
    }
    var noSignal: Int32 = 1
    guard withUnsafePointer(to: &noSignal, { setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size)) }) == 0 else {
        throw Failure(code: "control_ack_descriptor_unavailable")
    }
    return descriptor
}
func emitControlAcknowledgement(_ data: Data) -> Bool {
    guard captureControlAckFD >= 0 else { return false }
    // One bounded Unix datagram preserves the complete ACK as a packet. A
    // nonblocking send fails closed if the reader is unavailable or saturated.
    guard !data.isEmpty, data.count <= 4096 else { return false }
    return data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return false }
        var written: Int
        repeat {
            written = Darwin.send(captureControlAckFD, base, rawBuffer.count, MSG_DONTWAIT)
        } while written < 0 && errno == EINTR
        return written == rawBuffer.count
    }
}
func emit(_ value: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    if value["type"] as? String == "recording_paused" || value["type"] as? String == "recording_resumed" {
        // Prefer the independent nonblocking channel, but never silently lose
        // the control receipt when that one datagram cannot be delivered.
        if emitControlAcknowledgement(data) { return }
    }
    outputLock.lock(); defer { outputLock.unlock() }
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
}
func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func processes(bundle: String) -> [pid_t] {
    NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundle }.map { $0.processIdentifier }.sorted()
}
func selectedAudioProcesses(bundle: String) -> [[String: Any]] {
    let selected = Set(processes(bundle: bundle))
    var property = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { return [] }
    guard size >= MemoryLayout<AudioObjectID>.size else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, $0.baseAddress!) }
    guard status == noErr else { return [] }
    return ids.compactMap { id in
        var pid: pid_t = 0; var bytes = UInt32(MemoryLayout<pid_t>.size)
        var field = address(kAudioProcessPropertyPID)
        guard AudioObjectGetPropertyData(id, &field, 0, nil, &bytes, &pid) == noErr, selected.contains(pid) else { return nil }
        var running: UInt32 = 0; bytes = 4; field = address(kAudioProcessPropertyIsRunningOutput)
        let result = AudioObjectGetPropertyData(id, &field, 0, nil, &bytes, &running)
        return ["pid": pid, "audio_object_id": id, "running_output": result == noErr && running != 0]
    }
}

func audioObjects(for pids:[pid_t])->[AudioObjectID] {
    pids.compactMap { original in var pid=original;var property=address(kAudioHardwarePropertyTranslatePIDToProcessObject);var object:AudioObjectID=0;var size=UInt32(MemoryLayout<AudioObjectID>.size)
        let status=AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&property,UInt32(MemoryLayout<pid_t>.size),&pid,&size,&object)
        return status==noErr && object != kAudioObjectUnknown ? object : nil
    }.sorted()
}
func selfAudioPIDs()->[pid_t] {[getpid()]+processes(bundle:"com.joesang.meeting-assistant")+processes(bundle:"com.joesang.meeting-assistant.validation")+processes(bundle:"com.joesang.meeting-assistant.next")+processes(bundle:"com.joesang.meeting-assistant.offlineqa")+processes(bundle:"com.joesang.meeting-assistant.desktop")+processes(bundle:"com.joesang.meeting-assistant.development-qa")}
func scopeDescription(global:Bool,ids:[AudioObjectID])->CATapDescription {
    let description=global ? CATapDescription(monoGlobalTapButExcludeProcesses:ids) : CATapDescription(monoMixdownOfProcesses:ids)
    description.isPrivate=true;description.muteBehavior = .unmuted
    return description
}
struct Config: Decodable {
    let session: String
    let bundle: String
    let key: String
    let confirmed: Bool
    let maxSeconds: Double
    let model: String
    let silenceMS: Int
    let micEnabled: Bool?
    let localSpeakerDirectory: String?
    let localEmbeddingModel: String?
    let userLaunchConfirmed: Bool?
    var echoModelDirectory:String? = nil
    var cloudSessionConfirmed:Bool? = nil
    var unlimitedSession:Bool? = nil
    var resumeUploadConfirmed:Bool? = nil
    var localOnly:Bool? = nil
    var localRecordingConfirmed:Bool? = nil
    var isLocalOnly:Bool {localOnly == true}
    var resumeCacheID:String? = nil
    var appendCaptureCacheID:String? = nil
    var remainingUploadSeconds:Double? = nil
    var controlAckFD:Int32? = nil
    var useMic: Bool {micEnabled ?? true}
    func validate() throws {
        guard unlimitedSession != true || userLaunchConfirmed==true && (cloudSessionConfirmed==true || isLocalOnly && localRecordingConfirmed==true) else{throw Failure(code:"invalid_unlimited_scope")}
        guard confirmed, !session.isEmpty, !bundle.isEmpty, !bundle.hasPrefix("com.joesang."),
              appendCaptureCacheID.map({UUID(uuidString:$0) != nil}) ?? true,
              !(resumeCacheID != nil && appendCaptureCacheID != nil),
              (isLocalOnly ? (localRecordingConfirmed == true && key.isEmpty && resumeCacheID == nil):!key.isEmpty),
              controlAckFD.map({ $0 >= 3 }) ?? true,
              !key.contains("\n"), !key.contains("\r"),
              remainingUploadSeconds.map({$0.isFinite && $0>0 && $0<=14400}) ?? true,
              maxSeconds > 0, maxSeconds <= (isLocalOnly ? 7200:cloudSessionConfirmed==true ? 7200:450),
              model == "qwen-audio-3.0-asr-flash-streaming", [400, 800, 1300].contains(silenceMS)
        else { throw Failure(code: "invalid_config") }
    }
}

final class PCMConverter {
    let converter: AVAudioConverter
    let output: AVAudioFormat
    let microphoneChannelSelection:Bool
    private(set) var selectedInputChannel=0
    init(_ input: AVAudioFormat,microphoneChannelSelection:Bool=false) throws {
        guard input.sampleRate > 0, input.channelCount > 0,
              let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: input, to: out) else { throw Failure(code: "unsupported_audio_format") }
        converter = conv; output = out;self.microphoneChannelSelection=microphoneChannelSelection
        if microphoneChannelSelection {converter.channelMap=[0]}
    }
    func convert(_ input: AVAudioPCMBuffer) throws -> Data {
        if microphoneChannelSelection {
            let energy=hardwareChannelEnergy(input)
            if let strongest=energy.indices.max(by:{energy[$0].rms<energy[$1].rms}),
               strongest != selectedInputChannel,
               energy[strongest].rms>max(0.00001,energy[selectedInputChannel].rms*2) {
                // Keep a live channel when equally loud (including antiphase
                // stereo); switch away from a silent/weak channel explicitly.
                selectedInputChannel=strongest;converter.channelMap=[NSNumber(value:strongest)]
            }
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate) + 64)
        guard let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { throw Failure(code: "pcm_allocation") }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: result, error: &error) { _, state in
            if consumed { state.pointee = .noDataNow; return nil }
            consumed = true; state.pointee = .haveData; return input
        }
        guard error == nil, status != .error else { throw Failure(code: "pcm_conversion") }
        let audio = result.audioBufferList.pointee.mBuffers
        guard let pointer = audio.mData else { return Data() }
        return Data(bytes: pointer, count: Int(audio.mDataByteSize))
    }
}

private func microphoneDeviceSnapshot(_ device:AudioObjectID)->[String:Any] {
    var result:[String:Any]=["device_id":device,"observed_at":Date().timeIntervalSince1970]
    func prop(_ selector:AudioObjectPropertySelector,_ scope:AudioObjectPropertyScope=kAudioObjectPropertyScopeGlobal)->AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain)
    }
    for (key,selector) in [("name",kAudioObjectPropertyName),("uid",kAudioDevicePropertyDeviceUID)] {
        var p=prop(selector),value:Unmanaged<CFString>?,size=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status=AudioObjectGetPropertyData(device,&p,0,nil,&size,&value)
        if status==noErr,let value {result[key]=value.takeRetainedValue() as String}
    }
    for (key,selector,scope) in [("alive",kAudioDevicePropertyDeviceIsAlive,kAudioObjectPropertyScopeGlobal),("mute",kAudioDevicePropertyMute,kAudioObjectPropertyScopeInput)] {
        var p=prop(selector,scope),value:UInt32=0,size:UInt32=4
        let status=AudioObjectGetPropertyData(device,&p,0,nil,&size,&value)
        result[key+"_status"]=status;if status==noErr {result[key]=value != 0}
    }
    var gain:Float32=0,p=prop(kAudioDevicePropertyVolumeScalar,kAudioObjectPropertyScopeInput),size:UInt32=4
    let status=AudioObjectGetPropertyData(device,&p,0,nil,&size,&gain)
    result["gain_status"]=status;if status==noErr {result["gain"]=gain}
    return result
}

func hardwareChannelEnergy(_ buffer:AVAudioPCMBuffer)->[(samples:Int,nonzero:Int,peak:Double,rms:Double)] {
    let count=Int(buffer.frameLength),channels=Int(buffer.format.channelCount),interleaved=buffer.format.isInterleaved
    let list=UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:buffer.audioBufferList))
    return (0..<channels).map { channel in
        var samples=0,nonzero=0,peak=0.0,sum=0.0
        func add(_ value:Double) {guard value.isFinite else{return};samples+=1;if value != 0 {nonzero+=1};peak=max(peak,abs(value));sum+=value*value}
        let index=interleaved ? 0:channel
        if index<list.count,let base=list[index].mData {
            for frame in 0..<count {
                let offset=interleaved ? frame*channels+channel:frame
                switch buffer.format.commonFormat {
                case .pcmFormatFloat32:add(Double(base.assumingMemoryBound(to:Float.self)[offset]))
                case .pcmFormatFloat64:add(base.assumingMemoryBound(to:Double.self)[offset])
                case .pcmFormatInt16:add(Double(base.assumingMemoryBound(to:Int16.self)[offset])/32768)
                case .pcmFormatInt32:add(Double(base.assumingMemoryBound(to:Int32.self)[offset])/2147483648)
                default:break
                }
            }
        }
        return(samples,nonzero,peak,samples>0 ? sqrt(sum/Double(samples)):0)
    }
}
func hardwareInputEnergy(_ buffer:AVAudioPCMBuffer)->(samples:Int,nonzero:Int,peak:Double,rms:Double) {
    let values=hardwareChannelEnergy(buffer),samples=values.reduce(0){$0+$1.samples}
    return(samples,values.reduce(0){$0+$1.nonzero},values.map(\.peak).max() ?? 0,
           samples>0 ? sqrt(values.reduce(0){$0+$1.rms*$1.rms*Double($1.samples)}/Double(samples)):0)
}

// Configuration notifications also arrive for startup/output graph changes.
// Validate the actual microphone route, and reconcile off CoreAudio's callback.
func reconcileMicrophoneConfiguration(admitted:Bool,expectedDevice:UInt32,currentDevice:UInt32,
                                      defaultDevice:UInt32,formatMatches:Bool,engineRunning:Bool,
                                      restartAttempts:Int,restart:() throws->Void) throws->Bool {
    guard admitted else{return false}
    guard expectedDevice != 0,currentDevice==expectedDevice,defaultDevice==expectedDevice,formatMatches else {
        throw Failure(code:"input_device_changed")
    }
    guard !engineRunning else{return false}
    guard restartAttempts<3 else{throw Failure(code:"microphone_engine_restart_limit")}
    try restart()
    return true
}

func requireMicrophoneStartAvailable(installed:Bool) throws {
    guard !installed else{throw Failure(code:"microphone_already_started")}
}

// After the input unit is rebound, the engine can still report the previous
// route's tap format (48 kHz built-in → 24 kHz AirPods). A tap whose rate differs
// from the hardware raises an Objective-C exception that aborts the helper, so
// follow the bound hardware; a device still switching is a recoverable change.
func microphoneTapFormat(cached:AVAudioFormat,hardware:AVAudioFormat) throws->AVAudioFormat {
    guard hardware.sampleRate>0,hardware.channelCount>0 else{throw Failure(code:"input_device_changed")}
    if cached.sampleRate==hardware.sampleRate,cached.channelCount>0 {return cached}
    guard let current=AVAudioFormat(standardFormatWithSampleRate:hardware.sampleRate,channels:hardware.channelCount) else{
        throw Failure(code:"input_device_changed")
    }
    return current
}

// Shared by real resume and device-free regression fixtures. A running engine
// alone is insufficient: only fresh admitted PCM can acknowledge a resume.
func waitForMicrophoneResume(timeout:Double=1,stillRequested:()->Bool,
                             validateEngine:() throws->Bool,hasFreshFrame:()->Bool) async throws->Bool {
    let deadline=ProcessInfo.processInfo.systemUptime+timeout
    while stillRequested() {
        guard try validateEngine(),stillRequested() else{return false}
        if hasFreshFrame() {return stillRequested()}
        if ProcessInfo.processInfo.systemUptime>=deadline {throw Failure(code:"microphone_resume_no_frames")}
        try await Task.sleep(nanoseconds:10_000_000)
    }
    return false
}

// Queue saturation is exceptional, but the hardware callback must never wait
// for conversion capacity. Collapse repeated callbacks into one recoverable
// pause request while keeping the exact duration of buffers that could not be
// admitted for conversion.
final class MicrophoneBackpressurePauseGate {
    private enum State { case idle, pending, accepted, rejected }
    private let lock=NSLock()
    private var state=State.idle
    private var intervalDroppedSeconds=0.0
    private var totalDroppedSeconds=0.0

    @discardableResult func report(droppedSeconds:Double,request:()->Bool)->Bool {
        lock.lock()
        let duration=droppedSeconds.isFinite ? max(0,droppedSeconds):0
        intervalDroppedSeconds+=duration;totalDroppedSeconds+=duration
        switch state {
        case .accepted: lock.unlock();return true
        case .rejected: lock.unlock();return false
        case .pending: lock.unlock();return true
        case .idle: state = .pending;lock.unlock()
        }
        let accepted=request()
        lock.lock();state=accepted ? .accepted:.rejected;lock.unlock()
        return accepted
    }

    func resetForResume() {
        lock.lock();state = .idle;intervalDroppedSeconds=0;lock.unlock()
    }

    func snapshot()->(requested:Bool,intervalDroppedSeconds:Double,totalDroppedSeconds:Double) {
        lock.lock();defer{lock.unlock()}
        return(state != .idle,intervalDroppedSeconds,totalDroppedSeconds)
    }
}

@discardableResult func handleMicrophoneConversionBackpressure(
    gate:MicrophoneBackpressurePauseGate,frames:Int,sampleRate:Double,
    requestPause:()->Bool,mailbox:Mailbox)->Bool {
    let seconds=sampleRate.isFinite && sampleRate>0 ? Double(max(0,frames))/sampleRate:0
    let accepted=gate.report(droppedSeconds:seconds,request:requestPause)
    if !accepted {mailbox.fail("mic_conversion_backpressure")}
    return accepted
}

@discardableResult func writeQueuedMicrophonePCM(_ pcm:Data,at timestamp:Double,to mailbox:Mailbox)->Bool {
    guard !pcm.isEmpty else{return false}
    if mailbox.put(pcm,at:timestamp){return true}
    return mailbox.putPreviouslyAdmitted(pcm,at:timestamp)
}

/// Which input device a recording uses: follow the system default (plug in
/// headphones, record from them), but never stay on a device that delivers
/// only digital silence; fall back to the last device that produced sound.
struct MicrophoneDevicePolicy {
    private(set) var lastGood:AudioObjectID=0
    private(set) var rejected:AudioObjectID=0
    private var silentDevice:AudioObjectID=0
    private var silentStrikes=0
    /// Restarts on the same device before declaring it broken: a just-switched
    /// headset (especially Bluetooth) can need a few seconds to deliver sound.
    static let restartsBeforeFallback=2
    mutating func confirmGood(_ device:AudioObjectID) {
        guard device != 0 else{return}
        lastGood=device
        if rejected==device {rejected=0}
        if silentDevice==device {silentDevice=0;silentStrikes=0}
    }
    /// True while the silent device still gets an in-place restart.
    mutating func retrySilent(_ device:AudioObjectID)->Bool {
        if silentDevice != device {silentDevice=device;silentStrikes=0}
        silentStrikes+=1
        return silentStrikes<=Self.restartsBeforeFallback
    }
    /// Returns true when a different, previously working device is available.
    mutating func reject(_ device:AudioObjectID,alive:(AudioObjectID)->Bool,builtIn:AudioObjectID)->Bool {
        guard device != 0 else{return false}
        rejected=device
        return fallback(excluding:device,alive:alive,builtIn:builtIn) != 0
    }
    /// Prefer the last device that produced sound, else the Mac's own microphone.
    private func fallback(excluding device:AudioObjectID,alive:(AudioObjectID)->Bool,builtIn:AudioObjectID)->AudioObjectID {
        if lastGood != 0 && lastGood != device && alive(lastGood) {return lastGood}
        if builtIn != 0 && builtIn != device && alive(builtIn) {return builtIn}
        return 0
    }
    /// A rejected device that is no longer the default (unplugged or switched
    /// away) gets a fresh chance the next time it becomes the default.
    mutating func observeDefault(_ device:AudioObjectID) {
        if rejected != 0 && device != rejected {rejected=0}
    }
    func choose(defaultDevice:AudioObjectID,alive:(AudioObjectID)->Bool,builtIn:AudioObjectID)->AudioObjectID {
        guard defaultDevice == rejected else {return defaultDevice}
        let other=fallback(excluding:defaultDevice,alive:alive,builtIn:builtIn)
        return other != 0 ? other:defaultDevice
    }
    /// The default moving matters only when it is not the device we just rejected.
    func effectiveDefault(_ defaultDevice:AudioObjectID,bound:AudioObjectID)->AudioObjectID {
        defaultDevice == rejected ? bound:defaultDevice
    }
}

/// The Mac's built-in input device, or 0 when none is present.
func builtInInputDevice()->AudioObjectID {
    var property=address(kAudioHardwarePropertyDevices),size:UInt32=0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&property,0,nil,&size)==noErr,size>0 else{return 0}
    var devices=[AudioObjectID](repeating:0,count:Int(size)/MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&property,0,nil,&size,&devices)==noErr else{return 0}
    for device in devices {
        var transport=address(kAudioDevicePropertyTransportType),kind:UInt32=0,kindSize=UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device,&transport,0,nil,&kindSize,&kind)==noErr,kind==kAudioDeviceTransportTypeBuiltIn else{continue}
        var streams=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreams,mScope:kAudioDevicePropertyScopeInput,mElement:kAudioObjectPropertyElementMain)
        var streamSize:UInt32=0
        if AudioObjectGetPropertyDataSize(device,&streams,0,nil,&streamSize)==noErr,streamSize>0 {return device}
    }
    return 0
}

func audioDeviceIsAlive(_ device:AudioObjectID)->Bool {
    var property=address(kAudioDevicePropertyDeviceIsAlive),alive:UInt32=0,size=UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(device,&property,0,nil,&size,&alive)==noErr && alive != 0
}

// Bounded by audio duration and memory, independent of the device's callback
// packet size. A short scheduling stall must not exhaust twenty small packets.
final class MicrophoneConversionBudget {
    struct Ticket {let seconds:Double;let bytes:Int}
    private let lock=NSLock()
    private var seconds=0.0,peak=0.0
    private var bytes=0,packets=0
    func acquire(frames:Int,sampleRate:Double,channels:Int)->Ticket? {
        let memoryLimit=32*1024*1024
        guard frames>0,channels>0,channels<=256,sampleRate.isFinite,sampleRate>0,
              frames<=memoryLimit/(8*channels) else{return nil}
        let ticket=Ticket(seconds:Double(frames)/sampleRate,bytes:frames*channels*8)
        lock.lock();defer{lock.unlock()}
        guard seconds+ticket.seconds<=10.000001,bytes+ticket.bytes<=memoryLimit,packets<4096 else{return nil}
        seconds+=ticket.seconds;bytes+=ticket.bytes;packets+=1;peak=max(peak,seconds)
        return ticket
    }
    func release(_ ticket:Ticket) {lock.lock();seconds=max(0,seconds-ticket.seconds);bytes=max(0,bytes-ticket.bytes);packets=max(0,packets-1);lock.unlock()}
    func snapshot()->[String:Any] {lock.lock();defer{lock.unlock()};return ["pending_seconds":seconds,"peak_seconds":peak,"pending_bytes_upper_bound":bytes,"capacity_seconds":10]}
}

final class Microphone {
    let engine = AVAudioEngine()
    let queue = DispatchQueue(label: "meeting.mic.convert",qos:.userInitiated)
    private let control = DispatchQueue(label:"meeting.mic.lifecycle",qos:.userInitiated)
    private var generation=UUID()
    private var restartAttempts=0,configurationNotifications=0
    let capacity = MicrophoneConversionBudget()
    private let backpressurePause=MicrophoneBackpressurePauseGate()
    private let diagnosticLock=NSLock()
    private var deviceInfo:[String:Any]=[:]
    private var inputSamples=0,inputNonzero=0,inputCallbacks=0
    private var inputPeak=0.0,inputRMS=0.0
    private var channelTotals:[Int:Int]=[:],lastChannels:[[String:Any]]=[]
    private var selectedChannel=0
    private var copiedChannels:[[String:Any]]=[]
    var installed = false
    var recoverableFaultHandler:((String)->Bool)?
    private var reconcileCurrentConfiguration:(() throws->Void)?
    private var admittedFrames=0,lastAdmittedTimestamp=0.0
    var configurationObserver:NSObjectProtocol?
    private var devicePolicy=MicrophoneDevicePolicy()
    private var boundDevice:AudioObjectID=0
    /// The bound device just produced real (non-zero) audio.
    func confirmSignal() {control.async{[self] in devicePolicy.confirmGood(boundDevice)}}
    /// The bound device delivers only digital silence; true when a working
    /// fallback exists and a restart will move to it.
    enum SilentAction {case restarted,fallback,none}
    /// Silent bound device: first restart it in place (it may still be waking
    /// up); only after repeated silence reject it in favour of a working one.
    func handleSilentDevice()->SilentAction {
        control.sync{
            guard installed else{return .none}
            if devicePolicy.retrySilent(boundDevice) {
                engine.stop()
                do {try engine.start();diagnosticLock.lock();restartAttempts+=1;diagnosticLock.unlock();return .restarted}
                catch {return devicePolicy.reject(boundDevice,alive:audioDeviceIsAlive,builtIn:builtInInputDevice()) ? .fallback:.none}
            }
            return devicePolicy.reject(boundDevice,alive:audioDeviceIsAlive,builtIn:builtInInputDevice()) ? .fallback:.none
        }
    }
    func diagnostics()->[String:Any] {
        diagnosticLock.lock();defer{diagnosticLock.unlock()}
        let pressure=backpressurePause.snapshot()
        return ["input_device":deviceInfo,"configuration_notifications":configurationNotifications,"engine_restarts":restartAttempts,"input_callback_count":inputCallbacks,
                "input_samples":inputSamples,"input_nonzero_samples":inputNonzero,
                "input_peak":inputPeak,"input_rms":inputRMS,"input_channels":lastChannels,"copied_input_channels":copiedChannels,"selected_input_channel":selectedChannel,"channel_policy":"live_channel_without_phase_cancellation",
                "conversion_backpressure_pause_requested":pressure.requested,
                "conversion_backpressure_dropped_seconds":pressure.intervalDroppedSeconds,
                "conversion_backpressure_dropped_seconds_total":pressure.totalDroppedSeconds]
    }
    func start(_ box: Mailbox) throws {try control.sync {try startOnControl(box)}}
    private func startOnControl(_ box:Mailbox) throws {
        try requireMicrophoneStartAvailable(installed:installed)
        generation=UUID();let activeGeneration=generation
        backpressurePause.resetForResume()
        diagnosticLock.lock();restartAttempts=0;configurationNotifications=0;admittedFrames=0;lastAdmittedTimestamp=0;diagnosticLock.unlock()
        let input = engine.inputNode
        // AVAudioEngine can retain a previous/default route across starts.
        // Bind only this helper's AudioUnit to the current system selection,
        // verify readback, and retain the route as evidence for this run.
        var property=address(kAudioHardwarePropertyDefaultInputDevice),device:AudioObjectID=0,size=UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&property,0,nil,&size,&device),"microphone_default_device")
        devicePolicy.observeDefault(device)
        device=devicePolicy.choose(defaultDevice:device,alive:audioDeviceIsAlive,builtIn:builtInInputDevice())
        guard device != kAudioObjectUnknown,let unit=input.audioUnit else {throw Failure(code:"microphone_input_unavailable")}
        var actual:AudioObjectID=0
        try check(AudioUnitGetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&actual,&size),"microphone_read_device")
        if actual != device {
            try check(AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&device,size),"microphone_bind_device")
        }
        try check(AudioUnitGetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&actual,&size),"microphone_read_device")
        guard actual==device else {throw Failure(code:"microphone_device_mismatch")}
        boundDevice=actual
        let format = try microphoneTapFormat(cached:input.outputFormat(forBus:0),hardware:input.inputFormat(forBus:0))
        let converter = try PCMConverter(format,microphoneChannelSelection:true)
        var info=microphoneDeviceSnapshot(actual)
        info["sample_rate"]=format.sampleRate;info["channels"]=format.channelCount
        info["common_format"]=format.commonFormat.rawValue;info["interleaved"]=format.isInterleaved
        info["microphone_permission_authorized"]=AVCaptureDevice.authorizationStatus(for:.audio) == .authorized
        diagnosticLock.lock();deviceInfo=info;diagnosticLock.unlock()
        if info["alive"] as? Bool==false {throw Failure(code:"microphone_device_disconnected")}
        if info["mute"] as? Bool==true {throw Failure(code:"microphone_device_muted")}
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate * 0.1), format: format) { buffer, time in
            guard captureAdmissionOpen() else { return }
            guard let ticket=self.capacity.acquire(frames:Int(buffer.frameLength),sampleRate:format.sampleRate,channels:Int(format.channelCount)) else {
                _=handleMicrophoneConversionBackpressure(gate:self.backpressurePause,
                    frames:Int(buffer.frameLength),sampleRate:format.sampleRate,
                    requestPause:{self.recoverableFaultHandler?("mic_conversion_backpressure") ?? false},
                    mailbox:box)
                return
            }
            let hardwareChannels=hardwareChannelEnergy(buffer)
            guard let copied = clone(buffer) else { self.capacity.release(ticket); box.fail("mic_copy"); return }
            let stamp = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : ProcessInfo.processInfo.systemUptime
            self.queue.async {
                defer { self.capacity.release(ticket) }
                let copiedEnergy=hardwareChannelEnergy(copied),channels=hardwareChannels,samples=channels.reduce(0){$0+$1.samples}
                self.diagnosticLock.lock();self.inputCallbacks+=1;self.inputSamples+=samples
                self.inputNonzero+=channels.reduce(0){$0+$1.nonzero};self.inputPeak=channels.map(\.peak).max() ?? 0
                self.inputRMS=samples>0 ? sqrt(channels.reduce(0){$0+$1.rms*$1.rms*Double($1.samples)}/Double(samples)):0
                self.copiedChannels=copiedEnergy.enumerated().map{["channel":$0.offset,"nonzero_samples":$0.element.nonzero,"peak":$0.element.peak,"rms":$0.element.rms]}
                self.lastChannels=channels.enumerated().map { index,value in
                    self.channelTotals[index,default:0]+=value.nonzero
                    return ["channel":index,"samples":value.samples,"nonzero_samples":value.nonzero,"cumulative_nonzero_samples":self.channelTotals[index] ?? 0,"peak":value.peak,"rms":value.rms]
                };self.diagnosticLock.unlock()
                do {
                    let data = try converter.convert(copied)
                    self.diagnosticLock.lock();self.selectedChannel=converter.selectedInputChannel;self.diagnosticLock.unlock()
                    if !data.isEmpty {
                        // This callback passed the capture gate before queuing.
                        // Drain it during pause teardown so every admitted
                        // pre-boundary buffer reaches the journal in order.
                        _=writeQueuedMicrophonePCM(data,at:stamp,to:box)
                        self.diagnosticLock.lock();self.admittedFrames+=1;self.lastAdmittedTimestamp=stamp;self.diagnosticLock.unlock()
                    }
                }
                catch { box.fail("mic_conversion") }
            }
        }
        installed = true
        engine.prepare()
        try engine.start()
        reconcileCurrentConfiguration = { [weak self] in
            guard let self,self.installed,self.generation==activeGeneration else {throw Failure(code:"microphone_resume_generation_changed")}
            self.diagnosticLock.lock();let attempts=self.restartAttempts;self.diagnosticLock.unlock()
            var current:AudioObjectID=0,selected:AudioObjectID=0,bytes=UInt32(MemoryLayout<AudioObjectID>.size)
            var field=address(kAudioHardwarePropertyDefaultInputDevice)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&field,0,nil,&bytes,&selected),"microphone_default_device")
            try check(AudioUnitGetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&current,&bytes),"microphone_read_device")
            let observed=input.outputFormat(forBus:0)
            self.devicePolicy.observeDefault(selected)
            let restarted=try reconcileMicrophoneConfiguration(admitted:capturePaused==0 && interrupted==0,expectedDevice:actual,
                currentDevice:current,defaultDevice:self.devicePolicy.effectiveDefault(selected,bound:actual),formatMatches:observed==format,
                engineRunning:self.engine.isRunning,restartAttempts:attempts,restart:{
                    guard capturePaused==0 && interrupted==0 else{return}
                    try self.engine.start()
                })
            if restarted {self.diagnosticLock.lock();self.restartAttempts+=1;self.diagnosticLock.unlock()}
        }
        configurationObserver=NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:engine,queue:nil){[weak self] _ in
            self?.control.async {[weak self] in
                guard let self,self.installed,self.generation==activeGeneration else{return}
                self.diagnosticLock.lock();self.configurationNotifications+=1;self.diagnosticLock.unlock()
                // A closed gate never restarts hardware from a notification.
                // Explicit resume revalidates this same route before admission.
                guard captureAdmissionOpen() else{return}
                do {try self.reconcileCurrentConfiguration?()}
                catch {
                    let code=(error as? Failure)?.code ?? "microphone_engine_restart_failed"
                    if self.recoverableFaultHandler?(code)==true {return}
                    box.fail(code)
                }
            }
        }
    }
    func prepareForResume(revision:sig_atomic_t) throws->Bool {
        try control.sync {
            guard captureControlRevision==revision,capturePaused==0,interrupted==0 else{return false}
            guard installed,let reconcile=reconcileCurrentConfiguration else{throw Failure(code:"microphone_resume_not_started")}
            try reconcile()
            guard captureControlRevision==revision,capturePaused==0,interrupted==0 else{return false}
            guard engine.isRunning else{throw Failure(code:"microphone_engine_restart_failed")}
            return true
        }
    }
    func frameEvidence()->(count:Int,hostTime:Double) {
        diagnosticLock.lock();defer{diagnosticLock.unlock()};return(admittedFrames,lastAdmittedTimestamp)
    }
    func stop() { control.sync {generation=UUID();reconcileCurrentConfiguration=nil;if let observer=configurationObserver {NotificationCenter.default.removeObserver(observer);configurationObserver=nil};engine.stop();if installed {engine.inputNode.removeTap(onBus:0);installed=false}};queue.sync {} }

}

// Ask only from the actual capturing helper, after the launch request has been
// validated. macOS remembers the decision; launch/model preparation never ask.
func requireMicrophonePermission() async throws {
    switch AVCaptureDevice.authorizationStatus(for:.audio) {
    case .authorized:return
    case .notDetermined:
        let allowed=await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for:.audio){continuation.resume(returning:$0)}
        }
        guard allowed else {throw Failure(code:"microphone_permission_denied")}
    default:throw Failure(code:"microphone_permission_denied")
    }
}
func clone(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { return nil }
    copy.frameLength = input.frameLength
    let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
    let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for (s, t) in zip(source, target) {
        guard let from = s.mData, let to = t.mData else { return nil }
        memcpy(to, from, Int(s.mDataByteSize))
    }
    return copy
}

// A process tap describes its mix format; the IOProc receives the aggregate
// input stream's virtual format. Bluetooth call routes can make these differ.
func applicationTapInputFormat(device:AudioObjectID)throws->AVAudioFormat {
    var property=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreams,mScope:kAudioObjectPropertyScopeInput,mElement:kAudioObjectPropertyElementMain)
    var size:UInt32=0
    try check(AudioObjectGetPropertyDataSize(device,&property,0,nil,&size),"tap_input_streams_size")
    guard size==UInt32(MemoryLayout<AudioObjectID>.size) else{throw Failure(code:"tap_input_stream_layout")}
    var stream:AudioObjectID=0
    try check(AudioObjectGetPropertyData(device,&property,0,nil,&size,&stream),"tap_input_stream")
    property=address(kAudioStreamPropertyVirtualFormat)
    var asbd=AudioStreamBasicDescription();size=UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(AudioObjectGetPropertyData(stream,&property,0,nil,&size,&asbd),"tap_input_virtual_format")
    guard asbd.mFormatID==kAudioFormatLinearPCM,asbd.mSampleRate.isFinite,
          (8000...384000).contains(asbd.mSampleRate),asbd.mChannelsPerFrame>0,
          asbd.mBytesPerFrame>0,let format=AVAudioFormat(streamDescription:&asbd) else{
        throw Failure(code:"tap_input_format_unsupported")
    }
    return format
}

// Device-free clock check shared by both tap paths. A route can change its
// sample rate without changing its device ID; stop using that format promptly.
struct ApplicationTapClockCheck {
    private var anchor:(sample:Double,host:Double)?
    mutating func accepts(_ time:AudioTimeStamp,sampleRate:Double)->Bool {
        guard time.mFlags.contains(.sampleTimeValid),time.mFlags.contains(.hostTimeValid) else{return true}
        let host=AVAudioTime.seconds(forHostTime:time.mHostTime),sample=time.mSampleTime
        guard host.isFinite,sample.isFinite else{return false}
        guard let old=anchor else{anchor=(sample,host);return true}
        let elapsed=host-old.host
        guard elapsed>=0,sample>=old.sample else{return false}
        guard elapsed>=0.1 else{return true}
        anchor=(sample,host)
        return abs((sample-old.sample)/elapsed/sampleRate-1)<=0.05
    }
}

@available(macOS 14.2, *)
final class ApplicationTap {
    var tap: AudioObjectID = 0
    var device: AudioObjectID = 0
    var io: AudioDeviceIOProcID?
    var selectedPIDs: [pid_t] = []
    let queue = DispatchQueue(label: "meeting.app.tap",qos:.userInitiated)
    var outputClock: AudioObjectID = 0
    var excludedAudioObjects:[AudioObjectID]=[]
    var capturedInputFormat:AVAudioFormat?
    func inputFormatChanged()->Bool {
        guard device != 0,let capturedInputFormat else{return false}
        guard let current=try? applicationTapInputFormat(device:device) else{return true}
        return !current.isEqual(capturedInputFormat)
    }
    func start(bundle: String, micEnabled:Bool, box: Mailbox,announce:Bool=true) throws {
        // Retry teardown of anything a failed earlier stop left behind.
        if device != 0 || tap != 0 {try? stopChecked()}
        let global = bundle == "*system*"
        let pids = global ? selfAudioPIDs() : processes(bundle: bundle)
        guard global || !pids.isEmpty else { throw Failure(code: "selected_application_not_running") }
        selectedPIDs = pids
        var ids: [AudioObjectID] = []
        for var pid in pids {
            var property = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var object: AudioObjectID = 0; var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status=AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property,
                      UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
            if global && status != noErr {continue}
            try check(status,"selected_process_audio")
            if object == kAudioObjectUnknown && global {continue}
            guard object != kAudioObjectUnknown else { throw Failure(code: "selected_process_no_audio_object") }
            ids.append(object)
        }
        // Explicit global exclusion or selected inclusive list; never mute playback.
        let description = scopeDescription(global:global,ids:ids)
        if global {excludedAudioObjects=ids.sorted()}
        description.name = global ? "在场：电脑声音（排除自身）" : "在场：选定应用输出"
        description.uuid = UUID(); description.isPrivate = true; description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), "create_selected_tap")
        var asbd = AudioStreamBasicDescription()
        var property = address(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &asbd), "tap_format")
        let declaredTapSampleRate=asbd.mSampleRate
        // Include the output device as the aggregate clock, matching the CoreAudio sample setup.
        var systemProperty = address(kAudioHardwarePropertyDefaultOutputDevice)
        var outputDevice: AudioObjectID = 0
        var outputSize = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &systemProperty, 0, nil, &outputSize, &outputDevice), "output_clock_device")
        outputClock = outputDevice
        var uidProperty = address(kAudioDevicePropertyDeviceUID)
        var outputUID: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(outputDevice, &uidProperty, 0, nil, &uidSize, &outputUID), "output_clock_uid")
        guard let clockUID = outputUID?.takeRetainedValue() else { throw Failure(code: "missing_output_clock") }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "在场临时私有设备",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID,
                                                     kAudioSubDeviceInputChannelsKey: 0]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                             kAudioSubTapDriftCompensationKey: true]]
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "create_private_aggregate")
        let format=try applicationTapInputFormat(device:device)
        asbd=format.streamDescription.pointee;capturedInputFormat=format
        let converter=try PCMConverter(format)
        var formatClock=ApplicationTapClockCheck()
        let formatInfo:[String:Any]=["type":"capture_format","source_id":global ? "reference":"remote",
              "tap_sample_rate":declaredTapSampleRate,"input_sample_rate":format.sampleRate,
              "input_channels":format.channelCount,"input_bytes_per_frame":asbd.mBytesPerFrame]
        box.journal?.recordCaptureFormat(formatInfo)
        emit(formatInfo)
        try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, queue) { _, input, inputTime, _, _ in
            guard captureAdmissionOpen() else { return }
            guard formatClock.accepts(inputTime.pointee,sampleRate:format.sampleRate) else{box.fail("tap_input_clock_changed");return}
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = list.first, asbd.mBytesPerFrame > 0 else { box.fail("tap_empty_format"); return }
            let frames = AVAudioFrameCount(first.mDataByteSize / asbd.mBytesPerFrame)
            guard let copied = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { box.fail("tap_copy"); return }
            copied.frameLength = frames
            let target = UnsafeMutableAudioBufferListPointer(copied.mutableAudioBufferList)
            guard target.count == list.count else { box.fail("tap_channel_layout"); return }
            for (source, destination) in zip(list, target) {
                guard source.mDataByteSize <= destination.mDataByteSize, let from = source.mData, let to = destination.mData else { box.fail("tap_buffer_layout"); return }
                memcpy(to, from, Int(source.mDataByteSize))
            }
            let stamp = inputTime.pointee.mFlags.contains(.hostTimeValid) ? AVAudioTime.seconds(forHostTime: inputTime.pointee.mHostTime) : ProcessInfo.processInfo.systemUptime
            do { let data = try converter.convert(copied); if !data.isEmpty { _ = writeCapturedPCMIfAdmitted(data,at:stamp,to:box) } }
            catch { box.fail("tap_conversion") }
        }, "create_tap_io")
        try check(AudioDeviceStart(device, io), "start_tap")
        if announce {emit(["type": "capture_scope", "bundle": bundle, "pids": pids, "tracks": micEnabled ? ["mic", "remote"] : ["remote"]])}
    }
    func stop() {
        try? stopChecked()
    }
    func stopChecked() throws {
        // Clear each handle only after it is really destroyed. A failed destroy
        // keeps its handle so the next stop/start can retry instead of leaking
        // a process tap or aggregate device on every pause-resume cycle.
        var failure:String?
        if device != 0 {
            let stopStatus=AudioDeviceStop(device, io);if stopStatus != noErr { failure="tap_device_stop:\(stopStatus)" }
            if let id = io {let status=AudioDeviceDestroyIOProcID(device,id);if status == noErr {io=nil} else if failure==nil {failure="tap_ioproc_destroy:\(status)"}}
            let status=AudioHardwareDestroyAggregateDevice(device);if status == noErr {device=0;io=nil} else if failure==nil {failure="tap_aggregate_destroy:\(status)"}
        }
        if tap != 0 {let status=AudioHardwareDestroyProcessTap(tap);if status == noErr {tap=0} else if failure==nil {failure="tap_destroy:\(status)"}}
        if let failure {throw Failure(code:failure)}
    }
}

func providerUsage(_ object:[String:Any],task:String,track:String)throws->[String:Any]? {
    guard let header=object["header"] as? [String:Any],header["task_id"] as? String==task else {throw Failure(code:"task_mismatch")}
    let event=header["event"] as? String ?? ""
    guard ["result-generated","task-finished"].contains(event),let payload=object["payload"] as? [String:Any],let usage=payload["usage"] as? [String:Any],let value=usage["duration"] else {return nil}
    guard let number=value as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue.isFinite,number.doubleValue>=0 else {throw Failure(code:"invalid_provider_usage")}
    return ["type":"usage_provider","track":track,"task_id":task,"duration":number.doubleValue,"final":event=="task-finished"]
}

protocol ASRSocket:AnyObject {
    func resume()
    func cancel(with:URLSessionWebSocketTask.CloseCode,reason:Data?)
    func send(_ message:URLSessionWebSocketTask.Message) async throws
    func receive() async throws->URLSessionWebSocketTask.Message
}
extension URLSessionWebSocketTask:ASRSocket {}
actor Lane {
    var ws:ASRSocket
    let socketFactory:()->ASRSocket
    var task: String
    let speakerEpoch:String
    var taskAttemptedBytes=0;var replayBase=0;var finalCursor=0;var retryCount=0;var partialIDs=Set<String>();var transportFailed=false
    let decoder = Decoder()
    let track: String; let config: Config
    var speakerPipeline:SpeakerPipeline?
    var journal:RecordingJournal?
    private var journalConsumerActive=false
    func claimJournalConsumer()->Bool {guard !journalConsumerActive,!stopped else{return false};journalConsumerActive=true;return true}
    func releaseJournalConsumer(){journalConsumerActive=false}
    var transportError:String?
    var sentBytes = 0
    var providerCounter = 0.0
    var origin: Double?
    var receiptClock:Double?;var receiptFloor=0.0
    var stopped = false
    var closing = false
    private var uploadPaused = false
    private var inFlightAudioSends = 0
    var finished = false
    var ready = false
    var attemptedBytes = 0
    var inFlightBytes = 0
    var sendCalls = 0
    var sendWaitTotal = 0.0
    var sendWaitMax = 0.0
    var modelWaitTotal=0.0;var modelWaitMax=0.0;var socketWaitTotal=0.0;var socketWaitMax=0.0;var annotationWaitTotal=0.0;var annotationWaitMax=0.0;var queueAgeTotal=0.0;var queueAgeMax=0.0
    var finalSpeakerDiagnostics:[String:Any]=[:];var modelProcessedBytes=0;var modelOrigin:Double?;var speakerReady=false
    let sourceMetadata:[String:Any];let sessionBudget:SessionUploadBudget?
    init(track: String, config: Config, prepared: SpeakerPipeline? = nil, preparedEpoch: String? = nil,socketFactory:(()->ASRSocket)?=nil,metadata:[String:Any]=[:],budget:SessionUploadBudget?=nil) {
        self.sourceMetadata=metadata;self.sessionBudget=budget
        self.track = track; self.config = config
        self.speakerEpoch=preparedEpoch ?? UUID().uuidString;self.task = UUID().uuidString; self.speakerPipeline = prepared;self.speakerReady=prepared != nil
        var request = URLRequest(url: URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference/")!)
        request.setValue("Bearer " + config.key, forHTTPHeaderField: "Authorization")
        // Standard URLSession trust validation, no custom trust bypass or redirects.
        self.socketFactory=socketFactory ?? {URLSession.shared.webSocketTask(with:request)}
        ws=self.socketFactory()
    }
    func discardRecoveredPartials(_ events:[[String:Any]]) {let ids=events.filter{$0["final"] as? Bool != true}.compactMap{$0["segment_id"] as? String};if !ids.isEmpty {publish(["type":"asr_replay","track":track,"discard_segment_ids":ids,"resume_sample":replayBase/2])}}
    func configureReceiptClock(floor:Double){receiptClock=ProcessInfo.processInfo.systemUptime;receiptFloor=max(0,floor)}
    func beginAt(_ cursor:Int){replayBase=cursor;finalCursor=cursor}
    func seed(_ events:[[String:Any]]) async {if let pipeline=speakerPipeline {for event in events where event["final"] as? Bool==true {publish(await pipeline.accept(event))}}}
    func attachJournal(_ store:RecordingJournal?){journal=store}
    func publish(_ event:[String:Any]){let annotated=event.merging(sourceMetadata){old,_ in old};journal?.record(annotated);emit(annotated)}
    func prepareSpeakers() async throws {
        if speakerReady { return }
        guard let path=config.localSpeakerDirectory else{return}
        let pipeline=SpeakerPipeline(source:track,epoch:speakerEpoch)
        emit(["type":"speaker_model","state":"loading","track":track,"capture":true])
        do {try await pipeline.load(directory:URL(fileURLWithPath:path),embeddingModel:config.localEmbeddingModel.map{URL(fileURLWithPath:$0)})}
        catch {_ = try? await pipeline.close(flush:false);speakerPipeline=nil;speakerReady=false;throw error}
        speakerPipeline=pipeline;speakerReady=true
        emit(["type":"speaker_model","state":"ready","track":track,"identity_available":false])
    }
    func finishSpeakerInput() async {
        guard let pipeline=speakerPipeline else{return}
        do {for update in try await pipeline.finishInput() {publish(update)}}
        catch {emit(["type":"speaker_model","state":"failed","track":track,"reason":"speaker_tail_failed","asr_continues":true,"audio_retained":true])}
        speakerReady=false
    }
    func command(_ action: String) throws -> String {
        let payload: [String: Any] = action == "run-task" ? ["task_group": "audio", "task": "asr", "function": "recognition",
                 "model": config.model, "parameters": ["format":"pcm","sample_rate":16000,"max_sentence_silence":config.silenceMS], "input": [String: Any]()] : ["input": [String: Any]()]
        let output: [String: Any] = ["header": ["action": action, "task_id": task, "streaming": "duplex"], "payload": payload]
        return String(data: try JSONSerialization.data(withJSONObject: output), encoding: .utf8)!
    }
    func reconnect(at cursor:Int) async {
        while ((captureUploadPaused != 0 || uploadPaused) && interrupted == 0 && !stopped) { try? await Task.sleep(nanoseconds:10_000_000) }
        guard !stopped,interrupted<2,captureUploadPaused==0,!uploadPaused else{return}
        emit(["type":"usage_local","track":track,"task_id":task,"sent_audio_seconds":Double(taskAttemptedBytes)/32000])
        ws.cancel(with:.goingAway,reason:nil)
        if let pipeline=speakerPipeline {await pipeline.discard(partialIDs)}
        publish(["type":"asr_replay","track":track,"discard_segment_ids":Array(partialIDs),"resume_sample":cursor/2])
        partialIDs=[];taskAttemptedBytes=0;task=UUID().uuidString;replayBase=cursor;origin=nil;closing=false;finished=false;ready=false;transportFailed=false;transportError=nil;providerCounter=0
        retryCount+=1
        var request=URLRequest(url:URL(string:"wss://dashscope.aliyuncs.com/api-ws/v1/inference/")!)
        request.setValue("Bearer "+config.key,forHTTPHeaderField:"Authorization");ws=socketFactory()
    }
    func confirmedCursor()->Int {finalCursor}
    func didFinish()->Bool {finished}
    func transportFailure(_ code:String="asr_transport_error"){transportFailed=true;transportError=code;ready=false;ws.cancel(with:.goingAway,reason:nil)}
    func transportFailureCode()->String? {transportFailed ? (transportError ?? "asr_transport_error"):nil}
    func hasTransportFailure()->Bool {transportFailed}
    func start() async throws {
        while ((captureUploadPaused != 0 || uploadPaused) && interrupted == 0 && !stopped) { try await Task.sleep(nanoseconds:10_000_000) }
        guard !stopped,interrupted<2,captureUploadPaused==0,!uploadPaused else { throw Failure(code:"capture_interrupted") }
        while true {
            try Task.checkCancellation()
            while ((captureUploadPaused != 0 || uploadPaused) && interrupted == 0 && !stopped) {try await Task.sleep(nanoseconds:10_000_000)}
            guard !stopped,interrupted<2,captureUploadPaused==0,!uploadPaused else{throw Failure(code:"capture_interrupted")}
            ws.resume();try await ws.send(.string(command("run-task")))
            let object=try parse(try await ws.receive())
            try Task.checkCancellation()
            guard !stopped,interrupted<2 else{throw Failure(code:"capture_interrupted")}
            guard let h=object["header"] as? [String:Any],h["task_id"] as? String==task else{throw Failure(code:"asr_not_started:"+track)}
            if h["event"] as? String=="task-failed" {
                throw Failure(code:asrProviderFailure(h,track:track))
            }
            guard h["event"] as? String=="task-started" else{throw Failure(code:"asr_not_started:"+track)}
            ready=true;return
        }
    }
    func isReady() -> Bool { ready && !stopped }
    func metrics(includeSpeakerDiagnostics:Bool=true) async -> [String: Any] {
        var result:[String:Any]=["task_id": task, "provider_audio_seconds": providerCounter, "asr_ready": ready && !stopped, "sent_audio_seconds": Double(sentBytes) / 32000,
         "attempted_audio_seconds": Double(attemptedBytes) / 32000,"task_attempted_audio_seconds":Double(taskAttemptedBytes)/32000, "inflight_bytes": inFlightBytes,
         "send_calls": sendCalls, "send_wait_total_seconds": sendWaitTotal, "send_wait_max_seconds": sendWaitMax,"model_ingest_wait_total_seconds":modelWaitTotal,"model_ingest_wait_max_seconds":modelWaitMax,"socket_send_wait_total_seconds":socketWaitTotal,"socket_send_wait_max_seconds":socketWaitMax,"annotation_wait_total_seconds":annotationWaitTotal,"annotation_wait_max_seconds":annotationWaitMax,"queue_age_total_seconds":queueAgeTotal,"queue_age_max_seconds":queueAgeMax,"automatic_asr_retries":retryCount,"speaker_ready":speakerReady,"speaker_processed_audio_seconds":Double(modelProcessedBytes)/32000]
        if includeSpeakerDiagnostics {
            let diagnostics=await speakerPipeline?.diagnosticSnapshot() ?? finalSpeakerDiagnostics
            result.merge(diagnostics){_,new in new}
        } else {
            result.merge(finalSpeakerDiagnostics){_,new in new}
        }
        return result
    }
    func pauseUploadsAndDrain() async {
        uploadPaused=true
        while inFlightAudioSends>0 { try? await Task.sleep(nanoseconds:5_000_000) }
    }
    func closeUploadGate() { uploadPaused=true }
    func resumeUploads() { uploadPaused=false }
    func send(_ frame: Data, captureAt: Double, sessionStart: Double) async throws {
        // Pause closes capture admission but permits upload of already saved
        // journal bytes. Only a hard stop or an explicit actor gate blocks ASR.
        while ((captureUploadPaused != 0 || uploadPaused) && interrupted == 0 && !stopped) { try await Task.sleep(nanoseconds:10_000_000) }
        guard interrupted < 2,captureUploadPaused==0,!uploadPaused else { throw Failure(code:"capture_interrupted") }
        guard !stopped && !closing else { throw Failure(code: "send_after_stop") }
        guard frame.count % 2 == 0, config.unlimitedSession==true || attemptedBytes + frame.count <= Int(config.maxSeconds * 32000) else { throw Failure(code: "audio_budget_limit") }
        guard sessionBudget?.reserve(frame.count) ?? true else {throw Failure(code:"audio_budget_limit")}
        if origin == nil { origin = max(0, captureAt - sessionStart) }
        attemptedBytes += frame.count;taskAttemptedBytes+=frame.count; inFlightBytes = frame.count; sendCalls += 1
        inFlightAudioSends += 1
        defer { inFlightAudioSends -= 1 }
        let before = ProcessInfo.processInfo.systemUptime;let age=max(0,before-captureAt);queueAgeTotal+=age;queueAgeMax=max(queueAgeMax,age)
        let socketStart=ProcessInfo.processInfo.systemUptime;defer {let d=ProcessInfo.processInfo.systemUptime-socketStart;socketWaitTotal+=d;socketWaitMax=max(socketWaitMax,d)}
        try await ws.send(.data(frame))
        let wait = ProcessInfo.processInfo.systemUptime - before
        sendWaitTotal += wait; sendWaitMax = max(sendWaitMax, wait)
        sentBytes += frame.count; inFlightBytes = 0
    }
    func ingestSpeakers(_ frame:Data,captureAt:Double,sessionStart:Double) async throws {
        guard !stopped,speakerReady,let pipeline=speakerPipeline else{throw Failure(code:"speaker_model_not_ready")}
        if modelOrigin==nil {modelOrigin=max(0,captureAt-sessionStart)}
        let began=ProcessInfo.processInfo.systemUptime;let updates=try await pipeline.ingest(frame,captureOrigin:modelOrigin!)
        let duration=ProcessInfo.processInfo.systemUptime-began;modelWaitTotal+=duration;modelWaitMax=max(modelWaitMax,duration);modelProcessedBytes+=frame.count
        for update in updates {publish(update)}
    }
    @discardableResult func publishPendingSpeakerFeatures() async->Int {
        guard let pipeline=speakerPipeline else{return 0}
        let updates=await pipeline.drainFeatureUpdates()
        for update in updates {publish(update)}
        return updates.count
    }
    func receive(sessionStart: Double) async throws {
        while !stopped {
            let object = try parse(await ws.receive())
            if stopped || Task.isCancelled {return}
            if let h = object["header"] as? [String: Any], h["event"] as? String == "task-failed" {
                throw Failure(code:asrProviderFailure(h,track:track))
            }
            if let usage=try providerUsage(object,task:task,track:track) {providerCounter=max(providerCounter,usage["duration"] as? Double ?? 0);emit(usage)}
            if let h=object["header"] as? [String:Any],h["event"] as? String=="task-finished" {
                finished=true;ready=false
                if !closing && !stopped {throw Failure(code:"asr_stream_finished:"+track)}
                return
            }
            if let start = origin, let event = try decoder.decode(object, task: task, track: track, session: config.session,
                    bundle: config.bundle, origin: start, received: receiptFloor+max(0,ProcessInfo.processInfo.systemUptime-(receiptClock ?? sessionStart))) {
                if let id=event["segment_id"] as? String {if event["final"] as? Bool==true {partialIDs.remove(id);if let end=event["end"] as? Double,let start=origin {finalCursor=max(finalCursor,replayBase+Int(max(0,end-start)*32000)/2*2)}}else{partialIDs.insert(id)}}
                if let pipeline=speakerPipeline {let t=ProcessInfo.processInfo.systemUptime;let annotated=await pipeline.accept(event);publish(annotated);if annotated["annotation_capacity_reached"] as? Bool==true {speakerPipeline=nil;speakerReady=false;_ = try? await pipeline.close(flush:false);emit(["type":"speaker_model","state":"failed","track":track,"reason":"speaker_context_capacity","asr_continues":true,"audio_retained":true])};let d=ProcessInfo.processInfo.systemUptime-t;annotationWaitTotal+=d;annotationWaitMax=max(annotationWaitMax,d)} else {publish(event)}
                if event["final"] as? Bool==true,let journal=journal {journal.commitAfterTranscript(min(finalCursor,journal.bytes()))}
            }
        }
    }
    func freezeAudio() {closing=true}
    func finishSentAudio() async {
        guard ready,!stopped,origin != nil else{return}
        closing=true
        do {
            try await ws.send(.string(command("finish-task")))
            while !finished && !stopped && !transportFailed {try await Task.sleep(nanoseconds:20_000_000)}
        } catch {}
    }
    func cancelTransport(){ws.cancel(with:.goingAway,reason:nil)}
    func stop() async {
        guard !stopped else{return};stopped = true
        // Close network first; a synchronous model inference cannot be preempted mid-call.
        ws.cancel(with: .normalClosure, reason: nil)
        if let pipeline=speakerPipeline {for event in (try? await pipeline.close(flush:true)) ?? [] {publish(event)};finalSpeakerDiagnostics=await pipeline.diagnosticSnapshot();speakerPipeline=nil}
        emit(["type": "usage_local", "track": track, "task_id": task, "sent_audio_seconds": Double(taskAttemptedBytes) / 32000,"total_attempted_audio_seconds":Double(attemptedBytes)/32000])
    }
    func parse(_ message: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        let data: Data
        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: throw Failure(code: "unknown_ws_message") }
        guard data.count <= 1048576, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure(code: "invalid_ws_json") }
        return value
    }
}

func asrProviderFailure(_ header:[String:Any],track:String)->String {
    let raw=header["error_code"] as? String ?? "unknown"
    let allowed=Set(["CLIENT_ERROR","SERVER_ERROR","REQUEST_TIMEOUT","IDLE_TIMEOUT","InvalidApiKey","InvalidParameter","AccessDenied","QuotaExceeded","NoAudioData","RequestTimeout","IdleTimeout","ModelNotFound","ResponseTimeout","401","403"])
    return "asr_task_failed:"+track+":"+(allowed.contains(raw) ? raw:"redacted")
}
func transientASRFailure(_ code:String)->Bool {
    if ["audio_budget_limit","send_after_stop","speaker_context_capacity"].contains(code){return false}
    return !["InvalidApiKey","InvalidParameter","AccessDenied","QuotaExceeded","ModelNotFound","401","403"].contains{code.hasSuffix(":"+$0)}
}
func runJournalASR(lane:Lane,box:Mailbox,store:RecordingJournal,track:String,origin:Double,onCacheFailure:(String)->Void,retryLimit:Int=16,retryDelay:Double=1,retryAfterLimit:Bool=false,slowRetryDelay:Double=30,stopReconnectOnCaptureStop:Bool=false,pauseTailReady:(sig_atomic_t) async -> Bool={_ in true}) async {
    guard await lane.claimJournalConsumer() else{emit(["type":"asr_consumer_active","track":track]);return}
    await runJournalASRLoop(lane:lane,box:box,store:store,track:track,origin:origin,onCacheFailure:onCacheFailure,retryLimit:retryLimit,retryDelay:retryDelay,retryAfterLimit:retryAfterLimit,slowRetryDelay:slowRetryDelay,stopReconnectOnCaptureStop:stopReconnectOnCaptureStop,pauseTailReady:pauseTailReady)
    await lane.releaseJournalConsumer()
}
func runJournalASRLoop(lane:Lane,box:Mailbox,store:RecordingJournal,track:String,origin:Double,onCacheFailure:(String)->Void,retryLimit:Int,retryDelay:Double,retryAfterLimit:Bool,slowRetryDelay:Double,stopReconnectOnCaptureStop:Bool,pauseTailReady:(sig_atomic_t) async -> Bool={_ in true}) async {
    var failures=0
    var reportedPauseRevision:sig_atomic_t = -1
    func mayRetry()->Bool {!Task.isCancelled && interrupted<2 && captureUploadPaused==0 && (!stopReconnectOnCaptureStop || interrupted==0 || captureTailDrainAllowed != 0)}
    func reportProcessingFailure(_ code:String) {
        emit(["type":"processing_failed","session":lane.config.session,"consumer":"asr",
              "track":track,"reason":code,"audio_retained":true,"retry_available":true])
        if capturePaused != 0 && captureUploadPaused==0 {
            let revision=captureControlRevision
            if capturePauseAcknowledgedRevision==revision && reportedPauseRevision != revision {
                emit(["type":"recording_pause_tail","session":lane.config.session,"track":track,
                      "pause_revision":revision,"state":"pending"])
                reportedPauseRevision=revision
            }
        }
    }
    func finishCurrentTask() async throws {
        if let code=store.processingFault() { throw Failure(code:code) }
        if await lane.isReady() {
            let finishWatch=Task {try? await Task.sleep(nanoseconds:12_000_000_000);if !Task.isCancelled {await lane.transportFailure()}}
            await lane.finishSentAudio();finishWatch.cancel()
        }
        if let code=store.processingFault() { throw Failure(code:code) }
        if let code=await lane.transportFailureCode(){throw Failure(code:code)}
        if await lane.didFinish() {
            try box.checkpoint("asr")
            // commit("asr") queues its durable checkpoint behind transcript
            // writes. A pause receipt must observe that checkpoint, otherwise
            // it can report pending once and then sleep until resume forever.
            await waitForSourceJournal(store)
        }
        if let code=store.processingFault() { throw Failure(code:code) }
    }
    func closeSocket(_ receiver:Task<Void,Never>?) async {
        if let receiver {receiver.cancel();await lane.cancelTransport();await receiver.value}
        else {await lane.cancelTransport()}
    }
    func awaitPauseAcknowledgement(_ revision:sig_atomic_t) async -> Bool {
        while capturePaused != 0 && captureControlRevision==revision && capturePauseAcknowledgedRevision != revision && interrupted<2 && !Task.isCancelled {
            try? await Task.sleep(nanoseconds:5_000_000)
        }
        return capturePaused != 0 && captureControlRevision==revision && capturePauseAcknowledgedRevision==revision
    }
    // Admission is already closed when the matching pause ACK is published.
    // Let the serialized journal writer finish those accepted packets before
    // deciding that this track's tail is complete. Poll asynchronously so a
    // slow filesystem cannot block capture-control handling or defeat cancel.
    func waitForJournalWrites(_ revision:sig_atomic_t) async -> Bool {
        while (store.metadata()["pending_writer_bytes"] as? Int ?? 0)>0 {
            if Task.isCancelled || interrupted>=2 || captureUploadPaused != 0 || capturePaused==0 || captureControlRevision != revision {return false}
            try? await Task.sleep(nanoseconds:5_000_000)
        }
        return !Task.isCancelled && interrupted<2 && captureUploadPaused==0 && capturePaused != 0 && captureControlRevision==revision
    }
    if let code=store.processingFault() {reportProcessingFailure(code);return}
    while !Task.isCancelled && interrupted<2 && captureUploadPaused==0 {
        if let code=store.processingFault() {reportProcessingFailure(code);return}
        var receiver:Task<Void,Never>?
        do {
            while !box.hasFrames() && !box.isSealed() && interrupted<2 && capturePaused==0 && captureFinishing==0 {
                if let code=store.processingFault() {reportProcessingFailure(code);return}
                try await Task.sleep(nanoseconds:5_000_000)
            }
            if interrupted>=2 || Task.isCancelled {return}
            if !box.hasFrames() && !box.isSealed() && capturePaused != 0 && captureUploadPaused==0 {
                let pauseRevision=captureControlRevision
                guard await awaitPauseAcknowledgement(pauseRevision),await pauseTailReady(pauseRevision),
                      await waitForJournalWrites(pauseRevision) else {
                    if interrupted>=2 || Task.isCancelled {return}
                    if capturePaused==0 || captureControlRevision != pauseRevision {continue}
                    throw Failure(code:"pause_tail_not_ready")
                }
                if box.hasFrames() {continue}
                try await finishCurrentTask()
                await closeSocket(nil)
                if capturePaused != 0 && captureControlRevision != pauseRevision {
                    // The completed provider task is closed. If a new pause
                    // superseded this one during finish, rewind and create a
                    // fresh task before the next loop can send its backlog.
                    let cursor=min(store.committed("asr"),store.bytes())
                    do {try box.rewind(cursor)}catch{onCacheFailure("cache_cursor_invalid");return}
                    await lane.reconnect(at:cursor)
                    continue
                }
                if capturePaused != 0 && captureControlRevision==pauseRevision && reportedPauseRevision != pauseRevision {
                    // A paused track is not ended yet, so use its durable
                    // checkpoint and processing status; capture-gap warnings
                    // remain independent from transcription of saved bytes.
                    let complete=store.committed("asr")>=store.bytes() && store.processingFault()==nil
                    emit(["type":"recording_pause_tail","session":lane.config.session,"track":track,"pause_revision":pauseRevision,"state":complete ? "complete":"pending"])
                    reportedPauseRevision=pauseRevision
                }
                while capturePaused != 0 && captureControlRevision==pauseRevision && interrupted==0 && !Task.isCancelled {try? await Task.sleep(nanoseconds:10_000_000)}
                guard interrupted<2,captureUploadPaused==0,!Task.isCancelled else{return}
                let cursor=min(store.committed("asr"),store.bytes())
                do {try box.rewind(cursor)}catch{onCacheFailure("cache_cursor_invalid");return}
                await lane.reconnect(at:cursor)
                continue
            }
            if !box.hasFrames() && captureFinishing != 0 {
                // A producer may still be flushing already-admitted data (or,
                // for the source-capture mic, finishing its derived clean
                // track). Do not finish an empty provider task until the
                // producer has sealed and all serialized journal writes land.
                while !box.isSealed() && captureFinishing != 0 && interrupted<2 && !Task.isCancelled {
                    try await Task.sleep(nanoseconds:5_000_000)
                }
                if interrupted>=2 || captureUploadPaused != 0 || Task.isCancelled {return}
                if box.hasFrames() {continue}
                store.wait()
                if box.hasFrames() {continue}
                try await finishCurrentTask()
                await closeSocket(nil)
                return
            }
            guard box.hasFrames(),interrupted<2 else{return}
            let handshakeWatch=Task {try? await Task.sleep(nanoseconds:12_000_000_000);if !Task.isCancelled {await lane.cancelTransport()}}
            do {try await lane.start()}catch{handshakeWatch.cancel();throw error};handshakeWatch.cancel()
            var catchingUp=(store.bytes()-box.readCursor)>3200
            emit(["type":catchingUp ? "asr_catching_up":"asr_resumed","track":track,"backlog_audio_seconds":Double(max(0,store.bytes()-box.readCursor))/32000])
            receiver=Task {do {try await lane.receive(sessionStart:origin)}catch{await lane.transportFailure((error as? Failure)?.code ?? "asr_transport_error")}}
            while !Task.isCancelled && interrupted<2 && captureUploadPaused==0 {
                if let code=store.processingFault() {
                    reportProcessingFailure(code)
                    await closeSocket(receiver)
                    return
                }
                if let code=await lane.transportFailureCode(){throw Failure(code:code)}
                if let (packet,stamp)=try box.takePacket(now:ProcessInfo.processInfo.systemUptime,flush:box.isSealed() || capturePaused != 0 || captureFinishing != 0) {
                    try await lane.send(packet,captureAt:stamp,sessionStart:origin)
                    if catchingUp && store.bytes()-box.readCursor<=3200 {catchingUp=false;emit(["type":"asr_resumed","track":track])}
                }else if box.isSealed() || capturePaused != 0 {break}else{try await Task.sleep(nanoseconds:5_000_000)}
            }
            if captureUploadPaused != 0 {await closeSocket(receiver);return}
            if box.isSealed() {
                try await finishCurrentTask()
                let laneReady=await lane.isReady()
                guard await lane.didFinish() || !laneReady else{throw Failure(code:"asr_tail_unconfirmed")}
                await closeSocket(receiver);return
            } else if capturePaused != 0 && captureUploadPaused==0 {
                let pauseRevision=captureControlRevision
                guard await awaitPauseAcknowledgement(pauseRevision),await pauseTailReady(pauseRevision),
                      await waitForJournalWrites(pauseRevision) else {
                    if interrupted>=2 || Task.isCancelled {await closeSocket(receiver);return}
                    if capturePaused==0 || captureControlRevision != pauseRevision {
                        // The pause was superseded while this provider socket
                        // still had a live receive task. Retire it before
                        // leaving this iteration, then replay from the last
                        // provider-confirmed cursor on a fresh task.
                        await closeSocket(receiver)
                        let cursor=min(await lane.confirmedCursor(),store.bytes())
                        do {try box.rewind(cursor)}catch{onCacheFailure("cache_cursor_invalid");return}
                        await lane.reconnect(at:cursor)
                        continue
                    }
                    throw Failure(code:"pause_tail_not_ready")
                }
                if box.hasFrames() {
                    try await finishCurrentTask()
                    await closeSocket(receiver)
                    let cursor=min(store.committed("asr"),store.bytes())
                    do {try box.rewind(cursor)}catch{onCacheFailure("cache_cursor_invalid");return}
                    await lane.reconnect(at:cursor)
                    continue
                }
                try await finishCurrentTask()
                guard await lane.didFinish() || store.committed("asr")>=box.readCursor else{throw Failure(code:"asr_tail_unconfirmed")}
                await closeSocket(receiver)
                if capturePaused != 0 && captureControlRevision != pauseRevision {
                    // `finish-task` leaves Lane.closing set. A quick resume
                    // followed by another pause must reopen it from the last
                    // durable ASR cursor before the next iteration sends.
                    let cursor=min(store.committed("asr"),store.bytes())
                    do {try box.rewind(cursor)}catch{onCacheFailure("cache_cursor_invalid");return}
                    await lane.reconnect(at:cursor)
                    continue
                }
                if capturePaused != 0 && captureControlRevision==pauseRevision && reportedPauseRevision != pauseRevision {
                    let complete=store.committed("asr")>=store.bytes() && store.processingFault()==nil
                    emit(["type":"recording_pause_tail","session":lane.config.session,"track":track,"pause_revision":pauseRevision,"state":complete ? "complete":"pending"])
                    reportedPauseRevision=pauseRevision
                }
                while capturePaused != 0 && captureControlRevision==pauseRevision && interrupted==0 && !Task.isCancelled {try? await Task.sleep(nanoseconds:10_000_000)}
                guard interrupted<2,captureUploadPaused==0,!Task.isCancelled else{return}
                let cursor=min(store.committed("asr"),store.bytes())
                do {try box.rewind(cursor)}catch{onCacheFailure("cache_cursor_invalid");return}
                await lane.reconnect(at:cursor)
                continue
            }
            if let receiver=receiver {receiver.cancel();await lane.cancelTransport();await receiver.value};return
        }catch{
            await closeSocket(receiver)
            if let processingError=store.processingFault() {
                reportProcessingFailure(processingError)
                return
            }
            failures+=1
            let code=(error as? Failure)?.code ?? "asr_transport_error"
            guard transientASRFailure(code),mayRetry(),retryAfterLimit || failures<=retryLimit else {
                emit(["type":"asr_pending","track":track,"reason":code,"audio_retained":true,"automatic_retry":false])
                if capturePaused != 0 && captureUploadPaused==0 {
                    let pauseRevision=captureControlRevision
                    let acknowledged=await awaitPauseAcknowledgement(pauseRevision)
                    let sourceReady=acknowledged ? await pauseTailReady(pauseRevision):false
                    if acknowledged && sourceReady && capturePaused != 0 && captureControlRevision==pauseRevision && reportedPauseRevision != pauseRevision {
                        emit(["type":"recording_pause_tail","session":lane.config.session,"track":track,"pause_revision":pauseRevision,"state":"pending"])
                        reportedPauseRevision=pauseRevision
                    }
                    while capturePaused != 0 && captureControlRevision==pauseRevision && interrupted==0 && !Task.isCancelled {try? await Task.sleep(nanoseconds:10_000_000)}
                    guard interrupted<2,captureUploadPaused==0,!Task.isCancelled else{return}
                    let cursor=min(await lane.confirmedCursor(),store.bytes())
                    do {try box.rewind(cursor)}catch{onCacheFailure("cache_cursor_invalid");return}
                    await lane.reconnect(at:cursor);continue
                }
                return
            }
            let cursor=min(await lane.confirmedCursor(),store.bytes())
            do {try store.commit("asr",cursor:cursor);try box.rewind(cursor)}catch{onCacheFailure("cache_cursor_invalid");return}
            let delay=failures>retryLimit ? slowRetryDelay:Double(min(failures,10))*retryDelay
            emit(["type":"asr_reconnecting","track":track,"attempt":failures,"audio_retained":true,"automatic_retry":true,"next_retry_seconds":delay])
            let until=ProcessInfo.processInfo.systemUptime+max(0,delay)
            while mayRetry() && ProcessInfo.processInfo.systemUptime<until {try? await Task.sleep(nanoseconds:UInt64(min(0.1,max(0,until-ProcessInfo.processInfo.systemUptime))*1e9))}
            guard mayRetry() else{emit(["type":"asr_pending","track":track,"reason":"user_stopped","audio_retained":true,"automatic_retry":false]);return}
            await lane.reconnect(at:cursor)
        }
    }
}
// Offline fault injection into the same Lane and reconnect loop; no socket, key,
// device, ASR service or human recording. Words below are synthetic placeholders.
final class FixtureSocket:ASRSocket {
    private let lock=NSLock();private var messages:[URLSessionWebSocketTask.Message]=[];private var canceled=false;private var task="";private var bytes=0;private var sentence=0
    let shouldFail:Bool;let offline:Bool;let delay:UInt64;var failed=false
    init(fail:Bool,offline:Bool=false,delay:UInt64=1_000_000){shouldFail=fail;self.offline=offline;self.delay=delay}
    func isCanceled()->Bool {lock.lock();defer{lock.unlock()};return canceled}
    func sentBytes()->Int {lock.lock();defer{lock.unlock()};return bytes}
    func resume(){}
    func cancel(with:URLSessionWebSocketTask.CloseCode,reason:Data?){lock.lock();canceled=true;lock.unlock()}
    private func push(_ value:[String:Any])throws {let data=try JSONSerialization.data(withJSONObject:value);lock.lock();messages.append(.data(data));lock.unlock()}
    func send(_ message:URLSessionWebSocketTask.Message) async throws {
        if offline {throw Failure(code:"fixture_offline")}
        switch message {
        case .string(let text):
            let object=try JSONSerialization.jsonObject(with:Data(text.utf8)) as! [String:Any];let h=object["header"] as! [String:Any]
            if h["action"] as? String=="run-task" {task=h["task_id"] as! String;try push(["header":["task_id":task,"event":"task-started"]])}
            else {let total=sentBytes();if total%32000 != 0 {sentence+=1;try result(final:true,start:max(0,total-total%32000),end:total)};try push(["header":["task_id":task,"event":"task-finished"]])}
        case .data(let data):
            if shouldFail && sentBytes()>=48000 {failed=true;throw Failure(code:"fixture_disconnect")}
            try await Task.sleep(nanoseconds:delay)
            lock.lock();let old=bytes;bytes+=data.count;let total=bytes;lock.unlock()
            if total/32000>old/32000 {sentence+=1;try result(final:true,start:(total/32000-1)*32000,end:total/32000*32000)}
            else {try result(final:false,start:total/32000*32000,end:total)}
        @unknown default:throw Failure(code:"fixture_message")
        }
    }
    private func result(final:Bool,start:Int,end:Int)throws {try push(["header":["task_id":task,"event":"result-generated"],"payload":["output":["sentence":["sentence_id":final ? sentence:sentence+1,"begin_time":Double(start)/32,"end_time":Double(end)/32,"sentence_end":final,"text":"离线协议占位文本"]]]])}
    func receive() async throws->URLSessionWebSocketTask.Message {
        while true {lock.lock();let stopped=canceled;let message=messages.isEmpty ? nil:messages.removeFirst();lock.unlock();if let message=message{return message};if stopped || Task.isCancelled {throw Failure(code:"fixture_canceled")};try await Task.sleep(nanoseconds:1_000_000)}
    }
}
func journalTransportFixture(root:URL,fixture:URL) async throws->[String:Any] {
    let raw=try Data(contentsOf:fixture.appendingPathComponent("input.pcm"));let input=Data(raw.prefix(5*32000));guard input.count==5*32000 else{throw Failure(code:"fixture_pcm")}
    let folder=root.appendingPathComponent(UUID().uuidString);let store=try RecordingJournal(directory:folder,track:"mic",freeSpace:{1_000_000_000});let box=Mailbox(journal:store)
    let start=ProcessInfo.processInfo.systemUptime
    for offset in stride(from:0,to:input.count,by:3200){box.put(Data(input[offset..<offset+3200]),at:start+Double(offset)/32000)}
    box.seal();store.wait()
    var sockets:[FixtureSocket]=[]
    let factory:()->ASRSocket={let socket=FixtureSocket(fail:sockets.isEmpty);sockets.append(socket);return socket}
    let config=Config(session:"offline-protocol",bundle:"*microphone*",key:"",confirmed:true,maxSeconds:10,model:"qwen-audio-3.0-asr-flash-streaming",silenceMS:1300,micEnabled:true,localSpeakerDirectory:nil,localEmbeddingModel:nil,userLaunchConfirmed:nil)
    let lane=Lane(track:"mic",config:config,socketFactory:factory);await lane.attachJournal(store)
    await runJournalASR(lane:lane,box:box,store:store,track:"mic",origin:start,onCacheFailure:{_ in preconditionFailure()})
    await lane.stop();store.wait();let metrics=await lane.metrics()
    precondition(sockets.count==2 && sockets.first!.failed && store.committed("asr")==input.count)
    precondition(metrics["automatic_asr_retries"] as? Int==1 && (metrics["attempted_audio_seconds"] as! Double)>5 && (metrics["attempted_audio_seconds"] as! Double)<=10)
    let recovered=try RecordingJournal(directory:folder,track:"mic",freeSpace:{1_000_000_000});precondition(recovered.bytes()==input.count && recovered.committed("asr")==input.count)
    let log=try String(contentsOf:folder.appendingPathComponent("mic-transcript.jsonl"),encoding:.utf8);precondition(log.contains("asr_replay") && log.contains("discard_segment_ids"))
    let events=try log.split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
    let finals=events.filter{$0["type"] as? String=="segment" && $0["final"] as? Bool==true}
    precondition(finals.count==5 && Set(finals.compactMap{$0["segment_id"] as? String}).count==5)
    try recovered.markArchived();precondition(recovered.eligibleForCleanup())
    try archiveAndCleanSessionAt(folder,text:"离线虚构全文归档",retire:{try retireFixtureAudio($0,base:root,id:folder.lastPathComponent)})
    let clean=try RecordingJournal(directory:folder,track:"mic");precondition(clean.bytes()==input.count && !clean.eligibleForCleanup())
    let remaining=try FileManager.default.contentsOfDirectory(atPath:folder.path);precondition(!remaining.contains{$0.hasSuffix(".pcm")})
    return ["type":"journal_transport_fixture","passed":6,"network":false,"capture":false,"cloud_asr":false,"protocol_mock":true,"same_production_lane_and_retry_loop":true,"recovery_verified":true,"tail_confirmed":true,"metrics":metrics]
}
func resumeCachedMeeting(config:Config,id:String,base:URL=meetingCacheRoot(),factory:(()->ASRSocket)?=nil,retryLimit:Int=16,retryDelay:Double=1) async throws {
    guard UUID(uuidString:id) != nil else{throw Failure(code:"cache_scope_invalid")}
    let directory=base.appendingPathComponent(id,isDirectory:true)
    let writerLease=try await SessionCacheWriterLease.acquireForRecovery(directory:directory)
    defer {writerLease.release()}
    guard let meeting=try cachedMeetings(in:base,recoverInterrupted:false).first(where:{$0.id==id}),!meeting.audioCleaned else{throw Failure(code:"cache_scope_invalid")}
    let old=try meeting.events();let metadata=try meeting.metadata();let session=metadata["session"] as? String ?? old.first?["session"] as? String ?? id
    guard session==config.session else{throw Failure(code:"cache_session_mismatch")}
    var approved=metadata,metadataChanged=false
    if metadata["capture_mode"] as? String=="local_only",metadata["upload_authorized"] as? Bool != true {
        guard config.resumeUploadConfirmed==true else{throw Failure(code:"local_audio_upload_not_confirmed")}
        approved["upload_authorized"]=true;approved["asr_destination"]="dashscope.aliyuncs.com";approved["upload_confirmed_at"]=Date().timeIntervalSince1970;if config.cloudSessionConfirmed==true {approved["cloud_session_authorized"]=true;approved["unlimited_session"]=config.unlimitedSession==true;if config.unlimitedSession != true {approved["cloud_audio_ceiling_seconds"]=14400;approved["cloud_budget_yuan"]=5}};metadataChanged=true
    }
    if metadataChanged {try JSONSerialization.data(withJSONObject:approved,options:[.sortedKeys]).write(to:meeting.directory.appendingPathComponent("meeting.json"),options:.atomic)}
    var stores:[String:RecordingJournal]=[:];var lanes:[String:Lane]=[:];var jobs:[()->Task<Void,Never>]=[]
    for track in meeting.tracks {stores[track]=try RecordingJournal(directory:meeting.directory,track:track)}
    let origin=(metadata["capture_origin_uptime"] as? Double).flatMap{$0.isFinite ? $0:nil} ?? stores.values.compactMap{$0.firstOrigin()}.min() ?? ProcessInfo.processInfo.systemUptime
    let uploadBudget:SessionUploadBudget?=config.unlimitedSession==true ? nil:SessionUploadBudget(maxSeconds:config.remainingUploadSeconds ?? config.maxSeconds*Double(meeting.tracks.count))
    let pendingTracks=meeting.tracks.filter{stores[$0]!.committed("asr")<stores[$0]!.bytes()}
    signal(SIGINT,interruptHandler);signal(SIGTERM,interruptHandler);interrupted=1
    let launcher=getppid()
    var resumedEvent:[String:Any]=["type":"started","audio_frames_received":false,"session":session,"cache_id":id,"capture":false,"resume":true,"model":config.model,"audio_storage":"local_segmented_recoverable"];resumedEvent["absolute_clock"]=metadata["absolute_clock"];emit(resumedEvent)
    emit(["type":"processing_started","session":session,"recording_elapsed_seconds":0,"capture":false,"deadline_seconds":180])
    for track in pendingTracks {
        let store=stores[track]!;let historical=old.filter{$0["track"] as? String==track}
        let epoch=historical.compactMap{($0["speaker"] as? [String:Any])?["epoch"] as? String}.first ?? id+":"+track
        let attrs=(metadata["audio_sources"] as? [[String:Any]])?.first{$0["source_id"] as? String==track} ?? [:]
        let lane=Lane(track:track,config:config,preparedEpoch:epoch,socketFactory:factory,metadata:attrs,budget:uploadBudget);await lane.attachJournal(store);await lane.configureReceiptClock(floor:max(Double(store.bytes())/32000,historical.compactMap{$0["received_at"] as? Double}.max() ?? 0));lanes[track]=lane
        let asr=Mailbox(journal:store,producer:false);let model=Mailbox(journal:store,producer:false);try asr.rewind(store.committed("asr"));await lane.beginAt(store.committed("asr"));await lane.discardRecoveredPartials(historical)
        jobs.append {Task {
        async let asrWork:Void=runJournalASR(lane:lane,box:asr,store:store,track:track,origin:origin,onCacheFailure:{code in emit(["type":"error","code":code])},retryLimit:retryLimit,retryDelay:retryDelay)
        async let modelWork:Void={ () async -> Void in do {if config.localSpeakerDirectory != nil && store.committed("model")<store.bytes() {try await lane.prepareSpeakers();await lane.seed(historical);while interrupted<2 {if let (packet,stamp)=try model.takePacket(now:ProcessInfo.processInfo.systemUptime,flush:true){try await lane.ingestSpeakers(packet,captureAt:stamp,sessionStart:origin);try model.checkpoint("model")}else{break}}}}catch{emit(["type":"speaker_model","state":"failed","track":track,"audio_retained":true])};await lane.finishSpeakerInput()}()
        _ = await (asrWork,modelWork)
        await lane.stop()
        }}
    }
    let watch=Task {try? await Task.sleep(nanoseconds:180_000_000_000);if !Task.isCancelled {interrupted=2;for lane in lanes.values {await lane.cancelTransport()}}}
    let health=Task {while !Task.isCancelled && interrupted<2 {if getppid() != launcher {interrupted=2;for lane in lanes.values {await lane.cancelTransport()};break};var event:[String:Any]=["type":"health","session":session,"elapsed_seconds":0];for track in pendingTracks {event[track]=await lanes[track]!.metrics()};emit(event);try? await Task.sleep(nanoseconds:1_000_000_000)}}
    for batchStart in stride(from:0,to:jobs.count,by:2) {let active=jobs[batchStart..<min(jobs.count,batchStart+2)].map{$0()};for task in active {await task.value};if interrupted>=2 {break}}
    watch.cancel();health.cancel();await health.value
    for lane in lanes.values {await lane.stop()};for store in stores.values {store.wait()}
    var final:[String:Any]=["type":"health","session":session,"elapsed_seconds":0];for track in pendingTracks {final[track]=await lanes[track]!.metrics()};emit(final)
    let complete=stores.values.allSatisfy{$0.transcriptionIsComplete()}
    emit(["type":"stopped","session":session,"reason":interrupted>=2 ? "processing_cancelled":"user_stop","recording_elapsed_seconds":0,"received_at":0,"transcription_complete":complete,"raw_audio_saved":true,"capture":false])
}

var interrupted: sig_atomic_t = 0
var capturePaused: sig_atomic_t = 0
// Upload stays open while paused so already-recorded journal data can drain.
// This separate gate is closed only by a hard stop/cancel.
var captureUploadPaused: sig_atomic_t = 0
var captureControlRevision: sig_atomic_t = 0
var capturePauseAcknowledgedRevision: sig_atomic_t = -1
var captureHardwareReady: sig_atomic_t = 1
var captureFinishing: sig_atomic_t = 0
var captureTailDrainAllowed: sig_atomic_t = 0
@inline(__always) func captureAdmissionOpen() -> Bool { capturePaused == 0 && captureFinishing == 0 && interrupted == 0 && captureHardwareReady != 0 }
@discardableResult func writeCapturedPCMIfAdmitted(_ pcm:Data,at timestamp:Double,to mailbox:Mailbox)->Bool {
    guard captureAdmissionOpen() else{return false};mailbox.put(pcm,at:timestamp);return true
}
func recordingPauseHandler(_ value:Int32) {
    // A stale control signal can arrive after finish/cancel was already
    // observed. Terminal controls own the gates; do not resurrect a pause
    // revision whose capture loop and ACK worker are shutting down.
    guard captureFinishing==0 && interrupted==0 else{return}
    // A device-change pause and the user's SIGUSR1 can name the same closed
    // boundary. Do not orphan its teardown/echo/ASR barriers with a new revision.
    if value==SIGUSR1 && capturePaused != 0 {captureHardwareReady=0;return}
    capturePaused = value==SIGUSR1 ? 1:0
    if value==SIGUSR1 { captureHardwareReady=0 }
    captureControlRevision &+= 1
}
func recordingFinishHandler(_ signal:Int32) {
    guard captureFinishing==0 && interrupted==0 else{return}
    captureFinishing=1
    captureHardwareReady=0
    capturePaused=0
    captureUploadPaused=0
    captureTailDrainAllowed=1
    captureControlRevision &+= 1
}
func interruptHandler(_ signal: Int32) {
    captureHardwareReady=0;captureUploadPaused=1
    captureFinishing=0;captureTailDrainAllowed=0
    interrupted = min(2,interrupted+1)
}

// A signal requests a state and increments the revision even when it repeats
// the current state. Only the capture loop acknowledges the observed result.
struct CaptureControlAcknowledgement {
    private(set) var revision: sig_atomic_t = 0
    mutating func accept(requestRevision: sig_atomic_t, requestedPaused: Bool,
                         actualPaused: Bool) -> Bool {
        guard requestRevision != revision, requestedPaused == actualPaused else { return false }
        revision = requestRevision
        return true
    }
}
@main struct Main {
    static func main() async {
        do {
            let args = CommandLine.arguments
            if args.count==2,args[1]=="--runtime-configuration-self-test",Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true {
                let checks=try runtimeConfigurationChecks()
                print(String(data:try JSONSerialization.data(withJSONObject:["type":"runtime_helper","checks":checks,"passed":checks.count,"edition":RuntimeConfiguration.edition(),"data_root":RuntimeConfiguration.dataRoot().path,"capture":false,"cloud":false,"keychain":false],options:.sortedKeys),encoding:.utf8)!)
                return
            }
            if args.count==3,args[1]=="--recover-session-cache" {
                guard UUID(uuidString:args[2]) != nil,
                      Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool != true,
                      Bundle.main.object(forInfoDictionaryKey:"LocalRecordingAllowed") as? Bool==true else{throw Failure(code:"cache_recovery_scope_invalid")}
                let result=try recoverInterruptedSessionCache(at:meetingCacheRoot().appendingPathComponent(args[2],isDirectory:true))
                print(String(data:try JSONSerialization.data(withJSONObject:result.json,options:[.sortedKeys]),encoding:.utf8)!);return
            }
            if args.count==4,args[1]=="--recover-session-cache-fixture" {
                guard Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true,
                      let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,
                      UUID(uuidString:args[2]) != nil else{throw Failure(code:"offline_fixture_scope_invalid")}
                let runtime=URL(fileURLWithPath:root).appendingPathComponent(".runtime",isDirectory:true).resolvingSymlinksInPath()
                let base=URL(fileURLWithPath:args[3],isDirectory:true).standardizedFileURL.resolvingSymlinksInPath()
                guard (base.path==runtime.path || base.path.hasPrefix(runtime.path+"/")),FileManager.default.fileExists(atPath:base.path) else{throw Failure(code:"offline_fixture_scope_invalid")}
                let result=try recoverInterruptedSessionCache(at:base.appendingPathComponent(args[2],isDirectory:true))
                print(String(data:try JSONSerialization.data(withJSONObject:result.json,options:[.sortedKeys]),encoding:.utf8)!);return
            }
            if args.count==3,args[1]=="--refine-meeting-speakers" {
                let input=FileHandle.standardInput.readData(ofLength:65537)
                guard !input.isEmpty,input.count<=65536 else{throw Failure(code:"refinement_request_too_large")}
                let request=try JSONDecoder().decode(SpeakerRefinementRequest.self,from:input)
                let result=try await SpeakerRefinement.run(request:request,models:URL(fileURLWithPath:args[2]))
                let data=try JSONSerialization.data(withJSONObject:result,options:.sortedKeys)
                guard data.count<=2*1024*1024 else{throw Failure(code:"refinement_result_too_large")}
                print(String(decoding:data,as:UTF8.self));return
            }
            if args.count==3,args[1]=="--automatic-acoustic-refinement" {
                let input=FileHandle.standardInput.readData(ofLength:65537)
                guard !input.isEmpty,input.count<=65536 else{throw Failure(code:"acoustic_request_too_large")}
                let request=try JSONDecoder().decode(SpeakerRefinementRequest.self,from:input)
                do {
                    let result=try MeetingAcousticRefinement.run(request:request,modelURL:URL(fileURLWithPath:args[2]))
                    print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!);return
                } catch let error as SpeakerRefinementArtifactError {throw Failure(code:"acoustic_"+String(describing:error).lowercased())}
            }
            if args.count==3,args[1]=="--saved-voice-recognition" {
                let input=FileHandle.standardInput.readData(ofLength:65537)
                guard !input.isEmpty,input.count<=65536 else{throw Failure(code:"saved_voice_request_too_large")}
                let request=try JSONDecoder().decode(SavedVoiceRecognitionRequest.self,from:input)
                let result=try SavedVoiceRecognition.run(request,model:URL(fileURLWithPath:args[2]))
                print(String(data:try JSONEncoder().encode(result),encoding:.utf8)!);return
            }
            var prepared: [String: SpeakerPipeline] = [:]
            var preparedEpochs: [String: String] = [:]
            var preparedDirectory: String?; var preparedEmbedding: String?
            if args.count==4,args[1]=="--qa-recovery-fixture" {
                guard Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true,Bundle.main.object(forInfoDictionaryKey:"OfflineQA") as? Bool==true,UUID(uuidString:args[2]) != nil,["normal","offline","disconnect","limited","slow"].contains(args[3]) else{throw Failure(code:"offline_fixture_scope_invalid")}
                let base=offlineQACacheRoot();guard let meeting=try cachedMeetings(in:base).first(where:{$0.id==args[2]}) else{throw Failure(code:"fixture_missing")};let metadata=try meeting.metadata()
                guard metadata["fixture"] as? Bool==true,metadata["audio_is_synthetic_silence"] as? Bool==true,meeting.tracks==["mic"],meeting.writtenBytes==160000,let session=metadata["session"] as? String,session=="qa-"+meeting.id else{throw Failure(code:"offline_fixture_scope_invalid")}
                let store=try RecordingJournal(directory:meeting.directory,track:"mic");var cursor=0
                while let (packet,_)=try store.read(cursor){guard packet.allSatisfy({$0==0}) else{throw Failure(code:"offline_fixture_scope_invalid")};cursor+=packet.count}
                let config=Config(session:session,bundle:"*microphone*",key:"",confirmed:true,maxSeconds:args[3]=="limited" ? 1:10,model:"qwen-audio-3.0-asr-flash-streaming",silenceMS:1300,micEnabled:true,localSpeakerDirectory:nil,localEmbeddingModel:nil,userLaunchConfirmed:nil)
                var sockets=0;let factory:()->ASRSocket={let first=sockets==0;sockets+=1;return FixtureSocket(fail:args[3]=="disconnect" && first,offline:args[3]=="offline",delay:args[3]=="slow" ? 50_000_000:1_000_000)}
                try await resumeCachedMeeting(config:config,id:args[2],base:base,factory:factory,retryLimit:2,retryDelay:0.01);return
            }
            if args.count==4,args[1]=="--recovery-fixture" {
                guard let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true || Bundle.main.object(forInfoDictionaryKey:"TrialCandidate") as? Bool==true,UUID(uuidString:args[2]) != nil,["normal","offline","disconnect","limited","slow"].contains(args[3]) else{throw Failure(code:"offline_fixture_scope_invalid")}
                let base=URL(fileURLWithPath:root+"/native/validation-workflow/recovery-ui-fixtures");guard let meeting=try cachedMeetings(in:base).first(where:{$0.id==args[2]}) else{throw Failure(code:"fixture_missing")};let metadata=try meeting.metadata()
                let config=Config(session:metadata["session"] as! String,bundle:"*microphone*",key:"",confirmed:true,maxSeconds:args[3]=="limited" ? 1:10,model:"qwen-audio-3.0-asr-flash-streaming",silenceMS:1300,micEnabled:true,localSpeakerDirectory:nil,localEmbeddingModel:nil,userLaunchConfirmed:nil)
                var sockets=0;let factory:()->ASRSocket={let first=sockets==0;sockets+=1;return FixtureSocket(fail:args[3]=="disconnect" && first,offline:args[3]=="offline",delay:args[3]=="slow" ? 50_000_000:1_000_000)}
                try await resumeCachedMeeting(config:config,id:args[2],base:base,factory:factory,retryLimit:2,retryDelay:0.01);return
            }
            if args.count==2,args[1]=="--public-cloud-probe" {
                guard Bundle.main.object(forInfoDictionaryKey:"PublicAudioASRTestAllowed") as? Bool==true,let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,let line=readLine() else{throw Failure(code:"public_trial_not_authorized")}
                let config=try JSONDecoder().decode(Config.self,from:Data(line.utf8));emit(try await publicAudioTrial(config:config,root:URL(fileURLWithPath:root)));return
            }
            if args.count==3,args[1]=="--network-recovery-self-test" {
                guard Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true else{throw Failure(code:"offline_fixture_scope_invalid")}
                emit(try await networkRecoveryFixture(base:URL(fileURLWithPath:args[2])));return
            }
            if args.count==3,args[1]=="--local-recording-self-test" {
                guard let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,URL(fileURLWithPath:args[2]).standardizedFileURL.path==URL(fileURLWithPath:root+"/.runtime/local-recording-fixtures").standardizedFileURL.path else{throw Failure(code:"offline_fixture_scope_invalid")}
                emit(try await localRecordingFixture(base:URL(fileURLWithPath:args[2])));return
            }
            if args.count==3,args[1]=="--journal-self-test" {
                guard let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true || Bundle.main.object(forInfoDictionaryKey:"TrialCandidate") as? Bool==true,URL(fileURLWithPath:args[2]).standardizedFileURL.path==URL(fileURLWithPath:root+"/native/validation-workflow/journal-fixtures").standardizedFileURL.path else{throw Failure(code:"offline_fixture_scope_invalid")}
                emit(try await journalTransportFixture(root:URL(fileURLWithPath:args[2]),fixture:URL(fileURLWithPath:root+"/native/validation-workflow/public-mic-fixture")));return
            }
            if args.count==5,args[1]=="--buffer-probe",let delay=Double(args[4]) {
                guard Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true || Bundle.main.object(forInfoDictionaryKey:"TrialCandidate") as? Bool==true else{throw Failure(code:"offline_fixture_scope_invalid")}
                guard let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,URL(fileURLWithPath:args[2]).standardizedFileURL.path==URL(fileURLWithPath:root+"/native/local-speaker-install/runtime-models").standardizedFileURL.path,["public-mic-fixture","public-overlap-fixture"].map({URL(fileURLWithPath:root+"/native/validation-workflow/"+$0).standardizedFileURL.path}).contains(URL(fileURLWithPath:args[3]).standardizedFileURL.path) else{throw Failure(code:"offline_fixture_scope_invalid")}
                emit(try await bufferedCaptureFixture(directory:URL(fileURLWithPath:args[2]),fixture:URL(fileURLWithPath:args[3]),delay:delay));return
            }
            if args.count==4,args[1]=="--speech-probe" {
                let isOffline=Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true
                if !isOffline {
                    guard Bundle.main.object(forInfoDictionaryKey:"TrialCandidate") as? Bool==true,let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String else{throw Failure(code:"offline_fixture_scope_invalid")}
                    let model=URL(fileURLWithPath:root+"/native/local-speaker-install/runtime-models").standardizedFileURL.path
                    let fixtures=["public-speech-fixture","public-mic-fixture","public-overlap-fixture"].map{URL(fileURLWithPath:root+"/native/validation-workflow/"+$0).standardizedFileURL.path}
                    guard URL(fileURLWithPath:args[2]).standardizedFileURL.path==model,fixtures.contains(URL(fileURLWithPath:args[3]).standardizedFileURL.path) else{throw Failure(code:"offline_fixture_scope_invalid")}
                }
                emit(try await offlineSpeechProbe(directory:URL(fileURLWithPath:args[2]),fixture:URL(fileURLWithPath:args[3])));return
            }
            if args.count == 4 && args[1] == "--prepare-standby" {
                guard let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,
                      URL(fileURLWithPath:args[2]).standardizedFileURL.path == URL(fileURLWithPath:root+"/native/local-speaker-install/runtime-models").standardizedFileURL.path,
                      URL(fileURLWithPath:args[3]).standardizedFileURL.path == URL(fileURLWithPath:root+"/native/local-embedding-install/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx").standardizedFileURL.path
                else {throw Failure(code:"preparation_model_scope_invalid")}
                preparedDirectory=args[2];preparedEmbedding=args[3]
                let started=ProcessInfo.processInfo.systemUptime
                for track in ["mic","remote"] {
                    let epoch=UUID().uuidString;let pipeline=SpeakerPipeline(source:track,epoch:epoch)
                    prepared[track]=pipeline;preparedEpochs[track]=epoch
                    emit(["type":"preparation","state":"loading","track":track,"capture":true,"network":false])
                    try await pipeline.load(directory:URL(fileURLWithPath:args[2]),embeddingModel:URL(fileURLWithPath:args[3]))
                    emit(["type":"preparation","state":"warming","track":track,"capture":false,"network":false])
                    try await pipeline.warmStandby()
                    emit(["type":"preparation","state":"track_ready","track":track,"elapsed_seconds":ProcessInfo.processInfo.systemUptime-started,"capture":false,"network":false])
                }
                emit(["type":"preparation","state":"ready","elapsed_seconds":ProcessInfo.processInfo.systemUptime-started,"models_retained":2,"capture":false,"network":false])
            }
            if args.count==2,args[1]=="--speaker-history-self-test",Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true {
                emit(try await speakerHistoryChecks());return
            }
            if args.count==3,args[1]=="--pipeline-self-test",Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true {
                let fixture=try await pipelineFixture(directory:URL(fileURLWithPath:args[2]))
                for event in fixture.events {emit(event)};emit(fixture.evidence);return
            }
            if args.count==4,args[1]=="--clock-self-test",Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true,let seconds=Double(args[3]) {do {emit(try await independentClockFixture(directory:URL(fileURLWithPath:args[2]),target:seconds))} catch {emit(["type":"offline_clock_fixture_error","diagnostic":String(describing:error),"capture":false,"network":false]);exit(1)};return}
            if args.count==5,args[1]=="--clock-diagnostic",Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true,let seconds=Double(args[3]) {do {emit(try await clockDiagnostic(directory:URL(fileURLWithPath:args[2]),target:seconds,mode:args[4]))}catch{emit(["type":"offline_clock_probe_error","diagnostic":String(describing:error),"capture":false,"network":false]);exit(1)};return}
            if args.count==3,args[1]=="--source-pipeline-self-test",Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true {
                guard let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,URL(fileURLWithPath:args[2]).standardizedFileURL.path==root+"/.runtime/source-pipeline-checks" else{throw Failure(code:"offline_fixture_scope_invalid")}
                emit(try await sourcePipelineFixture(directory:URL(fileURLWithPath:args[2])));return
            }
            if args.count==3,args[1]=="--capture-safety-self-test",Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true {
                guard let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,URL(fileURLWithPath:args[2]).standardizedFileURL.path==root+"/.runtime/capture-safety-checks" else{throw Failure(code:"offline_fixture_scope_invalid")}
                emit(try await captureSafetyChecks(directory:URL(fileURLWithPath:args[2])));return
            }
            if args.count==6,args[1]=="--capture-control-protocol-fixture",Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true,
               let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,
               let ackFD=Int32(args[5]),UUID(uuidString:args[3]) != nil,UUID(uuidString:args[4]) != nil {
                let directory=URL(fileURLWithPath:args[2]).standardizedFileURL
                let expected=URL(fileURLWithPath:root+"/.runtime/capture-protocol-fixtures/"+args[4]).standardizedFileURL
                guard directory.path==expected.path else{throw Failure(code:"offline_fixture_scope_invalid")}
                try runCaptureControlProtocolFixture(directory:directory,session:args[3],ackFD:ackFD);return
            }
            if args.count==3,args[1]=="--session-cache-recovery-self-test",Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true {
                guard let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,URL(fileURLWithPath:args[2]).standardizedFileURL.path==root+"/.runtime/session-cache-recovery-checks" else{throw Failure(code:"offline_fixture_scope_invalid")}
                emit(try sessionCacheRecoveryChecks(base:URL(fileURLWithPath:args[2])));return
            }
            if args.contains("--self-test") { try selfTest(); return }
            if let index = args.firstIndex(of: "--describe"), args.count > index + 1 {
                let bundle = args[index + 1]
                var inputProperty=address(kAudioHardwarePropertyDefaultInputDevice),inputDevice:AudioObjectID=0,inputSize=UInt32(MemoryLayout<AudioObjectID>.size)
                let inputStatus=AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&inputProperty,0,nil,&inputSize,&inputDevice)
                var description:[String:Any]=["type": "description", "bundle": bundle, "pids": processes(bundle: bundle),
                      "audio_processes": selectedAudioProcesses(bundle: bundle),
                      "microphone_permission_status":AVCaptureDevice.authorizationStatus(for:.audio).rawValue,
                      "default_input_status":inputStatus,"audio_started":false,"network_started":false,"permission_requested":false]
                if inputStatus==noErr,inputDevice != kAudioObjectUnknown {description["default_microphone"]=microphoneDeviceSnapshot(inputDevice)}
                emit(description);return
            }
            guard (args == [args[0], "--run-confirmed"] || !prepared.isEmpty), let line = readLine() else {
                for pipeline in prepared.values {_ = try? await pipeline.close(flush:false)}
                emit(["type": "help", "modes": ["--self-test (offline)", "--describe BUNDLE (read only)", "--run-confirmed (approved launcher only)"]]); return
            }
            if !prepared.isEmpty,let command=(try? JSONSerialization.jsonObject(with:Data(line.utf8))) as? [String:Any],command["preparation_only"] as? Bool == true {
                for pipeline in prepared.values {_ = try await pipeline.close(flush:false)}
                emit(["type":"preparation","state":"released","models_released":2,"capture":false,"network":false]);return
            }
            if Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool == true {throw Failure(code:"offline_validation_only")}
            let config = try JSONDecoder().decode(Config.self, from: Data(line.utf8)); try config.validate()
            captureControlAckFD = try configureControlAcknowledgementDescriptor(config.controlAckFD)
            if !prepared.isEmpty {guard config.localSpeakerDirectory==preparedDirectory,config.localEmbeddingModel==preparedEmbedding else {throw Failure(code:"prepared_model_scope_changed")}}
            if config.bundle=="*system*",config.resumeCacheID==nil {
                if config.isLocalOnly {guard Bundle.main.object(forInfoDictionaryKey:"LocalRecordingAllowed") as? Bool==true,config.userLaunchConfirmed==true,config.localRecordingConfirmed==true else{throw Failure(code:"local_recording_not_confirmed")}}
                guard config.userLaunchConfirmed==true,config.useMic,(config.isLocalOnly || config.cloudSessionConfirmed==true),Bundle.main.object(forInfoDictionaryKey:"LocalRecordingAllowed") as? Bool==true else{throw Failure(code:"source_capture_not_confirmed")}
                try await requireMicrophonePermission()
                try await runSourceCaptureSession(config:config);return
            }
            if config.isLocalOnly {
                guard Bundle.main.object(forInfoDictionaryKey:"LocalRecordingAllowed") as? Bool==true,config.userLaunchConfirmed==true,config.localRecordingConfirmed==true,["com.tencent.meeting","*microphone*","*system*"].contains(config.bundle),config.useMic else{throw Failure(code:"local_recording_not_confirmed")}
                try await requireMicrophonePermission()
                try await runLocalRecording(config:config);return
            }
            if Bundle.main.object(forInfoDictionaryKey:"TrialCandidate") as? Bool == true {
                let clickGate=Bundle.main.object(forInfoDictionaryKey:"ClickStartsTrial") as? Bool == true && config.userLaunchConfirmed == true
                let independentCloud=Bundle.main.object(forInfoDictionaryKey:"LocalRecordingAllowed") as? Bool==true && config.cloudSessionConfirmed==true
                guard (Bundle.main.object(forInfoDictionaryKey:"TrialArmed") as? Bool == true || clickGate),(independentCloud ? ["com.tencent.meeting","*microphone*","*system*"]:["com.tencent.meeting","*microphone*"]).contains(config.bundle),config.useMic,config.maxSeconds<=(independentCloud ? 7200:180),config.localSpeakerDirectory != nil,config.localEmbeddingModel != nil else {throw Failure(code:"candidate_not_armed_or_out_of_scope")}
            }
            if let id=config.resumeCacheID {try await resumeCachedMeeting(config:config,id:id);return}
            guard config.bundle != "*microphone*" || config.useMic else {throw Failure(code:"microphone_mode_requires_mic")}
            guard ["*system*","*microphone*"].contains(config.bundle) || !processes(bundle: config.bundle).isEmpty else { throw Failure(code: "selected_application_not_running") }
            if config.useMic {try await requireMicrophonePermission()}
            let launcherPID = getppid()
            let active=activeCaptureTracks(bundle:config.bundle,useMic:config.useMic)
            let cacheID=config.appendCaptureCacheID ?? UUID().uuidString
            let cacheDirectory=RuntimeConfiguration.dataRoot().appendingPathComponent("SessionCache").appendingPathComponent(cacheID)
            if config.appendCaptureCacheID==nil {try FileManager.default.createDirectory(at:cacheDirectory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
            let writerLease=try SessionCacheWriterLease.acquire(directory:cacheDirectory)
            defer {writerLease.release()}
            let oldInfo:[String:Any]
            let oldTracks:[String]
            if config.appendCaptureCacheID != nil {
                guard let value=try JSONSerialization.jsonObject(with:Data(contentsOf:cacheDirectory.appendingPathComponent("meeting.json"))) as? [String:Any],
                      value["session"] as? String==config.session,value["bundle"] as? String==config.bundle,
                      value["asr_model"] as? String==config.model,value["capture_mode"] as? String != "local_only" else{throw Failure(code:"append_capture_scope_invalid")}
                oldInfo=value;oldTracks=try meetingAudioTracks(in:cacheDirectory,transcriptOnly:false)
            } else {oldInfo=[:];oldTracks=[]}
            let reserved=reservedMeetingAudioTracks(in:cacheDirectory,metadata:oldInfo)
            var physical:[String:String]=[:]
            for logical in active {
                if config.appendCaptureCacheID==nil && !reserved.contains(logical) {physical[logical]=logical}
                else {physical[logical]=(1...999).map{logical+"-g"+String($0)}.first{!reserved.contains($0)}}
                guard physical[logical] != nil else{throw Failure(code:"source_generation_limit")}
            }
            let continuation=captureContinuation(in:cacheDirectory,metadata:oldInfo)
            let captureClock=CaptureBudgetClock(zone:continuation.zone,continuationOrigin:config.appendCaptureCacheID==nil ? nil:continuation.origin,continuationElapsed:continuation.elapsed,priorAnchors:continuation.anchors)
            let state=CaptureRunState()
            var journals:[String:RecordingJournal]=[:]
            for track in active {journals[track]=try RecordingJournal(directory:cacheDirectory,track:physical[track]!)}
            var meetingInfo:[String:Any]=oldInfo.isEmpty ? ["session":config.session,"cache_id":cacheID,"bundle":config.bundle,"mic_enabled":config.useMic,"created_at":Date().timeIntervalSince1970,"capture_mode":"cloud","asr_destination":"dashscope.aliyuncs.com","asr_model":config.model] : oldInfo
            if config.appendCaptureCacheID != nil,meetingInfo["archive_only_before_append"] as? Bool != true,
               FileManager.default.fileExists(atPath:cacheDirectory.appendingPathComponent("archived-transcript.txt").path),
               oldTracks.filter({isTranscriptAudioTrack($0)}).allSatisfy({track in
                   let file=cacheDirectory.appendingPathComponent(track+"-transcript.jsonl")
                   return ((try? file.resourceValues(forKeys:[.fileSizeKey]))?.fileSize ?? 0)==0
               }) {
                let prefix=cacheDirectory.appendingPathComponent("archived-preappend.txt")
                if !FileManager.default.fileExists(atPath:prefix.path) {try FileManager.default.copyItem(at:cacheDirectory.appendingPathComponent("archived-transcript.txt"),to:prefix)}
                meetingInfo["archive_only_before_append"]=true
            }
            if config.cloudSessionConfirmed==true {meetingInfo["cloud_session_authorized"]=true;meetingInfo["unlimited_session"]=config.unlimitedSession==true;if config.unlimitedSession != true {meetingInfo["cloud_audio_ceiling_seconds"]=14400;meetingInfo["cloud_budget_yuan"]=5}}
            let meetingFile=cacheDirectory.appendingPathComponent("meeting.json");try JSONSerialization.data(withJSONObject:meetingInfo,options:[.sortedKeys]).write(to:meetingFile,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:meetingFile.path)
            func persistClock()throws {meetingInfo["absolute_clock"]=captureClock.absoluteClock();try JSONSerialization.data(withJSONObject:meetingInfo,options:[.sortedKeys]).write(to:meetingFile,options:.atomic)}
            let modelBoxes=["mic":Mailbox(journal:journals["mic"],producer:false),"remote":Mailbox(journal:journals["remote"],producer:false)]
            let micBox=Mailbox(captureClock:captureClock,totalByteLimit:config.unlimitedSession==true ? nil:Int(config.maxSeconds*32000),journal:journals["mic"])
            let remoteBox=Mailbox(captureClock:captureClock,totalByteLimit:config.unlimitedSession==true ? nil:Int(config.maxSeconds*32000),journal:journals["remote"])
            let boxes=["mic":micBox,"remote":remoteBox]
            let mic=Microphone();let tap=ApplicationTap()
            let lanes=["mic":Lane(track:physical["mic"] ?? "mic",config:config,prepared:prepared["mic"],preparedEpoch:preparedEpochs["mic"]),"remote":Lane(track:physical["remote"] ?? "remote",config:config,prepared:prepared["remote"],preparedEpoch:preparedEpochs["remote"])]
            for track in active {await lanes[track]!.attachJournal(journals[track])}
            capturePaused=0;captureUploadPaused=0;captureHardwareReady=0;captureControlRevision=0;capturePauseAcknowledgedRevision = -1;captureFinishing=0;captureTailDrainAllowed=0
            signal(SIGINT,interruptHandler);signal(SIGTERM,interruptHandler)
            signal(SIGUSR1,recordingPauseHandler);signal(SIGUSR2,recordingPauseHandler)
            signal(SIGWINCH,recordingFinishHandler)
            func stopCapture(_ reason:String){
                let elapsed=captureClock.elapsed(ProcessInfo.processInfo.systemUptime)
                guard state.end(reason:reason,elapsed:elapsed) else{return}
                mic.stop();tap.stop();for box in boxes.values {box.seal()};for box in modelBoxes.values {box.seal()}
                emit(["type":"capture_stopped","session":config.session,"recording_elapsed_seconds":elapsed,"reason":reason,"capture":false,"capture_gate":"closed","upload_gate":"draining_saved_audio","processing_pending":true])
            }
            var consumers:[Task<Void,Never>]=[]
            var sourceWatcher:Task<Void,Never>?
            do {
                // Device capture precedes model load and every network handshake.
                if config.bundle != "*microphone*" {try tap.start(bundle:config.bundle,micEnabled:config.useMic,box:remoteBox)}
                if config.useMic {try mic.start(micBox)}
                captureHardwareReady=1
                let firstPCMDeadline=ProcessInfo.processInfo.systemUptime+5
                while captureClock.origin()==nil && interrupted==0 && ProcessInfo.processInfo.systemUptime<firstPCMDeadline {for box in boxes.values {try box.checkFault()};try await Task.sleep(nanoseconds:10_000_000)}
                guard let origin=captureClock.origin(),interrupted==0 else{throw Failure(code:interrupted != 0 ? "user_stopped_before_capture":"no_sound")}
                meetingInfo["capture_origin_uptime"]=origin;try persistClock()
                emit(["type":"started","audio_frames_received":true,"session":config.session,"destination":"dashscope.aliyuncs.com","model":config.model,"absolute_clock":captureClock.absoluteClock(),"capture_origin_uptime":origin,"audio_storage":"local_segmented_recoverable","cache_id":cacheID,"speaker_loading":true,"append_capture":config.appendCaptureCacheID != nil])
                sourceWatcher=Task {
                    while !Task.isCancelled && state.snapshot().0==nil {
                        if getppid() != launcherPID {stopCapture("launcher_exited");interrupted=2;return}
                        if interrupted>0 {stopCapture("user_stop");return}
                        if config.unlimitedSession != true && captureClock.elapsed(ProcessInfo.processInfo.systemUptime)>=config.maxSeconds {stopCapture(config.cloudSessionConfirmed==true ? "cloud_duration_limit":"trial_time_limit");return}
                        do {for box in boxes.values {try box.checkFault()};for box in modelBoxes.values {try box.checkFault()}}
                        catch {let code=(error as? Failure)?.code ?? "capture_failed";state.fault(code);stopCapture(code);return}
                        try? await Task.sleep(nanoseconds:20_000_000)
                    }
                }
                for track in active {
                    let lane=lanes[track]!;let modelBox=modelBoxes[track]!;let box=boxes[track]!
                    consumers.append(Task {
                        do {
                            guard config.localSpeakerDirectory != nil else{return}
                            try await lane.prepareSpeakers()
                            while !Task.isCancelled && interrupted<2 {
                                if let (packet,stamp)=try modelBox.takePacket(now:ProcessInfo.processInfo.systemUptime,flush:modelBox.isSealed()) {try await lane.ingestSpeakers(packet,captureAt:stamp,sessionStart:origin);try modelBox.checkpoint("model")}
                                else if modelBox.isSealed() {break}
                                else {await lane.publishPendingSpeakerFeatures();try await Task.sleep(nanoseconds:5_000_000)}
                            }
                        } catch {if interrupted<2 {emit(["type":"speaker_model","state":"failed","track":track,"session":config.session,"reason":(error as? Failure)?.code ?? "speaker_model_failed","audio_retained":true,"asr_continues":true])}}
                    })
                    consumers.append(Task {
                        let store=journals[track]!
                        await runJournalASR(lane:lane,box:box,store:store,track:physical[track]!,origin:origin,onCacheFailure:{code in
                            if let audioFault=store.fault() {state.fault(audioFault);stopCapture(audioFault)}
                            else {emit(["type":"processing_failed","session":config.session,"consumer":"asr","track":physical[track]!,"reason":code,"audio_retained":true,"retry_available":true])}
                        },retryAfterLimit:true,stopReconnectOnCaptureStop:true)
                    })
                }
                var lastHealth=0.0;var lastProcessCheck=0.0
                // Application-tap route changes (device switch, helper PID change) are
                // repaired in place: pause the budget clock, rebuild the tap on the new
                // route, resume. Only repeated failed rebuilds end the recording.
                var tapNeedsRebuild=false;var tapRebuildReason="";var rebuildAttempts=0;var lastRebuildAt: Double = -1000
                func routeChangeReason() throws -> String? {
                    if config.bundle != "*system*",processes(bundle:config.bundle) != tap.selectedPIDs {return "selected_application_process_changed"}
                    if config.bundle=="*system*",audioObjects(for:selfAudioPIDs()) != tap.excludedAudioObjects {return "self_audio_process_changed"}
                    var property=address(kAudioHardwarePropertyDefaultOutputDevice);var clock:AudioObjectID=0;var size=UInt32(MemoryLayout<AudioObjectID>.size)
                    try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&property,0,nil,&size,&clock),"output_clock_check")
                    return clock != tap.outputClock ? "output_device_changed" : (tap.inputFormatChanged() ? "output_format_changed":nil)
                }
                func rebuildApplicationTap(reason:String) throws {
                    // The budget clock keeps running: the control loop treats a paused
                    // clock as a user pause. The microphone keeps recording throughout;
                    // only the application track has a short gap.
                    if capturePaused != 0 {tapNeedsRebuild=false;return}
                    let now=ProcessInfo.processInfo.systemUptime
                    if tapNeedsRebuild && now-lastRebuildAt<2 {return}  // give the device time to settle
                    if now-lastRebuildAt>30 {rebuildAttempts=0}
                    rebuildAttempts+=1;lastRebuildAt=now
                    guard rebuildAttempts<=3 else{throw Failure(code:reason)}
                    emit(["type":"audio_source","session":config.session,"state":"rerouting","reason":reason,"raw_microphone_retained":true])
                    tap.stop()
                    do {
                        try tap.start(bundle:config.bundle,micEnabled:config.useMic,box:remoteBox)
                    } catch {
                        tapNeedsRebuild=true;tapRebuildReason=reason
                        emit(["type":"audio_source","session":config.session,"state":"capture_unavailable","reason":reason,"raw_microphone_retained":true])
                        return
                    }
                    tapNeedsRebuild=false
                    emit(["type":"audio_source","session":config.session,"state":"capture_recovered","reason":reason])
                }
                var controlAcknowledgement=CaptureControlAcknowledgement()
                while state.snapshot().0==nil {
                    if captureFinishing != 0 {stopCapture("user_finish");break}
                    let controlTime=ProcessInfo.processInfo.systemUptime
                    let requestRevision=captureControlRevision
                    let requestedPaused=capturePaused != 0
                    if requestRevision != captureControlRevision { continue }
                    if requestedPaused && !captureClock.isPaused {
                        captureHardwareReady=0;captureClock.pause(at:controlTime);mic.stop();tap.stop()
                    } else if !requestedPaused && captureClock.isPaused {
                        if config.bundle != "*microphone*" {try tap.start(bundle:config.bundle,micEnabled:config.useMic,box:remoteBox)}
                        if config.useMic {try mic.start(micBox)}
                        captureClock.resume(at:controlTime);captureHardwareReady=1;captureUploadPaused=0;try persistClock()
                    }
                    if controlAcknowledgement.accept(requestRevision:requestRevision,
                                                     requestedPaused:requestedPaused,
                                                     actualPaused:captureClock.isPaused) {
                        emit(["type":requestedPaused ? "recording_paused":"recording_resumed",
                              "session":config.session,
                              "recording_elapsed_seconds":captureClock.elapsed(ProcessInfo.processInfo.systemUptime),
                              "absolute_clock":captureClock.absoluteClock(),
                              "capture":!requestedPaused,
                              "capture_gate":requestedPaused ? "closed":"open",
                              "upload_gate":requestedPaused ? "draining_saved_audio":"open",
                              "control_revision":requestRevision,
                              "draining_tracks":requestedPaused ? active:[],
                              "hardware_teardown":requestedPaused ? "pending":"complete"])
                        if requestedPaused {capturePauseAcknowledgedRevision=requestRevision}
                    }
                    let elapsed=captureClock.elapsed(ProcessInfo.processInfo.systemUptime)
                    if tapNeedsRebuild || (!captureClock.isPaused && elapsed-lastProcessCheck>=0.5 && config.bundle != "*microphone*") {
                        if !tapNeedsRebuild {lastProcessCheck=elapsed}
                        let reason = try tapNeedsRebuild ? tapRebuildReason : routeChangeReason()
                        if let reason {try rebuildApplicationTap(reason:reason)}
                    }
                    if elapsed-lastHealth>=1 {
                        lastHealth=elapsed;var health:[String:Any]=["type":"health","session":config.session,"elapsed_seconds":elapsed]
                        for track in active {var metrics=boxes[track]!.metrics().merging(await lanes[track]!.metrics()){_,new in new};let model=modelBoxes[track]!.metrics();metrics["speaker_backlog_seconds"]=model["buffered_audio_seconds"];metrics["speaker_queue_peak_bytes"]=model["max_queued_bytes"];metrics["speaker_discarded_bytes"]=model["discarded_bytes"];metrics["speaker_coverage_gap"]=model["coverage_gap"];metrics["speaker_buffer_near_full"]=model["buffer_near_full"];health[physical[track]!]=metrics};emit(health)
                    }
                    try await Task.sleep(nanoseconds:10_000_000)
                }
            } catch {let code=(error as? Failure)?.code ?? "capture_or_send_failed";state.fault(code);stopCapture(code)}
            sourceWatcher?.cancel()
            let recordingEnded=state.snapshot().0 ?? captureClock.elapsed(ProcessInfo.processInfo.systemUptime)
            meetingInfo["recording_elapsed_seconds"]=recordingEnded;try persistClock()
            if interrupted==0 {interrupted=1}
            emit(["type":"processing_started","session":config.session,"recording_elapsed_seconds":recordingEnded,"capture":false,"deadline_seconds":180])
            let processingWatch=Task {try? await Task.sleep(nanoseconds:180_000_000_000);if !Task.isCancelled {state.fault("processing_timeout");interrupted=2;for lane in lanes.values {await lane.cancelTransport()}}}
            let parentWatch=Task {while !Task.isCancelled {if getppid() != launcherPID {interrupted=2;for lane in lanes.values {await lane.cancelTransport()};return};try? await Task.sleep(nanoseconds:250_000_000)}}
            for consumer in consumers {await consumer.value}
            parentWatch.cancel();await parentWatch.value;processingWatch.cancel()
            // Final local finish annotates the entire retained transcript before close.
            for lane in lanes.values {await lane.stop()}
            for store in journals.values {store.wait()}
            for box in boxes.values {box.clear()};for box in modelBoxes.values {box.clear()}
            var health:[String:Any]=["type":"health","session":config.session,"elapsed_seconds":recordingEnded]
            for track in active {var metrics=boxes[track]!.metrics().merging(await lanes[track]!.metrics()){_,new in new};let model=modelBoxes[track]!.metrics();metrics["speaker_backlog_seconds"]=model["buffered_audio_seconds"];metrics["speaker_queue_peak_bytes"]=model["max_queued_bytes"];metrics["speaker_discarded_bytes"]=model["discarded_bytes"];metrics["speaker_coverage_gap"]=model["coverage_gap"];health[physical[track]!]=metrics};emit(health)
            let snapshot=state.snapshot();let reason=snapshot.2 ?? (interrupted>=2 ? "processing_cancelled":snapshot.1)
            emit(["type":"stopped","reason":reason,"recording_elapsed_seconds":recordingEnded,"received_at":captureClock.elapsed(ProcessInfo.processInfo.systemUptime),"session":config.session,"application":config.bundle,"transcription_complete":journals.values.allSatisfy{$0.transcriptionIsComplete()},"raw_audio_saved":true,"audio_storage":"local_segmented_recoverable","capture":false,"capture_gate":"closed","upload_gate":"closed"])
        } catch let error as Failure { emit(["type": "error", "code": error.code]); exit(1) }
          catch { emit(["type": "error", "code": "operation_failed"]); exit(1) }
    }
    static func selfTest() throws {
        try appendCaptureClockChecks()
        let clock=CaptureBudgetClock();precondition(clock.elapsed(90)==0 && clock.origin()==nil)
        let syntheticBox=Mailbox(captureClock:clock);syntheticBox.put(Data([0,0]),at:100)
        precondition(clock.origin()==100 && clock.elapsed(101)==1)
        syntheticBox.put(Data([0,0]),at:200);precondition(clock.origin()==100 && clock.elapsed(201)==101)
        let noAudioClock=CaptureBudgetClock();let emptyBox=Mailbox(captureClock:noAudioClock);emptyBox.put(Data(),at:300);precondition(noAudioClock.elapsed(400)==0)
        let decoder = Decoder()
        func object(_ final: Bool, _ text: String, _ end: Any = NSNull(), _ task: String = "t") -> [String: Any] {
            ["header": ["event": "result-generated", "task_id": task], "payload": ["output": ["sentence": ["sentence_id": 1,
              "begin_time": 100.0, "end_time": end, "sentence_end": final, "text": text, "speaker_id": NSNull()]]]]
        }
        let globalScope=scopeDescription(global:true,ids:[11,12]);precondition(globalScope.isExclusive && globalScope.isPrivate && globalScope.processes == [11,12])
        let selectedScope=scopeDescription(global:false,ids:[21]);precondition(!selectedScope.isExclusive && selectedScope.processes == [21] && selectedScope.muteBehavior == .unmuted)
        func decode(_ value: [String: Any]) throws -> [String: Any]? { try decoder.decode(value, task: "t", track: "remote", session: "mock", bundle: "mock-app", origin: 10, received: 11) }
        let partial = try decode(object(false, "数值12"))!
        precondition(partial["final"] as? Bool == false && partial["end_time_known"] as? Bool == false)
        let duplicate = try decode(object(false, "数值12"))
        precondition(duplicate == nil)
        let final = try decode(object(true, "数值15.2", 800.0))!
        precondition(final["revision"] as? Int == 2 && final["start"] as? Double == 10.1)
        var failures = 0
        for bad in [object(true, "缺结束时间"), object(false, "错误task", NSNull(), "other")] {
            do { _ = try decode(bad) } catch { failures += 1 }
        }
        precondition(failures == 2)
        let empty = try decode(object(true, "", 900.0))
        precondition(empty == nil)
        _ = try decode(object(false, "合成中文片段"))
        let shifted = try decode(object(true, "unexpected English result", 900.0))!
        precondition((shifted["quality_flags"] as? [String]) == ["language_shift_needs_review"])
        precondition(shifted["text"] as? String == "unexpected English result" && shifted["previous_partial"] as? String == "合成中文片段")
        // Synthetic PCM frame playback exercises resampling without opening any device.
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let samples = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4800)!
        samples.frameLength = 4800
        for i in 0..<4800 { samples.floatChannelData![0][i] = Float(sin(Double(i) * 0.1) * 0.2) }
        let pcm = try PCMConverter(inputFormat).convert(samples)
        precondition(pcm.count > 0 && pcm.count <= 3328 && pcm.contains(where: { $0 != 0 }))
        let copy = clone(samples)!
        precondition(copy.frameLength == 4800 && copy.floatChannelData![0][100] == samples.floatChannelData![0][100])
        let box = Mailbox()
        precondition(!box.hasFrames()) // Idle remote does not satisfy the lazy-connection guard.
        box.put(Data([1, 0]), at: 0)
        precondition(box.hasFrames())
        _ = try box.take()
        for _ in 0..<21 { box.put(Data(repeating: 0, count: 4000), at: 0) }
        do { _ = try box.take(); throw Failure(code: "self_test_overflow_missing") } catch let error as Failure { precondition(error.code == "audio_backpressure") }
        let usage:[String:Any]=["header":["task_id":"fake-task","event":"result-generated"],"payload":["usage":["duration":3]]]
        let firstUsage=try providerUsage(usage,task:"fake-task",track:"mic");precondition(firstUsage?["duration"] as? Double==3)
        let finalUsage:[String:Any]=["header":["task_id":"fake-task","event":"task-finished"],"payload":["usage":["duration":9]]]
        let lastUsage=try providerUsage(finalUsage,task:"fake-task",track:"mic");precondition(lastUsage?["final"] as? Bool==true)
        for bad in [-1.0,Double.nan,Double.infinity] {
            do {_ = try providerUsage(["header":["task_id":"fake-task","event":"result-generated"],"payload":["usage":["duration":bad]]],task:"fake-task",track:"mic");preconditionFailure()} catch {}
        }
        do {_ = try providerUsage(usage,task:"wrong-task",track:"mic");preconditionFailure()} catch {}
        try transportReplay()
        let bounded=Decoder()
        for sid in 1...2000 {
            let sentence:[String:Any]=["sentence_id":sid,"begin_time":Double(sid*100),"end_time":Double(sid*100+100),"sentence_end":true,"text":"合成段"]
            _ = try bounded.decode(["header":["task_id":"bounded","event":"result-generated"],"payload":["output":["sentence":sentence]]],task:"bounded",track:"mic",session:"synthetic",bundle:"synthetic",origin:0,received:0)
        }
        precondition(bounded.payloads.count==200 && bounded.revisions.count==200 && bounded.retainedOrder.count==200 && bounded.partials.isEmpty)
        precondition(activeCaptureTracks(bundle:"*microphone*",useMic:true)==["mic"])
        precondition(activeCaptureTracks(bundle:"*microphone*",useMic:false).isEmpty)
        precondition(activeCaptureTracks(bundle:"com.tencent.meeting",useMic:true)==["mic","remote"])
        precondition(activeCaptureTracks(bundle:"com.tencent.meeting",useMic:false)==["remote"])
        let wordDecoder=Decoder()
        func withWords(_ words:[[String:Any]])->[String:Any] {var result=object(true,"你好。",800.0);var payload=result["payload"] as! [String:Any];var output=payload["output"] as! [String:Any];var sentence=output["sentence"] as! [String:Any];sentence["words"]=words;output["sentence"]=sentence;payload["output"]=output;result["payload"]=payload;return result}
        let words:[[String:Any]]=[["begin_time":100.0,"end_time":300.0,"text":"你","punctuation":""],["begin_time":300.0,"end_time":800.0,"text":"好","punctuation":"。"]]
        let wordEvent=try wordDecoder.decode(withWords(words),task:"t",track:"mic",session:"fixture",bundle:"synthetic",origin:10,received:11)!
        precondition((wordEvent["word_spans"] as? [[String:Any]])?.first?["start"] as? Double==10.1)
        var revised=words;revised[0]["end_time"]=250.0;revised[1]["begin_time"]=250.0
        let revisionEvent=try wordDecoder.decode(withWords(revised),task:"t",track:"mic",session:"fixture",bundle:"synthetic",origin:10,received:11)!
        precondition(revisionEvent["revision"] as? Int==2)
        var badWords=words;badWords[1]["text"]="错"
        let badEvent=try wordDecoder.decode(withWords(badWords),task:"t",track:"mic",session:"fixture",bundle:"synthetic",origin:10,received:11)!
        precondition(badEvent["word_spans"]==nil && badEvent["text"] as? String=="你好。")
        badWords=words;badWords[1]["begin_time"]=200.0
        let overlapWords=try wordDecoder.decode(withWords(badWords),task:"t",track:"mic",session:"fixture",bundle:"synthetic",origin:10,received:11)!
        precondition(overlapWords["word_spans"]==nil)
        let independentModel=Mailbox(maxBytes:9600,maxFrames:100);let earlyASR=Mailbox(maxBytes:9600,maxFrames:100,mirror:independentModel,totalByteLimit:6400)
        earlyASR.put(Data(repeating:7,count:3200),at:100);earlyASR.put(Data(repeating:8,count:3200),at:100.1);earlyASR.put(Data(repeating:9,count:3200),at:100.2)
        precondition(earlyASR.metrics()["pcm_bytes"] as? Int==6400 && independentModel.metrics()["pcm_bytes"] as? Int==6400 && earlyASR.metrics()["boundary_trimmed_bytes"] as? Int==3200)
        earlyASR.seal();independentModel.seal();var asrBytes=Data();var modelBytes=Data()
        while let (packet,_)=try earlyASR.takePacket(now:101,flush:true){asrBytes.append(packet)}
        while let (packet,_)=try independentModel.takePacket(now:101,flush:true){modelBytes.append(packet)}
        precondition(asrBytes==modelBytes && asrBytes.count==6400 && asrBytes[0]==7 && asrBytes[3200]==8)
        earlyASR.clear();independentModel.clear();precondition(earlyASR.metrics()["discarded_bytes"] as? Int==0 && independentModel.metrics()["queued_bytes"] as? Int==0)
        let stopState=CaptureRunState();precondition(stopState.end(reason:"user_stop",elapsed:3) && !stopState.end(reason:"trial_time_limit",elapsed:10) && stopState.snapshot().0==3);stopState.fault("processing_timeout");precondition(stopState.snapshot().2=="processing_timeout")
        var controlAck=CaptureControlAcknowledgement()
        precondition(!controlAck.accept(requestRevision:0,requestedPaused:false,actualPaused:false))
        precondition(controlAck.accept(requestRevision:1,requestedPaused:true,actualPaused:true))
        precondition(!controlAck.accept(requestRevision:1,requestedPaused:true,actualPaused:true))
        precondition(controlAck.accept(requestRevision:2,requestedPaused:true,actualPaused:true)) // lost pause ACK, same-state retry
        precondition(!controlAck.accept(requestRevision:3,requestedPaused:false,actualPaused:true)) // hardware not resumed yet
        precondition(controlAck.accept(requestRevision:3,requestedPaused:false,actualPaused:false))
        precondition(controlAck.accept(requestRevision:4,requestedPaused:false,actualPaused:false)) // lost resume ACK
        emit(["type": "self_test", "passed": 42, "network": false, "capture": false])
    }

    static func transportReplay() throws {
        // Exact runtime Mailbox/packetizer, virtual 1ms clock. No audio device or socket.
        func replay(congested: Bool, oldSerial: Bool) throws -> [String: Any] {
            let boxes = ["mic": Mailbox(), "remote": Mailbox()]
            var received = ["mic": 0, "remote": 0]
            var delivery = ["mic": 0.0, "remote": 0.0]
            var completed = ["mic": Data(), "remote": Data()]
            var nextGlobal = 0.0
            var stoppedAt: Double?
            var fault = "none"
            for tick in 0..<480_000 {
                let now = Double(tick) / 1000
                if tick % 100 == 0 { boxes["mic"]!.put(Data(repeating: 0x11, count: 3200), at: now) }
                if tick % 20 == 0 { boxes["remote"]!.put(Data(repeating: 0x22, count: 640), at: now) }
                do {
                    try boxes["mic"]!.checkFault(); try boxes["remote"]!.checkFault()
                    if oldSerial {
                        if now >= nextGlobal {
                            var delay = 0.01 // Previous unconditional sleep.
                            if let packet = try boxes["mic"]!.take() { received["mic"]! += packet.0.count; delay += 0.014 }
                            if let packet = try boxes["remote"]!.take() { received["remote"]! += packet.0.count; delay += 0.009 }
                            nextGlobal = now + delay
                        }
                    } else {
                        for track in ["mic", "remote"] {
                            if now >= delivery[track]! {
                                if !completed[track]!.isEmpty { received[track]! += completed[track]!.count; completed[track] = Data() }
                                if let packet = try boxes[track]!.takePacket(now: now) {
                                    precondition(packet.0.count <= 3200)
                                    precondition(packet.0.allSatisfy { $0 == (track == "mic" ? 0x11 : 0x22) })
                                    completed[track] = packet.0
                                    // 80ms send latency; occasional 250ms stalls; a fault case exceeds the fixed 2s budget.
                                    let stall = congested && track == "remote" && now >= 30 && now < 30.2 ? 2.5 :
                                                Int(now) % 31 == 30 ? 0.25 : 0.08
                                    delivery[track] = now + stall
                                }
                            }
                        }
                    }
                } catch let error as Failure { stoppedAt = now; fault = error.code; break }
            }
            if stoppedAt == nil {
                for track in ["mic", "remote"] {
                    received[track]! += completed[track]!.count
                    while let packet = try boxes[track]!.takePacket(now: 481, flush: true) { received[track]! += packet.0.count }
                    precondition(received[track] == 480 * 32000)
                    precondition(boxes[track]!.metrics()["discarded_bytes"] as? Int == 0)
                }
            }
            let gap = boxes.values.contains { ($0.metrics()["coverage_gap"] as? Bool) == true }
            for box in boxes.values { box.clear() }
            precondition(boxes.values.allSatisfy { ($0.metrics()["queued_bytes"] as? Int) == 0 })
            return ["scenario": oldSerial ? "old_serial" : congested ? "congestion" : "new_dual_8min",
                    "virtual_seconds": stoppedAt ?? 480, "stop_reason": fault, "sent_bytes": received,
                    "coverage_gap": gap, "queues_released": true]
        }
        let old = try replay(congested: false, oldSerial: true)
        precondition(old["stop_reason"] as? String == "audio_backpressure")
        let regular = try replay(congested: false, oldSerial: false)
        precondition(regular["stop_reason"] as? String == "none")
        let slow = try replay(congested: true, oldSerial: false)
        precondition(slow["stop_reason"] as? String == "audio_backpressure" && slow["coverage_gap"] as? Bool == true)
        emit(["type": "transport_replay", "results": [old, regular, slow], "network": false, "capture": false])
    }
}
