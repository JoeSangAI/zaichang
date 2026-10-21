import AppKit
import Foundation
// Visible QA is deliberately a separate bundle. It never uses a live worker.
extension Delegate {
    var offlineQA:Bool {Bundle.main.object(forInfoDictionaryKey:"OfflineQA") as? Bool==true}
    func configureOfflineQA()throws {
        guard Credential.offline,!authorized else{throw Failure(code:"offline_qa_not_isolated")}
        recoveryRootOverride=offlineQACacheRoot()
        recoveryBudgetOverride=10;try vault.save("synthetic-offline-qa")
        window.title="在场 · 离线QA · 假数据／无音源／无云"
        recoveryRunnerOverride={ [weak self] item in self?.startQARecovery(item) }
        mockRecordingControlHandler={ [weak self] command in
            guard let self=self,command["session"] as? String==self.activeSession else{return}
            if command["action"] as? String=="pause",self.phase.phase == .recording {
                self.timer?.invalidate();self.receive(["type":"recording_paused","session":self.activeSession ?? ""])
            } else if command["action"] as? String=="resume",self.phase.phase == .paused {
                self.receive(["type":"recording_resumed","session":self.activeSession ?? ""])
                self.timer=Timer.scheduledTimer(withTimeInterval:0.4,repeats:true){[weak self] _ in self?.mockStep()}
            }
        }
        // Startup must not enumerate the fixture filesystem on the AppKit main thread.
        // QA fixtures are created explicitly through the QA menu or fake Start action.
        diagnostic.stringValue="离线开发预览 · 使用虚构发言，不采音、不连接云"
    }
    func makeQACache(complete:Bool)throws->CachedMeeting {
        guard offlineQA,Credential.offline,let base=recoveryRootOverride else{throw Failure(code:"offline_qa_scope")}
        let id=UUID().uuidString;let folder=base.appendingPathComponent(id);let store=try RecordingJournal(directory:folder,track:"mic",freeSpace:{1_000_000_000})
        for index in 0..<50 {try store.enqueue(Data(repeating:0,count:3200),at:100+Double(index)/10)};store.finish();store.wait()
        let session="qa-"+id
        let metadata:[String:Any]=["session":session,"bundle":"*microphone*","asr_destination":"dashscope.aliyuncs.com","asr_model":"qwen-audio-3.0-asr-flash-streaming","fixture":true,"audio_is_synthetic_silence":true]
        try JSONSerialization.data(withJSONObject:metadata).write(to:folder.appendingPathComponent("meeting.json"),options:.atomic)
        if complete {try store.commit("asr",cursor:store.bytes());store.wait()}
        return CachedMeeting(id:id,directory:folder,date:Date(),writtenBytes:160000,pendingBytes:complete ? 0:160000,occupiedBytes:160000,tracks:["mic"],audioCleaned:false,warning:false,retiredBytes:0)
    }
    func beginQAMeetingAsync(done:@escaping()->Void){
        diagnostic.stringValue="正在后台建立假会话；停止可取消等待"
        qaWriteJob.run(work:{let item=try self.makeQACache(complete:false);return (item,try RecordingJournal(directory:item.directory,track:"mic"),try item.metadata())}){[weak self] result in guard let self=self else{return};switch result {case .success(let (item,store,metadata)):self.qaStore=store;self.qaSession=metadata["session"] as? String ?? item.id;self.activeSession=self.qaSession;self.currentCacheID=item.id;self.cachedTranscriptionComplete=false;self.sessionSource="离线假会议";self.source.stringValue="假人物A／B · 无音源／无云";done();case .failure:self.phase.phase = .failed;self.phase.error="假会话后台读取超时或失败；文件保留";self.updateUI()}}
    }
    func qaUtterance(_ index:Int) {
        guard offlineQA else{return};let slot=index%2;let epoch="qa-speakers"
        let event:[String:Any]=["type":"segment","session":qaSession,"segment_id":"qa-live-\(index)","revision":1,"source_id":"mic","epoch":epoch,"track":"mic","start":Double(index)*0.4,"end":Double(index)*0.4+0.35,"end_time_known":true,"received_at":Double(index)*0.4+0.4,"text":"假人物\(slot==0 ? "A":"B")第\(index)句：这只是离线界面验证，没有真人录音。","final":true,"speaker":["basis":"anonymous_cluster","source_id":"mic","epoch":epoch,"cluster_id":slot]]
        qaStore?.record(event);receive(event)
    }
    func finishQAMeeting(){timer?.invalidate();receive(["type":"meter","elapsed_seconds":Double(mockTick)*0.4,"estimated_yuan":"0"]);guard let store=qaStore else{return};qaStore=nil;phase.phase = .stopping;updateUI();qaWriteJob.run(work:{try store.commit("asr",cursor:store.bytes());store.wait()}){[weak self] result in guard let self=self else{return};switch result {case .success:self.receive(["type":"stopped","reason":"user_stop","transcription_complete":true]);case .failure:self.receive(["type":"stopped","reason":"processing_cancelled","transcription_complete":false]);self.diagnostic.stringValue="假会话保存未完成；文件保留"}}}
    @objc func qaPrepare(){guard offlineQA,child==nil else{return};timer?.invalidate();preparingModels=true;modelsPrepared=false;preparationElapsed=0;phase.phase = .connecting;updateUI()
        timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] timer in guard let self=self else{timer.invalidate();return};self.preparationElapsed+=1;self.receive(["type":"preparation","state":"progress","track":self.preparationElapsed<4 ? "mic":"remote","elapsed_seconds":self.preparationElapsed]);if self.preparationElapsed>=8 {timer.invalidate();self.receive(["type":"preparation","state":"ready","elapsed_seconds":8]);self.diagnostic.stringValue="假准备已完成；未加载模型、未采音、未连接云"}}
    }
    @objc func qaSeedRecovery(){guard offlineQA else{return};diagnostic.stringValue="正在后台添加假会话";qaWriteJob.run(work:{try self.makeQACache(complete:false)}){[weak self] result in switch result {case .success:self?.diagnostic.stringValue="已添加5秒假未完成会话";case .failure:self?.diagnostic.stringValue="添加超时／失败；文件保留"}}}
    @objc func qaLongTranscript(){
        guard offlineQA,child==nil else{return};timer?.invalidate()
        // Pure text must still work when a kernel directory read has not returned.
        if qaStore==nil {qaWriteJob.cancel();naming.reset();sourceActivity=SourceActivity();segments=[:];sequence=[];expandedParents=[:];transcriptCapacity.reset();transcriptLimitHit=false;showWholeTranscript=false;recoveredArchiveText=nil;qaSession="qa-memory-"+UUID().uuidString;activeSession=qaSession;currentCacheID=nil;cachedTranscriptionComplete=false}
        phase=UIState();phase.phase = .recording;sessionSource="离线假文本";source.stringValue="220条假发言 · 无原音／无云"
        for index in 1000..<1220 {qaUtterance(index)}
        if qaStore != nil {finishQAMeeting()}else{receive(["type":"stopped","reason":"user_stop","transcription_complete":true]);diagnostic.stringValue="220条内存假文本已生成，可导出；不读取旧目录"}
    }
    @objc func qaNetworkMode(_ item:NSMenuItem){guard offlineQA else{return};qaRecoveryMode=item.tag==1 ? "offline":item.tag==2 ? "disconnect":"slow";diagnostic.stringValue="恢复协议假场景："+qaRecoveryMode+"（无网络连接）"}
    func installQAMenu(_ menu:NSMenu){guard offlineQA else{return};let node=NSMenuItem();menu.addItem(node);let qa=NSMenu(title:"离线QA");node.submenu=qa
        for (title,selector) in [("假准备进度／取消／重开",#selector(qaPrepare)),("添加假未完成会话",#selector(qaSeedRecovery)),("添加220条假发言",#selector(qaLongTranscript))] {let item=qa.addItem(withTitle:title,action:selector,keyEquivalent:"");item.target=self}
        for (tag,title) in [(0,"假补转：正常（可取消）"),(1,"假补转：无网保留"),(2,"假补转：断线后恢复")] {let item=qa.addItem(withTitle:title,action:#selector(qaNetworkMode(_:)),keyEquivalent:"");item.target=self;item.tag=tag}
    }
    func startQARecovery(_ item:CachedMeeting){
        guard offlineQA,Credential.offline else{return}
        let proc=Process();let pipe=Pipe();proc.executableURL=captureExecutableURL;proc.arguments=["--qa-recovery-fixture",item.id,qaRecoveryMode];proc.standardOutput=pipe;proc.standardError=FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler={ [weak self] handle in let data=handle.availableData;guard !data.isEmpty else{return};self?.readLock.lock();self?.pending.append(data);self?.readLock.unlock();DispatchQueue.main.async{self?.drain()}}
        proc.terminationHandler={ [weak self] _ in DispatchQueue.main.async {pipe.fileHandleForReading.readabilityHandler=nil;self?.drain();self?.child=nil;self?.resumeBusy=false;self?.processingAudio=false;self?.updateUI();self?.completeApplicationTerminationIfReady()}}
        do {try proc.run();child=proc}catch{resumeBusy=false;processingAudio=false;phase.phase = .failed;phase.error="离线协议夹具未启动";updateUI()}
    }
}

func offlineQAClockChecks(input:URL)throws {
    guard Credential.offline,let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,input.standardizedFileURL.path==URL(fileURLWithPath:root+"/native/validation-workflow/production-clock-protocol.jsonl").standardizedFileURL.path else{throw Failure(code:"offline_clock_scope")}
    _ = NSApplication.shared
    let view=Delegate();view.previewRenderOnly=true;view.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    view.toggle();waitQAIO(view);view.timer?.invalidate();for _ in 0..<45 {view.mockStep()}
    precondition(view.phase.elapsed==18 && view.meter.stringValue.hasPrefix("00:18") && view.phase.estimated==0)
    let firstID=view.currentCacheID!;view.naming.setSpeaker(segment:"qa-live-2",name:"第一场人物");view.persistSessionNames();view.cacheWriteQueue.sync{}
    view.end();waitQAIO(view);let stopped=view.phase.elapsed;view.mockStep();view.updateUI();precondition(view.phase.elapsed==stopped && view.phase.phase == .stopped && view.phase.estimated==0)
    view.newMeeting();precondition(view.sequence.isEmpty && view.currentCacheID==nil && view.phase.elapsed==0)
    view.toggle();waitQAIO(view);view.timer?.invalidate();precondition(view.phase.elapsed==0 && view.meter.stringValue.hasPrefix("00:00"));let secondID=view.currentCacheID!;precondition(secondID != firstID)
    for _ in 0..<10 {view.mockStep()};precondition(view.sequence.count==10 && view.naming.name(segment:"qa-live-2")==nil);view.end();waitQAIO(view)
    view.showRecoveries();waitQAIO(view);precondition(view.recoveries.contains{$0.id==firstID} && view.recoveries.contains{$0.id==secondID});view.recoveryPicker!.selectItem(at:view.recoveries.firstIndex{$0.id==firstID}!);view.changeRecoverySelection();view.viewRecoveryOriginal();waitQAIO(view);precondition(view.sequence.count==45 && view.naming.name(segment:"qa-live-2")=="第一场人物")
    view.mock=false;view.availableCloudSeconds=0;view.newMeeting();precondition(view.newRecordingPending && view.phase.phase == .idle && view.action.isEnabled);view.toggle();precondition(view.child==nil && view.currentCacheID==nil && view.phase.phase == .idle);view.showRecoveries();waitQAIO(view);precondition(view.recoveries.contains{$0.id==firstID});view.laterRecovery();view.mock=true
    view.phase=UIState();view.pending=try Data(contentsOf:input);view.drain()
    precondition(view.phase.phase == .stopped && view.phase.elapsed==12 && view.meter.stringValue.hasPrefix("00:12") && view.phase.estimated==0)
    print("{\"type\":\"offline_qa_clock_checks\",\"qa_growth_stop_reset\":true,\"production_protocol_stdout_to_gui\":true,\"fee_zero\":true,\"two_sessions_history_isolated\":true,\"exhausted_budget_history_and_pending_new\":true,\"capture\":false,\"network\":false,\"keychain\":false}")
}

func waitQAIO(_ view:Delegate){let until=Date().addingTimeInterval(6);while (view.cacheReadJob.busy || view.cacheExportJob.busy || view.qaWriteJob.busy) && Date()<until {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))};precondition(!view.cacheReadJob.busy && !view.cacheExportJob.busy && !view.qaWriteJob.busy)}

func cacheAsyncChecks()throws {
    _ = NSApplication.shared;let job=CacheReadJob();var ticks=0;let timer=Timer.scheduledTimer(withTimeInterval:0.005,repeats:true){_ in ticks+=1};defer{timer.invalidate()}
    func wait(){let until=Date().addingTimeInterval(2);while job.busy && Date()<until {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))};precondition(!job.busy)}
    let gate=DispatchSemaphore(value:0);var timedOut=false;var stale=false;job.run(timeout:0.03,work:{precondition(!Thread.isMainThread);_ = gate.wait(timeout:.now()+5);return 1}){result in switch result {case .failure:timedOut=true;case .success:stale=true}}
    let until=Date().addingTimeInterval(2);while (!timedOut || ticks<=2) && Date()<until {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))};precondition(timedOut && job.busy && ticks>2)
    var rejected=false;job.run(work:{return 2}){result in if case .failure=result {rejected=true}};precondition(rejected);gate.signal();wait();precondition(!stale)
    var cancelledCallback=false;job.run(work:{Thread.sleep(forTimeInterval:0.05);return 3}){_ in cancelledCallback=true};job.cancel();wait();precondition(!cancelledCallback)
    guard let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String else{throw Failure(code:"offline_scope")};var items:[CachedMeeting]=[];var failed:Error?;job.run(work:{try cachedMeetings(in:URL(fileURLWithPath:root+"/native/validation-workflow/recovery-ui-fixtures"))}){result in switch result {case .success(let value):items=value;case .failure(let error):failed=error}};wait();if let error=failed {throw error};precondition(!items.isEmpty)
    var loaded=false;job.run(work:{try RecoveryPayload(items[0])}){result in if case .success=result {loaded=true}};wait();precondition(loaded)
    print("{\"type\":\"cache_async_checks\",\"ui_heartbeat_during_blocked_io\":true,\"timeout_visible\":true,\"cancel_discards_late_result\":true,\"no_duplicate_blocked_reads\":true,\"actual_fixture_scan_and_payload_read\":true,\"capture\":false,\"network\":false}")
}

