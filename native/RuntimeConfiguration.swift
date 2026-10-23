import Foundation
import CoreFoundation

// Shared by the UI and capture helper. Edition comes from the signed bundle;
// only the data path is inherited when the UI launches a child.
enum RuntimeConfiguration {
    static func edition(info:[String:Any]=Bundle.main.infoDictionary ?? [:], environment:[String:String]=ProcessInfo.processInfo.environment)->String {
        // Bundle identity wins; unbundled tools can inherit an explicit edition.
        let value=(info["ZaichangEdition"] as? String) ?? environment["ZAICHANG_EDITION"]
        return value == "standalone" ? "standalone":"joe"
    }
    static var standalone:Bool {edition() == "standalone"}
    static var bailianService:String {standalone ? "com.joesang.zaichang.standalone.bailian":"com.joesang.meeting-assistant.bailian"}
    static var identityService:String {standalone ? "com.zaichang.app.identity-v2":"com.joesang.meeting-assistant.identity-v2"}
    static func dataRoot(legacyJoeIdentity:Bool=false,info:[String:Any]=Bundle.main.infoDictionary ?? [:],environment:[String:String]=ProcessInfo.processInfo.environment)->URL {
        if let path=environment["ZAICHANG_DATA_ROOT"],path.hasPrefix("/"),!path.split(separator:"/").contains("..") {return URL(fileURLWithPath:path,isDirectory:true)}
        if let name=environment["ZAICHANG_DATA_ROOT"],!name.isEmpty,!name.contains("/"),name != ".",name != ".." {return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent(name,isDirectory:true)}
        // Retired encrypted identity storage keeps its ExampleUser path for compatibility.
        // An explicit DataRootName always wins, including for this legacy caller.
        let name=(info["DataRootName"] as? String).flatMap{!$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." ? $0:nil} ?? (edition(info:info,environment:environment) == "standalone" ? "ZaichangStandalone":(legacyJoeIdentity ? "JoeMeetingAssistant":"MeetingAssistant"))
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
        env["ZAICHANG_EDITION"]=standalone ? "standalone":"joe"
        return env
    }
}
