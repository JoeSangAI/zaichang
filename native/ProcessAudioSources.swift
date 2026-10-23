import Foundation
import AppKit
import AVFoundation
import CoreAudio
import CryptoKit
import Darwin

// A process is attributed to an application only after its PID or executable
// location has been checked. CoreAudio's optional bundle ID is not ownership
// evidence for a helper process.
struct ProcessAudioObservation: Equatable {
    let pid: pid_t
    let objectID: AudioObjectID
    let ownerBundleID: String?
    let ownerName: String?
}

struct ProcessAudioSource: Equatable {
    let sourceID: String
    let applicationName: String
    let bundleID: String?
    let audioObjectIDs: [AudioObjectID]
    let pids: [pid_t]

    var metadata: [String: Any] {
        var result: [String: Any] = ["source_id": sourceID, "application_name": applicationName]
        if let bundleID { result["bundle_id"] = bundleID }
        return result
    }
}

enum ProcessAudioInventory {
    static let unknownSourceID = "remote"
    static let unknownName = "其他电脑声音"

    static func sourceID(for bundleID: String) -> String {
        let digest = SHA256.hash(data: Data(bundleID.utf8))
        return "app-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // Pure grouping lets route behavior be tested without a capture permission.
    static func group(_ observations: [ProcessAudioObservation]) -> [ProcessAudioSource] {
        let byBundle = Dictionary(grouping: observations.filter { $0.objectID != kAudioObjectUnknown }) {
            $0.ownerBundleID.flatMap { $0.isEmpty ? nil : $0 }
        }
        return byBundle.map { bundle, members in
            let names = members.compactMap(\.ownerName).filter { !$0.isEmpty }
            let candidate = bundle == nil ? unknownName : (names.sorted().first ?? bundle ?? unknownName)
            let name = candidate.count <= 80 && !candidate.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }) ? candidate : unknownName
            return ProcessAudioSource(sourceID: bundle.map(sourceID(for:)) ?? unknownSourceID,
                                      applicationName: name, bundleID: bundle,
                                      audioObjectIDs: Array(Set(members.map(\.objectID))).sorted(),
                                      pids: Array(Set(members.map(\.pid))).sorted())
        }.sorted { $0.sourceID < $1.sourceID }
    }

    static func snapshot(excludingPIDs: Set<pid_t> = [getpid()]) throws -> [ProcessAudioSource] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var property = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size), "audio_process_list_size")
        guard size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(objects.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!)
        }, "audio_process_list")
        let apps = Dictionary(grouping: NSWorkspace.shared.runningApplications, by: { $0.processIdentifier })
        var observations: [ProcessAudioObservation] = []
        for object in objects {
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidProperty = address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(object, &pidProperty, 0, nil, &pidSize, &pid) == noErr,
                  pid > 0, !excludingPIDs.contains(pid) else { continue }
            var outputProperty = address(kAudioProcessPropertyIsRunningOutput)
            var outputActive:UInt32 = 0;var outputBytes=UInt32(MemoryLayout<UInt32>.size)
            let outputStatus=AudioObjectGetPropertyData(object,&outputProperty,0,nil,&outputBytes,&outputActive)
            // A failed inventory refresh must preserve existing taps. Only an
            // explicit false can remove a source as inactive.
            try check(outputStatus,"audio_process_activity_unavailable")
            if outputActive == 0 {continue}
            let ownership = owner(pid: pid, running: apps[pid]?.first)
            // All variants of the assistant, including a helper inside its app,
            // must be excluded before the unknown-source fallback.
            if ownership?.bundleID.hasPrefix("com.joesang.meeting-assistant") == true { continue }
            if executablePath(pid: pid).map({ isAssistantPath($0) }) == true { continue }
            observations.append(ProcessAudioObservation(pid: pid, objectID: object,
                                                         ownerBundleID: ownership?.bundleID,
                                                         ownerName: ownership?.name))
        }
        return group(observations)
    }

    private static func executablePath(pid: pid_t) -> String? {
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath().path
    }

    private static func isAssistantPath(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).pathComponents
        return components.contains {
            let normalized = $0.lowercased().replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
            return normalized.hasPrefix("meetingassistant") && normalized.hasSuffix(".app")
        }
    }

    private static func owner(pid: pid_t, running: NSRunningApplication?) -> (bundleID: String, name: String)? {
        let path = executablePath(pid: pid)
        if let running, let id = running.bundleIdentifier, !id.isEmpty,
           let url = running.bundleURL?.resolvingSymlinksInPath(),
           let path, path.hasPrefix(url.path + "/") {
            return (id, running.localizedName ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? id)
        }
        guard let path else { return nil }
        let components = URL(fileURLWithPath: path).pathComponents
        guard let appIndex = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        let appURL = URL(fileURLWithPath: NSString.path(withComponents: Array(components[...appIndex])))
        guard let bundle = Bundle(url: appURL), let id = bundle.bundleIdentifier, !id.isEmpty,
              FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/Info.plist").path) else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
                   bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ??
                   appURL.deletingPathExtension().lastPathComponent
        return (id, name)
    }
}

