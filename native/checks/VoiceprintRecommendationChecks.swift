import AppKit

@MainActor func voiceprintRecommendationChecks(directory:URL) async throws->[String:Any] {
    guard Credential.offline,directory.path.contains("/.runtime/") else{throw Failure(code:"voiceprint_fixture_scope")}
    let previousPolicy=UserDefaults.standard.object(forKey:VoiceprintLearningPolicy.preferenceKey)
    VoiceprintLearningPolicy().setEnabled(true)
    defer {if let previousPolicy {UserDefaults.standard.set(previousPolicy,forKey:VoiceprintLearningPolicy.preferenceKey)}else{UserDefaults.standard.removeObject(forKey:VoiceprintLearningPolicy.preferenceKey)}}
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    var checks=try voiceprintMixedGroupChecks()
    checks+=try voiceprintAutomaticLearningChecks()
    checks+=try voiceprintGroupCentroidChecks()
    func check(_ ok:Bool,_ name:String)throws {guard ok else{throw Failure(code:name)};checks.append(name)}
    func vector(_ position:Int)->[Double] {var v=[Double](repeating:0,count:192);v[position]=1;return v}
    let people=(0..<3).map{i in VoiceprintPerson(id:UUID().uuidString,name:["测试甲方","测试乙方","测试Bob"][i],authorizedAt:"2026-10-05T12:00:00Z",enabled:true,samples:(0..<3).map{j in VoiceprintSample(session:"past",source:"remote",epoch:"past-epoch",start:Double(j*5),end:Double(j*5+2),vector:vector(i))})}
    let archive=VoiceprintArchive(schema:1,partition:SpeakerEmbeddingBackend.partition,inputKind:"synthetic_model_output",revision:1,people:people)
    _ = try archive.validated(domain:"synthetic_model_output")
    let key=SessionSpeakerKey(session:"voice-fixture",source:"mic",epoch:"live-epoch",identity:"slot:0")
    func event(_ i:Int,_ values:[Double]?=nil)->[String:Any] {
        let start=Double(i*5)
        return ["type":"segment","session":key.session,"segment_id":"voice-\(i)","revision":1,"source_id":"mic","track":"mic","epoch":key.epoch,"start":start,"end":start+4,"end_time_known":true,"final":true,"text":"这是第\(i)段完整发言。","speaker":["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":key.epoch],"identity_features":["partition":archive.partition,"input_kind":archive.inputKind,"source_id":"mic","epoch":key.epoch,"quality_gate":"single_model_slot_asr_final_unclipped","evidence_start":start,"evidence_end":start+2,"values":values ?? vector(0)]]
    }
    var matcher=VoiceprintMatcher(archive:archive);matcher.reset(session:key.session)
    _ = matcher.observe(event(0),domain:archive.inputKind);_ = matcher.observe(event(1),domain:archive.inputKind)
    try check(matcher.recommendation(key)==nil,"two_examples_do_not_recommend")
    _ = matcher.observe(event(2),domain:archive.inputKind)
    try check(matcher.recommendation(key)?.personID==people[0].id,"three_independent_examples_recommend")
    let accepted=matcher.recommendation(key)!
    var names=SessionNames()
    for i in 0..<3 {names.register(segment:"voice-\(i)",item:event(i))}
    try check(names.reconcileAutoVoiceprint(key:key,candidate:accepted) && names.name(speaker:key)==nil && names.displayName(speaker:key)?.origin == .voiceprint,"qualified_evidence_sets_only_an_automatic_display_name")
    var mixedMatcher=matcher,mixedNames=names
    let outsideVoice=event(3,vector(4));mixedNames.register(segment:"voice-3",item:outsideVoice)
    _ = mixedMatcher.observe(outsideVoice,domain:archive.inputKind)
    try check(mixedNames.reconcileAutoVoiceprint(key:key,candidate:mixedMatcher.recommendation(key),conflictingEvidence:mixedMatcher.conflictingEvidence(key)) && mixedNames.displayName(speaker:key)==nil && !mixedNames.autoNameIsSuppressed(key),"out_of_library_voice_temporarily_withdraws_display_name")
    var correctedVoice=event(3);correctedVoice["revision"]=2
    mixedNames.register(segment:"voice-3",item:correctedVoice);_ = mixedMatcher.observe(correctedVoice,domain:archive.inputKind)
    try check(mixedNames.reconcileAutoVoiceprint(key:key,candidate:mixedMatcher.recommendation(key),conflictingEvidence:mixedMatcher.conflictingEvidence(key)) && mixedNames.displayName(speaker:key)?.value==people[0].name && !mixedNames.autoNameIsSuppressed(key),"corrected_library_unknown_voice_restores_display_without_manual_reset")
    var batchNames=names
    var other=event(9);other["segment_id"]="voice-other";other["speaker"]=["basis":"anonymous_cluster","cluster_id":1,"source_id":"mic","epoch":key.epoch]
    batchNames.register(segment:"voice-other",item:other)
    let beforeBatchRevision=batchNames.correctionRevision
    try check(batchNames.assignBatch(segmentIDs:["voice-0","voice-1"],to:batchNames.key(segment:"voice-other")!,humanConfirmed:true) && batchNames.correctionRevision==beforeBatchRevision+1 && batchNames.displayName(speaker:key)==nil && batchNames.autoNameIsSuppressed(key),"manual_batch_with_automatic_name_advances_one_revision")
    let savedNames=try names.snapshot(session:key.session)
    try check(!String(decoding:savedNames,as:UTF8.self).contains("identity_features"),"saved_automatic_name_contains_no_voice_vector")
    var restoredNames=SessionNames()
    for i in 0..<3 {restoredNames.register(segment:"voice-\(i)",item:event(i))}
    try restoredNames.restore(savedNames,session:key.session)
    try check(restoredNames.displayName(speaker:key)?.value==people[0].name && restoredNames.name(speaker:key)==nil && !restoredNames.restoredAutoNameInvalidated,"automatic_name_survives_history_restore_without_becoming_manual")
    var staleNames=SessionNames();for i in 0..<3 {var row=event(i);if i==0 {row["revision"]=2};staleNames.register(segment:"voice-\(i)",item:row)}
    try staleNames.restore(savedNames,session:key.session)
    try check(staleNames.displayName(speaker:key)==nil && !staleNames.autoNameIsSuppressed(key) && staleNames.restoredAutoNameInvalidated,"stale_saved_evidence_is_withdrawn")
    var legacy=try JSONSerialization.jsonObject(with:savedNames) as! [String:Any]
    legacy["schema"]=1;legacy.removeValue(forKey:"autoNames");legacy.removeValue(forKey:"autoSuppressed")
    let legacyData=try JSONSerialization.data(withJSONObject:legacy)
    var legacyNames=SessionNames();for i in 0..<3 {legacyNames.register(segment:"voice-\(i)",item:event(i))};try legacyNames.restore(legacyData,session:key.session)
    try check(legacyNames.displayName(speaker:key)==nil && !legacyNames.autoNameIsSuppressed(key),"schema_one_history_still_restores")
    var manualNames=names
    try check(manualNames.renameSpeaker(key:key,name:"人工确认") && manualNames.name(speaker:key)=="人工确认" && manualNames.displayName(speaker:key)?.origin == .manual,"human_name_overrides_automatic_name")
    _ = manualNames.undo()
    try check(manualNames.displayName(speaker:key)==nil && manualNames.autoNameIsSuppressed(key) && !manualNames.reconcileAutoVoiceprint(key:key,candidate:accepted),"undo_does_not_reapply_rejected_automatic_name")
    var revokedNames=names
    try check(revokedNames.dismissAutoName(key) && revokedNames.displayName(speaker:key)==nil && !revokedNames.reconcileAutoVoiceprint(key:key,candidate:accepted),"explicit_revoke_stays_silent_this_meeting")
    for _ in 0..<12 {_ = matcher.observe(event(2),domain:archive.inputKind)}
    try check(matcher.retainedEvidenceCount==3,"revisions_do_not_count_as_independent_audio")
    var duplicate=event(2);duplicate["segment_id"]="same-audio-another-id";_ = matcher.observe(duplicate,domain:archive.inputKind)
    try check(matcher.retainedEvidenceCount==3,"overlapping_audio_is_not_new_evidence")
    _ = matcher.observe(event(3,vector(1)),domain:archive.inputKind)
    try check(matcher.recommendation(key)==nil,"conflicting_clear_voice_withholds_group")
    try check(names.reconcileAutoVoiceprint(key:key,candidate:matcher.recommendation(key),conflictingEvidence:matcher.conflictingEvidence(key)) && names.displayName(speaker:key)==nil && names.autoNameIsSuppressed(key),"new_acoustic_conflict_withdraws_existing_automatic_name")
    matcher.remove("voice-3");try check(matcher.recommendation(key) != nil,"discarded_evidence_recomputes_group")
    try check(!names.reconcileAutoVoiceprint(key:key,candidate:matcher.recommendation(key)) && names.displayName(speaker:key)==nil,"withdrawn_name_does_not_reappear_after_conflict")
    var invalid=event(2);invalid["speaker"]=["basis":"multiple","reason":"overlap"];_ = matcher.observe(invalid,domain:archive.inputKind)
    try check(matcher.recommendation(key)==nil,"overlap_revision_retracts_old_recommendation")
    _ = matcher.observe(event(2),domain:archive.inputKind);matcher.dismiss(key)
    try check(matcher.recommendation(key)==nil,"rejection_remains_silent_for_this_group")
    matcher.reset(session:"next");try check(matcher.retainedEvidenceCount==0 && matcher.recommendation(key)==nil,"new_meeting_resets_evidence_and_rejections")
    let secondKey=SessionSpeakerKey(session:"second-meeting",source:"mic",epoch:"second-epoch",identity:"slot:7")
    matcher.reset(session:secondKey.session)
    for i in 0..<3 {
        var second=event(i,vector(2));second["session"]=secondKey.session;second["epoch"]=secondKey.epoch
        second["speaker"]=["basis":"anonymous_cluster","cluster_id":7,"source_id":"mic","epoch":secondKey.epoch]
        var feature=second["identity_features"] as! [String:Any];feature["epoch"]=secondKey.epoch;second["identity_features"]=feature
        _=matcher.observe(second,domain:archive.inputKind)
    }
    try check(matcher.recommendation(secondKey)?.personID==people[2].id && matcher.recommendation(key)==nil,"same_registered_person_recognized_in_new_session_with_different_slot")
    try check(matcher.archive?.revision==archive.revision,"cross_session_matching_does_not_enroll_or_modify_archive")
    matcher.reset(session:key.session)
    for i in 0..<3 {_ = matcher.observe(event(i,vector(4)),domain:archive.inputKind)}
    try check(matcher.recommendation(key)==nil,"unknown_voice_is_not_forced_into_known_people")
    var ambiguous=vector(0);ambiguous[0]=sqrt(0.5);ambiguous[1]=sqrt(0.5)
    matcher.reset(session:key.session);for i in 0..<3 {_ = matcher.observe(event(i,ambiguous),domain:archive.inputKind)}
    try check(matcher.recommendation(key)==nil,"similar_two_people_withholds_name")
    try check(VoiceprintEvidence.from(event(0),domain:"consented_live_audio")==nil,"synthetic_and_real_voice_domains_are_isolated")
    var short=event(0);var f=short["identity_features"] as! [String:Any];f["evidence_end"]=0.2;short["identity_features"]=f
    try check(VoiceprintEvidence.from(short,domain:archive.inputKind)==nil,"short_voice_does_not_support_recommendation")
    var poor=event(0);poor["quality_flags"]=["unreliable"]
    try check(VoiceprintEvidence.from(poor,domain:archive.inputKind)==nil,"low_quality_asr_is_not_voice_evidence")
    let store=VoiceprintArchiveStore(folder:directory.appendingPathComponent("voices"),domain:archive.inputKind)
    try store.save(archive);let loaded=try store.load()!
    try check(loaded.people.count==3 && loaded.partition==archive.partition,"archive_reopens_after_app_exit")
    try check((try FileManager.default.attributesOfItem(atPath:store.file.path)[.posixPermissions] as? NSNumber)?.intValue==0o600,"feature_file_is_owner_only")
    do {_ = try archive.validated(domain:"consented_live_audio");throw Failure(code:"accepted_wrong_domain")}catch ProfileStoreError.invalid{checks.append("wrong_archive_domain_rejected")}
    var disabled=loaded;disabled.people[0].enabled=false;disabled.revision+=1;try store.save(disabled)
    matcher.archive=try store.load();matcher.reset(session:key.session);for i in 0..<3 {_ = matcher.observe(event(i),domain:archive.inputKind)}
    try check(matcher.recommendation(key)==nil,"disabled_voice_is_not_recommended_after_restart")
    matcher.reset(session:key.session);for i in 0..<3 {_ = matcher.observe(event(i,ambiguous),domain:archive.inputKind)}
    try check(matcher.recommendation(key)==nil,"disabling_one_voice_does_not_force_a_similar_other_name")
    try store.save(archive)
    let cacheRoot=directory.appendingPathComponent("session-cache")
    let cacheID=UUID().uuidString
    try FileManager.default.createDirectory(at:cacheRoot.appendingPathComponent(cacheID),withIntermediateDirectories:true)
    let namesFile=cacheRoot.appendingPathComponent(cacheID).appendingPathComponent("session-names.json")
    let view=Delegate();view.previewRenderOnly=true;view.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));view.voiceprintService=VoiceprintRecommendationService(store:store);view.recoveryRootOverride=cacheRoot
    let historicalReader=Delegate();historicalReader.workspaceOwner=view;historicalReader.previewRenderOnly=true
    try check(historicalReader.voiceprintManagementOwner.voiceprintService === view.voiceprintService,"historical_reader_manages_primary_voice_archive")
    // Exercise the actual stdout JSONL drain, which holds deferPresentation
    // while it dispatches a batch. Calling receive() directly misses that gate.
    var jsonl=Data()
    for row in [["type":"started","session":key.session,"cache_id":cacheID] as [String:Any]]+(0..<3).map({event($0)}) {
        jsonl.append(try JSONSerialization.data(withJSONObject:row));jsonl.append(10)
    }
    view.readLock.lock();view.pending.append(jsonl);view.readLock.unlock();view.drain()
    for _ in 0..<100 {if view.naming.displayName(speaker:key)?.origin == .voiceprint {break};try await Task.sleep(nanoseconds:10_000_000)}
    try view.settleTranscriptForOfflineReview()
    try check(view.sequence.count==3 && view.naming.displayName(speaker:key)?.origin == .voiceprint,"stdout_jsonl_drain_triggers_automatic_name")
    try check(view.output.string.contains("测试甲方"),"native_live_header_marks_automatic_name")
    try check(view.naming.name(speaker:key)==nil && view.naming.displayName(speaker:key)?.origin == .voiceprint && view.transcriptExport().contains("测试甲方"),"automatic_name_exports_with_provenance_without_manual_confirmation")
    view.cacheWriteQueue.sync{}
    try check(FileManager.default.fileExists(atPath:namesFile.path) && String(decoding:try Data(contentsOf:namesFile),as:UTF8.self).contains("autoNames"),"automatic_name_is_saved_to_session_cache")
    let revisionCacheID=UUID().uuidString
    try FileManager.default.createDirectory(at:cacheRoot.appendingPathComponent(revisionCacheID),withIntermediateDirectories:true)
    let revisionNamesFile=cacheRoot.appendingPathComponent(revisionCacheID).appendingPathComponent("session-names.json")
    let revisionView=Delegate();revisionView.previewRenderOnly=true;revisionView.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));revisionView.voiceprintService=VoiceprintRecommendationService(store:store);revisionView.recoveryRootOverride=cacheRoot
    var revisionJSONL=Data()
    for row in [["type":"started","session":key.session,"cache_id":revisionCacheID] as [String:Any]]+(0..<3).map({event($0)}) {
        revisionJSONL.append(try JSONSerialization.data(withJSONObject:row));revisionJSONL.append(10)
    }
    revisionView.readLock.lock();revisionView.pending.append(revisionJSONL);revisionView.readLock.unlock();revisionView.drain()
    for _ in 0..<100 {if revisionView.naming.displayName(speaker:key)?.origin == .voiceprint {break};try await Task.sleep(nanoseconds:10_000_000)}
    try check(revisionView.naming.displayName(speaker:key)?.origin == .voiceprint,"revision_fixture_first_sets_automatic_name")
    var revised=event(0);revised["revision"]=2;revised.removeValue(forKey:"identity_features")
    var revisionLine=try JSONSerialization.data(withJSONObject:revised);revisionLine.append(10)
    revisionView.readLock.lock();revisionView.pending.append(revisionLine);revisionView.readLock.unlock();revisionView.drain()
    for _ in 0..<100 {if revisionView.naming.displayName(speaker:key)==nil {break};try await Task.sleep(nanoseconds:10_000_000)}
    try revisionView.settleTranscriptForOfflineReview()
    revisionView.cacheWriteQueue.sync{}
    var reopenedRevision=SessionNames()
    for i in 0..<3 {reopenedRevision.register(segment:"voice-\(i)",item:i==0 ? revised:event(i))}
    try reopenedRevision.restore(Data(contentsOf:revisionNamesFile),session:key.session)
    try check(revisionView.naming.displayName(speaker:key)==nil && !revisionView.output.string.contains("测试甲方") && !revisionView.transcriptExport().contains("测试甲方") && !reopenedRevision.autoNameIsSuppressed(key),"temporary_revision_withdraws_without_permanent_suppression")
    revised["revision"]=3;revised["identity_features"]=event(0)["identity_features"]
    revisionView.receive(revised)
    for _ in 0..<100 {if revisionView.naming.displayName(speaker:key)?.origin == .voiceprint {break};try await Task.sleep(nanoseconds:10_000_000)}
    try check(revisionView.naming.displayName(speaker:key)?.origin == .voiceprint,"voice_name_returns_when_temporary_evidence_recovers")
    var semantic=SessionNames()
    func intro(_ i:Int,_ text:String)->[String:Any] {var value=event(i);value["text"]=text;value.removeValue(forKey:"identity_features");return value}
    let firstIntro=intro(20,"大家好，我叫张三。"),secondIntro=intro(21,"我的名字是张三。")
    semantic.register(segment:"voice-20",item:firstIntro);_=semantic.observeSemanticName(firstIntro)
    try check(semantic.displayName(speaker:key)==nil,"one_self_introduction_is_not_a_name")
    for _ in 0..<4 {_=semantic.observeSemanticName(firstIntro)}
    try check(semantic.displayName(speaker:key)==nil,"intro_revisions_are_not_independent_confirmations")
    semantic.register(segment:"voice-21",item:secondIntro);_=semantic.observeSemanticName(secondIntro)
    try check(semantic.displayName(speaker:key)?.origin == .semantic && semantic.displayName(speaker:key)?.visibleValue=="张三" && semantic.name(speaker:key)==nil,"repeated_explicit_self_introduction_has_separate_provenance")
    for text in ["张三说他已经到家了。","张三你好。","他说我叫张三。","我不是张三。","我叫张三吗？","我是老师。","我叫他们来开会。","我叫张三。只是开玩笑。","他说：“我叫张三。”"] {
        try check(LocalSemanticNames.explicitIntroduction(text)==nil,"semantic_rejects_"+text)
    }
    let semanticSaved=try semantic.snapshot(session:key.session)
    var semanticRestored=SessionNames();semanticRestored.register(segment:"voice-20",item:firstIntro);semanticRestored.register(segment:"voice-21",item:secondIntro);try semanticRestored.restore(semanticSaved,session:key.session)
    try check(semanticRestored.displayName(speaker:key)?.origin == .semantic,"semantic_name_restores_with_its_evidence")
    var amended=secondIntro;amended["revision"]=2;amended["text"]="今天我们来讨论项目。"
    semanticRestored.register(segment:"voice-21",item:amended);_=semanticRestored.observeSemanticName(amended)
    try check(semanticRestored.displayName(speaker:key)==nil && !semanticRestored.autoNameIsSuppressed(key),"revised_introduction_withdraws_semantic_name")
    let conflicting=intro(22,"我叫李四。");semantic.register(segment:"voice-22",item:conflicting);_=semantic.observeSemanticName(conflicting)
    try check(semantic.displayName(speaker:key)==nil,"conflicting_self_introductions_never_choose_a_name")
    var overlapped=LocalSemanticNames();_=overlapped.observe(firstIntro)
    var sameAudio=firstIntro;sameAudio["segment_id"]="different-id";_=overlapped.observe(sameAudio)
    try check(overlapped.recommendation(key)==nil,"same_audio_cannot_confirm_a_semantic_name_twice")
    var otherSource=secondIntro;otherSource["source_id"]="remote";otherSource["speaker"]=["basis":"anonymous_cluster","cluster_id":0,"source_id":"remote","epoch":key.epoch]
    _=overlapped.observe(otherSource);try check(overlapped.recommendation(key)==nil,"semantic_names_do_not_merge_audio_sources")
    var manualSemantic=SessionNames();for e in [firstIntro,secondIntro] {manualSemantic.register(segment:e["segment_id"] as! String,item:e);_=manualSemantic.observeSemanticName(e)}
    _=manualSemantic.renameSpeaker(key:key,name:"人工姓名");_=manualSemantic.observeSemanticName(firstIntro)
    try check(manualSemantic.displayName(speaker:key)?.value=="人工姓名" && manualSemantic.displayName(speaker:key)?.origin == .manual,"manual_name_overrides_semantic_inference")
    _=manualSemantic.undo();_=manualSemantic.observeSemanticName(secondIntro)
    try check(manualSemantic.displayName(speaker:key)==nil,"manual_undo_does_not_reapply_semantic_inference")
    var learner=VoiceprintMatcher();learner.reset(session:key.session)
    for i in 0..<3 {_=learner.observe(event(i,vector(7)),domain:archive.inputKind)}
    let learnedSamples=learner.enrollmentSamples(key)
    let firstArchive=try archiveRememberingManualVoice(nil,name:"合成新人物",key:key,samples:learnedSamples,domain:archive.inputKind)!
    try check(firstArchive.people.count==1 && firstArchive.people[0].samples.count==3,"manual_name_and_three_clear_examples_create_reference")
    try check(try archiveRememberingManualVoice(firstArchive,name:"合成新人物",key:key,samples:learnedSamples,domain:archive.inputKind)==nil,"same_audio_is_not_enrolled_twice")
    var muted=firstArchive;muted.people[0].enabled=false
    try check(try archiveRememberingManualVoice(muted,name:"合成新人物",key:key,samples:learnedSamples,domain:archive.inputKind)==nil,"disabled_reference_is_never_reenabled_by_automatic_learning")
    var mixed=learner;_=mixed.observe(event(3,vector(6)),domain:archive.inputKind)
    try check(mixed.enrollmentSamples(key).isEmpty,"mixed_voice_group_cannot_train_a_reference")
    let changedCondition=learnedSamples.map{VoiceprintSample(session:"later-session",source:$0.source,epoch:"later-epoch",start:$0.start,end:$0.end,vector:vector(9))}
    let laterKey=SessionSpeakerKey(session:"later-session",source:key.source,epoch:"later-epoch",identity:key.identity)
    let augmented=try archiveRememberingManualVoice(firstArchive,name:"合成新人物",key:laterKey,samples:changedCondition,domain:archive.inputKind)
    try check(augmented?.people[0].samples.count==6,"explicit_name_can_add_internally_consistent_new_microphone_condition")
    var splitMatcher=VoiceprintMatcher(archive:archive);splitMatcher.reset(session:key.session)
    var split=event(30);split["segment_id"]="split-parent";split["start"]=0.0;split["end"]=12.0;split["text"]="甲a乙b丙c";split["speaker"]=["basis":"multiple","reason":"speaker_change"];split.removeValue(forKey:"identity_features")
    var splitRuns:[[String:Any]]=[]
    for i in 0..<3 {
        let lo=Double(i*4)
        var run=event(i);run["start"]=lo;run["end"]=lo+3;run["text"]=["甲","乙","丙"][i]
        var feature=run["identity_features"] as! [String:Any];feature["evidence_start"]=lo;feature["evidence_end"]=lo+2;run["identity_features"]=feature
        splitRuns.append(run);splitRuns.append(["start":lo+3,"end":lo+4,"text":["a","b","c"][i],"speaker":["basis":"unknown"]])
    }
    split["speaker_runs"]=splitRuns
    var splitNames=SessionNames();splitNames.register(segment:"split-parent",item:split)
    for run in TranscriptTimeline.speakerRuns(split) {splitNames.register(segment:TranscriptTimeline.runID(parent:"split-parent",run:run),item:run)}
    _=splitMatcher.observeParent(split,domain:archive.inputKind)
    try check(splitMatcher.retainedEvidenceCount==3 && splitNames.reconcileAutoVoiceprint(key:key,candidate:splitMatcher.recommendation(key)),"three_clear_subruns_in_mixed_parent_support_name_with_canonical_bindings")
    split["revision"]=2;split.removeValue(forKey:"speaker_runs");_=splitMatcher.observeParent(split,domain:archive.inputKind)
    try check(splitMatcher.retainedEvidenceCount==0 && splitNames.reconcileAutoVoiceprint(key:key,candidate:splitMatcher.recommendation(key)) && !splitNames.autoNameIsSuppressed(key),"revised_parent_retracts_all_subrun_evidence_without_permanent_suppression")
    let targetStore=VoiceprintArchiveStore(folder:directory.appendingPathComponent("manual-memory"),domain:archive.inputKind)
    try targetStore.save(firstArchive)
    do {try targetStore.save(firstArchive,expectedRevision:99);throw Failure(code:"stale_archive_write_accepted")}catch ProfileStoreError.invalid{checks.append("stale_reference_update_is_rejected")}
    let memoryService=VoiceprintRecommendationService(store:targetStore);memoryService.reset(key.session)
    for i in 0..<3 {memoryService.observe(event(i,vector(6))) {_,_,_,_ in }}
    memoryService.queue.sync{}
    try check((try targetStore.load()!).people.count==1,"observing_unnamed_voice_never_trains_a_reference")
    func confirmation(_ name:String)->SessionVoiceConfirmation {SessionVoiceConfirmation(id:UUID().uuidString,session:key.session,name:name,person:nil,segmentIDs:["voice-0","voice-1","voice-2"],createdAt:ISO8601DateFormatter().string(from:Date()))}
    memoryService.synchronize(session:key.session,confirmations:[confirmation("人工新姓名")]) {_ in };memoryService.queue.sync{}
    try check((try targetStore.load()!).people.contains(where:{$0.name=="人工新姓名" && $0.samples.count==3}),"explicit_manual_action_reaches_reference_store")
    let waitingStore=VoiceprintArchiveStore(folder:directory.appendingPathComponent("pending-manual-memory"),domain:archive.inputKind)
    let waitingService=VoiceprintRecommendationService(store:waitingStore);waitingService.reset(key.session)
    waitingService.observe(event(0,vector(8))) {_,_,_,_ in };waitingService.queue.sync{}
    waitingService.synchronize(session:key.session,confirmations:[confirmation("等待清晰样本")]) {_ in };waitingService.queue.sync{}
    var missingFeature=event(0,vector(8));missingFeature["revision"]=2;missingFeature.removeValue(forKey:"identity_features")
    waitingService.observe(missingFeature,confirmedManualNames:[key:"等待清晰样本"]) {_,_,_,_ in }
    for i in 0..<3 {var e=event(i,vector(8));e["revision"]=3;waitingService.observe(e,confirmedManualNames:[key:"等待清晰样本"]) {_,_,_,_ in }}
    waitingService.queue.sync{}
    try check((try waitingStore.load())?.people.first?.name=="等待清晰样本","temporary_feature_gap_does_not_cancel_explicit_pending_memory")
    let cancelledStore=VoiceprintArchiveStore(folder:directory.appendingPathComponent("cancelled-manual-memory"),domain:archive.inputKind)
    let cancelledService=VoiceprintRecommendationService(store:cancelledStore);cancelledService.reset(key.session)
    cancelledService.observe(event(0,vector(8))) {_,_,_,_ in };cancelledService.queue.sync{}
    cancelledService.synchronize(session:key.session,confirmations:[confirmation("已经撤回")]) {_ in };cancelledService.synchronize(session:key.session,confirmations:[]) {_ in }
    for i in 1..<3 {cancelledService.observe(event(i,vector(8)),confirmedManualNames:[key:"已经撤回"]) {_,_,_,_ in }}
    cancelledService.queue.sync{}
    try check(try cancelledStore.load()?.people.isEmpty != false,"manual_undo_cancels_future_automatic_learning")
    let semanticView=Delegate();semanticView.previewRenderOnly=true;semanticView.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));semanticView.recoveryRootOverride=cacheRoot
    semanticView.receive(["type":"started","session":key.session,"cache_id":UUID().uuidString])
    semanticView.receive(firstIntro);semanticView.receive(secondIntro)
    try semanticView.settleTranscriptForOfflineReview()
    try check(semanticView.naming.displayName(speaker:key)?.origin == .semantic && semanticView.transcriptExport().contains("张三"),"production_receive_and_export_preserve_semantic_provenance")
    try check(semanticView.acceptVoiceprintRecommendation(key) && semanticView.naming.name(speaker:key)=="张三" && semanticView.naming.displayName(speaker:key)?.origin == .manual,"explicit_semantic_confirmation_becomes_manual_name")
    let ui=try await minimalVoiceprintUIChecks(owner:view,key:key,directory:directory);checks.append(contentsOf:ui)
    view.cacheWriteQueue.sync{}
    var reopenedAfterRevoke=SessionNames();for i in 0..<3 {reopenedAfterRevoke.register(segment:"voice-\(i)",item:event(i))}
    try reopenedAfterRevoke.restore(Data(contentsOf:namesFile),session:key.session)
    try check(reopenedAfterRevoke.displayName(speaker:key)==nil && reopenedAfterRevoke.autoNameIsSuppressed(key),"revoke_and_manual_undo_persist_across_restart")
    try check(view.naming.name(speaker:key)==nil && (try store.load()!).revision==1,"conflicting_manual_override_does_not_poison_existing_profiles")
    view.receive(event(4));view.phase.phase = .stopped;view.newMeeting()
    try await Task.sleep(nanoseconds:50_000_000)
    try check(view.voiceprintCandidates.isEmpty,"late_background_result_cannot_leak_into_new_meeting")
    let data=try JSONEncoder().encode(archive);try data.write(to:directory.appendingPathComponent("synthetic-voices.json"))
    return ["type":"voiceprint_recommendation_checks","passed":checks.count,"checks":checks,"network":false,"capture":false,"keychain":false,"real_people_enrolled":false]
}

