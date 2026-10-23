import AppKit

/// Local, inert Markdown presentation. No HTML execution, remote images or web view.
/// Foundation handles inline syntax; AppKit text blocks keep tables selectable and
/// responsive inside the same native transcript as paragraphs and code.
enum MeetingMarkdown {
    static func inline(_ source: String, font: NSFont = .systemFont(ofSize: 14)) -> NSAttributedString {
        let prepared = cjkStrongBoundaries(source)
        guard let parsed = try? AttributedString(markdown: prepared.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: source, attributes: [.font: font, .foregroundColor: MeetingVisualStyle.ink])
        }
        let result = NSMutableAttributedString(string: "")
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var chosen = font
            if intent.contains(.code) { chosen = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) }
            else {
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                chosen = NSFontManager.shared.convert(font, toHaveTrait: traits)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: chosen, .foregroundColor: MeetingVisualStyle.ink]
            if intent.contains(.code) { attributes[.backgroundColor] = MeetingVisualStyle.quietFill }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link, let safe = MeetingAssistantLinks.webURL(link.absoluteString) {
                attributes[.link] = safe; attributes[.foregroundColor] = NSColor.linkColor
            }
            let original = String(parsed[run.range].characters)
            let text = prepared.marker.map { original.replacingOccurrences(of: $0, with: "") } ?? original
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    // Foundation applies CommonMark's punctuation flanking rule even between
    // Chinese words: **说明。**后文 remains literal. Adapt only paired CJK strong
    // delimiters at those boundaries; preserve code, escapes and destinations.
    // The collision-free word marker exists only during parsing, never storage.
    static func cjkStrongBoundaries(_ source: String) -> (text: String, marker: String?) {
        let chars = Array(source)
        var insertions: Set<Int> = [], opener: Int?, i = 0
        func cjk(_ c: Character) -> Bool {
            c.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x323AF).contains($0.value) }
        }
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "`" {
                var end = i; while end < chars.count && chars[end] == "`" { end += 1 }
                let width = end - i; var scan = end, close: Int?
                while scan < chars.count {
                    if chars[scan] != "`" { scan += 1; continue }
                    let start = scan; while scan < chars.count && chars[scan] == "`" { scan += 1 }
                    if scan - start == width { close = scan; break }
                }
                i = close ?? end; continue
            }
            if chars[i] == "<", let end = chars[(i + 1)...].firstIndex(of: ">") { i = end + 1; continue }
            if chars[i] == "]", i + 1 < chars.count, chars[i + 1] == "(" {
                var depth = 1; i += 2
                while i < chars.count && depth > 0 {
                    if chars[i] == "\\" { i += 2; continue }
                    if chars[i] == "(" { depth += 1 }
                    if chars[i] == ")" { depth -= 1 }
                    i += 1
                }
                continue
            }
            guard chars[i] == "*" else { i += 1; continue }
            var end = i; while end < chars.count && chars[end] == "*" { end += 1 }
            guard end - i == 2 else { i = end; continue }
            if let start = opener, i > start + 2, !chars[i - 1].isWhitespace {
                let body = chars[(start + 2)..<i]
                if body.contains(where: cjk) {
                    if start > 0, (chars[start - 1].isLetter || chars[start - 1].isNumber), chars[start + 2].isPunctuation { insertions.insert(start + 2) }
                    if end < chars.count, (chars[end].isLetter || chars[end].isNumber), chars[i - 1].isPunctuation { insertions.insert(i) }
                }
                opener = nil
            } else if end < chars.count, !chars[end].isWhitespace {
                opener = i
            }
            i = end
        }
        guard !insertions.isEmpty,
              let original = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return (source, nil) }
        // Entities can spell the marker only after Markdown decoding. Avoid
        // collisions in both representations before removing inserted markers.
        let decoded = String(original.characters)
        var marker = "ZCStrongBoundary"
        while source.contains(marker) || decoded.contains(marker) { marker += "X" }
        var text = ""
        for (index, char) in chars.enumerated() {
            if insertions.contains(index) { text += marker }
            text.append(char)
        }
        return (text, marker)
    }

    static func render(_ source: String, plain: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        func append(_ content: NSAttributedString, style: NSMutableParagraphStyle) {
            let value = NSMutableAttributedString(attributedString: content)
            value.append(NSAttributedString(string: "\n"))
            value.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: value.length))
            result.append(value)
        }
        func style(spacing: CGFloat = 10) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle(); p.lineSpacing = 4; p.paragraphSpacing = spacing
            return p
        }
        func panelBlock() -> NSTextTableBlock {
            let table = NSTextTable(); table.numberOfColumns = 1
            table.layoutAlgorithm = .fixedLayoutAlgorithm
            table.setValue(100, type: .percentageValueType, for: .width)
            return NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        }
        if plain {
            return NSAttributedString(string: source, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: MeetingVisualStyle.ink, .paragraphStyle: style()])
        }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }
            if let fence = fenceStart(trimmed) {
                index += 1; var code: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.count >= fence.count && candidate.allSatisfy({ $0 == fence.first! }) { index += 1; break }
                    code.append(lines[index]); index += 1
                }
                let p = style(); p.headIndent = 12; p.firstLineHeadIndent = 12; p.tailIndent = -12
                let block = panelBlock(); block.backgroundColor = MeetingVisualStyle.quietFill
                block.setWidth(9, type: .absoluteValueType, for: .padding); p.textBlocks = [block]
                append(NSAttributedString(string: code.joined(separator: "\n"), attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: MeetingVisualStyle.ink]), style: p)
                continue
            }
            if index + 1 < lines.count, let header = cells(line), let alignment = separator(lines[index + 1]), header.count == alignment.count {
                var rows = [header]; index += 2
                while index < lines.count, let row = cells(lines[index]), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(Array((row + Array(repeating: "", count: header.count)).prefix(header.count))); index += 1
                }
                let table = NSTextTable(); table.numberOfColumns = header.count
                table.layoutAlgorithm = .fixedLayoutAlgorithm; table.collapsesBorders = true
                table.setValue(100, type: .percentageValueType, for: .width)
                for (r, row) in rows.enumerated() {
                    for (c, cell) in row.enumerated() {
                        let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                        let width: CGFloat = header.count == 2 ? (c == 0 ? 30 : 70) : 100 / CGFloat(header.count)
                        block.setValue(width, type: .percentageValueType, for: .width)
                        block.setWidth(8, type: .absoluteValueType, for: .padding)
                        block.setWidth(0.5, type: .absoluteValueType, for: .border)
                        block.setBorderColor(MeetingVisualStyle.border)
                        block.backgroundColor = r == 0 ? MeetingVisualStyle.quietFill : NSColor.textBackgroundColor
                        block.verticalAlignment = .topAlignment
                        let p = style(spacing: 0); p.textBlocks = [block]; p.alignment = alignment[c]
                        append(inline(cell, font: .systemFont(ofSize: 13, weight: r == 0 ? .semibold : .regular)), style: p)
                    }
                }
                // A normal paragraph ends the table, including while streaming.
                append(NSAttributedString(string: "", attributes: [.font: NSFont.systemFont(ofSize: 4)]), style: style(spacing: 6))
                continue
            }
            if let heading = match("^(#{1,6})[ \\t]+(.+?)(?:[ \\t]+#+)?$", trimmed) {
                let level = heading[0].count, p = style(spacing: 8); p.paragraphSpacingBefore = 8
                append(inline(heading[1], font: .systemFont(ofSize: level == 1 ? 21 : level == 2 ? 18 : 15, weight: .semibold)), style: p)
                index += 1; continue
            }
            if index + 1 < lines.count, match("^ *(=+|-+) *$", lines[index + 1]) != nil {
                let p = style(spacing: 8); p.paragraphSpacingBefore = 8
                append(inline(trimmed, font: .systemFont(ofSize: lines[index + 1].contains("=") ? 21 : 18, weight: .semibold)), style: p)
                index += 2; continue
            }
            if match("^(?:[-*_][ \\t]*){3,}$", trimmed) != nil {
                let p = style(); p.paragraphSpacingBefore = 4
                append(NSAttributedString(string: "────────────────", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: MeetingVisualStyle.border]), style: p)
                index += 1; continue
            }
            if let list = match("^([ \\t]*)([-+*]|[0-9]+[.)])[ \\t]+(.*)$", line) {
                let indent = CGFloat(list[0].replacingOccurrences(of: "\t", with: "    ").count / 2) * 14
                let p = style(spacing: 5); p.firstLineHeadIndent = indent; p.headIndent = indent + 22
                p.tabStops = [NSTextTab(textAlignment: .left, location: p.headIndent)]
                var content = list[2], marker = list[1].first?.isNumber == true ? list[1] : "•"
                if content.hasPrefix("[ ] ") { marker = "☐"; content = String(content.dropFirst(4)) }
                else if content.lowercased().hasPrefix("[x] ") { marker = "☑"; content = String(content.dropFirst(4)) }
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                      lines[index].prefix(while: { $0 == " " }).count > list[0].count,
                      match("^[ \\t]*([-+*]|[0-9]+[.)])[ \\t]+", lines[index]) == nil,
                      fenceStart(lines[index].trimmingCharacters(in: .whitespaces)) == nil {
                    content += "\n" + lines[index].trimmingCharacters(in: .whitespaces); index += 1
                }
                append(inline(marker + "\t" + content), style: p); continue
            }
            if trimmed.hasPrefix(">") {
                let p = style(); p.firstLineHeadIndent = 14; p.headIndent = 14
                let block = panelBlock(); block.setWidth(2, type: .absoluteValueType, for: .border, edge: .minX)
                block.setBorderColor(MeetingVisualStyle.border); block.setWidth(8, type: .absoluteValueType, for: .padding); p.textBlocks = [block]
                append(inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)), style: p)
                index += 1; continue
            }
            var paragraph = line; index += 1
            while index < lines.count, !startsBlock(lines, index) {
                paragraph += (paragraph.hasSuffix("  ") ? "\n" : " ") + lines[index]; index += 1
            }
            append(inline(paragraph), style: style())
        }
        return result
    }

    private static func startsBlock(_ lines: [String], _ index: Int) -> Bool {
        let text = lines[index].trimmingCharacters(in: .whitespaces)
        return text.isEmpty || text.hasPrefix(">") || fenceStart(text) != nil
            || match("^(#{1,6}[ \\t]|[ \\t]*([-+*]|[0-9]+[.)])[ \\t]|(?:[-*_][ \\t]*){3,}$)", lines[index]) != nil
            || (index + 1 < lines.count && (separator(lines[index + 1]) != nil || match("^ *(=+|-+) *$", lines[index + 1]) != nil))
    }

    private static func fenceStart(_ text: String) -> String? {
        guard let first = text.first, first == "`" || first == "~" else { return nil }
        let prefix = String(text.prefix(while: { $0 == first }))
        return prefix.count >= 3 ? prefix : nil
    }

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let ns = text as NSString
        return (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
    }

    /// Pipes inside code spans or escaped pipes do not split a cell.
    static func cells(_ line: String) -> [String]? {
        var text = line.trimmingCharacters(in: .whitespaces)
        guard text.contains("|") else { return nil }
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var result: [String] = [], cell = "", escaped = false, ticks = 0
        let chars = Array(text); var i = 0
        while i < chars.count {
            let c = chars[i]
            if escaped { cell.append(c); escaped = false; i += 1; continue }
            if c == "\\" { cell.append(c); escaped = true; i += 1; continue }
            if c == "`" {
                var end = i; while end < chars.count && chars[end] == "`" { end += 1 }
                let count = end - i; if ticks == 0 { ticks = count } else if ticks == count { ticks = 0 }
                cell += String(repeating: "`", count: count); i = end; continue
            }
            if c == "|" && ticks == 0 { result.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(c) }
            i += 1
        }
        result.append(cell.trimmingCharacters(in: .whitespaces))
        return result.count > 1 ? result : nil
    }

    private static func separator(_ line: String) -> [NSTextAlignment]? {
        guard let values = cells(line), values.allSatisfy({ match("^:?-{3,}:?$", $0) != nil }) else { return nil }
        return values.map { $0.hasSuffix(":") ? ($0.hasPrefix(":") ? .center : .right) : .left }
    }
}