struct ProcessAudioRouteChange {
    let added: [ProcessAudioSource]
    let removed: [ProcessAudioSource]
    let changed: [ProcessAudioSource]
    var failed: [String: String] = [:]
    var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty && failed.isEmpty }
}

enum ProcessAudioRoutePlanner {
    static func reconcile(previous: [ProcessAudioSource], current: [ProcessAudioSource]) -> ProcessAudioRouteChange {
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.sourceID, $0) })
        let new = Dictionary(uniqueKeysWithValues: current.map { ($0.sourceID, $0) })
        return ProcessAudioRouteChange(
            added: current.filter { old[$0.sourceID] == nil },
            removed: previous.filter { new[$0.sourceID] == nil },
            changed: current.filter { item in
                guard let prior = old[item.sourceID] else { return false }
                return prior.audioObjectIDs != item.audioObjectIDs || prior.pids != item.pids ||
                       prior.applicationName != item.applicationName || prior.bundleID != item.bundleID
            })
    }
}

@available(macOS 14.2, *)
extension ApplicationTap {
    // This is the inclusive-process variant of ApplicationTap.start(bundle:).
    // Every source gets its own tap and Mailbox; no global/mixed PCM is routed
    // into an app track.
    func start(audioObjects: [AudioObjectID], sourceID: String, box: Mailbox) throws {
        guard !audioObjects.isEmpty else { throw Failure(code: "empty_audio_source") }
        let description = scopeDescription(global: false, ids: audioObjects)
        description.name = "在场：\(sourceID)"
        description.uuid = UUID()
        do {
            try check(AudioHardwareCreateProcessTap(description, &tap), "create_app_tap")
            var asbd = AudioStreamBasicDescription()
            var property = address(kAudioTapPropertyFormat)
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &asbd), "app_tap_format")
            let declaredTapSampleRate=asbd.mSampleRate
            var systemProperty = address(kAudioHardwarePropertyDefaultOutputDevice)
            var outputDevice: AudioObjectID = 0
            var outputSize = UInt32(MemoryLayout<AudioObjectID>.size)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &systemProperty, 0, nil, &outputSize, &outputDevice), "app_output_clock_device")
            outputClock = outputDevice
            var uidProperty = address(kAudioDevicePropertyDeviceUID)
            var outputUID: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            try check(AudioObjectGetPropertyData(outputDevice, &uidProperty, 0, nil, &uidSize, &outputUID), "app_output_clock_uid")
            guard let clockUID = outputUID?.takeRetainedValue() else { throw Failure(code: "app_missing_output_clock") }
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "在场临时私有设备",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: clockUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID, kAudioSubDeviceInputChannelsKey: 0]],
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "create_app_aggregate")
            let format=try applicationTapInputFormat(device:device)
            asbd=format.streamDescription.pointee;capturedInputFormat=format
            let converter=try PCMConverter(format)
            var formatClock=ApplicationTapClockCheck()
            let formatInfo:[String:Any]=["type":"capture_format","source_id":sourceID,"tap_sample_rate":declaredTapSampleRate,
                  "input_sample_rate":format.sampleRate,"input_channels":format.channelCount,
                  "input_bytes_per_frame":asbd.mBytesPerFrame]
            box.journal?.recordCaptureFormat(formatInfo)
            emit(formatInfo)
            try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, queue) { _, input, inputTime, _, _ in
                guard captureAdmissionOpen() else { return }
                guard formatClock.accepts(inputTime.pointee,sampleRate:format.sampleRate) else{box.fail("app_tap_input_clock_changed");return}
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = list.first, asbd.mBytesPerFrame > 0 else { box.fail("app_tap_empty_format"); return }
                let frames = AVAudioFrameCount(first.mDataByteSize / asbd.mBytesPerFrame)
                guard let copied = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { box.fail("app_tap_copy"); return }
                copied.frameLength = frames
                let target = UnsafeMutableAudioBufferListPointer(copied.mutableAudioBufferList)
                guard target.count == list.count else { box.fail("app_tap_channel_layout"); return }
                for (source, destination) in zip(list, target) {
                    guard source.mDataByteSize <= destination.mDataByteSize,
                          let from = source.mData, let to = destination.mData else { box.fail("app_tap_buffer_layout"); return }
                    memcpy(to, from, Int(source.mDataByteSize))
                }
                let stamp = inputTime.pointee.mFlags.contains(.hostTimeValid) ?
                    AVAudioTime.seconds(forHostTime: inputTime.pointee.mHostTime) : ProcessInfo.processInfo.systemUptime
                do { let data = try converter.convert(copied); if !data.isEmpty { _ = writeCapturedPCMIfAdmitted(data,at:stamp,to:box) } }
                catch { box.fail("app_tap_conversion") }
            }, "create_app_tap_io")
            try check(AudioDeviceStart(device, io), "start_app_tap")
        } catch {
            stop()
            throw error
        }
    }
}

