import Foundation

func speakerRefinementJobChecks(directory:URL)throws->[String] {
    guard directory.path.contains("/.runtime/") else{throw Failure(code:"speaker_refinement_fixture_scope")}
    let folder=directory.appendingPathComponent("speaker-refinement-"+UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:folder)}

    let helper=folder.appendingPathComponent("refinement-helper.py")
    let source="""
    #!/usr/bin/env python3
    import json, os, sys, time
    mode = os.path.basename(sys.argv[2])
    raw = sys.stdin.buffer.read()
    assert raw.endswith(b"\\n")
    json.loads(raw[:-1])
    if mode == "fail":
        sys.exit(23)
    if mode == "slow":
        open(sys.argv[2] + ".started", "w").close()
        time.sleep(1.0)
    if mode == "oversize":
        sys.stdout.buffer.write(b"{" + b"x" * (2 * 1024 * 1024))
    elif mode == "invalid":
        sys.stdout.write('{not-json')
    else:
        sys.stdout.write('{"candidate":true}\\n')
    """
    try source.write(to:helper,atomically:true,encoding:.utf8)
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
    let successModels=folder.appendingPathComponent("success")
    let failModels=folder.appendingPathComponent("fail")
    let slowModels=folder.appendingPathComponent("slow")
    let largeModels=folder.appendingPathComponent("oversize")
    let invalidModels=folder.appendingPathComponent("invalid")

    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:name)};checks.append(name)}
    func waitForResult(_ worker:SpeakerRefinementJob,request:[String:Any],models:URL,token:UUID?=nil,limit:TimeInterval=6)->(UUID,Result<Data,Error>)? {
        let semaphore=DispatchSemaphore(value:0);let resultLock=NSLock();var received:(UUID,Result<Data,Error>)?
        let id=worker.start(request:request,executable:helper,models:models,reservedToken:token) { token,result in
            resultLock.lock();received=(token,result);resultLock.unlock();semaphore.signal()
        }
        guard semaphore.wait(timeout:.now()+limit) == .success else{return nil}
        resultLock.lock();let value=received;resultLock.unlock()
        return value ?? (id,.failure(SpeakerRefinementJobError.invalidOutput))
    }
    let worker=SpeakerRefinementJob(timeout:5)
    guard let successful=waitForResult(worker,request:["snapshot":"synthetic"],models:successModels) else{throw Failure(code:"speaker_refinement_success_timeout")}
    if case .success(let bytes)=successful.1 {
        let object=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any]
        try check(object?["candidate"] as? Bool==true,"speaker_refinement_helper_returns_complete_json")
    } else {throw Failure(code:"speaker_refinement_success_failed")}
    try check(!worker.busy && !worker.waiting && worker.isCurrent(successful.0),"speaker_refinement_success_releases_worker_but_keeps_commit_token")

    guard let failed=waitForResult(worker,request:["snapshot":"synthetic"],models:failModels) else{throw Failure(code:"speaker_refinement_failure_timeout")}
    if case .failure(let error)=failed.1,let typed=error as? SpeakerRefinementJobError,typed == .helperFailed(23) {
        try check(true,"speaker_refinement_helper_failure_is_reported")
    } else {throw Failure(code:"speaker_refinement_failure_contract_"+String(describing:failed.1))}
    guard let retried=waitForResult(worker,request:["snapshot":"retry"],models:successModels) else{throw Failure(code:"speaker_refinement_retry_timeout")}
    if case .success=retried.1 {try check(true,"speaker_refinement_same_worker_retries_after_failure")}
    else {throw Failure(code:"speaker_refinement_retry_failed")}

    guard let oversized=waitForResult(worker,request:["snapshot":"synthetic"],models:largeModels) else{throw Failure(code:"speaker_refinement_output_limit_timeout")}
    if case .failure(let error)=oversized.1,(error as? SpeakerRefinementJobError) == .outputTooLarge {
        try check(true,"speaker_refinement_stdout_is_capped_at_two_megabytes")
    } else {throw Failure(code:"speaker_refinement_output_limit_contract")}
    guard let malformed=waitForResult(worker,request:["snapshot":"synthetic"],models:invalidModels) else{throw Failure(code:"speaker_refinement_json_validation_timeout")}
    if case .failure(let error)=malformed.1,(error as? SpeakerRefinementJobError) == .invalidOutput {
        try check(true,"speaker_refinement_rejects_incomplete_json_output")
    } else {throw Failure(code:"speaker_refinement_json_validation_contract_"+String(describing:malformed.1))}
    guard let invalid=waitForResult(worker,request:["large":String(repeating:"x",count:65*1024)],models:successModels) else{throw Failure(code:"speaker_refinement_request_limit_timeout")}
    if case .failure(let error)=invalid.1,(error as? SpeakerRefinementJobError) == .invalidRequest {
        try check(true,"speaker_refinement_stdin_request_is_capped_at_64kib")
    } else {throw Failure(code:"speaker_refinement_request_limit_contract")}

    let timeoutWorker=SpeakerRefinementJob(timeout:0.35)
    guard let timed=waitForResult(timeoutWorker,request:["snapshot":"synthetic"],models:slowModels,limit:4) else{throw Failure(code:"speaker_refinement_timeout_wait")}
    if case .failure(let error)=timed.1,(error as? SpeakerRefinementJobError) == .timeout {
        try check(true,"speaker_refinement_timeout_terminates_owned_helper")
    } else {throw Failure(code:"speaker_refinement_timeout_contract")}

    let cancelWorker=SpeakerRefinementJob(timeout:4)
    let finished=DispatchSemaphore(value:0),resultLock=NSLock()
    var late:(UUID,Result<Data,Error>)?
    let marker=URL(fileURLWithPath:slowModels.path+".started")
    try? FileManager.default.removeItem(at:marker)
    let cancelledToken=cancelWorker.start(request:["snapshot":"synthetic"],executable:helper,models:slowModels) { token,result in
        resultLock.lock();late=(token,result);resultLock.unlock();finished.signal()
    }
    // Wait until the synthetic helper has consumed stdin and entered its slow
    // section, then cancel without waiting for inference.
    let launchDeadline=Date().addingTimeInterval(2)
    while !FileManager.default.fileExists(atPath:marker.path),Date()<launchDeadline {Thread.sleep(forTimeInterval:0.01)}
    guard FileManager.default.fileExists(atPath:marker.path) else{throw Failure(code:"speaker_refinement_cancel_setup")}
    cancelWorker.cancel()
    try check(!cancelWorker.isCurrent(cancelledToken),"speaker_refinement_cancel_invalidates_result_token")
    guard finished.wait(timeout:.now()+4) == .success else{throw Failure(code:"speaker_refinement_cancel_cleanup_timeout")}
    resultLock.lock();let lateValue=late;resultLock.unlock()
    if let lateValue,case .failure(let error)=lateValue.1,(error as? SpeakerRefinementJobError) == .cancelled {
        try check(true,"speaker_refinement_cancel_discards_late_helper_result")
    } else {throw Failure(code:"speaker_refinement_cancel_late_result_contract")}

    let stale=cancelWorker.reserve(),current=cancelWorker.reserve()
    try check(!cancelWorker.isCurrent(stale) && cancelWorker.isCurrent(current),"speaker_refinement_new_snapshot_invalidates_prior_manual_state_token")
    var committed=false
    do {try cancelWorker.commitIfCurrent(stale){committed=true};throw Failure(code:"speaker_refinement_stale_commit_accepted")}
    catch SpeakerRefinementJobError.cancelled {}
    try check(!committed,"speaker_refinement_stale_result_cannot_commit_after_state_change")
    try cancelWorker.commitIfCurrent(current){committed=true}
    try check(committed,"speaker_refinement_current_result_can_commit")
    cancelWorker.cancel()
    return checks
}
