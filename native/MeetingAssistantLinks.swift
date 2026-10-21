import AppKit

/// Explicit references from assistant messages. A filename alone never guesses a path.
enum MeetingAssistantLinks {
    struct Reference {
        let range: NSRange
        let label: String
        let target: String
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

final class MeetingAssistantFileRow: NSStackView {
    let referenceURL: URL
    let openButton = NSButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    var onOpened: ((String?) -> Void)?
    init(label: String, url: URL) {
        referenceURL = url
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 4
        var directory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        openButton.title = label; openButton.isBordered = false; openButton.alignment = .left
        openButton.font = .systemFont(ofSize: 13, weight: .medium)
        openButton.contentTintColor = MeetingVisualStyle.ink
        openButton.image = NSImage(systemSymbolName: directory.boolValue ? "folder" : "doc.text", accessibilityDescription: nil)
        openButton.imagePosition = .imageLeading; openButton.lineBreakMode = .byTruncatingMiddle
        openButton.toolTip = url.path; openButton.setAccessibilityLabel("打开\(directory.boolValue ? "文件夹" : "文件")：\(label)")
        openButton.target = self; openButton.action = #selector(openReference)
        addArrangedSubview(openButton); openButton.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .secondaryLabelColor
        addArrangedSubview(errorLabel); errorLabel.isHidden = true
        errorLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
        let menu = NSMenu(); let reveal = NSMenuItem(title: "在访达中显示", action: #selector(revealReference), keyEquivalent: "")
        reveal.target = self; menu.addItem(reveal); openButton.menu = menu
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