final class MeetingMarkdownTextView: NSTextView {
    private let backingStorage: NSTextStorage?
    private var measuredWidth: CGFloat = 0
    override init(frame: NSRect, textContainer: NSTextContainer? = nil) {
        // A nil container on a custom NSTextView can leave it without storage;
        // NSTextTable also needs TextKit 1. Build that graph explicitly.
        let container: NSTextContainer
        if let textContainer { container = textContainer; backingStorage = textContainer.layoutManager?.textStorage }
        else {
            let storage = NSTextStorage()
            let manager = NSLayoutManager()
            container = NSTextContainer(containerSize: NSSize(width: max(1, frame.width), height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(manager); manager.addTextContainer(container)
            backingStorage = storage
        }
        super.init(frame: frame, textContainer: container)
        isEditable = false; isSelectable = true; drawsBackground = false
        isVerticallyResizable = false; isHorizontallyResizable = false
        textContainerInset = .zero; self.textContainer?.lineFragmentPadding = 0
        self.textContainer?.widthTracksTextView = true
        self.textContainer?.heightTracksTextView = false
        measuredWidth = frame.width
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        linkTextAttributes = [.foregroundColor: NSColor.linkColor]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func apply(_ text: NSAttributedString) { textStorage?.setAttributedString(text); invalidateIntrinsicContentSize() }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - measuredWidth) > 0.5 {
            measuredWidth = newSize.width
            textContainer?.containerSize = NSSize(width: max(1, newSize.width), height: CGFloat.greatestFiniteMagnitude)
            invalidateIntrinsicContentSize()
        }
    }
    override var intrinsicContentSize: NSSize {
        guard measuredWidth > 1 else { return NSSize(width: NSView.noIntrinsicMetric, height: 20) }
        guard let layoutManager, let textContainer else { return NSSize(width: NSView.noIntrinsicMetric, height: 20) }
        layoutManager.ensureLayout(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(20, ceil(layoutManager.usedRect(for: textContainer).height)))
    }
}
