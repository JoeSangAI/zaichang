import AppKit

/// Read-only fallback: reuse the actual cache/reading-turn/bridge projection rules.
/// Deliberately never calls applicationDidFinishLaunching, recovery, persist, or bind.
@main struct ReplayMeetingProjection {
    static func read(directory: URL) throws -> [String: Any] {
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("meeting.json"))) as! [String: Any]
        let tracks = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix("-transcript.jsonl") }.map { String($0.dropLast("-transcript.jsonl".count)) }
        let date = Date(timeIntervalSince1970: metadata["created_at"] as? Double ?? 0)
        var item = CachedMeeting(id: directory.lastPathComponent, directory: directory, date: date, writtenBytes: 0, pendingBytes: 0,
            occupiedBytes: 0, tracks: tracks, audioCleaned: false, warning: false, retiredBytes: 0)
        item.customTitle = try MeetingLibraryInfo.loadTitle(in: directory)
        let events = try item.events()
        let owner = Delegate(); owner.previewRenderOnly = true; owner.recoveryRootOverride = directory.deletingLastPathComponent()
        owner.activeSession = metadata["session"] as? String
        owner.segments = Dictionary(uniqueKeysWithValues: events.compactMap { event in (event["segment_id"] as? String).map { ($0, event) } })
        owner.sequence = events.compactMap { $0["segment_id"] as? String }
        for event in events {
            guard let parent = event["segment_id"] as? String else { continue }
            owner.naming.register(segment: parent, item: event)
            for run in TranscriptTimeline.speakerRuns(event) { owner.naming.register(segment: TranscriptTimeline.runID(parent: parent, run: run), item: run) }
        }
        let names = directory.appendingPathComponent("session-names.json")
        if FileManager.default.fileExists(atPath: names.path), let session = owner.activeSession {
            try owner.naming.restore(Data(contentsOf: names), session: session, events: events, directory: directory)
        }
        let turns = owner.readingTurns(owner.sequence).filter { $0.item["final"] as? Bool == true }
        let rows = zip(meetingAssistantSegments(owner: owner, turns: turns), turns).map { row, turn -> [String: Any] in
            var result = row; result["start"] = turn.item["start"] ?? 0; result["end"] = turn.item["end"] ?? turn.item["start"] ?? 0
            return result
        }
        let result: [String: Any] = ["title": item.customTitle ?? metadata["title"] as? String ?? item.displayTitle, "cache_id": item.id,
            "session_id": owner.activeSession ?? item.id, "segments": rows, "source": "SessionCache/native-reading-projection"]
        return result
    }
    static func main() throws {
        let result = try read(directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
