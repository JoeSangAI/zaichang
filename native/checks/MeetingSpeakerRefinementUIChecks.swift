import Foundation
import AppKit

/// Synthetic event and projection checks only. No user cache, capture, cloud,
/// model inference, or real audio is accessed here.
@MainActor
func meetingSpeakerRefinementUIChecks(directory:URL)throws->[String] {
    var checks:[String]=[]
    precondition(Delegate().friendly("capture_control_timeout_pause_drain").contains("尾部转写超时"))
    checks.append("tail_timeout_explains_saved_audio_and_recovery")
    var gate=MeetingSpeakerRefinementLifecycle();gate.begin(session:"session-a")

    precondition(!gate.pauseTailCompleted(session:"session-a",revision:7,states:["mic":"processing"],localOnly:false))
    precondition(!gate.pauseTailCompleted(session:"session-a",revision:7,states:["mic":"pending"],localOnly:false))
    precondition(gate.pauseTailCompleted(session:"session-a",revision:7,states:["mic":"complete","app":"complete"],localOnly:false))
    precondition(!gate.pauseTailCompleted(session:"session-a",revision:7,states:["mic":"complete","app":"complete"],localOnly:false))
    checks.append("pause_waits_for_all_complete_and_runs_once")

    precondition(!gate.pauseTailCompleted(session:"session-a",revision:8,states:["mic":"complete"],localOnly:true))
    precondition(!gate.shouldRefineStopped(session:"session-a",reason:"user_finish",transcriptionComplete:false,localOnly:false,recoverySucceeded:false))
    precondition(!gate.shouldRefineStopped(session:"session-a",reason:"user_finish",transcriptionComplete:true,localOnly:true,recoverySucceeded:false))
    precondition(gate.shouldRefineStopped(session:"session-a",reason:"user_finish",transcriptionComplete:true,localOnly:false,recoverySucceeded:false))
    precondition(gate.shouldRefineStopped(session:"session-a",reason:"recovery_complete",transcriptionComplete:true,localOnly:false,recoverySucceeded:true))
    precondition(!gate.shouldRefineStopped(session:"session-a",reason:"network_disconnected",transcriptionComplete:true,localOnly:false,recoverySucceeded:false))
    precondition(gate.shouldRefineStopped(session:"session-a",reason:"input_device_changed",transcriptionComplete:true,localOnly:false,recoverySucceeded:false))
    precondition(!gate.shouldRefineStopped(session:"session-a",reason:"input_device_changed",transcriptionComplete:false,localOnly:false,recoverySucceeded:false))
    precondition(gate.shouldRefineStopped(session:"session-a",reason:"user_finish",transcriptionComplete:true,localOnly:false,recoverySucceeded:false))
    checks.append("stop_requires_complete_and_recovery_success_is_supported")
    checks.append("completed_audio_after_input_device_change_still_refines_but_incomplete_audio_does_not")

    precondition(gate.resumed(session:"session-a"))
    precondition(gate.pauseTailCompleted(session:"session-a",revision:8,states:["mic":"complete"],localOnly:false))
    precondition(!gate.pauseTailCompleted(session:"session-a",revision:8,states:["mic":"complete"],localOnly:false))
    precondition(!gate.acceptsResult(session:"session-a",cacheID:"cache-a",expectedSession:"session-a",expectedCacheID:"cache-a",phase:.recording,currentRevision:0,expectedRevision:0))
    precondition(!gate.acceptsResult(session:"session-a",cacheID:"cache-a",expectedSession:"session-b",expectedCacheID:"cache-a",phase:.stopped,currentRevision:0,expectedRevision:0))
    precondition(!gate.acceptsResult(session:"session-a",cacheID:"cache-a",expectedSession:"session-a",expectedCacheID:"cache-a",phase:.stopped,currentRevision:1,expectedRevision:0))
    precondition(!gate.resumed(session:"session-b"))
    gate.begin(session:"session-b")
    precondition(!gate.shouldRefineStopped(session:"session-a",reason:"user_stop",transcriptionComplete:true,localOnly:false,recoverySucceeded:false))
    checks.append("resume_cancels_late_result_revision_and_session_changes_are_isolated")

    var names=SessionNames()
    let original:[String:Any]=["type":"segment","session":"session-a","source_id":"mic","epoch":"epoch-1","segment_id":"word-1","revision":1,"final":true,"speaker":["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":"epoch-1"]]
    names.register(segment:"word-1",item:original)
    names.set(segment:"word-1",name:"人工确认的张三")
    var refined=original;refined["speaker"]=["basis":"anonymous_cluster","cluster_id":1,"source_id":"mic","epoch":"epoch-1"]
    names.register(segment:"word-1",item:refined)
    precondition(names.name(segment:"word-1")=="人工确认的张三")
    precondition(names.displayName(segment:"word-1")?.origin == .manual)
    checks.append("human_name_survives_automatic_speaker_projection")

    // Exercise Delegate persistence, artifact validation, cancellation, and
    // live projection against a disposable synthetic cache.
    let root=directory.appendingPathComponent("speaker-refinement-ui-"+UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:root)}
    let recoveryFolder=root.appendingPathComponent(UUID().uuidString,isDirectory:true)
    let saved=try RecordingJournal(directory:recoveryFolder,track:"mic",freeSpace:{1_000_000_000})
    try saved.enqueue(Data(repeating:0,count:3200),at:10);saved.finish();saved.wait()
    let manifest=recoveryFolder.appendingPathComponent("mic-manifest.json")
    var interrupted=try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as! [String:Any]
    interrupted["ended"]=false
    try JSONSerialization.data(withJSONObject:interrupted).write(to:manifest,options:.atomic)
    let recovered=try RecordingJournal(directory:recoveryFolder,track:"mic")
    precondition(recovered.fault()=="cache_unclean_shutdown" && !recovered.transcriptionIsComplete())
    recovered.commitAfterTranscript(3200);recovered.wait()
    let listed=try cachedMeetings(in:root).first{$0.id==recoveryFolder.lastPathComponent}!
    precondition(recovered.transcriptionIsComplete() && listed.transcriptionComplete && listed.warning)
    precondition(!recovered.eligibleForCleanup())
    checks.append("recovered_saved_audio_completes_without_erasing_capture_warning_or_allowing_cleanup")
    let corruptManifest=recoveryFolder.appendingPathComponent("remote-manifest.json")
    try Data("broken".utf8).write(to:corruptManifest)
    let damaged=try cachedMeetings(in:root).first{$0.id==recoveryFolder.lastPathComponent}!
    precondition(damaged.warning && !damaged.transcriptionComplete)
    try FileManager.default.removeItem(at:corruptManifest)
    checks.append("unreadable_track_manifest_cannot_be_omitted_from_completion")
    recovered.setError("cache_transcript_write_failed")
    precondition(recovered.fault()=="cache_transcript_write_failed" && !recovered.transcriptionIsComplete())
    checks.append("new_transcript_failure_overrides_historical_interruption_warning")
    try Data(repeating:0,count:2).write(to:recoveryFolder.appendingPathComponent("mic-000001.pcm"))
    try JSONSerialization.data(withJSONObject:interrupted).write(to:manifest,options:.atomic)
    let unindexed=try RecordingJournal(directory:recoveryFolder,track:"mic")
    precondition(unindexed.fault()=="cache_unindexed_audio_retained" && !unindexed.transcriptionIsComplete())
    precondition(!RecordingJournal.transcriptionIsComplete(ended:false,written:3200,committed:3200,error:nil))
    precondition(!RecordingJournal.transcriptionIsComplete(ended:true,written:3200,committed:3200,error:"cache_checkpoint_write_failed"))
    checks.append("unsealed_or_damaged_recordings_never_report_transcription_complete")
    let cacheID=UUID().uuidString,session=UUID().uuidString
    let folder=root.appendingPathComponent(cacheID,isDirectory:true)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    func writeJSON(_ value:Any,to url:URL)throws {
        try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:url,options:.atomic)
    }
    try writeJSON(["schema":1,"session":session,"capture_origin_uptime":10.0],to:folder.appendingPathComponent("meeting.json"))
    try writeJSON(["schema":1,"track":"mic","written_bytes":0,"asr_committed_bytes":0,"ended":true,"audio_cleaned":false,"chunks":[]],to:folder.appendingPathComponent("mic-manifest.json"))
    let known:[String:Any]=["type":"segment","session":session,"source_id":"mic","track":"mic","epoch":"epoch-a","segment_id":"known","revision":1,"final":true,"end_time_known":true,"start":0.1,"end":0.8,"text":"已知发言","speaker":["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":"epoch-a"],"quality_flags":[]]
    let target:[String:Any]=["type":"segment","session":session,"source_id":"mic","track":"mic","epoch":"epoch-a","segment_id":"target","revision":1,"final":true,"end_time_known":true,"start":1.0,"end":1.6,"text":"待确认发言","speaker":["basis":"unknown","reason":"no_speaker_evidence"],"quality_flags":[]]
    let transcript=folder.appendingPathComponent("mic-transcript.jsonl")
    var transcriptData=Data()
    for event in [known,target] {transcriptData.append(try JSONSerialization.data(withJSONObject:event,options:[.sortedKeys]));transcriptData.append(10)}
    try transcriptData.write(to:transcript)
    let meeting=CachedMeeting(id:cacheID,directory:folder,date:Date(),writtenBytes:0,pendingBytes:0,occupiedBytes:0,tracks:["mic"],audioCleaned:false,warning:false,retiredBytes:0)
    let events=try meeting.events(includeAutomaticRefinement:false),hashes=try meeting.transcriptHashes()
    let projectedSpeaker:[String:Any]=["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":"epoch-a"]
    let record:[String:Any]=["segment_id":"target","original_sha256":try SpeakerRefinementArtifact.originalEventSHA256(target),"speaker":projectedSpeaker,"speaker_runs":[]]
    let artifact:[String:Any]=["schema":1,"method":SpeakerRefinementArtifact.method,"model":SpeakerRefinementArtifact.model,"cache_id":cacheID,"session":session,"source_sha256":hashes,"snapshot_sha256":try SpeakerRefinementArtifact.snapshotSHA256(directory:folder,cacheID:cacheID,sourceHashes:hashes),"records":[record]]
    let candidate=try JSONSerialization.data(withJSONObject:artifact,options:[.sortedKeys])

    let view=Delegate();view.speakerRefinementCheckMode=true;view.previewRenderOnly=true;view.deferPresentation=true
    view.recoveryRootOverride=root;view.currentCacheID=cacheID;view.activeSession=session;view.phase.phase = .paused
    view.speakerRefinementLifecycle.begin(session:session)
    view.segments=Dictionary(uniqueKeysWithValues:events.compactMap{event in (event["segment_id"] as? String).map{($0,event)}})
    view.sequence=events.compactMap{$0["segment_id"] as? String}
    for event in events {view.naming.register(segment:event["segment_id"] as! String,item:event)}
    view.naming.setSpeaker(segment:"known",name:"人工确认的张三")
    view.pausedTailRevision=9;view.pausedTailStates=["mic":"processing","remote-g1":"processing","remote-g2":"processing","remote-g3":"processing","remote-g4":"processing"]
    let lock=NSLock();var pending:(UUID,(UUID,Result<Data,Error>)->Void)?
    view.speakerRefinementExecutorOverride={_,_,_,token,done in lock.lock();pending=(token,done);lock.unlock()}
    func takePending(until deadline:Date)->(UUID,(UUID,Result<Data,Error>)->Void)? {
        while Date()<deadline {
            lock.lock();let value=pending;pending=nil;lock.unlock()
            if let value=value{return value}
            RunLoop.main.run(until:Date().addingTimeInterval(0.01))
        }
        return nil
    }
    for track in ["remote-g1","remote-g2","remote-g3","remote-g4"] {
        view.receive(["type":"recording_pause_tail","session":session,"pause_revision":9,"track":track,"state":"complete"])
        precondition(view.speakerRefinementToken==nil)
    }
    view.receive(["type":"recording_pause_tail","session":session,"pause_revision":9,"track":"mic","state":"complete"])
    checks.append("four_retired_sources_settle_before_mic_tail_starts_refinement")
    guard let first=takePending(until:Date().addingTimeInterval(5)) else{throw Failure(code:"speaker_refinement_ui_executor_not_started")}
    first.1(first.0,.success(candidate))
    let committed=folder.appendingPathComponent(SpeakerRefinementArtifact.filename)
    let commitDeadline=Date().addingTimeInterval(5)
    while Date()<commitDeadline && !FileManager.default.fileExists(atPath:committed.path) {RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
    while Date()<commitDeadline && view.speakerRefinementToken != nil {RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
    precondition(FileManager.default.fileExists(atPath:committed.path))
    precondition((view.segments["target"]?["speaker"] as? [String:Any])?["cluster_id"] as? Int==0)
    precondition(view.naming.name(segment:"target")=="人工确认的张三")
    checks.append("delegate_commits_and_projects_result_without_losing_manual_speaker_name")

    try FileManager.default.removeItem(at:committed)
    lock.lock();pending=nil;lock.unlock()
    view.scheduleSpeakerRefinement(trigger:"pause",allowUnsealed:true)
    guard let late=takePending(until:Date().addingTimeInterval(5)) else{throw Failure(code:"speaker_refinement_ui_late_executor_not_started")}
    view.cancelSpeakerRefinementForResume();view.phase.phase = .recording
    late.1(late.0,.success(candidate))
    RunLoop.main.run(until:Date().addingTimeInterval(0.15))
    precondition(!FileManager.default.fileExists(atPath:committed.path))
    precondition(view.speakerRefinementToken==nil)
    checks.append("resume_cancels_late_result_before_sidecar_commit")

    view.phase.phase = .paused
    view.scheduleSpeakerRefinement(trigger:"manual_retry",allowUnsealed:true)
    guard let failed=takePending(until:Date().addingTimeInterval(5)) else{throw Failure(code:"speaker_refinement_ui_failure_executor_not_started")}
    failed.1(failed.0,.failure(SpeakerRefinementJobError.helperFailed(1)))
    let failureDeadline=Date().addingTimeInterval(5)
    while Date()<failureDeadline && view.speakerRefinementToken != nil {RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
    precondition(view.speakerRefinementToken==nil)
    lock.lock();pending=nil;lock.unlock()
    view.scheduleSpeakerRefinement(trigger:"manual_retry",allowUnsealed:true)
    guard takePending(until:Date().addingTimeInterval(5)) != nil else{throw Failure(code:"speaker_refinement_ui_failure_not_retryable")}
    view.cancelSpeakerRefinement()
    checks.append("failed_refinement_can_be_retried")

    view.sessionLocalOnly=true;view.phase.phase = .stopped
    view.scheduleSpeakerRefinement(trigger:"stopped")
    precondition(view.speakerRefinementToken==nil)
    view.scheduleSpeakerRefinement(trigger:"manual_recovery")
    guard takePending(until:Date().addingTimeInterval(5)) != nil else{throw Failure(code:"speaker_refinement_ui_local_only_recovery_not_started")}
    view.cancelSpeakerRefinement()
    checks.append("successful_manual_recovery_can_refine_local_only_session")
    view.sessionLocalOnly=false;view.resumeBusy=true
    view.receive(["type":"stopped","session":session,"reason":"user_stop","transcription_complete":listed.transcriptionComplete])
    guard takePending(until:Date().addingTimeInterval(5)) != nil else{throw Failure(code:"recovered_saved_audio_did_not_start_refinement")}
    precondition(view.cachedTranscriptionComplete && view.phase.phase == .stopped)
    view.cancelSpeakerRefinement()
    checks.append("recovery_completion_event_automatically_starts_refinement_despite_retained_warning")
    precondition(view.canRetrySpeakerRefinement)
    view.retrySpeakerRefinement()
    guard takePending(until:Date().addingTimeInterval(5)) != nil else{throw Failure(code:"manual_refinement_retry_did_not_start")}
    precondition(!view.canRetrySpeakerRefinement)
    view.cancelSpeakerRefinement();view.cachedTranscriptionComplete=false
    // Available text can be refined independently of the unfinished ASR tail.
    precondition(view.canRetrySpeakerRefinement)
    view.phase.phase = .paused;view.pausedTailStates=["mic":"pending"]
    precondition(view.canRetrySpeakerRefinement)
    let savedSegments=view.segments;view.segments=[:]
    precondition(!view.canRetrySpeakerRefinement);view.segments=savedSegments
    view.pausedTailStates=["mic":"complete"]
    precondition(view.canRetrySpeakerRefinement)
    view.sessionLocalOnly=true
    precondition(!view.canRetrySpeakerRefinement)
    checks.append("manual_refinement_retry_uses_available_text_and_excludes_empty_duplicate_or_local_only_work")
    let visual=Delegate();visual.mock=true;visual.previewRenderOnly=true
    visual.buildWorkspace();visual.phase.phase = .paused;visual.phase.elapsed=60
    visual.meetingTitle="测试会议｜暂停后的发言人校正"
    visual.speakerRefinementToken=UUID();visual.diagnostic.stringValue="正在校正发言人…"
    visual.updateUI();visual.window.contentView?.layoutSubtreeIfNeeded()
    precondition(!visual.diagnostic.isHidden && visual.diagnostic.stringValue=="正在校正发言人…")
    precondition(visual.recordingModeHint?.superview?.subviews.compactMap{$0 as? CoarseProcessingStatusView}.first?.isHidden==false)
    visual.showTransientFeedback("姓名已保存")
    visual.updateUI()
    precondition(visual.recordingModeHint?.superview?.subviews.compactMap{$0 as? CoarseProcessingStatusView}.first?.isHidden==false)
    let drawing=visual.window.contentView!.superview!
    guard let bitmap=drawing.bitmapImageRepForCachingDisplay(in:drawing.bounds) else{throw Failure(code:"refinement_bitmap")}
    drawing.cacheDisplay(in:drawing.bounds,to:bitmap)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("paused-refinement.png"))
    visual.speakerRefinementToken=nil;visual.speakerRefinementMessage="发言人已校正";visual.showTransientFeedback("发言人已校正")
    visual.updateUI();precondition(visual.heading.stringValue.contains("发言人已校正"))
    visual.cancelSpeakerRefinementForResume();visual.phase.phase = .recording;visual.updateUI()
    precondition(visual.speakerRefinementMessage==nil && !visual.heading.stringValue.contains("校正"))
    precondition(!visual.diagnostic.isHidden)
    visual.window.orderOut(nil)
    checks.append("background_progress_and_completion_are_visible_in_real_appkit_workspace")
    return checks
}
