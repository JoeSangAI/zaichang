import AppKit

@MainActor private func incrementalTranscriptRegressionChecks(directory:URL)throws->[String:Any] {
    func makeBlock(_ parent:String,_ id:String,_ start:Double,_ body:String)->TranscriptRenderedBlock {
        let item:[String:Any] = ["start":start,"end":start+1,"text":body,"final":true,"speaker":["basis":"unknown"]]
        let turn=ReadingTurn(id:id,parent:parent,item:item,parts:[(id,item)],uncertain:false)
        return TranscriptRenderedBlock(turn:turn,attributed:NSAttributedString(string:body+"\n"),partRanges:[id:NSRange(location:0,length:body.utf16.count)],identities:[])
    }
    let index=IncrementalTranscript(),storage=NSTextStorage(string:"")
    for count in [10_000,50_000] {
        index.reset(storage:storage);index.resetMetrics()
        for i in 0..<count {
            let id="turn-\(i)",parent="parent-\(i)",start=Double(i)
            let block=makeBlock(parent,id,start,"row-\(i)")
            index.replace(parent:parent,with:[block],storage:storage)
            _=index.replaceAtoms(parent:parent,rows:[TranscriptAtomicRow(id:id,parent:parent,item:block.turn.item)])
        }
        guard index.turnCount==count,index.orderedAtomCount==count,index.blockRemovals==0,index.blockInsertions==count,
              storage.string.hasPrefix("row-0\n"),storage.string.hasSuffix("row-\(count-1)\n"),
              (0..<min(count,2_000)).allSatisfy({index.range(forTurn:"turn-\($0)") != nil}) else {throw Failure(code:"incremental_append_\(count)")}
    }
    let appendCounters=["parents":index.parentReplacements,"insertions":index.blockInsertions,"removals":index.blockRemovals,"atom_shifts":index.atomShiftCount]
    guard index.parentReplacements==50_000,index.blockInsertions==50_000,index.blockRemovals==0,index.atomShiftCount==0 else{throw Failure(code:"incremental_append_counters")}

    index.reset(storage:storage)
    let p0=makeBlock("p","p0",0,"前句。"),p8=makeBlock("p","p8",2,"后句。"),q4=makeBlock("q","q4",1.5,"中间句。")
    index.replace(parent:"p",with:[p0,p8],storage:storage)
    _=index.replaceAtoms(parent:"p",rows:[p0,p8].map{TranscriptAtomicRow(id:$0.turn.id,parent:"p",item:$0.turn.item)})
    index.replace(parent:"q",with:[q4],storage:storage)
    let insertionAffected=index.replaceAtoms(parent:"q",rows:[TranscriptAtomicRow(id:"q4",parent:"q",item:q4.turn.item)])
    let identity:(String,[String:Any])->String? = {_,_ in "same-speaker"}
    guard insertionAffected.contains("p"),index.turns(forParent:"p",identity:identity).count==2 else{throw Failure(code:"interleaved_turn_barrier")}
    index.replace(parent:"q",with:[],storage:storage)
    let affected=index.replaceAtoms(parent:"q",rows:[])
    guard affected.contains("p"),index.turns(forParent:"p",identity:identity).count==1 else{throw Failure(code:"removed_barrier_rejoins_turn")}
    let revised=makeBlock("p","p8",2,"修订后的后句。")
    _=index.replaceAtoms(parent:"p",rows:[TranscriptAtomicRow(id:"p0",parent:"p",item:p0.turn.item),TranscriptAtomicRow(id:"p8",parent:"p",item:revised.turn.item)])
    let projected=index.turns(forParent:"p",identity:identity)
    let merged=projected.map { turn -> TranscriptRenderedBlock in
        let body=turn.parts.map{$0.1["text"] as? String ?? ""}.joined()
        return TranscriptRenderedBlock(turn:turn,attributed:NSAttributedString(string:body+"\n"),partRanges:Dictionary(uniqueKeysWithValues:turn.parts.map{($0.0,NSRange(location:0,length:($0.1["text"] as? String ?? "").utf16.count))}),identities:[])
    }
    index.replace(parent:"p",with:merged,storage:storage)
    guard index.range(forPart:"p8") != nil,index.turnCount==1,storage.string.contains("修订后的后句。") else{throw Failure(code:"local_revision_replaces_parent_block")}
    let exportTurns=index.allTurns()
    guard exportTurns.count==1,exportTurns[0].parts.map({$0.1["text"] as? String ?? ""}).joined()=="前句。修订后的后句。" else{throw Failure(code:"full_text_survives_local_revision")}

    let app=Delegate();app.previewRenderOnly=true;app.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));app.phase.phase = .recording;app.activeSession="projection-fixture";app.deferPresentation=true
    func segment(_ id:String,_ start:Double,_ text:String,_ revision:Int=1)->[String:Any] { ["type":"segment","session":"projection-fixture","segment_id":id,"source_id":"mic","track":"mic","epoch":"projection-fixture","start":start,"end":start+1,"text":text,"revision":revision,"final":true,"speaker":["basis":"unknown"]] }
    for i in 0..<10_000 {app.receive(segment("projection-\(i)",Double(i)*2,"长会话第\(i)段，用于检查真实界面的增量投影。"))}
    app.deferPresentation=false;try app.settleTranscriptForOfflineReview()
    guard app.incrementalTranscript.turnCount==10_000,app.output.string.contains("长会话第0段"),app.output.string.contains("长会话第9999段") else{throw Failure(code:"delegate_full_10k_transcript")}
    let initialExport=app.transcriptExport()
    guard initialExport.contains("长会话第0段") && initialExport.contains("长会话第9999段") else{throw Failure(code:"delegate_full_10k_export")}
    app.incrementalTranscript.resetMetrics();app.transcriptProjectionComputations=0
    app.receive(segment("projection-10000",20_000,"追加的一段内容。"))
    guard app.transcriptProjectionComputations==1,app.incrementalTranscript.parentReplacements==1,app.incrementalTranscript.blockInsertions==1,app.incrementalTranscript.blockRemovals==0,app.incrementalTranscript.charactersRemoved==0 else{throw Failure(code:"delegate_append_cost_is_local_\(app.transcriptProjectionComputations)_\(app.incrementalTranscript.parentReplacements)_\(app.incrementalTranscript.blockInsertions)_\(app.incrementalTranscript.blockRemovals)_\(app.incrementalTranscript.charactersRemoved)_\(app.fullTranscriptRefreshPending)_\(app.dirtyTranscriptParents.count)")}
    app.incrementalTranscript.resetMetrics();app.transcriptProjectionComputations=0
    app.receive(segment("projection-10000",20_000,"修订这一段，其他 10000 段不重算。",2))
    guard app.transcriptProjectionComputations==1,app.incrementalTranscript.parentReplacements==1,app.incrementalTranscript.blockInsertions==1,app.incrementalTranscript.blockRemovals==1,app.incrementalTranscript.charactersRemoved<100 else{throw Failure(code:"delegate_revision_cost_is_local")}
    app.incrementalTranscript.resetMetrics();app.transcriptProjectionComputations=0
    app.receive(["type":"meter","elapsed_seconds":12.0,"estimated_yuan":"0.02"])
    guard app.transcriptProjectionComputations==0,app.incrementalTranscript.parentReplacements==0,app.incrementalTranscript.charactersInserted==0,app.incrementalTranscript.charactersRemoved==0 else{throw Failure(code:"meter_event_does_not_project_transcript")}
    app.naming.set(segment:"projection-5000",name:"确认人物");app.markAllTranscriptParentsDirty()
    let exportURL=directory.appendingPathComponent("incremental-refresh-export.txt");app.saveTranscriptAsync(to:exportURL)
    guard app.fullTranscriptRefreshPending || app.fullRefreshBuildInFlight else{throw Failure(code:"export_waits_for_full_refresh")}
    guard !app.cacheExportJob.busy else{throw Failure(code:"export_started_before_projection_settled")}
    try app.settleTranscriptForOfflineReview()
    let deadline=Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath:exportURL.path) && Date()<deadline {_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}
    guard FileManager.default.fileExists(atPath:exportURL.path),!app.fullTranscriptRefreshPending,!app.fullRefreshBuildInFlight else{throw Failure(code:"export_waits_for_full_refresh_timeout")}
    let refreshedExport=try String(contentsOf:exportURL,encoding:.utf8)
    guard refreshedExport.contains("确认人物"),refreshedExport.contains("长会话第0段"),refreshedExport.contains("长会话第9999段") else{throw Failure(code:"export_contains_refreshed_full_transcript")}
    let uiMetrics=["initial_parents":10_000,"append_projection_computations":1,"append_block_insertions":1,"revision_projection_computations":1,"revision_block_replacements":1,"meter_projection_computations":0,"meter_text_edits":0]
    app.window.orderOut(nil)
    return ["counts":[10_000,50_000],"append_counters":appendCounters,"interleave_and_revision":true,"delegate_projection":uiMetrics,"all_text_preserved":true]
}

