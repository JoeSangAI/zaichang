import AppKit

@MainActor func editionUIChecks(directory:URL) throws -> [String] {
    guard Credential.offline,directory.path.contains("/.runtime/"),RuntimeConfiguration.dataRoot().path.contains("/.runtime/") else{throw Failure(code:"edition_ui_scope")}
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:"edition_ui_"+name)};checks.append(name)}
    let owner=Delegate();owner.previewRenderOnly=true;owner.recoveryRootOverride=directory.appendingPathComponent("SessionCache")
    owner.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    defer {owner.cancelMeetingMinutes();owner.window.orderOut(nil)}
    try check(owner.archiveButton?.isHidden == !RuntimeConfiguration.archiveEnabled,"archive_visibility_matches_configuration")
    let menu=owner.makeMeetingExportMenu()
    try check(menu.items.map(\.title).contains("导出原文…") && menu.items.map(\.title).contains("导出纪要…"),"both_export_entries_visible")
    try check(menu.items.first?.action == #selector(Delegate.exportVisibleDocument),"transcript_uses_existing_export")
    try check(menu.items.last?.action == #selector(Delegate.beginMeetingMinutes),"minutes_uses_shared_generator")
    try check(menu.items.last?.isEnabled==false,"offline_minutes_cannot_call_cloud")
    try check(Credential.service==RuntimeConfiguration.bailianService,"minutes_and_transcription_share_credential")
    try check(owner.translationSwitch != nil && owner.speakerReviewButton != nil && owner.notesController != nil,"translation_people_notes_retained")
    try check(owner.sheet.sheetParent==nil,"launch_has_no_extra_modal")
    owner.vault.bytes=nil;owner.showMissingCredentialHintIfNeeded()
    if !RuntimeConfiguration.archiveEnabled {
        owner.updateUI()
        try check(owner.diagnostic.stringValue=="去设置里填写百炼密钥" && !owner.diagnostic.isHidden && owner.empty.stringValue=="去设置里填写百炼密钥" && owner.sheet.sheetParent==nil,"first_launch_has_one_visible_next_step_after_repaint")
    }
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    func settingsSnapshot(_ name:String)throws {
        owner.sheet.appearance=NSAppearance(named:.aqua);owner.sheet.layoutIfNeeded()
        try check(owner.savedLabel.isHidden != owner.keyLabel.isHidden,"settings_labels_mutually_exclusive_"+name)
        try check(owner.keyLabel.isHidden==owner.key.isHidden,"settings_key_caption_and_field_share_visibility_"+name)
        let target=owner.sheet.contentView!
        let enteringKey = !owner.key.isHidden
        try check(target.bounds.height==(enteringKey ? 360:300),"settings_height_tracks_visible_input_"+name)
        guard let privacy=target.subviews.first(where:{$0.identifier==NSUserInterfaceItemIdentifier("settings-privacy")}) else {throw Failure(code:"settings_privacy_missing")}
        let credential=enteringKey ? owner.key!:owner.savedLabel!
        let gap=credential.frame.minY-privacy.frame.maxY
        try check(gap>=8 && gap<=14,"settings_privacy_follows_visible_credential_without_hole_"+name)
        let visible=owner.settingsLayoutFrames.map{$0.0}.filter{!$0.isHidden}
        // Keep the exact visible ordering and native frames in the QA receipt,
        // even if a following overlap assertion fails before the PNG is written.
        let layout=visible.enumerated().map {index,view -> [String:Any] in
            let text:String
            if view is NSSecureTextField {text="[secure input]"}
            else if let field=view as? NSTextField {text=field.stringValue}
            else if let button=view as? NSButton {text=button.title}
            else {text=""}
            return ["index":index,"type":String(describing:type(of:view)),"id":view.identifier?.rawValue ?? "","text":text,
                    "frame":[Double(view.frame.minX),Double(view.frame.minY),Double(view.frame.width),Double(view.frame.height)]]
        }
        try JSONSerialization.data(withJSONObject:layout,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent(name+"-layout.json"))
        let moreButtons=visible.filter{["settings-people","settings-balance"].contains($0.identifier?.rawValue ?? "")}
        try check(owner.setupMessage.frame.height>=ceil(owner.setupMessage.font!.ascender-owner.setupMessage.font!.descender+owner.setupMessage.font!.leading),"settings_message_has_full_line_height_"+name)
        for button in moreButtons {try check(owner.setupMessage.frame.minY-button.frame.maxY>=2,"settings_message_clear_of_more_settings_"+name+"_"+button.identifier!.rawValue)}
        for (index,view) in visible.enumerated() {
            try check(target.bounds.contains(view.frame),"settings_content_inside_sheet_"+name+"_\(index)")
            for other in visible.dropFirst(index+1) {try check(!view.frame.intersects(other.frame),"settings_no_visible_overlap_"+name+"_\(index)_\(visible.firstIndex(where:{$0 === other})!)")}
        }
        let bitmap=target.bitmapImageRepForCachingDisplay(in:target.bounds)!
        target.effectiveAppearance.performAsCurrentDrawingAppearance{target.cacheDisplay(in:target.bounds,to:bitmap)}
        try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name+".png"))
    }
    owner.showSettings()
    try settingsSnapshot("settings-no-key")
    try check(!owner.key.isHidden && owner.editing && owner.save.title=="保存密钥","settings_accepts_key_even_for_trial_build")
    owner.key.stringValue="fake_new_key";owner.saveKey()
    try check(owner.vault.load()=="fake_new_key" && !owner.change.isHidden && owner.key.stringValue.isEmpty,"settings_saves_and_clears_field")
    try settingsSnapshot("settings-saved")
    owner.changeKey();try settingsSnapshot("settings-replacing");owner.key.stringValue="fake_replacement_key";owner.saveKey()
    try check(owner.vault.load()=="fake_replacement_key","settings_replaces_key")
    owner.changeKey();owner.vault.failNext=true;owner.key.stringValue="fake_failed_key";owner.saveKey()
    try check(owner.vault.load()=="fake_replacement_key","failed_replacement_preserves_previous")
    owner.changeKey();owner.key.stringValue="fake_offline_preview";try settingsSnapshot("settings-mock")
    owner.dismissSettings()
    owner.currentCacheID=UUID().uuidString;owner.activeSession=UUID().uuidString
    owner.phase.phase = .stopped;owner.cachedTranscriptionComplete=true
    if !RuntimeConfiguration.archiveEnabled {
        owner.openMeetingArchive();owner.presentMeetingArchiveSheetForChecks();owner.scheduleMeetingArchivePreparationIfEligible(trigger:"edition_check")
        try check(!owner.meetingArchiveEligible && owner.window.attachedSheet==nil && owner.meetingArchiveSheetCloseButtonForChecks==nil,"standalone_archive_open_prepare_and_panel_disabled")
    } else {try check(owner.meetingArchiveEligible,"configured_archive_still_eligible")}
    let transcript="参会者：周五前我会发测试清单。"
    let response = #"{"overview":"会议明确了测试清单安排。","topics_and_conclusions":[],"decisions":[],"action_items":[{"text":"发送测试清单","owner":"参会者","due":"周五前","evidence_quote":"周五前我会发测试清单。"}],"open_questions":[],"key_quotes":["周五前我会发测试清单。"]}"#
    let markdown=try MeetingMinutes.validateAndRender(response,title:"隔离纪要导出",finalTranscript:transcript)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let target=directory.appendingPathComponent("会议纪要.md")
    owner.savePanelURLProvider={target};owner.meetingMinutesBusy=true;owner.saveMeetingMinutes(markdown)
    let saved=try String(contentsOf:target,encoding:.utf8)
    try check(saved==markdown && saved.components(separatedBy:"\n").filter{$0.hasPrefix("## ")}.count==6 && !owner.meetingMinutesBusy,"minutes_saved_as_six_section_markdown")
    owner.savePanelURLProvider={nil};owner.meetingMinutesBusy=true;owner.saveMeetingMinutes(markdown)
    try check(!owner.meetingMinutesBusy,"cancel_save_releases_minutes_busy")
    owner.meetingMinutesBusy=true;owner.currentCacheID=UUID().uuidString
    try check(!owner.meetingMinutesBusy && owner.meetingMinutesTask==nil,"switching_meeting_cancels_minutes")
    // Exercise enabled connectors in either edition, without opening a network panel.
    let configURL=RuntimeConfiguration.dataRoot().appendingPathComponent("connectors.json")
    let oldConfig=try? Data(contentsOf:configURL)
    try FileManager.default.createDirectory(at:configURL.deletingLastPathComponent(),withIntermediateDirectories:true)
    defer {if let oldConfig {try? oldConfig.write(to:configURL)} else {try? FileManager.default.removeItem(at:configURL)}}
    try Data(#"{"schema":1,"archive":{"url":"http://127.0.0.1:18766","app_id":"example-archive"},"people_loader":"/tmp/example.py","project_roots":["/tmp/projects"],"context_hint":"示例背景"}"#.utf8).write(to:configURL)
    try check(RuntimeConfiguration.archiveEnabled && RuntimeConfiguration.peopleEnabled,"configured_integrations_enabled_in_both_editions")
    try check(!owner.makeMeetingArchiveButton().isHidden && owner.meetingArchiveEligible,"configured_archive_entry_visible_and_eligible")
    let request=try MeetingArchiveRequest.prepareRequest(session:"meeting-1",csrfToken:"example-token")
    try check(request.url?.host=="127.0.0.1" && request.url?.port==18766 && request.value(forHTTPHeaderField:"Origin")=="http://127.0.0.1:18766","archive_uses_configured_service")
    let bootstrapResponse=HTTPURLResponse(url:MeetingArchiveRequest.bootstrapURL()!,statusCode:200,httpVersion:nil,headerFields:nil)
    let token=try MeetingArchiveRequest.validatedCSRFToken(data:Data(#"{"app_id":"example-archive","csrf_token":"example-token"}"#.utf8),response:bootstrapResponse,error:nil)
    try check(token=="example-token","archive_accepts_configured_app_identity")
    try Data(#"{"schema":1,"archive":{"url":"file:///tmp/service","app_id":"example"}}"#.utf8).write(to:configURL)
    try check(!RuntimeConfiguration.archiveEnabled && owner.makeMeetingArchiveButton().isHidden,"invalid_archive_config_stays_hidden")
    return checks
}
