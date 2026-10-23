import AppKit

/// Replays the sidebar's Markdown and workspace transitions without recording
/// or starting an assistant/model process. Also used by the official UI check.
@MainActor func meetingMarkdownChecks() throws -> [String] {
    var checks: [String] = []
    func check(_ ok: Bool, _ name: String) throws {
        guard ok else { throw Failure(code: name) }; checks.append(name)
    }
    let source = """
    # 在场侧栏检查

    **助理、概览和笔记**，保留 `Markdown` 格式。

    | 功能 | 验收路径 |
    | --- | --- |
    | 助理 | 发送、取消、切换会议与恢复草稿 |
    | 笔记 | 保存最后一次输入后导出 |

    1. 检查标题和表格
    2. 检查窄栏换行

    > 三个功能是否都能按照设计正常运行。

    ```swift
    let tabs = ["助理", "概览", "笔记"]
    // 保留原始换行
    ```
    """
    let rich = MeetingMarkdown.render(source)
    try check(!rich.string.contains("| ---") && !rich.string.contains("# 在场"), "markdown_removes_block_markers")
    try check(rich.string.contains("助理、概览和笔记") && !rich.string.contains("**"), "markdown_inline_emphasis")
    for (source, expected, emphasized) in [
        ("**中文句号。**后续文字", "中文句号。后续文字", "中文句号。"),
        ("前文**“中文”**后文", "前文“中文”后文", "“中文”"),
        ("**中文。**后文，**第二项！**接着", "中文。后文，第二项！接着", "第二项！"),
        ("ZCStrongBoundary **中文。**后文", "ZCStrongBoundary 中文。后文", "中文。")
    ] {
        let value = MeetingMarkdown.inline(source), range = (value.string as NSString).range(of: emphasized)
        let bold = range.location != NSNotFound && (value.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true
        try check(value.string == expected && bold, "markdown_cjk_strong_\(checks.count)")
    }
    let nested = MeetingMarkdown.inline("**含 `code` 与 [链接](https://example.com/a) 的中文。**后文")
    let linkRange = (nested.string as NSString).range(of: "链接"), codeRange = (nested.string as NSString).range(of: "code")
    try check(nested.string == "含 code 与 链接 的中文。后文" && nested.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL == URL(string: "https://example.com/a") && nested.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) != nil, "markdown_cjk_strong_preserves_nested_code_and_links")
    for source in ["`**中文。**后文`", "``a ` **中文。**后文``", "\\*\\*中文。\\*\\*后文", "[查看](https://example.com/**中文。**后文)", "**尚未完成", "** 空白。**后文", "**English.**next"] {
        try check(MeetingMarkdown.cjkStrongBoundaries(source).text == source, "markdown_cjk_preserves_literals_\(checks.count)")
    }
    for source in ["ZCStrongBound&#97;ry", "[ZCStrongBound&#97;ry](https://example.com)", "ZCStrongBound&#97;ry **中文。**后文", "[ZCStrongBound&#97;ry](https://example.com) **中文。**后文"] {
        let value = MeetingMarkdown.inline(source)
        try check(value.string == "ZCStrongBoundary" + (source.contains("**") ? " 中文。后文" : ""), "markdown_cjk_preserves_decoded_marker_text_\(checks.count)")
        if source.hasPrefix("[") { try check(value.attribute(.link, at: 0, effectiveRange: nil) as? URL == URL(string: "https://example.com"), "markdown_cjk_preserves_decoded_link_\(checks.count)") }
    }
    let headerRange = (rich.string as NSString).range(of: "在场侧栏检查")
    try check((rich.attribute(.font, at: headerRange.location, effectiveRange: nil) as? NSFont)?.pointSize == 21, "markdown_heading_hierarchy")
    var tableCells = 0, codeBlocks = 0
    rich.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
        let blocks = (value as? NSParagraphStyle)?.textBlocks ?? []
        if blocks.contains(where: { ($0 as? NSTextTableBlock)?.table.numberOfColumns == 2 }) { tableCells += 1 }
        else if !blocks.isEmpty { codeBlocks += 1 }
    }
    try check(tableCells == 6, "markdown_table_has_six_native_cells")
    try check(codeBlocks >= 2 && rich.string.contains("\n// 保留原始换行"), "markdown_quote_and_code_blocks")
    let pipes = MeetingMarkdown.cells("| `a|b` | c\\|d |")
    try check(pipes == ["`a|b`", "c\\|d"], "markdown_code_and_escaped_pipes_keep_columns")
    let safe = MeetingMarkdown.render("[链接](https://example.com) [拒绝](javascript:alert(1))")
    var urls: [URL] = []
    safe.enumerateAttribute(.link, in: NSRange(location: 0, length: safe.length)) { value, _, _ in
        if let url = value as? URL { urls.append(url) }
    }
    try check(urls.count == 1 && urls[0].scheme == "https", "markdown_only_web_links_are_active")
    try check(MeetingMarkdown.render(source, plain: true).string == source, "markdown_user_input_stays_literal")
    let partial = MeetingMarkdown.render("```swift\nlet tabs = [\"助理\"]")
    try check(partial.string.contains("let tabs") && !partial.string.contains("```"), "markdown_unclosed_streaming_fence")
    let view = MeetingMarkdownTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 10))
    view.apply(rich); view.setFrameSize(NSSize(width: 500, height: 10))
    try check(view.textStorage?.string == rich.string && view.textLayoutManager == nil, "markdown_owns_textkit1_storage")
    let wide = view.intrinsicContentSize.height
    view.setFrameSize(NSSize(width: 240, height: 10))
    let narrow = view.intrinsicContentSize.height
    try check(wide > 100 && narrow >= wide && narrow.isFinite, "markdown_narrow_column_remeasures_height")
    for columns in [2, 4, 6] {
        let header = "|" + (0..<columns).map { "列\($0)" }.joined(separator: "|") + "|"
        let separator = "|" + Array(repeating: "---", count: columns).joined(separator: "|") + "|"
        let row = "|" + Array(repeating: "较长中文内容 `https://example.com/a-long-unbroken-path`", count: columns).joined(separator: "|") + "|"
        for width: CGFloat in [280, 360, 480] {
            let tableView = MeetingMarkdownTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
            tableView.apply(MeetingMarkdown.render([header, separator, row].joined(separator: "\n")))
            let height = tableView.intrinsicContentSize.height
            let used = tableView.layoutManager!.usedRect(for: tableView.textContainer!)
            try check(height.isFinite && height > 20 && used.maxX <= width + 1, "markdown_\(columns)_columns_at_\(Int(width))")
        }
    }

    let panel = MeetingAgentPanel()
    panel.activateWorkspace("first"); panel.restoreDraft("三个功能是否正常运行")
    panel.activateWorkspace("second"); panel.restoreDraft("检查 Markdown 格式")
    panel.restoreDraft("上一条发送失败", workspace: "first")
    try check(panel.draftText == "检查 Markdown 格式", "late_failure_does_not_replace_other_meeting_draft")
    panel.activateWorkspace("first")
    try check(panel.draftText == "上一条发送失败\n\n三个功能是否正常运行", "failed_send_preserves_newer_draft")
    panel.activateWorkspace("second")
    try check(panel.draftText == "检查 Markdown 格式", "draft_survives_workspace_roundtrip")
    panel.activateWorkspace("temporary"); panel.restoreDraft("连接中输入的内容")
    panel.resolveDraftWorkspace(from: "temporary", to: "canonical")
    panel.activateWorkspace("canonical")
    try check(panel.draftText == "连接中输入的内容", "canonical_bind_preserves_draft")
    panel.restoreDraft("迟到的失败发送", workspace: "temporary")
    try check(panel.draftText == "迟到的失败发送\n\n连接中输入的内容", "canonical_bind_routes_late_failure")
    func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    for warning in ["overview_evidence_filtered", "overview_source_needs_review"] {
        panel.apply(["meeting_overview": ["status": "ready", "stale": true, "error": warning]])
        let status = descendants(panel).compactMap { $0 as? NSTextField }.first { $0.toolTip?.contains(warning) == true }
        try check(status?.stringValue.hasPrefix("会议有新内容") == true, "overview_stale_visible_with_\(warning)")
    }
    return checks
}
