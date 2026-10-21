import AppKit

@MainActor func savedVoiceRecognitionChecks(directory:URL) async throws->[String:Any] {
    guard Credential.offline,directory.path.contains("/.runtime/") else{throw Failure(code:"saved_voice_fixture_scope")}
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:name)};checks.append(name)}
    let base=directory.appendingPathComponent(UUID().uuidString),folder=base.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    func write(_ object:Any,_ name:String)throws {try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:folder.appendingPathComponent(name))}
    let session=UUID().uuidString,key=SessionSpeakerKey(session:session,source:"mic",epoch:"saved-test",identity:"slot:0")
    try write(["session":session,"capture_origin_uptime":100.0],"meeting.json")
    let samples=(0..<160000).map{i in Int16(6000*sin(Double(i)*0.07))},pcm=samples.withUnsafeBytes{Data($0)}
    try pcm.write(to:folder.appendingPathComponent("mic-000000.pcm"))
    let manifest:[String:Any]=["schema":1,"track":"mic","format":"pcm_s16le","sample_rate":16000,"channels":1,"ended":true,"written_bytes":pcm.count,"asr_committed_bytes":pcm.count,"origin_uptime":100.0,"chunks":[["index":0,"start_sample":0,"bytes":pcm.count,"sha256":historicalVoiceHash(pcm)]]]
    try write(manifest,"mic-manifest.json")
    var events=(0..<3).map{i -> [String:Any] in ["type":"segment","session":session,"source_id":"mic","track":"mic","epoch":key.epoch,"segment_id":"saved-\(i)","revision":1,"start":Double(i*3),"end":Double(i*3+3),"final":true,"end_time_known":true,"text":"独立合成发言\(i)","speaker":["basis":"anonymous_cluster","source_id":"mic","epoch":key.epoch,"cluster_id":0]]}
    func writeEvents()throws {var data=Data();for event in events {data.append(try JSONSerialization.data(withJSONObject:event,options:[.sortedKeys]));data.append(10)};try data.write(to:folder.appendingPathComponent("mic-transcript.jsonl"))}
    try writeEvents()
    func vector(_ i:Int)->[Double] {var v=[Double](repeating:0,count:192);v[i]=1;return v}
    let request=SavedVoiceRecognitionRequest(folder:folder.path,session:session,inputKind:"synthetic_model_output",keys:[key])
    var calls=0
    let result=try SavedVoiceRecognition.run(request,extract:{audio in calls+=1;guard audio.count==48000 else{throw Failure(code:"saved_voice_unbounded_audio")};return vector(0)})
    try check(calls==3 && result.evidence.count==3,"saved_history_without_persisted_features_extracts_three_independent_spans")
    try check(result.audioChecks.count==1 && result.inputHashes[MeetingCoarseRefinement.filename]=="absent","saved_result_binds_audio_and_absent_projection")
    try check(historicalVoiceHash(try Data(contentsOf:folder.appendingPathComponent("mic-000000.pcm")))==historicalVoiceHash(pcm),"saved_matching_preserves_original_pcm")
    let people=(0..<2).map{i in VoiceprintPerson(id:UUID().uuidString,name:"合成人物\(i)",authorizedAt:"2026-10-14T00:00:00Z",enabled:true,samples:(0..<3).map{j in VoiceprintSample(session:"training",source:"mic",epoch:"past",start:Double(j*3),end:Double(j*3+2),vector:vector(i))})}
    let archive=VoiceprintArchive(schema:1,partition:SpeakerEmbeddingBackend.partition,inputKind:request.inputKind,revision:1,people:people)
    var matcher=VoiceprintMatcher(archive:archive);matcher.reset(session:session);matcher.importSavedEvidence(result.evidence)
    try check(matcher.recommendation(key)?.name==people[0].name,"saved_features_use_same_strict_matcher")
    matcher.importSavedEvidence([SavedVoiceRecognitionEvidence(id:"echo-on-other-track",revision:1,key:key,sample:VoiceprintSample(session:session,source:"remote",epoch:"remote",start:0,end:2,vector:vector(0)))])
    try check(matcher.retainedEvidenceCount==3,"same_utterance_on_two_sources_counts_as_one_independent_example")
    let outlier=SavedVoiceRecognitionEvidence(id:"outlier",revision:1,key:key,sample:VoiceprintSample(session:session,source:"mic",epoch:key.epoch,start:12,end:14,vector:vector(4)))
    matcher.importSavedEvidence([outlier])
    let suggestion=matcher.suggestion(key)
    try check(matcher.recommendation(key)==nil && suggestion?.name==people[0].name && suggestion?.groupConsistent==false,"outlier_keeps_supported_suggestion_without_naming_whole_group")
    var names=SessionNames();for event in events {names.register(segment:event["segment_id"] as! String,item:event)}
    _ = names.reconcileAutoVoiceprint(key:key,candidate:suggestion)
    try check(names.displayName(speaker:key)==nil && names.name(speaker:key)==nil,"partial_suggestion_cannot_name_whole_group")
    try check(events.allSatisfy{names.displayName(segment:$0["segment_id"] as! String)?.origin == .voiceprint} && names.voiceConfirmations.isEmpty,"qualified_partial_spans_display_automatic_name_without_becoming_training_labels")
    names.register(segment:"outlier",item:["session":session,"source_id":"mic","epoch":key.epoch,"revision":1,"speaker":["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":key.epoch]])
    try check(names.displayName(segment:"outlier")==nil,"unmatched_span_in_same_group_stays_unknown")
    let spanSnapshot=try names.snapshot(session:session)
    var reopenedSpans=SessionNames();for event in events {reopenedSpans.register(segment:event["segment_id"] as! String,item:event)}
    try reopenedSpans.restore(spanSnapshot,session:session)
    try check(reopenedSpans.displayName(segment:"saved-0")==nil,"restored_span_name_requires_current_bank")
    reopenedSpans.validateVoiceprintArchive(archive)
    try check(reopenedSpans.displayName(segment:"saved-0")?.value==people[0].name,"current_bank_restores_qualified_span_name")
    var staleBank=archive;staleBank.revision+=1;reopenedSpans.validateVoiceprintArchive(staleBank)
    try check(reopenedSpans.displayName(segment:"saved-0")==nil,"changed_bank_withdraws_old_per_span_decision_until_rematched")
    var optedOut=archive;optedOut.people[0].enabled=false;reopenedSpans.validateVoiceprintArchive(optedOut)
    try check(reopenedSpans.displayName(segment:"saved-0")==nil,"disabled_person_withdraws_saved_per_span_name")
    var nearVector=[Double](repeating:0,count:192);nearVector[0]=0.65;nearVector[1]=sqrt(1-0.65*0.65)
    var near=VoiceprintMatcher(archive:archive);near.reset(session:session);near.importSavedEvidence(result.evidence)
    near.importSavedEvidence([SavedVoiceRecognitionEvidence(id:"similar-unknown",revision:1,key:key,sample:VoiceprintSample(session:session,source:"mic",epoch:key.epoch,start:18,end:20,vector:nearVector))])
    try check(near.recommendation(key)==nil && near.suggestion(key)?.groupConsistent==false,"acoustically_similar_but_unidentified_row_never_inherits_group_name")
    let conflict=SavedVoiceRecognitionEvidence(id:"conflict",revision:1,key:key,sample:VoiceprintSample(session:session,source:"mic",epoch:key.epoch,start:15,end:17,vector:vector(1)))
    matcher.importSavedEvidence([conflict]);try check(matcher.suggestion(key)==nil,"strong_different_person_blocks_partial_suggestion")
    var same=VoiceprintMatcher(archive:archive);same.reset(session:"training");same.importSavedEvidence(result.evidence.map{SavedVoiceRecognitionEvidence(id:$0.id,revision:$0.revision,key:SessionSpeakerKey(session:"training",source:"mic",epoch:key.epoch,identity:key.identity),sample:$0.sample)})
    try check(same.suggestion(SessionSpeakerKey(session:"training",source:"mic",epoch:key.epoch,identity:key.identity))==nil,"training_session_is_excluded_from_saved_recognition")
    var selected=request;selected.selectedIDs=["saved-1"]
    let subset=try SavedVoiceRecognition.run(selected,extract:{_ in vector(0)})
    try check(subset.evidence.map(\.id)==["saved-1"],"read_only_review_never_expands_explicit_selection")
    try write(["schema":1],MeetingCoarseRefinement.filename)
    do {try SavedVoiceRecognition.validate(result,request:request);throw Failure(code:"saved_changed_projection_accepted")}catch let error as Failure {try check(error.code=="saved_voice_source_changed","changed_projection_invalidates_inflight_result")}
    try FileManager.default.removeItem(at:folder.appendingPathComponent(MeetingCoarseRefinement.filename))
    var changed=pcm;changed[0]^=1;try changed.write(to:folder.appendingPathComponent("mic-000000.pcm"))
    do {try SavedVoiceRecognition.validate(result,request:request);throw Failure(code:"saved_changed_audio_accepted")}catch let error as Failure {try check(error.code=="saved_voice_source_changed","changed_pcm_invalidates_inflight_result")}
    try pcm.write(to:folder.appendingPathComponent("mic-000000.pcm"))
    let cleanEvents=events
    events[0]["speaker"]=["basis":"multiple","reason":"overlap"]
    events[1]["quality_flags"]=["low_quality"]
    events[2]["final"]=false;try writeEvents()
    calls=0;let unsafe=try SavedVoiceRecognition.run(request,extract:{_ in calls+=1;return vector(0)})
    try check(unsafe.evidence.isEmpty && calls==0,"overlap_quality_flags_and_partial_text_do_not_enter_matcher")
    events=cleanEvents;try writeEvents()
    let store=VoiceprintArchiveStore(folder:base.appendingPathComponent("Voiceprints"),domain:request.inputKind);try store.save(archive,expectAbsent:true)
    try check(savedVoiceRecognitionEligible(offline:false,preview:true,history:true,fixtureExecutor:false),"production_embedded_history_with_preview_rendering_is_eligible_without_test_override")
    try check(!savedVoiceRecognitionEligible(offline:false,preview:true,history:false,fixtureExecutor:true),"test_executor_cannot_bypass_preview_only_guard")
    try check(!savedVoiceRecognitionEligible(offline:true,preview:true,history:true,fixtureExecutor:false),"offline_history_never_reads_real_audio_without_explicit_fixture_executor")
    let view=Delegate();view.previewRenderOnly=true;view.isHistoryReader=true;view.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));view.recoveryRootOverride=base
    view.voiceprintService=VoiceprintRecommendationService(store:store)
    var launched=0,pending:((UUID,Result<Data,Error>)->Void)?,pendingToken:UUID?
    view.savedVoiceRecognitionExecutorOverride={req,token,done in launched+=1;pending=done;pendingToken=token}
    let meeting=CachedMeeting(id:folder.lastPathComponent,directory:folder,date:Date(),writtenBytes:pcm.count,pendingBytes:0,occupiedBytes:pcm.count,tracks:["mic"],audioCleaned:false,warning:false,retiredBytes:0)
    try view.applyRecovery(meeting,payload:RecoveryPayload(meeting))
    for _ in 0..<100 where launched==0 {try await Task.sleep(nanoseconds:10_000_000)}
    try check(launched==1,"opening_history_schedules_matching_after_name_restore")
    pending?(pendingToken!,.success(try JSONEncoder().encode(result)))
    for _ in 0..<100 where view.naming.displayName(speaker:key)==nil {try await Task.sleep(nanoseconds:10_000_000)}
    try check(view.naming.displayName(speaker:key)?.origin == .voiceprint && view.naming.name(speaker:key)==nil,"saved_result_reaches_actual_history_display_as_automatic_name")
    let captureOwner=Delegate()
    // Saved-name persistence can asynchronously refresh the owning library.
    // Build its actual UI before attaching the history reader to that owner.
    captureOwner.previewRenderOnly=true
    captureOwner.recoveryRootOverride=base
    captureOwner.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    captureOwner.speakerRefinementCheckMode=true
    captureOwner.voiceprintService=view.voiceprintService
    captureOwner.phase.phase = .paused
    view.workspaceOwner=captureOwner
    try check(captureOwner.recordingBusy && !captureOwner.savedVoiceRecognitionBlocksHistory,"paused_capture_does_not_block_saved_history_matching")
    captureOwner.pausedTailStates=["mic":"processing"]
    try check(captureOwner.savedVoiceRecognitionBlocksHistory,"paused_tail_drain_still_blocks_history_matching")
    captureOwner.pausedTailStates=[:]
    captureOwner.recordingControlInFlight="resume"
    try check(captureOwner.savedVoiceRecognitionBlocksHistory,"pending_resume_blocks_history_matching")
    captureOwner.recordingControlInFlight=nil
    captureOwner.phase.phase = .recording
    try check(captureOwner.savedVoiceRecognitionBlocksHistory,"active_capture_still_blocks_history_matching")
    captureOwner.phase.phase = .paused
    view.scheduleSavedVoiceRecognition()
    for _ in 0..<100 where launched<2 {try await Task.sleep(nanoseconds:10_000_000)}
    try check(launched==2,"history_reader_launches_matching_with_other_meeting_paused")
    captureOwner.historyReader=view
    captureOwner.cancelSpeakerRefinementForResume()
    pending?(pendingToken!,.success(try JSONEncoder().encode(result)))
    try await Task.sleep(nanoseconds:50_000_000)
    try check(view.savedVoiceRecognitionJob.isCurrent(pendingToken!)==false,"owner_resume_cancels_history_matching")
    captureOwner.historyReader=nil;view.workspaceOwner=nil
    launched=1
    view.rejectVoiceprintRecommendation(key);view.scheduleSavedVoiceRecognition()
    try check(view.naming.autoNameIsSuppressed(key) && view.naming.displayName(speaker:key)==nil && launched==1,"rejecting_saved_name_stays_silent_on_retry")
    view.naming.reset();for event in events {view.naming.register(segment:event["segment_id"] as! String,item:event)}
    view.scheduleSavedVoiceRecognition()
    for _ in 0..<100 where launched<2 {try await Task.sleep(nanoseconds:10_000_000)}
    let late=pending,lateToken=pendingToken!
    view.phase.phase = .paused
    view.receive(["type":"recording_resumed","session":session,"control_revision":1])
    late?(lateToken,.success(try JSONEncoder().encode(result)));try await Task.sleep(nanoseconds:50_000_000)
    try check(view.phase.phase == .recording && view.voiceprintCandidates.isEmpty && view.naming.displayName(speaker:key)==nil,"same_meeting_resume_cancels_saved_match_without_delaying_recording")
    view.phase.phase = .paused;view.scheduleSavedVoiceRecognition()
    for _ in 0..<100 where launched<3 {try await Task.sleep(nanoseconds:10_000_000)}
    let switched=pending,switchedToken=pendingToken!
    view.resetVoiceprintRecommendations(session:"next");view.activeSession="next"
    switched?(switchedToken,.success(try JSONEncoder().encode(result)));try await Task.sleep(nanoseconds:50_000_000)
    try check(view.voiceprintCandidates.isEmpty && view.naming.displayName(speaker:key)==nil,"switching_meeting_cancels_late_saved_matching")
    view.activeSession=session;view.naming.reset()
    for event in events {view.naming.register(segment:event["segment_id"] as! String,item:event)}
    view.voiceprintCandidates=[key:suggestion!]
    let supported=ReadingTurn(id:"saved-0",parent:"saved-0",item:events[0],parts:[("saved-0",events[0])],uncertain:false)
    var otherItem=events[0];otherItem["segment_id"]="unmatched"
    view.naming.register(segment:"unmatched",item:otherItem)
    let unmatched=ReadingTurn(id:"unmatched",parent:"unmatched",item:otherItem,parts:[("unmatched",otherItem)],uncertain:false)
    try check(view.voiceprintHint(supported).contains("合成人物0") && view.voiceprintHint(unmatched).isEmpty,"partial_suggestion_hint_only_marks_its_supporting_utterances")
    checks+=try await partialVoiceprintUIChecks(owner:view,key:key,directory:directory)
    view.voiceprintCandidates=[:]
    _ = view.naming.reconcileAutoVoiceprint(key:key,candidate:suggestion)
    view.voiceprintSuggestionArchive=nil
    try check(view.voiceprintRecommendation(for:key)==nil,"persisted_suggestion_waits_for_current_archive_validation")
    view.voiceprintSuggestionArchive=archive
    try check(view.voiceprintRecommendation(for:key)?.name==people[0].name,"current_enabled_archive_restores_persisted_review_candidate")
    var disabledArchive=archive;disabledArchive.people[0].enabled=false;view.voiceprintSuggestionArchive=disabledArchive
    try check(view.voiceprintRecommendation(for:key)==nil,"disabled_archive_cannot_revive_or_confirm_persisted_suggestion")
    captureOwner.window.close();captureOwner.sheet.close()
    view.window.close();view.sheet.close()
    // Long-history coverage keeps the same score, independence and consistency
    // gates. More spans can reveal a supported voice, never name mixed rows.
    let longFolder=base.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:longFolder,withIntermediateDirectories:true)
    try JSONSerialization.data(withJSONObject:["session":session,"capture_origin_uptime":100.0]).write(to:longFolder.appendingPathComponent("meeting.json"))
    var chunks:[[String:Any]]=[]
    for i in 0..<8 {
        try pcm.write(to:longFolder.appendingPathComponent(String(format:"mic-%06d.pcm",i)))
        chunks.append(["index":i,"start_sample":i*160000,"bytes":pcm.count,"sha256":historicalVoiceHash(pcm)])
    }
    var longManifest=manifest;longManifest["chunks"]=chunks;longManifest["written_bytes"]=pcm.count*8;longManifest["asr_committed_bytes"]=pcm.count*8
    try JSONSerialization.data(withJSONObject:longManifest).write(to:longFolder.appendingPathComponent("mic-manifest.json"))
    var longData=Data()
    for i in 0..<30 {var event=cleanEvents[0];event["segment_id"]="broad-\(i)";event["start"]=Double(i)*2.5;event["end"]=Double(i)*2.5+2;longData.append(try JSONSerialization.data(withJSONObject:event));longData.append(10)}
    try longData.write(to:longFolder.appendingPathComponent("mic-transcript.jsonl"))
    var longRequest=SavedVoiceRecognitionRequest(folder:longFolder.path,session:session,inputKind:request.inputKind,keys:[key])
    let limited=try SavedVoiceRecognition.run(longRequest,extract:{_ in vector(4)})
    longRequest.sampleLimit=24
    let broader=try SavedVoiceRecognition.run(longRequest,extract:{_ in vector(4)})
    try check(limited.evidence.count==8 && broader.evidence.count==24,"saved_coverage_expands_to_bounded_24_spans")
    let positives=Set(["broad-1","broad-3","broad-5"])
    func remap(_ rows:[SavedVoiceRecognitionEvidence])->[SavedVoiceRecognitionEvidence] {rows.map{row in var sample=row.sample;sample=VoiceprintSample(session:sample.session,source:sample.source,epoch:sample.epoch,start:sample.start,end:sample.end,vector:vector(positives.contains(row.id) ? 0:4));return SavedVoiceRecognitionEvidence(id:row.id,revision:row.revision,key:row.key,sample:sample)}}
    var limitedMatcher=VoiceprintMatcher(archive:archive);limitedMatcher.reset(session:session);limitedMatcher.importSavedEvidence(remap(limited.evidence))
    var broaderMatcher=VoiceprintMatcher(archive:archive);broaderMatcher.reset(session:session);broaderMatcher.importSavedEvidence(remap(broader.evidence))
    try check(limitedMatcher.suggestion(key)==nil && broaderMatcher.suggestion(key)?.name==people[0].name && broaderMatcher.recommendation(key)==nil,"broader_coverage_finds_three_consistent_spans_without_naming_mixed_group")
    longRequest.sampleLimit=25
    do {_ = try SavedVoiceRecognition.folder(longRequest);throw Failure(code:"saved_unbounded_sampling_accepted")}catch let error as Failure {try check(error.code=="saved_voice_scope_invalid","unbounded_saved_sampling_is_rejected")}
    var learningNames=SessionNames()
    for i in 0..<30 {var event=cleanEvents[0];event["segment_id"]="broad-\(i)";event["start"]=Double(i)*2.5;event["end"]=Double(i)*2.5+2;learningNames.register(segment:"broad-\(i)",item:event)}
    let learningFile=longFolder.appendingPathComponent("session-names.json"),learningStore=VoiceprintArchiveStore(folder:base.appendingPathComponent("Enrollment"),domain:request.inputKind)
    try learningNames.snapshot(session:session).write(to:learningFile)
    let noLabel=try enrollSavedVoiceReferences(result:broader,folder:longFolder,store:learningStore,authorized:true)
    try check(noLabel.isEmpty && !FileManager.default.fileExists(atPath:learningStore.file.path),"continuous_learning_never_enrolls_unlabelled_or_inferred_identity")
    do {_ = try enrollSavedVoiceReferences(result:broader,folder:longFolder,store:learningStore,authorized:false);throw Failure(code:"unauthorized_learning_accepted")}catch let error as Failure {try check(error.code=="voice_learning_not_authorized","continuous_learning_requires_explicit_local_permission")}
    _ = learningNames.confirmSegments((0..<30).map{"broad-\($0)"},name:"合成新人物",learn:false)
    let beforeLearning=try learningNames.snapshot(session:session);try beforeLearning.write(to:learningFile)
    let runtimeStore=VoiceprintArchiveStore(folder:base.appendingPathComponent("RuntimeEnrollment"),domain:request.inputKind)
    let withoutRecord=try enrollSavedVoiceReferences(result:broader,folder:longFolder,store:runtimeStore,authorized:true,createConfirmationIfMissing:false)
    try check(withoutRecord.isEmpty && !FileManager.default.fileExists(atPath:runtimeStore.file.path),"runtime_learning_requires_confirmation_persisted_with_name_transaction")
    var supportedNames=learningNames
    let supportedIDs=Array(broader.evidence.prefix(3).map(\.id))
    supportedNames.attachConfirmation(segmentIDs:supportedIDs,name:"合成新人物",learn:true)
    let supportedData=try supportedNames.snapshot(session:session);try supportedData.write(to:learningFile)
    _ = try enrollSavedVoiceReferences(result:broader,folder:longFolder,store:runtimeStore,authorized:true,createConfirmationIfMissing:false)
    try check(try runtimeStore.load()?.learning?.contributions.first?.samples.count==3,"runtime_partial_confirmation_trains_only_three_supporting_spans")
    try check(try Data(contentsOf:learningFile)==supportedData,"runtime_learning_does_not_rewrite_inflight_names")
    let newCondition=SavedVoiceRecognitionResult(session:broader.session,partition:broader.partition,inputKind:broader.inputKind,inputHashes:broader.inputHashes,audioChecks:broader.audioChecks,evidence:broader.evidence.map{row in let s=row.sample;return SavedVoiceRecognitionEvidence(id:row.id,revision:row.revision,key:row.key,sample:VoiceprintSample(session:s.session,source:s.source,epoch:s.epoch,start:s.start,end:s.end,vector:vector(5),context:s.context))},skipped:broader.skipped)
    _ = try enrollSavedVoiceReferences(result:newCondition,folder:longFolder,store:runtimeStore,authorized:true)
    try check(try runtimeStore.load()?.learning?.contributions.count==2,"standing_learning_keeps_old_reference_and_separates_incompatible_cohort")
    try beforeLearning.write(to:learningFile)
    do {_ = try enrollSavedVoiceReferences(result:broader,folder:longFolder,store:learningStore,authorized:true,commitGate:{_ in throw Failure(code:"cancelled_learning")});throw Failure(code:"cancelled_learning_accepted")}catch let error as Failure {try check(error.code=="cancelled_learning" && (try Data(contentsOf:learningFile))==beforeLearning,"continuous_learning_cancel_gate_preserves_names_and_archive")}
    let single=SavedVoiceRecognitionResult(session:broader.session,partition:broader.partition,inputKind:broader.inputKind,inputHashes:broader.inputHashes,audioChecks:broader.audioChecks,evidence:Array(broader.evidence.prefix(1)),skipped:broader.skipped)
    let pendingStore=VoiceprintArchiveStore(folder:base.appendingPathComponent("PendingEnrollment"),domain:request.inputKind)
    let pendingEnrollment=try enrollSavedVoiceReferences(result:single,folder:longFolder,store:pendingStore,authorized:true)
    try check(pendingEnrollment.first?["status"] as? String=="reference_only" && (try pendingStore.load()?.people.isEmpty)==true,"continuous_learning_accumulates_short_references_without_premature_recognition")
    try beforeLearning.write(to:learningFile)
    let enrolled=try enrollSavedVoiceReferences(result:broader,folder:longFolder,store:learningStore,authorized:true)
    let enrolledArchive=try learningStore.load()!
    try check(enrolled.first?["status"] as? String=="ready" && enrolledArchive.people.first?.name=="合成新人物","continuous_learning_reuses_projected_manual_labels_for_new_person")
    var oldObject=try JSONSerialization.jsonObject(with:beforeLearning) as! [String:Any],newObject=try JSONSerialization.jsonObject(with:Data(contentsOf:learningFile)) as! [String:Any]
    oldObject.removeValue(forKey:"voiceConfirmations");newObject.removeValue(forKey:"voiceConfirmations")
    try check((oldObject as NSDictionary).isEqual(to:newObject),"continuous_learning_only_appends_reversible_learning_metadata")
    _ = try enrollSavedVoiceReferences(result:broader,folder:longFolder,store:learningStore,authorized:true)
    try check(try learningStore.load()?.revision==enrolledArchive.revision,"continuous_learning_repeat_is_idempotent")
    let disabled=try archiveSettingVoiceEnabled(enrolledArchive,personID:enrolledArchive.people[0].id,enabled:false,domain:request.inputKind);try learningStore.save(disabled,expectedRevision:enrolledArchive.revision)
    let disabledReport=try enrollSavedVoiceReferences(result:broader,folder:longFolder,store:learningStore,authorized:true)
    try check(disabledReport.first?["status"] as? String=="rejected" && (try learningStore.load()?.revision)==disabled.revision,"continuous_learning_never_reenables_disabled_person")
    checks+=try voiceSuggestionPersistenceChecks()
    checks+=try await automaticVoiceServiceChecks(directory:directory)
    checks+=try await quickVoiceConfirmationChecks(directory:directory)
    return ["checks":checks,"passed":checks.count,"capture":false,"cloud":false,"keychain":false]
}

