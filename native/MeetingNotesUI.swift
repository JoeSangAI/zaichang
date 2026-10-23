import AppKit
import ImageIO
import UniformTypeIdentifiers

final class MeetingNotesPanel: NSView {
    // The left hairline doubles as a drag handle: drag to resize, double-click to reset.
    static let handleWidth: CGFloat = 8
    var onResize: ((CGFloat) -> Void)?
    var onReset: (() -> Void)?
    private var dragStart: (x: CGFloat, width: CGFloat)?
    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: Self.handleWidth, height: bounds.height), cursor: .resizeLeftRight)
    }
    override func mouseDown(with event: NSEvent) {
        guard convert(event.locationInWindow, from: nil).x <= Self.handleWidth else { dragStart = nil; super.mouseDown(with: event); return }
        if event.clickCount == 2 { dragStart = nil; onReset?(); return }
        dragStart = (event.locationInWindow.x, bounds.width)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { super.mouseDragged(with: event); return }
        onResize?(start.width + start.x - event.locationInWindow.x)
    }
    override func mouseUp(with event: NSEvent) { dragStart = nil; super.mouseUp(with: event) }
    override func draw(_ dirtyRect: NSRect) {
        MeetingVisualStyle.surface.setFill(); bounds.fill()
        MeetingVisualStyle.border.setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: 1 / (window?.backingScaleFactor ?? 1), height: bounds.height).fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

extension NSAttributedString.Key {
    static let meetingNoteIdentity = NSAttributedString.Key("meeting.note.identity")
    static let zaichangNoteImageSHA = NSAttributedString.Key("zaichang.note.image.sha256")
}