func offlineQABlockedReadChecks()throws {
    guard Credential.offline,Bundle.main.object(forInfoDictionaryKey:"OfflineQA") as? Bool==true else{throw Failure(code:"offline_qa_scope")}
    _ = NSApplication.shared
    let view=Delegate();view.previewRenderOnly=true;view.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    let gate=DispatchSemaphore(value:0);var timedOut=false
    view.cacheReadJob.run(timeout:0.03,work:{_ = gate.wait(timeout:.now()+5);return 1}){_ in timedOut=true};defer{gate.signal()}
    let until=Date().addingTimeInterval(2)
    while !timedOut && Date()<until {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))}
    precondition(timedOut && view.cacheReadJob.busy && !view.cacheReadJob.waiting)
    view.qaLongTranscript();precondition(view.sequence.count==220 && view.exportButton!.isEnabled && view.currentCacheID==nil)
    let folder=offlineQACacheRoot().deletingLastPathComponent().appendingPathComponent("Exports");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let file=folder.appendingPathComponent("blocked-read-220-"+UUID().uuidString+".txt");view.saveTranscriptAsync(to:file)
    let deadline=Date().addingTimeInterval(2);while view.cacheExportJob.busy && Date()<deadline {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005))}
    let text=try String(contentsOf:file,encoding:.utf8)
    precondition(!view.cacheExportJob.busy && view.cacheReadJob.busy && text.contains("第1000句") && text.contains("第1219句") && view.diagnostic.stringValue.contains("220段"))
    print("{\"type\":\"offline_qa_blocked_read_checks\",\"memory_220_generated_while_read_blocked\":true,\"complete_export_while_read_blocked\":true,\"old_documents_read_or_copied\":false,\"capture\":false,\"network\":false,\"keychain\":false}")
}

