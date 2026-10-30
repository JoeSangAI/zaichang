import AppKit

// Records dispatch without invoking NSTableView's event loop or opening a menu.
private final class MeetingLibraryMouseProbe:NSTableView {
    var leftEvents:[NSEvent]=[]
    var rightEvents:[NSEvent]=[]
    override func mouseDown(with event:NSEvent) {leftEvents.append(event)}
    override func rightMouseDown(with event:NSEvent) {rightEvents.append(event)}
}

@MainActor func workspaceChecks(directory:URL)throws->[String:Any] {
    guard Credential.offline,let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,directory.standardizedFileURL.path.hasPrefix(root+"/.runtime/") else{throw Failure(code:"workspace_scope")}
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    var checks:[String]=[];var images:[String]=[]
    func check(_ condition:@autoclosure ()->Bool,_ name:String)throws{guard condition() else{throw Failure(code:name)};checks.append(name)}
    func settle(_ seconds:Double=0.1){let limit=Date().addingTimeInterval(seconds);while Date()<limit {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}}
    func wait(line:Int = #line,_ done:()->Bool)throws {let end=Date().addingTimeInterval(8);while !done() && Date()<end {settle(0.02)};guard done() else{throw Failure(code:"workspace_async_timeout_line_\(line)_after_\(checks.last ?? "none")")}}
    func snapshot(_ app:Delegate,_ name:String)throws {
        app.window.contentView!.layoutSubtreeIfNeeded()
        let target=app.window.contentView!.superview!
        guard let bitmap=target.bitmapImageRepForCachingDisplay(in:target.bounds) else{throw Failure(code:"workspace_bitmap")}
        target.effectiveAppearance.performAsCurrentDrawingAppearance{target.cacheDisplay(in:target.bounds,to:bitmap)}
        let image=NSImage(size:target.bounds.size);image.lockFocus()
        target.effectiveAppearance.performAsCurrentDrawingAppearance{NSColor.windowBackgroundColor.setFill();NSBezierPath(rect:target.bounds).fill();bitmap.draw(in:target.bounds)}
        image.unlockFocus()
        let opaque=NSBitmapImageRep(data:image.tiffRepresentation!)!
        let file=directory.appendingPathComponent(name+".png")
        try opaque.representation(using:.png,properties:[:])!.write(to:file);images.append(file.path)
    }
    func event(_ session:String,_ id:String,_ source:String="mic",_ slot:Int=0,_ start:Double=1)->[String:Any] {["type":"segment","session":session,"segment_id":id,"source_id":source,"track":source,"epoch":"fixture","start":start,"end":start+3,"text":id+"：先保留完整原文，再确认每位发言人的内容。","revision":1,"final":true,"speaker":["basis":"anonymous_cluster","cluster_id":slot,"source_id":source,"epoch":"fixture"]]}
    let base=directory.appendingPathComponent(UUID().uuidString)
    func fixture(_ title:String,_ complete:Bool)throws->CachedMeeting {
        let folder=base.appendingPathComponent(UUID().uuidString);let journal=try RecordingJournal(directory:folder,track:"mic",freeSpace:{1_000_000_000});try journal.enqueue(Data(repeating:0,count:32000),at:0);journal.finish();journal.wait();journal.record(event(folder.lastPathComponent,"历史专属关键词"));journal.wait();if complete {try journal.commit("asr",cursor:journal.bytes());journal.wait()}
        try JSONSerialization.data(withJSONObject:["session":folder.lastPathComponent,"bundle":"*system*","capture_mode":"local_only","asr_model":"qwen-audio-3.0-asr-flash-streaming","asr_destination":"dashscope.aliyuncs.com"]).write(to:folder.appendingPathComponent("meeting.json"));try MeetingLibraryInfo.saveTitle(title,in:folder)
        return try cachedMeetings(in:base).first{$0.id==folder.lastPathComponent}!
    }
    let old=try fixture("品牌讨论",true),pending=try fixture("待转写会议",false),current=try fixture("当前会议",false)
    let preferenceDomain="com.joesang.meeting-assistant.sidebar-fixture."+UUID().uuidString
    let sidebarDefaults=UserDefaults(suiteName:preferenceDomain)!
    defer{sidebarDefaults.removePersistentDomain(forName:preferenceDomain)}
    let app=Delegate();app.sidebarPreferencesOverride=sidebarDefaults;app.previewRenderOnly=true;app.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));app.recoveryRootOverride=base
    let summaryGate=DispatchSemaphore(value:0)
    app.librarySummaryJob.run(timeout:10,work:{summaryGate.wait();return true}){_ in}
    app.reloadLibrary();try wait{!app.libraryJob.busy}
    try check(app.libraryVisible.count==3,"library_loads_app_owned_meetings")
    try check(app.librarySummaryJob.busy && app.libraryRetryButton.isHidden,"library_list_renders_while_participant_summary_is_busy")
    try check(cacheFailureMessage(Failure(code:"cache_io_timeout"))=="读取超时，请重试；若持续失败，再检查文件访问权限","cache_timeout_does_not_claim_permission_failure")
    let selectedSummaryItem=app.libraryVisible[0];app.libraryTable.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);app.tableViewSelectionDidChange(Notification(name:NSTableView.selectionDidChangeNotification,object:app.libraryTable))
    try check(app.librarySummaryPending?.id==selectedSummaryItem.id,"library_summary_queues_only_selected_meeting")
    summaryGate.signal();try wait{app.librarySummaryLoaded.contains(selectedSummaryItem.id)}
    try check(app.libraryParticipants[selectedSummaryItem.id] != nil,"library_selected_participant_summary_populates_after_list")
    try wait{app.recoveries.allSatisfy{app.librarySummaryLoaded.contains($0.id)}}
    try check(app.recoveries.allSatisfy{app.libraryParticipants[$0.id] != nil},"library_unselected_participants_populate_without_clicking")
    try check(app.libraryTable.selectedRow==0,"library_background_names_preserve_selected_row")
    let retainedNames=app.libraryParticipants
    let reloadSummaryGate=DispatchSemaphore(value:0)
    app.librarySummaryJob.run(timeout:10,work:{reloadSummaryGate.wait();return true}){_ in}
    app.reloadLibrary();try wait{!app.libraryJob.busy}
    try check(app.libraryParticipants==retainedNames,"library_reload_retains_names_while_background_refresh_waits")
    reloadSummaryGate.signal();try wait{app.recoveries.allSatisfy{app.librarySummaryLoaded.contains($0.id)}}
    // Use the production row factory and actual hit testing, including its child labels.
    let tableProbe=MeetingLibraryMouseProbe(frame:NSRect(x:0,y:0,width:220,height:100))
    let rowItem=app.libraryVisible[0]
    app.libraryParticipants[rowItem.id]=["测试参会人甲","测试参会人乙"]
    guard let hitCell=app.tableView(tableProbe,viewFor:nil,row:0) as? MeetingLibraryCellView else{throw Failure(code:"library_row_cell_type")}
    let hitHost=NSView(frame:NSRect(x:0,y:0,width:220,height:100))
    hitCell.frame=hitHost.bounds;hitHost.addSubview(hitCell);hitHost.layoutSubtreeIfNeeded()
    guard let titleHit=hitCell.textField,
          let dateHit=hitCell.subviews.compactMap({$0 as? NSTextField}).first(where:{$0 !== titleHit && $0.stringValue.contains(" · ")}),
          let peopleHit=hitCell.subviews.compactMap({$0 as? MeetingParticipantLabel}).first else{throw Failure(code:"library_row_display_children")}
    for (name,child) in [("title",titleHit as NSView),("date",dateHit as NSView),("participants",peopleHit as NSView)] {
        try check(child.bounds.width>0 && child.bounds.height>0,"library_"+name+"_has_hit_area")
        let point=child.convert(NSPoint(x:child.bounds.midX,y:child.bounds.midY),to:hitHost)
        let hit=hitHost.hitTest(point)
        try check(hit === hitCell,"library_"+name+"_hit_routes_to_row")
        guard let left=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:1,windowNumber:0,context:nil,eventNumber:1,clickCount:1,pressure:1),
              let right=NSEvent.mouseEvent(with:.rightMouseDown,location:point,modifierFlags:[],timestamp:2,windowNumber:0,context:nil,eventNumber:2,clickCount:1,pressure:1) else{throw Failure(code:"library_row_mouse_fixture")}
        hit?.mouseDown(with:left);hit?.rightMouseDown(with:right)
        try check(tableProbe.leftEvents.last === left && tableProbe.rightEvents.last === right,"library_"+name+"_forwards_original_mouse_events")
    }
    try check(tableProbe.leftEvents.count==3 && tableProbe.rightEvents.count==3,"library_row_forwards_once_without_text_menu")
    try check(!titleHit.isSelectable && !dateHit.isSelectable && !titleHit.isEditable && !dateHit.isEditable,"library_row_text_is_display_only")
    try check(titleHit.accessibilityLabel()==titleHit.stringValue && dateHit.accessibilityLabel()==dateHit.stringValue && peopleHit.accessibilityLabel()=="参会人：测试参会人甲  ·  测试参会人乙","library_row_accessibility_labels_preserved")
    try check(dateHit.stringValue.contains("不到 1 分钟 · 仅录音") && !dateHit.stringValue.contains("待转写"),"record_only_row_does_not_promise_automatic_transcription")
    if let row=app.libraryVisible.firstIndex(where:{$0.id==pending.id}) {
        let original=app.libraryVisible[row];var transcribing=original;transcribing.recordingMode="record_and_transcribe";app.libraryVisible[row]=transcribing
        let pendingCell=app.tableView(tableProbe,viewFor:nil,row:row)!
        try check(pendingCell.subviews.compactMap{$0 as? NSTextField}.contains{$0.stringValue.hasSuffix(" · 待转写")},"transcription_row_still_discloses_remaining_audio")
        app.libraryVisible[row]=original
    }
    peopleHit.updateTrackingAreas()
    try check(peopleHit.trackingAreas.contains{($0.owner as? NSView) === peopleHit && $0.options.contains(.mouseEnteredAndExited)},"library_participant_hover_tracking_preserved")
    // Exercise the real table's menu preparation and presentation boundary.
    // Only the final native popup is replaced, so this stays fully offscreen.
    guard let menuTable=app.libraryTable as? MeetingLibraryTableView else{throw Failure(code:"library_context_table_type")}
    let menuRow=1,menuTarget=app.libraryVisible[1],documentBeforeMenu=app.displayedDocument
    app.libraryParticipants[menuTarget.id]=["菜单参会人"]
    app.librarySelectionChanging=true;menuTable.reloadData();menuTable.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);app.librarySelectionChanging=false
    // Context clicks require the sidebar to be presented. Offscreen windows
    // may be constrained to the current screen before their first display.
    app.window.setContentSize(NSSize(width:1040,height:720));app.sidebarManualVisible=true;app.layoutWorkspace()
    app.window.contentView?.layoutSubtreeIfNeeded()
    guard let menuCell=menuTable.view(atColumn:0,row:menuRow,makeIfNecessary:true) as? MeetingLibraryCellView,
          let menuTitle=menuCell.textField,
          let menuDate=menuCell.subviews.compactMap({$0 as? NSTextField}).first(where:{$0 !== menuTitle && $0.stringValue.contains(" · ")}),
          let menuPeople=menuCell.subviews.compactMap({$0 as? MeetingParticipantLabel}).first else{throw Failure(code:"library_context_actual_row")}
    menuCell.layoutSubtreeIfNeeded()
    var presented=0,preparedIDs:[String]=[],preparedOperations:Set<Int>=[],presentationRow = -1
    var loadedInTracking=false,renameEnabledInTracking=false,renameTitleInTracking=""
    menuTable.contextMenuPresenter={menu,_,view in
        presented += 1;presentationRow=(view as? NSTableView)?.clickedRow ?? -1
        app.menuWillOpen(menu)
        let deadline=Date().addingTimeInterval(2)
        while app.libraryManagementController.loadedID != menuTarget.id && Date()<deadline {
            _ = RunLoop.current.run(mode:.eventTracking,before:Date().addingTimeInterval(0.01))
        }
        loadedInTracking=app.libraryManagementController.files?.localOnly==true
        let rename=menu.items.first{($0.representedObject as? [String:Any])?["operation"] as? Int == MeetingLibraryOperation.rename.rawValue}
        renameEnabledInTracking=rename?.isEnabled==true;renameTitleInTracking=rename?.title ?? ""
        let commands=menu.items.compactMap{$0.representedObject as? [String:Any]}
        preparedIDs=commands.compactMap{$0["id"] as? String};preparedOperations=Set(commands.compactMap{$0["operation"] as? Int})
        app.menuDidClose(menu)
    }
    for (name,child) in [("title",menuTitle as NSView),("date",menuDate as NSView),("participants",menuPeople as NSView)] {
        let point=child.convert(NSPoint(x:child.bounds.midX,y:child.bounds.midY),to:nil)
        guard let click=NSEvent.mouseEvent(with:.rightMouseDown,location:point,modifierFlags:[],timestamp:3,windowNumber:app.window.windowNumber,context:nil,eventNumber:3,clickCount:1,pressure:1) else{throw Failure(code:"library_menu_event")}
        let prepared=menuCell.menu(for:click)
        try check(prepared === menuTable.menu && prepared!.items.count>=6,"library_"+name+"_prepares_nonempty_context_menu")
        let hit=menuTable.hitTest(menuTable.superview!.convert(point,from:nil))
        // NSTableView may retain the hit itself to handle row selection. Both
        // production receivers must take the same explicit context-menu path.
        if hit !== menuCell && hit !== menuTable {
            try snapshot(app,"context-hit-failure")
            throw Failure(code:"library_"+name+"_actual_hit_routes_to_context_receiver hit=\(String(describing:hit)) cell=\(menuCell.frame) table=\(menuTable.frame) clip=\(menuTable.superview!.bounds) point=\(point) sidebarHidden=\(app.sidebar.isHidden)")
        }
        try check(hit === menuCell || hit === menuTable,"library_"+name+"_actual_hit_routes_to_context_receiver")
        hit?.rightMouseDown(with:click)
        let expectedActions:[MeetingLibraryOperation]=[.rename,.renameAudio,.transcribe,.exportAudio,.meetingFiles,.delete]
        try check(presentationRow==menuRow && preparedIDs.count==6 && preparedIDs.allSatisfy{$0==menuTarget.id} && preparedOperations==Set(expectedActions.map{$0.rawValue}),"library_"+name+"_presents_six_actions_with_one_meeting_files_entrance_for_clicked_row")
        try check(menuTable.selectedRow==menuRow && app.displayedDocument === documentBeforeMenu,"library_"+name+"_context_selection_preserves_document")
        try check(loadedInTracking && renameEnabledInTracking && renameTitleInTracking=="重命名会议…","library_"+name+"_first_open_updates_during_menu_tracking")
    }
    try check(presented==3,"library_real_context_route_reaches_popup_once_per_click")
    let controlPoint=menuDate.convert(NSPoint(x:menuDate.bounds.midX,y:menuDate.bounds.midY),to:nil)
    guard let controlClick=NSEvent.mouseEvent(with:.leftMouseDown,location:controlPoint,modifierFlags:.control,timestamp:4,windowNumber:app.window.windowNumber,context:nil,eventNumber:4,clickCount:1,pressure:1) else{throw Failure(code:"library_control_click_fixture")}
    menuCell.mouseDown(with:controlClick)
    try check(presented==4 && presentationRow==menuRow && app.displayedDocument === documentBeforeMenu,"library_control_click_uses_same_context_route")
    menuTable.contextMenuPresenter=nil
    app.librarySearch.stringValue="品牌";app.filterLibrary();try wait{app.libraryVisible.count==1};try check(app.libraryVisible.first?.id==old.id,"meeting_title_search")
    app.librarySearch.stringValue="历史专属关键词";app.filterLibrary();try wait{app.libraryVisible.count==3};try check(app.libraryVisible.count==3,"meeting_original_text_search")
    app.librarySearch.stringValue="不存在的关键词";app.filterLibrary();try wait{app.libraryVisible.isEmpty};try check(app.libraryStatus.stringValue=="没有找到会议","search_empty_state")
    app.librarySearch.stringValue="";app.filterLibrary()
    app.currentCacheID=current.id;app.activeSession=current.id;app.meetingTitle="当前会议";app.phase.phase = .recording;app.receive(event(current.id,"当前发言一","remote",0,8));app.receive(event(current.id,"当前发言二","mic",0,1));app.cacheWriteQueue.sync{}
    let numbering=try Data(contentsOf:current.directory.appendingPathComponent("session-names.json"));var replay=SessionNames();replay.register(segment:"当前发言二",item:event(current.id,"当前发言二","mic"));replay.register(segment:"当前发言一",item:event(current.id,"当前发言一","remote"));try replay.restore(numbering,session:current.id)
    try check(replay.displayLabel(speaker:replay.key(segment:"当前发言一")!)=="发言人 1" && replay.displayLabel(speaker:replay.key(segment:"当前发言二")!)=="发言人 2","speaker_numbers_persist_across_reordered_track_replay")
    try check(replay.key(segment:"当前发言一") != replay.key(segment:"当前发言二"),"same_slot_on_different_tracks_does_not_merge_people")
    app.openLibraryMeeting(old);try wait{app.historyReader?.currentCacheID==old.id};let reader=app.historyReader!
    try check(app.activeSession==current.id && app.currentDocument.isHidden && reader.currentDocument.superview===app.documentHost,"history_isolated_from_recording_owner")
    try check(reader.previewRenderOnly && reader.documentIsPreview,"offscreen_history_keeps_presentation_suppressed")
    app.previewRenderOnly=false
    try check(reader.previewRenderOnly && !reader.documentIsPreview && reader.workspaceOwner===app,"real_workspace_history_enables_confirmation_without_startup_side_effects")
    app.previewRenderOnly=true
    app.receive(event(current.id,"继续到达的当前发言","remote",0,12));try check(app.sequence.count==3 && !reader.output.string.contains("继续到达的当前发言"),"live_events_continue_while_browsing_history")
    reader.beginInlineName("历史专属关键词");reader.inlineField!.stringValue="张宇";reader.commitInlineName();reader.cacheWriteQueue.sync{}
    try check(reader.naming.name(segment:"历史专属关键词")=="张宇" && app.naming.name(segment:"当前发言一")==nil,"history_speaker_correction_does_not_change_live_names")
    let independentlySaved=directory.appendingPathComponent("本人另存的原文.txt")
    try reader.saveTranscript(to:independentlySaved);let independentBytes=try Data(contentsOf:independentlySaved)
    reader.renameMeeting("品牌周会");try wait{app.libraryManagement?.busy==false && reader.meetingTitle=="品牌周会"};try wait{!app.libraryJob.busy};settle()
    try check(try! MeetingLibraryInfo.loadTitle(in:old.directory)=="品牌周会" && app.meetingTitle=="当前会议","rename_persists_without_changing_live_meeting")
    try check(app.displayedDocument.transcriptSuggestedFilename=="品牌周会－转写原文.txt","renamed_meeting_drives_new_export_filename")
    let independentAfterRename=try Data(contentsOf:independentlySaved)
    try check(independentAfterRename==independentBytes,"rename_preserves_existing_user_saved_export_filename_and_bytes")
    let exported=app.displayedDocument.transcriptExport();try check(exported.contains("品牌周会") && exported.contains("张宇") && !exported.contains("当前发言"),"export_targets_visible_document")
    try check(app.historyReader?.action.isHidden==false && app.historyReader?.action.title=="继续这场录音" && app.historyReader?.historyLiveButton.isHidden==false && app.newButton?.isEnabled==true,"history_offers_append_capture_and_keeps_new_meeting_entry_available")
    app.returnToCurrent();try check(app.historyReader==nil && !app.currentDocument.isHidden && app.output.string.contains("继续到达的当前发言"),"return_to_current_preserves_incoming_text")
    app.openLibraryMeeting(old);app.openLibraryMeeting(pending);try wait{app.historyReader?.currentCacheID==pending.id};try check(app.historyReader?.action.isHidden==false && app.historyReader?.historyLiveButton.isHidden==false,"rapid_switch_keeps_latest_selection_and_live_controls")
    app.openLibraryMeeting(old);try wait{app.historyReader?.currentCacheID==old.id}
    // Let AppKit recompute the native window's resize limits after history
    // hides its meters; setContentSize alone can bypass the user resize gate.
    app.sidebarManualVisible=nil
    for state in [RecordingPhase.stopped,RecordingPhase.recording] {
        app.phase.phase=state;app.updateUI()
        for width:CGFloat in [640,1040,1200,800,1040] {
            app.window.setContentSize(NSSize(width:width,height:720));app.layoutWorkspace();settle(0.15)
            let actual=app.window.contentView!.bounds.width
            try check(abs(actual-width)<0.5 && app.window.maxSize.width>=1200 && app.window.contentMaxSize.width>=1200,
                      "history_window_\(state)_\(Int(width))_keeps_requested_width_and_allows_user_growth_actual_\(actual)_max_\(app.window.contentMaxSize.width)")
        }
        try check(app.historyReader?.microphoneLevel?.alphaValue==0 && app.historyReader?.computerLevel?.alphaValue==0 &&
                  app.historyReader?.microphoneLevel?.isHidden==false && app.historyReader?.computerLevel?.isHidden==false,
                  "history_hidden_meter_presentation_preserves_flexible_layout_\(state)")
    }
    app.phase.phase = .stopped;app.updateUI();app.window.contentView?.layoutSubtreeIfNeeded()
    try check(app.historyReader?.action.isHiddenOrHasHiddenAncestor==false && (app.historyReader?.action.frame.width ?? 0)>0 && (app.historyReader?.action.frame.height ?? 0)>0,
              "stopped_history_append_control_is_actually_visible")
    try snapshot(app,"history-append-b-stopped")
    if let reader=app.historyReader,let capsule=reader.recordingCapsuleWidth?.firstItem as? NSView {
        capsule.superview?.layoutSubtreeIfNeeded()
        let control=reader.action.convert(reader.action.bounds,to:capsule)
        try check(capsule.frame.width<420 && capsule.frame.height==50 && capsule.bounds.contains(control),"saved_meeting_capsule_hugs_its_content_\(capsule.frame)_\(control)")
    }
    app.phase.phase = .recording;app.updateUI();app.window.contentView?.layoutSubtreeIfNeeded()
    try check(app.historyReader?.action.isHiddenOrHasHiddenAncestor==false && (app.historyReader?.action.frame.width ?? 0)>0 && (app.historyReader?.action.frame.height ?? 0)>0,
              "active_b_history_append_control_is_actually_visible")
    try snapshot(app,"history-append-b-recording")
    let bTranscriptBefore=try Data(contentsOf:current.directory.appendingPathComponent("mic-transcript.jsonl"))
    let bNamesBefore=try Data(contentsOf:current.directory.appendingPathComponent("session-names.json"))
    let aHashesBefore=try old.transcriptHashes()
    var appendRequest:[String:Any]?;app.startupWorkerFixture={appendRequest=$0};app.resumeViewedMeeting();try wait{appendRequest != nil}
    try check(appendRequest?["append_capture_cache_id"] as? String==old.id && app.currentCacheID==old.id && app.historyReader==nil,"resume_selected_history_reuses_original_cache_and_starts_capture")
    // The shipped helper is chosen by candidate_mode exactly as for a normal start.
    try check(appendRequest?["candidate_mode"] as? Bool==app.trialCandidate,"resume_request_selects_shipped_helper_like_normal_start")
    let contextFolder=directory.appendingPathComponent("append-context-"+UUID().uuidString)
    app.contextPublisher=MeetingContextPublisher(directory:contextFolder);app.beginMeetingContext();app.contextPublisher?.flushForChecks()
    let contextStore=try MeetingContextStore(directory:contextFolder)
    let contextBefore=try contextStore.revision(old.id)
    app.receive(["type":"started","session":old.id,"cache_id":old.id,"mode":"local_only","capture":true,"audio_frames_received":true,"append_capture":true])
    let appendJournal=try RecordingJournal(directory:old.directory,track:"mic-g1",freeSpace:{1_000_000_000})
    try appendJournal.enqueue(Data(repeating:0,count:3200),at:20)
    var added=event(old.id,"续录新发言","mic-g1",0,20);added["epoch"]="append-epoch"
    added["speaker"]=["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic-g1","epoch":"append-epoch"]
    appendJournal.record(added);appendJournal.finish();appendJournal.wait();try appendJournal.commit("asr",cursor:appendJournal.bytes());appendJournal.wait()
    app.receive(added);app.receive(["type":"stopped","session":old.id,"reason":"user_stop","transcription_complete":true,"recording_elapsed_seconds":23.0])
    try app.settleTranscriptForOfflineReview();app.contextPublisher?.flushForChecks()
    let appendedExport=app.transcriptExport()
    try check(appendedExport.contains("历史专属关键词") && appendedExport.contains("张宇") && appendedExport.contains("续录新发言") &&
              appendedExport.range(of:"历史专属关键词")!.lowerBound < appendedExport.range(of:"续录新发言")!.lowerBound,
              "append_capture_export_retains_original_manual_name_and_new_text_in_order")
    try check(try! Data(contentsOf:current.directory.appendingPathComponent("mic-transcript.jsonl"))==bTranscriptBefore &&
              (try! Data(contentsOf:current.directory.appendingPathComponent("session-names.json")))==bNamesBefore,
              "switch_saves_b_without_mutating_its_transcript_or_names")
    let aAfter=try cachedMeetings(in:base).first{$0.id==old.id}!
    let contextAfter=try contextStore.revision(old.id)
    try check(try! aAfter.transcriptHashes() != aHashesBefore && contextAfter>contextBefore,
              "append_capture_changes_saved_source_and_context_revision")
    let reopenedA=Delegate();reopenedA.previewRenderOnly=true;reopenedA.recoveryRootOverride=base
    reopenedA.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    try reopenedA.applyRecovery(aAfter,payload:RecoveryPayload(aAfter));try reopenedA.settleTranscriptForOfflineReview()
    let reopenedAExport=reopenedA.transcriptExport()
    try check(reopenedA.currentCacheID==old.id && reopenedA.activeSession==old.id && reopenedAExport.contains("历史专属关键词") && reopenedAExport.contains("张宇") && reopenedAExport.contains("续录新发言"),
              "append_capture_reopens_same_session_with_old_name_and_new_text")
    reopenedA.window.orderOut(nil)
    app.processingAudio=false;app.resumeBusy=false;app.phase.phase = .stopped;app.updateUI();try check(app.action.title=="继续这场录音" && app.action.isEnabled,"saved_current_meeting_can_append")
    app.openLibraryMeeting(old);try wait{app.currentCacheID==old.id && app.historyReader==nil}
    try check(app.displayedDocument.action.isHiddenOrHasHiddenAncestor==false,"completed_saved_meeting_can_append")
    app.showDocumentSearch();settle();try check(app.displayedDocument.scroll.isFindBarVisible,"find_bar_targets_visible_saved_document")
    let archived=try fixture("归档会议",true)
    let manifestFile=archived.directory.appendingPathComponent("mic-manifest.json")
    var manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:manifestFile)) as! [String:Any];manifest["audio_cleaned"]=true;try JSONSerialization.data(withJSONObject:manifest).write(to:manifestFile)
    try Data().write(to:archived.directory.appendingPathComponent("mic-transcript.jsonl"));try "归档原文必须完整保留".write(to:archived.directory.appendingPathComponent("archived-transcript.txt"),atomically:true,encoding:.utf8)
    app.libraryJob.run(work:{Thread.sleep(forTimeInterval:0.05);return true}){_ in}
    app.reloadLibrary();try wait{!app.libraryJob.busy && !app.libraryReloadPending && app.recoveries.count==4}
    try check(app.recoveries.count==4,"refresh_requested_during_busy_read_is_not_lost")
    app.openLibraryMeeting(app.recoveries.first{$0.id==archived.id}!);try wait{app.historyReader?.currentCacheID==archived.id}
    app.historyReader!.timelineToggle.state = .on;app.historyReader!.toggleSpeakerRanges()
    try check(app.historyReader!.output.string=="归档原文必须完整保留","archive_only_document_survives_open_and_rerender")
    let archiveOriginal=try Data(contentsOf:archived.directory.appendingPathComponent("archived-transcript.txt"))
    let archivedMetadataFile=archived.directory.appendingPathComponent("meeting.json")
    var archivedMetadata=try JSONSerialization.jsonObject(with:Data(contentsOf:archivedMetadataFile)) as! [String:Any]
    archivedMetadata["archive_only_before_append"]=true
    try JSONSerialization.data(withJSONObject:archivedMetadata,options:[.sortedKeys]).write(to:archivedMetadataFile,options:.atomic)
    try FileManager.default.copyItem(at:archived.directory.appendingPathComponent("archived-transcript.txt"),
                                     to:archived.directory.appendingPathComponent("archived-preappend.txt"))
    let archiveJournal=try RecordingJournal(directory:archived.directory,track:"mic-g1",freeSpace:{1_000_000_000})
    try archiveJournal.enqueue(Data(repeating:0,count:3200),at:0)
    var archiveAdded=event(archived.id,"归档后新发言","mic-g1",0,0)
    archiveAdded["segment_id"]="0000-archive-new"
    archiveAdded["epoch"]="archive-append-epoch"
    archiveAdded["speaker"]=["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic-g1","epoch":"archive-append-epoch"]
    archiveJournal.record(archiveAdded);archiveJournal.finish();archiveJournal.wait()
    let archivePending=CachedMeeting(id:archived.id,directory:archived.directory,date:archived.date,
        writtenBytes:archiveJournal.bytes(),pendingBytes:archiveJournal.bytes(),occupiedBytes:archiveJournal.bytes(),
        tracks:["mic","mic-g1"],audioCleaned:false,warning:false,retiredBytes:archived.retiredBytes)
    try app.historyReader!.applyRecovery(archivePending,payload:RecoveryPayload(archivePending))
    try check(!app.historyReader!.cachedTranscriptionComplete && !app.historyReader!.meetingArchiveEligible,
              "old_archive_does_not_mark_new_untranscribed_audio_complete")
    try archiveJournal.commit("asr",cursor:archiveJournal.bytes());archiveJournal.wait()
    let archiveComplete=CachedMeeting(id:archived.id,directory:archived.directory,date:archived.date,
        writtenBytes:archiveJournal.bytes(),pendingBytes:0,occupiedBytes:archiveJournal.bytes(),
        tracks:["mic","mic-g1"],audioCleaned:false,warning:false,retiredBytes:archived.retiredBytes)
    try app.historyReader!.applyRecovery(archiveComplete,payload:RecoveryPayload(archiveComplete))
    try app.historyReader!.settleTranscriptForOfflineReview()
    let archiveExport=app.historyReader!.transcriptExport()
    let archiveOld=archiveExport.range(of:"归档原文必须完整保留"),archiveNew=archiveExport.range(of:"归档后新发言")
    try check(archiveOld != nil && archiveNew != nil && archiveOld!.lowerBound < archiveNew!.lowerBound &&
              app.historyReader!.output.string.contains("归档原文必须完整保留") && app.historyReader!.output.string.contains("归档后新发言"),
              "archive_only_append_keeps_old_text_before_new_in_document_and_export")
    try check(try! Data(contentsOf:archived.directory.appendingPathComponent("archived-transcript.txt"))==archiveOriginal,
              "archive_only_append_preserves_original_archive_bytes")
    app.returnToCurrent();app.phase.phase = .recording;app.meetingTitle="产品讨论";app.phase.elapsed=125;app.updateUI();app.receive(event(pending.id,"需要保留的完整发言"))
    // Resize the real divider using mouse events; keep user defaults isolated.
    guard let divider=app.sidebarDivider else{throw Failure(code:"sidebar_divider_missing")}
    app.sidebarManualVisible=nil;app.window.setContentSize(NSSize(width:1040,height:720));app.layoutWorkspace()
    func dividerMouse(_ type:NSEvent.EventType,x:CGFloat,clicks:Int=1)throws->NSEvent {
        guard let event=NSEvent.mouseEvent(with:type,location:NSPoint(x:x,y:300),modifierFlags:[],timestamp:5,windowNumber:app.window.windowNumber,context:nil,eventNumber:5,clickCount:clicks,pressure:1) else{throw Failure(code:"sidebar_mouse_fixture")};return event
    }
    let originalSelection=app.selectedLibraryManagementItem?.id,originalDocument=app.displayedDocument
    let start=divider.convert(NSPoint(x:divider.bounds.midX,y:divider.bounds.midY),to:nil).x
    try check(divider.bounds.width==8 && !divider.isHidden && divider.accessibilityRole() == .splitter,"sidebar_divider_is_visible_accessible_and_hittable")
    let contentRoot=app.window.contentView!
    let dividerHitPoint=divider.convert(NSPoint(x:divider.bounds.midX,y:divider.bounds.midY),to:contentRoot.superview)
    try check(contentRoot.hitTest(dividerHitPoint) === divider,"sidebar_real_window_hit_reaches_divider")
    let dragTarget=app.preferredSidebarWidth+80
    divider.mouseDown(with:try dividerMouse(.leftMouseDown,x:start))
    divider.mouseDragged(with:try dividerMouse(.leftMouseDragged,x:start+80))
    try check(app.sidebarWidth.constant==dragTarget && app.preferredSidebarWidth==dragTarget,"sidebar_drag_event_changes_actual_constraint")
    try check(sidebarDefaults.object(forKey:MeetingSidebarSizing.preferenceKey)==nil,"sidebar_drag_does_not_write_preferences_on_each_frame")
    divider.mouseUp(with:try dividerMouse(.leftMouseUp,x:start+80))
    try check(sidebarDefaults.double(forKey:MeetingSidebarSizing.preferenceKey)==Double(dragTarget),"sidebar_drag_end_persists_user_width")
    try check(app.selectedLibraryManagementItem?.id==originalSelection && app.displayedDocument === originalDocument,"sidebar_drag_preserves_selection_and_document")
    let reopened=Delegate();reopened.sidebarPreferencesOverride=UserDefaults(suiteName:preferenceDomain);reopened.restoreSidebarWidth()
    try check(reopened.preferredSidebarWidth==dragTarget,"sidebar_width_restores_from_independent_defaults_instance")
    guard let left=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:6,windowNumber:app.window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:123) else{throw Failure(code:"sidebar_key_fixture")}
    divider.keyDown(with:left)
    try check(app.sidebarWidth.constant==dragTarget-12 && sidebarDefaults.double(forKey:MeetingSidebarSizing.preferenceKey)==Double(dragTarget-12),"sidebar_arrow_key_adjustment_persists")
    divider.mouseDown(with:try dividerMouse(.leftMouseDown,x:start))
    divider.mouseDragged(with:try dividerMouse(.leftMouseDragged,x:start+10000))
    divider.mouseUp(with:try dividerMouse(.leftMouseUp,x:start+10000))
    try check(app.preferredSidebarWidth==360 && app.sidebarWidth.constant==360,"sidebar_drag_clamps_upper_bound")
    app.window.setContentSize(NSSize(width:800,height:720));app.layoutWorkspace()
    try check(app.sidebarWidth.constant==260 && app.preferredSidebarWidth==360 && sidebarDefaults.double(forKey:MeetingSidebarSizing.preferenceKey)==360,"sidebar_window_pressure_does_not_overwrite_preference")
    try check(abs(app.window.contentView!.bounds.width-800)<0.5 && app.documentHost.frame.maxX<=800.5,"sidebar_resize_keeps_document_inside_visible_window")
    app.window.setContentSize(NSSize(width:640,height:480));app.layoutWorkspace()
    try check(app.sidebar.isHidden && divider.isHidden && app.sidebarWidth.constant==0 && app.preferredSidebarWidth==360,"sidebar_narrow_window_hides_without_losing_user_width")
    app.sidebarManualVisible=true;app.layoutWorkspace()
    try check(app.sidebarWidth.constant==200 && app.documentHost.frame.maxX<=640.5 && (app.microphoneLevel?.bounds.width ?? 0)>=48 && (app.computerLevel?.bounds.width ?? 0)>=48 && (app.recordingTransportView?.subviews.first?.frame.maxX ?? .infinity)<=(app.recordingTransportView?.bounds.maxX ?? 0)+0.5,"sidebar_explicit_narrow_show_keeps_waveforms_readable_and_document_inside")
    app.sidebarManualVisible=nil;app.layoutWorkspace()
    try check(app.sidebar.isHidden && app.preferredSidebarWidth==360,"sidebar_automatic_visibility_restored_without_preference_loss")
    app.window.setContentSize(NSSize(width:1040,height:720));app.layoutWorkspace()
    try check(!app.sidebar.isHidden && !divider.isHidden && app.sidebarWidth.constant==360,"sidebar_wide_window_restores_preferred_width")
    app.toggleSidebar();try check(app.sidebar.isHidden && divider.isHidden,"sidebar_manual_hide_hides_drag_target")
    app.toggleSidebar();try check(app.sidebarWidth.constant==360,"sidebar_manual_reopen_restores_preferred_width");app.sidebarManualVisible=nil
    divider.mouseDown(with:try dividerMouse(.leftMouseDown,x:start))
    divider.mouseDragged(with:try dividerMouse(.leftMouseDragged,x:start-10000))
    divider.mouseUp(with:try dividerMouse(.leftMouseUp,x:start-10000))
    try check(app.sidebarWidth.constant==200 && app.preferredSidebarWidth==200,"sidebar_drag_clamps_lower_bound")
    for (value,expected) in [(Double.nan,200.0),(Double.infinity,200.0),(-50.0,200.0),(99999.0,360.0)] {
        sidebarDefaults.set(value,forKey:MeetingSidebarSizing.preferenceKey);reopened.restoreSidebarWidth()
        try check(reopened.preferredSidebarWidth==CGFloat(expected),"sidebar_invalid_stored_width_"+String(value)+"_normalized")
    }
    sidebarDefaults.set("untrusted width",forKey:MeetingSidebarSizing.preferenceKey);reopened.restoreSidebarWidth()
    try check(reopened.preferredSidebarWidth==200,"sidebar_non_numeric_preference_ignored")
    sidebarDefaults.set(true,forKey:MeetingSidebarSizing.preferenceKey);reopened.restoreSidebarWidth()
    try check(reopened.preferredSidebarWidth==200,"sidebar_boolean_preference_ignored")
    divider.mouseDown(with:try dividerMouse(.leftMouseDown,x:start,clicks:2))
    try check(app.preferredSidebarWidth==200 && sidebarDefaults.double(forKey:MeetingSidebarSizing.preferenceKey)==200,"sidebar_double_click_restores_default")
    app.window.makeFirstResponder(app.output)
    for (name,size,appearance) in [("workspace-wide",NSSize(width:1040,height:720),NSAppearance.Name.aqua),("workspace-compact",NSSize(width:640,height:480),NSAppearance.Name.aqua),("workspace-dark",NSSize(width:1040,height:720),NSAppearance.Name.darkAqua)] {
        app.window.appearance=NSAppearance(named:appearance);app.window.setContentSize(size);app.layoutWorkspace();settle();app.renderText();app.window.contentView!.layoutSubtreeIfNeeded()
        try check(app.sidebar.isHidden == (size.width<800),name+"_adaptive_sidebar")
        try check(abs(app.output.frame.width-app.scroll.contentSize.width)<1 && app.scroll.contentSize.width>500,name+"_readable_transcript_width")
        try snapshot(app,name)
    }
    // Paper & vermilion P0: real native views with isolated, synthetic rows.
    func dated(_ item:CachedMeeting,_ date:Date,_ title:String)->CachedMeeting {
        var row=CachedMeeting(id:item.id,directory:item.directory,date:date,writtenBytes:item.writtenBytes,pendingBytes:item.pendingBytes,occupiedBytes:item.occupiedBytes,tracks:item.tracks,audioCleaned:item.audioCleaned,warning:item.warning,retiredBytes:item.retiredBytes)
        row.customTitle=title;row.durationSeconds=item.durationSeconds;row.recordingMode="record_and_transcribe";return row
    }
    // A fixed Wednesday keeps all three calendar groups represented on any run date.
    let reference=Date(timeIntervalSince1970:1793188800)
    let today=dated(current,Date(),"纸与朱砂｜离线界面检查")
    let early=dated(old,Calendar.current.date(byAdding:.day,value:-14,to:Date())!,"较早会议")
    app.returnToCurrent();app.currentCacheID=today.id;app.activeSession=today.id;app.meetingTitle=today.displayTitle;app.phase.phase = .recording;app.phase.elapsed=1938;app.sessionLocalOnly=false
    app.recoveries=[today,early];app.libraryVisible=app.recoveries;app.libraryParticipants[today.id]=["测试参会人甲","测试参会人乙"];app.renderLibraryList()
    try check(app.libraryGroup(at:0)=="今天" && app.libraryGroup(at:1)=="更早","paper_sidebar_calendar_groups")
    try check(MeetingLibraryDate.group(reference,now:reference)=="今天" && MeetingLibraryDate.group(reference.addingTimeInterval(-86400),now:reference)=="本周" && MeetingLibraryDate.group(reference.addingTimeInterval(-14*86400),now:reference)=="更早","paper_all_three_group_rules")
    let unknown:[String:Any]=["type":"segment","session":today.id,"segment_id":"paper-unknown","track":"mic","start":1930.0,"end":1933.0,"text":"这句话保留原文，只确认界面的发言人入口。","final":true,"speaker":["basis":"unknown"]]
    app.receive(unknown);app.renderText();try app.settleTranscriptForOfflineReview()
    let exportBefore=app.transcriptExport()
    try check(app.output.string.contains("未识别 · 是谁？") && exportBefore.contains("待确认"),"paper_unknown_display_changes_without_export_wording")
    try check(app.heading.isDescendant(of:app.recordingTransportView!) && !app.meetingEyebrow!.stringValue.contains(app.phase.time),"paper_status_and_timer_live_only_in_transport_not_title")
    try check(app.notesController!.toggle.isDescendant(of:app.recordingTransportView!),"paper_note_entry_inside_capsule")
    app.window.appearance=NSAppearance(named:.aqua);app.window.setContentSize(NSSize(width:1040,height:720));app.sidebarManualVisible=nil;app.layoutWorkspace();settle()
    try snapshot(app,"paper-sidebar-title-unknown")
    app.showDocumentSearch();settle();try snapshot(app,"paper-chinese-find")
    app.scroll.isFindBarVisible=false
    app.window.appearance=NSAppearance(named:.darkAqua);try snapshot(app,"paper-dark")
    app.window.setContentSize(NSSize(width:640,height:480));app.layoutWorkspace();settle();try snapshot(app,"paper-640pt")
    try check(app.sidebar.isHidden && app.recordingTransportView!.frame.maxX<=app.recordingTransportView!.superview!.bounds.width+0.5,"paper_640pt_transport_inside_document")
    try check(app.transcriptExport()==exportBefore,"paper_rendering_preserves_exact_transcript_export_bytes")
    return ["type":"workspace_checks","passed":checks.count,"checks":checks,"images":images,"capture":false,"cloud":false,"keychain":false,"offscreen":true]
}
