import Foundation
import AppKit
import CryptoKit
import Vision
import ImageIO
import UniformTypeIdentifiers

struct MeetingNoteAnchor: Codable, Equatable {
    var clock = "capture"
    var relative: Double
    var state: String
    static func capture(_ absolute: MeetingAbsoluteTime?, now: Double, paused: Double? = nil) -> Self? {
        guard let latest = absolute?.anchors.last else { return nil }
        let value = paused ?? (latest.relative + now - latest.unix)
        guard value.isFinite, value >= 0 else { return nil }
        return Self(relative: value, state: paused == nil ? "recording" : "paused")
    }
}
struct MeetingNoteImage: Codable, Equatable {
    var sha256: String
    var file: String
    var w: Int
    var h: Int
    var bytes: Int
}
struct MeetingNote: Codable, Equatable {
    var schema = 1
    var op = "create"
    var note_id = UUID().uuidString
    var rev = 1
    var at_unix = Date().timeIntervalSince1970
    var anchor: MeetingNoteAnchor?
    var text = ""
    var images: [MeetingNoteImage] = []
    var starred = false
    var archive = true
    // Explicit null is part of the event contract for after-meeting notes.
    enum CodingKeys: String, CodingKey { case schema, op, note_id, rev, at_unix, anchor, text, images, starred, archive }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema); try c.encode(op, forKey: .op)
        try c.encode(note_id, forKey: .note_id); try c.encode(rev, forKey: .rev)
        try c.encode(at_unix, forKey: .at_unix); try c.encode(anchor, forKey: .anchor)
        try c.encode(text, forKey: .text); try c.encode(images, forKey: .images)
        try c.encode(starred, forKey: .starred); try c.encode(archive, forKey: .archive)
    }
}
struct MeetingNotesSnapshot {
    var events: [MeetingNote] = []
    var latest: [MeetingNote] {
        var values: [String: MeetingNote] = [:], order: [String] = []
        for event in events {
            if values[event.note_id] == nil { order.append(event.note_id) }
            values[event.note_id] = event
        }
        return order.compactMap { values[$0] }
    }
    var visible: [MeetingNote] { latest.filter { $0.op != "delete" } }
}