func savedVoiceRecognitionReview(resultURL:URL,archiveURL:URL)throws->[String:Any] {
    let result=try JSONDecoder().decode(SavedVoiceRecognitionResult.self,from:SavedVoiceRecognition.read(resultURL,limit:2*1024*1024))
    let archive=try JSONDecoder().decode(VoiceprintArchive.self,from:SavedVoiceRecognition.read(archiveURL,limit:16*1024*1024)).validated(domain:result.inputKind)
    var matcher=VoiceprintMatcher(archive:archive);matcher.reset(session:result.session);matcher.importSavedEvidence(result.evidence)
    let groups=Set(result.evidence.map(\.key)).map {key -> [String:Any] in
        let suggestion=matcher.suggestion(key)
        return ["key":try! JSONSerialization.jsonObject(with:JSONEncoder().encode(key)),"samples":result.evidence.filter{$0.key==key}.count,"name":suggestion?.name as Any? ?? NSNull(),"support":suggestion?.evidenceCount ?? 0,"automatic":suggestion?.groupConsistent ?? false,"conflict":matcher.conflictingEvidence(key)]
    }
    return ["session":result.session,"groups":groups,"skipped":result.skipped,"capture":false,"cloud":false,"original_files_modified":false]
}


@MainActor private func automaticVoiceServiceChecks(directory:URL) async throws->[String] {
    let automatic=try await automaticVoiceServiceCase(directory:directory,manualSource:false)
    let manual=try await automaticVoiceServiceCase(directory:directory,manualSource:true)
    return automatic+manual.map{"confirmed_source_"+$0}
}

