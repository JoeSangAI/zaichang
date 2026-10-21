import AppKit

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

// The standalone build has no global identity adapter or query side effect.
@MainActor func sharedPersonIdentityServiceChecks(directory:URL) throws->[String:Any] {
    _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
    let service=SharedPersonIdentityService(root:directory.path)
    var result:Result<[SharedPersonCandidate],Error>?
    service.search(query:"synthetic"){result=$0}
    let deadline=Date().addingTimeInterval(2)
    while result == nil && Date()<deadline {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}
    guard let result,case .failure(let error)=result,case SharedPersonIdentityError.unavailable=error else {throw SharedPersonIdentityError.invalidData}
    return ["count":1,"synthetic_only":true,"checks":["portable_edition_has_no_global_shared_person_lookup"]]
}
