import Foundation
import AppKit

// Own native views rendered offscreen. This does not capture the desktop or automate UI input.
@MainActor func renderReview(directory:URL)throws->[String:Any] {
    let expected=URL(fileURLWithPath:Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as! String).appendingPathComponent("native/ui-review").standardizedFileURL.path
    guard directory.standardizedFileURL.path.hasPrefix(expected+"/") else{throw ProfileStoreError.permission}
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    let view=Delegate();view.previewRenderOnly=true;view.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));var files:[String]=[];var checks=0
    func save(_ target:NSView,_ name:String)throws {
        try view.settleTranscriptForOfflineReview()
        target.layoutSubtreeIfNeeded();guard let bitmap=target.bitmapImageRepForCachingDisplay(in:target.bounds) else{throw ProfileStoreError.invalid};target.cacheDisplay(in:target.bounds,to:bitmap);guard let png=bitmap.representation(using:.png,properties:[:]) else{throw ProfileStoreError.invalid}
        let path=directory.appendingPathComponent(name+".png");try png.write(to:path);files.append(path.lastPathComponent)
    }
    for theme in ["light","dark"] {
        NSApp.appearance=NSAppearance(named:theme=="dark" ? .darkAqua:.aqua);view.window.appearance=NSApp.appearance;view.sheet.appearance=NSApp.appearance
        for size in [NSSize(width:800,height:620),NSSize(width:640,height:480)] {
            view.window.setContentSize(size);view.window.contentView!.layoutSubtreeIfNeeded();let prefix=theme+"-"+String(Int(size.width))
            view.phase=UIState();view.segments=[:];view.sequence=[];view.naming.reset();view.empty.stringValue="会议文字会出现在这里";view.renderText();view.updateUI();try save(view.window.contentView!,prefix+"-ready")
            view.receive(["type":"started","session":"review"])
            for i in 0..<18 {let mic=i%3==1;view.receive(["type":"segment","segment_id":"r-\(i)","session":"review","track":mic ? "mic":"remote","text":i%3==0 ? "这次先把品牌主张讲清楚。广告需要让观众听完一句，就知道我们解决的是什么问题。":"先保留两个创意方向，下一步比较用户反馈与预算，再确认执行方案。","final":i != 17,"revision":1,"speaker":["basis":"anonymous_cluster","cluster_id":i%2]])}
            view.naming.set(segment:"r-0",name:"合成说话人甲 · 产品负责人");view.phase.elapsed=123;view.phase.estimated=0.12;view.renderText();view.updateUI();try save(view.window.contentView!,prefix+"-transcript")
            view.balanceState.cash="1234567890.12";view.balanceState.currency="CNY";view.phase.estimated=99999.99;view.updateUI();view.window.contentView!.layoutSubtreeIfNeeded();precondition(view.meter.frame.maxX<=view.window.contentView!.bounds.maxX-72);checks+=1;try save(view.window.contentView!,prefix+"-long-amount")
            view.balanceState=BalanceSnapshotState();view.phase.phase = .failed;view.phase.error="连接中断，请重新开始";view.updateUI();try save(view.window.contentView!,prefix+"-error")
            view.phase.phase = .recording;view.phase.error=nil;view.segments=[:];view.sequence=[];view.output.string="";view.empty.stringValue="还没听到声音";view.empty.isHidden=false;view.updateUI();try save(view.window.contentView!,prefix+"-silence")
            precondition(view.scroll.frame.height/size.height>=0.60);checks+=1
        }
        view.editing=true;view.refreshSettings();try save(view.sheet.contentView!,theme+"-settings-new")
        try view.vault.save("fake-review-key");view.editing=false;view.refreshSettings();precondition(view.key.stringValue.isEmpty && view.key.isHidden);checks+=1;try save(view.sheet.contentView!,theme+"-settings-saved")
        view.segments["person"]=["text":"合成标注界面","final":true];view.naming.set(segment:"person",name:"合成说话人甲");view.beginInlineName("person");try save(view.inlinePopover!.contentViewController!.view,theme+"-person")
    }
    return ["type":"native_view_render_review","files":files,"checks":checks,"window_opened":false,"desktop_capture":false,"actual_keyboard_mouse_QA":false,"keychain":false,"network":false,"capture":false,"render_basis":"actual_product_AppKit_views_offscreen"]
}

