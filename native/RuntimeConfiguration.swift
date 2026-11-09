import Foundation
import CoreFoundation

// Shared by the UI and capture helper. There is one app, so one identity: the data path
// is the only thing a child inherits, and only so tests can point it somewhere isolated.
enum RuntimeConfiguration {
    /// Where tools the user installed live; a GUI app does not inherit their shell's PATH.
    static var toolSearchPaths:[String] {["/usr/local/bin","/opt/homebrew/bin",NSHomeDirectory()+"/.local/bin",NSHomeDirectory()+"/.codex/bin","/usr/bin","/bin"]}
    /// Whatever Python 3 the user installed runs the workers, any version from any installer (python.org, Homebrew, uv,
    /// pyenv, conda, Apple's developer tools): the first that already has certifi and numpy, found once per launch.
    /// The shell's PATH never reaches a GUI app, so the usual homes are tried in turn; /usr/bin/python3 is skipped
    /// because without developer tools it opens an install prompt instead of running.
    static let python:String=findPython()
    static func pythonCandidates(home:String=NSHomeDirectory(),fileManager:FileManager = .default)->[String] {
        var directories=["/usr/local/bin","/opt/homebrew/bin",home+"/.local/bin",home+"/.pyenv/shims"]
        for base in ["miniconda3","anaconda3","miniforge3","mambaforge"] {directories+=[home+"/"+base+"/bin","/opt/"+base+"/bin","/opt/homebrew/Caskroom/"+base.replacingOccurrences(of:"3",with:"")+"/base/bin"]}
        let framework="/Library/Frameworks/Python.framework/Versions"
        directories+=((try? fileManager.contentsOfDirectory(atPath:framework)) ?? []).filter{$0.hasPrefix("3.")}
            .sorted{$0.compare($1,options:.numeric) == .orderedDescending}.map{framework+"/"+$0+"/bin"}
        directories+=["/Library/Developer/CommandLineTools/usr/bin","/Applications/Xcode.app/Contents/Developer/usr/bin"]
        var found:[String]=[]
        for directory in directories {
            // python3 first, then versioned names newest first (Homebrew's python@3.x only installs those).
            let versioned=((try? fileManager.contentsOfDirectory(atPath:directory)) ?? []).filter{name in
                name.hasPrefix("python3.") && name.dropFirst(8).allSatisfy(\.isNumber) && !name.dropFirst(8).isEmpty}
                .sorted{$0.compare($1,options:.numeric) == .orderedDescending}
            for name in ["python3"]+versioned {
                let path=directory+"/"+name
                if !found.contains(path),fileManager.isExecutableFile(atPath:path) {found.append(path)}
            }
        }
        return found
    }
    static func findPython(candidates:[String]=pythonCandidates())->String {
        for path in candidates where pythonIsReady(path) {return path}
        return candidates.first ?? "/usr/local/bin/python3"
    }
    static func pythonIsReady(_ path:String,timeout:TimeInterval=15)->Bool {
        let process=Process();process.executableURL=URL(fileURLWithPath:path);process.arguments=["-c","import certifi, numpy"]
        var environment=ProcessInfo.processInfo.environment
        for key in ["PYTHONPATH","PYTHONHOME","PYTHONSTARTUP"] {environment.removeValue(forKey:key)}
        environment["PYTHONDONTWRITEBYTECODE"]="1";process.environment=environment
        process.standardInput=FileHandle.nullDevice;process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        let done=DispatchSemaphore(value:0);process.terminationHandler={_ in done.signal()}
        guard (try? process.run()) != nil else{return false}
        if done.wait(timeout:.now()+timeout) == .timedOut {process.terminate();return false}
        return process.terminationStatus==0
    }
    static let bailianService="com.joesang.zaichang.standalone.bailian"
    static let identityService="com.zaichang.app.identity-v2"
    static func dataRoot(info:[String:Any]=Bundle.main.infoDictionary ?? [:],environment:[String:String]=ProcessInfo.processInfo.environment)->URL {
        if let path=environment["ZAICHANG_DATA_ROOT"],path.hasPrefix("/"),!path.split(separator:"/").contains("..") {return URL(fileURLWithPath:path,isDirectory:true)}
        if let name=environment["ZAICHANG_DATA_ROOT"],!name.isEmpty,!name.contains("/"),name != ".",name != ".." {return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent(name,isDirectory:true)}
        let name=(info["DataRootName"] as? String).flatMap{!$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." ? $0:nil} ?? "ZaichangStandalone"
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent(name,isDirectory:true)
    }
    // Optional connectors are independent of bundle identity and safe to omit.
    static var connectors:[String:Any] {
        let url=dataRoot().appendingPathComponent("connectors.json")
        guard let size=(try? url.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size<=65536,
              let data=try? Data(contentsOf:url),let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let schema=value["schema"] as? NSNumber,CFGetTypeID(schema) != CFBooleanGetTypeID(),schema.intValue==1,schema.doubleValue==1 else{return [:]}
        return value
    }
    static var archiveConfiguration:(url:String,appID:String)? {
        guard let archive=connectors["archive"] as? [String:Any],let raw=archive["url"] as? String,
              let url=URLComponents(string:raw),["http","https"].contains(url.scheme ?? ""),let host=url.host,!host.isEmpty,
              url.user==nil,url.password==nil,url.query==nil,url.fragment==nil,
              let appID=archive["app_id"] as? String,!appID.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return nil}
        return (raw.hasSuffix("/") ? String(raw.dropLast()):raw,appID.trimmingCharacters(in:.whitespacesAndNewlines))
    }
    static var archiveEnabled:Bool {archiveConfiguration != nil}
    static var peopleEnabled:Bool {
        guard let loader=connectors["people_loader"] as? String,!loader.isEmpty,
              let roots=connectors["project_roots"] as? [String],!roots.isEmpty else{return false}
        return true
    }
    static func adapterRoot(bundle:Bundle = .main)->URL {
        if bundle.object(forInfoDictionaryKey:"SelfContainedRuntime") as? Bool != true,
           let path=bundle.object(forInfoDictionaryKey:"AdapterRoot") as? String,!path.isEmpty {return URL(fileURLWithPath:path,isDirectory:true)}
        // The packaged capture helper is nested inside the outer app's Runtime.
        // Resolve the owning bundle after relocation, without a machine-specific path.
        if bundle.object(forInfoDictionaryKey:"SelfContainedRuntime") as? Bool == true {
            var parent=bundle.bundleURL.deletingLastPathComponent()
            while parent.path != "/" {
                if parent.pathExtension == "app",let owner=Bundle(url:parent),
                   owner.object(forInfoDictionaryKey:"SelfContainedRuntime") as? Bool == true,
                   let resources=owner.resourceURL {
                    return resources.appendingPathComponent("Runtime",isDirectory:true)
                }
                parent.deleteLastPathComponent()
            }
        }
        return bundle.resourceURL!.appendingPathComponent("Runtime",isDirectory:true)
    }
    static func childEnvironment()->[String:String] {
        var env=ProcessInfo.processInfo.environment
        env["ZAICHANG_DATA_ROOT"]=dataRoot().path
        // Python must never write bytecode into the signed bundle: one .pyc breaks its seal.
        env["PYTHONDONTWRITEBYTECODE"]="1"
        return env
    }
}

/// What the user calls the assistant. One small file in the app's data
/// directory, read by the UI and by the Python runtime; later persona fields
/// (such as tone) belong in the same file.
enum AssistantProfile {
    static let defaultName="小满"
    static let maxNameLength=12
    static let changed=Notification.Name("ZaichangAssistantProfileChanged")
    static var url:URL {RuntimeConfiguration.dataRoot().appendingPathComponent("assistant-profile.json")}
    private(set) static var name:String=load()
    static func validated(_ raw:String)->String? {
        let value=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty,value.count<=maxNameLength,!value.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{return nil}
        return value
    }
    static func load()->String {
        guard let size=(try? url.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size<=4096,
              let data=try? Data(contentsOf:url),let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let schema=value["schema"] as? NSNumber,schema.intValue==1,let stored=value["name"] as? String else{return defaultName}
        return validated(stored) ?? defaultName
    }
    /// Saves the name (an invalid or empty one restores the default) and tells open windows.
    static func save(name raw:String) throws {
        let value=validated(raw) ?? defaultName
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        let data=try JSONSerialization.data(withJSONObject:["schema":1,"name":value],options:[.sortedKeys])
        try data.write(to:url,options:.atomic)
        name=value;NotificationCenter.default.post(name:changed,object:nil)
    }
}
