import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Explicit references from assistant messages. A filename alone never guesses a path.
enum MeetingAssistantLinks {
    static func isBitmap(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "heic", "webp", "gif", "tif", "tiff"].contains(url.pathExtension.lowercased())
    }
    struct Reference {
        let range: NSRange
        let label: String
        let target: String
    }

    enum Content {
        case text(String)
        case file(label: String, url: URL)
    }

    /// Preserve prose/image order while coalescing a download link and its image.
    static func content(in text: String, base: URL) -> [Content] {
        let ns = text as NSString
        let refs = references(in: text)
        var result: [Content] = [], seen = Set<String>(), cursor = 0
        for ref in refs {
            guard let url = localURL(ref.target, base: base) else { continue }
            var start = ref.range.location
            if start > 0, ns.character(at: start - 1) == 33 { start -= 1 }
            let prose = ns.substring(with: NSRange(location: cursor, length: start - cursor)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prose.isEmpty { result.append(.text(prose)) }
            cursor = NSMaxRange(ref.range)
            guard seen.insert(url.path).inserted else { continue }
            var label = ref.label
            if isBitmap(url) {
                if let imageRef = refs.first(where: {
                    $0.range.location > 0 && ns.character(at: $0.range.location - 1) == 33 && localURL($0.target, base: base) == url
                }) { label = imageRef.label }
                label = label.replacingOccurrences(of: "^(下载|打开|查看)\\s*", with: "", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "「」『』“”\" "))
            }
            result.append(.file(label: label, url: url))
        }
        let tail = ns.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(.text(tail)) }
        return result
    }

    static func references(in text: String) -> [Reference] {
        let ns = text as NSString
        guard let starts = try? NSRegularExpression(pattern: "\\[([^\\]\\n]+)\\]\\(") else { return [] }
        var results: [Reference] = [], consumed = 0
        for match in starts.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.range.location >= consumed {
            let start = NSMaxRange(match.range)
            var cursor = start, depth = 1, angle = false
            while cursor < ns.length {
                let c = ns.character(at: cursor)
                if c == 10 { break }
                if c == 60 && cursor == start { angle = true }
                else if c == 62 && angle { angle = false }
                else if !angle && c == 40 { depth += 1 }
                else if !angle && c == 41 { depth -= 1; if depth == 0 { break } }
                cursor += 1
            }
            guard depth == 0 else { continue }
            consumed = cursor + 1
            var target = ns.substring(with: NSRange(location: start, length: cursor - start))
            if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
            results.append(Reference(range: NSRange(location: match.range.location, length: consumed - match.range.location),
                                     label: ns.substring(with: match.range(at: 1)), target: target))
        }
        return results
    }

    static func localURL(_ target: String, base: URL) -> URL? {
        let raw: URL
        if target.hasPrefix("file:") {
            guard let url = URL(string: target), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            raw = url
        } else if target.hasPrefix("/") || target.hasPrefix("~/") {
            raw = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
        } else if target.hasPrefix("./") || target.hasPrefix("../") {
            raw = base.appendingPathComponent(target)
        } else { return nil }
        var path = raw.path
        if !FileManager.default.fileExists(atPath: path),
           let decoded = path.removingPercentEncoding, FileManager.default.fileExists(atPath: decoded) { path = decoded }
        // Codex source links may include :line[:column]. Prefer an existing literal filename.
        if !FileManager.default.fileExists(atPath: path),
           let suffix = path.range(of: ":\\d+(?::\\d+)?$", options: .regularExpression) {
            path = String(path[..<suffix.lowerBound])
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func webURL(_ target: String) -> URL? {
        guard let url = URL(string: target), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    static func copyImage(_ url: URL, to pasteboard: NSPasteboard = .general) throws {
        let data = try Data(contentsOf: url)
        guard let image = NSImage(data: data), image.isValid, let tiff = image.tiffRepresentation else {
            throw NSError(domain: "MeetingAssistantImage", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取图片"])
        }
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        if url.pathExtension.lowercased() == "png" { pasteboard.setData(data, forType: .png) }
    }

    static func saveImage(_ source: URL, to destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        // Preserve the original encoding and resolution, never the thumbnail.
        let data = try Data(contentsOf: source)
        try data.write(to: destination, options: .atomic)
    }

    static func open(_ url: URL, completion: @escaping (String?) -> Void) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            completion("文件已移动或不存在：\(url.lastPathComponent)"); return
        }
        // References are for documents, never for executing downloaded applications/scripts.
        if ["app", "command", "workflow", "scpt", "sh", "exe"].contains(url.pathExtension.lowercased()) {
            NSWorkspace.shared.activateFileViewerSelecting([url]); completion(nil); return
        }
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async { completion(error == nil ? nil : "无法打开文件：\(url.lastPathComponent)") }
        }
    }
}