func offlineQAAudioRestoreChecks()throws {
    guard Credential.offline,Bundle.main.object(forInfoDictionaryKey:"OfflineQA") as? Bool==true else{throw Failure(code:"offline_qa_scope")}
    _ = NSApplication.shared;let view=Delegate();view.previewRenderOnly=true;view.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    let base=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("meeting-restore-check-"+UUID().uuidString);try FileManager.default.createDirectory(at:base,withIntermediateDirectories:false);view.recoveryRootOverride=base;let raw=Data(repeating:0,count:160000)
    func archived()throws->CachedMeeting {let item=try view.makeQACache(complete:true);try archiveAndCleanSessionAt(item.directory,text:"离线恢复原音测试",retire:{try retireFixtureAudio($0,base:base,id:item.id)});return try cachedMeetings(in:base).first{$0.id==item.id}!}
    let item=try archived();let receiptBefore=try Data(contentsOf:item.directory.appendingPathComponent("audio-retirement.json"));let source=base.appendingPathComponent(".retired/").appendingPathComponent(item.id).appendingPathComponent("mic-000000.pcm")
    // Collision never overwrites a newly present original.
    let existing=item.directory.appendingPathComponent("mic-000000.pcm");try Data("do not overwrite".utf8).write(to:existing)
    do {try restoreRetiredAudioAt(item.directory,sessionBase:base,allowedRetiredBase:base.appendingPathComponent(".retired"));preconditionFailure()}catch{precondition((error as? Failure)?.code=="cache_restore_conflict")};precondition(try! Data(contentsOf:source)==raw);precondition(try! String(contentsOf:existing)=="do not overwrite");try FileManager.default.removeItem(at:existing)
    // Hash mismatch changes no file or metadata.
    try Data(repeating:1,count:160000).write(to:source)
    do {try restoreRetiredAudioAt(item.directory,sessionBase:base,allowedRetiredBase:base.appendingPathComponent(".retired"));preconditionFailure()}catch{precondition((error as? Failure)?.code=="cache_restore_hash_mismatch")};precondition(try! Data(contentsOf:item.directory.appendingPathComponent("audio-retirement.json"))==receiptBefore);try raw.write(to:source)
    // Scope and symlink destinations are rejected before moving.
    do {try restoreRetiredAudioAt(item.directory,sessionBase:base.appendingPathComponent("other"),allowedRetiredBase:base.appendingPathComponent(".retired"));preconditionFailure()}catch{precondition((error as? Failure)?.code=="cache_restore_scope_invalid")}
    let receiptFile=item.directory.appendingPathComponent("audio-retirement.json");var bad=try JSONSerialization.jsonObject(with:receiptBefore) as! [String:Any];bad["destination"]=base.appendingPathComponent("unrelated").path;try JSONSerialization.data(withJSONObject:bad).write(to:receiptFile)
    do {try restoreRetiredAudioAt(item.directory,sessionBase:base,allowedRetiredBase:base.appendingPathComponent(".retired"));preconditionFailure()}catch{precondition((error as? Failure)?.code=="cache_restore_scope_invalid")};try receiptBefore.write(to:receiptFile)
    let original=base.appendingPathComponent(".retired/").appendingPathComponent(item.id);let saved=original.appendingPathExtension("fixture");try FileManager.default.moveItem(at:original,to:saved);try FileManager.default.createSymbolicLink(at:original,withDestinationURL:saved)
    do {try restoreRetiredAudioAt(item.directory,sessionBase:base,allowedRetiredBase:base.appendingPathComponent(".retired"));preconditionFailure()}catch{precondition((error as? Failure)?.code=="cache_restore_scope_invalid")};try FileManager.default.removeItem(at:original);try FileManager.default.moveItem(at:saved,to:original)
    view.recoveries=[item];view.presentRecoveries();precondition(view.recoveryRestore!.isEnabled);view.restoreRecoveryAudioConfirmed(item);waitQAIO(view)
    precondition(try! Data(contentsOf:existing)==raw);precondition(!FileManager.default.fileExists(atPath:source.path));let restored=try cachedMeetings(in:base).first{$0.id==item.id}!;precondition(restored.audioRestored && !restored.audioCleaned && restored.retiredBytes==0 && restored.pendingBytes==0)
    try archiveAndCleanSessionAt(item.directory,text:"恢复后重新导出",retire:{_ in preconditionFailure("restored audio must stay pinned")});precondition(try! Data(contentsOf:existing)==raw)
    try restoreRetiredAudioAt(item.directory,sessionBase:base,allowedRetiredBase:base.appendingPathComponent(".retired"));precondition(try! Data(contentsOf:existing)==raw)
    try view.importRecovery(restored);let export=base.appendingPathComponent("restore-reexport-"+item.id+".txt");view.saveTranscriptAsync(to:export);waitQAIO(view);precondition(view.currentCacheID==item.id && view.diagnostic.stringValue.contains("原文已导出"));try view.saveTranscript(to:export);precondition(view.currentCacheID==item.id && view.diagnostic.stringValue.contains("原文已导出"));precondition(try! Data(contentsOf:existing)==raw)
    print("{\"type\":\"offline_qa_audio_restore_checks\",\"AppKit_confirmed_restore_handler\":true,\"same_PCM_hash_and_bytes\":true,\"no_duplicate\":true,\"collision_hash_scope_and_symlink_rejected\":true,\"restored_audio_pinned_on_export\":true,\"capture\":false,\"cloud\":false,\"keychain\":false}")
}

