import Foundation

enum SharedPersonIdentityError: Error, LocalizedError {
    case invalidQuery, invalidData, unavailable, timeout
    var errorDescription:String? {
        switch self {
        case .invalidQuery:return "请输入姓名或已确认的别名"
        case .invalidData:return "人物资料格式异常，暂时无法关联"
        case .unavailable:return "共享人物资料暂不可用，请稍后重试"
        case .timeout:return "人物查询超时，请重试"
        }
    }
}

private func sharedPersonTextValid(_ value:String,limit:Int,allowEmpty:Bool=false)->Bool {
    value.count<=limit && (allowEmpty || !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) &&
        !value.unicodeScalars.contains{CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format || $0.properties.generalCategory == .privateUse || $0.properties.generalCategory == .unassigned}
}

struct SharedPersonReference: Codable, Equatable {
    let id:String
    let name:String
    let evidence:[String]
    init(id:String,name:String,evidence:[String]) {self.id=id;self.name=name;self.evidence=evidence}
    func validated() throws->Self {
        guard id.utf8.count==27,id.range(of:"^person:[0-9a-f]{20}$",options:.regularExpression) != nil,
              sharedPersonTextValid(name,limit:80),!evidence.isEmpty,evidence.count<=8,
              Set(evidence).count==evidence.count else{throw SharedPersonIdentityError.invalidData}
        for path in evidence {
            guard sharedPersonTextValid(path,limit:2048),path.hasPrefix("/"),
                  !path.split(separator:"/",omittingEmptySubsequences:false).contains(".."),
                  URL(fileURLWithPath:path).standardizedFileURL.path==path else{throw SharedPersonIdentityError.invalidData}
        }
        return self
    }
}

struct SharedPersonCandidate: Codable, Equatable {
    let reference:SharedPersonReference
    let organization:String
    let role:String
    init(reference:SharedPersonReference,organization:String="",role:String="") {
        self.reference=reference;self.organization=organization;self.role=role
    }
    func validated() throws->Self {
        _=try reference.validated()
        guard sharedPersonTextValid(organization,limit:240,allowEmpty:true),sharedPersonTextValid(role,limit:240,allowEmpty:true) else{throw SharedPersonIdentityError.invalidData}
        return self
    }
}

private struct SharedPersonQueryResponse:Decodable {
    let schema:Int
    let status:String
    let requires_confirmation:Bool
    let candidates:[SharedPersonCandidate]
}

func decodeSharedPersonCandidates(_ data:Data) throws->[SharedPersonCandidate] {
    guard data.count<=128*1024 else{throw SharedPersonIdentityError.invalidData}
    let response:SharedPersonQueryResponse
    do {response=try JSONDecoder().decode(SharedPersonQueryResponse.self,from:data)}
    catch {throw SharedPersonIdentityError.invalidData}
    guard response.schema==1,response.requires_confirmation else{throw SharedPersonIdentityError.invalidData}
    guard response.status=="ok" else{throw SharedPersonIdentityError.unavailable}
    guard response.candidates.count<=20,Set(response.candidates.map{ $0.reference.id }).count==response.candidates.count else{throw SharedPersonIdentityError.invalidData}
    return try response.candidates.map{try $0.validated()}
}

// The portable edition deliberately has no connection to a private shared-person
// index. Users can confirm speaker labels locally for each recording.
final class SharedPersonIdentityService {
    init(root: String = "", pythonExecutable: String? = nil) {}
    func cancel() {}
    func search(query: String, completion: @escaping (Result<[SharedPersonCandidate], Error>) -> Void) {
        DispatchQueue.main.async { completion(.failure(SharedPersonIdentityError.unavailable)) }
    }
}
