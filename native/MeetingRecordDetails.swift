import AppKit
import CoreFoundation
import Foundation

/// A display-only snapshot. Callers build it from already loaded meeting data;
/// constructing or presenting the panel never scans the cache on AppKit's thread.
struct MeetingRecordDetailsSnapshot {
    enum TranscriptionState: Equatable {
        case complete
        case live
        case paused(seconds: Double?)
        case processing
        case pending(seconds: Double?)
        case failed(String?)
        case recordingOnly
        case unknown

        var label: String {
            switch self {
            case .complete: return "转写已完成"
            case .live: return "实时转写中"
            case .paused(let seconds):
                guard let seconds, seconds.isFinite, seconds > 0 else { return "已暂停" }
                return "已暂停 · 待转 \(Self.duration(seconds))"
            case .processing: return "正在完成转写"
            case .pending(let seconds):
                guard let seconds, seconds.isFinite, seconds > 0 else { return "转写待处理" }
                return "转写待处理 · \(Self.duration(seconds))"
            case .failed(let reason): return reason.map { "转写异常 · \($0)" } ?? "转写异常"
            case .recordingOnly: return "仅录音 · 未转写"
            case .unknown: return "转写状态未记录"
            }
        }

        private static func duration(_ value: Double) -> String {
            let seconds = max(0, Int(value.rounded()))
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
    }

    enum AudioState: Equatable {
        case retained
        case retainedPartial
        case restorable
        case unavailable
        case unknown

        var label: String {
            switch self {
            case .retained: return "原音保留在本机"
            case .retainedPartial: return "原音保留，尾段未封存"
            case .restorable: return "原音已归档，可恢复"
            case .unavailable: return "原音不可用"
            case .unknown: return "原音状态未记录"
            }
        }
    }

    let title: String
    let startTime: Date?
    let durationSeconds: Double?
    let transcription: TranscriptionState
    let sources: [String]
    let audio: AudioState
    let recordingFolder: URL?
    /// nil means there was no persisted estimate. Explicit 0 is a recorded zero.
    let estimatedFeeYuan: Double?
    let feeNote: String?

    init(title: String, startTime: Date?, durationSeconds: Double?,
         transcription: TranscriptionState, sources: [String], audio: AudioState,
         recordingFolder: URL?, estimatedFeeYuan: Double?, feeNote: String? = nil) {
        self.title = title
        self.startTime = startTime
        self.durationSeconds = durationSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.transcription = transcription
        var uniqueSources: [String] = []
        for source in sources.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !source.isEmpty {
            if !uniqueSources.contains(source) { uniqueSources.append(source) }
        }
        self.sources = uniqueSources
        self.audio = audio
        self.recordingFolder = recordingFolder
        self.estimatedFeeYuan = estimatedFeeYuan.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.feeNote = feeNote
    }

    var displayedStartTime: String {
        guard let startTime else { return "开始时间未记录" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy年M月d日 HH:mm:ss"
        return formatter.string(from: startTime)
    }

    var displayedDuration: String {
        guard let durationSeconds else { return "录音时长未记录" }
        let seconds = Int(durationSeconds)
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    var displayedSources: String { sources.isEmpty ? "来源未记录" : sources.joined(separator: "、") }

    var displayedFee: String {
        guard let amount = estimatedFeeYuan else { return "费用未记录" }
        return "¥" + String(format: "%.2f", amount) + (feeNote.map { "（\($0)）" } ?? "")
    }
}

/// A small non-modal utility window so viewing details never blocks pause/stop.
final class MeetingRecordDetailsWindow: NSWindowController, NSWindowDelegate {
    private static var visibleController: MeetingRecordDetailsWindow?
    private let snapshot: MeetingRecordDetailsSnapshot

    private init(snapshot: MeetingRecordDetailsSnapshot) {
        self.snapshot = snapshot
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 330),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "会议详情"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
        let content = makeContent()
        let fitting = content.fittingSize
        let height = min(560, max(280, fitting.height))
        content.setFrameSize(NSSize(width: 460, height: max(height, fitting.height)))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: height))
        scroll.hasVerticalScroller = fitting.height > height
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = content
        panel.contentView = scroll
        panel.setContentSize(NSSize(width: 460, height: height))
    }

    required init?(coder: NSCoder) { return nil }

    @discardableResult
    static func present(_ snapshot: MeetingRecordDetailsSnapshot) -> MeetingRecordDetailsWindow {
        let controller = MeetingRecordDetailsWindow(snapshot: snapshot)
        visibleController?.close()
        visibleController = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.orderFrontRegardless()
        return controller
    }

    @discardableResult
    static func closeIfVisible(_ foreground: NSWindow?) -> Bool {
        guard let controller = visibleController,
              isDetailWindowForeground(foreground, detailsWindow: controller.window) else { return false }
        controller.close()
        return true
    }

