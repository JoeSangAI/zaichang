import Foundation
import Darwin

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

// Query-only service. This owns no binding: the UI must require a deliberate
// candidate selection and confirmation before persisting SharedPersonReference.
final class SharedPersonIdentityService {
    private let root:String,pythonExecutable:String
    private let lock=NSLock()
    private var generation=UUID()
    private var active:Process?
    init(root:String,pythonExecutable:String="/usr/local/bin/python3") {
        self.root=root;self.pythonExecutable=pythonExecutable
    }
    func cancel() {
        lock.lock();generation=UUID();let process=active;active=nil;lock.unlock()
        if let process,process.isRunning {process.terminate()}
    }
    func search(query:String,completion:@escaping(Result<[SharedPersonCandidate],Error>)->Void) {
        guard RuntimeConfiguration.peopleEnabled else{completion(.success([]));return}
        cancel()
        lock.lock();let token=generation;lock.unlock()
        let root=self.root,python=self.pythonExecutable
        DispatchQueue.global(qos:.userInitiated).async {[weak self] in
            guard let self else{return}
            let result:Result<[SharedPersonCandidate],Error>
            do {
                guard sharedPersonTextValid(query,limit:80) else{throw SharedPersonIdentityError.invalidQuery}
                let script=URL(fileURLWithPath:root,isDirectory:true).appendingPathComponent("shared_people.py")
                guard script.path==script.standardizedFileURL.path,script.resolvingSymlinksInPath().path==script.path,
                      let attributes=try? FileManager.default.attributesOfItem(atPath:script.path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1024*1024 else{throw SharedPersonIdentityError.unavailable}
                let process=Process(),pipe=Pipe(),ended=DispatchSemaphore(value:0)
                process.executableURL=URL(fileURLWithPath:python)
                process.arguments=["-B",script.path,"--query",query]
                var environment=RuntimeConfiguration.childEnvironment()
                environment["PYTHONDONTWRITEBYTECODE"]="1"
                for key in ["PYTHONPATH","PYTHONHOME","PYTHONSTARTUP"] {environment.removeValue(forKey:key)}
                process.environment=environment;process.standardInput=FileHandle.nullDevice
                process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
                process.terminationHandler={_ in ended.signal()}
                self.lock.lock()
                guard self.generation==token else{self.lock.unlock();return}
                do {try process.run();self.active=process;self.lock.unlock()}
                catch {self.lock.unlock();throw SharedPersonIdentityError.unavailable}
                // The CLI bounds output. Drain concurrently so a broken helper
                // cannot fill stdout and deadlock the process deadline.
                let outputLock=NSLock(),readDone=DispatchSemaphore(value:0)
                var output=Data(),overflow=false
                DispatchQueue.global(qos:.utility).async {
                    defer {readDone.signal()}
                    while true {
                        let data=pipe.fileHandleForReading.availableData
                        if data.isEmpty {break}
                        outputLock.lock()
                        if output.count+data.count>128*1024 {overflow=true}
                        else if !overflow {output.append(data)}
                        let exceeded=overflow;outputLock.unlock()
                        if exceeded,process.isRunning {process.terminate()}
                    }
                }
                let timedOut=ended.wait(timeout:.now()+3.5) != .success
                if timedOut {
                    if process.isRunning {process.terminate()}
                    if ended.wait(timeout:.now()+0.25) != .success,process.isRunning {_=Darwin.kill(process.processIdentifier,SIGKILL);_=ended.wait(timeout:.now()+0.25)}
                }
                _=readDone.wait(timeout:.now()+0.25)
                outputLock.lock();let data=output,exceeded=overflow;outputLock.unlock()
                if timedOut {throw SharedPersonIdentityError.timeout}
                guard !exceeded else{throw SharedPersonIdentityError.invalidData}
                guard process.terminationStatus==0 else{throw SharedPersonIdentityError.unavailable}
                result = .success(try decodeSharedPersonCandidates(data))
            } catch {result = .failure(error)}
            self.lock.lock();let current=self.generation==token;if current {self.active=nil};self.lock.unlock()
            guard current else{return}
            DispatchQueue.main.async {[weak self] in
                guard let self else{return};self.lock.lock();let current=self.generation==token;self.lock.unlock()
                if current {completion(result)}
            }
        }
    }
    deinit {if let active,active.isRunning {active.terminate()}}
}