// Immutable attributes survive NSTextView's attributed-text deletion/undo.
final class MeetingNoteIdentity: NSObject, NSCopying {
    let id: String
    let anchor: MeetingNoteAnchor?
    init(id: String = UUID().uuidString, anchor: MeetingNoteAnchor?) { self.id = id; self.anchor = anchor }
    func copy(with zone: NSZone? = nil) -> Any { self }
}
struct MeetingNotebookParagraph {
    let identity: MeetingNoteIdentity
    let text: String
    let images: [MeetingNoteImage]
}
enum MeetingNotebook {
    static func ordered(_ snapshot: MeetingNotesSnapshot) -> [MeetingNote] {
        snapshot.visible.enumerated().sorted {
            let a = $0.element.anchor?.relative ?? .infinity, b = $1.element.anchor?.relative ?? .infinity
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }
    // Call only on the notes write queue. Stable IDs make repeated flushes and
    // undo before/after an asynchronous save idempotent. Other windows' new IDs
    // are not deleted merely because they are absent from this editor.
    static func save(_ paragraphs: [MeetingNotebookParagraph], knownIDs: Set<String>, store: MeetingNotesStore) throws -> MeetingNotesSnapshot {
        var latest = Dictionary(uniqueKeysWithValues: try store.snapshot().latest.map { ($0.note_id, $0) })
        let present = Set(paragraphs.map { $0.identity.id })
        for paragraph in paragraphs {
            let id = paragraph.identity.id
            let text = paragraph.text.replacingOccurrences(of: "\u{fffc}", with: "")
            if var old = latest[id] {
                if old.op == "delete" { old = try store.change(id, op: "restore") }
                let imagesChanged = old.images != paragraph.images
                if old.text != text || old.starred || !old.archive || imagesChanged {
                    old = try store.change(id, text: text, starred: false, archive: true, imageReferences: imagesChanged ? paragraph.images : nil)
                }
                latest[id] = old
            } else {
                latest[id] = try store.create(text: text, anchor: paragraph.identity.anchor, id: id, imageReferences: paragraph.images)
            }
        }
        for id in knownIDs.subtracting(present) {
            if let old = latest[id], old.op != "delete" { try store.change(id, op: "delete") }
        }
        return try store.snapshot()
    }
}

final class MeetingNoteEditor: NSTextView {
    let placeholder = "记点什么…可直接粘贴截图"
    let noteUndoManager = UndoManager()
    override var undoManager: UndoManager? { noteUndoManager }
    var pasteboardOverride: NSPasteboard?
    var reportError: ((Error) -> Void)?
    var importImages: (([Data]) throws -> [(MeetingNoteImage, Data)])?
    var insertionIdentity: ((NSRange) -> MeetingNoteIdentity?)?
    private var attachmentWidth: CGFloat = 0
    var isPlaceholderVisible: Bool { string.isEmpty }
    override var string: String { didSet { needsDisplay = true } }
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
    func restoreAttributes(_ value: NSAttributedString) {
        guard let storage = textStorage, storage.length == value.length else { return }
        let inverse = NSAttributedString(attributedString: storage)
        noteUndoManager.registerUndo(withTarget: self) { $0.restoreAttributes(inverse) }
        storage.beginEditing()
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attrs, range, _ in storage.setAttributes(attrs, range: range) }
        storage.endEditing()
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if let attributed = insertString as? NSAttributedString, attributed.length > 0,
           let identity = insertionIdentity?(replacementRange.location == NSNotFound ? selectedRange() : replacementRange) {
            let value = NSMutableAttributedString(attributedString: attributed)
            value.addAttribute(.meetingNoteIdentity, value: identity, range: NSRange(location: 0, length: value.length))
            super.insertText(value, replacementRange: replacementRange)
        } else { super.insertText(insertString, replacementRange: replacementRange) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isPlaceholderVisible else { return }
        let inset = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        (placeholder as NSString).draw(with: NSRect(x: inset, y: textContainerInset.height, width: max(0, bounds.width - inset * 2), height: 80), options: [.usesLineFragmentOrigin], attributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: MeetingVisualStyle.muted])
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            breakUndoCoalescing()
            if event.modifierFlags.contains(.shift) { if noteUndoManager.canRedo { noteUndoManager.redo() } }
            else if noteUndoManager.canUndo { noteUndoManager.undo() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); fitAttachments() }
    func fitAttachments() {
        let width = max(1, bounds.width - 2 * (textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)))
        guard let storage = textStorage else { return }
        var changed = attachmentWidth != width; attachmentWidth = width
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment, let image = attachment.image, image.size.width > 0 else { return }
            let scale = min(1, width / image.size.width, 240 / max(1, image.size.height))
            let rect = NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
            if attachment.bounds != rect { attachment.bounds = rect; changed = true }
        }
        if changed { layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil); needsDisplay = true }
    }
    static func images(from board: NSPasteboard) throws -> [Data] {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return try urls.map { url in
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize, size <= 20 * 1024 * 1024 else { throw Failure(code: "notes_image_20mb_limit") }
                return try Data(contentsOf: url)
            }
        }
        for type in [NSPasteboard.PasteboardType.png, NSPasteboard.PasteboardType("public.jpeg"), .tiff] {
            if let data = board.data(forType: type) { return [data] }
        }
        return []
    }
    static func attachment(_ input: Data) throws -> NSTextAttachment {
        guard input.count <= 20 * 1024 * 1024, let source = CGImageSourceCreateWithData(input as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 30000, h <= 30000, w * h <= 100_000_000 else { throw Failure(code: "notes_invalid_image_or_20mb_limit") }
        let attachment = NSTextAttachment()
        // This is only a preview. AppKit may replace/re-encode this attachment;
        // saving never reads its fileWrapper, contents or image representation.
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw Failure(code: "notes_image_decode") }
        attachment.image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        return attachment
    }
    @discardableResult func pasteImages(_ board: NSPasteboard) -> Bool {
        do {
            let images = try Self.images(from: board)
            guard !images.isEmpty else { return false }
            guard let importImages else { throw Failure(code: "notes_missing_image_store") }
            let content = NSMutableAttributedString(string: "")
            for (reference, data) in try importImages(images) {
                let character = NSMutableAttributedString(attributedString: NSAttributedString(attachment: try Self.attachment(data)))
                character.addAttribute(.zaichangNoteImageSHA, value: reference.sha256, range: NSRange(location: 0, length: character.length))
                content.append(character)
            }
            // One explicit group: a paste is one undo step, even outside an AppKit event.
            noteUndoManager.beginUndoGrouping(); defer { noteUndoManager.endUndoGrouping() }
            insertText(content, replacementRange: selectedRange()); fitAttachments(); return true
        } catch { reportError?(error); return true }
    }
    override func paste(_ sender: Any?) {
        let board = pasteboardOverride ?? .general
        if !pasteImages(board), let text = board.string(forType: .string) {
            noteUndoManager.beginUndoGrouping(); defer { noteUndoManager.endUndoGrouping() }
            insertText(text, replacementRange: selectedRange())
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]) == nil ? [] : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if sender.draggingDestinationWindow != nil {
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil)), length: 0))
        }
        return pasteImages(sender.draggingPasteboard)
    }
}

