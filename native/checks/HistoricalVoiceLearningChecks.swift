import Foundation

func historicalVoiceLearningChecks(directory:URL)throws->[String] {
    guard directory.path.contains("/.runtime/") else{throw Failure(code:"historical_scope")}
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:name)};checks.append(name)}
    let session=UUID().uuidString
    let events:[[String:Any]]=(0..<3).map {i in
        ["type":"segment","segment_id":"history-\(i)","session":session,"revision":1,"source_id":"mic","epoch":"history-epoch","start":Double(i*4),"end":Double(i*4+3),"text":"合成确认片段","final":true,"end_time_known":true,
         "speaker":["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":"history-epoch"]]
    }
    try check(historicalVoiceClearSelection(events,session:session),"historical_ui_accepts_clear_same_scope_final_metadata")
    var unknownUI=events;unknownUI[0]["speaker"]=["basis":"unknown"]
    try check(!historicalVoiceClearSelection(unknownUI,session:session),"historical_ui_rejects_unknown_before_opt_in")
    var badEpoch=events;badEpoch[1]["epoch"]="other";badEpoch[1]["speaker"]=["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":"other"]
    try check(!historicalVoiceClearSelection(badEpoch,session:session),"historical_ui_rejects_mixed_epoch_before_opt_in")
    var partialUI=events;partialUI[0]["final"]=false
    try check(!historicalVoiceClearSelection(partialUI,session:session),"historical_ui_rejects_partial_before_opt_in")
    var shortUI=events[0];shortUI["end"]=(shortUI["start"] as! Double)+0.5
    try check(!historicalVoiceClearSelection([shortUI],session:session),"historical_ui_rejects_insufficient_duration_before_opt_in")
    return checks
}