// Explicitly selected, already-authorized local feature replay. No device,
// enrollment, historical transcript mutation or genuine new-meeting claim.
func voiceprintSavedFeatureReview(archiveURL:URL,featuresURL:URL)throws->[String:Any] {
    guard Credential.offline,archiveURL.path.contains("/.runtime/voiceprint-review/"),featuresURL.path.contains("/.runtime/voiceprint-review/") else{throw Failure(code:"voiceprint_saved_review_scope")}
    let archive=try JSONDecoder().decode(VoiceprintArchive.self,from:Data(contentsOf:archiveURL)).validated(domain:"consented_live_audio")
    let object=try JSONSerialization.jsonObject(with:Data(contentsOf:featuresURL)) as! [String:Any]
    let probes=object["features"] as! [[String:Any]]
    var groups:[String:[[String:Any]]]=[:];var accepted=0,unknown=0;var matcher=VoiceprintMatcher(archive:archive)
    matcher.reset(session:"independent-saved-feature-replay")
    for (i,probe) in probes.enumerated() {
        let expected=probe["expected"] as! String,sample=probe["sample"] as! [String:Any]
        let person=archive.people.first{$0.name==expected}!
        let slot=archive.people.firstIndex{$0.id==person.id}!
        let start=sample["start"] as! Double,end=sample["end"] as! Double,values=sample["vector"] as! [Double]
        let scores=archive.scores(values)
        let passes=scores.first.map{$0.1>=0.60 && $0.1-(scores.dropFirst().first?.1 ?? 0)>=0.14} ?? false
        if passes {guard scores[0].0==person.id else{throw Failure(code:"saved_voice_false_positive")};accepted+=1}else{unknown+=1}
        let speaker:[String:Any]=["basis":"anonymous_cluster","cluster_id":slot,"source_id":"remote","epoch":"feature-replay"]
        let event:[String:Any]=["type":"segment","session":"independent-saved-feature-replay","segment_id":"saved-\(i)","revision":1,"source_id":"remote","epoch":"feature-replay","start":start,"end":end,"final":true,"end_time_known":true,"speaker":speaker,"identity_features":["partition":archive.partition,"input_kind":archive.inputKind,"source_id":"remote","epoch":"feature-replay","quality_gate":"single_model_slot_asr_final_unclipped","evidence_start":start,"evidence_end":end,"values":values]]
        _ = matcher.observe(event,domain:archive.inputKind);groups[expected,default:[]].append(event)
    }
    var recommendations:[String:String]=[:]
    for (i,person) in archive.people.enumerated() {
        let key=SessionSpeakerKey(session:"independent-saved-feature-replay",source:"remote",epoch:"feature-replay",identity:"slot:\(i)")
        guard matcher.recommendation(key)?.personID==person.id else{throw Failure(code:"saved_voice_group_no_recommendation")}
        recommendations[person.name]=matcher.recommendation(key)!.name
    }
    return ["type":"independent_saved_voice_feature_review","profiles":archive.people.count,"independent_examples":probes.count,"accepted":accepted,"unknown":unknown,"wrong_names":0,"group_recommendations":recommendations,"capture":false,"cloud":false,"keychain":false,"new_meeting_quality_verified":false]
}

