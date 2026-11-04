import Foundation
import CoreFoundation

// Shared by the UI and capture helper. There is one app, so one identity: the data path
// is the only thing a child inherits, and only so tests can point it somewhere isolated.
enum RuntimeConfiguration {
    /// Where tools the user installed live; a GUI app does not inherit their shell's PATH.
    static var toolSearchPaths:[String] {["/usr/local/bin","/opt/homebrew/bin",NSHomeDirectory()+"/.local/bin",NSHomeDirectory()+"/.codex/bin","/usr/bin","/bin"]}
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
    /// What the user is called in meetings, so the overview can put their own to-dos first. Empty until they say.
    private(set) static var myNames:[String]=loadMyNames()
    static let maxMyNames=6
    private static func stored()->[String:Any] {
        guard let size=(try? url.resourceValues(forKeys:[.fileSizeKey]))?.fileSize,size<=4096,
              let data=try? Data(contentsOf:url),let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              let schema=value["schema"] as? NSNumber,schema.intValue==1 else{return [:]}
        return value
    }
    static func load()->String {
        guard let stored=stored()["name"] as? String else{return defaultName}
        return validated(stored) ?? defaultName
    }
    static func loadMyNames()->[String] {myNames(from:(stored()["me"] as? [String] ?? []).joined(separator:"、"))}
    /// "林岚、小林，Lan" → each valid name once, in order.
    static func myNames(from raw:String)->[String] {
        var seen=Set<String>()
        return raw.components(separatedBy:CharacterSet(charactersIn:"、，,;；/\n")).compactMap(validated).filter{seen.insert($0.lowercased()).inserted}.prefix(maxMyNames).map{$0}
    }
    private static func write(_ fields:[String:Any]) throws {
        var value=stored();value["schema"]=1;for (key,field) in fields {value[key]=field}
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:url,options:.atomic)
    }
    /// Saves the name (an invalid or empty one restores the default) and tells open windows.
    static func save(name raw:String) throws {
        let value=validated(raw) ?? defaultName
        try write(["name":value])
        name=value;NotificationCenter.default.post(name:changed,object:nil)
    }
    static func save(myNames raw:String) throws {
        let values=myNames(from:raw)
        try write(["me":values])
        myNames=values;NotificationCenter.default.post(name:changed,object:nil)
    }
}
