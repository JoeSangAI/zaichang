import Foundation

func appUpdateChecks()throws->[String] {
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:"app_update_"+name)};checks.append(name)}
    try check(!AppUpdater.enabled,"qa_never_reaches_the_network")
    try check(AppUpdater.isNewer("0.4.10",than:"0.4.9") && !AppUpdater.isNewer("0.4.9",than:"0.4.10"),"versions_compare_as_numbers")
    try check(!AppUpdater.isNewer("0.4.9",than:"0.4.9") && AppUpdater.isNewer("0.5",than:"0.4.9"),"same_version_is_not_new")
    let feed=#"{"version":"0.4.9","notes":"- 新","sha256":"AA","zip":"https://example.com/a.zip","patch":{"zip":"https://example.com/b.zip","sha256":"BB","models":"M"}}"#
    let release=AppUpdater.release(from:Data(feed.utf8))
    try check(release?.version=="0.4.9" && release?.whole.models==nil && release?.small?.models=="M","feed_reads_both_packages")
    let plain=#"{"version":"0.4.9","sha256":"AA","zip":"http://example.com/a.zip"}"#
    try check(AppUpdater.release(from:Data(plain.utf8))==nil,"plain_http_refused")
    try check(AppUpdater.release(from:Data("not json".utf8))==nil,"broken_feed_is_no_update")
    let log="# Changelog\n\n## 0.4.10 — d\n\n- 甲\n\n## 0.4.9 — d\n\n- 乙\n\n## 0.4.8 — d\n\n- 丙\n"
    try check(AppUpdater.changes(in:log,since:"0.4.9")=="- 甲","one_version_needs_no_heading")
    let several=AppUpdater.changes(in:log,since:"0.4.8")
    try check(several.contains("0.4.10") && several.contains("- 乙") && !several.contains("- 丙"),"several_versions_keep_their_headings")
    try check(AppUpdater.requirement.contains("com.joesang.zaichang.standalone") && AppUpdater.requirement.contains(AppUpdater.teamID),"only_the_release_identity_installs")
    return checks
}
