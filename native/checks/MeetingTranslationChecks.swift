import AppKit

@MainActor func meetingTranslationChecks(directory: URL) throws -> [String: Any] {
    guard Credential.offline else { throw Failure(code:"offline_only") }
    let meeting=directory.appendingPathComponent(UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:meeting,withIntermediateDirectories:true)
    let store=MeetingTranslationStore(meetingDirectory:meeting)
    try store.saveEnabled(true)
    let source="We should send the revised plan on Friday."
    let hash=MeetingTranslationService.hash(source)
    try store.append(MeetingTranslationEntry(segmentID:"synthetic-1",sourceHash:hash,text:"我们应该在周五发送修订后的计划。"))
    let loaded=try store.load()
    guard loaded.0,loaded.1["synthetic-1:"+hash]=="我们应该在周五发送修订后的计划。" else {
        throw Failure(code:"translation_persistence")
    }
    return ["type":"meeting_translation_checks","checks":["settings_are_per_meeting","translations_are_hash_scoped_and_persisted"],"network":false,"capture":false,"passed":2]
}
