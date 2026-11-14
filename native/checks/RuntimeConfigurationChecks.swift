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
    // No "time_zone" in connectors.json: 在场 follows the Mac. One named there holds against the Mac's zone,
    // also for a meeting recorded while the Mac was set elsewhere. Only an isolated QA data root is touched.
    let york:[String:Any]=["schema":1,"basis":"capture_clock","time_zone":"America/New_York","anchors":[["relative_start":0.0,"unix_time":1793844955.5]]]
    let connectorsFile=RuntimeConfiguration.dataRoot().appendingPathComponent("connectors.json")
    if ProcessInfo.processInfo.environment["ZAICHANG_DATA_ROOT"] != nil,!FileManager.default.fileExists(atPath:connectorsFile.path) {
        let zoneBefore=NSTimeZone.default,environment=ProcessInfo.processInfo.environment
        defer {
            NSTimeZone.default=zoneBefore
            for name in ["TZ",MeetingAbsoluteTime.pinnedZoneVariable] {if let value=environment[name] {setenv(name,value,1)}else{unsetenv(name)}}
            try? FileManager.default.removeItem(at:connectorsFile)
        }
        RuntimeConfiguration.applyMeetingZone()
        try check(RuntimeConfiguration.pinnedZone==nil && MeetingAbsoluteTime(york)?.display(0)=="21:15:55" && MeetingAbsoluteTime(york)?.zone.identifier=="America/New_York","unpinned_follows_the_recorded_zone")
        try FileManager.default.createDirectory(at:connectorsFile.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:["schema":1,"time_zone":"Asia/Shanghai"]).write(to:connectorsFile)
        RuntimeConfiguration.applyMeetingZone()
        let read=MeetingAbsoluteTime(york)
        try check(RuntimeConfiguration.pinnedZone?.identifier=="Asia/Shanghai" && read?.display(0)=="10:15:55" && read?.iso(0)=="2026-11-05T10:15:55.500+08:00","pinned_zone_reads_a_new_york_meeting_in_china_time")
        try check(TimeZone.current.identifier=="Asia/Shanghai" && RuntimeConfiguration.childEnvironment()["TZ"]=="Asia/Shanghai","pinned_zone_reaches_formatters_and_children")
    }
    return checks
}