// Call refresh periodically and on process/output-device changes. It is owned
// by the capture worker's serial context; callers must not refresh concurrently.
@available(macOS 14.2, *)
final class ProcessAudioSourceController {
    private var active: [String: (source: ProcessAudioSource, tap: ApplicationTap)] = [:]
    private var outputClock: AudioObjectID = 0

    var sources: [ProcessAudioSource] { active.values.map(\.source).sorted { $0.sourceID < $1.sourceID } }

    @discardableResult
    func refresh(boxForSource: (ProcessAudioSource) throws -> Mailbox) throws -> ProcessAudioRouteChange {
        let desired = try ProcessAudioInventory.snapshot(excludingPIDs: Set(selfAudioPIDs()))
        return try reconcile(desired, boxForSource: boxForSource)
    }

    @discardableResult
    func reconcile(_ desired: [ProcessAudioSource], boxForSource: (ProcessAudioSource) throws -> Mailbox) throws -> ProcessAudioRouteChange {
        let prior = sources
        var changes = ProcessAudioRoutePlanner.reconcile(previous: prior, current: desired)
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        var clock: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &clock), "source_default_output")
        let clockChanged = outputClock != 0 && outputClock != clock
        let currentIDs = Set(desired.map(\.sourceID))
        let changedIDs = Set(changes.changed.map(\.sourceID))
        for (id, entry) in active where !currentIDs.contains(id) || changedIDs.contains(id) || clockChanged || entry.tap.inputFormatChanged() {
            entry.tap.stop()
            active.removeValue(forKey: id)
        }
        for source in desired where active[source.sourceID] == nil {
            let box = try boxForSource(source)
            let tap = ApplicationTap()
            tap.selectedPIDs = source.pids
            do {
                try tap.start(audioObjects: source.audioObjectIDs, sourceID: source.sourceID, box: box)
                active[source.sourceID] = (source, tap)
            } catch {
                // A single unsupported/vanished process cannot starve the
                // other applications. Retain its journal for a later retry.
                tap.stop()
                changes.failed[source.sourceID] = (error as? Failure)?.code ?? "source_tap_failed"
            }
        }
        outputClock = clock
        return changes
    }

    func stop() {
        try? stopChecked()
    }

    func stopChecked() throws {
        var firstFailure:Error?
        for entry in active.values {
            do { try entry.tap.stopChecked() } catch { if firstFailure==nil { firstFailure=error } }
        }
        active.removeAll()
        outputClock = 0
        if let firstFailure { throw firstFailure }
    }
}

// No CoreAudio call is made by these regressions.
func processAudioSourceSyntheticChecks() -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ code: String) { if !condition { failures.append(code) } }
    let a = ProcessAudioObservation(pid: 101, objectID: 501, ownerBundleID: "com.example.alpha", ownerName: "Alice")
    let helper = ProcessAudioObservation(pid: 102, objectID: 502, ownerBundleID: "com.example.alpha", ownerName: "Alice")
    let unknown = ProcessAudioObservation(pid: 103, objectID: 503, ownerBundleID: nil, ownerName: nil)
    let other = ProcessAudioObservation(pid: 104, objectID: 504, ownerBundleID: "com.example.beta", ownerName: "Bob")
    let first = ProcessAudioInventory.group([a, helper, unknown, other])
    expect(first.count == 3, "group_count")
    expect(first.first(where: { $0.bundleID == "com.example.alpha" })?.audioObjectIDs == [501, 502], "verified_helper_group")
    expect(first.first(where: { $0.bundleID == nil })?.sourceID == ProcessAudioInventory.unknownSourceID, "unknown_fallback")
    expect(first.first(where: { $0.bundleID == "com.example.beta" })?.audioObjectIDs == [504], "separate_apps")
    expect(first.first(where: { $0.bundleID == nil })?.metadata["bundle_id"] == nil, "unknown_has_no_claimed_bundle")
    let changed = ProcessAudioInventory.group([a, unknown, other])
    let diff = ProcessAudioRoutePlanner.reconcile(previous: first, current: changed)
    expect(diff.changed.count == 1 && diff.changed[0].bundleID == "com.example.alpha", "process_exit_restarts_route")
    expect(diff.removed.isEmpty, "unknown_route_stable")
    let gone = ProcessAudioRoutePlanner.reconcile(previous: changed, current: [])
    expect(gone.removed.count == 3, "teardown_on_disappearance")
    expect(ProcessAudioInventory.sourceID(for: "com.example.alpha") == ProcessAudioInventory.sourceID(for: "com.example.alpha"), "source_id_stable")
    expect(ProcessAudioInventory.group([helper]).first?.sourceID == ProcessAudioInventory.group([a]).first?.sourceID, "source_id_survives_reappearance")
    expect(ProcessAudioInventory.sourceID(for: "com.example.alpha") != ProcessAudioInventory.sourceID(for: "com.example.beta"), "source_ids_distinct")
    return failures
}
