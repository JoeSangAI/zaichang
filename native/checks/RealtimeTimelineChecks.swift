import AppKit
import Foundation

// Synthetic events through the actual UI, journal, naming and export paths.
// No capture, network, credentials, desktop screenshots or real session cache.
@MainActor func realtimeTimelineChecks(directory: URL) throws -> [String: Any] {
    guard Credential.offline, let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,
          directory.standardizedFileURL.path.hasPrefix(root+"/.runtime/") else {throw Failure(code:"timeline_fixture_scope")}
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    var checks:[String]=[]
    for i in 0..<(try meetingAbsoluteTimeChecks()) {checks.append("actual_capture_absolute_time_\(i)")}
    for i in 0..<(try speakerReconciliationChecks(directory:directory)) {checks.append("reversible_speaker_reconciliation_\(i)")}

    func check(_ condition:@autoclosure ()->Bool,_ name:String)throws {guard condition() else{throw Failure(code:name)};checks.append(name)}
    func makeView()->Delegate {let v=Delegate();v.previewRenderOnly=true;v.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));v.window.contentView!.layoutSubtreeIfNeeded();v.resizeTranscript();return v}
    let view=makeView()
    func speaker(_ slot:Int)->[String:Any] {["basis":"anonymous_cluster","cluster_id":slot,"source_id":"mic","epoch":"fixture-epoch"]}
    func event(_ id:String,_ start:Double,_ text:String,_ slot:Int?=0,_ revision:Int=1)->[String:Any] {
        ["type":"segment","session":"timeline-fixture","segment_id":id,"source_id":"mic","track":"mic","epoch":"fixture-epoch","start":start,"end":start+4,"end_time_known":true,"text":text,"final":true,"revision":revision,"speaker":slot.map{speaker($0)} ?? ["basis":"unknown"]]
    }
    let nameReuse=makeView();nameReuse.activeSession="timeline-fixture";nameReuse.phase.phase = .recording
    var amberA=event("same-name-a",1,"合成人物第一句",7),amberB=event("same-name-b",5.5,"合成人物第二句",6)
    nameReuse.receive(amberA);nameReuse.receive(amberB)
    nameReuse.naming.setSpeaker(segment:"same-name-a",name:"说话人甲");nameReuse.naming.setSpeaker(segment:"same-name-b",name:"说话人甲")
    var otherEpoch=event("same-name-other-epoch",11,"另一录音轮次",5);otherEpoch["epoch"]="fixture-epoch-2";otherEpoch["speaker"]=["basis":"anonymous_cluster","cluster_id":5,"source_id":"mic","epoch":"fixture-epoch-2"]
    var otherSource=event("same-name-other-source",17,"另一音源",4);otherSource["source_id"]="remote"
    otherSource["track"]="remote";otherSource["speaker"]=["basis":"anonymous_cluster","cluster_id":4,"source_id":"remote","epoch":"fixture-epoch"]
    nameReuse.receive(otherEpoch);nameReuse.receive(otherSource)
    nameReuse.naming.setSpeaker(segment:"same-name-other-epoch",name:"说话人甲");nameReuse.naming.setSpeaker(segment:"same-name-other-source",name:"说话人甲")
    let sameNameIdentityA=nameReuse.transcriptIdentity(for:"same-name-a"),sameNameIdentityB=nameReuse.transcriptIdentity(for:"same-name-b")
    guard sameNameIdentityA==sameNameIdentityB &&
          nameReuse.transcriptIdentity(for:"same-name-a") != nameReuse.transcriptIdentity(for:"same-name-other-epoch") &&
          nameReuse.transcriptIdentity(for:"same-name-a") != nameReuse.transcriptIdentity(for:"same-name-other-source") else {
        throw Failure(code:"same_manual_name_merges_only_within_same_session_source_and_epoch:a=\(String(describing:sameNameIdentityA));b=\(String(describing:sameNameIdentityB));keyA=\(String(describing:nameReuse.naming.key(segment:"same-name-a")));keyB=\(String(describing:nameReuse.naming.key(segment:"same-name-b")))")
    }
    checks.append("same_manual_name_merges_only_within_same_session_source_and_epoch")
    // One mic sentence alternates roster keys for the same confirmed person.
    // It must read as one turn without changing the evidence or cross-track scope.
    let micKey=nameReuse.naming.key(segment:"same-name-a")!,remoteKey=nameReuse.naming.key(segment:"same-name-other-source")!
    func reconciled(_ key:SessionSpeakerKey)throws->[String:Any] {
        ["basis":"meeting_reconciliation","source_id":"mic","epoch":"fixture-epoch",
         "identity_key":try JSONSerialization.jsonObject(with:JSONEncoder().encode(key))]
    }
    var repeated=event("same-person-roster-switch",22,"那个叫示例项目的事情。",nil)
    repeated["speaker_runs"]=[
        ["start":22.0,"end":23.0,"text":"那个叫","speaker":try reconciled(remoteKey)],
        ["start":23.0,"end":24.0,"text":"示例项目","speaker":try reconciled(micKey)],
        ["start":24.0,"end":26.0,"text":"的事情。","speaker":try reconciled(remoteKey)]]
    nameReuse.receive(repeated);try nameReuse.settleTranscriptForOfflineReview()
    let samePersonTurns=nameReuse.readingTurns(["same-person-roster-switch"])
    try check(samePersonTurns.count==1 && samePersonTurns[0].item["text"] as? String=="那个叫示例项目的事情。" && samePersonTurns[0].parts.count==3,
              "same_physical_sentence_reconciled_to_same_manual_name_reads_as_one_turn")
    try check(TranscriptTimeline.speakerRuns(nameReuse.segments["same-person-roster-switch"]!).count==3 &&
              SessionSpeakerKey.from(samePersonTurns[0].parts[0].1)==remoteKey &&
              SessionSpeakerKey.from(samePersonTurns[0].parts[1].1)==micKey,
              "reading_merge_preserves_cross_track_person_keys_and_original_runs")
    let clock=CaptureBudgetClock(wallTime:{1791215990},uptime:{100},zone:TimeZone(identifier:"Asia/Shanghai")!)
    clock.mark(100)
    // Consecutive turns of one speaker read as one passage: later headers fold
    // by attributes only, so the text, ranges and export stay unchanged.
    let folded=makeView();folded.activeSession="timeline-fixture";folded.phase.phase = .recording
    for (i,(id,start,slot)) in [("fold-a",10.0,0),("fold-b",16.0,0),("fold-c",22.0,1),("fold-d",200.0,1)].enumerated() {folded.receive(event(id,start,"连续第\(i)句。",slot))}
    try folded.settleTranscriptForOfflineReview()
    var foldedStates:[Bool]=[]
    folded.output.textStorage!.enumerateAttribute(.zaichangTurnHeader,in:NSRange(location:0,length:folded.output.textStorage!.length)) {value,range,_ in
        guard value is TranscriptTurnHeader else{return}
        let font=folded.output.textStorage!.attribute(.font,at:range.location+1,effectiveRange:nil) as? NSFont
        foldedStates.append((font?.pointSize ?? 12)<1)
    }
    if ProcessInfo.processInfo.environment["ZAICHANG_FOLD_DEBUG"] != nil {print("fold-debug",foldedStates)}
    try check(foldedStates==[false,true,false,false] && folded.output.string.contains("连续第1句。") && folded.transcriptExport().contains("连续第1句。"),"same_speaker_continuation_folds_header_only")
    // A realistic synthetic conversation for visual review (offscreen, light).
    do {
        NSApp.appearance=NSAppearance(named:.aqua)
        let talk=makeView();talk.window.appearance=NSApp.appearance;talk.window.setContentSize(NSSize(width:1100,height:760))
        talk.activeSession="timeline-fixture";talk.phase.phase = .recording;talk.meetingTitle="示例项目｜验收范围与使用反馈"
        let lines:[(String,Double,Int,String)]=[("c1",31,0,"这周先把新版操作流程走查一遍，桌面版和导出文件分开确认。"),("c2",37,0,"上次记录的问题表已经整理到测试目录里。"),
            ("c3",44,1,"收到，我把主要页面和使用步骤放在同一个清单了。"),("c4",52,2,"这一步先看新用户能不能独立完成，不要只统计点击次数。"),
            ("c5",61,0,"同意。我们先整理一版测试结果，下周初一起核对。"),("c6",68,0,"另一个试用场景的反馈，下一次也一起看。")]
        for (id,start,slot,body) in lines {talk.receive(event(id,start,body,slot))}
        for (id,name) in [("c1","合成说话人甲"),("c3","合成说话人乙"),("c4","合成说话人丙")] {talk.naming.setSpeaker(segment:id,name:name)}
        talk.markAllTranscriptParentsDirty();try talk.settleTranscriptForOfflineReview();talk.updateUI();talk.scroll.contentView.scroll(to:.zero)
        let target=talk.window.contentView!.superview!;target.layoutSubtreeIfNeeded()
        guard let bitmap=target.bitmapImageRepForCachingDisplay(in:target.bounds) else{throw Failure(code:"render_bitmap")}
        target.effectiveAppearance.performAsCurrentDrawingAppearance {target.cacheDisplay(in:target.bounds,to:bitmap)}
        try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("conversation.png"))
    }
    let timed=makeView();timed.receive(["type":"started","session":"timeline-fixture","absolute_clock":clock.absoluteClock()])
    clock.pause(at:110);clock.resume(at:710)
    timed.receive(["type":"recording_resumed","session":"timeline-fixture","absolute_clock":clock.absoluteClock()])
    timed.receive(event("absolute-late",15,"实际声音时间保持，不取转写返回时间。"))
    try timed.settleTranscriptForOfflineReview()
    // The header shows the actual clock time; the relative time stays in its tooltip.
    let timedTips=(0..<timed.output.string.utf16.count).lazy.compactMap{timed.output.textStorage!.attribute(.toolTip,at:$0,effectiveRange:nil) as? String}
    try check(timed.output.string.contains("00:10:05") && !timed.output.string.contains("00:15 · 00:10:05") && timedTips.contains(where:{$0.contains("00:15 · 00:10:05")}),"actual_absolute_and_relative_times_in_native_body")
    try check(timed.transcriptExport().contains("2026-10-06T00:10:05.000+08:00") && timed.transcriptExport().contains("Asia/Shanghai"),"export_preserves_date_timezone_and_pause_gap")
    let absolutePartial=event("absolute-partial",16,"未完成声音")
    var noEnd=absolutePartial;noEnd["end_time_known"]=false;noEnd["final"]=false;timed.receive(noEnd);try timed.settleTranscriptForOfflineReview()
    try check(timed.transcriptExport().contains("时间待确认"),"unknown_end_time_is_not_invented")
    timed.phase.phase = .stopped;timed.newMeeting()
    try check(timed.absoluteTime==nil,"new_meeting_clears_previous_absolute_time")
    let early=event("early",105.87,"这是一句应出现在前面的合成发言。")
    var late=event("late",160.37,"请把这句话完整保留下来。",0)
    view.receive(late);view.receive(early)
    try check(view.sequence==["early","late"],"late_delivery_sorted_by_capture_time")
    view.naming.register(segment:"late",item:late);view.naming.setSpeaker(segment:"late",name:"测试人物甲")
    late["revision"]=2;late["speaker"]=["basis":"unknown","reason":"coverage_gap"]
    late["speaker_runs"]=[
        ["start":160.37,"end":164.1,"text":"请把这句话完整保留","speaker":speaker(0)],
        ["start":164.1,"end":164.37,"text":"下来。","speaker":["basis":"unknown","reason":"coverage_gap"]]]
    view.receive(late)
    try check(view.sequence==["early","late"] && view.segments.count==2,"speaker_updates_never_split_or_reappend_sentences")
    try check(view.naming.name(segment:"late")=="测试人物甲" && view.spokenRows("late",late).map{$0.1["text"] as? String ?? ""}.joined()==late["text"] as? String,"confirmed_name_and_complete_sentence_survive_annotation")
    try check(view.speakerDetails("late",late).count==2,"uncertain_tail_retained_as_separate_evidence")
    var stale=late;stale["revision"]=1;stale["text"]="不能覆盖的新旧冲突";view.receive(stale)
    var regression=late;regression["revision"]=3;regression["final"]=false;view.receive(regression)
    try check(view.segments["late"]?["revision"] as? Int==2 && view.segments["late"]?["final"] as? Bool==true,"stale_and_final_to_partial_regressions_rejected")
    var conflict=late;conflict["text"]="同版本冲突";view.receive(conflict)
    try check(view.segments["late"]?["text"] as? String==late["text"] as? String,"same_revision_cannot_change_text")
    var changed=late;changed["revision"]=3;changed["speaker_runs"] = nil;changed["speaker"]=speaker(1);view.receive(changed)
    try check(view.naming.name(segment:"late")=="测试人物甲","human_binding_survives_different_model_slot")
    let names=try view.naming.snapshot(session:"timeline-fixture")
    let reopened=makeView();reopened.receive(early);reopened.receive(changed);try reopened.naming.restore(names,session:"timeline-fixture");reopened.renderText()
    try check(reopened.naming.name(segment:"late")=="测试人物甲","human_binding_persists_across_reload")
    view.receive(event("replayed",90,"将被重放替换的合成结果"));view.receive(["type":"asr_replay","discard_segment_ids":["replayed"]]);view.receive(event("replayed",90,"迟到的旧分人更新",1,2))
    try check(view.segments["replayed"]==nil,"replay_tombstone_prevents_old_annotation_resurrection")
    view.activeSession="timeline-fixture";view.receive(["type":"segment","session":"old-session","segment_id":"foreign","text":"上场迟到的内容","revision":1,"final":true])
    try check(view.segments["foreign"]==nil,"late_event_from_another_session_ignored")
    var partial=event("partial",170,"尚未结束的合成句子");partial["final"]=false;view.receive(partial)
    partial["final"]=true;partial["revision"]=2;view.receive(partial)
    try check(!view.output.string.contains("正在转写") && view.segments["partial"]?["final"] as? Bool==true,"partial_final_presentation_updates")
    let dual=event("dual",175,"第一位说完，第二位接着说。",nil)
    var split=dual;split["speaker_runs"]=[["start":175.0,"end":177.0,"text":"第一位说完，","speaker":speaker(0)],["start":177.0,"end":179.0,"text":"第二位接着说。","speaker":speaker(1)]]
    view.receive(split)
    let runID="dual:word:177000";view.beginInlineName(runID);view.inlineField!.stringValue="测试人物乙";view.inlineScope!.selectItem(at:0);view.commitInlineName()
    try check(view.segments["dual"] != nil && view.output.string.contains("第一位说完，") && view.output.string.contains("第二位接着说。") && view.speakerDetails("dual",split).contains{$0.1.contains("测试人物乙")},"within_sentence_speaker_timeline_is_editable_without_fragmenting_text")
    let visibleRuns=view.spokenRows("dual",split)
    try check(visibleRuns.count==2 && view.incrementalTranscript.allPartRanges()[runID] != nil && visibleRuns.map{$0.1["text"] as! String}.joined()==split["text"] as? String,"main_transcript_shows_turns_with_lossless_original")
    let turnExport=view.transcriptExport()
    try check(turnExport.contains("02:57.000") && turnExport.contains("第二位接着说。") && !turnExport.contains("人物时间线："),"export_shares_the_visible_speaker_turns")
    view.naming.set(segment:"dual",name:"人工整句确认");view.renderText()
    try check(view.spokenRows("dual",split).count==1 && view.output.string.contains("人工整句确认"),"explicit_whole_sentence_name_takes_precedence")
    view.undoName();try check(view.spokenRows("dual",split).count==2,"undo_whole_sentence_override_restores_speaker_turns")
    var overlap=split;overlap["segment_id"]="real-overlap";overlap["speaker"]=["basis":"multiple","reason":"overlap"];overlap["speaker_runs"]=[["start":175.0,"end":177.0,"text":"第一位说完，","speaker":speaker(0)],["start":177.0,"end":179.0,"text":"第二位接着说。","speaker":["basis":"multiple","reason":"overlap","cluster_ids":[0,1]]]]
    view.receive(overlap)
    let overlapRows=view.spokenRows("real-overlap",overlap)
    try check(overlapRows.count==2 && view.speakerLabel(overlapRows[0].0,overlapRows[0].1)=="测试人物甲" &&
              view.speakerLabel(overlapRows[1].0,overlapRows[1].1)=="测试人物甲、测试人物乙 · 同时发言" &&
              view.output.string.contains("测试人物甲、测试人物乙 · 同时发言"),"genuine_named_overlap_only_labels_its_own_turn")
    // A manual word-run correction survives a later model merge and reload.
    let anchored=makeView();var anchoredEvent=split;anchoredEvent["word_spans"]=[["start":175.0,"end":177.0,"text":"第一位说完，"],["start":177.0,"end":179.0,"text":"第二位接着说。"]]
    anchored.receive(anchoredEvent);anchored.naming.set(segment:runID,name:"已确认人物")
    var merged=anchoredEvent;merged["revision"]=2;merged.removeValue(forKey:"speaker_runs");merged["speaker"]=speaker(0);anchored.receive(merged)
    try check(anchored.spokenRows("dual",merged).count==2 && anchored.output.string.contains("已确认人物") && anchored.namingItem(runID)?["text"] as? String=="第二位接着说。","manual_turn_survives_model_merge_without_relabelling_surrounding_text")
    let anchoredNames=try anchored.naming.snapshot(session:"timeline-fixture");let anchorReload=makeView();anchorReload.receive(merged);try anchorReload.naming.restore(anchoredNames,session:"timeline-fixture");anchorReload.renderText()
    try check(anchorReload.output.string.contains("已确认人物") && anchorReload.transcriptExport().contains("已确认人物"),"anchored_turn_correction_persists_across_reload_and_export")
    anchored.undoName();try check(anchored.spokenRows("dual",merged).count==1,"undo_anchored_correction_returns_current_model_turn")
    var punctuation=anchoredEvent;punctuation["segment_id"]="punctuation";punctuation["text"]="内容。";punctuation["speaker_runs"]=[["start":175.0,"end":177.0,"text":"内容","speaker":speaker(0)],["start":177.0,"end":179.0,"text":"。","speaker":["basis":"multiple","reason":"overlap"]]]
    anchored.receive(punctuation);try check(anchored.spokenRows("punctuation",punctuation).count==1 && anchored.spokenRows("punctuation",punctuation)[0].1["text"] as? String=="内容。","punctuation_does_not_create_an_audible_speaker_turn")
    let collision=makeView();collision.receive(anchoredEvent);collision.naming.set(segment:"dual:word:175000",name:"只确认第一句");collision.receive(merged);collision.renderText()
    let collisionTurns=collision.readingTurns();try check(collisionTurns.count==2 && collision.speakerLabel(collisionTurns[0].id,collisionTurns[0].item)=="只确认第一句" && collision.speakerLabel(collisionTurns[1].id,collisionTurns[1].item) != "只确认第一句","expanded_run_start_collision_never_spreads_manual_name")
    let chronological=makeView();var remote=split;remote["segment_id"]="remote-cross";remote["start"]=0.0;remote["end"]=10.0;remote["text"]="前句。后句。";remote["speaker_runs"]=[["start":0.0,"end":2.0,"text":"前句。","speaker":speaker(0)],["start":8.0,"end":10.0,"text":"后句。","speaker":speaker(1)]]
    chronological.receive(remote);chronological.receive(event("between-tracks",4,"中间句。",0));try check(chronological.readingTurns().map{TranscriptTimeline.start($0.item)}==[0.0,4.0,8.0],"visible_turns_and_export_sorted_across_interleaved_sentences")
    let chronExport=chronological.transcriptExport();try check(chronExport.range(of:"前句。")!.lowerBound<chronExport.range(of:"中间句。")!.lowerBound && chronExport.range(of:"中间句。")!.lowerBound<chronExport.range(of:"后句。")!.lowerBound,"interleaved_export_preserves_turn_chronology")
    var malformed=split;malformed["revision"]=2;malformed["speaker_runs"]=[["start":175.0,"end":176.0,"text":"伪造内容","speaker":speaker(0)],["start":174.0,"end":179.0,"text":"错误范围","speaker":speaker(1)]];view.receive(malformed)
    try check(view.speakerDetails("dual",malformed).isEmpty && view.segments["dual"]?["text"] as? String==dual["text"] as? String,"invalid_optional_spans_never_damage_original")
    var activity=SourceActivity();activity.receive(["type":"capture_status","tracks":["mic":32000,"remote":32000]])
    try check(activity.label("remote")=="已收到音频，暂无文字","pcm_not_misrepresented_as_recognized_speech")
    activity.receive(early);try check(activity.label("mic")=="已有转写" && activity.label("remote") != activity.label("mic"),"track_statuses_independent")
    try check(view.sourceBundle=="*system*" && view.useMic,"new_session_captures_computer_and_microphone_by_default")
    view.sourceBundle="*microphone*";view.useMic=false;view.confirmedScope=true;view.prepareAutomaticCapture()
    try check(view.sourceBundle=="*system*" && view.useMic && !view.confirmedScope,"legacy_source_does_not_narrow_next_capture")
    view.phase.phase = .recording;view.sourceBundle="com.tencent.meeting";view.prepareAutomaticCapture()
    try check(view.sourceBundle=="com.tencent.meeting","active_or_recovered_capture_scope_is_not_mutated")
    view.phase.phase = .idle;view.prepareAutomaticCapture()
    try check(view.sheet.contentView!.subviews.compactMap{$0 as? NSPopUpButton}.allSatisfy{$0===view.recordingModePicker},"settings_has_no_source_picker")
    try check(view.historyButton?.superview != view.output.superview && ["history","search","export"].allSatisfy{identifier in view.window.toolbar!.items.contains{$0.itemIdentifier.rawValue==identifier}},"session_actions_in_window_toolbar")
    // Disk round trip contains revisions, out-of-order delivery and final result protection.
    let cacheRoot=directory.appendingPathComponent("sessions");let cache=cacheRoot.appendingPathComponent(UUID().uuidString)
    let journal=try RecordingJournal(directory:cache,track:"mic",freeSpace:{1_000_000_000})
    try journal.enqueue(Data(repeating:0,count:32000),at:1);journal.finish();journal.wait()
    for e in [late,early,stale,conflict,regression,event("retired",80,"重放前的旧结果"),["type":"asr_replay","discard_segment_ids":["retired"]],event("retired",80,"重放后迟到的旧结果",0,2)] {journal.record(e)};journal.wait();try journal.commit("asr",cursor:journal.bytes());journal.wait()
    try JSONSerialization.data(withJSONObject:["session":"timeline-fixture","bundle":"*system*"]).write(to:cache.appendingPathComponent("meeting.json"))
    try view.naming.snapshot(session:"timeline-fixture").write(to:cache.appendingPathComponent("session-names.json"))
    let cached=try cachedMeetings(in:cacheRoot).first!
    let historical=makeView();try historical.importRecovery(cached)
    try check(historical.sequence==["early","late"] && historical.segments["late"]?["revision"] as? Int==2,"journal_reload_matches_live_revision_rules_and_order")
    try check(historical.cachedTranscriptionComplete,"export_preserves_audio_even_when_transcription_complete")
    historical.recoveryRootOverride=cacheRoot
    historical.beginInlineName("late");historical.inlineField!.stringValue="测试人物丙";historical.inlineScope!.selectItem(at:0);historical.commitInlineName();historical.cacheWriteQueue.sync{}
    let namedReload=makeView();try namedReload.importRecovery(cached)
    try check(namedReload.naming.name(segment:"late")=="测试人物丙","post_stop_name_edit_saved_by_actual_UI_handler")
    let raw=try Data(contentsOf:cache.appendingPathComponent("mic-000000.pcm"))
    let export=directory.appendingPathComponent("synthetic-export.txt");try historical.saveTranscript(to:export)
    historical.saveTranscriptAsync(to:export);waitQAIO(historical)
    try check(try! Data(contentsOf:cache.appendingPathComponent("mic-000000.pcm"))==raw,"sync_and_async_exports_preserve_raw_audio")
    let exported=try String(contentsOf:export,encoding:.utf8)
    try check(exported.contains("请把这句话完整保留") && exported.contains("下来。") && exported.range(of:"01:45.870")!.lowerBound<exported.range(of:"02:40.370")!.lowerBound && !exported.contains(" · mic · "),"export_keeps_chronology_whole_text_and_readable_labels")
    // The development UI and helper share the same isolated fixture cache.
    let qa=makeView();let fixture=try qa.makeQACache(complete:false);try qa.importRecovery(fixture)
    qa.qaRecoveryMode="normal";qa.phase.phase = .stopping;qa.processingAudio=true;qa.resumeBusy=true;qa.startQARecovery(fixture)
    let deadline=Date().addingTimeInterval(15)
    while qa.child != nil && Date()<deadline {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}
    try check(qa.child==nil && qa.cachedTranscriptionComplete && qa.phase.phase == .stopped && !qa.segments.isEmpty,"native_helper_fake_resume_uses_same_development_cache")
    // Full history stays visible, including when an older result arrives while reading.
    view.newMeeting();view.phase.phase = .recording;view.sessionSource="合成会议 · 电脑声音与麦克风"
    view.deferPresentation=true
    for i in 0..<225 {view.receive(event("long-\(i)",Double(i)*5,"第\(i)段合成原文。这里检查长句自动换行、人物时间线和阅读位置，窗口缩小时不应需要横向拖动。",i%2))}
    view.deferPresentation=false;view.renderText();try view.settleTranscriptForOfflineReview();view.updateUI()
    try check(view.textRanges.count==225 && view.output.string.contains("第0段") && view.output.string.contains("第224段"),"entire_retained_transcript_visible_without_200_row_cutoff")
    view.window.setContentSize(NSSize(width:640,height:480));view.window.contentView!.layoutSubtreeIfNeeded();view.resizeTranscript();view.renderText()
    try check(abs(view.output.frame.width-view.scroll.contentSize.width)<1 && !view.scroll.hasHorizontalScroller,"compact_window_text_width_tracks_viewport")
    let anchorID="long-100",range=view.textRanges[anchorID]!,layout=view.output.layoutManager!,container=view.output.textContainer!
    func rect(_ range:NSRange)->NSRect {layout.boundingRect(forGlyphRange:layout.glyphRange(forCharacterRange:NSRange(location:range.location,length:1),actualCharacterRange:nil),in:container)}
    let y=rect(range).minY+view.output.textContainerInset.height
    view.scroll.contentView.scroll(to:NSPoint(x:0,y:y));view.output.setSelectedRange(NSRange(location:range.location,length:5))
    view.receive(event("insert-early",2,"这是迟到的前文。"))
    let shifted=rect(view.textRanges[anchorID]!).minY+view.output.textContainerInset.height
    try check(abs(view.scroll.contentView.bounds.minY-shifted)<3 && view.output.selectedRange().location==view.textRanges[anchorID]!.location,"reading_anchor_and_selection_survive_earlier_insertion")
    view.markAllTranscriptParentsDirty();try view.settleTranscriptForOfflineReview()
    let refreshedY=rect(view.textRanges[anchorID]!).minY+view.output.textContainerInset.height
    try check(abs(view.scroll.contentView.bounds.minY-refreshedY)<3 && view.output.selectedRange()==NSRange(location:view.textRanges[anchorID]!.location,length:5),"full_refresh_preserves_reading_anchor_and_selected_characters")
    // A new selection/navigation supersedes the deferred AppKit restoration.
    view.restoreAfterTranscriptEdit(view.captureTranscriptReadingPosition())
    let otherID="long-110",otherRange=view.textRanges[otherID]!
    view.output.setSelectedRange(NSRange(location:otherRange.location,length:5))
    view.receive(event("long-224",1120,"最后一轮修订仍需保留读者的新选择。",0,2))
    try check(view.output.selectedRange()==NSRange(location:view.textRanges[otherID]!.location,length:5),"new_selection_survives_update_during_deferred_restore")
    view.restoreAfterTranscriptEdit(view.captureTranscriptReadingPosition())
    (view.scroll as? MeetingTranscriptScroll)?.manualScroll?()
    view.scroll.contentView.scroll(to:NSPoint(x:0,y:0))
    let navigationDeadline=Date().addingTimeInterval(0.03)
    while Date()<navigationDeadline {_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))}
    try check(view.pendingTranscriptReadingPosition==nil && view.scroll.contentView.bounds.minY<1,"manual_navigation_cancels_deferred_restore")
    // Unnamed manual reassignment must update the visible label as well as its binding.
    let assignment=makeView();assignment.receive(event("one",1,"第一段",0));assignment.receive(event("two",8,"第二段",1))
    let target=assignment.naming.key(segment:"two")!
    try check(assignment.naming.assign(segment:"one",to:target,humanConfirmed:true) && assignment.speakerLabel("one",assignment.segments["one"]!)=="发言人 2","unnamed_manual_assignment_updates_visible_person")
    // A normal-product menu must not expose disabled development identity workflows.
    let wasMock=view.mock;view.mock=false;view.humanIdentityAuthorized=false;view.installMenus()
    let productActions=NSApp.mainMenu?.items.flatMap{$0.submenu?.items ?? []}.compactMap{$0.action} ?? []
    try check(!productActions.contains(#selector(Delegate.enrollSegment)) && !productActions.contains(#selector(Delegate.calibrateIdentity)) && productActions.contains(#selector(Delegate.nameVisibleSegment)),"product_menu_keeps_naming_without_unavailable_identity_setup")
    view.mock=wasMock;view.installMenus()
    // Offscreen product views, not desktop capture.
    var images:[String]=[]
    view.phase.phase = .stopped;view.newMeeting();view.phase.phase = .recording;view.source.stringValue="合成会议 · 人物时间线预览";view.receive(early);view.receive(late);view.receive(split);view.output.setSelectedRange(NSRange(location:0,length:0));view.scroll.contentView.scroll(to:.zero);view.diagnostic.stringValue="合成示例 · 原文按时间排列，人物范围可点击纠正"
    for (name,size,appearance) in [("standard",NSSize(width:800,height:620),NSAppearance.Name.aqua),("compact",NSSize(width:640,height:480),NSAppearance.Name.aqua),("dark",NSSize(width:800,height:620),NSAppearance.Name.darkAqua)] {
        NSApp.appearance=NSAppearance(named:appearance)
        let preview=makeView();preview.window.appearance=NSApp.appearance;preview.window.setContentSize(size)
        preview.timeline=view.timeline;preview.naming=view.naming;preview.phase=view.phase;preview.source.stringValue=view.source.stringValue;preview.diagnostic.stringValue=view.diagnostic.stringValue
        let settle=Date().addingTimeInterval(0.15)
        while Date()<settle {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}
        preview.window.contentView!.layoutSubtreeIfNeeded();preview.resizeTranscript();preview.renderText();try preview.settleTranscriptForOfflineReview();preview.updateUI();preview.scroll.contentView.scroll(to:.zero)
        let target=preview.window.contentView!.superview!;target.layoutSubtreeIfNeeded()
        guard let bitmap=target.bitmapImageRepForCachingDisplay(in:target.bounds) else{throw Failure(code:"render_bitmap")}
        target.effectiveAppearance.performAsCurrentDrawingAppearance {target.cacheDisplay(in:target.bounds,to:bitmap)}
        let image=NSImage(size:target.bounds.size);image.lockFocus()
        target.effectiveAppearance.performAsCurrentDrawingAppearance {NSColor.windowBackgroundColor.setFill();NSBezierPath(rect:NSRect(origin:.zero,size:target.bounds.size)).fill();bitmap.draw(in:NSRect(origin:.zero,size:target.bounds.size))}
        image.unlockFocus()
        let opaque=NSBitmapImageRep(data:image.tiffRepresentation!)!
        let file=directory.appendingPathComponent(name+".png");try opaque.representation(using:.png,properties:[:])!.write(to:file);images.append(file.path)
    }
    NSApp.appearance=NSAppearance(named:.aqua)
    // Start has no app modal; mode choices remain in Settings.
    let settingsView=view.sheet.contentView!;settingsView.layoutSubtreeIfNeeded()
    if let bitmap=settingsView.bitmapImageRepForCachingDisplay(in:settingsView.bounds) {
        settingsView.effectiveAppearance.performAsCurrentDrawingAppearance {settingsView.cacheDisplay(in:settingsView.bounds,to:bitmap)}
        let file=directory.appendingPathComponent("recording-mode-settings.png")
        try bitmap.representation(using:.png,properties:[:])!.write(to:file);images.append(file.path)
    }
    return ["type":"realtime_timeline_checks","passed":checks.count,"checks":checks,"images":images,"export":export.path,"capture":false,"network":false,"keychain":false,"offscreen":true,"real_audio_quality_verified":false]
}


func speakerReconciliationChecks(directory:URL)throws->Int {
    let folder=directory.appendingPathComponent("reconciliation-fixture")
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let key=SessionSpeakerKey(session:"fixture",source:"remote",epoch:"remote-epoch",identity:"slot:0")
    let keyObject=try JSONSerialization.jsonObject(with:JSONEncoder().encode(key)) as! [String:Any]
    try JSONSerialization.data(withJSONObject:["session":"fixture","speakers":[["key":keyObject,"name":"合成人物"]]]).write(to:folder.appendingPathComponent("session-names.json"))
    let original:[String:Any]=["type":"segment","segment_id":"utterance","session":"fixture","source_id":"mic","epoch":"mic-epoch","revision":3,"final":true,"end_time_known":true,"start":1.0,"end":3.0,"text":"保留原文","speaker":["basis":"unknown"]]
    let corrected:[String:Any]=["basis":"meeting_reconciliation","identity_key":keyObject,"source_id":"mic","epoch":"mic-epoch"]
    let hashes=["mic-transcript.jsonl":String(repeating:"a",count:64)]
    var object:[String:Any]=["schema":1,"cache_id":"fixture-cache","session":"fixture","source_sha256":hashes,"model_sha256":SpeakerEmbeddingBackend.modelHash,"roster":[keyObject],"records":[["segment_id":"utterance","revision":3,"text_sha256":MeetingSpeakerReconciliation.hash(Data("保留原文".utf8)),"start":1.0,"end":3.0,"speaker":corrected,"speaker_runs":[["start":1.0,"end":3.0,"text":"保留原文","speaker":corrected]]]]]
    let path=folder.appendingPathComponent("speaker-reconciliation.json")
    func save()throws{try JSONSerialization.data(withJSONObject:object).write(to:path)}
    func read()->[[String:Any]]{MeetingSpeakerReconciliation.apply(in:folder,cacheID:"fixture-cache",events:[original],sourceHashes:hashes)}
    var passed=0
    try save();let result=read()
    precondition(SessionSpeakerKey.from(result[0])==key && result[0]["source_id"] as? String=="mic" && result[0]["text"] as? String=="保留原文" && result[0]["revision"] as? Int==3);passed+=1
    var names=SessionNames();names.register(segment:"utterance",item:original);names.set(segment:"utterance",name:"人工原名");names.register(segment:"utterance",item:result[0]);precondition(names.name(segment:"utterance")=="人工原名");passed+=1
    let sourceBefore=try JSONSerialization.data(withJSONObject:original,options:.sortedKeys)
    object["source_sha256"]=["mic-transcript.jsonl":String(repeating:"b",count:64)];try save()
    precondition(read()[0]["speaker_reconciliation_warning"] is String && SessionSpeakerKey.from(read()[0])==nil);passed+=1
    object["source_sha256"]=hashes;object["cache_id"]="other";try save();precondition(SessionSpeakerKey.from(read()[0])==nil);passed+=1
    object["cache_id"]="fixture-cache";object["model_sha256"]="unverified-model";try save();precondition(SessionSpeakerKey.from(read()[0])==nil);passed+=1
    object["model_sha256"]=SpeakerEmbeddingBackend.modelHash
    var records=object["records"] as! [[String:Any]];var bad=records[0];bad["speaker_runs"]=[["start":1.0,"end":3.0,"text":"删除原文","speaker":corrected]];object["records"]=[bad];try save();precondition(SessionSpeakerKey.from(read()[0])==nil);passed+=1
    bad=records[0];bad["revision"]=4;object["records"]=[bad];try save();precondition(SessionSpeakerKey.from(read()[0])==nil);passed+=1
    object["records"]=records;object["roster"]=[];try save();precondition(SessionSpeakerKey.from(read()[0])==nil);passed+=1
    let sourceAfter=try JSONSerialization.data(withJSONObject:original,options:.sortedKeys)
    precondition(sourceAfter==sourceBefore);passed+=1
    // Timed-word repairs use the local diarization model; never pretend that
    // an embedding was extracted. Bind the exact model and original provenance.
    object["roster"]=[keyObject];object["records"]=records
    object["model_kind"]="nemotron3-low";object["method"]="timed_word_context_v1"
    object["model_sha256"]=MeetingSpeakerReconciliation.diarizationModelHash
    try save()
    precondition(read()[0]["speaker_reconciliation_warning"] is String);passed+=1
    var diarized=original;diarized["local_speaker_model"]=MeetingSpeakerReconciliation.diarizationDescriptor
    let recovered=MeetingSpeakerReconciliation.apply(in:folder,cacheID:"fixture-cache",events:[diarized],sourceHashes:hashes)
    precondition(SessionSpeakerKey.from(recovered[0])==key && recovered[0]["text"] as? String=="保留原文");passed+=1
    object["model_kind"]="unverified-model";try save()
    precondition(MeetingSpeakerReconciliation.apply(in:folder,cacheID:"fixture-cache",events:[diarized],sourceHashes:hashes)[0]["speaker_reconciliation_warning"] is String);passed+=1
    object["model_kind"]="nemotron3-low";object["model_sha256"]=SpeakerEmbeddingBackend.modelHash;try save()
    precondition(MeetingSpeakerReconciliation.apply(in:folder,cacheID:"fixture-cache",events:[diarized],sourceHashes:hashes)[0]["speaker_reconciliation_warning"] is String);passed+=1
    object["model_sha256"]=MeetingSpeakerReconciliation.diarizationModelHash;object["method"]="unknown-method";try save()
    precondition(MeetingSpeakerReconciliation.apply(in:folder,cacheID:"fixture-cache",events:[diarized],sourceHashes:hashes)[0]["speaker_reconciliation_warning"] is String);passed+=1
    return passed
}
