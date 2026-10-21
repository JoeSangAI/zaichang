import AppKit

@MainActor func asrTermsChecks()throws->[String:Any] {
    guard Credential.offline else{throw Failure(code:"offline_only")}
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws{guard value else{throw Failure(code:name)};checks.append(name)}
    for value in ["示例术语",String(repeating:"词",count:15),"one two three four five six seven"] {try check(ASRTermVocabulary.valid(value),"term_valid_"+String(checks.count))}
    for value in ["",String(repeating:"词",count:16),"one two three four five six seven eight","bad\nword","隐\u{200b}词"] {try check(!ASRTermVocabulary.valid(value),"term_invalid_"+String(checks.count))}
    try check((try? ASRTermVocabulary.validated(["示例":50]))==nil,"local_weights_never_force_fifty")
    let full=Dictionary(uniqueKeysWithValues:(0..<ASRTermVocabulary.maximumWords).map{("词"+String($0),3)})
    try check(ASRTermVocabulary.maximumWords==300 && (try? ASRTermVocabulary.validated(full))?.count==300,"standing_project_vocabulary_fits_three_hundred")
    let words=Dictionary(uniqueKeysWithValues:(0...ASRTermVocabulary.maximumWords).map{("word"+String($0),2)})
    try check((try? ASRTermVocabulary.validated(words))==nil,"bounded_selection_rejects_overflow")
    let projection=try ASRTermProjection.decode(Data("{\"schema\":1,\"status\":\"ok\",\"requires_selection\":true,\"source_digest\":\"fixture\",\"candidates\":[{\"word\":\"示例\",\"sources\":[\"公司资料\"]}]}".utf8))
    try check(projection.candidates.count==1,"source_projection_is_local_candidate_only")
    let owner=Delegate();owner.previewRenderOnly=true;owner.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));owner.pendingASRTerms=["示例":2];owner.pendingASRTermsDecision=true
    let local=owner.requestWithASRTerms(["local_only":true,"cloud_session_confirmed":false])
    try check(local["asr_vocabulary"]==nil && owner.pendingASRTerms.count==1,"local_mode_never_sends_terms")
    let cloud=owner.requestWithASRTerms(["cloud_session_confirmed":true])
    try check(cloud["asr_vocabulary"] as? [String:Int]==["示例":2] && cloud["asr_terms_confirmed"] as? Bool==true,"explicit_selection_enters_cloud_request")
    try check(owner.pendingASRTerms==["示例":2] && owner.activeASRTerms.isEmpty,"failed_launch_keeps_explicit_selection_for_retry")
    try check(owner.requestWithASRTerms(["cloud_session_confirmed":true])["asr_vocabulary"] as? [String:Int]==["示例":2],"retry_retains_selected_words")
    owner.startingASRTerms=cloud["asr_vocabulary"] as? [String:Int];owner.commitASRTermsOnStarted()
    try check(owner.pendingASRTerms.isEmpty && owner.activeASRTerms==["示例":2],"started_commits_immutable_session_snapshot")
    try check(owner.requestWithASRTerms(["cloud_session_confirmed":true])["asr_vocabulary"]==nil,"next_start_does_not_implicitly_reuse_previous_terms")
    owner.pendingASRTerms=[:];owner.pendingASRTermsDecision=true
    let cleared=owner.requestWithASRTerms(["cloud_session_confirmed":true,"resume_cache_id":"fixture"])
    try check(cleared["asr_vocabulary"] as? [String:Int]==[:] && cleared["asr_terms_confirmed"] as? Bool==true,"explicit_disable_sends_empty_snapshot_for_historical_resume")
    owner.pendingASRTerms=["下一场":2];owner.pendingASRTermsDecision=true;owner.newMeeting()
    try check(owner.pendingASRTerms.isEmpty && owner.activeASRTerms.isEmpty,"new_meeting_resets_term_authorization")
    try check(owner.asrTermsButton?.title=="本场术语…","settings_entry_reports_disabled_default")
    try check(ASRTermVocabulary.explicitVocabularyRejection(["error_code":"InvalidParameter","error_message":"invalid vocabulary"]),"explicit_term_error_identified")
    let bilingual = try ASRTermVocabulary.parameters(silenceMS: 800)
    try check(bilingual["language_hints"] as? [String] == ["zh", "en"],"bilingual_recognition_hints_are_explicit")
    try check(!ASRTermVocabulary.explicitVocabularyRejection(["error_code":"InvalidApiKey","error_message":"vocabulary request invalid"]) && !ASRTermVocabulary.explicitVocabularyRejection(["error_code":"InvalidParameter","error_message":"sample_rate"]),"unrelated_failures_never_labeled_term_failure")
    return ["type":"asr_terms_checks","passed":checks.count,"checks":checks,"capture":false,"cloud":false,"offscreen":true]
}
