import Foundation

func runtimeConfigurationChecks() throws -> [String] {
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {
        guard value else{throw Failure(code:"runtime_configuration_"+name)}
        checks.append(name)
    }
    try check(RuntimeConfiguration.dataRoot(info:[:],environment:[:]).lastPathComponent=="ZaichangStandalone","one_data_root")
    try check(RuntimeConfiguration.dataRoot(info:["DataRootName":"SyntheticQA"],environment:[:]).lastPathComponent=="SyntheticQA","qa_bundle_names_its_root")
    try check(RuntimeConfiguration.dataRoot(info:[:],environment:["ZAICHANG_DATA_ROOT":"/tmp/zaichang-test-data"]).path=="/tmp/zaichang-test-data","absolute_override")
    try check(RuntimeConfiguration.dataRoot(info:[:],environment:["ZAICHANG_DATA_ROOT":"SyntheticQA"]).lastPathComponent=="SyntheticQA","named_override")
    for value in ["../outside","/tmp/../outside"] {
        try check(RuntimeConfiguration.dataRoot(info:[:],environment:["ZAICHANG_DATA_ROOT":value]).lastPathComponent=="ZaichangStandalone","reject_traversal_"+value)
    }
    let env=RuntimeConfiguration.childEnvironment()
    try check(env["ZAICHANG_DATA_ROOT"]==RuntimeConfiguration.dataRoot().path && env["ZAICHANG_EDITION"]==nil,"child_inherits_only_the_root")
    try check(env["PYTHONDONTWRITEBYTECODE"]=="1","child_python_cannot_write_into_signed_bundle")
    try check(RuntimeConfiguration.bailianService=="com.joesang.zaichang.standalone.bailian","one_bailian_service")
    try check(RuntimeConfiguration.identityService=="com.zaichang.app.identity-v2","one_identity_service")
    return checks
}
