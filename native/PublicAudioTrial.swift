import Foundation
import CryptoKit
import Darwin
private func publicAudioSHA(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
// User-approved public file only. Never constructs Microphone/ApplicationTap.
func publicAudioTrial(config:Config,root:URL)async throws->[String:Any] {
    signal(SIGINT,interruptHandler);signal(SIGTERM,interruptHandler)
    try config.validate();guard !config.isLocalOnly,config.maxSeconds>=36.76 && config.maxSeconds<=90,config.localSpeakerDirectory==nil,config.localEmbeddingModel==nil else{throw Failure(code:"public_trial_scope_invalid")}
    let source=root.appendingPathComponent("native/validation-workflow/public-mic-fixture/input.pcm");let input=try Data(contentsOf:source)
    guard input.count==1176320,publicAudioSHA(input)=="e4d31ccf5923cff4678eb79e62136e229b22fe8ffdfef54a6a2b63a9453cf85e" else{throw Failure(code:"public_trial_hash_mismatch")}
    let folder=root.appendingPathComponent("native/validation-workflow/public-cloud-trial/").appendingPathComponent(config.session);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    var result:[String:Any]=[:];var attempted=0.0;var committed=0;var taskIDs:[String]=[]
    for track in ["mic","remote"] {
        let store=try RecordingJournal(directory:folder,track:track);let box=Mailbox(journal:store);let origin=ProcessInfo.processInfo.systemUptime
        for offset in stride(from:0,to:input.count,by:3200){box.put(Data(input[offset..<min(input.count,offset+3200)]),at:origin+Double(offset)/32000);if offset%(3200*16)==0 {store.wait();try box.checkFault()}};box.seal();store.wait();try box.checkFault();guard store.bytes()==input.count else{throw Failure(code:"public_pcm_not_fully_saved")}
        let lane=Lane(track:track,config:config);await lane.attachJournal(store)
        await runJournalASR(lane:lane,box:box,store:store,track:track,origin:origin,onCacheFailure:{_ in interrupted=2},retryLimit:1,retryDelay:1)
        await lane.stop();store.wait();let metrics=await lane.metrics();let seconds=metrics["attempted_audio_seconds"] as? Double ?? 0;guard seconds<=config.maxSeconds else{throw Failure(code:"public_trial_budget_exceeded")};attempted+=seconds;committed+=store.committed("asr");if let task=metrics["task_id"] as? String {taskIDs.append(task)};result[track]=["metrics":metrics,"committed_bytes":store.committed("asr"),"input_bytes":input.count]
    }
    guard attempted<=180 else{throw Failure(code:"public_trial_budget_exceeded")}
    let receipt:[String:Any]=["type":"public_cloud_trial_result","session":config.session,"approval":"explicit_public_audio_probe","destination":"dashscope.aliyuncs.com","region":"Beijing","model":config.model,"public_pcm_sha256":publicAudioSHA(input),"input_audio_seconds":73.52,"attempted_audio_seconds":attempted,"max_attempted_audio_seconds":config.maxSeconds*2,"estimated_yuan":attempted*0.00033,"night_authorized_budget_yuan":5,"supplier_bill_verified":false,"tracks":result,"complete":committed==input.count*2,"capture":false,"system_audio":false,"task_ids":taskIDs,"chinese_natural_meeting_verified":false]
    try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys,.prettyPrinted]).write(to:folder.appendingPathComponent("receipt.json"),options:.atomic)
    return receipt
}
