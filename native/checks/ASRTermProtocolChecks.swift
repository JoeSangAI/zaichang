import Foundation

private final class TermProtocolState {
    var commands:[[String:Any]]=[];var audioBytes=0;let error:String?
    init(_ error:String?=nil){self.error=error}
}
private final class TermProtocolSocket:ASRSocket {
    let state:TermProtocolState;var answer:URLSessionWebSocketTask.Message?
    init(_ state:TermProtocolState){self.state=state}
    func resume(){}
    func cancel(with:URLSessionWebSocketTask.CloseCode,reason:Data?){}
    func send(_ message:URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text)=message else{if case .data(let data)=message {state.audioBytes+=data.count};return}
        let command=try JSONSerialization.jsonObject(with:Data(text.utf8)) as! [String:Any];state.commands.append(command)
        let header=command["header"] as! [String:Any],payload=command["payload"] as! [String:Any],parameters=payload["parameters"] as? [String:Any] ?? [:]
        var reply:[String:Any]=["task_id":header["task_id"]!,"event":"task-started"]
        if let error=state.error,parameters["vocabulary"] != nil {reply["event"]="task-failed";reply["error_code"]=error=="auth" ? "InvalidApiKey":"InvalidParameter";reply["error_message"]=["terms","cancel"].contains(error) ? "invalid vocabulary":"other parameter"}
        if state.error=="wrong_task" {reply["task_id"]="not-this-task"}
        answer = .data(try JSONSerialization.data(withJSONObject:["header":reply]))
    }
    func receive() async throws->URLSessionWebSocketTask.Message {if state.error=="cancel" {interrupted=2};guard let answer else{throw Failure(code:"fixture_missing_reply")};return answer}
}

func asrTermProtocolChecks() async throws->[String:Any] {
    guard Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool==true else{throw Failure(code:"offline_only")}
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws{guard value else{throw Failure(code:name)};checks.append(name)}
    var config=Config(session:"terms-fixture",bundle:"*microphone*",key:"synthetic-key",confirmed:true,maxSeconds:10,model:"qwen-audio-3.0-asr-flash-streaming",silenceMS:1300,micEnabled:true,localSpeakerDirectory:nil,localEmbeddingModel:nil,userLaunchConfirmed:true)
    config.asrVocabulary=["示例术语":2];try check((try? config.validate())==nil,"unconfirmed_terms_rejected")
    config.asrVocabularyConfirmed=true;try config.validate()
    let state=TermProtocolState(),lane=Lane(track:"mic",config:config,socketFactory:{TermProtocolSocket(state)})
    try await lane.start()
    func words(_ command:[String:Any])->[String:Int]? {((command["payload"] as? [String:Any])?["parameters"] as? [String:Any])?["vocabulary"] as? [String:Int]}
    try check(words(state.commands[0])==["示例术语":2],"selected_words_enter_actual_run_task")
    let finish=try JSONSerialization.jsonObject(with:Data(try await lane.command("finish-task").utf8)) as! [String:Any]
    try check(words(finish)==nil,"finish_does_not_repeat_vocabulary")
    await lane.reconnect(at:0);try await lane.start()
    try check(state.commands.count==2 && words(state.commands[1])==words(state.commands[0]),"reconnect_repeats_frozen_snapshot")
    let ids=state.commands.map{($0["header"] as! [String:Any])["task_id"] as! String};try check(ids[0] != ids[1],"reconnect_uses_new_task_identity")
    let rejected=TermProtocolState("terms"),retry=Lane(track:"remote",config:config,socketFactory:{TermProtocolSocket(rejected)})
    try await retry.start();try check(rejected.commands.count==2 && words(rejected.commands[0]) != nil && words(rejected.commands[1])==nil,"explicit_vocabulary_rejection_retries_once_without_terms")
    try check(rejected.audioBytes==0,"fallback_occurs_before_any_audio_send")
    await retry.reconnect(at:0);try await retry.start();try check(words(rejected.commands[2])==nil,"rejected_terms_stay_disabled_for_same_lane")
    for error in ["auth","other","wrong_task"] {
        let failed=TermProtocolState(error),candidate=Lane(track:"mic",config:config,socketFactory:{TermProtocolSocket(failed)})
        var threw=false;do{try await candidate.start()}catch{threw=true}
        try check(threw && failed.commands.count==1,"no_vocab_fallback_for_"+error)
    }
    let cancelled=TermProtocolState("cancel"),cancelLane=Lane(track:"mic",config:config,socketFactory:{TermProtocolSocket(cancelled)})
    var cancelledThrown=false;do{try await cancelLane.start()}catch{cancelledThrown=true};interrupted=0
    try check(cancelledThrown && cancelled.commands.count==1,"cancelled_handshake_cannot_start_vocabulary_retry")
    return ["type":"asr_term_protocol_checks","passed":checks.count,"checks":checks,"capture":false,"network":false,"cloud":false]
}
