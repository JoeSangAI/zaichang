import Foundation

// Synthetic only. These checks exercise durable round trips, exact rollback,
// delayed callbacks and independent concurrent contributions, without audio I/O.
func voiceprintLearningChecks(directory:URL)throws->[String] {
    guard Credential.offline,directory.path.contains("/.runtime/") else{throw Failure(code:"voice_learning_fixture_scope")}
    let domain="synthetic_model_output",time="2026-10-08T12:00:00Z"
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:name)};checks.append(name)}
    func vector(_ index:Int)->[Double] {var v=[Double](repeating:0,count:192);v[index]=1;return v}
    let preferenceDomain="VoiceprintLearningPolicyChecks-"+UUID().uuidString
    let policyDefaults=UserDefaults(suiteName:preferenceDomain)!
    defer {policyDefaults.removePersistentDomain(forName:preferenceDomain)}
    let policy=VoiceprintLearningPolicy(defaults:policyDefaults)
    try check(!policy.isEnabled,"continuous_learning_is_off_for_fresh_install")
    policy.setEnabled(true);try check(policy.isEnabled,"continuous_learning_permission_persists_locally")
    policy.setEnabled(false);try check(!policy.isEnabled,"turning_off_learning_is_durable")
    func sample(_ index:Int,_ voice:Int=0,_ session:String="current")->VoiceprintSample {
        VoiceprintSample(session:session,source:"mic",epoch:"epoch",start:Double(index*5),end:Double(index*5+2),vector:vector(voice))
    }
    let person=UUID().uuidString,other=UUID().uuidString
    let originals=(0..<12).map{sample($0,0,"past")}
    let baseline=VoiceprintPerson(id:person,name:"合成人物",authorizedAt:time,enabled:true,samples:originals)
    let legacy=VoiceprintArchive(schema:1,partition:SpeakerEmbeddingBackend.partition,inputKind:domain,revision:7,people:[baseline])
    let legacyData=try JSONEncoder().encode(legacy)
    let loadedLegacy=try JSONDecoder().decode(VoiceprintArchive.self,from:legacyData).validated(domain:domain)
    try check(loadedLegacy.learning==nil && loadedLegacy.people==[baseline],"schema_one_archive_loads_without_sample_changes")
    let ids=(0..<3).map{_ in UUID().uuidString}
    func contribution(_ id:String,_ samples:[VoiceprintSample],personID:String?=nil,name:String="合成人物",shared:SharedPersonReference?=nil)->VoiceprintLearningContribution {
        VoiceprintLearningContribution(confirmationID:id,personID:personID ?? person,name:name,sharedPerson:shared,confirmedAt:time,samples:samples)
    }
    let roster=(0..<voiceprintMaximumPeople).map { i in
        VoiceprintPerson(id:UUID().uuidString,name:"合成成员\(i)",authorizedAt:time,enabled:true,samples:(0..<3).map{sample(100+i*3+$0,i,"capacity-fixture")})
    }
    var fullRoster=VoiceprintArchive(schema:2,partition:legacy.partition,inputKind:domain,revision:1,people:roster)
    fullRoster.learning=VoiceprintLearningLedger(baseline:roster,contributions:[],revokedConfirmationIDs:[],enabledOverrides:[:])
    try check(try fullRoster.validated(domain:domain).people.count==64,"archive_and_baseline_accept_sixty_four_people")
    var oversizedRoster=fullRoster
    oversizedRoster.people.append(VoiceprintPerson(id:UUID().uuidString,name:"第65人",authorizedAt:time,enabled:true,samples:(0..<3).map{sample(900+$0,2,"capacity-fixture")}))
    do {_ = try oversizedRoster.validated(domain:domain);throw Failure(code:"sixty_five_people_accepted")}
    catch ProfileStoreError.invalid {checks.append("archive_rejects_more_than_sixty_four_people")}
    do {_ = try archiveAddingVoiceConfirmation(fullRoster,contribution:contribution(UUID().uuidString,(0..<3).map{sample(950+$0,100,"new-person")},personID:UUID().uuidString,name:"第65位新人"),domain:domain);throw Failure(code:"learning_created_sixty_fifth_person")}
    catch VoiceprintLearningError.capacity {checks.append("ledger_projection_stops_at_sixty_four_people")}
    var current=try archiveAddingVoiceConfirmation(loadedLegacy,contribution:contribution(ids[0],[sample(20,1)]),domain:domain)
    try check(current.schema==2 && current.learning?.baseline==[baseline] && current.people==[baseline],"one_confirmation_is_pending_and_preserves_baseline")
    current=try archiveAddingVoiceConfirmation(current,contribution:contribution(ids[1],[sample(21,1)]),domain:domain)
    try check(current.people==[baseline],"two_independent_confirmations_do_not_train")
    current=try archiveAddingVoiceConfirmation(current,contribution:contribution(ids[2],[sample(22,1)]),domain:domain)
    try check(current.people[0].samples.count==12 && current.people[0].samples.contains(sample(22,1)) && current.learning?.baseline[0].samples==originals,"third_consistent_confirmation_trains_but_retains_evicted_originals")
    let same=try archiveAddingVoiceConfirmation(current,contribution:contribution(ids[2],[sample(22,1)]),domain:domain)
    try check(same.revision==current.revision,"confirmation_retry_is_idempotent")
    let unrelatedID=UUID().uuidString
    current=try archiveAddingVoiceConfirmation(current,contribution:contribution(unrelatedID,(0..<3).map{sample($0,2,"other-session")},personID:other,name:"另一位合成人物"),domain:domain)
    let unrelated=current.people.first{$0.id==other}!
    let activeData=try JSONEncoder().encode(current)
    var tampered=try JSONDecoder().decode(VoiceprintArchive.self,from:activeData)
    tampered.people[0].enabled=false
    do {_ = try tampered.validated(domain:domain);throw Failure(code:"effective_projection_tamper_accepted")}
    catch ProfileStoreError.invalid {checks.append("effective_people_cannot_silently_override_ledger_owner")}
    let store=VoiceprintArchiveStore(folder:directory.appendingPathComponent("voices-"+UUID().uuidString),domain:domain)
    try store.save(current,expectAbsent:true)
    let reopened=try store.load()!
    var withdrawn=try archiveRevokingVoiceConfirmation(reopened,confirmationID:ids[2],domain:domain)
    try check(withdrawn.people.first{$0.id==person}!.samples==originals,"restart_then_undo_restores_all_twelve_original_references")
    try check(withdrawn.people.first{$0.id==other}==unrelated,"undo_preserves_unrelated_later_person_contribution")
    try check(withdrawn.learning?.contributions.count==4 && withdrawn.learning?.revokedConfirmationIDs.contains(ids[2])==true,"undo_keeps_recoverable_contribution_and_durable_tombstone")
    do {_ = try archiveAddingVoiceConfirmation(withdrawn,contribution:contribution(ids[2],[sample(22,1)]),domain:domain);throw Failure(code:"revoked_callback_relearned")}
    catch VoiceprintLearningError.revokedConfirmation {checks.append("late_callback_cannot_relearn_revoked_confirmation")}
    withdrawn=try archiveReconcilingVoiceConfirmations(withdrawn,session:"current",activeIDs:Set(ids),domain:domain)
    try check(withdrawn.people.first{$0.id==person}!.samples.contains(sample(22,1)),"explicit_persisted_undo_of_undo_restores_old_contribution_without_features")
    withdrawn=try archiveReconcilingVoiceConfirmations(withdrawn,session:"current",activeIDs:[],domain:domain)
    try check(withdrawn.people.first{$0.id==person}!.samples==originals && withdrawn.people.first{$0.id==other}==unrelated,"session_reconciliation_clears_only_that_sessions_contributions")
    let repeated=try archiveReconcilingVoiceConfirmations(withdrawn,session:"current",activeIDs:[],domain:domain)
    try check(repeated.revision==withdrawn.revision,"persisted_state_reconciliation_is_idempotent")
    let disabled=try archiveSettingVoiceEnabled(withdrawn,personID:person,enabled:false,domain:domain)
    let restoredDisabled=try archiveReconcilingVoiceConfirmations(disabled,session:"current",activeIDs:Set(ids),domain:domain)
    try check(restoredDisabled.people.first{$0.id==person}?.enabled==false,"restoring_confirmations_preserves_user_disabled_state")
    do {_ = try archiveAddingVoiceConfirmation(restoredDisabled,contribution:contribution(UUID().uuidString,[sample(25,1)]),domain:domain);throw Failure(code:"disabled_person_trained")}
    catch VoiceprintLearningError.disabled {checks.append("disabled_person_does_not_gain_new_contributions")}
    let enabled=try archiveSettingVoiceEnabled(restoredDisabled,personID:person,enabled:true,domain:domain)
    try check(enabled.people.first{$0.id==person}?.enabled==true && enabled.learning?.baseline==[baseline],"explicit_reenable_preserves_original_baseline")
    let newID=UUID().uuidString,newPerson=UUID().uuidString
    var pending=try archiveAddingVoiceConfirmation(nil,contribution:contribution(newID,[sample(0,4)],personID:newPerson,name:"新人"),domain:domain)
    try check(pending.people.isEmpty && pending.learning?.contributions.count==1,"new_person_pending_sample_is_durable_without_matching_profile")
    pending=try archiveAddingVoiceConfirmation(pending,contribution:contribution(newID,[sample(1,4),sample(2,4)],personID:newPerson,name:"新人"),domain:domain)
    try check(pending.people.count==1 && pending.people[0].samples.count==3,"one_explicit_group_confirmation_can_accumulate_three_current_segments")
    let laterSameID=UUID().uuidString
    let laterSame=try archiveAddingVoiceConfirmation(pending,contribution:contribution(laterSameID,(3..<6).map{sample($0,4,"later")},personID:newPerson,name:"新人"),domain:domain)
    let earlierRemoved=try archiveRevokingVoiceConfirmation(laterSame,confirmationID:newID,domain:domain)
    try check(earlierRemoved.people[0].samples==(3..<6).map{sample($0,4,"later")},"undo_preserves_independent_later_contribution_for_the_same_person")
    let noNewPerson=try archiveRevokingVoiceConfirmation(pending,confirmationID:newID,domain:domain)
    try check(noNewPerson.people.isEmpty,"undo_removes_a_new_profiles_entire_effective_contribution")
    let restoredNew=try archiveReconcilingVoiceConfirmations(noNewPerson,session:"current",activeIDs:[newID],domain:domain)
    try check(restoredNew.people==pending.people,"undo_of_new_profile_undo_restores_exact_samples")
    let duplicateAudio=UUID().uuidString
    var duplicates=try archiveAddingVoiceConfirmation(nil,contribution:contribution(UUID().uuidString,[sample(0,4)],personID:newPerson,name:"新人"),domain:domain)
    duplicates=try archiveAddingVoiceConfirmation(duplicates,contribution:contribution(duplicateAudio,[sample(0,4)],personID:newPerson,name:"新人"),domain:domain)
    duplicates=try archiveAddingVoiceConfirmation(duplicates,contribution:contribution(UUID().uuidString,[sample(1,4)],personID:newPerson,name:"新人"),domain:domain)
    try check(duplicates.people.isEmpty,"multiple_confirmations_of_same_audio_are_not_independent_samples")
    let mixed=contribution(UUID().uuidString,[sample(0,4),sample(1,5),sample(2,4)],personID:newPerson,name:"新人")
    do {_ = try archiveAddingVoiceConfirmation(nil,contribution:mixed,domain:domain);throw Failure(code:"mixed_confirmation_trained")}
    catch VoiceprintLearningError.invalidConfirmation {checks.append("mixed_acoustic_confirmation_is_rejected")}
    do {_ = try archiveAddingVoiceConfirmation(legacy,contribution:contribution(UUID().uuidString,[sample(30,0)],personID:newPerson,name:"错误新人物"),domain:domain);throw Failure(code:"known_voice_bound_to_other_person")}
    catch VoiceprintLearningError.conflictingVoice {checks.append("strong_other_person_voice_cannot_be_trained_under_new_identity")}
    let reference=SharedPersonReference(id:"person:1234567890abcdef1234",name:"共享合成人物",evidence:["/synthetic/人物主本.md"])
    let shared=try archiveAddingVoiceConfirmation(legacy,contribution:contribution(UUID().uuidString,(0..<3).map{sample($0,1)},name:reference.name,shared:reference),domain:domain)
    try check(shared.people[0].id==person && shared.people[0].sharedPerson==reference && shared.learning?.baseline[0].sharedPerson==nil,"explicit_shared_reference_preserves_legacy_uuid_and_baseline")
    do {_ = try archiveAddingVoiceConfirmation(legacy,contribution:contribution(UUID().uuidString,[sample(30,1)],name:"错位姓名",shared:reference),domain:domain);throw Failure(code:"shared_contribution_name_mismatch_accepted")}
    catch VoiceprintLearningError.invalidConfirmation {checks.append("shared_contribution_name_must_match_canonical_reference")}
    for invalid in [SharedPersonReference(id:"person:wrong",name:reference.name,evidence:reference.evidence),SharedPersonReference(id:reference.id,name:reference.name,evidence:Array(repeating:reference.evidence[0],count:9))] {
        do {_ = try archiveAddingVoiceConfirmation(legacy,contribution:contribution(UUID().uuidString,[sample(30,1)],name:invalid.name,shared:invalid),domain:domain);throw Failure(code:"invalid_shared_reference_accepted")}
        catch VoiceprintLearningError.invalidConfirmation {checks.append("shared_reference_uses_canonical_validation_"+String(checks.count))}
    }
    var wrongProfile=shared
    let profile=shared.people[0]
    wrongProfile.people[0]=VoiceprintPerson(id:profile.id,name:"错位姓名",authorizedAt:profile.authorizedAt,enabled:profile.enabled,samples:profile.samples,sharedPerson:reference)
    do {_ = try wrongProfile.validated(domain:domain);throw Failure(code:"shared_profile_name_mismatch_accepted")}
    catch ProfileStoreError.invalid {checks.append("shared_profile_name_must_match_canonical_reference")}
    let conflictingReference=SharedPersonReference(id:reference.id,name:"同一ID不同姓名",evidence:reference.evidence)
    do {_ = try archiveAddingVoiceConfirmation(shared,contribution:contribution(UUID().uuidString,[sample(30,1)],name:conflictingReference.name,shared:conflictingReference),domain:domain);throw Failure(code:"shared_id_name_collision_accepted")}
    catch VoiceprintLearningError.conflictingIdentity {checks.append("same_shared_id_cannot_silently_change_canonical_name")}
    let sharedUndone=try archiveReconcilingVoiceConfirmations(shared,session:"current",activeIDs:[],domain:domain)
    try check(sharedUndone.people==legacy.people,"undo_restores_prior_shared_identity_binding")
    let capacityContributions=(0..<512).map{i in contribution(UUID().uuidString,(0..<4).map{sample(i*4+$0+100,1,"capacity-ledger")})}
    var capacityArchive=VoiceprintArchive(schema:2,partition:legacy.partition,inputKind:domain,revision:1,people:[baseline])
    capacityArchive.learning=VoiceprintLearningLedger(baseline:[baseline],contributions:capacityContributions,revokedConfirmationIDs:capacityContributions.map(\.confirmationID),enabledOverrides:[:])
    _ = try capacityArchive.validated(domain:domain)
    try check(capacityArchive.learning?.contributions.count==512 && capacityArchive.learning?.contributions.reduce(0,{$0+$1.samples.count})==2048,"ledger_supports_long_term_contributions_within_bounded_capacity")
    do {_ = try archiveAddingVoiceConfirmation(capacityArchive,contribution:contribution(UUID().uuidString,[sample(400,1)]),domain:domain);throw Failure(code:"learning_capacity_not_bounded")}
    catch VoiceprintLearningError.capacity {checks.append("capacity_stops_learning_without_discarding_reversible_evidence")}
    try store.save(withdrawn,expectedRevision:reopened.revision)
    do {try store.save(reopened,expectedRevision:reopened.revision);throw Failure(code:"learning_stale_write_overwrote_undo")}
    catch ProfileStoreError.invalid {checks.append("compare_and_swap_prevents_stale_learning_from_overwriting_undo")}
    let disk=try store.load()!
    try check(disk.people==withdrawn.people && disk.learning==withdrawn.learning,"reversible_state_round_trips_after_undo")
    var matcher=VoiceprintMatcher();matcher.reset(session:"selection")
    func event(_ i:Int,_ voice:Int=0)->[String:Any] {
        let start=Double(i*5)
        return ["segment_id":"selected-\(i)","session":"selection","source_id":"mic","epoch":"epoch","revision":1,"final":true,"end_time_known":true,"start":start,"end":start+4,"speaker":["basis":"anonymous_cluster","source_id":"mic","epoch":"epoch","cluster_id":0],"identity_features":["partition":legacy.partition,"input_kind":domain,"quality_gate":"single_model_slot_asr_final_unclipped","source_id":"mic","epoch":"epoch","evidence_start":start,"evidence_end":start+2,"values":vector(voice)]]
    }
    for i in 0..<4 {_=matcher.observe(event(i),domain:domain)}
    try check(matcher.confirmationSamples(segmentIDs:["selected-0"]).count==1,"single_sentence_confirmation_selects_only_that_sentence")
    _=matcher.observe(event(4),domain:domain)
    try check(matcher.confirmationSamples(segmentIDs:["selected-0"]).count==1,"later_speech_does_not_expand_confirmed_scope")
    var unknown=event(0);unknown["speaker"]=["basis":"unknown"];_=matcher.observe(unknown,domain:domain)
    try check(matcher.confirmationSamples(segmentIDs:["selected-0"]).isEmpty,"unknown_revision_cannot_train_from_old_evidence")
    var overlap=event(1);overlap["speaker"]=["basis":"multiple","reason":"overlap"];_=matcher.observe(overlap,domain:domain)
    try check(matcher.confirmationSamples(segmentIDs:["selected-1"]).isEmpty,"overlap_revision_is_not_force_trained")
    _=matcher.observe(event(5,1),domain:domain)
    try check(matcher.confirmationSamples(segmentIDs:["selected-2","selected-5"]).isEmpty,"mixed_selected_voices_do_not_train")
    let roomA=VoiceprintAcousticContext(channel:"microphone",deviceFingerprint:String(repeating:"a",count:64),environmentLabel:"会议室")
    let roomB=VoiceprintAcousticContext(channel:"microphone",deviceFingerprint:String(repeating:"b",count:64),environmentLabel:"耳机")
    func contextSample(_ index:Int,_ voice:Int,_ context:VoiceprintAcousticContext)->VoiceprintSample {
        VoiceprintSample(session:"conditions",source:"mic",epoch:"condition-epoch",start:Double(index*5),end:Double(index*5+2),vector:vector(voice),context:context)
    }
    let roomAID=UUID().uuidString,roomBID=UUID().uuidString
    let roomASamples=(0..<3).map{contextSample($0,1,roomA)},roomBSamples=(3..<9).map{contextSample($0,2,roomB)}
    var layered=try archiveAddingVoiceConfirmation(legacy,contribution:contribution(roomAID,roomASamples),domain:domain)
    layered=try archiveAddingVoiceConfirmation(layered,contribution:contribution(roomBID,roomBSamples),domain:domain)
    try check(layered.people[0].samples.count==12 && layered.people[0].samples.filter{$0.context==roomA}.count>=3 && layered.people[0].samples.filter{$0.context==roomB}.count>=3,"recording_conditions_retain_complete_reference_cohorts")
    try check(Array(layered.people[0].samples.prefix(3))==Array(originals.prefix(3)) && layered.learning?.baseline[0].samples==originals,"condition_retention_preserves_anchor_and_full_legacy_baseline")
    try check(layered.scores(vector(1)).first?.1==1 && layered.scores(vector(2)).first?.1==1,"different_conditions_remain_matchable_without_identity_bonus")
    let unlayered=try archiveReconcilingVoiceConfirmations(layered,session:"conditions",activeIDs:[],domain:domain)
    try check(unlayered.people==legacy.people,"undo_all_condition_learning_restores_exact_legacy_references")
    let reLayered=try archiveReconcilingVoiceConfirmations(unlayered,session:"conditions",activeIDs:[roomAID,roomBID],domain:domain)
    try check(reLayered.people==layered.people,"redo_restores_condition_balancing_without_reextracting_pcm")
    let contextData=try JSONEncoder().encode(layered),reloadedContext=try JSONDecoder().decode(VoiceprintArchive.self,from:contextData).validated(domain:domain)
    try check(reloadedContext.people==layered.people && reloadedContext.learning==layered.learning,"recording_conditions_and_undo_ledger_survive_restart")
    let invalidContext=VoiceprintAcousticContext(channel:"microphone",deviceFingerprint:"invented-device",environmentLabel:"会议室")
    do {_ = try archiveAddingVoiceConfirmation(legacy,contribution:contribution(UUID().uuidString,[contextSample(20,1,invalidContext)]),domain:domain);throw Failure(code:"invalid_recording_context_accepted")}
    catch VoiceprintLearningError.invalidConfirmation {checks.append("unverified_device_identity_format_is_rejected")}
    let wrongChannel=VoiceprintAcousticContext(channel:"system",environmentLabel:"会议室")
    do {_ = try archiveAddingVoiceConfirmation(legacy,contribution:contribution(UUID().uuidString,[contextSample(20,1,wrongChannel)]),domain:domain);throw Failure(code:"wrong_recording_channel_accepted")}
    catch VoiceprintLearningError.invalidConfirmation {checks.append("context_channel_cannot_override_sample_source")}
    let disabledContext=try archiveSettingVoiceEnabled(layered,personID:person,enabled:false,domain:domain)
    try check(disabledContext.people[0].enabled==false && disabledContext.scores(vector(1)).first?.1==1,"disabled_context_references_remain_negative_competitors")
    try check(!VoiceprintAcousticContext(channel:"microphone",environmentLabel:"会议\n室").valid && !VoiceprintAcousticContext(channel:"microphone",environmentLabel:String(repeating:"长",count:41)).valid,"environment_notes_are_bounded_plain_labels")
    return checks
}