// One serial writer across live/history readers of the same cache. Constructing
// or reading a store is side-effect free, including meetings without notes.
final class MeetingNotesStore {
    static let queue = DispatchQueue(label: "meeting.notes.writes", qos: .userInitiated)
    // Derived OCR never occupies the durable-write lane or the quit barrier.
    private static let ocrQueue = DispatchQueue(label: "meeting.notes.ocr", qos: .utility)
    let ocrTasks = DispatchGroup() // Bounded waits are used by offline checks only.
    let directory: URL
    let notes: URL
    var recognize: (Data) throws -> String = MeetingNotesStore.visionText
    init(directory: URL) {
        self.directory = directory.standardizedFileURL
        notes = self.directory.appendingPathComponent("notes", isDirectory: true)
    }
    static func exportMeetingFiles(_ target: CachedMeeting, to folder: URL) throws {
        try queue.sync {
            let clock = MeetingAbsoluteTime(try target.metadata()["absolute_clock"])
            try MeetingNotesStore(directory: target.directory).export(to: folder, absolute: clock)
        }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func safe(_ url: URL) throws {
        // Foundation normalizes existing /private/tmp paths differently from
        // not-yet-created children. Compare the two OS aliases consistently.
        func scopePath(_ value:URL)->String {
            let path=value.standardizedFileURL.path
            for prefix in ["/private/tmp", "/private/var"] {
                if path==prefix || path.hasPrefix(prefix+"/") {return String(path.dropFirst(8))}
            }
            return path
        }
        let path=scopePath(url),base=scopePath(directory)
        guard path == base || path.hasPrefix(base + "/") else { throw Failure(code: "notes_path_scope") }
        var part = url.standardizedFileURL
        while part.path != "/" {
            if let type = try? FileManager.default.attributesOfItem(atPath: part.path)[.type], type as? FileAttributeType == .typeSymbolicLink {
                let target=(try? FileManager.default.destinationOfSymbolicLink(atPath:part.path)) ?? ""
                let systemAlias=["/tmp","/var"].contains(part.path) && ["/private"+part.path,"private"+part.path].contains(target)
                if !systemAlias {throw Failure(code:"notes_symlink")}
            }
            part.deleteLastPathComponent()
        }
    }
    private func ensure(_ url: URL) throws {
        try safe(url)
        if FileManager.default.fileExists(atPath: url.path) {
            guard (try FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeDirectory else { throw Failure(code: "notes_not_directory") }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private func write(_ data: Data, to url: URL) throws {
        try safe(url)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func snapshot() throws -> MeetingNotesSnapshot {
        let file = notes.appendingPathComponent("notes.jsonl"); try safe(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return MeetingNotesSnapshot() }
        let data = try Data(contentsOf: file)
        var events: [MeetingNote] = [], revisions: [String: Int] = [:]
        for line in data.split(separator: 10) {
            // A crash may leave a partial final write; keep the bytes as evidence.
            // Subsequent append starts a fresh line, never overwrites that evidence.
            guard let event = try? JSONDecoder().decode(MeetingNote.self, from: Data(line)) else {
                if line.last != 125 { continue }
                throw Failure(code: "notes_invalid_event")
            }
            guard event.schema == 1, UUID(uuidString: event.note_id) != nil,
                  ["create", "edit", "delete", "restore"].contains(event.op),
                  event.rev == (revisions[event.note_id] ?? 0) + 1 else { throw Failure(code: "notes_invalid_revision") }
            revisions[event.note_id] = event.rev; events.append(event)
        }
        return MeetingNotesSnapshot(events: events)
    }
    private func append(_ note: MeetingNote) throws {
        try ensure(notes)
        let file = notes.appendingPathComponent("notes.jsonl"); try safe(file)
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure(code: "notes_create_failed") }
        }
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        let old = try Data(contentsOf: file)
        try handle.seekToEnd()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if !old.isEmpty && old.last != 10 { try handle.write(contentsOf: Data([10])) }
        try handle.write(contentsOf: encoder.encode(note) + Data([10])); try handle.synchronize()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    @discardableResult func create(text: String = "", images: [Data] = [], starred: Bool = false, anchor: MeetingNoteAnchor?, id: String = UUID().uuidString, imageReferences: [MeetingNoteImage] = []) throws -> MeetingNote {
        guard UUID(uuidString: id) != nil, try !snapshot().latest.contains(where: { $0.note_id == id }) else { throw Failure(code: "notes_duplicate_or_invalid_id") }
        let text = text.replacingOccurrences(of: "\u{fffc}", with: "")
        var note = MeetingNote(anchor: anchor, text: text, starred: starred)
        note.note_id = id
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !imageReferences.isEmpty || starred else { throw Failure(code: "notes_empty") }
        for data in images { note.images.append(try importImage(data)) }
        for image in imageReferences { _ = try imageData(image); note.images.append(image) }
        try append(note)
        let recognize = self.recognize
        for image in note.images {
            Self.ocrQueue.async(group: ocrTasks) { self.tryOCR(image, recognize: recognize) }
        }
        return note
    }
    @discardableResult func change(_ id: String, op: String = "edit", text: String? = nil, starred: Bool? = nil, archive: Bool? = nil, images: [Data]? = nil, imageReferences: [MeetingNoteImage]? = nil) throws -> MeetingNote {
        guard images == nil || imageReferences == nil else { throw Failure(code: "notes_conflicting_images") }
        guard var note = try snapshot().latest.first(where: { $0.note_id == id }),
              ["edit", "delete", "restore"].contains(op),
              (op == "restore" ? note.op == "delete" : note.op != "delete") else { throw Failure(code: "notes_missing") }
        note.op = op; note.rev += 1; note.at_unix = Date().timeIntervalSince1970
        if let text { note.text = text }; if let starred { note.starred = starred }; if let archive { note.archive = archive }
        note.text = note.text.replacingOccurrences(of: "\u{fffc}", with: "")
        if let images { note.images = try images.map { try importImage($0) } }
        if let imageReferences { for image in imageReferences { _ = try imageData(image) }; note.images = imageReferences }
        try append(note)
        if images != nil || imageReferences != nil {
            let recognize = self.recognize
            for image in note.images { Self.ocrQueue.async(group: ocrTasks) { self.tryOCR(image, recognize: recognize) } }
        }
        return note
    }
    func draft() throws -> String {
        let file = notes.appendingPathComponent("draft.json"); try safe(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))["text"] ?? ""
    }
    func saveDraft(_ text: String) throws {
        if text.isEmpty && !FileManager.default.fileExists(atPath: notes.path) { return }
        try ensure(notes); try write(JSONEncoder().encode(["text": text]), to: notes.appendingPathComponent("draft.json"))
    }
    // Import on the write queue before handing a preview to AppKit. The returned
    // reference, rather than NSTextAttachment's regenerated bytes, is durable.
    func importImage(_ input: Data) throws -> MeetingNoteImage {
        guard !input.isEmpty, input.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(input as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 30000, h <= 30000, w * h <= 100_000_000 else { throw Failure(code: "notes_invalid_image_or_20mb_limit") }
        var data = input; var ext = type == UTType.jpeg.identifier ? "jpg" : "png"
        if type != UTType.png.identifier && type != UTType.jpeg.identifier {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(code: "notes_image_decode") }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw Failure(code: "notes_image_encode") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw Failure(code: "notes_image_encode") }
            data = output as Data; ext = "png"
        }
        guard data.count <= 20 * 1024 * 1024 else { throw Failure(code: "notes_image_20mb_limit") }
        try ensure(notes); let assets = notes.appendingPathComponent("assets"); try ensure(assets)
        let sha = Self.hash(data), file = "assets/\(sha).\(ext)", target = notes.appendingPathComponent(file)
        try safe(target)
        if !FileManager.default.fileExists(atPath: target.path) { try write(data, to: target) }
        return MeetingNoteImage(sha256: sha, file: file, w: w, h: h, bytes: data.count)
    }
    func imageData(_ image: MeetingNoteImage) throws -> Data {
        guard image.sha256.count == 64, image.sha256.allSatisfy({ $0.isHexDigit }),
              ["assets/\(image.sha256).png", "assets/\(image.sha256).jpg"].contains(image.file) else { throw Failure(code: "notes_image_path") }
        let file = notes.appendingPathComponent(image.file); try safe(file)
        let data = try Data(contentsOf: file)
        guard Self.hash(data) == image.sha256 else { throw Failure(code: "notes_image_hash") }
        return data
    }
    private func tryOCR(_ image: MeetingNoteImage, recognize: (Data) throws -> String) {
        do {
            let folder = notes.appendingPathComponent("ocr"), file = folder.appendingPathComponent(image.sha256 + ".json")
            try safe(file)
            if FileManager.default.fileExists(atPath: file.path) { return }
            let text = try recognize(imageData(image))
            // A meeting may have moved to the recycle bin during recognition.
            // Do not recreate its source directories after that move.
            _ = try imageData(image)
            try ensure(folder)
            try write(JSONSerialization.data(withJSONObject: ["sha256": image.sha256, "text": text, "langs": ["zh-Hans", "en"], "engine": "apple-vision"], options: [.sortedKeys]), to: file)
        } catch { /* OCR is derived; a failure never invalidates the saved note. */ }
    }
    static func visionText(_ data: Data) throws -> String {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en"]; request.usesLanguageCorrection = true
        try VNImageRequestHandler(data: data).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    // Keep the existing export layout, including legacy notes, without UI flags.
    func export(to folder: URL, absolute: MeetingAbsoluteTime?) throws {
        let items = try snapshot().visible
        let export = folder.appendingPathComponent("会中笔记.md")
        guard !items.isEmpty || FileManager.default.fileExists(atPath: export.path) else { return }
        guard folder.standardizedFileURL == folder.resolvingSymlinksInPath().standardizedFileURL else { throw Failure(code: "notes_export_symlink") }
        let assets = folder.appendingPathComponent("会中笔记.assets")
        for target in [folder, export, assets] {
            if let type = try? FileManager.default.attributesOfItem(atPath: target.path)[.type], type as? FileAttributeType == .typeSymbolicLink { throw Failure(code: "notes_export_symlink") }
        }
        var lines = ["# 会中笔记", ""]
        for note in items {
            let stamp = note.anchor.map { absolute?.display($0.relative) ?? String(format: "%.2fs", $0.relative) } ?? "会后补充"
            lines += ["## \(stamp)", "", note.text.replacingOccurrences(of: "\u{fffc}", with: ""), ""]
            for image in note.images {
                if !FileManager.default.fileExists(atPath: assets.path) {
                    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                }
                let name = URL(fileURLWithPath: image.file).lastPathComponent, target = assets.appendingPathComponent(name)
                if let type = try? FileManager.default.attributesOfItem(atPath: target.path)[.type], type as? FileAttributeType == .typeSymbolicLink { throw Failure(code: "notes_export_symlink") }
                if FileManager.default.fileExists(atPath: target.path), Self.hash(try Data(contentsOf: target)) != image.sha256 { throw Failure(code: "meeting_files_user_file_collision") }
                try imageData(image).write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                lines += ["![笔记图片](会中笔记.assets/\(name))", ""]
            }
        }
        // Preserve manual edits using a receipt, just like the existing exporter.
        let receipt = folder.appendingPathComponent(".meeting-notes-export.json")
        if let type = try? FileManager.default.attributesOfItem(atPath: receipt.path)[.type], type as? FileAttributeType == .typeSymbolicLink { throw Failure(code: "notes_export_symlink") }
        if FileManager.default.fileExists(atPath: export.path) {
            let old = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: receipt))
            guard old["sha256"] == Self.hash(try Data(contentsOf: export)) else { throw Failure(code: "meeting_files_user_file_collision") }
        }
        let data = Data(lines.joined(separator: "\n").utf8)
        try data.write(to: export, options: .atomic)
        try JSONEncoder().encode(["sha256": Self.hash(data)]).write(to: receipt, options: .atomic)
        for file in [export, receipt] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    }
}
