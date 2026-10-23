import Foundation

func runtimeConfigurationChecks() throws -> [String] {
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {
        guard value else{throw Failure(code:"runtime_configuration_"+name)}
        checks.append(name)
    }
    try check(RuntimeConfiguration.edition(info:[:],environment:[:])=="joe","default_joe")
    try check(RuntimeConfiguration.edition(info:["ZaichangEdition":"joe"],environment:["ZAICHANG_EDITION":"standalone"])=="joe","bundle_identity_wins")
    try check(RuntimeConfiguration.edition(info:["ZaichangEdition":"standalone"],environment:["ZAICHANG_EDITION":"joe"])=="standalone","standalone_bundle_wins")
    try check(RuntimeConfiguration.edition(info:[:],environment:["ZAICHANG_EDITION":"other"])=="joe","unknown_defaults_joe")
    for edition in ["joe","standalone"] {
        let info:[String:Any] = ["ZaichangEdition":edition]
        let expected=edition=="joe" ? "MeetingAssistant":"ZaichangStandalone"
        try check(RuntimeConfiguration.dataRoot(info:info,environment:[:]).lastPathComponent==expected,edition+"_data_root")
        try check(RuntimeConfiguration.dataRoot(legacyJoeIdentity:true,info:info,environment:[:]).lastPathComponent==(edition=="joe" ? "JoeMeetingAssistant":expected),edition+"_identity_root")
    }
    try check(RuntimeConfiguration.dataRoot(info:[:],environment:["ZAICHANG_DATA_ROOT":"/tmp/zaichang-test-data"]).path=="/tmp/zaichang-test-data","absolute_override")
    try check(RuntimeConfiguration.dataRoot(info:[:],environment:["ZAICHANG_DATA_ROOT":"SyntheticQA"]).lastPathComponent=="SyntheticQA","named_override")
    for value in ["../outside","/tmp/../outside"] {
        try check(RuntimeConfiguration.dataRoot(info:["ZaichangEdition":"standalone"],environment:["ZAICHANG_DATA_ROOT":value]).lastPathComponent=="ZaichangStandalone","reject_traversal_"+value)
    }
    let env=RuntimeConfiguration.childEnvironment()
    try check(env["ZAICHANG_EDITION"]==RuntimeConfiguration.edition() && env["ZAICHANG_DATA_ROOT"]==RuntimeConfiguration.dataRoot().path,"child_inherits_edition_and_root")
    try check(RuntimeConfiguration.bailianService==(RuntimeConfiguration.standalone ? "com.joesang.zaichang.standalone.bailian":"com.joesang.meeting-assistant.bailian"),"existing_bailian_service")
    try check(RuntimeConfiguration.identityService==(RuntimeConfiguration.standalone ? "com.zaichang.app.identity-v2":"com.joesang.meeting-assistant.identity-v2"),"identity_service_isolation")
    return checks
}