@MainActor func recordingControlChecks(directory:URL)async throws->[String:Any] {
    guard Credential.offline,let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,
          directory.standardizedFileURL.path.hasPrefix(root+"/.runtime/") else {throw Failure(code:"recording_control_scope")}
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    var checks:[String]=[]
    func check(_ condition:@autoclosure ()->Bool,_ name:String)throws{guard condition() else{throw Failure(code:name)};checks.append(name)}
    func wait(_ name:String,_ done:()->Bool)async throws {let until=Date().addingTimeInterval(12);while !done() && Date()<until {try await Task.sleep(nanoseconds:20_000_000)};guard done() else{throw Failure(code:"recording_control_timeout_"+name)}}
    func app()->Delegate {let value=Delegate();value.previewRenderOnly=true;value.mock=true;value.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));value.recoveryRootOverride=directory;value.qaStore=nil;return value}
    func event(_ session:String,_ id:String,_ track:String="mic",_ text:String?=nil)->[String:Any] {let bundle="com.example.meeting";let source=track=="mic" ? "mic":applicationAudioSourceID(bundle);return ["type":"segment","session":session,"segment_id":id,"source_id":source,"track":source,"bundle_id":bundle,"application_name":"腾讯会议","epoch":"fixture","start":1.0,"end":2.0,"text":text ?? id,"revision":1,"final":true,"speaker":["basis":"unknown"]]}
    let incrementalMetrics=try incrementalTranscriptRegressionChecks(directory:directory)

    let endedMeeting=app();try await wait("ended_fixture_history_read"){!endedMeeting.cacheReadJob.busy && !endedMeeting.cacheReadJob.waiting}
    endedMeeting.phase.phase = .ended;endedMeeting.activeSession="previous-session";endedMeeting.currentCacheID=UUID().uuidString
    endedMeeting.receive(event("previous-session","上一场保留"));endedMeeting.updateUI();endedMeeting.primaryWorkspaceAction()
    try await wait("missing_saved_meeting_append_releases_save_gate"){!endedMeeting.newMeetingRequested && !endedMeeting.newMeetingSaveInFlight}
    try check(endedMeeting.activeSession=="previous-session" && endedMeeting.sequence==["上一场保留"] && endedMeeting.action.isEnabled && endedMeeting.action.title=="继续这场录音" && endedMeeting.diagnostic.stringValue.contains("保存未完成"),"failed_saved_append_preserves_original_conversation_and_allows_retry")

    let controls=app();controls.phase.phase = .recording;controls.activeSession="session-a";controls.currentCacheID=UUID().uuidString
    controls.receive(event("session-a","保留原文一"));controls.updateUI()
    controls.receive(["type":"processing_failed","session":"session-a","consumer":"asr","track":"mic","reason":"cache_transcript_write_failed","audio_retained":true,"retry_available":true])
    try check(controls.phase.phase == .recording && controls.asrNetworkStates["mic"]=="pending" && controls.diagnostic.stringValue.contains("录音继续进行"),"transcript_processing_failure_does_not_stop_recording")
    var commands:[[String:Any]]=[];controls.mockRecordingControlHandler={commands.append($0)}
    controls.sendRecordingControl("pause")
    try check(controls.phase.phase == .recording && controls.recordingControlInFlight=="pause","pause_waits_for_helper_ack")
    try check(commands.last?["session"] as? String=="session-a" && commands.last?["action"] as? String=="pause","pause_targets_current_session")
    controls.receive(["type":"recording_paused","session":"other","recording_elapsed_seconds":3.0])
    try check(controls.phase.phase == .recording,"wrong_session_ack_ignored")
    controls.receive(["type":"recording_paused","session":"session-a","recording_elapsed_seconds":3.0])
    try check(controls.phase.phase == .paused && controls.sequence==["保留原文一"] && controls.currentCacheID != nil,"pause_preserves_transcript_and_cache")
    let delayed=app();delayed.phase.phase = .recording;delayed.activeSession="delayed-ui-ack";delayed.currentCacheID=UUID().uuidString
    delayed.mockRecordingControlHandler={_ in};var unintendedStops=0;delayed.mockStopHandler={unintendedStops+=1}
    delayed.sendRecordingControl("pause");delayed.recordingControlTimeout?.perform()
    try check(delayed.phase.phase == .recording && delayed.recordingControlInFlight=="pause" && unintendedStops==0,"ui_delivery_delay_does_not_stop_or_resubmit_recorder")
    delayed.receive(["type":"recording_paused","session":"delayed-ui-ack","control_revision":1,"draining_tracks":["mic"]])
    try check(delayed.phase.phase == .paused && delayed.action.isEnabled && delayed.currentCacheID != nil,"delayed_pause_ack_restores_same_session_continue")
    delayed.receive(["type":"stopped","session":"delayed-ui-ack","reason":"user_stop","capture_failure_reason":"capture_control_timeout_pause","transcription_complete":true])
    try check(delayed.phase.phase == .failed && delayed.cachedTranscriptionComplete && delayed.action.title=="继续这场录音" && delayed.action.isEnabled && delayed.heading.stringValue.contains("中断"),"recovered_transcription_cannot_hide_capture_failure")
    let writerFailure=app();writerFailure.phase.phase = .recording;writerFailure.activeSession="writer-failure";writerFailure.currentCacheID=UUID().uuidString
    writerFailure.receive(["type":"capture_stopped","session":"writer-failure","reason":"cache_writer_backpressure","capture":false,"capture_gate":"closed","upload_gate":"draining_saved_audio","recording_elapsed_seconds":12.0])
    try check(writerFailure.phase.phase == .stopping && writerFailure.diagnostic.stringValue.contains("录音已中断") && writerFailure.diagnostic.stringValue.contains("已保存原音"),"capture_writer_failure_is_visible_before_transcription_drain")
    writerFailure.receive(["type":"stopped","session":"writer-failure","reason":"cache_writer_backpressure","capture_failure_reason":"cache_writer_backpressure","transcription_complete":false])
    try check(writerFailure.phase.phase == .failed && writerFailure.action.title=="继续这场录音" && writerFailure.action.isEnabled,"capture_failure_keeps_same_session_recoverable")
    writerFailure.window.orderOut(nil)
    let sourceGap=app();sourceGap.phase.phase = .recording;sourceGap.activeSession="source-gap";sourceGap.currentCacheID=UUID().uuidString
    sourceGap.receive(["type":"audio_source","session":"source-gap","source_id":"app-0123456789abcdef-g1","core_source_id":"app-0123456789abcdef","application_name":"腾讯会议","state":"capture_unavailable","reason":"cache_writer_backpressure","raw_microphone_retained":true])
    try check(sourceGap.source.stringValue.contains("正在恢复"),"remote_source_failure_is_visible_while_recorder_recovers_generation")
    sourceGap.receive(["type":"audio_source","session":"source-gap","source_id":"app-0123456789abcdef-g2","core_source_id":"app-0123456789abcdef","application_name":"腾讯会议","state":"capture_recovered","had_capture_gap":true])
    try check(sourceGap.source.stringValue.contains("曾中断") && sourceGap.source.stringValue.contains("缺失时段无法补录"),"recovered_remote_source_keeps_gap_visible")
    sourceGap.receive(["type":"stopped","session":"source-gap","reason":"user_finish","transcription_complete":true,"audio_sources_complete":false,"source_capture_gaps":[["core_source_id":"app-0123456789abcdef","application_name":"腾讯会议","reason":"cache_writer_backpressure"]]])
    try check(sourceGap.cachedTranscriptionComplete && sourceGap.diagnostic.stringValue.contains("腾讯会议有一段声音未录到"),"source_capture_gap_is_distinct_from_transcription_completion")
    sourceGap.window.orderOut(nil)
    delayed.phase.phase = .paused;delayed.phase.error=nil
    delayed.workerExitReceived=true;delayed.workerEOFReceived=true;delayed.completeWorkerIfDrained()
    try check(delayed.phase.phase == .failed && delayed.heading.stringValue.contains("意外退出"),"unexpected_worker_exit_is_not_a_successfully_saved_pause")
    delayed.window.orderOut(nil)
    let tail=app();try await wait("pause_tail_fixture_history_read"){!tail.cacheReadJob.busy && !tail.cacheReadJob.waiting};tail.phase.phase = .recording;tail.activeSession="pause-tail-ui";tail.currentCacheID=UUID().uuidString
    tail.receive(["type":"recording_paused","session":"pause-tail-ui","control_revision":4,"draining_tracks":["mic","remote"]])
    try check(tail.phase.phase == .paused && tail.heading.stringValue.contains("正在补齐文字") && tail.action.isEnabled,"pause_tail_keeps_recording_paused_and_resume_available")
    tail.receive(["type":"recording_pause_tail","session":"other","pause_revision":4,"track":"mic","state":"complete"])
    tail.receive(["type":"recording_pause_tail","session":"pause-tail-ui","pause_revision":3,"track":"mic","state":"complete"])
    try check(tail.pausedTailStates["mic"]=="processing","foreign_or_previous_pause_tail_cannot_finish_current_pause")
    tail.receive(["type":"recording_pause_tail","session":"pause-tail-ui","pause_revision":4,"track":"mic","state":"complete"])
    try check(tail.heading.stringValue.contains("正在补齐文字"),"one_completed_track_does_not_claim_all_pause_tail_complete")
    tail.receive(["type":"recording_pause_tail","session":"pause-tail-ui","pause_revision":4,"track":"remote","state":"complete"])
    try check(tail.phase.phase == .paused && tail.heading.stringValue.contains("已录内容已转写"),"all_completed_pause_tracks_show_automatic_tail_completion_without_recording")
    tail.receive(["type":"recording_resumed","session":"pause-tail-ui","control_revision":5])
    tail.receive(["type":"recording_pause_tail","session":"pause-tail-ui","pause_revision":4,"track":"mic","state":"pending"])
    try check(tail.phase.phase == .recording && tail.pausedTailStates.isEmpty,"late_pause_result_after_resume_cannot_restore_paused_state")
    tail.receive(["type":"recording_paused","session":"pause-tail-ui","control_revision":4,"draining_tracks":["mic"]])
    try check(tail.phase.phase == .recording && tail.pausedTailStates.isEmpty,"late_pause_ack_after_resume_cannot_restore_paused_ui")
    tail.receive(["type":"recording_paused","session":"pause-tail-ui","control_revision":6,"draining_tracks":[]])
    tail.receive(["type":"recording_resumed","session":"pause-tail-ui","control_revision":5])
    try check(tail.phase.phase == .paused && tail.lastRecordingControlRevision==6,"late_resume_ack_cannot_override_new_pause_ui")
    let devicePause=app();devicePause.phase.phase = .recording;devicePause.activeSession="device-pause-session";devicePause.currentCacheID=UUID().uuidString
    let deviceCache=devicePause.currentCacheID
    devicePause.receive(["type":"recording_paused","session":"device-pause-session","control_revision":1,"reason":"input_device_changed","draining_tracks":[]])
    try check(devicePause.phase.phase == .paused && devicePause.action.title.contains("继续") && devicePause.action.isEnabled && devicePause.diagnostic.stringValue.contains("输入设备"),"device_change_is_visible_resumable_pause")
    var deviceCommand:[String:Any]=[:];devicePause.mockRecordingControlHandler={deviceCommand=$0};devicePause.primaryWorkspaceAction()
    try check(deviceCommand["action"] as? String=="resume" && deviceCommand["session"] as? String=="device-pause-session" && devicePause.currentCacheID==deviceCache && !devicePause.newMeetingRequested,"device_pause_continue_targets_same_conversation")
    devicePause.receive(["type":"recording_paused","session":"device-pause-session","control_revision":2,"reason":"input_device_changed","draining_tracks":[]])
    try check(devicePause.phase.phase == .paused && devicePause.recordingControlInFlight==nil && devicePause.currentCacheID==deviceCache,"device_change_during_resume_clears_pending_resume_and_stays_in_session")
    devicePause.window.orderOut(nil)
    // Plugging in headphones changes the default microphone: resume by itself.
    let autoResume=app();autoResume.phase.phase = .recording;autoResume.activeSession="auto-resume-session";autoResume.currentCacheID=UUID().uuidString
    var autoCommand:[String:Any]=[:];autoResume.mockRecordingControlHandler={autoCommand=$0}
    autoResume.receive(["type":"recording_paused","session":"auto-resume-session","control_revision":1,"reason":"input_device_changed","draining_tracks":[]])
    let autoDeadline=Date().addingTimeInterval(2.0)
    while Date()<autoDeadline && autoCommand.isEmpty {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.05))}
    try check(autoCommand["action"] as? String=="resume" && autoCommand["session"] as? String=="auto-resume-session","microphone_change_pause_resumes_automatically")
    autoResume.window.orderOut(nil)
    controls.sendRecordingControl("resume")
    try check(controls.phase.phase == .paused && commands.last?["session"] as? String=="session-a","resume_reuses_same_session")
    controls.receive(["type":"recording_resumed","session":"session-a","recording_elapsed_seconds":4.0])
    try check(controls.phase.phase == .recording && controls.sequence==["保留原文一"],"resume_ack_keeps_existing_timeline")
    controls.receive(["type":"echo_status","track":"mic","session":"session-a","state":"processedWithRawEdges"])
    try check(controls.echoStatusLabel.contains("部分声音") && controls.echoStatusLabel.contains("可能重复"),"camel_case_echo_status_is_understood")
    controls.receive(["type":"echo_status","track":"mic","session":"session-a","state":"referenceMisaligned"])
    try check(controls.echoStatusLabel.contains("参考未对齐") && controls.echoStatusLabel.contains("可能重复"),"echo_alignment_failure_is_distinguished")
    controls.receive(["type":"echo_status","track":"mic","session":"session-a","state":"modelUnavailable"])
    try check(controls.echoStatusLabel.contains("处理不可用") && controls.echoStatusLabel.contains("耳机"),"echo_model_failure_explains_echo_risk_and_headphone_option")
    let zeroRaw:[String:Any]=["hardware_pcm_frames":80,"nonzero_samples":0,"signal_rms":0.0,"last_packet_age_seconds":0.0]
    let remoteID=applicationAudioSourceID("com.example.meeting")
    controls.receive(["type":"capture_status","session":"session-a","elapsed_seconds":9.0,"paused":false,"tracks":["mic":256_000,remoteID:256_000],"signal":["mic":["raw_signal":zeroRaw,"clean_signal":zeroRaw],remoteID:["hardware_pcm_frames":80,"nonzero_samples":100,"signal_rms":0.1]]])
    try check(controls.sourceActivity.microphoneWarning != nil && controls.heading.stringValue.contains("麦克风收音异常") && !controls.diagnostic.isHidden,"zero_microphone_warns_even_with_existing_asr_and_remote_sound")
    try check(controls.source.stringValue.contains("全零") && !controls.source.stringValue.contains("回声处理正常"),"raw_zero_cannot_be_masked_by_bytes_or_echo_success")
    controls.receive(["type":"capture_status","session":"other-session","tracks":["mic":320_000],"signal":["mic":["raw_signal":["hardware_pcm_frames":100,"nonzero_samples":100]]]])
    try check(controls.sourceActivity.microphoneWarning != nil,"other_session_cannot_clear_microphone_warning")
    let liveRaw:[String:Any]=["hardware_pcm_frames":100,"nonzero_samples":1000,"signal_rms":0.1,"last_packet_age_seconds":0.0,"last_nonzero_age_seconds":0.0]
    controls.receive(["type":"capture_status","session":"session-a","elapsed_seconds":10.0,"paused":false,"tracks":["mic":320_000],"signal":["mic":["raw_signal":liveRaw,"clean_signal":liveRaw]]])
    try check(controls.sourceActivity.microphoneWarning==nil && !controls.heading.stringValue.contains("麦克风收音异常") && !controls.microphoneSignalAlertVisible,"microphone_signal_recovery_clears_only_its_warning")
    var activity=SourceActivity()
    activity.receive(["type":"capture_status","elapsed_seconds":9.0,"paused":true,"tracks":["mic":32000],"signal":["mic":["raw_signal":zeroRaw]]])
    try check(activity.microphoneWarning==nil,"paused_capture_is_not_a_microphone_failure")
    activity.receive(["type":"capture_status","elapsed_seconds":10.0,"paused":false,"tracks":["mic":32000],"signal":["mic":["raw_signal":liveRaw,"clean_signal":zeroRaw]]])
    try check(activity.microphoneWarning?.contains("处理后无声")==true,"raw_signal_and_cleaned_signal_failures_are_distinguished")
    var stale=liveRaw;stale["last_packet_age_seconds"]=4.0
    activity.receive(["type":"capture_status","elapsed_seconds":20.0,"tracks":["mic":32000],"signal":["mic":["raw_signal":stale]]])
    try check(activity.microphoneWarning?.contains("未收到音频")==true,"stale_microphone_warns_after_previous_success")

    controls.speakerLoading=true;controls.receive(["type":"speaker_model","state":"failed"])
    try check(!controls.speakerLoading && controls.diagnostic.stringValue.contains("文字记录继续"),"speaker_model_failure_does_not_block_transcription")
    controls.receive(["type":"audio_source","state":"detected","source_id":applicationAudioSourceID("com.example.meeting"),"bundle_id":"com.example.meeting","application_name":"腾讯会议"])
    try check(controls.observedAppSources.values.contains("腾讯会议"),"source_app_name_is_shown_when_validated")
    try check(audioSourceLabel(event("session-a","app","remote").merging(["application_name":"腾讯会议"],uniquingKeysWith:{_,new in new}))=="腾讯会议","source_identity_label_validates_bundle")

    let cancelled=app();cancelled.phase.phase = .recording;cancelled.activeSession="cancel-session";cancelled.currentCacheID=UUID().uuidString;cancelled.receive(event("cancel-session","取消应保留"));cancelled.savePanelURLProvider={nil};cancelled.exportTranscript()
    try check(cancelled.phase.phase == .recording && cancelled.sequence.count==1,"export_cancel_does_not_end_meeting")

    let folder=directory.appendingPathComponent(UUID().uuidString,isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let target=folder.appendingPathComponent("meeting.txt");let ending=app();ending.phase.phase = .paused;ending.activeSession=folder.lastPathComponent;ending.currentCacheID=folder.lastPathComponent
    ending.receive(event(ending.activeSession!,"开场文字","mic","开场文字"));ending.receive(event(ending.activeSession!,"尾段文字","mic","最后一句尾段"));ending.savePanelURLProvider={target};ending.exportTranscript()
    try await wait("snapshot_export"){FileManager.default.fileExists(atPath:target.path) && !ending.cacheExportJob.busy}
    let exported=try String(contentsOf:target,encoding:.utf8)
    try check(exported.contains("开场文字") && exported.contains("最后一句尾段"),"export_contains_all_available_text")
    try check(ending.phase.phase == .paused && ending.currentCacheID==folder.lastPathComponent && !FileManager.default.fileExists(atPath:folder.appendingPathComponent("meeting-lifecycle.json").path),"export_preserves_paused_conversation_without_ending_it")
    let failedFolder=directory.appendingPathComponent(UUID().uuidString,isDirectory:true);try FileManager.default.createDirectory(at:failedFolder,withIntermediateDirectories:true)
    let failed=app();failed.phase.phase = .recording;failed.activeSession=failedFolder.lastPathComponent;failed.currentCacheID=failedFolder.lastPathComponent;failed.receive(event(failed.activeSession!,"失败仍保留","mic"));failed.savePanelURLProvider={failedFolder.appendingPathComponent("missing/meeting.txt")};failed.exportTranscript()
    try await wait("failed_export"){!failed.cacheExportJob.busy && failed.diagnostic.stringValue.contains("导出失败")}
    try check(failed.phase.phase == .recording && failed.sequence.contains("失败仍保留"),"export_failure_does_not_stop_recording")
    let retryURL=failedFolder.appendingPathComponent("retry.txt");failed.savePanelURLProvider={retryURL};failed.exportTranscript();try await wait("export_retry"){FileManager.default.fileExists(atPath:retryURL.path) && !failed.cacheExportJob.busy}
    try check(failed.phase.phase == .recording,"successful_export_retry_keeps_recording")

    let owner=app();owner.phase.phase = .recording;owner.activeSession="owner-session";owner.currentCacheID=UUID().uuidString
    let history=app();history.isHistoryReader=true;history.workspaceOwner=owner;owner.historyReader=history;history.currentCacheID=UUID().uuidString;history.meetingTitle="历史会议";history.receive(event(history.currentCacheID!,"历史文字"));let historyURL=directory.appendingPathComponent("history.txt");history.savePanelURLProvider={historyURL};owner.exportVisibleDocument();try await wait("history_export"){FileManager.default.fileExists(atPath:historyURL.path) && !history.cacheExportJob.busy}
    try check(owner.phase.phase == .recording && owner.activeSession=="owner-session","history_export_does_not_stop_live_owner")

    let backlog=app();backlog.mock=false;backlog.phase.phase = .recording;backlog.activeSession="long-fixture";var payload=Data()
    for index in 0..<1500 {let row:[String:Any]=["type":"segment","session":"long-fixture","segment_id":"long-\(index)","source_id":"mic","track":"mic","epoch":"long-fixture","start":Double(index),"end":Double(index)+0.5,"text":"合成长会话第\(index)段","revision":1,"final":true,"speaker":["basis":"unknown"]];payload.append(try JSONSerialization.data(withJSONObject:row));payload.append(10)}
    backlog.readLock.lock();backlog.pending=payload;backlog.readLock.unlock();let started=Date();backlog.drain()
    let interruptedBeforeDrain=backlog.sequence.count<1500 && !backlog.buffer.isEmpty
    backlog.mock=true;backlog.mockRecordingControlHandler={command in backlog.receive(["type":command["action"] as? String=="pause" ? "recording_paused":"recording_resumed","session":"long-fixture","recording_elapsed_seconds":1500.0])};backlog.sendRecordingControl("pause")
    try check(interruptedBeforeDrain && backlog.phase.phase == .paused,"pause_is_serviced_while_long_transcript_is_queued")
    try await wait("long_transcript_drain"){backlog.sequence.count==1500 && backlog.buffer.isEmpty && backlog.pending.isEmpty};let drainDuration=Date().timeIntervalSince(started)
    try check(drainDuration<12 && backlog.sequence.count==1500,"long_transcript_is_drained_in_responsive_batches")
    let visual=app();visual.meetingTitle="产品讨论";var images:[String]=[]
    for (name,size,state) in [("recording-idle",NSSize(width:1040,height:720),RecordingPhase.idle),("recording-active",NSSize(width:1040,height:720),RecordingPhase.recording),("recording-paused",NSSize(width:1040,height:720),RecordingPhase.paused),("recording-narrow",NSSize(width:640,height:480),RecordingPhase.recording)] {
        visual.window.appearance=NSAppearance(named:.aqua);visual.window.setContentSize(size);visual.layoutWorkspace()
        if state != .idle && visual.sequence.isEmpty {
            visual.activeSession="visual";visual.currentCacheID=UUID().uuidString;visual.cachedTranscriptionComplete=false
            visual.receive(event("visual","visual-1","remote","先把品牌主张讲清楚，再比较用户反馈与预算。"))
            visual.receive(event("visual","visual-2","mic","我们保留两个创意方向，下次会议确认执行方案。"))
            visual.receive(["type":"audio_source","state":"detected","source_id":applicationAudioSourceID("com.example.meeting"),"bundle_id":"com.example.meeting","application_name":"腾讯会议"])
        }
        visual.phase.phase=state;visual.phase.elapsed=state == .idle ? 0:125;visual.renderText();visual.updateUI();visual.window.contentView!.layoutSubtreeIfNeeded()
        let target=visual.window.contentView!.superview!;guard let bitmap=target.bitmapImageRepForCachingDisplay(in:target.bounds) else{throw Failure(code:"recording_bitmap")}
        target.effectiveAppearance.performAsCurrentDrawingAppearance {target.cacheDisplay(in:target.bounds,to:bitmap)}
        let image=NSImage(size:target.bounds.size);image.lockFocus();NSColor.windowBackgroundColor.setFill();NSBezierPath(rect:target.bounds).fill();bitmap.draw(in:target.bounds);image.unlockFocus()
        let opaque=NSBitmapImageRep(data:image.tiffRepresentation!)!;let file=directory.appendingPathComponent(name+".png");try opaque.representation(using:.png,properties:[:])!.write(to:file);images.append(file.path)
    }
    try check(visual.transcriptExport().contains("文字来源：麦克风、电脑声音、腾讯会议"),"export_lists_microphone_and_computer_sources_once")
    let selected=visual.incrementalTranscript.range(forTurn:"visual-1")!;visual.output.setSelectedRange(NSRange(location:selected.location,length:1))
    var revised=event("visual","visual-1","remote","先把品牌主张说清楚，再比较用户反馈与预算。");revised["revision"]=2;visual.receive(revised)
    try check(visual.output.selectedRange().length==1,"single_character_selection_survives_local_revision")
    for view in [controls,cancelled,ending,failed,owner,history,backlog,visual,endedMeeting] {view.window?.orderOut(nil)}
    return ["type":"recording_control_checks","passed":checks.count,"checks":checks,"images":images,"incremental_transcript":incrementalMetrics,"long_transcript_events":1500,"long_transcript_drain_seconds":drainDuration,"capture":false,"cloud":false,"keychain":false,"offscreen":true]
}

