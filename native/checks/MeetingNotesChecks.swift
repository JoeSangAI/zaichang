import AppKit
import ImageIO
import UniformTypeIdentifiers

private final class NotesDragFixture: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var animatesToDestination = false
    var draggingFormation: NSDraggingFormation = .none
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(_ board: NSPasteboard) { draggingPasteboard = board }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@MainActor func meetingNotesChecks(directory: URL, storageOnly: Bool = false) throws -> [String: Any] {
    guard Credential.offline, let root = Bundle.main.object(forInfoDictionaryKey: "AdapterRoot") as? String,
          directory.standardizedFileURL.path.hasPrefix(root + "/.runtime/") else { throw Failure(code: "notes_fixture_scope") }
    let fm = FileManager.default
    let run = directory.appendingPathComponent("fixtures-" + UUID().uuidString)
    try fm.createDirectory(at: run, withIntermediateDirectories: true)
    var checks: [String] = []
    func check(_ ok: Bool, _ name: String) throws { guard ok else { throw Failure(code: name) }; checks.append(name) }
    func drain(_ controller: MeetingNotesController? = nil) throws {
        MeetingNotesStore.queue.sync {}
        let deadline = Date().addingTimeInterval(5)
        repeat { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) } while (controller?.pending ?? 0) > 0 && Date() < deadline
        try check((controller?.pending ?? 0) == 0, "notes_queue_completion_\(checks.count)")
        if let error = controller?.lastError { throw Failure(code: "notes_save_failed: " + error) }
    }
    func cache() throws -> URL {
        let value = run.appendingPathComponent(UUID().uuidString); try fm.createDirectory(at: value, withIntermediateDirectories: false); return value
    }
    let a = try cache(), b = try cache(), empty = try cache()
    let store = MeetingNotesStore(directory: a)
    let stamp = MeetingNoteAnchor(relative: 15, state: "recording")
    var original: MeetingNote!
    try MeetingNotesStore.queue.sync {
        let idle = MeetingNotesStore(directory: empty)
        _ = try idle.snapshot(); _ = try idle.draft(); try idle.saveDraft("")
        try check(try fm.contentsOfDirectory(atPath: empty.path).isEmpty, "no_notes_creates_no_files")
        original = try store.create(text: "品牌：在场；预算 12.5 万", anchor: stamp)
        try check(original.archive && original.rev == 1 && original.anchor == stamp, "create_defaults_archive_true")
        let edited = try store.change(original.note_id, text: "预算 15 万", starred: true, archive: false)
        try check(edited.rev == 2 && edited.anchor == stamp && !edited.archive && edited.starred, "edit_preserves_anchor_and_reference_flag")
        try store.change(original.note_id, op: "delete")
        try check(try store.snapshot().visible.isEmpty, "delete_hides_note")
        let restored = try store.change(original.note_id, op: "restore")
        try check(restored.rev == 4 && restored.text == "预算 15 万" && !restored.archive, "restore_retains_content")
        let mark = try store.create(starred: true, anchor: stamp)
        try check(mark.starred && mark.text.isEmpty && mark.archive, "star_only_empty_text")
        let paused = try store.create(text: "暂停中补一句", anchor: MeetingNoteAnchor(relative: 20, state: "paused"))
        try check(paused.anchor?.state == "paused", "paused_note_state")
        let after = try store.create(text: "会后补充", anchor: nil)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(after)) as! [String: Any]
        try check(json["anchor"] is NSNull, "after_meeting_explicit_null_anchor")
        try store.saveDraft("重启后继续写")
        try check(try MeetingNotesStore(directory: a).draft() == "重启后继续写", "draft_crash_recovery")
        let replay = try MeetingNotesStore(directory: a).snapshot()
        try check(replay.events == store.snapshot().events && replay.visible.count == 4, "restart_jsonl_replay_identical")
        try check(replay.events.contains { $0.op == "delete" && $0.text == "预算 15 万" }, "tombstone_retains_original_content")
        let permissions = try fm.attributesOfItem(atPath: store.notes.path)[.posixPermissions] as? Int
        let filePermissions = try fm.attributesOfItem(atPath: store.notes.appendingPathComponent("notes.jsonl").path)[.posixPermissions] as? Int
        try check(permissions == 0o700 && filePermissions == 0o600, "private_directory_and_journal_permissions")
    }
    let clock = CaptureBudgetClock(wallTime: { 1792239044.0 }, uptime: { 100 })
    clock.mark(100)
    let absolute = MeetingAbsoluteTime(clock.absoluteClock())!
    let inferred = MeetingNoteAnchor.capture(absolute, now: 1792239059.0)!
    try check(abs(inferred.relative - (clock.timestamp(115) - clock.origin()!)) <= 1, "absolute_anchor_matches_turn_clock_within_one_second")
    clock.pause(at: 120)
    try check(MeetingNoteAnchor.capture(absolute, now: 1792249059, paused: clock.elapsed(999))?.relative == 20, "pause_does_not_count_wall_gap")
    clock.resume(at: 720)
    let resumed = MeetingAbsoluteTime(clock.absoluteClock())!
    try check(abs(MeetingNoteAnchor.capture(resumed, now: 1792239670)!.relative - clock.elapsed(726)) <= 1, "resume_uses_latest_absolute_anchor")

    // The storage subset runs without registering an AppKit application. This
    // also gives a useful receipt when a headless/sandbox host cannot reach WindowServer.
    let pixels = Data(repeating: 180, count: 64 * 32 * 4)
    let provider = CGDataProvider(data: pixels as CFData)!
    let cg = CGImage(width: 64, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64 * 4,
                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    func encoded(_ type: UTType) -> Data {
        let output = NSMutableData(); let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg, nil); precondition(CGImageDestinationFinalize(destination)); return output as Data
    }
    try MeetingNotesStore.queue.sync {
        let store = MeetingNotesStore(directory: try cache())
        let png = encoded(.png), jpg = encoded(.jpeg)
        store.recognize = { _ in throw Failure(code: "synthetic_OCR_failure") }
        let imageNote = try store.create(images: [png], anchor: stamp)
        try check(store.ocrTasks.wait(timeout: .now() + 5) == .success && (try store.imageData(imageNote.images[0])) == png && !fm.fileExists(atPath: store.notes.appendingPathComponent("ocr/" + imageNote.images[0].sha256 + ".json").path), "storage_png_original_and_OCR_failure_retained")
        _ = try store.create(images: [png], anchor: nil)
        try check(try fm.contentsOfDirectory(atPath: store.notes.appendingPathComponent("assets").path).count == 1, "storage_image_sha_deduplication")
        let jpegNote = try store.create(images: [jpg], anchor: stamp)
        try check(jpegNote.images[0].file.hasSuffix(".jpg") && (try store.imageData(jpegNote.images[0])) == jpg, "storage_jpeg_original_retained")
        store.recognize = { _ in "合成 OCR 文字" }
        let converted = try store.create(images: [encoded(.tiff)], anchor: stamp)
        try check(converted.images[0].file.hasSuffix(".png"), "storage_TIFF_to_PNG")
        try check(store.ocrTasks.wait(timeout: .now() + 10) == .success, "storage_OCR_finishes_on_utility_queue")
        let ocrFile = store.notes.appendingPathComponent("ocr/" + converted.images[0].sha256 + ".json")
        let ocr = try JSONSerialization.jsonObject(with: Data(contentsOf: ocrFile)) as! [String: Any]
        try check(ocr["engine"] as? String == "apple-vision" && ocr["langs"] as? [String] == ["zh-Hans", "en"], "storage_OCR_contract")
        var oversize = false
        do { _ = try store.create(images: [Data(repeating: 0, count: 20 * 1024 * 1024 + 1)], anchor: stamp) } catch { oversize = true }
        try check(oversize, "storage_20mb_limit")
        let export = run.appendingPathComponent("storage-export"); try fm.createDirectory(at: export, withIntermediateDirectories: false)
        try store.export(to: export, absolute: absolute); let first = try Data(contentsOf: export.appendingPathComponent("会中笔记.md"))
        try store.export(to: export, absolute: absolute)
        try check(try Data(contentsOf: export.appendingPathComponent("会中笔记.md")) == first, "storage_export_markdown_idempotent")
        try check(try Data(contentsOf: export.appendingPathComponent("会中笔记.assets/" + URL(fileURLWithPath: imageNote.images[0].file).lastPathComponent)) == png, "storage_export_copies_original_image")
        let journal = store.notes.appendingPathComponent("notes.jsonl"), prior = try Data(contentsOf: journal)
        let handle = try FileHandle(forWritingTo: journal); try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"schema\":1,".utf8)); try handle.close()
        let before = try store.snapshot().visible
        _ = try store.create(text: "崩溃截断后的新记录", anchor: nil)
        let replay = try store.snapshot()
        try check(replay.visible.count == before.count + 1 && (try Data(contentsOf: journal)).starts(with: prior), "storage_torn_tail_preserved_and_replay_recovers")
        let other = MeetingNotesStore(directory: b); try other.create(text: "B 专属记录", anchor: nil)
        try check(!replay.visible.contains { $0.text == "B 专属记录" } && (try other.snapshot().visible.count) == 1, "storage_A_B_A_isolation")
    }
    let slowStore = MeetingNotesStore(directory: try cache())
    let ocrStarted = DispatchSemaphore(value: 0), ocrFinished = DispatchSemaphore(value: 0)
    slowStore.recognize = { _ in
        ocrStarted.signal(); Thread.sleep(forTimeInterval: 2); ocrFinished.signal(); return "慢速本机 OCR"
    }
    let firstSaveAt = ProcessInfo.processInfo.systemUptime
    let slowImage = try MeetingNotesStore.queue.sync { try slowStore.create(images: [encoded(.png)], anchor: stamp) }
    let firstSaveSeconds = ProcessInfo.processInfo.systemUptime - firstSaveAt
    try check(firstSaveSeconds < 1, "image_note_returns_before_two_second_OCR")
    try check(ocrStarted.wait(timeout: .now() + 5) == .success, "slow_OCR_started")
    let secondSaveAt = ProcessInfo.processInfo.systemUptime
    let secondNote = try MeetingNotesStore.queue.sync { try slowStore.create(text: "OCR 进行中继续保存", anchor: stamp) }
    let secondSaveSeconds = ProcessInfo.processInfo.systemUptime - secondSaveAt
    try check(secondSaveSeconds < 1 && ocrFinished.wait(timeout: .now()) == .timedOut, "second_note_saved_while_slow_OCR_still_running")
    let barrierAt = ProcessInfo.processInfo.systemUptime
    let loaded = try MeetingNotesStore.queue.sync { (try slowStore.snapshot(), try slowStore.draft()) }
    let barrierSeconds = ProcessInfo.processInfo.systemUptime - barrierAt
    try check(barrierSeconds < 1 && loaded.0.visible.last?.note_id == secondNote.note_id && ocrFinished.wait(timeout: .now()) == .timedOut, "bind_read_and_quit_write_barrier_do_not_wait_for_OCR")
    try check(slowStore.ocrTasks.wait(timeout: .now() + 5) == .success, "slow_OCR_eventually_finishes")
    try check(fm.fileExists(atPath: slowStore.notes.appendingPathComponent("ocr/" + slowImage.images[0].sha256 + ".json").path), "slow_OCR_result_atomically_persisted")

    // Exercise the same export hook called by MeetingLibraryManagement, without
    // AppKit or real meetings. A cache with no notes must stay byte-for-byte empty.
    func item(_ folder: URL) -> CachedMeeting {
        CachedMeeting(id: folder.lastPathComponent, directory: folder, date: Date(), writtenBytes: 0, pendingBytes: 0, occupiedBytes: 0, tracks: [], audioCleaned: false, warning: false, retiredBytes: 0)
    }
    let wiredExport = run.appendingPathComponent("wired-export"), emptyExport = run.appendingPathComponent("empty-export")
    try fm.createDirectory(at: wiredExport, withIntermediateDirectories: false)
    try fm.createDirectory(at: emptyExport, withIntermediateDirectories: false)
    try MeetingNotesStore.exportMeetingFiles(item(slowStore.directory), to: wiredExport)
    try check(fm.fileExists(atPath: wiredExport.appendingPathComponent("会中笔记.md").path) && (try Data(contentsOf: wiredExport.appendingPathComponent("会中笔记.assets/" + URL(fileURLWithPath: slowImage.images[0].file).lastPathComponent))) == encoded(.png), "export_hook_includes_markdown_and_original_image")
    let untouched = Data("已有转写文件".utf8); try untouched.write(to: emptyExport.appendingPathComponent("转写.txt"))
    try MeetingNotesStore.exportMeetingFiles(item(empty), to: emptyExport)
    try check(try fm.contentsOfDirectory(atPath: emptyExport.path) == ["转写.txt"] && Data(contentsOf: emptyExport.appendingPathComponent("转写.txt")) == untouched && fm.contentsOfDirectory(atPath: empty.path).isEmpty, "export_hook_without_notes_adds_no_note_files")

    let notebookStore = MeetingNotesStore(directory: try cache())
    notebookStore.recognize = { _ in "合成图片" }
    let firstIdentity = MeetingNoteIdentity(anchor: stamp)
    let secondIdentity = MeetingNoteIdentity(anchor: MeetingNoteAnchor(relative: 3, state: "paused"))
    let afterIdentity = MeetingNoteIdentity(anchor: nil)
    func paragraph(_ identity: MeetingNoteIdentity, _ text: String, _ images: [Data] = []) throws -> MeetingNotebookParagraph {
        MeetingNotebookParagraph(identity: identity, text: text, images: try images.map { try notebookStore.importImage($0) })
    }
    try MeetingNotesStore.queue.sync {
        let first = try paragraph(firstIdentity, "第一段")
        var saved = try MeetingNotebook.save([first], knownIDs: [], store: notebookStore)
        try check(saved.visible.first?.note_id == firstIdentity.id && saved.visible.first?.anchor == stamp, "notebook_create_uses_preassigned_identity_and_first_content_anchor")
        let changedIdentity = MeetingNoteIdentity(id: firstIdentity.id, anchor: nil)
        saved = try MeetingNotebook.save([paragraph(changedIdentity, "修改第一段")], knownIDs: [firstIdentity.id], store: notebookStore)
        try check(saved.visible.first?.rev == 2 && saved.visible.first?.anchor == stamp && saved.visible.first?.text == "修改第一段", "notebook_edit_preserves_original_anchor")
        let picture = try paragraph(firstIdentity, "前文\u{fffc}后文", [encoded(.png)])
        saved = try MeetingNotebook.save([picture], knownIDs: [firstIdentity.id], store: notebookStore)
        try check(saved.visible.count == 1 && saved.visible[0].images.count == 1 && saved.visible[0].note_id == firstIdentity.id && saved.visible[0].text == "前文后文" && (try notebookStore.imageData(saved.visible[0].images[0])) == encoded(.png), "notebook_inline_image_updates_same_paragraph")
        let count = saved.events.count
        saved = try MeetingNotebook.save([picture], knownIDs: [firstIdentity.id], store: notebookStore)
        try check(saved.events.count == count, "notebook_repeated_flush_is_idempotent")
        saved = try MeetingNotebook.save([], knownIDs: [firstIdentity.id], store: notebookStore)
        try check(saved.visible.isEmpty && saved.latest.first?.op == "delete" && saved.latest.first?.images.count == 1, "notebook_deleted_paragraph_keeps_tombstone_and_images")
        saved = try MeetingNotebook.save([paragraph(firstIdentity, "撤销并改字")], knownIDs: [firstIdentity.id], store: notebookStore)
        try check(saved.events.suffix(2).map(\.op) == ["restore", "edit"] && saved.visible.first?.anchor == stamp && saved.visible.first?.images.isEmpty == true, "notebook_undo_restore_then_edit_and_remove_images")
        let second = try paragraph(secondIdentity, "\u{fffc}", [encoded(.png)]), after = try paragraph(afterIdentity, "会后补充")
        saved = try MeetingNotebook.save([after, first, second], knownIDs: [firstIdentity.id], store: notebookStore)
        try check(saved.visible.first { $0.note_id == secondIdentity.id }?.text == "", "notebook_image_only_text_is_empty_without_placeholder")
        try check(MeetingNotebook.ordered(saved).map(\.note_id) == [secondIdentity.id, firstIdentity.id, afterIdentity.id], "notebook_rebuild_sorts_anchor_then_after_meeting")
        let tied = MeetingNoteIdentity(anchor: stamp)
        saved = try MeetingNotebook.save([first, paragraph(tied, "同一时刻")], knownIDs: [firstIdentity.id], store: notebookStore)
        try check(MeetingNotebook.ordered(saved).filter { $0.anchor == stamp }.map(\.note_id) == [firstIdentity.id, tied.id], "notebook_equal_anchor_keeps_creation_order")
        try check(saved.visible.contains { $0.note_id == secondIdentity.id }, "notebook_does_not_delete_unseen_other_window_note")
        try notebookStore.change(firstIdentity.id, starred: true, archive: false)
        saved = try MeetingNotebook.save([first], knownIDs: [firstIdentity.id], store: notebookStore)
        try check(saved.visible.first { $0.note_id == firstIdentity.id }?.starred == false && saved.visible.first { $0.note_id == firstIdentity.id }?.archive == true, "notebook_always_unstarred_and_archived")
        try notebookStore.change(firstIdentity.id, starred: true, archive: false)
        let export = run.appendingPathComponent("notebook-export"); try fm.createDirectory(at: export, withIntermediateDirectories: false)
        try notebookStore.export(to: export, absolute: absolute)
        let markdown = try String(contentsOf: export.appendingPathComponent("会中笔记.md"), encoding: .utf8)
        try check(!markdown.contains("仅参考") && !markdown.contains("⭐") && !markdown.contains("\u{fffc}"), "notebook_export_has_no_old_UI_labels_or_attachment_markers")
    }
    let referenceStore = MeetingNotesStore(directory: try cache())
    referenceStore.recognize = { _ in "合成引用图片" }
    try MeetingNotesStore.queue.sync {
        let png = encoded(.png), jpeg = encoded(.jpeg)
        let pngReference = try referenceStore.importImage(png), jpegReference = try referenceStore.importImage(jpeg)
        try check(try referenceStore.snapshot().events.isEmpty && referenceStore.imageData(pngReference) == png && referenceStore.imageData(jpegReference) == jpeg, "preimport_preserves_PNG_JPEG_original_bytes_before_note_save")
        let note = try referenceStore.create(text: "预算 \u{fffc}20 万", anchor: stamp, imageReferences: [pngReference])
        try check(note.text == "预算 20 万" && note.images == [pngReference] && (try referenceStore.imageData(note.images[0])) == png, "reference_create_keeps_original_bytes_and_clean_text")
        let changed = try referenceStore.change(note.note_id, text: "\u{fffc}", imageReferences: [jpegReference])
        try check(changed.text.isEmpty && changed.images == [jpegReference] && (try referenceStore.imageData(changed.images[0])) == jpeg, "reference_edit_keeps_original_JPEG_and_empty_image_only_text")
        let converted = try referenceStore.importImage(encoded(.tiff)), canonicalPNG = try referenceStore.imageData(converted)
        let imported = try referenceStore.change(note.note_id, imageReferences: [converted, converted])
        try check(converted.file.hasSuffix(".png") && imported.images == [converted, converted] && (try referenceStore.imageData(imported.images[0])) == canonicalPNG, "TIFF_converted_once_then_repeated_references_reuse_identical_PNG")
        let before = try referenceStore.snapshot().events.count
        var rejected = false, missing = pngReference; missing.sha256 = String(repeating: "0", count: 64); missing.file = "assets/" + missing.sha256 + ".png"
        do { _ = try referenceStore.change(note.note_id, imageReferences: [missing]) } catch { rejected = true }
        try check(rejected && (try referenceStore.snapshot()).events.count == before, "missing_image_reference_rejected_without_new_event")
        try check(try referenceStore.snapshot().events.allSatisfy { !$0.text.contains("\u{fffc}") }, "all_new_reference_events_have_placeholder_free_text")
    }

    let storageResult: [String: Any] = ["type":"meeting_notes_storage_checks", "passed":checks.count, "checks":checks, "fixtures":run.path, "slow_OCR_seconds":2, "image_save_seconds":firstSaveSeconds, "second_save_seconds":secondSaveSeconds, "write_barrier_seconds":barrierSeconds, "synthetic":true, "capture":false, "cloud":false, "keychain":false]
    try JSONSerialization.data(withJSONObject: storageResult, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("storage-checks.json"))
    if storageOnly { return storageResult }
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); NSApp.appearance = NSAppearance(named: .aqua)

    func makeView(_ folder: URL) -> Delegate {
        let value = Delegate(); value.previewRenderOnly = true
        value.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        // configureOfflineQA() sets its own default root during initialization.
        // Bind to this run only after initialization and before selecting a cache.
        value.recoveryRootOverride = run
        value.currentCacheID = folder.lastPathComponent; value.activeSession = "notes-fixture"
        value.absoluteTime = absolute; value.phase.phase = .recording; value.phase.elapsed = 15
        value.meetingTitle = "产品讨论｜会中笔记验证"; value.notesController!.now = { 1792239059 }
        value.updateUI(); return value
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    func edit(_ controller: MeetingNotesController, _ text: String, range: NSRange? = nil) {
        controller.editor.breakUndoCoalescing()
        controller.editor.noteUndoManager.groupsByEvent = false
        controller.editor.noteUndoManager.beginUndoGrouping(); defer { controller.editor.noteUndoManager.endUndoGrouping() }
        controller.editor.insertText(text, replacementRange: range ?? NSRange(location: (controller.editor.string as NSString).length, length: 0))
    }
    func flush(_ controller: MeetingNotesController) throws {
        try check(controller.flushPendingChanges(), "notebook_flush_\(checks.count)"); try drain(controller)
    }
    let undoEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
    let redoEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
    let folder = try cache(), view = makeView(folder), controller = view.notesController!, uiStore = controller.store!
    try check(controller.store?.directory.standardizedFileURL.path == folder.standardizedFileURL.path, "UI_fixture_bound_to_synthetic_cache")
    try check(!controller.expanded && controller.panel.isHidden && controller.toggle.title == "笔记", "notebook_default_collapsed_single_plain_toggle")
    try check(controller.transportRow?.arrangedSubviews.compactMap { $0 as? NSButton }.count == 1 && !descendants(controller.panel).contains { $0 is NSButton && !$0.isHidden }, "notebook_has_one_transport_switch_and_no_visible_panel_buttons")
    try check(descendants(controller.panel).compactMap { $0 as? NSTextView }.count == 1 && controller.status.isHidden && controller.editor.isPlaceholderVisible && controller.editor.placeholder == "记点什么…可直接粘贴截图", "notebook_single_text_view_empty_placeholder_no_status")
    try check(try fm.contentsOfDirectory(atPath: folder.path).isEmpty, "opening_empty_notebook_creates_no_files")
    controller.toggle.performClick(nil)
    try check(!controller.panel.isHidden && view.notesExpanded, "notebook_toggle_expands_and_remembers_window_state")
    edit(controller, "预算 15 万")
    let typed = try controller.paragraphs().first!, typedID = typed.identity.id
    try check(typed.identity.anchor?.relative == 15 && !controller.editor.isPlaceholderVisible, "paragraph_first_visible_content_captures_anchor_immediately")
    controller.now = { 1792239159 }
    RunLoop.current.run(until: Date().addingTimeInterval(0.65)); try drain(controller)
    try check(controller.snapshot.visible.first?.note_id == typedID && controller.snapshot.visible.first?.anchor?.relative == 15, "paragraph_500ms_debounce_creates_with_original_typing_time")
    try check(!fm.fileExists(atPath: uiStore.notes.appendingPathComponent("draft.json").path), "new_editor_does_not_write_draft_json")
    try check(controller.editor.textStorage?.attribute(.toolTip, at: 0, effectiveRange: nil) as? String == absolute.display(15), "paragraph_hover_tooltip_uses_clock_time")
    edit(controller, "20", range: (controller.editor.string as NSString).range(of: "15")); try flush(controller)
    try check(controller.snapshot.visible.first?.text == "预算 20 万" && controller.snapshot.visible.first?.anchor?.relative == 15 && controller.snapshot.visible.first?.note_id == typedID && controller.snapshot.visible.first?.op == "edit", "direct_edit_retains_paragraph_identity_and_anchor")
    edit(controller, "\n")
    let beforeEmpty = controller.snapshot.visible.count; try flush(controller)
    try check(controller.snapshot.visible.count == beforeEmpty, "return_inserts_line_without_empty_note")
    controller.now = { 1792239164 }
    edit(controller, "下周二确认"); try flush(controller)
    let secondID = controller.snapshot.visible.last!.note_id
    try check(controller.snapshot.visible.count == 2 && controller.snapshot.visible.last?.anchor?.relative == 120 && secondID != typedID, "new_paragraph_gets_new_identity_and_new_anchor")
    let secondRange = (controller.editor.string as NSString).range(of: "下周二确认")
    edit(controller, "", range: secondRange); try flush(controller)
    try check(controller.snapshot.latest.first { $0.note_id == secondID }?.op == "delete" && controller.snapshot.visible.count == 1, "deleting_paragraph_writes_tombstone")
    try check(controller.editor.performKeyEquivalent(with: undoEvent), "command_Z_routes_to_notebook_undo_manager")
    try flush(controller)
    try check(controller.snapshot.visible.first { $0.note_id == secondID }?.op == "restore" && controller.snapshot.visible.first { $0.note_id == secondID }?.anchor?.relative == 120, "command_Z_restores_same_id_and_anchor")
    _ = controller.editor.performKeyEquivalent(with: redoEvent); try flush(controller)
    try check(controller.snapshot.latest.first { $0.note_id == secondID }?.op == "delete", "command_shift_Z_redoes_paragraph_delete")
    _ = controller.editor.performKeyEquivalent(with: undoEvent); try flush(controller)
    let newline = (controller.editor.string as NSString).range(of: "\n")
    edit(controller, "", range: newline); try flush(controller)
    try check(controller.snapshot.visible.count == 1, "merging_paragraphs_deletes_second_identity")
    _ = controller.editor.performKeyEquivalent(with: undoEvent); try flush(controller)
    try check(Set(controller.snapshot.visible.map(\.note_id)) == Set([typedID, secondID]), "undo_paragraph_merge_restores_both_original_identities")
    view.phase.phase = .paused; view.phase.elapsed = 20
    edit(controller, "\n暂停补记"); try flush(controller)
    try check(controller.snapshot.visible.last?.anchor == MeetingNoteAnchor(relative: 20, state: "paused"), "paused_paragraph_uses_acknowledged_position")
    view.phase.phase = .stopped; edit(controller, "\n会后补充数字"); try flush(controller)
    let afterRange = (controller.editor.string as NSString).range(of: "会后补充数字")
    try check(controller.snapshot.visible.last?.anchor == nil && controller.editor.textStorage?.attribute(.toolTip, at: afterRange.location, effectiveRange: nil) as? String == "会后补充", "after_meeting_paragraph_has_null_anchor_and_tooltip")
    view.phase.phase = .recording
    let image = NSImage(size: NSSize(width: 400, height: 180))
    image.lockFocus(); NSColor(calibratedRed: 0.9, green: 0.95, blue: 0.93, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 400, height: 180)).fill()
    ("在场 · 讨论重点\n预算 15 万 / 下周二确认" as NSString).draw(at: NSPoint(x: 24, y: 65), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.labelColor]); image.unlockFocus()
    let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    board.declareTypes([.png], owner: nil); try check(board.setData(png, forType: .png), "synthetic_image_pasteboard_has_PNG")
    uiStore.recognize = { _ in throw Failure(code: "synthetic_ocr_failure") }
    controller.editor.pasteboardOverride = board
    try check(view.window.makeFirstResponder(controller.editor), "notebook_accepts_paste_focus")
    controller.editor.setSelectedRange(NSRange(location: 3, length: 0)); view.paste(nil); try flush(controller)
    let picture = controller.snapshot.visible.first { $0.note_id == typedID }!
    try check(picture.images.count == 1 && picture.text == "预算 20 万" && (try uiStore.imageData(picture.images[0])) == png, "command_V_embeds_original_image_in_current_paragraph")
    try check(controller.editor.textStorage?.attribute(.attachment, at: 3, effectiveRange: nil) is NSTextAttachment, "pasted_picture_is_native_text_attachment")
    try check(controller.editor.textStorage?.attribute(.zaichangNoteImageSHA, at: 3, effectiveRange: nil) as? String == MeetingNotesStore.hash(png), "paste_retains_original_SHA_attribute_after_AppKit_insertion")
    _ = controller.editor.performKeyEquivalent(with: undoEvent); try flush(controller)
    try check(controller.snapshot.visible.first { $0.note_id == typedID }?.images.isEmpty == true && controller.snapshot.visible.first { $0.note_id == typedID }?.text == "预算 20 万", "one_undo_removes_entire_image_paste_without_changing_text")
    _ = controller.editor.performKeyEquivalent(with: redoEvent); try flush(controller)
    try check(controller.snapshot.visible.first { $0.note_id == typedID }?.images == picture.images && (try uiStore.imageData(picture.images[0])) == png, "redo_image_paste_restores_original_SHA_and_bytes")
    // Emulate AppKit replacing the attachment with a different encoding. The
    // independent SHA attribute must still select the originally imported PNG.
    let jpeg = NSBitmapImageRep(data: png)!.representation(using: .jpeg, properties: [:])!
    controller.editor.textStorage!.addAttribute(.attachment, value: try MeetingNoteEditor.attachment(jpeg), range: NSRange(location: 3, length: 1))
    edit(controller, "21", range: (controller.editor.string as NSString).range(of: "20")); try flush(controller)
    try check(controller.snapshot.visible.first { $0.note_id == typedID }?.images == picture.images && (try uiStore.imageData(picture.images[0])) == png, "saving_ignores_replaced_or_reencoded_AppKit_attachment")
    edit(controller, "20", range: (controller.editor.string as NSString).range(of: "21")); try flush(controller)
    controller.editor.pasteboardOverride = nil
    controller.editor.setSelectedRange(NSRange(location: (controller.editor.string as NSString).length, length: 0))
    edit(controller, "\n"); let drag = NotesDragFixture(board)
    try check(controller.editor.draggingEntered(drag) == .copy && controller.editor.performDragOperation(drag), "image_drag_inserts_attachment_into_notebook")
    try flush(controller)
    try check(controller.snapshot.visible.last?.text == "" && controller.snapshot.visible.last?.images.count == 1, "image_only_paragraph_is_saved")
    try check(try fm.contentsOfDirectory(atPath: uiStore.notes.appendingPathComponent("assets").path).count == 1, "same_image_paste_and_drag_deduplicate_asset")
    try check(try uiStore.snapshot().events.allSatisfy { !$0.text.contains("\u{fffc}") }, "UI_note_events_never_persist_attachment_placeholders")
    let pasteView = makeView(try cache()), pasteController = pasteView.notesController!
    pasteController.store!.recognize = { _ in "合成图片" }
    pasteController.editor.noteUndoManager.groupsByEvent = false
    let pasteBoard = NSPasteboard.withUniqueName(); defer { pasteBoard.releaseGlobally() }
    pasteController.editor.pasteboardOverride = pasteBoard
    pasteBoard.declareTypes([.string], owner: nil); pasteBoard.setString("粘贴甲\n粘贴乙", forType: .string)
    pasteController.editor.paste(nil); try flush(pasteController)
    try check(pasteController.snapshot.visible.map(\.text) == ["粘贴甲", "粘贴乙"], "plain_text_paste_works_without_AppKit_event_group")
    _ = pasteController.editor.performKeyEquivalent(with: undoEvent); try flush(pasteController)
    try check(pasteController.snapshot.visible.isEmpty && pasteController.editor.string.isEmpty, "one_undo_removes_entire_multiline_text_paste")
    let jpegType = NSPasteboard.PasteboardType("public.jpeg")
    pasteBoard.declareTypes([jpegType], owner: nil); pasteBoard.setData(jpeg, forType: jpegType)
    pasteController.editor.paste(nil); try flush(pasteController)
    let jpegNote = pasteController.snapshot.visible.first!
    try check(jpegNote.text.isEmpty && jpegNote.images.count == 1 && (try pasteController.store!.imageData(jpegNote.images[0])) == jpeg, "UI_JPEG_paste_retains_original_bytes")
    edit(pasteController, "\n")
    pasteBoard.declareTypes([.tiff], owner: nil); pasteBoard.setData(image.tiffRepresentation!, forType: .tiff)
    pasteController.editor.paste(nil); try flush(pasteController)
    let tiffNote = pasteController.snapshot.visible.last!, convertedBytes = try pasteController.store!.imageData(tiffNote.images[0])
    try check(tiffNote.text.isEmpty && tiffNote.images[0].file.hasSuffix(".png") && MeetingNotesStore.hash(convertedBytes) == tiffNote.images[0].sha256, "UI_TIFF_paste_uses_once_converted_PNG_reference")
    // Switching synchronously flushes the old editor, before any new binding.
    edit(controller, "\nA 切换前的最后输入")
    let other = try cache(); view.currentCacheID = other.lastPathComponent
    edit(controller, "B 专属笔记"); view.currentCacheID = folder.lastPathComponent
    try check(controller.editor.string.contains("A 切换前的最后输入") && !controller.editor.string.contains("B 专属笔记"), "A_B_A_flushes_and_restores_without_cross_writes")
    try check(try MeetingNotesStore(directory: other).snapshot().visible.map(\.text) == ["B 专属笔记"], "switch_flushes_B_before_returning_to_A")
    try check(!controller.editor.noteUndoManager.canUndo, "switching_meetings_clears_other_meeting_undo_history")
    let reopenedIDs = try controller.paragraphs().map { $0.identity.id }
    try check(reopenedIDs == MeetingNotebook.ordered(controller.snapshot).map(\.note_id), "reopened_notebook_rebuilt_in_anchor_order_after_notes_last")
    let imagePosition = NSMaxRange((controller.editor.string as NSString).range(of: "预算 20 万"))
    try check(controller.editor.textStorage?.attribute(.attachment, at: imagePosition, effectiveRange: nil) is NSTextAttachment && controller.editor.textStorage?.attribute(.zaichangNoteImageSHA, at: imagePosition, effectiveRange: nil) as? String == picture.images[0].sha256, "reopening_appends_image_with_original_SHA_to_paragraph_end")
    edit(controller, "\n关窗前最后输入"); try check(view.windowShouldClose(view.window), "window_close_flush_succeeds")
    try check(try uiStore.snapshot().visible.contains { $0.text == "关窗前最后输入" }, "window_close_flushes_unexpired_debounce")
    let reopened = makeView(folder)
    try check(reopened.notesController!.editor.string.contains("关窗前最后输入"), "new_window_rebuilds_saved_notebook")
    let history = makeView(try cache()); history.isHistoryReader = true
    edit(history.notesController!, "历史会议补记"); try flush(history.notesController!)
    try check(history.notesController!.snapshot.visible.first?.anchor == nil, "historical_meeting_note_is_after_meeting_even_with_recording_clock")
    let legacy = try cache(), legacyStore = MeetingNotesStore(directory: legacy)
    try legacyStore.saveDraft("旧版未保存内容")
    let legacyView = makeView(legacy), legacyController = legacyView.notesController!
    try flush(legacyController)
    try check(legacyController.snapshot.visible.first?.text == "旧版未保存内容" && (try legacyStore.draft()).isEmpty, "legacy_draft_imported_once_into_durable_notes")
    legacyView.currentCacheID = other.lastPathComponent; legacyView.currentCacheID = legacy.lastPathComponent
    try check(legacyController.snapshot.visible.count == 1, "legacy_draft_not_duplicated_on_reopen")
    let malformed = try cache(), malformedStore = MeetingNotesStore(directory: malformed)
    try malformedStore.saveDraft("旧草稿"); try Data("{broken".utf8).write(to: malformedStore.notes.appendingPathComponent("draft.json"))
    let malformedView = makeView(malformed)
    try check(malformedView.notesController!.lastError == nil && malformedView.notesController!.editor.isEditable, "malformed_legacy_draft_does_not_block_notebook")
    // A damaged attachment must not make otherwise durable text disappear.
    // The degraded view stays read-only; its placeholder never becomes a note.
    for damage in ["missing", "corrupt"] {
        let damagedFolder = try cache(), damagedStore = MeetingNotesStore(directory: damagedFolder)
        damagedStore.recognize = { _ in throw Failure(code: "synthetic_ocr_failure") }
        let savedNote = try MeetingNotesStore.queue.sync { () throws -> MeetingNote in
            let note = try damagedStore.create(text: "图片前的有效文字", images: [png], anchor: nil)
            _ = try damagedStore.create(text: "图片后的有效文字", anchor: nil)
            return note
        }
        let asset = damagedStore.notes.appendingPathComponent(savedNote.images[0].file)
        let original = try Data(contentsOf: asset)
        let journal = damagedStore.notes.appendingPathComponent("notes.jsonl")
        let durableBefore = try Data(contentsOf: journal)
        if damage == "missing" { try fm.removeItem(at: asset) }
        else { try Data("invalid image bytes".utf8).write(to: asset, options: .atomic) }
        let damagedView = makeView(damagedFolder), damaged = damagedView.notesController!
        try check(damaged.editor.string.contains("图片前的有效文字") && damaged.editor.string.contains("图片后的有效文字") && damaged.editor.string.contains("[图片无法读取]"), "\(damage)_image_keeps_all_note_text_visible")
        try check(!damaged.editor.isEditable && !damaged.retryLoadButton.isHidden && damaged.status.stringValue.contains("只读"), "\(damage)_image_has_readonly_state_and_retry")
        try check(damaged.flushPendingChanges() && damaged.flushForClosing() && (try Data(contentsOf: journal)) == durableBefore, "\(damage)_image_placeholder_never_overwrites_durable_notes")
        try check(!damaged.status.isHidden, "\(damage)_image_close_flush_preserves_load_warning")
        let export = run.appendingPathComponent("damaged-image-export-" + UUID().uuidString)
        try fm.createDirectory(at: export, withIntermediateDirectories: false)
        var exportRejected = false
        do { try damagedStore.export(to: export, absolute: absolute) } catch { exportRejected = true }
        try check(exportRejected && (try Data(contentsOf: journal)) == durableBefore, "\(damage)_image_export_fails_without_dropping_original_reference")
        try original.write(to: asset, options: .atomic)
        damaged.retryLoadButton.performClick(nil)
        try check(damaged.editor.isEditable && damaged.retryLoadButton.isHidden && damaged.status.isHidden && !damaged.editor.string.contains("[图片无法读取]"), "\(damage)_image_retry_recovers_editable_notebook")
        try check((try Data(contentsOf: journal)) == durableBefore && damaged.snapshot.visible.first?.images == savedNote.images, "\(damage)_image_retry_preserves_revisions_and_original_image_reference")
        edit(damaged, "\n恢复后的新输入"); try flush(damaged)
        try check((try damagedStore.snapshot()).visible.contains { $0.text == "恢复后的新输入" }, "\(damage)_image_recovery_can_save_again")
        damagedView.window.orderOut(nil)
    }
    let failedFolder = try cache(), failureView = makeView(failedFolder), failedController = failureView.notesController!
    try Data("blocking file".utf8).write(to: failedFolder.appendingPathComponent("notes"))
    edit(failedController, "失败时保留我的文字")
    try check(!failedController.flushPendingChanges() && !failedController.status.isHidden && failedController.editor.string == "失败时保留我的文字", "save_error_is_only_status_and_keeps_editor_content")
    try check(!failureView.windowShouldClose(failureView.window) && failureView.applicationShouldTerminate(NSApp) == .terminateCancel, "failed_save_prevents_close_and_quit_from_losing_text")
    try fm.removeItem(at: failedFolder.appendingPathComponent("notes")); try flush(failedController)
    try check(failedController.status.isHidden && failedController.snapshot.visible.count == 1, "retry_saves_buffer_and_hides_error")
    let failedSwitchFolder = try cache(), failedSwitchView = makeView(failedSwitchFolder), failedSwitch = failedSwitchView.notesController!
    try Data("blocking file".utf8).write(to: failedSwitchFolder.appendingPathComponent("notes"))
    edit(failedSwitch, "切场失败仍保留 A")
    failedSwitchView.currentCacheID = other.lastPathComponent
    try check(!failedSwitchView.windowShouldClose(failedSwitchView.window), "close_cannot_discard_failed_previous_meeting_buffer")
    try fm.removeItem(at: failedSwitchFolder.appendingPathComponent("notes"))
    try check(failedSwitchView.windowShouldClose(failedSwitchView.window) && (try MeetingNotesStore(directory: failedSwitchFolder).snapshot()).visible.first?.text == "切场失败仍保留 A", "close_retries_failed_previous_meeting_without_cross_writes")
    let failedHistoryFolder = try cache(), failedHistory = makeView(failedHistoryFolder), historyOwner = makeView(try cache())
    try Data("blocking file".utf8).write(to: failedHistoryFolder.appendingPathComponent("notes"))
    edit(failedHistory.notesController!, "历史阅读器未落盘内容")
    historyOwner.historyReader = failedHistory; historyOwner.returnToCurrent()
    try check(historyOwner.historyReader === failedHistory, "failed_history_flush_keeps_reader_alive")
    try fm.removeItem(at: failedHistoryFolder.appendingPathComponent("notes")); historyOwner.returnToCurrent()
    try check(historyOwner.historyReader == nil && (try MeetingNotesStore(directory: failedHistoryFolder).snapshot()).visible.first?.text == "历史阅读器未落盘内容", "leaving_history_flushes_before_discarding_reader")
    let linked = try cache(); try fm.createSymbolicLink(at: linked.appendingPathComponent("notes"), withDestinationURL: uiStore.notes)
    var rejectedLink = false; do { _ = try MeetingNotesStore(directory: linked).snapshot() } catch { rejectedLink = true }
    try check(rejectedLink, "notes_symlink_rejected")
    // Verify the actual "打开会议文件…" handler as well as the storage hook.
    for withNotes in [true, false] {
        let folder = try cache(), exportView = makeView(folder)
        exportView.phase.phase = .stopped
        let session = "notes-export-" + folder.lastPathComponent
        try JSONSerialization.data(withJSONObject: ["session":session,"cache_id":folder.lastPathComponent,"capture_mode":"local_only"]).write(to: folder.appendingPathComponent("meeting.json"))
        try Data("合成会议原文，保持完整。".utf8).write(to: folder.appendingPathComponent("archived-transcript.txt"))
        let target = CachedMeeting(id:folder.lastPathComponent,directory:run.appendingPathComponent(folder.lastPathComponent),date:Date(),writtenBytes:0,pendingBytes:0,occupiedBytes:0,tracks:[],audioCleaned:true,warning:false,retiredBytes:0)
        if withNotes {
            let noteStore = exportView.notesController!.store!; noteStore.recognize = { _ in "导出图片" }
            try MeetingNotesStore.queue.sync { _ = try noteStore.create(text:"导出笔记",images:[png],anchor:nil) }
        }
        let management = exportView.libraryManagementController
        exportView.libraryMenuTarget = target; management.contextMenuOpen = true
        management.item = target; management.loadedID = target.id; management.files = try MeetingLibraryFiles.read(target, root:run)
        management.audioStoreOverride = MeetingAudioAssetsStore(cacheRoot:run,exportsRoot:directory.appendingPathComponent("UI-exports-" + run.lastPathComponent))
        var opened: URL?
        management.revealOverride = { opened = $0; return true }
        if withNotes {
            // No flush or run-loop tick: export must include an unexpired edit
            // and pasted image through the real editor/handler boundary.
            edit(exportView.notesController!, "导出前最后输入")
            let exportBoard = NSPasteboard.withUniqueName()
            exportBoard.declareTypes([.png], owner: nil); exportBoard.setData(png, forType: .png)
            exportView.notesController!.editor.pasteboardOverride = exportBoard
            exportView.notesController!.editor.paste(nil)
        }
        management.openMeetingFiles(target)
        exportView.cacheWriteQueue.sync {}
        let deadline = Date().addingTimeInterval(5)
        while management.busy && Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        guard let opened else { throw Failure(code:"UI_meeting_files_export_failed: " + management.status.stringValue) }
        let contents = try fm.contentsOfDirectory(atPath:opened.path)
        try check(contents.contains("会中笔记.md") == withNotes && contents.contains("会中笔记.assets") == withNotes && contents.contains(".meeting-notes-export.json") == withNotes, withNotes ? "UI_meeting_files_action_exports_notes_and_images" : "UI_meeting_files_action_without_notes_creates_no_note_files")
        if withNotes {
            let exported = try String(contentsOf: opened.appendingPathComponent("会中笔记.md"), encoding: .utf8)
            try check(exported.contains("导出前最后输入") && exportView.notesController!.snapshot.visible.contains { $0.text == "导出前最后输入" && !$0.images.isEmpty }, "export_flushes_pending_editor_text_and_image_before_reading_store")
            let source = exportView.notesController!.store!.notes
            let held = folder.appendingPathComponent("notes-held-for-failure-check")
            try fm.moveItem(at: source, to: held)
            try Data("blocked notes directory".utf8).write(to: source)
            edit(exportView.notesController!, "保存失败不导出旧稿")
            var failedExportOpened = false
            management.revealOverride = { _ in failedExportOpened = true; return true }
            management.openMeetingFiles(target)
            exportView.cacheWriteQueue.sync {}
            let failureDeadline = Date().addingTimeInterval(5)
            while management.busy && Date() < failureDeadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
            try check(!failedExportOpened && !management.busy && exportView.notesController!.lastError != nil, "export_stops_if_current_note_revision_cannot_be_saved")
            try fm.removeItem(at: source); try fm.moveItem(at: held, to: source)
            management.openMeetingFiles(target)
            exportView.cacheWriteQueue.sync {}
            let retryDeadline = Date().addingTimeInterval(5)
            while management.busy && Date() < retryDeadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
            let retried = try String(contentsOf: opened.appendingPathComponent("会中笔记.md"), encoding: .utf8)
            try check(failedExportOpened && retried.contains("保存失败不导出旧稿"), "export_retries_saved_editor_after_storage_recovers")
        }
        management.readJob.cancel()
    }
    // Actual AppKit views rendered offscreen; no desktop screenshot or capture.
    let shots = directory.appendingPathComponent("shots", isDirectory: true)
    try fm.createDirectory(at: shots, withIntermediateDirectories: true)
    let visual = makeView(try cache()), notes = visual.notesController!
    for (i, text) in ["先核对预算数字，再确定下一步。", "预算按十五万元准备，下周二确认。", "图片里保留了这次讨论的重点。"].enumerated() {
        visual.receive(["type": "segment", "session": "notes-fixture", "segment_id": "notes-turn-\(i)", "track": "mic", "source_id": "mic", "epoch": "fixture", "start": Double(i * 8), "end": Double(i * 8 + 6), "text": text, "revision": 1, "final": true, "speaker": ["basis": "unknown"]])
    }
    try visual.settleTranscriptForOfflineReview()
    func screenshot(_ name: String, width: CGFloat) throws {
        visual.window.setContentSize(NSSize(width: width, height: 760)); visual.layoutWorkspace(); visual.updateUI()
        visual.window.contentView!.layoutSubtreeIfNeeded(); visual.resizeTranscript(); notes.editor.fitAttachments()
        let target = visual.window.contentView!.superview!; target.layoutSubtreeIfNeeded()
        try check(abs(visual.window.contentLayoutRect.width - width) < 1, "window_width_\(name)")
        if notes.expanded {
            try check(name.hasPrefix("05") ? notes.panel.bounds.width >= MeetingNotesController.minimumWidth && visual.scroll.bounds.width >= MeetingNotesController.minimumTranscriptWidth - 1 : notes.panel.bounds.width >= 280 && notes.panel.bounds.width <= 360 && visual.scroll.bounds.width > 200, "panel_transcript_fit_\(name)")
            let panelRect = notes.panel.convert(notes.panel.bounds, to: target), transcriptRect = visual.scroll.convert(visual.scroll.bounds, to: target)
            try check(abs(panelRect.maxY - transcriptRect.maxY) <= 1, "notebook_top_aligns_with_transcript_\(name)")
            // Recovery is available only for a failed load. A hidden retry button
            // must not invalidate the normal notebook's clean visual contract.
            let panelButtons = descendants(notes.panel).compactMap { $0 as? NSButton }
            try check(panelButtons.allSatisfy { $0 === notes.retryLoadButton && $0.isHidden } && notes.retryLoadButton.isHidden && notes.status.isHidden, "notebook_clean_panel_\(name)")
            var fits = true
            notes.editor.textStorage!.enumerateAttribute(.attachment, in: NSRange(location: 0, length: notes.editor.textStorage!.length)) { value, _, _ in
                if let image = value as? NSTextAttachment { fits = fits && image.bounds.width > 0 && image.bounds.width <= notes.editor.bounds.width - 12 }
            }
            try check(fits, "inline_images_fit_notebook_width_\(name)")
        }
        guard let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { throw Failure(code: "notes_screenshot_bitmap") }
        target.effectiveAppearance.performAsCurrentDrawingAppearance { target.cacheDisplay(in: target.bounds, to: bitmap) }
        try bitmap.representation(using: .png, properties: [:])!.write(to: shots.appendingPathComponent(name + ".png"))
    }
    UserDefaults.standard.removeObject(forKey: MeetingNotesController.widthKey)
    try screenshot("01-collapsed", width: 1040)
    notes.togglePanel(); edit(notes, "预算 15 万，下周二确认。\n先核对专名和数字。\n把讨论重点记在这里。"); try flush(notes)
    try screenshot("02-expanded", width: 1040)
    notes.store!.recognize = { _ in "预算 15 万" }
    edit(notes, "\n"); _ = notes.editor.pasteImages(board); try flush(notes)
    try screenshot("03-image-1200", width: 1200)
    try screenshot("04-image-640", width: 640)
    // Drag the left hairline like a user: widen, clamp both ways, double-click resets.
    visual.window.setContentSize(NSSize(width: 1200, height: 760)); visual.layoutWorkspace()
    let defaultWidth = notes.panelWidth.constant
    func mouse(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: visual.window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    func grip() -> NSPoint { notes.panel.convert(NSPoint(x: 3, y: notes.panel.bounds.midY), to: nil) }
    let start = grip(), end = NSPoint(x: start.x - 140, y: start.y)
    notes.panel.mouseDown(with: mouse(.leftMouseDown, start)); notes.panel.mouseDragged(with: mouse(.leftMouseDragged, end)); notes.panel.mouseUp(with: mouse(.leftMouseUp, end))
    try check(abs(notes.panelWidth.constant - (defaultWidth + 140)) < 1 && UserDefaults.standard.double(forKey: MeetingNotesController.widthKey) == Double(notes.panelWidth.constant), "drag_left_edge_widens_notes_and_remembers_width")
    try screenshot("05-resized-1200", width: 1200)
    try check(abs(notes.panelWidth.constant - (defaultWidth + 140)) < 1, "remembered_width_survives_relayout")
    notes.setPanelWidth(5000); visual.window.contentView?.layoutSubtreeIfNeeded()
    try check(notes.panelWidth.constant <= (notes.panel.superview?.bounds.width ?? 0) - MeetingNotesController.minimumTranscriptWidth + 0.5, "notes_width_keeps_transcript_readable")
    notes.setPanelWidth(10)
    try check(notes.panelWidth.constant == MeetingNotesController.minimumWidth, "notes_width_minimum")
    notes.panel.mouseDown(with: mouse(.leftMouseDown, grip(), clicks: 2))
    try check(UserDefaults.standard.object(forKey: MeetingNotesController.widthKey) == nil && notes.panelWidth.constant == defaultWidth, "double_click_hairline_resets_notes_width")
    notes.togglePanel(); visual.window.setContentSize(NSSize(width: 1200, height: 760)); visual.layoutWorkspace()
    try check(abs(visual.window.contentLayoutRect.width - 1200) < 1, "collapse_does_not_lock_window_width")
    edit(controller, "\n退出前最后一条")
    var terminated = false; view.terminationReplyOverride = { terminated = true }
    try check(view.applicationShouldTerminate(NSApp) == .terminateLater, "cmd_Q_uses_existing_termination_gate")
    let deadline = Date().addingTimeInterval(5)
    while !terminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    try check(terminated && (try uiStore.snapshot()).visible.contains { $0.text == "退出前最后一条" }, "cmd_Q_flushes_debounce_and_drains_notes_write_queue")
    return ["type": "meeting_notes_checks", "passed": checks.count, "checks": checks, "fixtures": run.path,
            "images": ["01-collapsed.png", "02-expanded.png", "03-image-1200.png", "04-image-640.png", "05-resized-1200.png"].map { shots.appendingPathComponent($0).path }, "capture": false, "cloud": false, "keychain": false, "synthetic": true]
}