@MainActor private func automaticVoiceServiceCase(directory:URL,manualSource:Bool) async throws->[String] {
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:name)};checks.append(name)}
    let policy=VoiceprintLearningPolicy(),priorPermission=UserDefaults.standard.object(forKey:VoiceprintLearningPolicy.preferenceKey)
    policy.setEnabled(true)
    defer {if let priorPermission {UserDefaults.standard.set(priorPermission,forKey:VoiceprintLearningPolicy.preferenceKey)}else{UserDefaults.standard.removeObject(forKey:VoiceprintLearningPolicy.preferenceKey)}}
    let base=directory.appendingPathComponent(UUID().uuidString),session=UUID().uuidString
    let folder=base.appendingPathComponent("SessionCache").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    func vector(_ x:Double,_ y:Double)->[Double] {var v=[Double](repeating:0,count:192);v[0]=x;v[1]=y;return v}
    var otherVector=[Double](repeating:0,count:192);otherVector[2]=1
    let primary=UUID().uuidString,other=UUID().uuidString,time="2026-10-14T00:00:00Z",domain="synthetic_model_output"
    func sample(_ session:String,_ index:Int,_ value:[Double])->VoiceprintSample {VoiceprintSample(session:session,source:"mic",epoch:"synthetic",start:Double(index*3),end:Double(index*3+2),vector:value)}
    let baseline=VoiceprintArchive(schema:1,partition:SpeakerEmbeddingBackend.partition,inputKind:domain,revision:1,people:[
        VoiceprintPerson(id:primary,name:"合成学习人物",authorizedAt:time,enabled:true,samples:(0..<3).map{sample("human-baseline",$0,vector(1,0))}),
        VoiceprintPerson(id:other,name:"合成负比较人物",authorizedAt:time,enabled:true,samples:(0..<3).map{sample("human-other",$0,otherVector)})])
    let heldOut=(0..<3).map{sample("human-held-out",$0,vector(0.55,sqrt(1-0.55*0.55)))}
    let old=try archiveAddingVoiceConfirmation(baseline,contribution:VoiceprintLearningContribution(confirmationID:UUID().uuidString,personID:primary,name:"合成学习人物",confirmedAt:time,samples:heldOut),domain:domain)
    let store=VoiceprintArchiveStore(folder:base.appendingPathComponent("Voiceprints"),domain:domain)
    try store.save(old,expectAbsent:true)
    let key=SessionSpeakerKey(session:session,source:"mic",epoch:"synthetic",identity:"slot:0")
    let events=(0..<(manualSource ? 4:3)).map{i -> [String:Any] in ["type":"segment","session":session,"segment_id":"automatic-\(i)","revision":1,"source_id":"mic","track":"mic","epoch":key.epoch,"start":Double(i*3),"end":Double(i*3+2),"final":true,"end_time_known":true,"text":"独立合成新声音\(i)","speaker":["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":key.epoch]]}
    let waveform=(0..<160000).map{Int16(6000*sin(Double($0)*0.07))}
    let pcm=waveform.withUnsafeBytes{Data($0)}
    try pcm.write(to:folder.appendingPathComponent("mic-000000.pcm"))
    try JSONSerialization.data(withJSONObject:["session":session,"capture_origin_uptime":0.0]).write(to:folder.appendingPathComponent("meeting.json"))
    try JSONSerialization.data(withJSONObject:["schema":1,"track":"mic","format":"pcm_s16le","sample_rate":16000,"channels":1,"ended":true,"written_bytes":pcm.count,"asr_committed_bytes":pcm.count,"origin_uptime":0.0,"chunks":[["index":0,"start_sample":0,"bytes":pcm.count,"sha256":historicalVoiceHash(pcm)]]]).write(to:folder.appendingPathComponent("mic-manifest.json"))
    var raw=Data();for event in events {raw.append(try JSONSerialization.data(withJSONObject:event));raw.append(10)}
    try raw.write(to:folder.appendingPathComponent("mic-transcript.jsonl"))
    let request=SavedVoiceRecognitionRequest(folder:folder.path,session:session,inputKind:domain,keys:[key],sampleLimit:24)
    let result=try SavedVoiceRecognition.run(request,extract:{_ in vector(0.8,0.6)})
    var matcher=VoiceprintMatcher(archive:old);matcher.reset(session:session);matcher.importSavedEvidence(result.evidence)
    var names=SessionNames();for event in events {names.register(segment:event["segment_id"] as! String,item:event)}
    guard let candidate=matcher.suggestion(key),names.reconcileAutoVoiceprint(key:key,candidate:candidate) else{throw Failure(code:"automatic_service_source_decision")}
    if manualSource {
        _=names.renameSpeaker(key:key,name:"合成学习人物")
        // Learning intent survives on a separate manually named source turn;
        // its missing audio is not among the three new acoustic references.
        names.attachConfirmation(segmentIDs:["automatic-3"],name:"合成学习人物",learn:true)
    }
    let file=folder.appendingPathComponent("session-names.json")
    try names.snapshot(session:session).write(to:file)
    let service=VoiceprintRecommendationService(store:store),job=SpeakerRefinementJob(),token=job.reserve()
    var learned:Result<[[String:Any]],Error>?
    service.learnSaved(result:result,folder:folder,job:job,token:token){learned=$0}
    for _ in 0..<500 where learned==nil {try await Task.sleep(nanoseconds:10_000_000)}
    guard let learned else{throw Failure(code:"automatic_service_timeout")}
    let report=try learned.get(),updated=try store.load()!
    try check(report.contains{$0["status"] as? String=="automatic_verified"} && updated.learning?.contributions.filter{$0.automatic != nil}.count==1,"saved_service_commits_only_cross_meeting_verified_automatic_supplement")
    try check(updated.people==old.people && updated.learning?.baseline==old.learning?.baseline,"automatic_service_keeps_every_human_reference_and_manual_projection")
    try check((updated.scores(heldOut[0].vector,excludingSession:"human-held-out").first?.1 ?? 0)>=0.60 && (old.scores(heldOut[0].vector,excludingSession:"human-held-out").first?.1 ?? 1)<0.60,"automatic_service_improves_an_independently_human_labelled_other_meeting")
    let changed=manualSource ? names.renameSpeaker(key:key,name:"人工更正人物"):names.dismissAutoName(key)
    try check(changed,"automatic_service_source_can_be_retracted")
    let withdrawnData=try names.snapshot(session:session);try withdrawnData.write(to:file)
    policy.setEnabled(false)
    var synchronized:Result<String,Error>?
    service.synchronize(session:session,confirmations:[],sourceFolder:folder,sourceNames:withdrawnData){synchronized=$0}
    for _ in 0..<500 where synchronized==nil {try await Task.sleep(nanoseconds:10_000_000)}
    guard let synchronized else{throw Failure(code:"automatic_service_retraction_timeout")};_ = try synchronized.get()
    let withdrawn=try store.load()!,automaticID=updated.learning!.contributions.first{$0.automatic != nil}!.confirmationID
    try check(withdrawn.learning!.revokedConfirmationIDs.contains(automaticID) && (withdrawn.scores(heldOut[0].vector,excludingSession:"human-held-out").first?.1 ?? 1)<0.60,"source_name_retraction_with_learning_off_removes_automatic_effect_and_retains_human_anchors")
    try check(try Data(contentsOf:folder.appendingPathComponent("mic-000000.pcm"))==pcm,"automatic_service_never_changes_original_audio")
    return checks
}