    static func isDetailWindowForeground(_ foreground: AnyObject?, detailsWindow: AnyObject?) -> Bool {
        guard let foreground, let detailsWindow else { return false }
        return foreground === detailsWindow
    }

    func windowWillClose(_ notification: Notification) {
        if Self.visibleController === self { Self.visibleController = nil }
    }

    private func makeContent() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.distribution = .fill
        root.spacing = 13
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)

        let title = NSTextField(wrappingLabelWithString: snapshot.title)
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.textColor = .labelColor
        title.preferredMaxLayoutWidth = 412
        root.addArrangedSubview(title)

        addRow("开始", snapshot.displayedStartTime, to: root)
        addRow("时长", snapshot.displayedDuration, to: root)
        addRow("转写", snapshot.transcription.label, to: root)
        addRow("来源", snapshot.displayedSources, to: root)
        addRow("原音", snapshot.audio.label, to: root)
        addRow("费用", snapshot.displayedFee, to: root)

        if (snapshot.audio == .retained || snapshot.audio == .retainedPartial || snapshot.audio == .restorable), let folder = safeRecordingFolder(snapshot.recordingFolder) {
            let open = NSButton(title: "打开录音位置", target: self, action: #selector(openRecordingFolder))
            open.bezelStyle = .rounded
            open.keyEquivalent = "\r"
            open.identifier = NSUserInterfaceItemIdentifier(folder.path)
            root.addArrangedSubview(open)
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 420)
        ])
        return container
    }

    private func addRow(_ caption: String, _ value: String, to stack: NSStackView) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 14
        let key = NSTextField(labelWithString: caption)
        key.font = .systemFont(ofSize: 12, weight: .medium)
        key.textColor = .secondaryLabelColor
        key.setContentHuggingPriority(.required, for: .horizontal)
        key.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let text = NSTextField(wrappingLabelWithString: value)
        text.font = .systemFont(ofSize: 13)
        text.textColor = .labelColor
        text.preferredMaxLayoutWidth = 340
        row.addArrangedSubview(key)
        row.addArrangedSubview(text)
        row.widthAnchor.constraint(equalToConstant: 412).isActive = true
        stack.addArrangedSubview(row)
    }

    private func safeRecordingFolder(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        return url
    }

    @objc private func openRecordingFolder(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard safeRecordingFolder(url) != nil else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct MeetingRecordDetailsLiveState {
    let phase: RecordingPhase
    let elapsed: Double
    let feeEstimate: Double?
    let localOnly: Bool
    let transcriptionComplete: Bool
    let error: String?
}

private struct MeetingRecordDetailsManifest {
    let track: String
    let bytes: Int
    let pendingBytes: Int
    let ended: Bool
    let failure: Bool
    let audioCleaned: Bool
    let chunks: [[String: Any]]
}

fileprivate enum MeetingRecordDetailsReader {
    private static let metadataLimit = 512 * 1024
    private static let usageLimit = 256 * 1024
    private static let manifestLimit = 512 * 1024
    // A two-hour 16 kHz mono capture at 320 KB per PCM chunk is about 720 chunks.
    // 2,000 chunks and 512 KB leave headroom for manifest metadata.
    private static let maxChunks = 2_000

    static func snapshot(item: CachedMeeting?, title: String,
                         live: MeetingRecordDetailsLiveState?) throws -> MeetingRecordDetailsSnapshot {
        guard let item = item else {
            return MeetingRecordDetailsSnapshot(title: title, startTime: nil,
                durationSeconds: live?.elapsed, transcription: transcription(live: live, metadata: nil,
                    manifests: [], pendingBytes: nil), sources: [], audio: .unknown,
                recordingFolder: nil, estimatedFeeYuan: live?.localOnly == true ? 0 : live?.feeEstimate,
                feeNote: live?.localOnly == true ? "本地音频估算" : (live?.feeEstimate == nil ? nil : "音频估算"))
        }
        guard UUID(uuidString: item.id) != nil,
              item.directory.lastPathComponent == item.id,
              item.directory.path == item.directory.resolvingSymlinksInPath().path else {
            throw Failure(code: "record_details_cache_scope")
        }
        let directoryValues = try item.directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw Failure(code: "record_details_cache_directory")
        }

        let metadata = try readJSONObject(item.directory.appendingPathComponent("meeting.json"), limit: metadataLimit)
        let usage: [String: Any]?
        do { usage = try readJSONObject(item.directory.appendingPathComponent("session-usage.json"), limit: usageLimit) }
        catch { usage = ["schema": -1] } // Present but unreadable is unknown, never a fallback-to-zero.
        var transcriptManifests: [MeetingRecordDetailsManifest] = []
        var allManifests: [MeetingRecordDetailsManifest] = []
        for track in try meetingAudioTracks(in: item.directory, transcriptOnly: false) {
            guard let manifest = try readManifest(folder: item.directory, track: track) else { continue }
            allManifests.append(manifest)
            if isTranscriptAudioTrack(track) { transcriptManifests.append(manifest) }
        }

        let pending = transcriptManifests.reduce(0) { $0 + $1.pendingBytes }
        let duration = live.map { $0.elapsed } ?? item.durationSeconds
        let actualStart = MeetingAbsoluteTime(metadata?["absolute_clock"])?.date(0)
        let transcription = transcription(live: live, metadata: metadata,
            manifests: transcriptManifests, pendingBytes: pending)
        let sources = sourceLabels(metadata: metadata, manifests: allManifests)
        let (audioState, folderToOpen) = audioEvidence(item: item, manifests: allManifests)
        let persistedFee = feeFromUsage(usage)
        let localOnly = metadata?["capture_mode"] as? String == "local_only" && metadata?["upload_authorized"] as? Bool != true
        let fee: Double?
        switch persistedFee {
        case .recorded(let amount): fee = amount
        case .unknown: fee = nil
        case .absent: fee = localOnly ? 0 : live?.feeEstimate
        }
        return MeetingRecordDetailsSnapshot(title: item.customTitle ?? title,
            startTime: actualStart, durationSeconds: duration,
            transcription: transcription, sources: sources,
            audio: audioState, recordingFolder: folderToOpen,
            estimatedFeeYuan: fee,
            feeNote: fee == nil ? nil : (localOnly ? "本地音频估算" : "音频估算"))
    }

    private static func readJSONObject(_ url: URL, limit: Int) throws -> [String: Any]? {
        var statInfo = stat()
        guard lstat(url.path, &statInfo) == 0 else {
            if errno == ENOENT { return nil }
            throw Failure(code: "record_details_metadata_stat")
        }
        guard (statInfo.st_mode & S_IFMT) == S_IFREG,
              statInfo.st_size >= 0, statInfo.st_size <= limit else {
            throw Failure(code: "record_details_metadata_size")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(code: "record_details_metadata_invalid")
        }
        return value
    }

    private static func readManifest(folder: URL, track: String) throws -> MeetingRecordDetailsManifest? {
        guard isMeetingAudioTrack(track),
              track.range(of: "^[a-z0-9-]{1,64}$", options: .regularExpression) != nil else { return nil }
        guard let value = try readJSONObject(folder.appendingPathComponent(track + "-manifest.json"), limit: manifestLimit) else { return nil }
        guard value["schema"] as? Int == 1, value["track"] as? String == track,
              value["format"] as? String == "pcm_s16le",
              value["sample_rate"] as? Int == 16000, value["channels"] as? Int == 1,
              let bytes = value["written_bytes"] as? Int, bytes >= 0, bytes <= 512 * 1024 * 1024,
              let committed = value["asr_committed_bytes"] as? Int, committed >= 0, committed <= bytes else {
            throw Failure(code: "record_details_manifest_invalid")
        }
        let chunks = value["chunks"] as? [[String: Any]] ?? []
        guard chunks.count <= maxChunks else { throw Failure(code: "record_details_manifest_capacity") }
        return MeetingRecordDetailsManifest(track: track, bytes: bytes,
            pendingBytes: isTranscriptAudioTrack(track) ? bytes - committed : 0,
            ended: value["ended"] as? Bool == true,
            failure: value["error"] is String,
            audioCleaned: value["audio_cleaned"] as? Bool == true,
            chunks: chunks)
    }

    private static func transcription(live: MeetingRecordDetailsLiveState?, metadata: [String: Any]?,
                                      manifests: [MeetingRecordDetailsManifest], pendingBytes: Int?) -> MeetingRecordDetailsSnapshot.TranscriptionState {
        if live?.localOnly == true || (metadata?["capture_mode"] as? String == "local_only" && metadata?["upload_authorized"] as? Bool != true) {
            return .recordingOnly
        }
        if live?.phase == .failed || live?.error != nil || manifests.contains(where: { $0.failure }) { return .failed(nil) }
        let pending = pendingBytes ?? manifests.reduce(0) { $0 + $1.pendingBytes }
        let pendingSeconds = Double(pending) / 32_000
        if let live {
            switch live.phase {
            case .connecting, .recording: return .live
            case .paused: return .paused(seconds: pending > 0 ? pendingSeconds : nil)
            case .stopping: return .processing
            case .failed: return .failed(nil)
            case .stopped, .ended:
                if live.transcriptionComplete && pending == 0 { return .complete }
                if pending > 0 { return .pending(seconds: pendingSeconds) }
                if manifests.contains(where: { $0.failure || !$0.ended }) { return .failed(nil) }
                return !manifests.isEmpty && manifests.allSatisfy({ $0.ended && $0.pendingBytes == 0 }) ? .complete : .unknown
            case .idle: break
            }
        }
        guard !manifests.isEmpty else { return .unknown }
        if manifests.contains(where: { !$0.ended }) { return .failed("异常中断，已保存内容仍保留") }
        if pending > 0 { return .pending(seconds: pendingSeconds) }
        if manifests.allSatisfy({ $0.ended && !$0.failure && $0.pendingBytes == 0 }) { return .complete }
        return .unknown
    }

    private static func sourceLabels(metadata: [String: Any]?, manifests: [MeetingRecordDetailsManifest]) -> [String] {
        let usedTracks = manifests.filter { $0.bytes > 0 }.map(\.track)
        guard !usedTracks.isEmpty else { return [] }
        let rows = metadata?["audio_sources"] as? [[String: Any]] ?? []
        var labels: [String] = []
        for track in usedTracks {
            if audioSourceCoreID(track)=="mic" || track == "mic-raw" || track.hasPrefix("mic-raw-g") {
                labels.append("麦克风")
                continue
            }
            if track == "reference" || track.hasPrefix("reference-g") || track == "remote" || track.hasPrefix("remote-g") {
                let bundle = metadata?["bundle"] as? String
                if bundle == "com.tencent.meeting" { labels.append("腾讯会议") }
                else { labels.append("电脑声音") }
                continue
            }
            let core = audioSourceCoreID(track)
            let match = rows.first { row in
                let sourceID = row["source_id"] as? String ?? ""
                return sourceID == track || sourceID == core || applicationAudioCoreID(track) == sourceID
            }
            if let match {
                let label = audioSourceLabel(match)
                labels.append(label == "电脑声音" ? (match["application_name"] as? String ?? label) : label)
            } else {
                labels.append("电脑声音")
            }
        }
        var unique: [String] = []
        for label in labels where !unique.contains(label) { unique.append(label) }
        return unique
    }

    private static func audioEvidence(item: CachedMeeting,
                                      manifests: [MeetingRecordDetailsManifest]) -> (MeetingRecordDetailsSnapshot.AudioState, URL?) {
        guard !manifests.isEmpty else { return (.unknown, nil) }
        if manifests.allSatisfy({ !$0.audioCleaned }) {
            switch verifiedChunks(folder: item.directory, manifests: manifests) {
            case .complete: return (.retained, item.directory)
            case .partial: return (.retainedPartial, item.directory)
            case .invalid: return (.unknown, nil)
            }
        }

        let receiptURL = item.directory.appendingPathComponent("audio-retirement.json")
        guard let receipt = try? readJSONObject(receiptURL, limit: 64 * 1024),
              receipt["schema"] as? Int == 1, receipt["cache_id"] as? String == item.id,
              receipt["recoverable"] as? Bool == true,
              let state = receipt["state"] as? String, ["trashed", "restored"].contains(state),
              let tracks = receipt["tracks"] as? [String], !tracks.isEmpty,
              Set(tracks).count == tracks.count,
              tracks.allSatisfy({ track in isMeetingAudioTrack(track) && manifests.contains(where: { $0.track == track }) }) else {
            let anySavedManifest = manifests.contains { !$0.audioCleaned }
            return (anySavedManifest ? .unknown : .unavailable, nil)
        }
        let retiredBase = item.directory.deletingLastPathComponent().appendingPathComponent(".retired", isDirectory: true)
        guard let rawDestination = receipt["destination"] as? String else { return (.unknown, nil) }
        let destination = URL(fileURLWithPath: rawDestination, isDirectory: true).standardizedFileURL
        guard destination.deletingLastPathComponent().path == retiredBase.standardizedFileURL.path,
              destination.lastPathComponent == item.id,
              destination.path == destination.resolvingSymlinksInPath().path else { return (.unknown, nil) }
        let retiredManifests = manifests.filter { tracks.contains($0.track) }
        guard retiredManifests.count == tracks.count else { return (.unknown, nil) }
        if state == "restored" {
            guard receipt["keep_audio"] as? Bool == true,
                  receipt["restored_destination"] as? String == item.directory.path else { return (.unknown, nil) }
            switch verifiedChunks(folder: item.directory, manifests: retiredManifests) {
            case .complete: return (.retained, item.directory)
            case .partial: return (.retainedPartial, item.directory)
            case .invalid: return (.unknown, nil)
            }
        }
        guard directoryExistsWithoutSymlink(destination) else { return (.unknown, nil) }
        switch verifiedChunks(folder: destination, manifests: retiredManifests) {
        case .complete: return (.restorable, destination)
        case .partial: return (.retainedPartial, destination)
        case .invalid: return (.unknown, nil)
        }
    }

    private static func directoryExistsWithoutSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// Verifies names and sizes from manifests with lstat/resource metadata only;
    /// audio payload bytes are never opened or read.
    private enum ChunkVerification { case complete, partial, invalid }

    private static func verifiedChunks(folder: URL, manifests: [MeetingRecordDetailsManifest]) -> ChunkVerification {
        guard !manifests.isEmpty, directoryExistsWithoutSymlink(folder) else { return .invalid }
        var any = false
        var hasPartialTail = false
        for manifest in manifests {
            guard manifest.bytes >= 0, manifest.bytes <= 512 * 1024 * 1024 else { return .invalid }
            if manifest.chunks.isEmpty {
                guard manifest.bytes == 0 else { return .invalid }
                continue
            }
            var total = 0
            for (index, chunk) in manifest.chunks.enumerated() {
                guard chunk["index"] as? Int == index,
                      let size = chunk["bytes"] as? Int, size >= 0, size <= 320_000, size % 2 == 0,
                      let start = chunk["start_sample"] as? Int, start == total / 2 else { return .invalid }
                let filename = String(format: "%@-%06d.pcm", manifest.track, index)
                let file = folder.appendingPathComponent(filename)
                var fileStat = stat()
                guard lstat(file.path, &fileStat) == 0,
                      (fileStat.st_mode & S_IFMT) == S_IFREG,
                      fileStat.st_size >= 0 else { return .invalid }
                let actualSize = Int(fileStat.st_size)
                let isLast = index == manifest.chunks.count - 1
                if actualSize == size {
                    guard size > 0 else { return .invalid }
                } else if isLast && !manifest.ended {
                    // An unsealed final write may have reached disk after the last
                    // manifest update. Accept only a bounded, even PCM tail.
                    guard actualSize >= size, actualSize <= 320_000, actualSize % 2 == 0,
                          (size > 0 || actualSize > 0) else { return .invalid }
                    if actualSize > size { hasPartialTail = true }
                } else {
                    return .invalid
                }
                total += size
                if actualSize > 0 { any = true }
            }
            guard total == manifest.bytes else { return .invalid }
        }
        guard any else { return .invalid }
        return hasPartialTail ? .partial : .complete
    }

    private enum FeeEvidence { case recorded(Double), unknown, absent }

    private static func feeFromUsage(_ usage: [String: Any]?) -> FeeEvidence {
        guard let usage else { return .absent }
        let meter = usage["meter"] as? [String: Any]
        if usage["schema"] as? Int == 2 {
            guard let value = usage["cumulative_estimated_yuan"] else { return .unknown }
            return value is NSNull ? .unknown : feeAmount(value).map(FeeEvidence.recorded) ?? .unknown
        }
        guard usage["schema"] as? Int == 1 else { return .unknown }
        if usage["cumulative_input_audio_seconds"] != nil {
            guard let cumulativeSeconds = feeAmount(usage["cumulative_input_audio_seconds"]),
                  let meterSeconds = feeAmount(meter?["input_audio_seconds"]),
                  abs(cumulativeSeconds - meterSeconds) <= 0.000_001 else { return .unknown }
        }
        // A schema-1 file without a cumulative counter describes one run, so its
        // last meter value is still the full amount for that session.
        guard let amount = feeAmount(meter?["estimated_yuan"]) else { return .unknown }
        return .recorded(amount)
    }

    private static func feeAmount(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let amount = number.doubleValue
            return amount.isFinite && amount >= 0 ? amount : nil
        }
        if let string = value as? String, let amount = Double(string), amount.isFinite, amount >= 0 {
            return amount
        }
        return nil
    }

    static func offlineSnapshot(item: CachedMeeting, title: String) throws -> MeetingRecordDetailsSnapshot {
        try snapshot(item: item, title: title, live: nil)
    }
}

