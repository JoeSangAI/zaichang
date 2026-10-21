import AppKit

@MainActor func speakerConfirmationChecks(directory:URL)throws->[String:Any] {
    guard Credential.offline,directory.path.contains("/.runtime/") else{throw Failure(code:"confirmation_checks_scope")}
    let previousPolicy=UserDefaults.standard.object(forKey:VoiceprintLearningPolicy.preferenceKey)
    VoiceprintLearningPolicy().setEnabled(true)
    defer {if let previousPolicy {UserDefaults.standard.set(previousPolicy,forKey:VoiceprintLearningPolicy.preferenceKey)}else{UserDefaults.standard.removeObject(forKey:VoiceprintLearningPolicy.preferenceKey)}}
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let fixtureDirectory=directory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:fixtureDirectory,withIntermediateDirectories:true)
    var checks:[String]=[]
    func check(_ value:Bool,_ label:String)throws {guard value else{throw Failure(code:label)};checks.append(label)}
    let ref=SharedPersonReference(id:"person:1234567890abcdef1234",name:"合成人物",evidence:["/synthetic/people.md:3"])
    let session="confirmation-fixture",cache=UUID().uuidString
    func event(_ index:Int)->[String:Any] {
        let lo=Double(index*4),hi=lo+2.2
        let vector=[1.0]+Array(repeating:0.0,count:191)
        return ["type":"segment","session":session,"source_id":"mic","track":"mic","epoch":"confirmation-epoch","segment_id":"confirmed-\(index)","revision":1,"start":lo,"end":hi,"end_time_known":true,"final":true,"quality_flags":[],"text":"这是第\(index)段合成发言。","speaker":["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":"confirmation-epoch"],"identity_features":["partition":SpeakerEmbeddingBackend.partition,"input_kind":"synthetic_model_output","source_id":"mic","epoch":"confirmation-epoch","evidence_start":lo,"evidence_end":hi,"quality_gate":"single_model_slot_asr_final_unclipped","values":vector]]
    }
    var names=SessionNames();for i in 0..<4 {names.register(segment:"confirmed-\(i)",item:event(i))}
    try check(names.confirmSegments(["confirmed-0"],name:ref.name,person:ref,learn:true),"explicit_confirmation_records_shared_identity")
    try check(names.personReference(segment:"confirmed-0")==ref && names.personReference(segment:"confirmed-1")==nil,"identity_is_scoped_to_confirmed_text")
    var restored=SessionNames();for i in 0..<4 {restored.register(segment:"confirmed-\(i)",item:event(i))}
    try restored.restore(names.snapshot(session:session),session:session)
    try check(restored.personReference(segment:"confirmed-0")==ref && restored.canUndo,"identity_and_undo_survive_restart")
    _=restored.undo()
    try check(restored.personReference(segment:"confirmed-0")==nil && restored.voiceConfirmations.isEmpty && restored.name(segment:"confirmed-0")==nil,"reopened_undo_restores_name_reference_and_learning_intent")
    _=names.confirmSegments(["confirmed-0"],name:"临时更正",learn:false)
    try check(names.personReference(segment:"confirmed-0")==nil && names.voiceConfirmations.isEmpty,"different_name_revokes_previous_identity_and_learning")
    _=names.undo()
    try check(names.personReference(segment:"confirmed-0")==ref && names.voiceConfirmations.count==1,"undo_correction_restores_original_confirmation")
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    let view=Delegate();view.previewRenderOnly=true;view.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    let cacheRoot=fixtureDirectory.appendingPathComponent("SessionCache")
    try FileManager.default.createDirectory(at:cacheRoot.appendingPathComponent(cache),withIntermediateDirectories:true)
    try JSONSerialization.data(withJSONObject:["session":session,"cache_id":cache]).write(to:cacheRoot.appendingPathComponent(cache).appendingPathComponent("meeting.json"))
    view.recoveryRootOverride=cacheRoot
    let store=VoiceprintArchiveStore(folder:fixtureDirectory.appendingPathComponent("Voiceprints"),domain:"synthetic_model_output")
    view.voiceprintService=VoiceprintRecommendationService(store:store)
    view.receive(["type":"started","session":session,"cache_id":cache,"mode":"cloud"])
    for i in 0..<3 {view.receive(event(i))}
    view.voiceprintService!.queue.sync{}
    try view.settleTranscriptForOfflineReview()
    try check(try store.load()==nil,"model_predictions_do_not_enroll_people")
    func pump(_ until:()->Bool)throws {
        let end=Date().addingTimeInterval(5)
        while !until(),Date()<end {_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}
        guard until() else{throw Failure(code:"confirmation_async_timeout")}
    }
    func flushNames()throws {
        var done=false;var failure:Error?
        view.persistSessionNames{result in if case .failure(let error)=result {failure=error};done=true}
        try pump{done};if let failure {throw failure};view.voiceprintService?.queue.sync{}
        _=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))
    }
    let controller=SpeakerConfirmationController(owner:view);view.confirmationController=controller;controller.present(segment:"confirmed-0")
    controller.showCandidates([SharedPersonCandidate(reference:ref,organization:"合成组织")])
    let choice=controller.candidates.arrangedSubviews.first as! NSButton;choice.performClick(nil)
    controller.learn.state = .on
    try check(view.naming.voiceConfirmations.isEmpty,"selecting_candidate_does_not_confirm_or_train")
    controller.commit();try pump{view.naming.personReference(segment:"confirmed-0")==ref && !view.confirmationController!.field.isEnabled}
    view.cacheWriteQueue.sync{};try pump{(try? store.load()) != nil}
    view.voiceprintService!.queue.sync{}
    try check((try store.load())!.people.isEmpty,"one_confirmed_sample_does_not_claim_voice_ready")
    try check(view.naming.name(segment:"confirmed-1")==nil,"default_confirmation_does_not_rename_other_turns")
    for i in 1..<3 {_=view.naming.confirmSegments(["confirmed-\(i)"],name:ref.name,person:ref,learn:true);try flushNames()}
    let ready=try store.load()!
    try check(ready.people.count==1 && ready.people[0].sharedPerson==ref && ready.people[0].samples.count==3,"three_explicit_independent_confirmations_enable_same_shared_person")
    view.receive(event(3));view.voiceprintService!.queue.sync{}
    try check((try store.load())!.people[0].samples.count==3,"future_unconfirmed_speech_is_not_training_data")
    view.undoName();view.cacheWriteQueue.sync{};try pump{(try? store.load())?.people.isEmpty==true}
    try check(view.naming.name(segment:"confirmed-2")==nil && view.naming.personReference(segment:"confirmed-2")==nil,"undo_removes_current_name_and_reference")
    let afterUndo=try store.load()!
    try check(afterUndo.learning?.contributions.count==3 && afterUndo.people.isEmpty,"undo_removes_effective_voice_without_destroying_other_contributions")
    // Simulate crash after the durable names write but before the voice write.
    view.voiceprintService=nil
    _=view.naming.undo();try flushNames()
    let fresh=VoiceprintRecommendationService(store:store)
    var readDone=false;var recovered:VoiceprintArchive?
    fresh.profiles{value,_ in recovered=value;readDone=true};try pump{readDone}
    try check(recovered?.learning?.revokedConfirmationIDs.count==2,"restart_reconciles_interrupted_voice_retraction_from_saved_names")
    let imageController=SpeakerConfirmationController(owner:view);imageController.present(segment:"confirmed-0");imageController.showCandidates([SharedPersonCandidate(reference:ref,organization:"合成组织")])
    let imageView=imageController.popover.contentViewController!.view
    imageView.appearance=NSAppearance(named:.aqua)
    imageView.wantsLayer=true
    imageView.appearance!.performAsCurrentDrawingAppearance {imageView.layer!.backgroundColor=NSColor.windowBackgroundColor.cgColor}
    imageView.frame=NSRect(origin:.zero,size:imageView.fittingSize);imageView.layoutSubtreeIfNeeded();imageView.displayIfNeeded()
    guard let bitmap=imageView.bitmapImageRepForCachingDisplay(in:imageView.bounds) else{throw Failure(code:"confirmation_snapshot_failed")}
    imageView.cacheDisplay(in:imageView.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("confirmation-popover.png"))
    try check(imageView.fittingSize.width<=360 && imageView.fittingSize.height<430,"native_confirmation_has_compact_bounds")
    imageView.appearance=NSAppearance(named:.darkAqua)
    imageView.appearance!.performAsCurrentDrawingAppearance {imageView.layer!.backgroundColor=NSColor.windowBackgroundColor.cgColor}
    imageView.displayIfNeeded()
    let dark=imageView.bitmapImageRepForCachingDisplay(in:imageView.bounds)!
    imageView.cacheDisplay(in:imageView.bounds,to:dark)
    try dark.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("confirmation-dark.png"))
    let longRef=SharedPersonReference(id:ref.id,name:String(repeating:"合成姓名",count:15),evidence:ref.evidence)
    imageController.showCandidates([SharedPersonCandidate(reference:longRef,organization:String(repeating:"合成组织",count:10))])
    try check(imageView.fittingSize.width<=360,"long_candidate_does_not_expand_popover_beyond_compact_width")
    imageController.field.stringValue="  "
    imageController.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:imageController.field))
    try check(imageController.candidates.arrangedSubviews.isEmpty && !imageController.confirm.isEnabled && imageController.status.stringValue=="输入姓名，或选择已有的人。","empty_name_clears_candidates_without_false_lookup_error")
    let otherCache=cacheRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:otherCache,withIntermediateDirectories:true)
    try JSONSerialization.data(withJSONObject:["session":"unrelated-history"]).write(to:otherCache.appendingPathComponent("meeting.json"))
    try Data("broken names".utf8).write(to:otherCache.appendingPathComponent("session-names.json"))
    let cleanReader=VoiceprintRecommendationService(store:store);var cleanDone=false;var cleanArchive:VoiceprintArchive?
    cleanReader.profiles{value,_ in cleanArchive=value;cleanDone=true};try pump{cleanDone}
    try check(cleanArchive != nil,"unrelated_damaged_history_does_not_disable_voice_memory")
    let isolatedStore=VoiceprintArchiveStore(folder:fixtureDirectory.appendingPathComponent("cross-session/Voiceprints"),domain:"synthetic_model_output")
    let concurrentService=VoiceprintRecommendationService(store:isolatedStore);concurrentService.reset(session)
    concurrentService.observe(event(0)){_,_,_,_ in};concurrentService.queue.sync{}
    let activeRecord=SessionVoiceConfirmation(id:UUID().uuidString,session:session,name:ref.name,person:ref,segmentIDs:["confirmed-0","confirmed-1","confirmed-2"],createdAt:ISO8601DateFormatter().string(from:Date()))
    concurrentService.synchronize(session:session,confirmations:[activeRecord]){_ in};concurrentService.queue.sync{}
    concurrentService.synchronize(session:"other-history",confirmations:[]){_ in};concurrentService.cancelPendingMemory(session:"other-history")
    for i in 1..<3 {concurrentService.observe(event(i)){_,_,_,_ in}}
    concurrentService.queue.sync{}
    try check((try isolatedStore.load())?.people.first?.samples.count==3,"historical_retraction_preserves_current_confirmed_pending_samples")
    // A failed disk write must not loosen the conflict guard on a retry.
    let retry=Delegate();retry.previewRenderOnly=true;retry.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    retry.recoveryRootOverride=fixtureDirectory.appendingPathComponent("retry/SessionCache")
    retry.activeSession=session;retry.currentCacheID=UUID().uuidString
    retry.voiceprintService=VoiceprintRecommendationService(store:VoiceprintArchiveStore(folder:fixtureDirectory.appendingPathComponent("retry/Voiceprints"),domain:"synthetic_model_output"))
    for i in 0..<4 {retry.receive(event(i))}
    retry.naming.set(segment:"confirmed-0",name:"人工甲");retry.naming.set(segment:"confirmed-1",name:"人工乙")
    try retry.settleTranscriptForOfflineReview()
    let retryController=SpeakerConfirmationController(owner:retry);retry.confirmationController=retryController;retryController.present(segment:"confirmed-0")
    try check(!retryController.scope.isEnabled,"manual_conflict_disables_group_before_save")
    retryController.field.stringValue="人工丙";retryController.learn.state = .off;retryController.commit()
    try pump{retryController.field.isEnabled && retryController.status.stringValue.contains("未保存")}
    try check(!retryController.scope.isEnabled && retry.naming.name(segment:"confirmed-1")=="人工乙","save_failure_preserves_original_group_conflict_guard")
    let retryFolder=retry.recoveryBase().appendingPathComponent(retry.currentCacheID!)
    try FileManager.default.createDirectory(at:retryFolder,withIntermediateDirectories:true)
    retryController.scope.state = .on;retryController.commit();retry.cacheWriteQueue.sync{}
    try pump{retry.naming.name(segment:"confirmed-0")=="人工丙" && !retryController.field.isEnabled}
    try check(retry.naming.name(segment:"confirmed-1")=="人工乙" && retry.naming.name(segment:"confirmed-2")==nil,"retry_cannot_expand_into_manually_conflicting_group")
    retry.isHistoryReader=true
    let historical=SpeakerConfirmationController(owner:retry);historical.present(segment:"confirmed-0")
    try check(historical.learn.isEnabled && historical.learn.state == .on,"historical_learning_reuses_explicit_standing_local_permission")
    retry.newMeetingRequested=true
    let finishing=SpeakerConfirmationController(owner:retry);finishing.present(segment:"confirmed-0")
    try check(!finishing.learn.isEnabled && finishing.learn.state == .off,"historical_learning_disabled_while_pending_new_meeting")
    retry.newMeetingRequested=false
    retry.isHistoryReader=false
    var overlap=event(4);overlap["speaker"]=["basis":"multiple","reason":"overlap"]
    retry.receive(overlap);try retry.settleTranscriptForOfflineReview()
    let mixed=SpeakerConfirmationController(owner:retry);mixed.present(segment:"confirmed-4")
    try check(!mixed.learn.isEnabled && mixed.learn.state == .off,"overlapping_speech_does_not_offer_voice_training")
    retry.showTransientFeedback("姓名已保存",nameUndo:true)
    try check(!retry.diagnostic.isHidden && retry.feedbackUndoButton?.isHidden==false,"confirmation_success_shows_lightweight_undo")
    retry.showTransientFeedback("文件夹已打开")
    try check(retry.feedbackUndoButton?.isHidden==true,"unrelated_feedback_does_not_offer_voice_undo")
    for i in 5..<100 {retry.receive(event(i))}
    try retry.settleTranscriptForOfflineReview()
    retry.output.scrollRangeToVisible(NSRange(location:0,length:1))
    let scrolling=SpeakerConfirmationController(owner:retry);scrolling.present(segment:"confirmed-0")
    retry.cancelTranscriptReadingRestore();retry.output.scrollToEndOfDocument(nil)
    let intendedY=retry.scroll.contentView.bounds.origin.y
    scrolling.popoverDidClose(Notification(name:NSPopover.didCloseNotification))
    try check(intendedY>100 && abs(retry.scroll.contentView.bounds.origin.y-intendedY)<1,"closing_confirmation_preserves_user_new_scroll_position")
    retry.window.close()
    let detached=Delegate();detached.previewRenderOnly=true;detached.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    detached.recoveryRootOverride=fixtureDirectory.appendingPathComponent("detached-missing/SessionCache")
    detached.currentCacheID=UUID().uuidString;detached.activeSession=session
    detached.voiceprintService=VoiceprintRecommendationService(store:VoiceprintArchiveStore(folder:fixtureDirectory.appendingPathComponent("detached/Voiceprints"),domain:"synthetic_model_output"))
    for i in 0..<4 {detached.receive(event(i))};try detached.settleTranscriptForOfflineReview()
    let blockedWrite=DispatchSemaphore(value:0)
    detached.cacheWriteQueue.async{_ = blockedWrite.wait(timeout:.now()+5)}
    var temporary:SpeakerConfirmationController?=SpeakerConfirmationController(owner:detached)
    detached.confirmationController=temporary;temporary!.present(segment:"confirmed-0");temporary!.field.stringValue="未保存的人工名";temporary!.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:temporary!.field));temporary!.learn.state = .off;temporary!.commit()
    try check(detached.naming.name(segment:"confirmed-0")=="未保存的人工名","detached_save_probe_reaches_real_pending_confirmation")
    weak var released=temporary
    detached.showSpeakerConfirmation("confirmed-1");temporary=nil
    try check(released==nil,"changing_confirmation_releases_previous_editor")
    blockedWrite.signal()
    try pump{detached.naming.name(segment:"confirmed-0")==nil && detached.diagnostic.stringValue.contains("未保存")}
    try check(detached.naming.voiceConfirmations.isEmpty && !detached.diagnostic.isHidden,"failed_save_rolls_back_and_reports_after_editor_is_released")
    detached.window.close()
    checks += try voiceprintLearningChecks(directory:directory.appendingPathComponent("learning"))
    let shared=try sharedPersonIdentityChecks()
    view.window.close()
    return ["type":"speaker_confirmation_checks","passed":checks.count,"checks":checks,"shared_person_checks":shared,"capture":false,"cloud":false,"real_profiles_changed":false,"native_offscreen":true]
}