final class MeetingNotesController: NSObject, NSTextViewDelegate {
    weak var owner: Delegate?
    var store: MeetingNotesStore?
    var cacheID: String?
    var snapshot = MeetingNotesSnapshot()
    let panel = MeetingNotesPanel()
    let editor = MeetingNoteEditor()
    let scroller = NSScrollView()
    let status = NSTextField(wrappingLabelWithString: "")
    let retryLoadButton = NSButton(title: "重新读取笔记", target: nil, action: nil)
    let toggle = NSButton(title: "笔记", target: nil, action: nil)
    var panelWidth: NSLayoutConstraint!
    var transportRow: NSStackView?
    var expanded = false
    var embeddedInAssistant = false
    var lastError: String?
    var pending = 0
    var now: () -> Double = { Date().timeIntervalSince1970 }
    private var debounce: Timer?
    private var revision = 0
    private var binding = UUID()
    private var dirty = false
    private var loading = false
    private var loadFailureMessage: String?
    private var knownIDs = Set<String>()
    private var imageReferences: [String: MeetingNoteImage] = [:]
    private var migrateDraft = false
    private struct UnsavedNotebook {
        let content: NSAttributedString
        let paragraphs: [MeetingNotebookParagraph]?
        let knownIDs: Set<String>
        let store: MeetingNotesStore
        let migrateDraft: Bool
        let images: [String: MeetingNoteImage]
    }
    private var unsaved: [String: UnsavedNotebook] = [:]
    private var saveSequence = 0
    private var completedSave = 0
    private var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.paragraphSpacing = 10
        return [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: MeetingVisualStyle.ink, .paragraphStyle: paragraph]
    }
    init(owner: Delegate) {
        self.owner = owner; super.init()
        panel.translatesAutoresizingMaskIntoConstraints = false; panel.isHidden = true
        panelWidth = panel.widthAnchor.constraint(equalToConstant: 300)
        panel.onResize = { [weak self] in self?.setPanelWidth($0) }
        panel.onReset = { [weak self] in self?.resetPanelWidth() }
        toggle.target = self; toggle.action = #selector(togglePanel); toggle.bezelStyle = .inline
        toggle.font = .systemFont(ofSize: 11); toggle.setAccessibilityLabel("笔记")
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        scroller.hasVerticalScroller = true; scroller.autohidesScrollers = true; scroller.drawsBackground = false
        scroller.borderType = .noBorder
        editor.isRichText = true; editor.importsGraphics = true; editor.allowsUndo = true
        editor.font = .systemFont(ofSize: 14); editor.textColor = MeetingVisualStyle.ink; editor.backgroundColor = MeetingVisualStyle.surface
        editor.textContainerInset = NSSize(width: 6, height: 12)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false; editor.autoresizingMask = [.width]
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true; editor.textContainer?.containerSize = NSSize(width: 280, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = self; editor.typingAttributes = baseAttributes
        editor.registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")])
        editor.setAccessibilityLabel("笔记记事本"); editor.reportError = { [weak self] in self?.fail($0) }
        editor.importImages = { [weak self] data in
            guard let self, let store = self.store else { throw Failure(code: "notes_missing_image_store") }
            guard self.loadFailureMessage == nil else { throw Failure(code: "notes_read_only_load_failure") }
            let imported = try MeetingNotesStore.queue.sync {
                try data.map { bytes -> (MeetingNoteImage, Data) in
                    let image = try store.importImage(bytes)
                    return (image, try store.imageData(image))
                }
            }
            for (image, _) in imported { self.imageReferences[image.sha256] = image }
            return imported
        }
        editor.insertionIdentity = { [weak self] selection in
            guard let storage = self?.editor.textStorage, selection.location < storage.length else { return nil }
            let range = (storage.string as NSString).paragraphRange(for: NSRange(location: selection.location, length: 0))
            var identity: MeetingNoteIdentity?
            storage.enumerateAttribute(.meetingNoteIdentity, in: range) { value, _, _ in if identity == nil { identity = value as? MeetingNoteIdentity } }
            return identity
        }
        scroller.documentView = editor
        status.font = .systemFont(ofSize: 10); status.textColor = MeetingVisualStyle.muted; status.isHidden = true
        retryLoadButton.target = self; retryLoadButton.action = #selector(retryLoad)
        retryLoadButton.bezelStyle = .inline; retryLoadButton.isHidden = true
        let content = NSStackView(views: [scroller, status, retryLoadButton]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false; panel.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10), content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -6), content.topAnchor.constraint(equalTo: panel.topAnchor), content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6), scroller.widthAnchor.constraint(equalTo: content.widthAnchor), status.widthAnchor.constraint(equalTo: content.widthAnchor)])
        toggle.isEnabled = false; editor.isEditable = false
    }
    func anchor() -> MeetingNoteAnchor? {
        guard let owner, !owner.isHistoryReader else { return nil }
        if owner.phase.phase == .recording { return .capture(owner.absoluteTime, now: now()) }
        if owner.phase.phase == .paused { return .capture(owner.absoluteTime, now: now(), paused: owner.notesPausedRelative ?? owner.phase.elapsed) }
        return nil
    }
    func tooltip(_ identity: MeetingNoteIdentity) -> String {
        identity.anchor.map { owner?.absoluteTime?.display($0.relative) ?? TranscriptTimeline.timestamp($0.relative) } ?? "会后补充"
    }
    static func paragraphRanges(_ string: String) -> [NSRange] {
        let text = string as NSString
        var result: [NSRange] = [], index = 0
        while index < text.length { let range = text.paragraphRange(for: NSRange(location: index, length: 0)); result.append(range); index = NSMaxRange(range) }
        return result
    }
    // Run immediately after each edit, before the 500 ms disk debounce. Newline
    // inheritance may duplicate an ID; only the first nonempty paragraph keeps it.
    @discardableResult func paragraphs(recordUndo: Bool = false) throws -> [MeetingNotebookParagraph] {
        guard let storage = editor.textStorage else { return [] }
        let original = recordUndo ? NSAttributedString(attributedString: storage) : nil
        var identityChanged = false
        var result: [MeetingNotebookParagraph] = [], seen = Set<String>()
        storage.beginEditing(); defer { storage.endEditing() }
        for range in Self.paragraphRanges(storage.string) {
            var text = (storage.string as NSString).substring(with: range)
            while text.last == "\n" || text.last == "\r" || text.last == "\u{2029}" { text.removeLast() }
            var images: [MeetingNoteImage] = [], identity: MeetingNoteIdentity?
            storage.enumerateAttributes(in: range) { attrs, _, _ in
                if identity == nil { identity = attrs[.meetingNoteIdentity] as? MeetingNoteIdentity }
            }
            // Read one reference per attachment character, including repeated
            // copies of the same image. Never recover bytes from AppKit objects.
            for index in range.location..<NSMaxRange(range) where (storage.string as NSString).character(at: index) == 0xfffc {
                if storage.attribute(.attachment, at: index, effectiveRange: nil) == nil && storage.attribute(.zaichangNoteImageSHA, at: index, effectiveRange: nil) == nil { continue }
                guard let sha = storage.attribute(.zaichangNoteImageSHA, at: index, effectiveRange: nil) as? String,
                      let image = imageReferences[sha] else { throw Failure(code: "notes_missing_image_reference") }
                images.append(image)
            }
            text = text.replacingOccurrences(of: "\u{fffc}", with: "")
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty {
                if identity != nil { identityChanged = true }
                storage.removeAttribute(.meetingNoteIdentity, range: range); storage.removeAttribute(.toolTip, range: range); continue
            }
            if identity == nil || seen.contains(identity!.id) {
                let time = anchor()
                if time == nil, let owner, !owner.isHistoryReader, [.recording, .paused].contains(owner.phase.phase) { throw Failure(code: "notes_clock_not_ready") }
                identity = MeetingNoteIdentity(anchor: time)
            }
            let value = identity!; seen.insert(value.id)
            storage.enumerateAttribute(.meetingNoteIdentity, in: range) { old, _, _ in
                if (old as? MeetingNoteIdentity)?.id != value.id { identityChanged = true }
            }
            storage.addAttributes(baseAttributes.merging([.meetingNoteIdentity: value, .toolTip: tooltip(value)]) { _, new in new }, range: range)
            result.append(MeetingNotebookParagraph(identity: value, text: text.replacingOccurrences(of: "\u{2028}", with: "\n"), images: images))
        }
        // An empty final line must not inherit the previous paragraph's anchor.
        var typing = baseAttributes
        let cursor = min(editor.selectedRange().location, storage.length)
        if cursor < storage.length, let identity = storage.attribute(.meetingNoteIdentity, at: cursor, effectiveRange: nil) {
            typing[.meetingNoteIdentity] = identity
        } else if cursor > 0, !(storage.string as NSString).substring(with: NSRange(location: cursor - 1, length: 1)).contains("\n"), let identity = storage.attribute(.meetingNoteIdentity, at: cursor - 1, effectiveRange: nil) {
            typing[.meetingNoteIdentity] = identity
        }
        editor.typingAttributes = typing
        if identityChanged, let original {
            editor.noteUndoManager.registerUndo(withTarget: editor) { $0.restoreAttributes(original) }
        }
        return result
    }
    func textDidChange(_ notification: Notification) {
        guard !loading, loadFailureMessage == nil else { return }
        revision += 1; dirty = true
        do { _ = try paragraphs(recordUndo: true) } catch { fail(error) }
        editor.fitAttachments(); scheduleSave()
    }
    private func scheduleSave() {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.flushPendingChanges(wait: false) }
    }
    @discardableResult func flushPendingChanges(wait: Bool = true) -> Bool {
        debounce?.invalidate(); debounce = nil
        // A missing-image placeholder is presentation only. Never serialize it
        // or drop the original image reference when leaving this meeting.
        guard loadFailureMessage == nil else { return true }
        guard let store, dirty || pending > 0 || migrateDraft else { return true }
        let values: [MeetingNotebookParagraph]
        do { values = try paragraphs() } catch { fail(error); return false }
        let ids = knownIDs.union(values.map { $0.identity.id }); knownIDs = ids
        let version = revision, token = binding, clearDraft = migrateDraft
        saveSequence += 1; let sequence = saveSequence
        let save = { () throws -> MeetingNotesSnapshot in
            let result = try MeetingNotebook.save(values, knownIDs: ids, store: store)
            if clearDraft { try store.saveDraft("") }
            return result
        }
        let complete: (Result<MeetingNotesSnapshot, Error>) -> Bool = { [weak self] result in
            guard let self, self.binding == token else { return true }
            guard sequence >= self.completedSave else { return true }; self.completedSave = sequence
            switch result {
            case .success(let saved):
                if self.revision == version {
                    self.snapshot = saved; self.dirty = false; self.migrateDraft = false; self.lastError = nil; self.status.stringValue = ""; self.status.isHidden = true
                }
                return true
            case .failure(let error): self.dirty = true; self.fail(error); return false
            }
        }
        if wait { return complete(Result { try MeetingNotesStore.queue.sync(execute: save) }) }
        pending += 1
        MeetingNotesStore.queue.async { [weak self] in
            let result = Result { try save() }
            DispatchQueue.main.async { self?.pending -= 1; _ = complete(result) }
        }
        return true
    }
    func fail(_ error: Error) {
        lastError = String(describing: error); status.stringValue = "笔记未能保存，请重试（图片上限 20 MB）"; status.isHidden = false
    }
    func flushForClosing() -> Bool {
        guard flushPendingChanges() else { return false }
        do {
            for (id, buffer) in Array(unsaved) {
                guard let values = buffer.paragraphs else { throw Failure(code: "notes_unsaved_other_meeting") }
                try MeetingNotesStore.queue.sync {
                    _ = try MeetingNotebook.save(values, knownIDs: buffer.knownIDs, store: buffer.store)
                    if buffer.migrateDraft { try buffer.store.saveDraft("") }
                }
                unsaved.removeValue(forKey: id)
            }
            if loadFailureMessage == nil { lastError = nil; status.stringValue = ""; status.isHidden = true }
            return true
        } catch { fail(error); return false }
    }
    @objc func retryLoad() { bind(cacheID, reload: true) }
    func bind(_ id: String?, reload: Bool = false) {
        guard cacheID != id || reload else { return }
        if !flushPendingChanges(), let cacheID, let store {
            unsaved[cacheID] = UnsavedNotebook(content: editor.attributedString(), paragraphs: try? paragraphs(), knownIDs: knownIDs, store: store, migrateDraft: migrateDraft, images: imageReferences)
        }
        binding = UUID(); revision = 0; dirty = false; migrateDraft = false
        saveSequence = 0; completedSave = 0
        cacheID = id; snapshot = MeetingNotesSnapshot(); knownIDs = []; lastError = nil; status.stringValue = ""; status.isHidden = true
        loadFailureMessage = nil; retryLoadButton.isHidden = true
        imageReferences = [:]
        store = (Credential.offline && owner?.recoveryRootOverride == nil ? nil : id).flatMap { UUID(uuidString: $0) == nil ? nil : $0 }.map { MeetingNotesStore(directory: owner!.recoveryBase().appendingPathComponent($0)) }
        loading = true; defer { loading = false }
        editor.textStorage?.setAttributedString(NSAttributedString(string: "")); editor.noteUndoManager.removeAllActions()
        toggle.isEnabled = store != nil; editor.isEditable = store != nil
        guard let store else { return }
        do {
            var unreadableImages = 0
            let loaded = try MeetingNotesStore.queue.sync { () throws -> (MeetingNotesSnapshot, NSAttributedString, Bool) in
                let saved = try store.snapshot(); let content = NSMutableAttributedString(string: "")
                for note in MeetingNotebook.ordered(saved) {
                    if content.length > 0 { content.append(NSAttributedString(string: "\n", attributes: baseAttributes)) }
                    let paragraph = NSMutableAttributedString(string: note.text.replacingOccurrences(of: "\u{fffc}", with: "").replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: baseAttributes)
                    for image in note.images {
                        imageReferences[image.sha256] = image
                        do {
                            let character = NSMutableAttributedString(attributedString: NSAttributedString(attachment: try MeetingNoteEditor.attachment(store.imageData(image))))
                            character.addAttribute(.zaichangNoteImageSHA, value: image.sha256, range: NSRange(location: 0, length: character.length))
                            paragraph.append(character)
                        } catch {
                            unreadableImages += 1
                            paragraph.append(NSAttributedString(string: "\n[图片无法读取]", attributes: baseAttributes))
                        }
                    }
                    if paragraph.length == 0 { paragraph.append(NSAttributedString(string: "重点标记", attributes: baseAttributes)) }
                    let identity = MeetingNoteIdentity(id: note.note_id, anchor: note.anchor)
                    paragraph.addAttributes([.meetingNoteIdentity: identity, .toolTip: tooltip(identity)], range: NSRange(location: 0, length: paragraph.length)); content.append(paragraph)
                }
                // One-time recovery for the previous editor's draft. A malformed
                // obsolete draft does not prevent opening durable notes.
                let draft = (try? store.draft()) ?? ""
                if !draft.isEmpty {
                    if content.length > 0 { content.append(NSAttributedString(string: "\n", attributes: baseAttributes)) }
                    for (index, line) in draft.components(separatedBy: "\n").enumerated() {
                        if index > 0 { content.append(NSAttributedString(string: "\n", attributes: baseAttributes)) }
                        content.append(NSAttributedString(string: line, attributes: baseAttributes.merging([.meetingNoteIdentity: MeetingNoteIdentity(anchor: nil)]) { _, new in new }))
                    }
                }
                return (saved, content, !draft.isEmpty)
            }
            snapshot = loaded.0; knownIDs = Set(snapshot.visible.map(\.note_id)); migrateDraft = loaded.2
            // Keep any previous failed-save buffer until a complete reload can
            // safely restore it to the editable notebook.
            let buffer = unreadableImages > 0 ? unsaved[id!] : unsaved.removeValue(forKey: id!)
            if let buffer { imageReferences.merge(buffer.images) { _, buffered in buffered } }
            editor.textStorage?.setAttributedString(buffer?.content ?? loaded.1)
            dirty = migrateDraft || editor.attributedString() != loaded.1 || snapshot.visible.contains { $0.starred || !$0.archive || $0.text.contains("\u{fffc}") }
            editor.setSelectedRange(NSRange(location: 0, length: 0)); editor.typingAttributes = baseAttributes
            editor.fitAttachments(); editor.scrollToBeginningOfDocument(nil); editor.needsDisplay = true
            if unreadableImages > 0 {
                dirty = false
                showLoadFailure("\(unreadableImages) 张笔记图片缺失或损坏，文字已保留，只读查看。恢复原图片后可重新读取。", code: "notes_image_load_failed")
            } else if dirty { scheduleSave() }
        } catch { showLoadFailure("笔记读取失败，原文件未改动。修复文件或访问权限后可重新读取。", code: String(describing: error)) }
    }
    private func showLoadFailure(_ message: String, code: String) {
        loadFailureMessage = message; lastError = code; editor.isEditable = false
        status.stringValue = message; status.isHidden = false; retryLoadButton.isHidden = false
    }
    @objc func togglePanel() {
        expanded.toggle(); (owner?.workspaceOwner ?? owner)?.notesExpanded = expanded; applyExpansion()
        if expanded { owner?.window.makeFirstResponder(editor) } else { flushPendingChanges() }
    }
    static let widthKey = "zaichang.notes.panelWidth"
    static let minimumWidth: CGFloat = 240
    static let minimumTranscriptWidth: CGFloat = 240
    // Clamp to the current body so the transcript always keeps a readable column.
    func clampedWidth(_ width: CGFloat) -> CGFloat {
        let body = panel.superview?.bounds.width ?? 0
        let maximum = max(Self.minimumWidth, body > 0 ? body - Self.minimumTranscriptWidth : 520)
        return min(max(width.rounded(), Self.minimumWidth), maximum)
    }
    func preferredWidth(windowWidth: CGFloat) -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: Self.widthKey)
        return clampedWidth(stored > 0 ? CGFloat(stored) : (windowWidth < 800 ? 280 : 300))
    }
    func setPanelWidth(_ width: CGFloat) {
        let value = clampedWidth(width)
        guard panelWidth.constant != value else { return }
        panelWidth.constant = value; UserDefaults.standard.set(Double(value), forKey: Self.widthKey)
        owner?.window.contentView?.layoutSubtreeIfNeeded(); owner?.resizeTranscript(); editor.fitAttachments()
    }
    func resetPanelWidth() {
        UserDefaults.standard.removeObject(forKey: Self.widthKey)
        panelWidth.constant = preferredWidth(windowWidth: owner?.window.contentLayoutRect.width ?? 1200)
        owner?.window.contentView?.layoutSubtreeIfNeeded(); owner?.resizeTranscript(); editor.fitAttachments()
    }
    func applyExpansion() {
        if embeddedInAssistant {panelWidth.isActive=false;panel.isHidden=false;editor.fitAttachments();return}
        panelWidth.isActive = expanded; panel.isHidden = !expanded
        owner?.window.contentView?.layoutSubtreeIfNeeded(); owner?.resizeTranscript(); editor.fitAttachments()
    }
    func refreshTooltips() {
        guard let storage = editor.textStorage else { return }
        storage.enumerateAttribute(.meetingNoteIdentity, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let identity = value as? MeetingNoteIdentity { storage.addAttribute(.toolTip, value: tooltip(identity), range: range) }
        }
    }
}

