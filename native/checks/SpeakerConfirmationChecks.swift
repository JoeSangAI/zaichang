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
    // Clicking a speaker's name: the whole person, later turns included, in one step.
    func voice(_ cosine:Double,_ axis:Int=0)->[Double] {
        var vector=[Double](repeating:0,count:192);vector[axis]=cosine;vector[axis+1]=(1-cosine*cosine).squareRoot();return vector
    }
    let wholeSession="whole-speaker-fixture",wholeCache=UUID().uuidString
    try FileManager.default.createDirectory(at:cacheRoot.appendingPathComponent(wholeCache),withIntermediateDirectories:true)
    try JSONSerialization.data(withJSONObject:["session":wholeSession,"cache_id":wholeCache]).write(to:cacheRoot.appendingPathComponent(wholeCache).appendingPathComponent("meeting.json"))
    func spoken(_ index:Int,slot:Int,source:String="mic",vector:[Double],revision:Int=1,text:String?=nil)->[String:Any] {
        let lo=Double(index*4),hi=lo+2.2
        return ["type":"segment","session":wholeSession,"source_id":source,"track":source,"epoch":"whole-epoch","segment_id":"w-\(index)","revision":revision,"start":lo,"end":hi,"end_time_known":true,"final":true,"quality_flags":[],"text":text ?? "这是第\(index)段合成发言。","speaker":["basis":"anonymous_cluster","cluster_id":slot,"source_id":source,"epoch":"whole-epoch"],"identity_features":["partition":SpeakerEmbeddingBackend.partition,"input_kind":"synthetic_model_output","source_id":source,"epoch":"whole-epoch","evidence_start":lo,"evidence_end":hi,"quality_gate":"single_model_slot_asr_final_unclipped","values":vector]]
    }
    let whole=Delegate();whole.previewRenderOnly=true;whole.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    whole.recoveryRootOverride=cacheRoot
    whole.voiceprintService=VoiceprintRecommendationService(store:VoiceprintArchiveStore(folder:fixtureDirectory.appendingPathComponent("whole/Voiceprints"),domain:"synthetic_model_output"))
    whole.receive(["type":"started","session":wholeSession,"cache_id":wholeCache,"mode":"cloud"])
    for i in 0..<3 {whole.receive(spoken(i,slot:0,vector:voice(1)))}
    for i in 3..<6 {whole.receive(spoken(i,slot:1,vector:voice(0.9)))}
    for i in 6..<9 {whole.receive(spoken(i,slot:2,vector:voice(1,5)))}
    whole.voiceprintService!.queue.sync{};_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))
    try whole.settleTranscriptForOfflineReview()
    let slot0=SessionSpeakerKey(session:wholeSession,source:"mic",epoch:"whole-epoch",identity:"slot:0")
    let slot1=SessionSpeakerKey(session:wholeSession,source:"mic",epoch:"whole-epoch",identity:"slot:1")
    let slot2=SessionSpeakerKey(session:wholeSession,source:"mic",epoch:"whole-epoch",identity:"slot:2")
    var speakerLinks:[String]=[]
    whole.output.textStorage?.enumerateAttribute(.link,in:NSRange(location:0,length:whole.output.textStorage!.length)){value,_,_ in if let value=value as? String,value.hasPrefix(speakerLinkPrefix) {speakerLinks.append(value)}}
    try check(speakerLinks.contains(speakerLinkPrefix+"w-0"),"speaker_name_in_transcript_is_a_link_to_rename_the_person")
    try check(whole.textView(whole.output,clickedOnLink:speakerLinkPrefix+"w-0",at:0),"clicking_a_speaker_name_opens_the_editor")
    let wholeEditor=whole.confirmationController!
    try check(wholeEditor.scope.isHidden && wholeEditor.learn.isHidden && wholeEditor.status.stringValue.contains("后面说的也一样"),"speaker_name_editor_defaults_to_the_whole_person_without_options")
    if let content=wholeEditor.popover.contentViewController?.view {
        content.frame=NSRect(origin:.zero,size:content.fittingSize);content.layoutSubtreeIfNeeded()
        if let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) {content.cacheDisplay(in:content.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("whole-speaker-popover.png"))}
        try check(content.fittingSize.width<=360,"speaker_name_editor_stays_compact")
    }
    // While someone keeps talking their own newest turn is revised; that must not block naming them.
    whole.receive(spoken(1,slot:0,vector:voice(1),revision:2,text:"这是修订后的合成发言。"))
    wholeEditor.field.stringValue="合成甲";wholeEditor.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:wholeEditor.field));wholeEditor.commit()
    func wholePump(_ until:()->Bool)throws {
        let end=Date().addingTimeInterval(5)
        while !until(),Date()<end {whole.voiceprintService?.queue.sync{};_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}
        guard until() else{throw Failure(code:"whole_speaker_async_timeout")}
    }
    try check(whole.naming.name(speaker:slot0)=="合成甲" && whole.naming.name(segment:"w-2")=="合成甲","naming_from_the_heading_renames_every_turn_of_that_person")
    try wholePump{whole.diagnostic.stringValue.contains("后面的发言也会用这个名字")}
    whole.receive(spoken(9,slot:0,vector:voice(1)));try whole.settleTranscriptForOfflineReview()
    try check(whole.naming.displayName(segment:"w-9")?.value=="合成甲" && whole.naming.displayName(segment:"w-9")?.origin == .manual,"later_turns_of_a_named_person_carry_the_name")
    try wholePump{whole.naming.displayName(speaker:slot1)?.value=="合成甲"}
    try check(whole.naming.displayName(speaker:slot1)?.origin == .voiceprint && whole.naming.name(speaker:slot1)==nil,"same_voice_in_another_slot_follows_as_a_rejectable_automatic_name")
    try check(whole.naming.displayName(speaker:slot2)==nil,"a_different_voice_does_not_follow")
    try check(whole.naming.voiceConfirmations.allSatisfy{record in record.segmentIDs.allSatisfy{whole.naming.key(segment:$0)==slot0}},"a_followed_slot_is_never_a_training_label")
    try check(!whole.naming.voiceConfirmations.contains{$0.segmentIDs.contains("w-9")},"turns_after_naming_wait_for_the_end_of_capture")
    try check(whole.naming.extendSpeakerConfirmations(session:wholeSession) && whole.naming.voiceConfirmations.contains{$0.segmentIDs.contains("w-9")} && !whole.naming.extendSpeakerConfirmations(session:wholeSession),"end_of_capture_covers_turns_said_since_naming_once")
    try check(whole.textView(whole.output,clickedOnLink:speakerLinkPrefix+"w-0",at:0) && whole.confirmationController!.field.stringValue=="合成甲","reopening_a_named_person_prefills_the_name")
    whole.confirmationController!.field.stringValue="合成乙";whole.confirmationController!.commit()
    try check(whole.naming.name(segment:"w-2")=="合成乙","correcting_the_name_reaches_every_turn")
    try wholePump{whole.naming.displayName(speaker:slot1)?.value=="合成乙"}
    try wholePump{!whole.diagnostic.stringValue.isEmpty && whole.confirmationController?.speakerSaveInFlight != true}
    whole.undoName()
    try wholePump{whole.naming.name(speaker:slot0)=="合成甲" && whole.naming.displayName(speaker:slot1)?.value=="合成甲"}
    whole.undoName()
    try wholePump{whole.naming.name(speaker:slot0)==nil && whole.naming.displayName(speaker:slot1)==nil}
    try check(!whole.naming.autoNameIsSuppressed(slot1),"undoing_the_name_releases_the_followed_group")
    _=whole.textView(whole.output,clickedOnLink:speakerLinkPrefix+"w-0",at:0)
    whole.confirmationController!.field.stringValue="合成丙";whole.confirmationController!.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:whole.confirmationController!.field));whole.confirmationController!.commit()
    try wholePump{whole.naming.displayName(speaker:slot1)?.value=="合成丙" && whole.confirmationController?.speakerSaveInFlight != true}
    whole.rejectVoiceprintRecommendation(slot1)
    try check(whole.naming.displayName(speaker:slot1)==nil && whole.naming.autoNameIsSuppressed(slot1),"rejecting_a_followed_name_sticks")
    try check(whole.textView(whole.output,clickedOnLink:speakerLinkPrefix+"w-6",at:0),"another_person_opens_too")
    let narrowed=whole.confirmationController!
    narrowed.onlyThisForChecks();narrowed.field.stringValue="只这一段";narrowed.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:narrowed.field));narrowed.commit()
    try check(whole.naming.name(segment:"w-6")=="只这一段" && whole.naming.name(segment:"w-7")==nil && whole.naming.name(speaker:slot2)==nil,"only_this_turn_stays_available")
    whole.window.close()
    // The link is deliberately narrow; these are the shapes real meetings produced.
    func linkMatcher(_ rows:[(SessionSpeakerKey,Int,[Double])])->VoiceprintMatcher {
        var matcher=VoiceprintMatcher();matcher.reset(session:wholeSession)
        matcher.importSavedEvidence(rows.map{key,index,vector in SavedVoiceRecognitionEvidence(id:"m-\(key.identity)-\(key.source)-\(index)",revision:1,key:key,sample:VoiceprintSample(session:wholeSession,source:key.source,epoch:key.epoch,start:Double(index*4),end:Double(index*4)+3,vector:vector))})
        return matcher
    }
    func rows(_ key:SessionSpeakerKey,_ vector:[Double],from:Int)->[(SessionSpeakerKey,Int,[Double])] {(from..<from+3).map{(key,$0,vector)}}
    try check(linkMatcher(rows(slot0,voice(1),from:0)+rows(slot1,voice(0.74),from:3)).sessionLink(slot1,manualNames:[slot0:"甲"])==nil,"similar_but_different_voices_do_not_link")
    try check(linkMatcher(rows(slot0,voice(1),from:0)+rows(slot1,voice(0.86),from:3)).sessionLink(slot1,manualNames:[slot0:"甲"])?.name=="甲","same_voice_links_across_slots")
    try check(linkMatcher(rows(slot0,voice(1),from:0)+rows(slot1,voice(0.9),from:3)).sessionLink(slot1,manualNames:[:])==nil,"nothing_links_before_a_human_names_someone")
    let otherChannel=SessionSpeakerKey(session:wholeSession,source:"app-1",epoch:"whole-epoch",identity:"slot:0")
    try check(linkMatcher(rows(otherChannel,voice(1),from:0)+rows(slot1,voice(0.65),from:3)).sessionLink(slot1,manualNames:[otherChannel:"甲"])?.name=="甲","same_person_links_across_microphone_and_computer_audio")
    try check(linkMatcher(rows(otherChannel,voice(1),from:0)+rows(slot1,voice(0.3),from:3)).sessionLink(slot1,manualNames:[otherChannel:"甲"])==nil,"different_people_do_not_link_across_microphone_and_computer_audio")
    try check(linkMatcher(rows(slot0,voice(1),from:0)+rows(slot2,voice(0.95),from:6)+rows(slot1,voice(0.9),from:3)).sessionLink(slot1,manualNames:[slot0:"甲",slot2:"乙"])==nil,"two_named_people_both_close_withhold_the_link")
    // The voice library follows the authoritative names; nothing is lost in a merge.
    let voiceDomain="synthetic_model_output"
    func confirmed(_ name:String,person:String,session:String,source:String,vector:[Double],first:Int=0)->VoiceprintLearningContribution {
        VoiceprintLearningContribution(confirmationID:UUID().uuidString,personID:person,name:name,confirmedAt:ISO8601DateFormatter().string(from:Date()),
            samples:(first..<first+3).map{VoiceprintSample(session:session,source:source,epoch:"lib",start:Double($0*4),end:Double($0*4)+3,vector:vector)})
    }
    let aliasID=UUID().uuidString,canonicalID=UUID().uuidString,otherID=UUID().uuidString,typoID=UUID().uuidString
    var library=try archiveAddingVoiceConfirmation(nil,contribution:confirmed("Alpha",person:aliasID,session:"lib-1",source:"app-37d3b9dbfc68fcaf-g1",vector:voice(1)),domain:voiceDomain)
    library=try archiveAddingVoiceConfirmation(library,contribution:confirmed("合成甲正名",person:canonicalID,session:"lib-2",source:"mic",vector:voice(0.55)),domain:voiceDomain)
    library=try archiveAddingVoiceConfirmation(library,contribution:confirmed("其他人",person:otherID,session:"lib-3",source:"app-37d3b9dbfc68fcaf-g1",vector:voice(1,9)),domain:voiceDomain)
    library=try archiveAddingVoiceConfirmation(library,contribution:confirmed("合成错字 Beta",person:typoID,session:"lib-4",source:"app-37d3b9dbfc68fcaf-g1",vector:voice(1,20)),domain:voiceDomain)
    library=try archiveAddingVoiceConfirmation(library,contribution:confirmed("beta",person:UUID().uuidString,session:"lib-5",source:"app-37d3b9dbfc68fcaf-g1",vector:voice(0.55,20)),domain:voiceDomain)
    let aligned=try archiveAligningVoiceNames(library,resolved:["Alpha":"合成甲正名","合成错字 Beta":"合成乙正名","beta":"合成乙正名"],domain:voiceDomain)
    let canonical=aligned.people.first{$0.name=="合成甲正名"},misspelt=aligned.people.first{$0.name=="合成乙正名"}
    try check(aligned.people.count==3 && canonical?.samples.count==6 && Set(canonical?.samples.map{VoiceprintAcousticContext.channel(for:$0.source)} ?? []).count==2,"alias_merges_a_person_across_scenes_keeping_every_sample")
    try check(misspelt?.samples.count==6 && aligned.people.first{$0.name.contains("合成错字")}==nil && aligned.knownPeople.first{$0.name=="合成乙正名"}?.aliases.sorted()==["beta","合成错字 Beta"].sorted(),"misspelling_is_renamed_and_later_spellings_join_it")
    try check(aligned.learning?.contributions.contains{$0.name=="Alpha"}==true,"contributions_keep_the_name_their_meeting_confirmed")
    try check(try archiveAligningVoiceNames(aligned,resolved:["Alpha":"合成甲正名","合成错字 Beta":"合成乙正名","beta":"合成乙正名"],domain:voiceDomain).revision==aligned.revision,"alignment_is_idempotent")
    try check(try JSONDecoder().decode(VoiceprintArchive.self,from:JSONEncoder().encode(aligned)).validated(domain:voiceDomain).people==aligned.people,"aligned_library_survives_save_and_validation")
    let survivors=aligned.learning!.contributions.filter{$0.name=="Alpha"}.map(\.confirmationID)
    let reconciled=try archiveReconcilingVoiceConfirmations(aligned,session:"lib-1",activeIDs:Set(survivors),domain:voiceDomain)
    try check(reconciled.revision==aligned.revision,"restart_reconciliation_accepts_merged_contributions")
    let revoked=try archiveReconcilingVoiceConfirmations(aligned,session:"lib-1",activeIDs:[],domain:voiceDomain)
    try check(revoked.people.first{$0.name=="合成甲正名"}?.samples.count==3,"undoing_in_the_source_meeting_still_retracts_only_those_samples")
    let renamed=try archiveRenamingVoicePerson(aligned,personID:otherID,name:"新名字",domain:voiceDomain)
    try check(renamed.people.contains{$0.id==otherID && $0.name=="新名字"},"a_person_can_be_renamed_by_hand")
    try check(try archiveRenamingVoicePerson(aligned,personID:otherID,name:"合成甲正名",domain:voiceDomain).people.count==2,"renaming_to_an_existing_person_merges")
    let optedOut=try archiveSettingVoiceEnabled(aligned,personID:otherID,enabled:false,domain:voiceDomain)
    try check(try archiveMergingVoicePeople(optedOut,from:otherID,into:canonical!.id,domain:voiceDomain).people.first{$0.name=="合成甲正名"}?.enabled==false,"opting_out_survives_a_merge")
    // A voice heard only on computer audio, now on the microphone: asked, not asserted.
    func sceneMatcher(_ archive:VoiceprintArchive)->VoiceprintMatcher {
        var matcher=VoiceprintMatcher(archive:archive);matcher.reset(session:wholeSession)
        matcher.importSavedEvidence((0..<3).map{index in SavedVoiceRecognitionEvidence(id:"s-\(index)",revision:1,key:slot0,sample:VoiceprintSample(session:wholeSession,source:"mic",epoch:"whole-epoch",start:Double(index*4),end:Double(index*4)+3,vector:voice(0.55,9)))})
        return matcher
    }
    try check(sceneMatcher(aligned).suggestion(slot0)==nil,"one_meeting_in_the_other_scene_is_not_enough_to_ask")
    let twoMeetings=try archiveAddingVoiceConfirmation(aligned,contribution:confirmed("其他人",person:otherID,session:"lib-7",source:"app-37d3b9dbfc68fcaf-g1",vector:voice(1,9),first:40),domain:voiceDomain)
    let question=sceneMatcher(twoMeetings).suggestion(slot0)
    try check(question?.name=="其他人" && question?.groupConsistent==false && question?.recognizedSupport==nil,"a_voice_from_the_other_scene_is_offered_as_a_question")
    try check(sceneMatcher(twoMeetings).suggestion(slot0,groupCentroid:false)==nil,"a_question_is_never_automatic_learning")
    var questionNames=SessionNames();for index in 0..<3 {questionNames.register(segment:"s-\(index)",item:["session":wholeSession,"source_id":"mic","epoch":"whole-epoch","revision":1,"speaker":["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":"whole-epoch"]])}
    _=questionNames.reconcileAutoVoiceprint(key:slot0,candidate:question)
    try check(questionNames.displayName(segment:"s-0")==nil && questionNames.autoName(for:slot0)==nil,"a_question_shows_no_name_until_answered")
    let hasMic=try archiveAddingVoiceConfirmation(twoMeetings,contribution:confirmed("其他人",person:otherID,session:"lib-6",source:"mic",vector:voice(1,30)),domain:voiceDomain)
    try check(sceneMatcher(hasMic).suggestion(slot0)==nil,"someone_with_references_in_this_scene_is_judged_by_them")
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
