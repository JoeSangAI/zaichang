import Foundation

func voiceSuggestionPersistenceChecks()throws->[String] {
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {
        guard value else{throw Failure(code:"voice_suggestion_check_\(name)")}
        checks.append("voice_suggestion_"+name)
    }
    let session="voice-suggestion-session"
    let key=SessionSpeakerKey(session:session,source:"mic",epoch:"epoch",identity:"slot:0")
    func event(_ index:Int,_ slot:Int=0,_ revision:Int=1)->[String:Any] {
        ["type":"segment","session":session,"segment_id":"suggestion-\(index)","revision":revision,
         "source_id":"mic","track":"mic","epoch":"epoch","start":Double(index*5),"end":Double(index*5+4),
         "final":true,"text":"合成发言\(index)",
         "speaker":["basis":"anonymous_cluster","cluster_id":slot,"source_id":"mic","epoch":"epoch"]]
    }
    func candidate(_ groupConsistent:Bool)->VoiceprintRecommendation {
        VoiceprintRecommendation(personID:"00000000-0000-4000-8000-000000000011",name:"测试人物甲",archiveRevision:4,
            evidenceCount:3,support:(0..<3).map{VoiceprintEvidenceRef(id:"suggestion-\($0)",revision:1)},groupConsistent:groupConsistent)
    }
    var names=SessionNames()
    for index in 0..<3 {names.register(segment:"suggestion-\(index)",item:event(index))}
    let partial=candidate(false)
    try check(names.reconcileAutoVoiceprint(key:key,candidate:partial),"partial_candidate_persists")
    try check(names.voiceSuggestion(for:key)?.name=="测试人物甲","partial_candidate_available_through_suggestion_api")
    try check(names.name(speaker:key)==nil && names.displayName(speaker:key)==nil && names.values.values.allSatisfy{$0 != "测试人物甲"} && names.voiceConfirmations.isEmpty,
          "partial_candidate_is_not_name_export_or_confirmation")
    try check(names.autoNamedKeys(personID:partial.personID)==[key],"archive_disable_enumerates_suggestions")
    var completed=names
    try check(completed.reconcileAutoVoiceprint(key:key,candidate:candidate(true)) && completed.voiceSuggestion(for:key)==nil &&
          completed.displayName(speaker:key)?.origin == .voiceprint,"complete_candidate_replaces_persisted_suggestion")
    let saved=try names.snapshot(session:session)
    let snapshotText=String(decoding:saved,as:UTF8.self)
    try check(snapshotText.contains("voiceSuggestions") && snapshotText.contains("测试人物甲") && !snapshotText.contains("identity_features"),
          "snapshot_persists_only_candidate_metadata")

    var restored=SessionNames()
    for index in 0..<3 {restored.register(segment:"suggestion-\(index)",item:event(index))}
    try restored.restore(saved,session:session)
    try check(restored.voiceSuggestion(for:key)?.name=="测试人物甲" && restored.displayName(speaker:key)==nil,
          "history_restore_keeps_suggestion_out_of_display_name")

    var stale=SessionNames()
    for index in 0..<3 {stale.register(segment:"suggestion-\(index)",item:event(index,0,index==0 ? 2:1))}
    try stale.restore(saved,session:session)
    try check(stale.voiceSuggestion(for:key)==nil && stale.restoredAutoNameInvalidated,
          "stale_support_revision_invalidates_restored_suggestion")

    var suppression=names
    try check(suppression.dismissAutoName(key) && suppression.voiceSuggestion(for:key)==nil &&
          !suppression.reconcileAutoVoiceprint(key:key,candidate:partial),"manual_suppression_clears_and_blocks_suggestion")
    var manual=names
    try check(manual.renameSpeaker(key:key,name:"人工姓名") && manual.voiceSuggestion(for:key)==nil &&
          manual.displayName(speaker:key)?.origin == .manual,"manual_name_replaces_suggestion")

    var transitioning=names
    let complete=candidate(true)
    try check(transitioning.reconcileAutoVoiceprint(key:key,candidate:complete) && transitioning.displayName(speaker:key)?.origin == .voiceprint,
          "complete_candidate_can_be_automatic")
    try check(transitioning.reconcileAutoVoiceprint(key:key,candidate:partial) && transitioning.displayName(speaker:key)==nil &&
          transitioning.voiceSuggestion(for:key)?.name=="测试人物甲","partial_update_withdraws_auto_name_and_keeps_suggestion")

    var aliased=SessionNames()
    let destination=SessionSpeakerKey(session:session,source:"mic",epoch:"epoch",identity:"slot:1")
    for index in 0..<3 {aliased.register(segment:"suggestion-\(index)",item:event(index))}
    aliased.register(segment:"destination",item:["session":session,"source_id":"mic","epoch":"epoch",
        "speaker":["basis":"anonymous_cluster","cluster_id":1,"source_id":"mic","epoch":"epoch"]])
    _=aliased.reconcileAutoVoiceprint(key:key,candidate:partial)
    try check(aliased.mergeSpeaker(from:key,to:destination,humanConfirmed:true) && aliased.voiceSuggestion(for:key)==nil,
          "alias_merge_clears_partial_suggestion")
    var reset=names;reset.reset()
    for index in 0..<3 {reset.register(segment:"suggestion-\(index)",item:event(index))}
    try check(reset.voiceSuggestion(for:key)==nil && reset.autoNamedKeys(personID:partial.personID).isEmpty,"reset_drops_suggestions_even_when_same_ids_reappear")
    return checks
}
