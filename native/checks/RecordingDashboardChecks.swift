import AppKit

@MainActor func recordingDashboardChecks(directory:URL) async throws->[String] {
    guard Credential.offline else{throw Failure(code:"dashboard_offline_only")}
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    var checks:[String]=[]
    func check(_ value:Bool,_ label:String)throws{guard value else{throw Failure(code:label)};checks.append(label)}
    let v=Delegate();v.previewRenderOnly=true;v.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));v.recoveryRootOverride=directory;v.meetingTitle="声音与文字 · 合成验收"
    try check(RecordingStartChoice.dashboardDefault(saved:"local_only",migrated:false) == .transcribe,"dashboard_first_upgrade_defaults_to_transcription")
    try check(RecordingStartChoice.dashboardDefault(saved:"local_only",migrated:true) == .localOnly,"dashboard_remembers_later_explicit_choice")
    try check(v.recordingModeSwitch?.selectedSegment==0 && v.recordingModeSwitch?.isEnabled==true && v.heading.stringValue.contains("录音并转写") && v.recordingModeChip?.isHidden==false && v.recordingModeChip?.selectedIndex==0,"home_shows_default_mode_before_start")
    func snap(_ name:String,width:CGFloat=1040,height:CGFloat=720,dark:Bool=false)throws {
        v.window.appearance=NSAppearance(named:dark ? .darkAqua:.aqua);v.window.setContentSize(NSSize(width:width,height:height));v.layoutWorkspace();v.window.contentView!.layoutSubtreeIfNeeded()
        let target=v.window.contentView!.superview!;let bitmap=target.bitmapImageRepForCachingDisplay(in:target.bounds)!
        target.effectiveAppearance.performAsCurrentDrawingAppearance{target.cacheDisplay(in:target.bounds,to:bitmap)}
        try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name+".png"))
        try check(v.microphoneLevel!.frame.width>=48 && v.computerLevel!.frame.width>=48 && v.scroll.frame.height>70 && (v.recordingTransportView?.subviews.first?.frame.maxX ?? .infinity)<=(v.recordingTransportView?.bounds.maxX ?? 0)+0.5,"dashboard_layout_"+name)
    }
    try snap("01-home-transcribe")
    v.recordingModeSwitch!.selectedSegment=1;v.selectDashboardMode(v.recordingModeSwitch!)
    try check(v.localOnlyMode && v.empty.stringValue.contains("保存在本机") && v.recordingModeHint!.isHidden && v.recordingModeSwitch!.accessibilityHelp()!.contains("只保存在本机"),"home_local_selection_changes_copy_without_launching")
    try check(v.child==nil && v.phase.phase == .idle,"mode_selection_does_not_start_audio_or_cloud")
    try snap("02-home-local")
    v.sessionLocalOnly=true;v.activeSession="dashboard-fixture";v.currentCacheID="dashboard-fixture";v.phase.phase = .recording;v.phase.elapsed=14;v.updateUI()
    try check(!v.recordingModeSwitch!.isEnabled && v.heading.stringValue.contains("仅录音中") && v.action.title=="暂停录音" && !v.action.isHiddenOrHasHiddenAncestor,"recording_has_one_primary_action_and_explicit_local_state")
    let level:[String:Any]=["type":"audio_levels","session":"dashboard-fixture","levels":["mic":["signal_rms":0.08,"signal_peak":0.3,"last_packet_age_seconds":0.0],"computer":["signal_rms":0.02,"signal_peak":0.1,"last_packet_age_seconds":0.0]]]
    v.receiveAudioLevels(level)
    try check(v.microphoneLevel!.rms==0.08 && v.computerLevel!.rms==0.02,"meters_display_independent_actual_signal_values")
    var stale=level;stale["session"]="previous-session";v.receiveAudioLevels(stale)
    try check(v.microphoneLevel!.rms==0.08,"other_session_levels_cannot_replace_current_levels")
    for i in 0..<48 {
        let x=0.002+pow(sin(Double(i)*0.37),2)*0.09
        v.receiveAudioLevels(["type":"audio_levels","session":"dashboard-fixture","levels":["mic":["signal_rms":x,"signal_peak":x*2],"computer":["signal_rms":x*0.3,"signal_peak":x]]])
    }
    try snap("03-recording-levels")
    v.refreshAudioLevels(now:ProcessInfo.processInfo.systemUptime+2)
    try check(v.microphoneLevel!.rms==0 && v.computerLevel!.rms==0,"stale_levels_decay_to_zero_without_fake_activity")
    v.phase.phase = .paused;v.updateUI();v.receiveAudioLevels(level)
    try check(v.microphoneLevel!.rms==0 && v.action.title=="继续录音" && !v.action.isHiddenOrHasHiddenAncestor && v.empty.stringValue.contains("已暂停") && v.heading.stringValue.contains("仅录音"),"paused_displays_zero_levels_and_only_resume")
    v.recordingModeSwitch!.selectedSegment=0;v.selectDashboardMode(v.recordingModeSwitch!)
    try check(v.localOnlyMode && v.recordingModeSwitch!.selectedSegment==1,"paused_mode_change_cannot_trigger_unapproved_upload")
    try snap("04-paused-local")
    var commands:[String]=[];v.mock=true;v.mockRecordingControlHandler={command in let action=command["action"] as? String ?? "";commands.append(action);v.receive(["type":action=="resume" ? "recording_resumed":"recording_paused","session":command["session"] as? String ?? "","control_revision":commands.count])}
    v.updateUI();v.action.performClick(nil)
    try check(commands==["resume"] && v.phase.phase == .recording && v.currentCacheID=="dashboard-fixture" && v.activeSession=="dashboard-fixture","resume_reuses_same_conversation_during_background_work")
    v.action.performClick(nil)
    try check(commands==["resume","pause"] && v.phase.phase == .paused && v.currentCacheID=="dashboard-fixture" && v.action.title=="继续录音","pause_resume_pause_stays_in_same_conversation")
    v.receive(["type":"stopped","session":"dashboard-fixture","reason":"user_stop"] )
    try check(v.empty.stringValue.contains("打开会议文件"),"saved_recording_points_to_the_same_full_files_entry")
    try snap("05-saved-local")
    v.phase.phase = .recording;v.sessionLocalOnly=false;v.asrNetworkStates=["mic":"waiting"];v.updateUI()
    try check(v.heading.stringValue.contains("转写等待网络"),"network_wait_does_not_claim_transcription_is_running")
    try snap("06-transcription-network-wait")
    v.phase.phase = .stopped;v.cachedTranscriptionComplete=false;v.updateUI()
    try check(v.empty.stringValue.contains("录音已保存") && v.emptyTranscribeButton?.isHidden==false && v.emptyFilesButton?.isHidden==false && v.emptyTranscribeButton?.title=="补转剩余录音" && !v.empty.stringValue.contains("开始后"),"saved_empty_incomplete_transcription_preserves_recording_and_recovery_guidance")
    try snap("06a-saved-incomplete-empty")
    try snap("06b-saved-incomplete-compact",width:640,height:480)
    try check(v.empty.frame.width<=v.scroll.frame.width-20 && !v.empty.isHidden,"saved_empty_recovery_guidance_fits_inside_compact_document")
    v.cachedTranscriptionComplete=true;v.updateUI()
    try check(v.empty.stringValue.contains("没有识别到文字") && v.empty.stringValue.contains("打开会议文件") && !v.empty.stringValue.contains("补转"),"completed_silent_meeting_does_not_claim_a_missing_transcription")
    v.isHistoryReader=true;v.cachedTranscriptionComplete=false;v.updateUI()
    try check(v.recordingModeHint!.isHidden && v.heading.stringValue=="录音已保存 · 待转写" && v.meetingEyebrow!.stringValue.hasSuffix(" · 转写尚未完成"),"history_hint_discloses_incomplete_transcription")
    v.cachedTranscriptionComplete=true;v.updateUI()
    try check(v.meetingEyebrow!.stringValue.hasSuffix(" · 录音与文字已保存"),"history_eyebrow_discloses_saved_recording_and_transcript")
    v.sessionLocalOnly=true;v.cachedTranscriptionComplete=false;v.updateUI()
    try check(v.meetingEyebrow!.stringValue.hasSuffix(" · 仅录音 · 未转写"),"history_eyebrow_discloses_record_only_without_transcript")
    v.sessionLocalOnly=false;v.isHistoryReader=false;v.phase.phase = .stopping;v.resumeBusy=true;v.processingAudio=true;v.updateUI()
    try check(v.meetingEyebrow!.stringValue.hasSuffix(" · 正在补齐已录文字"),"eyebrow_discloses_pending_transcription_work")
    v.phase.phase = .recording;v.updateUI()
    try check(v.meetingEyebrow!.stringValue.hasSuffix(" · 实时转写") && !v.meetingEyebrow!.stringValue.contains("正在补齐"),"recording_eyebrow_prioritizes_current_capture_mode")
    v.resumeBusy=false;v.processingAudio=false
    v.isHistoryReader=false;v.phase.phase = .paused;v.pausedTailStates=["mic":"pending"];v.updateUI()
    try check(v.empty.stringValue.contains("尚未完成") && !v.empty.stringValue.contains("正在补齐"),"paused_failed_tail_empty_state_matches_pending_heading")
    v.pausedTailStates=["mic":"complete"];v.updateUI()
    try check(v.empty.stringValue.contains("已录内容已转写") && !v.empty.stringValue.contains("正在补齐"),"paused_complete_empty_state_stops_claiming_active_transcription")
    v.pausedTailStates=[:]
    v.phase.phase = .idle;v.phase.elapsed=0;v.activeSession=nil;v.currentCacheID=nil;v.localOnlyMode=false;v.asrNetworkStates=[:];v.updateUI()
    try snap("07-compact",width:640,height:480);try snap("08-dark",dark:true)
    let generation=v.workerGeneration
    v.receive(["type":"started","session":"stale-worker","mode":"local_only"],workerID:UUID())
    try check(v.activeSession==nil && v.phase.phase == .idle,"previous_worker_started_callback_cannot_reopen_capture")
    v.activeSession="new-session";v.phase.phase = .recording
    v.receive(["type":"stopped","session":"old-session","reason":"user_stop"],workerID:generation)
    v.receive(["type":"error","session":"old-session","code":"no_sound"],workerID:generation)
    try check(v.phase.phase == .recording && v.phase.error==nil,"old_session_terminal_events_cannot_stop_new_meeting")
    // EOF/exit must not release child after the first 64-row UI slice.
    v.child=Process();v.workerExitReceived=true;v.workerEOFReceived=true
    let rows=(0..<150).map{_ in ["type":"meter","session":"new-session","elapsed_seconds":1.0] as [String:Any]}+[["type":"stopped","session":"new-session","reason":"user_stop"]]
    v.pending=try rows.reduce(into:Data()){result,event in result.append(try JSONSerialization.data(withJSONObject:event));result.append(10)}
    v.mock=false;v.drain()
    try check(v.child != nil,"worker_exit_waits_for_all_buffered_rows")
    let until=Date().addingTimeInterval(3)
    while v.child != nil && Date()<until {try await Task.sleep(nanoseconds:10_000_000)}
    try check(v.child==nil && v.buffer.isEmpty && v.pending.isEmpty && v.phase.phase == .stopped,"worker_eof_drains_terminal_event_before_new_meeting")
    v.audioLevelTimer?.invalidate();v.timer?.invalidate();v.window.orderOut(nil)
    return checks
}
