import Foundation

func historicalVoiceLearningChecks(directory:URL)throws->[String] {
    guard directory.path.contains("/.runtime/") else{throw HistoricalVoiceLearningError.invalidRequest}
    let folder=directory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:name)};checks.append(name)}
    func write(_ object:Any,_ name:String)throws {try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:folder.appendingPathComponent(name))}
    let session=UUID().uuidString,confirmation=UUID().uuidString
    let ids=(0..<3).map{"history-\($0)"}
    var meeting:[String:Any]=["session":session,"capture_origin_uptime":100.0,"microphone_capture_diagnostics":["input_device":["uid":"synthetic-device-A"]]]
    let names:[String:Any]=["schema":2,"session":session,"voiceConfirmations":[["id":confirmation,"session":session,"name":"合成人物","createdAt":"2026-10-09T01:00:00Z","segmentIDs":ids]]]
    try write(meeting,"meeting.json");try write(names,"session-names.json")
    let samples=(0..<(12*16000)).map{i in Int16(6000*sin(Double(i)*0.07))}
    let pcm=samples.withUnsafeBytes{Data($0)}
    var chunks:[[String:Any]]=[]
    for index in 0..<2 {let data=Data(pcm[(index*320000)..<min(pcm.count,(index+1)*320000)]);let file=String(format:"mic-%06d.pcm",index);try data.write(to:folder.appendingPathComponent(file));chunks.append(["index":index,"bytes":data.count,"sha256":historicalVoiceHash(data)])}
    let manifest:[String:Any]=["schema":1,"track":"mic","format":"pcm_s16le","sample_rate":16000,"channels":1,"ended":true,"audio_cleaned":false,"origin_uptime":100.0,"written_bytes":pcm.count,"chunks":chunks]
    try write(manifest,"mic-manifest.json")
    var events:[[String:Any]]=(0..<3).map {i -> [String:Any] in
        let speaker:[String:Any]=["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":"history-epoch"]
        return ["type":"segment","segment_id":ids[i],"session":session,"revision":1,"source_id":"mic","epoch":"history-epoch","start":Double(i*4),"end":Double(i*4+3),"text":"合成确认片段","final":true,"end_time_known":true,"speaker":speaker]}
    func writeEvents(_ values:[[String:Any]])throws {var data=Data();for value in values {data.append(try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]));data.append(10)};try data.write(to:folder.appendingPathComponent("mic-transcript.jsonl"))}
    try writeEvents(events)
    func request(_ selected:[String]?=nil,_ digest:String?=nil)->HistoricalVoiceLearningRequest {
        HistoricalVoiceLearningRequest(folder:folder.path,session:session,confirmationID:confirmation,namesSHA256:digest ?? historicalVoiceHash(try! Data(contentsOf:folder.appendingPathComponent("session-names.json"))),segmentIDs:selected ?? ids,environmentLabel:"合成会议室")
    }
    var calls=0
    func extract(_ audio:[Float])throws->[Double] {calls+=1;guard audio.count==48000 else{throw Failure(code:"historical_unbounded_sample")};var v=[Double](repeating:0,count:192);v[0]=1;return v}
    let initial=request(),result=try historicalVoiceSamples(request:initial,extract:extract)
    try check(calls==3 && result.samples.count==3 && result.samples.map(\.start)==[0,4,8],"historical_only_explicit_three_spans_are_extracted")
    try check(result.samples.allSatisfy{$0.context?.environmentLabel=="合成会议室" && $0.context?.deviceFingerprint==historicalVoiceHash(Data("synthetic-device-A".utf8)) && $0.context?.channel=="microphone"},"historical_context_uses_observed_device_and_user_environment")
    try check(result.sourceHashes["mic-000000.pcm"] != nil && result.sourceHashes["mic-000001.pcm"] != nil && result.sourceHashes["mic-manifest.json"] != nil,"historical_result_binds_exact_pcm_and_manifest_hashes")
    let beforeAudio=historicalVoiceHash(try Data(contentsOf:folder.appendingPathComponent("mic-000000.pcm")))
    try historicalVoiceValidateResult(result,request:initial)
    try check(beforeAudio==historicalVoiceHash(try Data(contentsOf:folder.appendingPathComponent("mic-000000.pcm"))),"historical_extraction_never_rewrites_pcm")
    let person=UUID().uuidString
    let contribution=VoiceprintLearningContribution(confirmationID:confirmation,personID:person,name:"合成人物",confirmedAt:"2026-10-09T01:00:00Z",samples:result.samples)
    let archive=try archiveAddingVoiceConfirmation(nil,contribution:contribution,domain:"synthetic_model_output")
    try check(archive.people.count==1 && archive.people[0].samples.count==3,"historical_confirmed_samples_use_normal_reversible_ledger")
    let undone=try archiveRevokingVoiceConfirmation(archive,confirmationID:confirmation,domain:"synthetic_model_output")
    try check(undone.people.isEmpty && undone.learning?.contributions.first?.samples==result.samples,"historical_undo_removes_effective_samples_and_retains_exact_restore_evidence")
    let restored=try archiveReconcilingVoiceConfirmations(undone,session:session,activeIDs:[confirmation],domain:"synthetic_model_output")
    try check(restored.people==archive.people,"historical_undo_of_undo_restores_all_context_and_samples")
    func rejected(_ name:String,_ run:()throws->Void)throws {
        do {try run();throw Failure(code:"accepted_"+name)}catch is HistoricalVoiceLearningError{checks.append(name)}
    }
    try rejected("historical_unconfirmed_scope_is_rejected"){_ = try historicalVoiceSamples(request:request([ids[0]]),extract:extract)}
    var changedNames=names;changedNames["voiceConfirmations"]=[];try write(changedNames,"session-names.json")
    try rejected("historical_names_undo_cancels_result_commit"){try historicalVoiceValidateResult(result,request:initial)}
    try write(names,"session-names.json")
    meeting["capture_origin_uptime"]=101.0;try write(meeting,"meeting.json")
    try rejected("historical_changed_clock_rejects_result_commit"){try historicalVoiceValidateResult(result,request:initial)}
    meeting["capture_origin_uptime"]=100.0;try write(meeting,"meeting.json")
    let originalFirst=try Data(contentsOf:folder.appendingPathComponent("mic-000000.pcm"));var altered=originalFirst;altered[0]^=1;try altered.write(to:folder.appendingPathComponent("mic-000000.pcm"))
    try rejected("historical_pcm_hash_mismatch_is_rejected"){_ = try historicalVoiceSamples(request:request(),extract:extract)}
    try originalFirst.write(to:folder.appendingPathComponent("mic-000000.pcm"))
    for basis in ["unknown","multiple"] {
        var changed=events;changed[0]["speaker"]=["basis":basis,"reason":"overlap","cluster_ids":[0,1]];try writeEvents(changed)
        let prior=calls
        try rejected("historical_"+basis+"_does_not_train"){_ = try historicalVoiceSamples(request:request(),extract:extract)}
        try check(calls==prior,"historical_"+basis+"_rejected_before_model")
    }
    try writeEvents(events)
    var badEpoch=events;badEpoch[1]["epoch"]="other";badEpoch[1]["speaker"]=["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":"other"];try writeEvents(badEpoch)
    try rejected("historical_mixed_epoch_does_not_train"){_ = try historicalVoiceSamples(request:request(),extract:extract)}
    try writeEvents(events)
    try rejected("historical_cancel_before_extraction"){_ = try historicalVoiceSamples(request:request(),extract:extract,cancelled:{true})}
    var turns=0
    try rejected("historical_cancel_during_extraction"){_ = try historicalVoiceSamples(request:request(),extract:{audio in turns+=1;return try extract(audio)},cancelled:{turns>=1})}
    var count=0
    try rejected("historical_mixed_voice_embeddings_rejected"){_ = try historicalVoiceSamples(request:request(),extract:{audio in var v=[Double](repeating:0,count:192);v[count%2]=1;count+=1;return v})}
    let firstURL=folder.appendingPathComponent("mic-000000.pcm"),external=directory.appendingPathComponent("external-public.pcm")
    try originalFirst.write(to:external);try FileManager.default.removeItem(at:firstURL);try FileManager.default.createSymbolicLink(at:firstURL,withDestinationURL:external)
    try rejected("historical_symlink_audio_rejected"){_ = try historicalVoiceSamples(request:request(),extract:extract)}
    try FileManager.default.removeItem(at:firstURL);try originalFirst.write(to:firstURL)
    var unsealed=manifest;var unsealedChunks=chunks;unsealedChunks[0].removeValue(forKey:"sha256");unsealed["chunks"]=unsealedChunks;try write(unsealed,"mic-manifest.json")
    try rejected("historical_unsealed_audio_rejected"){_ = try historicalVoiceSamples(request:request(),extract:extract)}
    try write(manifest,"mic-manifest.json")
    events[0]["final"]=false;try writeEvents(events)
    try rejected("historical_partial_asr_does_not_train"){_ = try historicalVoiceSamples(request:request(),extract:extract)}
    events[0]["final"]=true
    var escaped=events;escaped[0]["source_id"]="../external";escaped[0]["speaker"]=["basis":"anonymous_cluster","cluster_id":0,"source_id":"../external","epoch":"history-epoch"];try writeEvents(escaped)
    let beforeEscape=calls
    try rejected("historical_source_cannot_escape_transcript_track"){_ = try historicalVoiceSamples(request:request(),extract:extract)}
    try check(calls==beforeEscape,"historical_source_escape_rejected_before_any_model_call")
    try writeEvents(events)
    try check(historicalVoiceClearSelection(events,session:session),"historical_ui_accepts_clear_same_scope_final_metadata")
    var unknownUI=events;unknownUI[0]["speaker"]=["basis":"unknown"]
    try check(!historicalVoiceClearSelection(unknownUI,session:session),"historical_ui_rejects_unknown_before_opt_in")
    try check(!historicalVoiceClearSelection(badEpoch,session:session),"historical_ui_rejects_mixed_epoch_before_opt_in")
    var partialUI=events;partialUI[0]["final"]=false
    try check(!historicalVoiceClearSelection(partialUI,session:session),"historical_ui_rejects_partial_before_opt_in")
    var shortUI=events[0];shortUI["end"]=(shortUI["start"] as! Double)+0.5
    try check(!historicalVoiceClearSelection([shortUI],session:session),"historical_ui_rejects_insufficient_duration_before_opt_in")
    let worker=HistoricalVoiceLearningWorker();let first=worker.reserve();worker.cancel()
    try check(!worker.isCurrent(first),"historical_cancel_invalidates_queued_task_before_launch")
    let second=worker.reserve(),third=worker.reserve()
    try check(!worker.isCurrent(second) && worker.isCurrent(third),"historical_new_request_invalidates_old_result_token")
    // The cancellation is deliberately injected after CAS/temp-file staging,
    // at the last possible point before the atomic archive replacement.
    let gateStore=VoiceprintArchiveStore(folder:directory.appendingPathComponent("gate-"+UUID().uuidString),domain:"synthetic_model_output")
    try gateStore.save(archive,expectAbsent:true)
    let beforeGate=try Data(contentsOf:gateStore.file),cancelledTicket=worker.reserve()
    try rejected("historical_cancel_at_atomic_commit_gate_rejects_write") {
        try gateStore.save(undone,expectedRevision:archive.revision,commitGate:{replace in
            worker.cancel()
            try worker.commitIfCurrent(cancelledTicket,replace)
        })
    }
    try check(try Data(contentsOf:gateStore.file)==beforeGate,"historical_cancel_gate_preserves_exact_prior_archive")
    let firstStore=VoiceprintArchiveStore(folder:directory.appendingPathComponent("gate-first-"+UUID().uuidString),domain:"synthetic_model_output"),firstTicket=worker.reserve()
    try rejected("historical_cancel_gate_prevents_first_archive_creation") {
        try firstStore.save(archive,expectAbsent:true,commitGate:{replace in worker.cancel();try worker.commitIfCurrent(firstTicket,replace)})
    }
    try check(!FileManager.default.fileExists(atPath:firstStore.file.path),"historical_cancel_gate_leaves_no_new_voice_archive")
    let commitTicket=worker.reserve()
    try gateStore.save(undone,expectedRevision:archive.revision,commitGate:{replace in try worker.commitIfCurrent(commitTicket,replace)})
    worker.cancel()
    try check(try gateStore.load()?.people==undone.people,"historical_committed_before_cancel_retains_durable_reversible_ledger")
    try check((try FileManager.default.contentsOfDirectory(atPath:gateStore.folder.path)).allSatisfy{!$0.hasPrefix(".voices-")},"historical_cancel_gate_cleans_staged_temporary_features")
    return checks
}