// Pure synthetic regression for registered and out-of-library voices sharing a
// model slot. No real PCM, app startup, or persistent voice archive is involved.
func voiceprintMixedGroupChecks() throws->[String] {
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:name)};checks.append(name)}
    func vector(_ i:Int)->[Double] {var v=[Double](repeating:0,count:192);v[i]=1;return v}
    let people=(0..<2).map {i in VoiceprintPerson(id:UUID().uuidString,name:"合成人物\(i)",authorizedAt:"2026-10-08T12:00:00Z",enabled:true,samples:(0..<3).map{j in VoiceprintSample(session:"prior",source:"mic",epoch:"old",start:Double(j*5),end:Double(j*5+2),vector:vector(i))})}
    let archive=VoiceprintArchive(schema:1,partition:SpeakerEmbeddingBackend.partition,inputKind:"synthetic_model_output",revision:1,people:people)
    _ = try archive.validated(domain:archive.inputKind)
    let key=SessionSpeakerKey(session:"mixed-group",source:"mic",epoch:"current",identity:"slot:0")
    func event(_ i:Int,_ values:[Double],source:String="mic",epoch:String="current",slot:Int=0)->[String:Any] {
        let start=Double(i*5)
        return ["session":key.session,"segment_id":"mixed-\(i)","revision":1,"source_id":source,"epoch":epoch,"start":start,"end":start+3,"final":true,"end_time_known":true,"speaker":["basis":"anonymous_cluster","cluster_id":slot,"source_id":source,"epoch":epoch],"identity_features":["partition":archive.partition,"input_kind":archive.inputKind,"source_id":source,"epoch":epoch,"quality_gate":"single_model_slot_asr_final_unclipped","evidence_start":start,"evidence_end":start+2,"values":values]]
    }
    var matcher=VoiceprintMatcher(archive:archive);matcher.reset(session:key.session)
    for i in 0..<3 {_ = matcher.observe(event(i,vector(0)),domain:archive.inputKind)}
    try check(matcher.recommendation(key)?.personID==people[0].id,"mixed_gate_preserves_consistent_known_speaker")
    for _ in 0..<4 {_ = matcher.observe(event(2,vector(0)),domain:archive.inputKind)}
    try check(matcher.retainedEvidenceCount==3,"mixed_gate_revisions_are_not_independent_samples")
    var duplicate=event(2,vector(4));duplicate["segment_id"]="same-interval"
    _ = matcher.observe(duplicate,domain:archive.inputKind)
    try check(matcher.retainedEvidenceCount==3 && matcher.recommendation(key) != nil,"mixed_gate_does_not_double_count_overlapping_audio")
    _ = matcher.observe(event(10,vector(4),epoch:"other-epoch"),domain:archive.inputKind)
    try check(matcher.recommendation(key) != nil,"mixed_gate_keeps_epochs_separate")
    _ = matcher.observe(event(11,vector(4),slot:1),domain:archive.inputKind)
    try check(matcher.recommendation(key) != nil,"mixed_gate_keeps_slots_separate")
    _ = matcher.observe(event(12,vector(4),source:"remote"),domain:archive.inputKind)
    try check(matcher.recommendation(key) != nil,"mixed_gate_keeps_sources_separate")
    _ = matcher.observe(event(3,vector(4)),domain:archive.inputKind)
    try check(matcher.recommendation(key)==nil,"clear_out_of_library_voice_withholds_group_name")
    try check(!matcher.conflictingEvidence(key),"out_of_library_inconsistency_is_not_permanent_identity_conflict")
    var revised=event(3,vector(0));revised["revision"]=2
    _ = matcher.observe(revised,domain:archive.inputKind)
    try check(matcher.recommendation(key)?.personID==people[0].id && matcher.recommendation(key)?.support.contains(VoiceprintEvidenceRef(id:"mixed-3",revision:2))==true,"corrected_out_of_library_evidence_restores_current_recommendation")
    _ = matcher.observe(event(4,vector(4)),domain:archive.inputKind)
    matcher.remove("mixed-4")
    try check(matcher.recommendation(key) != nil,"removed_out_of_library_evidence_restores_recommendation")
    _ = matcher.observe(event(4,vector(1)),domain:archive.inputKind)
    try check(matcher.recommendation(key)==nil && matcher.conflictingEvidence(key),"known_person_conflict_remains_distinct_and_withheld")
    matcher.reset(session:key.session)
    for i in 0..<8 {_ = matcher.observe(event(i,vector(i<3 ? 0:4)),domain:archive.inputKind)}
    try check(matcher.recommendation(key)==nil && !matcher.conflictingEvidence(key),"three_known_plus_five_unknown_never_names_whole_group")
    matcher.reset(session:key.session)
    for i in 0..<3 {_ = matcher.observe(event(i,vector(4)),domain:archive.inputKind)}
    try check(matcher.recommendation(key)==nil,"mixed_gate_never_guesses_all_unknown_group")
    matcher.reset(session:key.session)
    for i in 0..<4 {
        var varied=vector(0);varied[0]=0.9;varied[i+3]=(1-0.81).squareRoot()
        _ = matcher.observe(event(i,varied),domain:archive.inputKind)
    }
    try check(matcher.recommendation(key)?.personID==people[0].id,"consistent_nonidentical_voice_vectors_still_recommend")
    return checks
}
