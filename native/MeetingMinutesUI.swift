import AppKit
import PDFKit
import UniformTypeIdentifiers

extension Delegate {
    @objc func showMeetingExportMenu() {
        let menu = NSMenu()
        let document = displayedDocument
        let transcript = menu.addItem(withTitle: "导出原文…", action: #selector(exportVisibleDocument), keyEquivalent: "")
        transcript.target = self
        if RuntimeConfiguration.standalone {
            menu.addItem(.separator())
            let minutes = menu.addItem(withTitle: "生成会议纪要…", action: #selector(beginMeetingMinutes), keyEquivalent: "")
            minutes.target = document
            minutes.isEnabled = !document.readingTurns().isEmpty && !Credential.offline && !document.meetingMinutesBusy
        }
        if let button = exportButton { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button) }
        else { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
    }

    @objc func beginMeetingMinutes() {
        guard !Credential.offline, currentCacheID != nil, !meetingMinutesBusy, !(workspaceOwner ?? self).meetingDeletionBusy else { return }
        let choice = NSAlert(); choice.messageText = "生成会议纪要"; choice.informativeText = "可选取本地文件或文件夹作为背景资料。会议事实与原话仍只依据本场最终转写。"
        choice.addButton(withTitle: "选择参考资料…"); choice.addButton(withTitle: "不添加，继续")
        choice.addButton(withTitle: "取消")
        switch choice.runModal() {
        case .alertFirstButtonReturn: chooseMeetingReferencesAndGenerate()
        case .alertSecondButtonReturn: generateMeetingMinutes(references: [])
        default: return
        }
    }

    private func chooseMeetingReferencesAndGenerate() {
        let panel = NSOpenPanel(); panel.title = "选择会议背景资料"; panel.message = "可选择文件或文件夹；支持 PDF、TXT、Markdown。仅所选内容会作为背景资料发送处理。"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true; panel.resolvesAliases = false
        guard panel.runModal() == .OK else { return }
        guard let id = currentCacheID, !meetingMinutesBusy else { return }
        let generation = meetingDocumentGeneration
        meetingMinutesBusy = true; diagnostic.stringValue = "正在读取参考资料"
        meetingMinutesReferenceJob.run(timeout: 120, work: { try Self.readMinuteReferences(panel.urls) }) { [weak self] result in
            guard let self, self.currentCacheID == id, self.meetingDocumentGeneration == generation else { return }
            self.meetingMinutesBusy = false
            switch result {
            case .success(let references): self.generateMeetingMinutes(references: references)
            case .failure(let error): self.showMinuteError(error.localizedDescription)
            }
        }
    }

    private func generateMeetingMinutes(references: [String]) {
        guard let id = currentCacheID, !meetingMinutesBusy else { return }
        if notesController?.flushPendingChanges() == false { showMinuteError("会中笔记尚未保存，请稍后重试"); return }
        let notes: String
        do {
            let saved = try notesController?.store?.snapshot().visible.map(\.text).joined(separator: "\n") ?? ""
            let draft = try notesController?.store?.draft() ?? ""
            notes = [saved, draft].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
        } catch { showMinuteError("读取会中笔记失败：\(error.localizedDescription)"); return }

        let turns = readingTurns()
        let evidence = turns.flatMap { turn in turn.parts.compactMap { _, part -> String? in
            guard part["final"] as? Bool == true else { return nil }
            let text = (part["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "[\(TranscriptTimeline.timestamp(part["start"]))] \(readingTurnLabel(turn)): \(text)"
        }}.joined(separator: "\n")
        let request: MeetingMinutesRequest
        do { request = try MeetingMinutes.request(title: meetingTitle, finalTranscript: evidence, notes: notes, references: references) }
        catch { showMinuteError(error.localizedDescription); return }
        meetingMinutesBusy = true
        let generation = meetingDocumentGeneration, title = meetingTitle
        diagnostic.stringValue = "正在生成会议纪要"
        meetingMinutesCredentialJob.run(timeout: 15, work: { try Credential.load() }) { [weak self] result in
            guard let self, self.currentCacheID == id, self.meetingDocumentGeneration == generation else { return }
            guard case .success(let key?) = result, !key.isEmpty else {
                self.meetingMinutesBusy = false
                self.showMinuteError("读取服务凭据失败；请在设置中完成配置")
                return
            }
            self.meetingMinutesTask = Task { [weak self] in
                do {
                    let json = try await DashScopeMeetingMinutesClient(apiKey: key).complete(request)
                    let markdown = try MeetingMinutes.validateAndRender(json, title: title, finalTranscript: evidence)
                    guard let self, !Task.isCancelled, self.currentCacheID == id, self.meetingDocumentGeneration == generation else { return }
                    self.meetingMinutesTask = nil
                    self.saveMeetingMinutes(markdown)
                } catch {
                    guard let self, self.currentCacheID == id, self.meetingDocumentGeneration == generation else { return }
                    self.meetingMinutesTask = nil; self.meetingMinutesBusy = false
                    self.showMinuteError("纪要生成失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func saveMeetingMinutes(_ markdown: String) {
        let panel = NSSavePanel(); panel.title = "保存会议纪要"; panel.nameFieldStringValue = transcriptSuggestedFilename.replacingOccurrences(of: "－转写原文.txt", with: "－会议纪要.md")
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]; panel.canCreateDirectories = true
        panel.message = "会中笔记和参考资料只用于整理，不会附加到导出文件。"
        guard panel.runModal() == .OK, let url = panel.url else { meetingMinutesBusy = false; diagnostic.stringValue = "纪要已生成，未保存"; return }
        do { try markdown.write(to: url, atomically: true, encoding: .utf8); meetingMinutesBusy = false; diagnostic.stringValue = "会议纪要已保存" }
        catch { meetingMinutesBusy = false; showMinuteError("保存纪要失败：\(error.localizedDescription)") }
    }

    private func showMinuteError(_ text: String) {
        diagnostic.stringValue = text
        let alert = NSAlert(); alert.messageText = "无法生成会议纪要"; alert.informativeText = text; alert.addButton(withTitle: "好"); alert.runModal()
    }

    private static func readMinuteReferences(_ selections: [URL]) throws -> [String] {
        let fm = FileManager.default
        var files: [URL] = [], seen = Set<String>()
        for selection in selections {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: selection.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard let enumerator = fm.enumerator(at: selection, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                while let url = enumerator.nextObject() as? URL {
                    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true,
                          supportedReference(url), seen.insert(url.standardizedFileURL.path).inserted else { continue }
                    guard files.count < 64 else { throw Failure(code: "minutes_reference_count_limit") }
                    files.append(url)
                }
            } else if supportedReference(selection),
                      let values = try? selection.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true,
                      seen.insert(selection.standardizedFileURL.path).inserted {
                guard files.count < 64 else { throw Failure(code: "minutes_reference_count_limit") }
                files.append(selection)
            }
        }
        guard !files.isEmpty else { throw Failure(code: "minutes_no_supported_references") }
        var result: [String] = [], total = 0
        for url in files {
            guard let text = try referenceText(url) else { continue }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let entry = "【\(url.lastPathComponent)】\n\(cleaned)"
            let bytes = entry.utf8.count
            guard bytes <= 128 * 1024, total + bytes <= 128 * 1024 else { throw Failure(code: "minutes_reference_size_limit") }
            result.append(entry); total += bytes
        }
        guard !result.isEmpty else { throw Failure(code: "minutes_references_unreadable") }
        return result
    }

    private static func referenceText(_ url: URL) throws -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 32 * 1024 * 1024 else { return nil }
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url) else { return nil }
            return pdf.string ?? ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func supportedReference(_ url: URL) -> Bool { ["pdf", "txt", "md", "markdown"].contains(url.pathExtension.lowercased()) }
}

private struct DashScopeMeetingMinutesClient {
    let apiKey: String
    func complete(_ input: MeetingMinutesRequest) async throws -> String {
        guard !Credential.offline, !apiKey.isEmpty else { throw Failure(code: "minutes_offline") }
        let body: [String: Any] = ["model": "qwen-flash", "temperature": 0.1, "stream": false, "enable_thinking": false,
            "response_format": ["type": "json_object"], "max_tokens": 6000,
            "messages": [["role": "system", "content": input.system], ["role": "user", "content": input.input + "\n\n严格遵守 JSON Schema：\n" + (String(data: try JSONSerialization.data(withJSONObject: input.responseSchema, options: [.sortedKeys]), encoding: .utf8) ?? "{}")]]]
        var request = URLRequest(url: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 90; config.timeoutIntervalForResource = 120
        let (data, response) = try await URLSession(configuration: config).data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 768 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (root["choices"] as? [[String: Any]])?.first,
              choice["finish_reason"] as? String != "length",
              let message = choice["message"] as? [String: Any], let content = message["content"] as? String else { throw Failure(code: "minutes_response_invalid") }
        return content
    }
}