func networkStateUIChecks()throws {
    guard Credential.offline else{throw Failure(code:"offline_qa_scope")}
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited);let v=Delegate();v.previewRenderOnly=true;v.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    v.receive(["type":"started","session":"network-ui","cache_id":UUID().uuidString]);v.receive(["type":"asr_reconnecting","track":"mic","attempt":17]);precondition(v.phase.phase == .recording && v.heading.stringValue.contains("等待网络") && v.action.title=="暂停录音" && v.action.isEnabled && !v.action.isHiddenOrHasHiddenAncestor)
    v.receive(["type":"asr_catching_up","track":"mic"]);precondition(v.heading.stringValue.contains("补全转写"));v.receive(["type":"asr_reconnecting","track":"remote"]);v.receive(["type":"asr_resumed","track":"mic"]);precondition(v.heading.stringValue.contains("等待网络"));v.receive(["type":"asr_resumed","track":"remote"]);precondition(v.heading.stringValue.contains("录音中") && !v.heading.stringValue.contains("等待网络"))
    v.receive(["type":"asr_pending","track":"mic","reason":"audio_budget_limit"]);precondition(v.heading.stringValue.contains("待补转写"));v.receive(["type":"stopped","reason":"user_stop","transcription_complete":false]);precondition(v.heading.stringValue.contains("待转写") && !v.cachedTranscriptionComplete)
    print("{\"type\":\"network_state_ui_checks\",\"actual_AppKit_heading_updated\":true,\"waiting_catching_live_pending_visible\":true,\"two_track_status_not_cleared_early\":true,\"stop_incomplete_visible\":true,\"capture\":false,\"network\":false,\"keychain\":false,\"window_opened\":false}")
}