extension Delegate {
    @objc func loadRecordDetails() {
        let cacheID = currentCacheID
        let liveMode = !isHistoryReader &&
            [.connecting, .recording, .paused, .stopping].contains(phase.phase)
        let selected = liveMode ? nil : selectedRecovery()
        let cached = cacheID.flatMap { id in
            recoveries.first { $0.id == id } ?? libraryVisible.first { $0.id == id } ??
                workspaceOwner?.recoveries.first { $0.id == id } ?? workspaceOwner?.libraryVisible.first { $0.id == id }
        } ?? (cacheID == nil ? selected : nil)
        let live: MeetingRecordDetailsLiveState? = liveMode ? MeetingRecordDetailsLiveState(
            phase: phase.phase, elapsed: phase.elapsed,
            feeEstimate: (!sessionLocalOnly && phase.estimated > 0 && phase.estimated.isFinite) ? phase.estimated : nil,
            localOnly: sessionLocalOnly || localOnlyMode, transcriptionComplete: cachedTranscriptionComplete,
            error: phase.error) : nil
        let fallbackTitle = meetingTitle == "新会议" ? "会议详情" : meetingTitle
        let base = recoveryBase()
        recordDetailsJob.run(work: {
            var item = cached
            if item == nil, let cacheID, UUID(uuidString: cacheID) != nil {
                item = try cachedMeetings(in: base).first { $0.id == cacheID }
            }
            return try MeetingRecordDetailsReader.snapshot(item: item, title: fallbackTitle, live: live)
        }) { [weak self] result in
            guard let self, self.currentCacheID == cacheID else { return }
            switch result {
            case .success(let snapshot):
                MeetingRecordDetailsWindow.present(snapshot)
            case .failure:
                self.diagnostic.stringValue = "无法读取会议详情；录音控制不受影响"
            }
        }
    }
}

