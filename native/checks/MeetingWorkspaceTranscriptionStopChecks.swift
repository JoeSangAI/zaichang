import AppKit
import Foundation

/// Checks that paused tail transcription remains background status while the
/// primary control resumes and pauses the same conversation.
@MainActor
func meetingWorkspaceTranscriptionPauseChecks(directory:URL)throws->[String] {
    guard Credential.offline,directory.standardizedFileURL.path.contains("/.runtime/") else {
        throw Failure(code:"workspace_transcription_pause_scope")
    }
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    var checks:[String]=[]
    func check(_ condition:Bool,_ name:String)throws {
        guard condition else{throw Failure(code:name)}
        checks.append(name)
    }
    let paused=Delegate();paused.previewRenderOnly=true
    paused.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    paused.currentCacheID=UUID().uuidString;paused.activeSession="paused-tail-fixture"
    paused.phase.phase = .paused;paused.pausedTailStates=["mic":"processing"]
    var controlCommands:[[String:Any]]=[]
    paused.mockRecordingControlHandler={controlCommands.append($0)}
    paused.updateUI()
    try check(paused.action.title=="继续录音" && paused.action.isEnabled && paused.hasPendingTranscriptionWork && paused.meetingEyebrow?.stringValue.hasSuffix(" · 正在补齐已录文字")==true,
              "paused_tail_is_background_status_with_primary_resume")
    try check(paused.newButton?.isEnabled==true && !paused.toolbarAllowedItemIdentifiers(paused.window.toolbar!).contains(NSToolbarItem.Identifier("new")),
              "new_conversation_has_one_sidebar_entry")
    let cacheID=paused.currentCacheID
    let session=paused.activeSession!,epoch="pause-speaker-fixture"
    func speech(_ id:String,_ slot:Int,_ start:Double)->[String:Any] {
        ["type":"segment","session":session,"segment_id":id,"revision":1,
         "source_id":"mic","track":"mic","epoch":epoch,"start":start,"end":start+1,
         "end_time_known":true,"final":true,"text":"合成发言 \(id)。",
         "speaker":["basis":"anonymous_cluster","source_id":"mic","epoch":epoch,"cluster_id":slot]]
    }
    // Edit while paused, then send genuinely new provider segment IDs after
    // reconnect. Existing rows alone cannot prove that names carry forward.
    paused.receive(speech("before-a",0,0));paused.receive(speech("before-b",1,2))
    paused.receive(speech("before-duplicate",2,4))
    paused.naming.setSpeaker(segment:"before-a",name:"合成人物甲")
    paused.naming.setSpeaker(segment:"before-b",name:"合成人物乙")
    let keyA=paused.naming.key(segment:"before-a")!,keyB=paused.naming.key(segment:"before-b")!
    let duplicate=paused.naming.key(segment:"before-duplicate")!
    try check(paused.naming.mergeSpeaker(from:duplicate,to:keyA,humanConfirmed:true),
              "paused_person_merge_is_retained_for_future_turns")
    let namesBeforeResume=paused.naming.correctionRevision
    paused.action.performClick(nil)
    try check(controlCommands.last?["action"] as? String=="resume" && controlCommands.last?["session"] as? String=="paused-tail-fixture",
              "primary_resume_targets_original_conversation_during_tail_processing")
    paused.receive(["type":"recording_resumed","session":"paused-tail-fixture","control_revision":1])
    try check(paused.phase.phase == .recording && paused.currentCacheID==cacheID,"resume_preserves_cache_identity")
    paused.receive(speech("after-a",0,6));paused.receive(speech("after-b",1,8))
    paused.receive(speech("after-duplicate",2,10))
    try check(paused.naming.key(segment:"after-a")==keyA && paused.naming.name(segment:"after-a")=="合成人物甲" &&
              paused.naming.key(segment:"after-b")==keyB && paused.naming.name(segment:"after-b")=="合成人物乙",
              "resumed_new_turns_reuse_both_manual_names_and_person_keys")
    try check(paused.naming.key(segment:"after-duplicate")==keyA && paused.naming.name(segment:"after-duplicate")=="合成人物甲" &&
              paused.naming.choices(session:session).count==2 && paused.naming.correctionRevision==namesBeforeResume,
              "resumed_merged_slot_does_not_create_a_third_person_or_modify_corrections")
    paused.action.performClick(nil)
    paused.receive(["type":"recording_paused","session":"paused-tail-fixture","control_revision":2,"draining_tracks":["mic"]])
    try check(paused.phase.phase == .paused && paused.currentCacheID==cacheID && paused.action.title=="继续录音" && !paused.newMeetingRequested,
              "second_pause_remains_in_same_conversation")
    try check(controlCommands.map{$0["action"] as? String ?? ""}==["resume","pause"] && controlCommands.allSatisfy{$0["session"] as? String=="paused-tail-fixture"},
              "pause_resume_pause_commands_keep_original_session")
    checks.append("pause-resume-pause remains one conversation")
    try check(paused.naming.renameSpeaker(key:keyA,name:"合成人物甲改名"),"second_pause_can_update_existing_person_name")
    paused.action.performClick(nil)
    paused.receive(["type":"recording_resumed","session":session,"control_revision":3])
    paused.receive(speech("second-resume-a",2,12));paused.receive(speech("second-resume-b",1,14))
    try paused.settleTranscriptForOfflineReview()
    try check(paused.naming.name(segment:"second-resume-a")=="合成人物甲改名" &&
              paused.naming.name(segment:"before-a")=="合成人物甲改名" &&
              paused.naming.name(segment:"second-resume-b")=="合成人物乙" &&
              paused.naming.choices(session:session).count==2 && !paused.transcriptExport().contains("发言人 "),
              "second_resume_and_export_keep_latest_name_without_duplicate_speakers")
    let saved=try paused.naming.snapshot(session:session)
    var restored=SessionNames()
    for id in paused.sequence {if let item=paused.segments[id] {restored.register(segment:id,item:item)}}
    try restored.restore(saved,session:session)
    restored.register(segment:"reopened-a",item:speech("reopened-a",2,16))
    restored.register(segment:"reopened-b",item:speech("reopened-b",1,18))
    try check(restored.name(segment:"reopened-a")=="合成人物甲改名" && restored.name(segment:"reopened-b")=="合成人物乙" &&
              restored.choices(session:session).count==2,"saved_names_and_merges_apply_to_later_turns_after_restore")
    var fresh=speech("fresh-session",0,0);fresh["session"]="different-meeting"
    restored.register(segment:"fresh-session",item:fresh)
    try check(restored.name(segment:"fresh-session")==nil,"same_slot_in_new_conversation_does_not_inherit_old_name")
    paused.window.orderOut(nil)
    return checks
}