extension Delegate {
    func attachMeetingNotes(to transcript: NSView) -> NSView {
        let controller = MeetingNotesController(owner: self); notesController = controller
        let body = NSStackView(views: [transcript, controller.panel]); body.orientation = .horizontal; body.alignment = .top; body.spacing = 12
        transcript.setContentHuggingPriority(.defaultLow, for: .horizontal)
        transcript.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        let height = controller.panel.heightAnchor.constraint(equalTo: body.heightAnchor); height.priority = .defaultHigh; height.isActive = true
        controller.bind(currentCacheID); return body
    }
    func notesTransport(_ transport: NSView) -> NSView {
        guard let notesController else { return transport }
        // The switch sits under the capsule so it never takes width from the
        // capsule's timer at narrow window sizes.
        let row = NSStackView(views: [transport, notesController.toggle]); row.orientation = .vertical; row.spacing = 4; row.alignment = .centerX
        transport.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        notesController.transportRow = row; return row
    }
    func refreshMeetingNotes() {
        guard let controller = notesController else { return }
        controller.bind(currentCacheID)
        if controller.embeddedInAssistant {controller.refreshTooltips();return}
        let desired = (workspaceOwner ?? self).notesExpanded
        if controller.expanded != desired { controller.expanded = desired; controller.applyExpansion() }
        controller.panelWidth.constant = controller.preferredWidth(windowWidth: window.contentLayoutRect.width)
        controller.refreshTooltips()
    }
    func jumpToNote(_ relative: Double) {
        guard let turn = readingTurns(sequence).min(by: { abs(TranscriptTimeline.start($0.item) - relative) < abs(TranscriptTimeline.start($1.item) - relative) }) else { return }
        cancelTranscriptReadingRestore()
        // Existing header attributes supply the actual rendered range; no new
        // transcript markers, segmentation, or selection semantics are introduced.
        guard let storage = output.textStorage else { return }
        var match: NSRange?
        storage.enumerateAttribute(.zaichangTurnHeader, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if let header = value as? TranscriptTurnHeader, header.start == TranscriptTimeline.start(turn.item) { match = range; stop.pointee = true }
        }
        if let match { output.scrollRangeToVisible(match) }
    }
}