/// Offline regression checks for the display contract; no AppKit window,
/// cache, recording, network, or account access is involved.
func meetingRecordDetailsChecks() throws -> Int {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw Failure(code: "meeting_record_details_\(name)") }
        checks += 1
    }

    let missing = MeetingRecordDetailsSnapshot(title: "测试会议", startTime: nil,
        durationSeconds: nil, transcription: .unknown, sources: [], audio: .unknown,
        recordingFolder: nil, estimatedFeeYuan: nil)
    try check(missing.displayedStartTime == "开始时间未记录", "missing_start_is_not_guessed")
    try check(missing.displayedDuration == "录音时长未记录", "missing_duration_is_not_guessed")
    try check(missing.displayedFee == "费用未记录", "missing_fee_is_not_zero")
    try check(missing.transcription.label == "转写状态未记录", "unknown_transcription_is_explicit")

    let zero = MeetingRecordDetailsSnapshot(title: "测试会议", startTime: Date(timeIntervalSince1970: 1_791_216_000),
        durationSeconds: 65, transcription: .complete, sources: ["麦克风", "腾讯会议", "麦克风"],
        audio: .retained, recordingFolder: nil, estimatedFeeYuan: 0)
    try check(zero.displayedDuration == "00:01:05", "duration_format")
    let truncatedDuration = MeetingRecordDetailsSnapshot(title: "测试会议", startTime: nil,
        durationSeconds: 7 * 60 + 24.9, transcription: .unknown, sources: [], audio: .unknown,
        recordingFolder: nil, estimatedFeeYuan: nil)
    try check(truncatedDuration.displayedDuration == "00:07:24", "duration_truncates_to_whole_seconds")
    try check(zero.displayedFee == "¥0.00", "explicit_zero_fee_is_preserved")
    try check(zero.sources == ["麦克风", "腾讯会议"], "sources_are_deduplicated_in_order")
    try check(MeetingRecordDetailsSnapshot.TranscriptionState.recordingOnly.label == "仅录音 · 未转写", "local_only_never_implies_transcription")
    try check(MeetingRecordDetailsSnapshot.TranscriptionState.pending(seconds: 62).label == "转写待处理 · 01:02", "pending_transcription_is_visible")
    let localZero = MeetingRecordDetailsSnapshot(title: "本地会议", startTime: nil, durationSeconds: 2,
        transcription: .recordingOnly, sources: ["麦克风"], audio: .retained,
        recordingFolder: nil, estimatedFeeYuan: 0, feeNote: "本地音频估算")
    try check(localZero.displayedFee == "¥0.00（本地音频估算）", "explicit_local_zero_is_annotated")
    checks += 1
    let unrelatedWindow = NSObject(), detailsWindow = NSObject()
    try check(!MeetingRecordDetailsWindow.isDetailWindowForeground(unrelatedWindow, detailsWindow: detailsWindow), "command_w_does_not_close_background_details")
    try check(MeetingRecordDetailsWindow.isDetailWindowForeground(detailsWindow, detailsWindow: detailsWindow), "command_w_closes_focused_details")

    let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-details-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }
    func writeJSON(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
    }
    func manifest(_ track: String, cleaned: Bool = false) -> [String: Any] {
        ["schema": 1, "track": track, "format": "pcm_s16le", "sample_rate": 16000, "channels": 1,
         "written_bytes": 4, "asr_committed_bytes": 4, "ended": true, "error": NSNull(),
         "audio_cleaned": cleaned, "chunks": [["index": 0, "start_sample": 0, "bytes": 4, "sha256": "fixture"]]]
    }
    let recordedID = UUID().uuidString
    let recorded = fixtureRoot.appendingPathComponent(recordedID, isDirectory: true)
    try FileManager.default.createDirectory(at: recorded, withIntermediateDirectories: true)
    for track in ["mic", "remote"] {
        try Data([1, 2, 3, 4]).write(to: recorded.appendingPathComponent(track + "-000000.pcm"))
        try writeJSON(manifest(track), to: recorded.appendingPathComponent(track + "-manifest.json"))
    }
    let startEpoch = 1_791_216_000.0
    try writeJSON(["schema": 1, "capture_mode": "cloud", "bundle": "com.tencent.meeting",
        "absolute_clock": ["schema": 1, "basis": "capture_clock", "time_zone": "Asia/Shanghai",
                            "anchors": [["relative_start": 0.0, "unix_time": startEpoch]]],
        "audio_sources": [["source_id": "mic", "application_name": "我的麦克风"]]],
        to: recorded.appendingPathComponent("meeting.json"))
    try writeJSON(["schema": 1, "cumulative_input_audio_seconds": "2.0",
        "meter": ["input_audio_seconds": "2.0", "estimated_yuan": "0.17"]],
        to: recorded.appendingPathComponent("session-usage.json"))
    let item = CachedMeeting(id: recordedID, directory: recorded, date: .distantPast,
        writtenBytes: 8, pendingBytes: 0, occupiedBytes: 8, tracks: ["mic", "remote"],
        audioCleaned: false, warning: false, retiredBytes: 0, durationSeconds: 2)
    let evidence = try MeetingRecordDetailsReader.offlineSnapshot(item: item, title: "合成会议")
    try check(evidence.startTime?.timeIntervalSince1970 == startEpoch, "capture_clock_drives_start_date")
    try check(evidence.transcription == .complete, "manifests_drive_complete_status")
    try check(evidence.audio == .retained && evidence.recordingFolder == recorded, "retained_audio_requires_real_chunk_files")
    try check(evidence.sources == ["麦克风", "腾讯会议"], "source_names_come_from_meeting_metadata_and_tracks")
    try check(evidence.estimatedFeeYuan == 0.17, "schema1_fee_requires_matching_cumulative_meter")
    checks += 5
    try FileManager.default.removeItem(at: recorded.appendingPathComponent("remote-000000.pcm"))
    let missingChunk = try MeetingRecordDetailsReader.offlineSnapshot(item: item, title: "合成会议")
    try check(missingChunk.audio == .unknown && missingChunk.recordingFolder == nil,
              "missing_retained_chunk_is_not_reported_as_saved")
    try Data([1, 2, 3, 4]).write(to: recorded.appendingPathComponent("remote-000000.pcm"))
    checks += 1

    let partialID = UUID().uuidString
    let partialFolder = fixtureRoot.appendingPathComponent(partialID, isDirectory: true)
    try FileManager.default.createDirectory(at: partialFolder, withIntermediateDirectories: true)
    try Data([1, 2, 3, 4]).write(to: partialFolder.appendingPathComponent("mic-000000.pcm"))
    try Data([5, 6, 7, 8, 9, 10, 11, 12]).write(to: partialFolder.appendingPathComponent("mic-000001.pcm"))
    var partialManifest: [String: Any] = [
        "schema": 1, "track": "mic", "format": "pcm_s16le", "sample_rate": 16000, "channels": 1,
        "written_bytes": 4, "asr_committed_bytes": 4, "ended": false, "error": NSNull(),
        "audio_cleaned": false,
        "chunks": [["index": 0, "start_sample": 0, "bytes": 4, "sha256": "fixture"],
                    ["index": 1, "start_sample": 2, "bytes": 0, "sha256": "fixture"]]
    ]
    try writeJSON(partialManifest, to: partialFolder.appendingPathComponent("mic-manifest.json"))
    try writeJSON(["schema": 1, "capture_mode": "local_only"], to: partialFolder.appendingPathComponent("meeting.json"))
    let partialItem = CachedMeeting(id: partialID, directory: partialFolder, date: .distantPast,
        writtenBytes: 4, pendingBytes: 0, occupiedBytes: 12, tracks: ["mic"],
        audioCleaned: false, warning: true, retiredBytes: 0, durationSeconds: 2)
    let partialEvidence = try MeetingRecordDetailsReader.offlineSnapshot(item: partialItem, title: "尾段合成会议")
    try check(partialEvidence.audio == .retainedPartial && partialEvidence.recordingFolder == partialFolder,
              "unsealed_final_chunk_with_zero_manifest_bytes_is_reported_partial")
    partialManifest["chunks"] = [["index": 0, "start_sample": 0, "bytes": 4, "sha256": "fixture"],
                                  ["index": 2, "start_sample": 2, "bytes": 0, "sha256": "fixture"]]
    try writeJSON(partialManifest, to: partialFolder.appendingPathComponent("mic-manifest.json"))
    let badIndexEvidence = try MeetingRecordDetailsReader.offlineSnapshot(item: partialItem, title: "尾段合成会议")
    try check(badIndexEvidence.audio == .unknown && badIndexEvidence.recordingFolder == nil,
              "partial_tail_does_not_excuse_bad_chunk_index")
    partialManifest["chunks"] = [["index": 0, "start_sample": 0, "bytes": 4, "sha256": "fixture"],
                                  ["index": 1, "start_sample": 2, "bytes": 0, "sha256": "fixture"]]
    try writeJSON(partialManifest, to: partialFolder.appendingPathComponent("mic-manifest.json"))
    try Data([5, 6, 7, 8, 9, 10, 11]).write(to: partialFolder.appendingPathComponent("mic-000001.pcm"))
    let oddTailEvidence = try MeetingRecordDetailsReader.offlineSnapshot(item: partialItem, title: "尾段合成会议")
    try check(oddTailEvidence.audio == .unknown && oddTailEvidence.recordingFolder == nil,
              "odd_pcm_tail_is_not_reported_as_retained")
    checks += 3

    try writeJSON(["schema": 1, "cumulative_input_audio_seconds": "8.0",
        "meter": ["input_audio_seconds": "2.0", "estimated_yuan": "0.17"]],
        to: recorded.appendingPathComponent("session-usage.json"))
    let untrustedFee = try MeetingRecordDetailsReader.offlineSnapshot(item: item, title: "合成会议")
    try check(untrustedFee.estimatedFeeYuan == nil, "schema1_recent_run_fee_is_not_cumulative")
    checks += 1

    try writeJSON(["schema": 2, "cumulative_estimated_yuan": "0.23",
        "cumulative_input_audio_seconds": "4.0"], to: recorded.appendingPathComponent("session-usage.json"))
    let schemaTwoFee = try MeetingRecordDetailsReader.offlineSnapshot(item: item, title: "合成会议")
    try check(schemaTwoFee.estimatedFeeYuan == 0.23, "schema2_reads_cumulative_fee_string")
    try writeJSON(["schema": 2, "cumulative_estimated_yuan": true], to: recorded.appendingPathComponent("session-usage.json"))
    let booleanFee = try MeetingRecordDetailsReader.offlineSnapshot(item: item, title: "合成会议")
    try check(booleanFee.estimatedFeeYuan == nil, "boolean_is_not_a_fee_amount")
    checks += 2

    let retiredID = UUID().uuidString
    let retiredMeeting = fixtureRoot.appendingPathComponent(retiredID, isDirectory: true)
    let retiredBase = fixtureRoot.appendingPathComponent(".retired", isDirectory: true)
    let retiredPayload = retiredBase.appendingPathComponent(retiredID, isDirectory: true)
    try FileManager.default.createDirectory(at: retiredMeeting, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: retiredPayload, withIntermediateDirectories: true)
    try writeJSON(manifest("mic", cleaned: true), to: retiredMeeting.appendingPathComponent("mic-manifest.json"))
    try Data([1, 2, 3, 4]).write(to: retiredPayload.appendingPathComponent("mic-000000.pcm"))
    try writeJSON(["schema": 1, "cache_id": retiredID, "state": "trashed", "recoverable": true,
                   "destination": retiredPayload.path, "tracks": ["mic"], "audio_bytes": 4],
                  to: retiredMeeting.appendingPathComponent("audio-retirement.json"))
    try writeJSON(["schema": 1, "capture_mode": "local_only"], to: retiredMeeting.appendingPathComponent("meeting.json"))
    let retiredItem = CachedMeeting(id: retiredID, directory: retiredMeeting, date: .distantPast,
        writtenBytes: 4, pendingBytes: 4, occupiedBytes: 4, tracks: ["mic"],
        audioCleaned: true, warning: false, retiredBytes: 4)
    let retiredEvidence = try MeetingRecordDetailsReader.offlineSnapshot(item: retiredItem, title: "合成会议")
    try check(retiredEvidence.audio == .restorable && retiredEvidence.recordingFolder == retiredPayload,
              "restorable_audio_requires_valid_receipt_and_archived_chunks")
    try check(retiredEvidence.displayedFee == "¥0.00（本地音频估算）", "local_only_without_cloud_cost_shows_annotated_zero")
    checks += 2

    try writeJSON(["schema": 1, "cache_id": retiredID, "state": "trashed", "recoverable": false,
                   "destination": retiredPayload.path, "tracks": ["mic"], "audio_bytes": 4],
                  to: retiredMeeting.appendingPathComponent("audio-retirement.json"))
    let invalidReceipt = try MeetingRecordDetailsReader.offlineSnapshot(item: retiredItem, title: "合成会议")
    try check(invalidReceipt.audio == .unavailable && invalidReceipt.recordingFolder == nil,
              "audio_cleaned_does_not_mean_restorable")
    checks += 1
    return checks
}