/// Supporting files stay available without competing with the delivered artwork.
final class MeetingAssistantAttachments: NSStackView {
    private let toggle = NSButton()
    private let contents = NSStackView()
    init(rows: [MeetingAssistantFileRow]) {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        toggle.title = "附件（\(rows.count)）"; toggle.setButtonType(.pushOnPushOff)
        toggle.isBordered = false; toggle.imagePosition = .imageLeading
        toggle.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        toggle.font = .systemFont(ofSize: 12); toggle.contentTintColor = .secondaryLabelColor
        toggle.target = self; toggle.action = #selector(toggleContents)
        toggle.setAccessibilityLabel("展开附件，\(rows.count) 个文件")
        addArrangedSubview(toggle)
        contents.orientation = .vertical; contents.alignment = .leading; contents.spacing = 8
        addArrangedSubview(contents); contents.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        for row in rows { contents.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: contents.widthAnchor).isActive = true }
        contents.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggleContents() {
        contents.isHidden = toggle.state != .on
        toggle.image = NSImage(systemSymbolName: contents.isHidden ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
        toggle.setAccessibilityLabel(contents.isHidden ? "展开附件" : "收起附件")
    }
}

final class MeetingAssistantFileRow: NSStackView {
    let referenceURL: URL
    let openButton = NSButton()
    private let copyButton = NSButton()
    private let saveButton = NSButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    var onOpened: ((String?) -> Void)?
    init(label: String, url: URL) {
        referenceURL = url
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        var directory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        openButton.title = label; openButton.isBordered = false; openButton.alignment = .left
        openButton.font = .systemFont(ofSize: 13, weight: .medium)
        openButton.contentTintColor = MeetingVisualStyle.ink
        openButton.image = NSImage(systemSymbolName: directory.boolValue ? "folder" : "doc.text", accessibilityDescription: nil)
        openButton.imagePosition = .imageLeading; openButton.lineBreakMode = .byTruncatingMiddle
        openButton.toolTip = url.path; openButton.setAccessibilityLabel("打开\(directory.boolValue ? "文件夹" : "文件")：\(label)")
        openButton.target = self; openButton.action = #selector(openReference)
        if MeetingAssistantLinks.isBitmap(url) {
            openButton.image = nil; openButton.font = .systemFont(ofSize: 14, weight: .medium)
            addArrangedSubview(openButton)
            openButton.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
            copyButton.title = "复制图片"; copyButton.target = self; copyButton.action = #selector(copyReference)
            saveButton.title = "另存为…"; saveButton.target = self; saveButton.action = #selector(saveReference)
            for button in [copyButton, saveButton] {
                button.bezelStyle = .rounded; button.controlSize = .small
                button.font = .systemFont(ofSize: 12)
                button.widthAnchor.constraint(equalToConstant: 82).isActive = true
            }
            let actions = NSStackView(views: [copyButton, saveButton]); actions.spacing = 8
            openButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addArrangedSubview(actions); actions.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
        } else {
            addArrangedSubview(openButton); openButton.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .secondaryLabelColor
        addArrangedSubview(errorLabel); errorLabel.isHidden = true
        errorLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
        // Existing links (including ordinary Markdown links) preview bitmap
        // files. Decode a bounded thumbnail off the UI thread, never the full
        // print-resolution poster, and retain the original file action.
        if MeetingAssistantLinks.isBitmap(url) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1400
                      ] as CFDictionary) else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let preview = NSImageView()
                    preview.image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
                    preview.imageScaling = .scaleProportionallyUpOrDown
                    preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                    preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
                    preview.setContentHuggingPriority(.defaultLow, for: .vertical)
                    preview.setAccessibilityLabel("图片预览：\(label)，点击打开原图")
                    preview.menu = self.referenceMenu()
                    preview.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(self.openReference)))
                    self.insertArrangedSubview(preview, at: 1)
                    preview.widthAnchor.constraint(lessThanOrEqualTo: self.widthAnchor).isActive = true
                    let fill = preview.widthAnchor.constraint(equalTo: self.widthAnchor)
                    fill.priority = .defaultHigh; fill.isActive = true
                    let ratio = preview.heightAnchor.constraint(equalTo: preview.widthAnchor, multiplier: CGFloat(thumbnail.height) / CGFloat(thumbnail.width))
                    ratio.isActive = true
                    preview.heightAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
                }
            }
        }
        openButton.menu = referenceMenu(); menu = referenceMenu()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func referenceMenu() -> NSMenu {
        let menu = NSMenu()
        if MeetingAssistantLinks.isBitmap(referenceURL) {
            for (title, action) in [("复制图片", #selector(copyReference)), ("另存为…", #selector(saveReference))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let reveal = NSMenuItem(title: "在访达中显示", action: #selector(revealReference), keyEquivalent: "")
        reveal.target = self; menu.addItem(reveal)
        return menu
    }
    private func showResult(_ text: String) { errorLabel.stringValue = text; errorLabel.isHidden = false }
    private func showSuccess(on button: NSButton, title: String, restore: String) {
        errorLabel.isHidden = true; button.title = title
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak button] in button?.title = restore }
    }
    @objc private func copyReference() {
        do { try MeetingAssistantLinks.copyImage(referenceURL); showSuccess(on: copyButton, title: "已复制", restore: "复制图片") }
        catch { showResult("无法复制图片：\(error.localizedDescription)") }
    }
    @objc private func saveReference() {
        guard FileManager.default.fileExists(atPath: referenceURL.path) else { showResult("图片已移动或不存在"); return }
        let panel = NSSavePanel()
        panel.title = "图片另存为"; panel.nameFieldStringValue = referenceURL.lastPathComponent
        panel.directoryURL = referenceURL.deletingLastPathComponent()
        if let type = UTType(filenameExtension: referenceURL.pathExtension) { panel.allowedContentTypes = [type] }
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            do { try MeetingAssistantLinks.saveImage(self.referenceURL, to: destination); self.showSuccess(on: self.saveButton, title: "已保存", restore: "另存为…") }
            catch { self.showResult("无法保存图片：\(error.localizedDescription)") }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }
    @objc private func openReference() {
        MeetingAssistantLinks.open(referenceURL) { [weak self] error in
            self?.errorLabel.stringValue = error ?? ""; self?.errorLabel.isHidden = error == nil
            self?.onOpened?(error)
        }
    }
    @objc private func revealReference() {
        guard FileManager.default.fileExists(atPath: referenceURL.path) else { openReference(); return }
        NSWorkspace.shared.activateFileViewerSelecting([referenceURL])
    }
}
