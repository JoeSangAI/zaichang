import Foundation

// The public edition owns one private, per-user data root. Child processes
// inherit the resolved path so the recorder and UI always use the same store.
enum RuntimeConfiguration {
    static var standalone: Bool {
        if ProcessInfo.processInfo.environment["ZAICHANG_EDITION"] == "joe" { return false }
        return Bundle.main.object(forInfoDictionaryKey: "ZaichangEdition") as? String != "joe"
    }

    static func dataRoot(info: [String: Any] = Bundle.main.infoDictionary ?? [:],
                         environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["ZAICHANG_DATA_ROOT"], path.hasPrefix("/"),
           !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        let name = (info["DataRootName"] as? String).flatMap {
            !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." ? $0 : nil
        } ?? "ZaichangStandalone"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }

    static func adapterRoot(bundle: Bundle = .main) -> URL {
        if bundle.object(forInfoDictionaryKey: "SelfContainedRuntime") as? Bool == true {
            var parent = bundle.bundleURL.deletingLastPathComponent()
            while parent.path != "/" {
                if parent.pathExtension == "app", let owner = Bundle(url: parent),
                   owner.object(forInfoDictionaryKey: "SelfContainedRuntime") as? Bool == true,
                   let resources = owner.resourceURL {
                    return resources.appendingPathComponent("Runtime", isDirectory: true)
                }
                parent.deleteLastPathComponent()
            }
        }
        if let path = bundle.object(forInfoDictionaryKey: "AdapterRoot") as? String, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return bundle.resourceURL!.appendingPathComponent("Runtime", isDirectory: true)
    }

    static func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["ZAICHANG_DATA_ROOT"] = dataRoot().path
        environment["ZAICHANG_EDITION"] = standalone ? "standalone" : "joe"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return environment
    }
}

enum PythonRuntime {
    static let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
    static func select(_ paths:[String], probe:(String)->Bool)->URL? {
        paths.first(where:probe).map { URL(fileURLWithPath:$0) }
    }
    static let resolved:URL? = select(candidates) { path in
        guard FileManager.default.isExecutableFile(atPath:path) else{return false}
        let process=Process(),ended=DispatchSemaphore(value:0)
        process.executableURL=URL(fileURLWithPath:path)
        process.arguments=["-I","-c","import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)"]
        process.standardInput=FileHandle.nullDevice;process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        process.terminationHandler={_ in ended.signal()}
        do {try process.run()}catch{return false}
        guard ended.wait(timeout:.now()+3) == .success else{process.terminate();return false}
        return process.terminationStatus==0
    }
    static func executable()->URL? {resolved}
}
