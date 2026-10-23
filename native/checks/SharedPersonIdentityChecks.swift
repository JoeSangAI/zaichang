import Foundation

func sharedPersonIdentityChecks() throws->[String:Any] {
    let reference=SharedPersonReference(id:"person:0123456789abcdef0123",name:"合成人物",evidence:["/tmp/synthetic/people.md"])
    _=try reference.validated()
    let encoded=try JSONEncoder().encode(reference)
    let decoded=try JSONDecoder().decode(SharedPersonReference.self,from:encoded);precondition(decoded==reference)
    var checks=["reference_codable_round_trip"]
    for invalid in [SharedPersonReference(id:reference.id,name:reference.name,evidence:(0..<9).map{"/tmp/evidence-\($0).md"}),
                    SharedPersonReference(id:reference.id,name:reference.name,evidence:["/"+String(repeating:"a",count:2048)]),
                    SharedPersonReference(id:reference.id+"\n",name:reference.name,evidence:reference.evidence),
                    SharedPersonReference(id:"person:guessed",name:"合成",evidence:reference.evidence),
                    SharedPersonReference(id:reference.id,name:"坏\u{0}姓名",evidence:reference.evidence),
                    SharedPersonReference(id:reference.id,name:reference.name,evidence:[]),
                    SharedPersonReference(id:reference.id,name:reference.name,evidence:["/tmp/../private/file"])] {
        do {_=try invalid.validated();preconditionFailure("invalid identity accepted")}catch{}
    }
    checks.append("invalid_id_control_character_missing_and_noncanonical_evidence_rejected")
    let candidate=SharedPersonCandidate(reference:reference,organization:"合成组织",role:"合成角色")
    let object:[String:Any] = ["schema":1,"status":"ok","requires_confirmation":true,"candidates":[try JSONSerialization.jsonObject(with:JSONEncoder().encode(candidate))]]
    let payload=try JSONSerialization.data(withJSONObject:object)
    let decodedCandidates=try decodeSharedPersonCandidates(payload);precondition(decodedCandidates==[candidate])
    checks.append("candidate_keeps_evidence_and_disambiguation_without_binding")
    var unconfirmed=object;unconfirmed["requires_confirmation"]=false
    do {_=try decodeSharedPersonCandidates(JSONSerialization.data(withJSONObject:unconfirmed));preconditionFailure("unconfirmed protocol accepted")}catch{}
    var duplicate=object;duplicate["candidates"]=Array(repeating:try JSONSerialization.jsonObject(with:JSONEncoder().encode(candidate)),count:2)
    do {_=try decodeSharedPersonCandidates(JSONSerialization.data(withJSONObject:duplicate));preconditionFailure("duplicate ids accepted")}catch{}
    do {_=try decodeSharedPersonCandidates(Data(repeating:32,count:128*1024+1));preconditionFailure("oversized response accepted")}catch{}
    checks.append("unconfirmed_duplicate_and_oversized_responses_rejected")
    return ["checks":checks,"count":checks.count,"synthetic_only":true]
}

// Caller supplies an isolated temporary directory. No real people, audio or
// external service is used by these process/cancellation checks.
func sharedPersonIdentityServiceChecks(directory:URL) throws->[String:Any] {
    let target=directory.standardizedFileURL.resolvingSymlinksInPath()
    let temporary=URL(fileURLWithPath:NSTemporaryDirectory()).resolvingSymlinksInPath().path
    guard target.path.hasPrefix(temporary+"/") || target.path.hasPrefix("/private/tmp/") else{throw SharedPersonIdentityError.invalidData}
    try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
    let script="""
    import json,sys,time
    query=sys.argv[-1]
    if query=='slow': time.sleep(10)
    if query=='delay': time.sleep(.2)
    print(json.dumps({'schema':1,'status':'ok','requires_confirmation':True,'candidates':[{'reference':{'id':'person:0123456789abcdef0123','name':'synthetic','evidence':['/tmp/synthetic/people.md']},'organization':'fixture','role':'fixture'}]}))
    """
    try script.write(to:target.appendingPathComponent("shared_people.py"),atomically:true,encoding:.utf8)
    func wait(_ predicate:()->Bool,seconds:Double=5) throws {
        let deadline=Date().addingTimeInterval(seconds)
        while !predicate(),Date()<deadline {_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}
        guard predicate() else{throw SharedPersonIdentityError.timeout}
    }
    let service=SharedPersonIdentityService(root:target.path)
    var result:Result<[SharedPersonCandidate],Error>?,callbacks=0
    service.search(query:"delay"){_ in callbacks+=100}
    service.search(query:"normal"){result=$0;callbacks+=1}
    try wait{result != nil}
    let candidates=try result!.get();precondition(callbacks==1 && candidates.first?.reference.name=="synthetic")
    let settle=Date().addingTimeInterval(0.3)
    while Date()<settle {_=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}
    precondition(callbacks==1)
    result=nil
    service.search(query:"slow"){result=$0}
    try wait{result != nil}
    guard case .failure(let error)=result!,case SharedPersonIdentityError.timeout=error else{throw SharedPersonIdentityError.invalidData}
    result=nil
    let missing=SharedPersonIdentityService(root:target.appendingPathComponent("missing").path)
    missing.search(query:"normal"){result=$0}
    try wait{result != nil}
    guard case .failure=result! else{throw SharedPersonIdentityError.invalidData}
    return ["count":3,"synthetic_only":true,"checks":["superseded_query_cannot_deliver_or_bind","hung_helper_has_bounded_timeout","missing_query_adapter_is_explicitly_unavailable"]]
}
