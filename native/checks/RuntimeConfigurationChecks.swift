import Foundation

func runtimeConfigurationChecks() throws -> [String] {
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {
        guard value else{throw Failure(code:"runtime_configuration_"+name)}
        checks.append(name)
    }
    let absolute=RuntimeConfiguration.dataRoot(environment:["ZAICHANG_DATA_ROOT":"/tmp/zaichang-test-data"])
    try check(absolute.path=="/tmp/zaichang-test-data","absolute_data_root_override")
    let invalid=RuntimeConfiguration.dataRoot(info:["DataRootName":"SafeName"],environment:["ZAICHANG_DATA_ROOT":"../outside"])
    try check(invalid.lastPathComponent=="SafeName","traversal_override_rejected")
    let defaultRoot=RuntimeConfiguration.dataRoot(info:[:],environment:[:])
    try check(defaultRoot.lastPathComponent=="ZaichangStandalone","standalone_data_root_default")
    let selected=PythonRuntime.select(["missing","usable"]) {$0=="usable"}
    try check(selected?.path=="/usable","python_runtime_candidate_selection")
    return checks
}