@MainActor func quickVoiceConfirmationChecks(directory:URL,interactive:Bool=false) async throws->[String] {
    guard Credential.offline,directory.path.contains("/.runtime/") else{throw Failure(code:"quick_voice_fixture_scope")}
    let policy=VoiceprintLearningPolicy(),previousPolicy=UserDefaults.standard.object(forKey:VoiceprintLearningPolicy.preferenceKey)
    policy.setEnabled(false)
    defer {if let previousPolicy {UserDefaults.standard.set(previousPolicy,forKey:VoiceprintLearningPolicy.preferenceKey)}else{UserDefaults.standard.removeObject(forKey:VoiceprintLearningPolicy.preferenceKey)}}
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    let base=directory.appendingPathComponent("quick-voice-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:name)};checks.append(name)}
    let vector=[1.0]+Array(repeating:0.0,count:191),personID=UUID().uuidString
    let archive=VoiceprintArchive(schema:1,partition:SpeakerEmbeddingBackend.partition,inputKind:"synthetic_model_output",revision:1,people:[VoiceprintPerson(id:personID,name:"合成人物",authorizedAt:"2026-10-14T00:00:00Z",enabled:true,samples:(0..<3).map{VoiceprintSample(session:"synthetic-training",source:"mic",epoch:"old",start:Double($0*4),end:Double($0*4+3),vector:vector)})])
    let store=VoiceprintArchiveStore(folder:base.appendingPathComponent("Voiceprints"),domain:"synthetic_model_output")
    try store.save(archive,expectAbsent:true)
    let originalArchive=try Data(contentsOf:store.file)
    func makeView()throws->(Delegate,SessionSpeakerKey) {
        let session=UUID().uuidString,cache=UUID().uuidString,folder=base.appendingPathComponent(cache)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:["session":session,"cache_id":cache]).write(to:folder.appendingPathComponent("meeting.json"))
        let view=Delegate();view.previewRenderOnly=true;view.isHistoryReader=true;view.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));view.recoveryRootOverride=base
        view.voiceprintService=VoiceprintRecommendationService(store:store)
        view.receive(["type":"started","session":session,"cache_id":cache,"capture":false])
        for i in 0..<4 {view.receive(["type":"segment","session":session,"segment_id":"quick-\(i)","revision":1,"source_id":"mic","track":"mic","epoch":"quick","start":Double(i*4),"end":Double(i*4+3),"final":true,"end_time_known":true,"text":"这是第\(i)段合成发言。","speaker":["basis":"anonymous_cluster","source_id":"mic","epoch":"quick","cluster_id":i==3 ? 1:0]])}
        view.phase.phase = .stopped
        try view.settleTranscriptForOfflineReview()
        let key=SessionSpeakerKey(session:session,source:"mic",epoch:"quick",identity:"slot:0")
        let candidate=VoiceprintRecommendation(personID:personID,name:"合成人物",archiveRevision:1,evidenceCount:3,support:(0..<3).map{VoiceprintEvidenceRef(id:"quick-\($0)",revision:1)},groupConsistent:false)
        view.voiceprintCandidates[key]=candidate;view.voiceprintSuggestionArchive=archive
        _ = view.naming.reconcileAutoVoiceprint(key:key,candidate:candidate)
        view.refreshQuickVoiceCandidate()
        view.cacheWriteQueue.sync{}
        return (view,key)
    }
    func waitFor(_ predicate:()->Bool) async throws {
        for _ in 0..<300 {if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(code:"quick_voice_save_timeout")
    }
    func editor(_ view:Delegate)->SpeakerConfirmationController {
        let controller=SpeakerConfirmationController(owner:view);view.confirmationController=controller
        controller.present(segment:"quick-0",showPopover:false);return controller
    }
    let (view,key)=try makeView(),controller=editor(view)
    try check(view.voiceCandidateButton?.isHidden==false && view.voiceCandidateButton?.title=="合成人物？","quick_candidate_is_available_directly_above_transcript")
    try check(controller.field.isHidden && controller.learn.isHidden && controller.scope.isHidden && controller.confirm.title=="确认" && controller.status.isHidden,"quick_confirmation_starts_without_name_form_scope_checkboxes_or_learning_controls")
    try check(view.naming.name(speaker:key)==nil && view.naming.voiceConfirmations.isEmpty,"opening_quick_confirmation_never_confirms_or_enrolls")
    try check(controller.popover.contentSize.width==324 && controller.popover.contentSize.height<=250,"quick_confirmation_has_compact_native_bounds")
    if let content=controller.popover.contentViewController?.view {
        let window=NSWindow(contentRect:NSRect(origin:.zero,size:controller.popover.contentSize),styleMask:[],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=content;content.layoutSubtreeIfNeeded()
        if let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) {content.cacheDisplay(in:content.bounds,to:bitmap);if let data=bitmap.representation(using:.png,properties:[:]) {try data.write(to:directory.appendingPathComponent("quick-voice-confirmation.png"))}}
        window.contentView=nil;window.close()
    }
    controller.commit()
    try await waitFor{view.diagnostic.stringValue.contains("已确认")}
    try check(view.naming.name(speaker:key)=="合成人物" && view.naming.name(segment:"quick-3")==nil,"quick_confirmation_names_only_the_displayed_group")
    let saved=try Data(contentsOf:base.appendingPathComponent(view.currentCacheID!).appendingPathComponent("session-names.json"))
    var restored=SessionNames()
    for id in view.sequence {if let item=view.segments[id] {restored.register(segment:id,item:item)}}
    try restored.restore(saved,session:key.session)
    try check(restored.name(speaker:key)=="合成人物" && restored.voiceConfirmations.isEmpty,"quick_name_survives_reopen_without_voice_learning_authorization")
    view.undoName();try await waitFor{!view.quickVoiceUndoPending}
    try check(view.naming.name(speaker:key)==nil && view.naming.autoNameIsSuppressed(key),"quick_undo_uses_name_history_and_keeps_unconfirmed_group_suppressed")
    let (edited,editedKey)=try makeView(),edit=editor(edited)
    edit.editQuickName();edit.field.stringValue="正确姓名";edit.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:edit.field));edit.commit()
    try await waitFor{edited.diagnostic.stringValue.contains("已确认")}
    try check(edited.naming.name(speaker:editedKey)=="正确姓名" && edited.naming.voiceConfirmations.isEmpty,"quick_correction_reveals_name_field_only_on_request")
    let editFile=base.appendingPathComponent(edited.currentCacheID!).appendingPathComponent("session-names.json"),editBackup=editFile.appendingPathExtension("fixture-backup")
    edited.cacheWriteQueue.sync{}
    try FileManager.default.moveItem(at:editFile,to:editBackup);try FileManager.default.createDirectory(at:editFile,withIntermediateDirectories:true)
    edited.undoName();try await waitFor{!edited.quickVoiceUndoPending}
    try check(edited.naming.name(speaker:editedKey)=="正确姓名","failed_quick_undo_restores_confirmed_name_actual_\(edited.naming.name(speaker:editedKey) ?? "nil")")
    try check(edited.quickVoiceUndoScope != nil,"failed_quick_undo_restores_retry_receipt")
    try check(edited.diagnostic.stringValue.contains("撤销未保存"),"failed_quick_undo_keeps_failure_feedback_actual_\(edited.diagnostic.stringValue)")
    try FileManager.default.removeItem(at:editFile);try FileManager.default.moveItem(at:editBackup,to:editFile)
    edited.undoName();try await waitFor{!edited.quickVoiceUndoPending}
    try check(edited.naming.name(speaker:editedKey)==nil,"failed_quick_undo_can_be_retried_after_storage_recovers")
    let (failed,failedKey)=try makeView(),retry=editor(failed)
    let failedNames=base.appendingPathComponent(failed.currentCacheID!).appendingPathComponent("session-names.json")
    try FileManager.default.removeItem(at:failedNames)
    try FileManager.default.createDirectory(at:failedNames,withIntermediateDirectories:true)
    retry.commit()
    try await waitFor{retry.field.isEnabled && retry.status.stringValue.contains("未保存")}
    try check(failed.naming.name(speaker:failedKey)==nil && failed.naming.voiceConfirmations.isEmpty && retry.confirm.isEnabled,"failed_quick_save_restores_candidate_and_keeps_retry_available")
    let (switched,switchedKey)=try makeView(),stale=editor(switched)
    switched.currentCacheID=UUID().uuidString;stale.commit()
    try check(switched.naming.name(speaker:switchedKey)==nil,"old_quick_editor_cannot_confirm_after_cache_switch")
    let (during,_)=try makeView(),late=editor(during),gate=DispatchSemaphore(value:0)
    during.cacheWriteQueue.async{gate.wait()}
    late.commit();during.currentCacheID=UUID().uuidString;during.activeSession="next-fixture";during.naming.reset();gate.signal()
    var drained=false;during.cacheWriteQueue.async{DispatchQueue.main.async{drained=true}}
    try await waitFor{drained}
    try check(during.naming.values.isEmpty && !during.diagnostic.stringValue.contains("已确认"),"quick_save_callback_cannot_rewrite_or_announce_success_in_next_document")
    let (rejected,rejectedKey)=try makeView(),rejectEditor=editor(rejected)
    rejectEditor.rejectQuickVoice()
    try await waitFor{rejected.diagnostic.stringValue=="已移除候选"}
    try check(rejected.naming.autoNameIsSuppressed(rejectedKey) && rejected.naming.name(speaker:rejectedKey)==nil,"quick_rejection_removes_candidate_without_naming_or_learning")
    try check(try Data(contentsOf:store.file)==originalArchive,"quick_open_confirm_correct_reject_and_undo_leave_voice_archive_unchanged")
    let (learningView,learningKey)=try makeView()
    learningView.receive(["type":"segment","session":learningKey.session,"segment_id":"quick-unsupported","revision":1,"source_id":"mic","track":"mic","epoch":"quick","start":20.0,"end":23.0,"final":true,"end_time_known":true,"text":"未参与候选的合成发言。","speaker":["basis":"anonymous_cluster","source_id":"mic","epoch":"quick","cluster_id":0]])
    try learningView.settleTranscriptForOfflineReview()
    policy.setEnabled(true)
    let learningEditor=editor(learningView);learningEditor.commit()
    try await waitFor{learningView.diagnostic.stringValue.contains("已确认")}
    try check(learningView.naming.name(segment:"quick-unsupported")=="合成人物" && Set(learningView.naming.voiceConfirmations.last?.segmentIDs ?? [])==Set((0..<3).map{"quick-\($0)"}),"standing_permission_quick_confirmation_learns_only_candidate_support")
    learningView.undoName();try await waitFor{!learningView.quickVoiceUndoPending}
    try check(learningView.naming.voiceConfirmations.isEmpty && learningView.naming.name(speaker:learningKey)==nil,"standing_permission_quick_undo_retracts_learning_intent")
    policy.setEnabled(false)
    for item in [view,edited,failed,switched,during,rejected,learningView] {item.confirmationController?.cancelQuickInteraction();item.window.close();item.sheet.close()}
    if interactive {
        let (preview,_)=try makeView();preview.previewRenderOnly=false
        NSApp.setActivationPolicy(.regular);preview.window.center();preview.window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        preview.showQuickVoiceConfirmation()
        for _ in 0..<1200 {if !preview.window.isVisible {break};try await Task.sleep(nanoseconds:100_000_000)}
        preview.confirmationController?.cancelQuickInteraction();preview.window.orderOut(nil);preview.sheet.close()
        checks.append("quick_confirmation_native_preview_opened_without_capture_or_cloud")
    }
    return checks
}