/// Exercise actual AppKit close handlers and owned, synthetic subprocess shutdown.
@MainActor
func meetingWindowLifecycleChecks(directory:URL)throws->[String] {
    guard Credential.offline,directory.standardizedFileURL.path.contains("/.runtime/") else {
        throw Failure(code:"window_lifecycle_scope")
    }
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    var checks:[String]=[]
    func check(_ condition:Bool,_ name:String)throws {
        guard condition else{throw Failure(code:name)};checks.append(name)
    }
    func wait(_ condition:()->Bool)throws {
        let deadline=Date().addingTimeInterval(5)
        while !condition() && Date()<deadline {RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))}
        guard condition() else{throw Failure(code:"window_lifecycle_timeout")}
    }
    func owner()->Delegate {
        let view=Delegate();view.previewRenderOnly=true
        view.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
        view.window.setFrameOrigin(NSPoint(x:-10000,y:-10000))
        view.terminationReplyOverride={}
        return view
    }
    for phase in [RecordingPhase.recording,.paused,.stopping,.connecting] {
        let view=owner();view.phase.phase=phase;view.activeSession="window-fixture-"+phase.rawValue
        view.processingAudio=phase == .stopping
        let proc=Process(),ready=Pipe()
        proc.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        proc.arguments=["-u","-c","import signal,time,sys\nstops=0\ndef stop(*_):\n global stops\n stops+=1\n if stops==2: sys.exit(0)\nsignal.signal(signal.SIGINT,stop)\nprint('ready',flush=True)\ntime.sleep(60)"]
        proc.standardOutput=ready;proc.standardError=FileHandle.nullDevice;try proc.run()
        defer {if proc.isRunning {proc.terminate();proc.waitUntilExit()}}
        guard !ready.fileHandleForReading.availableData.isEmpty else{throw Failure(code:"synthetic_worker_not_ready")}
        view.child=proc
        view.window.orderFront(nil)
        view.window.standardWindowButton(.closeButton)!.performClick(nil)
        try check(!view.window.isVisible && proc.isRunning && !view.quitting && view.phase.phase==phase,
                  "red_close_preserves_"+phase.rawValue)
        try check(!view.applicationShouldTerminateAfterLastWindowClosed(NSApp),"last_window_does_not_quit_"+phase.rawValue)
        _=view.applicationShouldHandleReopen(NSApp,hasVisibleWindows:false)
        try check(view.window.isVisible && proc.isRunning && view.activeSession=="window-fixture-"+phase.rawValue,
                  "dock_reopen_preserves_"+phase.rawValue)
        let windowMenu=NSApp.mainMenu!.items.first{$0.submenu?.title=="窗口"}!.submenu!
        let close=windowMenu.items.first{$0.keyEquivalent=="w"}!
        try check(close.action == #selector(Delegate.closeWindow) && close.target === view,"command_w_targets_close_"+phase.rawValue)
        view.closeWindowTarget(view.window)
        try check(!view.window.isVisible && proc.isRunning && !view.quitting,"command_w_preserves_"+phase.rawValue)
        let quit=NSApp.mainMenu!.items[0].submenu!.items.first{$0.keyEquivalent=="q"}!
        try check(quit.action == #selector(Delegate.quitApplication) && quit.target === view,"command_q_targets_quit_"+phase.rawValue)
        view.newRecordingPending=true;view.newMeetingRequested=true
        try check(view.applicationShouldTerminate(NSApp) == .terminateLater,"quit_waits_for_worker_"+phase.rawValue)
        try wait{!proc.isRunning};proc.waitUntilExit()
        try check(proc.terminationStatus==0 && view.quitting && !view.newRecordingPending && !view.newMeetingRequested,
                  "quit_stops_worker_and_clears_pending_new_meeting_"+phase.rawValue)
        view.child=nil;view.completeApplicationTerminationIfReady()
    }
    let modal=owner(),panel=NSPanel(contentRect:NSRect(x:0,y:0,width:200,height:100),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    panel.animationBehavior = .none;modal.window.orderFront(nil);modal.phase.phase = .recording
    modal.window.beginSheet(panel)
    modal.closeWindowTarget(panel)
    try wait{modal.window.attachedSheet==nil}
    try check(modal.window.isVisible && !panel.isVisible && !modal.quitting && modal.phase.phase == .recording,
              "command_w_closes_nonsettings_sheet_without_stopping_owner")
    modal.window.orderOut(nil)
    let idle=owner()
    try check(idle.applicationShouldTerminate(NSApp) == .terminateLater,"idle_quit_flushes_write_queue")
    try wait{!idle.terminationReplyPending}
    let pending=owner(),gate=DispatchSemaphore(value:0)
    var restarted=false
    pending.credentialReadJob.run(timeout:20,work:{gate.wait();return true}){_ in restarted=true}
    try wait{pending.credentialReadJob.waiting}
    try check(pending.applicationShouldTerminate(NSApp) == .terminateLater,"quit_cancels_pending_credentials")
    gate.signal();try wait{!pending.credentialReadJob.busy}
    try check(!restarted,"late_credential_result_cannot_restart_after_quit")
    pending.startupWorkerFixture={_ in restarted=true}
    pending.startWorker(nil,overrideRequest:["mode":"local_only"])
    try check(!restarted && pending.child==nil,"late_worker_request_rejected_after_quit")

    let refinement=owner(),marker=directory.appendingPathComponent("refinement-pid.txt")
    let script=directory.appendingPathComponent("ignore-termination.py")
    try "import signal,sys,time,os\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nsys.stdin.readline()\nopen(sys.argv[1],'w').write(str(os.getpid()))\ntime.sleep(60)\n".write(to:script,atomically:true,encoding:.utf8)
    try? FileManager.default.removeItem(at:marker)
    let job=refinement.speakerRefinementJob
    job.startProcess(request:[:],executable:URL(fileURLWithPath:"/usr/bin/python3"),arguments:[script.path,marker.path]){_,_ in}
    defer{job.cancel()}
    try wait{(try? String(contentsOf:marker,encoding:.utf8)).flatMap{Int32($0)} != nil}
    let pid=Int32(try String(contentsOf:marker,encoding:.utf8))!
    var replied=false;refinement.terminationReplyOverride={replied=true}
    refinement.meetingDeletionBusy=true
    try check(refinement.applicationShouldTerminate(NSApp) == .terminateLater && !replied,"quit_waits_for_refinement_and_file_commit")
    try wait{refinement.terminationJobsPending==0}
    try check(kill(pid,0) == -1 && errno==ESRCH && !replied,"quit_reaps_stubborn_refinement_before_file_commit")
    refinement.meetingDeletionBusy=false;refinement.completeApplicationTerminationIfReady()
    try wait{replied}
    try check(replied && !refinement.terminationReplyPending,"quit_replies_after_all_owned_work_stops")

    let saving=owner(),writeGate=DispatchSemaphore(value:0),qaGate=DispatchSemaphore(value:0)
    let saved=directory.appendingPathComponent("queued-name.txt")
    saving.cacheWriteQueue.async {writeGate.wait();try! "人物修改".write(to:saved,atomically:true,encoding:.utf8)}
    saving.qaWriteJob.run(timeout:20,work:{qaGate.wait();return true}){_ in}
    try wait{saving.qaWriteJob.waiting}
    try check(saving.applicationShouldTerminate(NSApp) == .terminateLater,"quit_waits_for_qa_journal_commit")
    saving.completeApplicationTerminationIfReady()
    try check(saving.terminationReplyPending && !saving.terminationWriteBarrierStarted,"pending_qa_write_blocks_termination")
    qaGate.signal();try wait{saving.terminationWriteBarrierStarted}
    try check(saving.terminationReplyPending && !FileManager.default.fileExists(atPath:saved.path),"queued_name_write_blocks_termination")
    writeGate.signal();try wait{!saving.terminationReplyPending}
    try check((try String(contentsOf:saved,encoding:.utf8))=="人物修改","quit_preserves_queued_name_write")
    return checks
}