// Read-only evaluation of the explicitly selected saved recording. Never opens
// recording devices or ASR, and never writes back to the session cache.
@MainActor func renderSavedSpeakerReview(cacheID:String,directory:URL)throws->[String:Any] {
    guard Credential.offline,Bundle.main.object(forInfoDictionaryKey:"DevelopmentWorkspace") as? Bool==true,
          let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,
          UUID(uuidString:cacheID) != nil,directory.standardizedFileURL.path.hasPrefix(root+"/.runtime/") else{throw Failure(code:"saved_review_scope")}
    guard let meeting=try cachedMeetings(in:meetingCacheRoot()).first(where:{$0.id==cacheID}) else{throw Failure(code:"saved_review_missing")}
    let events=try meeting.events();let metadata=try meeting.metadata()
    guard let session=metadata["session"] as? String else{throw Failure(code:"saved_review_session")}
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    let view=Delegate();view.previewRenderOnly=true;view.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    view.deferPresentation=true;view.activeSession=session;view.phase.phase = .stopped;view.absoluteTime=MeetingAbsoluteTime(metadata["absolute_clock"])
    for event in events {view.receive(event)}
    let names=meeting.directory.appendingPathComponent("session-names.json")
    if FileManager.default.fileExists(atPath:names.path) {try view.naming.restore(Data(contentsOf:names),session:session,events:events,directory:meeting.directory)}
    // This explicit saved-recording review uses the same read-only validation
    // as export, so qualified per-span names are not hidden by the QA harness.
    let voiceFolder=RuntimeConfiguration.dataRoot().appendingPathComponent("Voiceprints")
    view.naming.validateVoiceprintArchive(try VoiceprintArchiveStore(folder:voiceFolder,domain:"consented_live_audio").load())
    view.meetingTitle=meeting.customTitle ?? MeetingLibraryInfo.defaultTitle(meeting.date);view.phase.elapsed=meeting.durationSeconds
    view.deferPresentation=false;view.window.title="在场 · 已保存记录";view.diagnostic.stringValue="已保存";view.window.setContentSize(NSSize(width:1050,height:780));view.window.contentView!.layoutSubtreeIfNeeded();view.renderText();try view.settleTranscriptForOfflineReview();view.updateUI();view.scroll.contentView.scroll(to:.zero)
    let output=directory.appendingPathComponent("saved-speaker-turns.txt");try view.transcriptExport().write(to:output,atomically:true,encoding:.utf8)
    if let marker=view.readingTurns().first(where:{TranscriptTimeline.start($0.item)>=37}),let range=view.textRanges[marker.id],let layout=view.output.layoutManager,let container=view.output.textContainer {
        let rect=layout.boundingRect(forGlyphRange:layout.glyphRange(forCharacterRange:NSRange(location:range.location,length:1),actualCharacterRange:nil),in:container)
        view.scroll.contentView.scroll(to:NSPoint(x:0,y:rect.minY+view.output.textContainerInset.height));view.scroll.reflectScrolledClipView(view.scroll.contentView)
    }
    let target=view.window.contentView!.superview!;target.layoutSubtreeIfNeeded()
    let bitmap=target.bitmapImageRepForCachingDisplay(in:target.bounds)!
    target.effectiveAppearance.performAsCurrentDrawingAppearance {target.cacheDisplay(in:target.bounds,to:bitmap)}
    let image=NSImage(size:target.bounds.size);image.lockFocus();NSColor.windowBackgroundColor.setFill();NSBezierPath(rect:NSRect(origin:.zero,size:target.bounds.size)).fill();bitmap.draw(in:NSRect(origin:.zero,size:target.bounds.size));image.unlockFocus()
    let opaque=NSBitmapImageRep(data:image.tiffRepresentation!)!;let screenshot=directory.appendingPathComponent("saved-speaker-turns.png");try opaque.representation(using:.png,properties:[:])!.write(to:screenshot)
    var rowCount=0,known=0,overlap=0,changes=0,unknown=0,lossless=true
    for id in view.sequence {
        let item=view.segments[id]!,rows=view.spokenRows(id,item);rowCount+=rows.count
        lossless = lossless && rows.map{$0.1["text"] as? String ?? ""}.joined()==item["text"] as? String
        for (key,row) in rows {
            let speaker=row["speaker"] as? [String:Any] ?? [:]
            if view.naming.key(segment:key) != nil || view.naming.name(segment:key) != nil {known+=1}
            else if speaker["reason"] as? String=="overlap" {overlap+=1}
            else if speaker["reason"] as? String=="speaker_change" {changes+=1}
            else{unknown+=1}
        }
    }
    let review=SpeakerReviewIndex.build(session:session,turns:view.readingTurns(),names:view.naming)
    let people=review.people.map{["name":$0.title,"turns":$0.entries.count] as [String:Any]}
    return ["people":people,"unassigned_review_turns":review.unassigned.count,"speaker_reconciliation_applied":events.filter{$0["speaker_reconciliation_applied"] as? Bool==true}.count,"type":"saved_speaker_review","cache_id":cacheID,"original_sentences":events.count,"evidence_runs":rowCount,"visible_turns":view.readingTurns().count,"known_turns":known,"overlap_turns":overlap,"speaker_change_turns":changes,"unknown_turns":unknown,"all_text_preserved":lossless,"export":output.path,"image":screenshot.path,"capture":false,"cloud":false,"keychain":false,"original_files_modified":false,"offscreen":true]
}