@MainActor func newMeetingLifecycleChecks(directory:URL) async throws->[String:Any] {
    guard Credential.offline,directory.path.contains("/.runtime/") else{throw Failure(code:"new_meeting_fixture_scope")}
    _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let view=Delegate();view.previewRenderOnly=true;view.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));view.recoveryRootOverride=directory;view.qaStore=nil
    try view.vault.save("fixture-key")
    var checks:[String]=[],retained:[String:[String:Data]]=[:]
    func check(_ ok:Bool,_ name:String)throws {guard ok else{throw Failure(code:name)};checks.append(name);print("new-meeting-check: "+name)}
    func wait(_ predicate:()->Bool) async throws {let until=Date().addingTimeInterval(8);while !predicate(),Date()<until{try await Task.sleep(nanoseconds:10_000_000);_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.002))};guard predicate() else{throw Failure(code:"new_meeting_fixture_deadline_"+view.phase.phase.rawValue+"_"+String(view.newMeetingRequested)+"_"+view.diagnostic.stringValue)}}
    func seed(_ suffix:String) throws->URL {
        let id=UUID().uuidString,session="lifecycle-"+suffix,folder=directory.appendingPathComponent(id)
        let store=try RecordingJournal(directory:folder,track:"mic",freeSpace:{1_000_000_000})
        try store.enqueue(Data(repeating:0x37,count:3200),at:0);store.wait()
        try JSONSerialization.data(withJSONObject:["session":session,"cache_id":id,"bundle":"*microphone*"]).write(to:folder.appendingPathComponent("meeting.json"))
        view.currentCacheID=id;view.activeSession=session;view.phase.phase = .recording;view.cachedTranscriptionComplete=false
        let row:[String:Any]=["type":"segment","session":session,"segment_id":"preserved-"+suffix,"source_id":"mic","track":"mic","epoch":session,"revision":1,"start":0.0,"end":1.0,"final":true,"text":"上一场原文必须保留。","speaker":["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":session]]
        store.record(row);store.finish();store.wait();view.receive(row);view.naming.setSpeaker(segment:"preserved-"+suffix,name:"原人物");view.persistSessionNames();view.cacheWriteQueue.sync{}
        view.mockStopHandler={view.receive(["type":"stopped","session":session,"reason":"user_stop","transcription_complete":false])}
        view.mockRecordingControlHandler={command in view.receive(["type":command["action"] as? String=="pause" ? "recording_paused":"recording_resumed","session":session,"recording_elapsed_seconds":0.1])}
        view.updateUI();retained[folder.path]=Dictionary(uniqueKeysWithValues:try ["mic-000000.pcm","mic-transcript.jsonl","session-names.json"].map{($0,try Data(contentsOf:folder.appendingPathComponent($0)))})
        return folder
    }
    let cancelled=try seed("cancel")
    view.action.performClick(nil);try check(view.phase.phase == .paused && view.newButton!.isEnabled,"pause_keeps_new_meeting_enabled")
    view.savePanelURLProvider={nil};view.exportTranscript()
    try check(view.phase.phase == .paused && view.currentCacheID==cancelled.lastPathComponent && view.newButton!.isEnabled,"cancelled_export_does_not_gate_new_meeting")
    view.requestNewMeeting();let generation=view.meetingDocumentGeneration;view.requestNewMeeting()
    try await wait({view.phase.phase == .idle && view.currentCacheID==nil && !view.newMeetingRequested})
    try check(view.meetingDocumentGeneration==generation+1,"repeated_new_request_ends_previous_and_creates_once")
    let receipt=try JSONSerialization.jsonObject(with:Data(contentsOf:cancelled.appendingPathComponent("meeting-lifecycle.json"))) as! [String:Any]
    try check(receipt["lifecycle"] as? String=="ended","capture_lifecycle_is_saved_without_successful_export")
    let titleEdit=try seed("title-editor-focus")
    let oldTitle="本机仅录音验证｜暂停继续两轮"
    view.meetingTitle="原会议名称";view.meetingTitleField.stringValue="原会议名称";view.updateWorkspacePresentation()
    view.window.makeKeyAndOrderFront(nil)
    try check(view.window.makeFirstResponder(view.meetingTitleField),"title_focus_fixture_activates_title_field")
    guard let titleEditor=view.meetingTitleField.currentEditor() as? NSTextView else{throw Failure(code:"title_focus_fixture_missing_field_editor")}
    titleEditor.string=oldTitle
    try check(view.meetingTitleField.currentEditor() != nil,"title_focus_fixture_has_live_field_editor")
    view.requestNewMeeting()
    try await wait({view.phase.phase == .idle && view.currentCacheID==nil && !view.newMeetingRequested})
    let savedOldTitle=try MeetingDisplayInfoStore.load(in:titleEdit)
    let expectedNewTitle=MeetingLibraryInfo.defaultTitle(Date())
    try check(savedOldTitle?.title==oldTitle && savedOldTitle?.provenance == .manual,"new_conversation_commits_title_editor_to_previous_cache")
    try check(view.meetingTitle==expectedNewTitle && view.meetingTitleField.stringValue==expectedNewTitle && view.meetingTitleField.currentEditor()==nil,"new_conversation_resets_accessible_title_after_ending_old_editor")
    try check(view.currentCacheID==nil && view.activeSession==nil && view.phase.phase == .idle && view.sequence.isEmpty && view.child==nil,"new_conversation_does_not_inherit_previous_cache_or_start_capture")
    view.mockStopHandler=nil;view.action.performClick(nil)
    try await wait({view.phase.phase == .recording && view.currentCacheID != nil})
    let firstNewID=view.currentCacheID!;view.timer?.invalidate();view.timer=nil
    try check((try Data(contentsOf:directory.appendingPathComponent(firstNewID).appendingPathComponent("mic-000000.pcm"))).count>0,"first_new_meeting_has_synthetic_audio_frames_before_recording_success")
    view.end();try await wait({view.phase.phase == .stopped && !view.qaWriteJob.busy})
    view.requestNewMeeting();try await wait({view.phase.phase == .idle && !view.newMeetingRequested})
    view.action.performClick(nil);try await wait({view.phase.phase == .recording && view.currentCacheID != nil})
    let secondNewID=view.currentCacheID!;view.timer?.invalidate();view.timer=nil;try check(firstNewID != secondNewID,"stop_then_new_starts_a_distinct_second_meeting")
    view.end();try await wait({view.phase.phase == .stopped && !view.qaWriteJob.busy});view.requestNewMeeting();try await wait({view.phase.phase == .idle && !view.newMeetingRequested})
    let failed=try seed("failed-export");view.savePanelURLProvider={failed.appendingPathComponent("missing/file.txt")};view.exportTranscript()
    try await wait({view.phase.phase == .recording && view.diagnostic.stringValue.contains("导出失败") && !view.cacheExportJob.busy})
    try check(view.newButton!.isEnabled && view.currentCacheID==failed.lastPathComponent && view.sequence.contains("preserved-failed-export"),"failed_export_does_not_gate_new_meeting_or_discard_old_session")
    view.requestNewMeeting();try await wait({view.phase.phase == .idle && !view.newMeetingRequested})
    let saveFailed=try seed("save-failed"),oldCache=view.currentCacheID,oldSession=view.activeSession
    let missingRoot=directory.appendingPathComponent("unavailable-root")
    view.recoveryRootOverride=missingRoot;view.requestNewMeeting()
    try await wait({!view.newMeetingRequested && !view.newMeetingSaveInFlight})
    try check(view.currentCacheID==oldCache && view.activeSession==oldSession && view.naming.name(segment:"preserved-save-failed") == "原人物","save_failure_keeps_previous_document_and_names")
    view.recoveryRootOverride=directory;view.requestNewMeeting()
    try await wait({view.phase.phase == .idle && !view.newMeetingRequested})
    try check(FileManager.default.fileExists(atPath:saveFailed.appendingPathComponent("meeting-lifecycle.json").path),"retry_after_save_failure_completes_without_export")
    for (path,files) in retained {for (name,data) in files {try check(try Data(contentsOf:URL(fileURLWithPath:path).appendingPathComponent(name))==data,"preserved_"+URL(fileURLWithPath:path).lastPathComponent+"_"+name)}}
    view.phase.phase = .connecting
    view.receive(["type":"started","session":"no-frames","audio_frames_received":false])
    try check(view.phase.phase == .connecting && !view.heading.stringValue.contains("录音中"),"no_audio_frames_cannot_show_recording_success")
    view.receive(["type":"started","session":"no-frames","audio_frames_received":true])
    try check(view.phase.phase == .recording,"actual_frame_receipt_allows_recording_status")
    view.phase.phase = .connecting
    view.receive(["type":"started","session":"cached-processing","capture":false,"audio_frames_received":false])
    try check(view.phase.phase == .stopping,"cached_processing_cannot_show_live_recording")
    view.phase.phase = .stopped;view.window.orderOut(nil)
    let newFlow=Delegate();newFlow.previewRenderOnly=true;newFlow.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));newFlow.recoveryRootOverride=directory
    try newFlow.vault.save("fixture-key")
    newFlow.newButton!.performClick(nil)
    try await wait({!newFlow.newMeetingRequested && newFlow.phase.phase == .idle})
    try check(newFlow.newButton!.title=="新会议" && newFlow.currentCacheID==nil && newFlow.child==nil && newFlow.timer==nil && !newFlow.credentialReadJob.busy && newFlow.sequence.isEmpty,
              "new_conversation_opens_blank_without_starting_capture_or_reading_credentials")
    newFlow.receive(["type":"stopped","session":"previous-session","reason":"user_stop","transcription_complete":true])
    try check(newFlow.phase.phase == .idle && newFlow.currentCacheID==nil && newFlow.child==nil && newFlow.timer==nil,
              "late_previous_session_completion_cannot_change_or_start_blank_conversation")
    newFlow.newButton!.performClick(nil)
    try check(newFlow.phase.phase == .idle && newFlow.currentCacheID==nil && newFlow.timer==nil && !newFlow.credentialReadJob.busy,
              "repeated_new_conversation_click_does_not_start_capture")
    newFlow.window.orderOut(nil)
    return ["type":"new_meeting_lifecycle_checks","passed":checks.count,"checks":checks,"synthetic_sessions":[firstNewID,secondNewID],"capture":false,"network":false,"cloud":false,"keychain":false,"original_synthetic_audio_and_names_preserved":true]
}
