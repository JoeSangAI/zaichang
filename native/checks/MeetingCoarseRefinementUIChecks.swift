import Foundation
import AppKit

/// Exercises the production Delegate route with synthetic PCM and a local
/// injected response. It does not read credentials or contact a provider.
@MainActor
func meetingCoarseRefinementUIChecks(directory:URL)throws->[String] {
    guard Credential.offline,directory.path.contains("/.runtime/") else{throw Failure(code:"coarse_ui_check_scope")}
    _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    var checks:[String]=[]
    func check(_ condition:Bool,_ name:String)throws {guard condition else{throw Failure(code:name)};checks.append(name)}
    func write(_ value:Any,to file:URL)throws {
        try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:file,options:.atomic)
    }
    func wait(_ label:String,until deadline:Date,condition:()->Bool)throws {
        while !condition(),Date()<deadline {RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))}
        guard condition() else{throw Failure(code:"coarse_ui_"+label+"_timeout")}
    }

    let root=directory.appendingPathComponent("coarse-refinement-ui-"+UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:root)}
    // A name belongs to the source time span through cleanup and original-view
    // toggles, including anchors created by the previous clean-text-only build.
    let anchorFolder=root.appendingPathComponent(UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:anchorFolder,withIntermediateDirectories:true)
    let rawText="顾问甲甲说明会议安排。",cleanText="顾问甲说明会议安排。",anchorID="named:word:10000"
    let sourceWords:[[String:Any]]=[["start":10.0,"end":11.0,"text":rawText],["start":11.0,"end":12.0,"text":"好的。"]]
    let nextRun:[String:Any]=["start":11.0,"end":12.0,"text":"好的。","speaker":["basis":"anonymous_cluster","cluster_id":1,"source_id":"mic","epoch":"anchor-epoch"]]
    let rawAnchorEvent:[String:Any]=["type":"segment","segment_id":"named","session":"anchor-session","source_id":"mic","epoch":"anchor-epoch","start":10.0,"end":12.0,"end_time_known":true,"text":rawText+"好的。","word_spans":sourceWords,"speaker_runs":[["start":10.0,"end":11.0,"text":rawText,"speaker":["basis":"unknown"]],nextRun]]
    var cleanAnchorEvent=rawAnchorEvent
    cleanAnchorEvent["text"]=cleanText+"好的。";cleanAnchorEvent["coarse_source_word_spans"]=sourceWords
    cleanAnchorEvent["word_spans"]=[["start":10.0,"end":11.0,"text":cleanText],["start":11.0,"end":12.0,"text":"好的。"]]
    cleanAnchorEvent["speaker_runs"]=[["start":10.0,"end":11.0,"text":cleanText,"speaker":["basis":"unknown"]],nextRun]
    var named=SessionNames()
    for run in TranscriptTimeline.speakerRuns(cleanAnchorEvent) where run["start"] as? Double==10 {named.register(segment:anchorID,item:run)}
    named.set(segment:anchorID,name:"顾问甲")
    let anchored=try named.snapshot(session:"anchor-session")
    var reopened=SessionNames();try reopened.restore(anchored,session:"anchor-session")
    try check(reopened.manualRunOverrides(parent:"named",item:rawAnchorEvent).first?.text==rawText && reopened.manualRunOverrides(parent:"named",item:cleanAnchorEvent).first?.text==cleanText && reopened.name(segment:anchorID)=="顾问甲","cleaned_name_anchor_survives_reload_and_raw_clean_toggle")
    var legacy=try JSONSerialization.jsonObject(with:anchored) as! [String:Any]
    var legacyAnchors=legacy["runAnchors"] as! [[String:Any]]
    legacyAnchors[0]["textSHA256"]=MeetingSpeakerReconciliation.hash(Data(cleanText.utf8));legacy["runAnchors"]=legacyAnchors
    let legacyData=try JSONSerialization.data(withJSONObject:legacy,options:[.sortedKeys])
    try legacyData.write(to:anchorFolder.appendingPathComponent("session-names.json"))
    try write(["schema":1,"method":MeetingCoarseRefinement.method,"cache_id":anchorFolder.lastPathComponent,"session":"anchor-session","records":[["unit_id":anchorID,"original_text_sha256":MeetingSpeakerReconciliation.hash(Data(rawText.utf8)),"text":cleanText]]],to:anchorFolder.appendingPathComponent(MeetingCoarseRefinement.filename))
    var oldReopened=SessionNames();try oldReopened.restore(legacyData,session:"anchor-session",events:[rawAnchorEvent],directory:anchorFolder)
    let oldProtected=try SpeakerRefinementArtifact.protectedIDs(directory:anchorFolder,session:"anchor-session",events:[rawAnchorEvent])
    try check(oldReopened.manualRunOverrides(parent:"named",item:rawAnchorEvent).count==1 && oldReopened.manualRunOverrides(parent:"named",item:cleanAnchorEvent).count==1 && oldProtected.contains(anchorID),"legacy_clean_hash_name_resolves_only_through_verified_source_sidecar")
    var changedSource=rawAnchorEvent;changedSource["text"]="另一位发言人的话。";changedSource["word_spans"]=[["start":10.0,"end":11.0,"text":"另一位发言人的话。"]]
    var staleReopened=SessionNames();try staleReopened.restore(legacyData,session:"anchor-session",events:[changedSource],directory:anchorFolder)
    try check(staleReopened.manualRunOverrides(parent:"named",item:changedSource).isEmpty,"legacy_anchor_rejects_changed_source_at_same_timestamp")
    try check(Data(contentsOf:anchorFolder.appendingPathComponent("session-names.json"))==legacyData,"legacy_compatibility_does_not_rewrite_source_names_file")
    let cacheID=UUID().uuidString,session=UUID().uuidString,folder=root.appendingPathComponent(cacheID,isDirectory:true)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let journal=try RecordingJournal(directory:folder,track:"mic",freeSpace:{1_000_000_000})
    try journal.enqueue(Data(repeating:0x24,count:32768),at:9.95)
    try journal.enqueue(Data(repeating:0x25,count:32768),at:10.95)
    try journal.enqueue(Data(repeating:0x26,count:32768),at:11.95)
    journal.finish();journal.commitAfterTranscript(98304);journal.wait()
    let pcmFile=folder.appendingPathComponent("mic-000000.pcm")
    let manifestFile=folder.appendingPathComponent("mic-manifest.json")
    let originalPCM=try Data(contentsOf:pcmFile),originalManifest=try Data(contentsOf:manifestFile)
    let rawKnown:[String:Any]=["type":"segment","session":session,"source_id":"mic","track":"mic","epoch":"epoch-a","segment_id":"known","revision":1,"final":true,"end_time_known":true,"start":0.1,"end":0.8,"text":"人工确认的发言。","speaker":["basis":"anonymous_cluster","source_id":"mic","epoch":"epoch-a","cluster_id":0],"quality_flags":[]]
    let rawTarget:[String:Any]=["type":"segment","session":session,"source_id":"mic","track":"mic","epoch":"epoch-a","segment_id":"target","revision":1,"final":true,"end_time_known":true,"start":0.9,"end":1.7,"text":"这是错误转写。","speaker":["basis":"unknown","reason":"no_speaker_evidence"],"quality_flags":[]]
    let transcript=folder.appendingPathComponent("mic-transcript.jsonl")
    var originalTranscript=Data()
    for event in [rawKnown,rawTarget] {originalTranscript.append(try JSONSerialization.data(withJSONObject:event,options:[.sortedKeys]));originalTranscript.append(10)}
    try originalTranscript.write(to:transcript,options:.atomic)
    try write(["schema":1,"session":session,"capture_origin_uptime":10.0,"bundle":"*microphone*","capture_mode":"cloud","upload_authorized":true,"cloud_session_authorized":true,"asr_destination":"dashscope.aliyuncs.com","cloud_budget_yuan":5,"asr_vocabulary_confirmed":true,"asr_vocabulary":["简知":2]],to:folder.appendingPathComponent("meeting.json"))
    try write(["schema":2,"session":session,"cloud_budget_yuan":5,"cumulative_input_audio_seconds":10,"cumulative_estimated_yuan":"0.0033","meter":["input_audio_seconds":"10","estimated_yuan":"0.0033"]],to:folder.appendingPathComponent("session-usage.json"))

    let view=Delegate();view.previewRenderOnly=true;view.deferPresentation=true
    view.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    view.recoveryRootOverride=root
    view.activeSession=session;view.currentCacheID=cacheID;view.sessionLocalOnly=false;view.phase.phase = .recording
    view.speakerRefinementLifecycle.begin(session:session)
    let originalEvents=try CachedMeeting(id:cacheID,directory:folder,date:Date(),writtenBytes:98304,pendingBytes:0,occupiedBytes:0,tracks:["mic"],audioCleaned:false,warning:false,retiredBytes:0).events(includeAutomaticRefinement:false)
    view.segments=Dictionary(uniqueKeysWithValues:originalEvents.compactMap{event in (event["segment_id"] as? String).map{($0,event)}})
    view.sequence=originalEvents.compactMap{$0["segment_id"] as? String}
    for event in originalEvents {view.naming.register(segment:event["segment_id"] as! String,item:event)}
    view.naming.set(segment:"known",name:"人工确认的顾问甲")
    let fixtureItem=CachedMeeting(id:cacheID,directory:folder,date:Date(),writtenBytes:98304,pendingBytes:0,occupiedBytes:0,tracks:["mic"],audioCleaned:false,warning:false,retiredBytes:0)
    _=try MeetingCoarseRefinement.prepareRequest(directory:folder,session:session,cacheID:cacheID,events:originalEvents,transcriptHashes:fixtureItem.transcriptHashes())
    _=try MeetingCoarseAudioInput.tracks(meeting:fixtureItem,events:originalEvents,allowUnsealed:false)
    var cleanTruncatedManifest=try JSONSerialization.jsonObject(with:originalManifest) as! [String:Any]
    cleanTruncatedManifest["asr_committed_bytes"]=32768
    var checkpointFaultManifest=cleanTruncatedManifest
    checkpointFaultManifest["processing_error"]="cache_checkpoint_write_failed"
    var backpressureManifest=cleanTruncatedManifest
    backpressureManifest["error"]="cache_writer_backpressure"
    for (label,candidate) in [("ended_clean_asr_lag",cleanTruncatedManifest),
                              ("processing_checkpoint_fault",checkpointFaultManifest),
                              ("capture_writer_backpressure",backpressureManifest)] {
        try write(candidate,to:manifestFile)
        let prefixOnlyAudio=try MeetingCoarseAudioInput.tracks(meeting:fixtureItem,events:originalEvents,allowUnsealed:false)
        let prefixOnlyRequest=try MeetingCoarseRefinement.prepareRequest(directory:folder,session:session,cacheID:cacheID,
            events:originalEvents,transcriptHashes:fixtureItem.transcriptHashes())
        try check(prefixOnlyAudio.first?["written_bytes"] as? Int==32768 && prefixOnlyAudio.first?["coverage_complete"] as? Bool==false,
                  "\(label)_limits_refinement_pcm_to_the_durable_transcript_cursor")
        try check(prefixOnlyRequest.incomplete_audio && prefixOnlyRequest.units.allSatisfy({$0.unit_id=="known"}),
                  "\(label)_excludes_uncommitted_final_text_and_keeps_partial_coverage_explicit")
    }
    var recoveredBackpressure=try JSONSerialization.jsonObject(with:originalManifest) as! [String:Any]
    recoveredBackpressure["error"]="cache_writer_backpressure"
    try write(recoveredBackpressure,to:manifestFile)
    let recoveredManifestBytes=try Data(contentsOf:manifestFile)
    let recoveredTracks=try MeetingCoarseAudioInput.tracks(meeting:fixtureItem,events:originalEvents,allowUnsealed:false)
    try check(recoveredTracks.first?["coverage_complete"] as? Bool==true && recoveredTracks.first?["written_bytes"] as? Int==originalPCM.count,
              "fully_transcribed_backpressure_history_does_not_mark_audio_input_pending")
    try check(try Data(contentsOf:manifestFile)==recoveredManifestBytes,"audio_input_preserves_historical_capture_fault")
    try originalManifest.write(to:manifestFile,options:.atomic)
    var corruptTail=originalPCM
    corruptTail[corruptTail.count-1]^=0x01
    try corruptTail.write(to:pcmFile,options:.atomic)
    do {
        _ = try MeetingCoarseAudioInput.tracks(meeting:fixtureItem,events:originalEvents,allowUnsealed:false)
        throw Failure(code:"coarse_ui_corrupt_uncommitted_chunk_accepted")
    } catch let error as Failure where error.code=="coarse_audio_changed" {
        checks.append("partial_refinement_still_verifies_the_entire_saved_chunk_chain")
    }
    try originalPCM.write(to:pcmFile,options:.atomic)

    let lock=NSLock();var pending:(request:[String:Any],token:UUID,done:(UUID,Result<Data,Error>)->Void)?
    view.coarseRefinementExecutorOverride={request,token,done in
        lock.lock();pending=(request,token,done);lock.unlock()
    }
    func takeRequest(until deadline:Date)->(request:[String:Any],token:UUID,done:(UUID,Result<Data,Error>)->Void)? {
        while Date()<deadline {
            lock.lock();let value=pending;pending=nil;lock.unlock()
            if let value{return value}
            RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01))
        }
        return nil
    }
    func syntheticResponse(_ request:[String:Any],warning:String?=nil)throws->Data {
        guard let units=request["units"] as? [[String:Any]],let roster=request["roster"] as? [[String:Any]],
              let knownKey=roster.first?["key"] as? [String:Any] else{throw Failure(code:"coarse_ui_request_shape")}
        let records=try units.map { unit -> [String:Any] in
            guard let id=unit["unit_id"] as? String,let text=unit["text"] as? String,
                  let hash=unit["original_text_sha256"] as? String else{throw Failure(code:"coarse_ui_unit_shape")}
            if id=="target" {return ["unit_id":id,"original_text_sha256":hash,"text":"这是已经校正的转写。","speaker_key":knownKey]}
            if id=="new-tail" {return ["unit_id":id,"original_text_sha256":hash,"text":"这是继续录音后校正的新句。","speaker_key":knownKey]}
            return ["unit_id":id,"original_text_sha256":hash,"text":text]
        }
        var response:[String:Any] = ["ok":true,"schema":1,"method":MeetingCoarseRefinement.method,"session":session,"cache_id":cacheID,"model":"synthetic","source_sha256":request["source_sha256"]!,"snapshot_sha256":request["snapshot_sha256"]!,"records":records]
        if let warning {response["warning"]=warning}
        if request["incomplete_audio"] as? Bool==true {response["incomplete_audio"]=true}
        return try JSONSerialization.data(withJSONObject:response,options:[.sortedKeys])
    }
    var contextReaderFailures:[String]=[]
    func readPublished(_ publisher:MeetingContextPublisher,directory:URL,_ arguments:[String])throws->[String:Any] {
        publisher.flushForChecks()
        let task=Process(),pipe=Pipe(),errorPipe=Pipe();task.executableURL=PythonRuntime.executable()!
        task.arguments=[view.root+"/meeting_context.py","--database",directory.appendingPathComponent("context.sqlite").path]+arguments
        task.standardOutput=pipe;task.standardError=errorPipe
        do {try task.run()} catch {contextReaderFailures.append(String(describing:error));throw error}
        let data=pipe.fileHandleForReading.readDataToEndOfFile(),errors=errorPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus==0,let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {
            contextReaderFailures.append("status=\(task.terminationStatus) stderr=\(String(data:errors,encoding:.utf8) ?? "<non-utf8>") stdout=\(String(data:data,encoding:.utf8) ?? "<non-utf8>")")
            throw Failure(code:"coarse_ui_context_reader_failed")
        }
        return value
    }

    // The first pause owns an explicit monotonic cutoff. A draining ASR tail
    // must not delay dispatch of work over the transcript already on disk.
    view.phase.elapsed=1.72
    view.receive(["type":"recording_paused","session":session,"control_revision":4,"draining_tracks":["mic"]])
    guard let first=takeRequest(until:Date().addingTimeInterval(5)) else{throw Failure(code:"coarse_ui_pause_trigger_missing:"+(view.speakerRefinementFailureCode ?? String(describing:view.phase.phase)))}
    guard let inputUnits=first.request["units"] as? [[String:Any]],
          (inputUnits.first{$0["unit_id"] as? String=="known"}?["manual"] as? Bool)==false,
          (inputUnits.first{$0["unit_id"] as? String=="known"}?["speaker_locked"] as? Bool)==true,
          (inputUnits.first{$0["unit_id"] as? String=="target"}? ["manual"] as? Bool)==false,
          let audio=first.request["audio_tracks"] as? [[String:Any]],audio.count==1,
          first.request["term_hints"] as? [String]==["简知"],
          let offset=audio.first?["origin_seconds"] as? Double,abs(offset + 0.05)<0.000001,
          let firstAudioBytes=audio.first?["written_bytes"] as? Int,firstAudioBytes==56640,
          inputUnits.allSatisfy({($0["end"] as? Double ?? .infinity)<=1.72}) else{
        throw Failure(code:"coarse_ui_input_scope_invalid")
    }
    // The same pause's ASR tail can report completion after the immutable
    // request has started. It queues the same cutoff, but must not pay for or
    // display a duplicate pass if its effective input signature is unchanged.
    view.receive(["type":"recording_pause_tail","session":session,"pause_revision":4,"track":"mic","state":"complete"])
    let tooEarlyMetadata:[String:Any] = ["schema":1,"session":session,"capture_origin_uptime":10.3,
        "bundle":"*microphone*","capture_mode":"cloud","upload_authorized":true,
        "cloud_session_authorized":true,"asr_destination":"dashscope.aliyuncs.com"]
    try write(tooEarlyMetadata,to:folder.appendingPathComponent("meeting.json"))
    do {
        _ = try MeetingCoarseAudioInput.tracks(meeting:fixtureItem,events:originalEvents,allowUnsealed:false)
        throw Failure(code:"coarse_ui_excessive_preroll_accepted")
    } catch let error as Failure where error.code=="coarse_origin_invalid" {
        checks.append("short_negative_mic_offset_is_preserved_and_excessive_preroll_is_rejected")
    }
    try write(["schema":1,"session":session,"capture_origin_uptime":10.0,"bundle":"*microphone*",
        "capture_mode":"cloud","upload_authorized":true,"cloud_session_authorized":true,
        "asr_destination":"dashscope.aliyuncs.com","cloud_budget_yuan":5,
        "asr_vocabulary_confirmed":true,"asr_vocabulary":["简知":2]],to:folder.appendingPathComponent("meeting.json"))
    try check(true,"pause_dispatches_before_asr_tail_and_freezes_text_and_pcm_at_its_explicit_cutoff")
    first.done(first.token,.success(try syntheticResponse(first.request)))
    let sidecar=folder.appendingPathComponent(MeetingCoarseRefinement.filename)
    try wait("sidecar_commit",until:Date().addingTimeInterval(5)){FileManager.default.fileExists(atPath:sidecar.path) && view.speakerRefinementToken==nil}
    let duplicateRequest=takeRequest(until:Date().addingTimeInterval(0.25))
    try check(duplicateRequest==nil && view.pendingCoarseCutoffs[cacheID]==nil,
              "same_cutoff_tail_completion_skips_an_identical_successful_batch")
    let projected=try CachedMeeting(id:cacheID,directory:folder,date:Date(),writtenBytes:98304,pendingBytes:0,occupiedBytes:0,tracks:["mic"],audioCleaned:false,warning:false,retiredBytes:0).events()
    guard let projectedTarget=projected.first(where:{$0["segment_id"] as? String=="target"}) else{throw Failure(code:"coarse_ui_projected_target_missing")}
    try check(projectedTarget["text"] as? String=="这是已经校正的转写。" && projectedTarget["coarse_refinement_applied"] as? Bool==true,"saved_projection_reloads_corrected_text")
    try check(view.naming.name(segment:"known")=="人工确认的顾问甲" && view.naming.sentenceName(segment:"known")=="人工确认的顾问甲","manual_sentence_label_survives_ai_projection")
    try check(try Data(contentsOf:transcript)==originalTranscript,"provider_transcript_remains_byte_identical")

    view.toggleCoarseProjection()
    try wait("original_toggle",until:Date().addingTimeInterval(5)){view.segments["target"]?["text"] as? String=="这是错误转写。"}
    let originalView=try CachedMeeting(id:cacheID,directory:folder,date:Date(),writtenBytes:98304,pendingBytes:0,occupiedBytes:0,tracks:["mic"],audioCleaned:false,warning:false,retiredBytes:0).events()
    try check(originalView.first(where:{$0["segment_id"] as? String=="target"})?["text"] as? String=="这是错误转写。" && FileManager.default.fileExists(atPath:sidecar.path),"original_toggle_and_reload_keep_disposable_refinement_reversible")

    var partialArtifact=try MeetingCoarseAudioInput.object(sidecar)
    let pauseTailBeforeResume:[String:Any] = ["type":"segment","session":session,"source_id":"mic","track":"mic","epoch":"epoch-a",
        "segment_id":"pause-tail-before-resume","revision":1,"final":true,"end_time_known":true,"start":1.68,"end":1.71,
        "text":"暂停补尾后、继续录音前出现的新句。","speaker":["basis":"unknown","reason":"no_speaker_evidence"],"quality_flags":[]]
    originalTranscript.append(try JSONSerialization.data(withJSONObject:pauseTailBeforeResume,options:[.sortedKeys]));originalTranscript.append(10)
    try originalTranscript.write(to:transcript,options:.atomic)
    view.phase.phase = .paused;view.phase.elapsed=1.72
    view.scheduleCoarseRefinement(trigger:"pause",allowUnsealed:true,cutoff:1.72)
    guard let late=takeRequest(until:Date().addingTimeInterval(5)) else{throw Failure(code:"coarse_ui_cancel_fixture_missing")}
    try check((late.request["units"] as? [[String:Any]])?.contains(where:{$0["unit_id"] as? String=="pause-tail-before-resume"})==true,
              "new_pause_tail_changes_the_successful_input_signature_and_starts_a_new_batch")
    let lateToken=late.token
    view.cancelSpeakerRefinementForResume();view.phase.phase = .recording
    try check(view.speakerRefinementToken==lateToken && view.savedCoarseJobs[cacheID]===view.speakerRefinementJob,
              "resume_keeps_frozen_pause_batch_running")
    let resumedContext=MeetingContextPublisher(directory:root.appendingPathComponent("resumed-agent-context",isDirectory:true))
    view.contextPublisher=resumedContext;view.meetingTitle="恢复中的合成会议"
    view.naming.set(segment:"known",name:"恢复后人工姓名")
    var namesSaved=false
    view.persistSessionNames { result in namesSaved = (try? result.get()) != nil }
    try wait("resumed_names_save",until:Date().addingTimeInterval(5)){namesSaved}
    // This fixture creates a real AppKit text view, but keeps presentation
    // deferred while setting up synthetic state. Resume the normal render path
    // before activating context so the restored rows (and current manual names)
    // are actually projected, as they are in the visible app.
    view.deferPresentation=false
    view.beginMeetingContext()
    try view.settleTranscriptForOfflineReview()
    resumedContext.flushForChecks()
    var resumedPublished:[String:Any]=[:]
    do {
        try wait("resume_context_name",until:Date().addingTimeInterval(5)){
            resumedPublished=(try? readPublished(resumedContext,directory:root.appendingPathComponent("resumed-agent-context"),["read","--session",session])) ?? [:]
            return (String(data:(try? JSONSerialization.data(withJSONObject:resumedPublished,options:[.sortedKeys])) ?? Data(),encoding:.utf8) ?? "").contains("恢复后人工姓名")
        }
    } catch {
        // Retain only this synthetic failing context so the QA runner can
        // distinguish a publisher/write problem from name projection or UI
        // scheduling. The enclosing fixture tree is otherwise disposable.
        resumedContext.flushForChecks()
        let debug=directory.appendingPathComponent("coarse-ui-resume-context-debug-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:debug,withIntermediateDirectories:true)
        let contextFolder=root.appendingPathComponent("resumed-agent-context",isDirectory:true)
        let namesFile=folder.appendingPathComponent("session-names.json")
        let savedNames=(try? Data(contentsOf:namesFile)).flatMap{String(data:$0,encoding:.utf8)} ?? ""
        let contextFiles=(try? FileManager.default.contentsOfDirectory(atPath:contextFolder.path)) ?? []
        if FileManager.default.fileExists(atPath:contextFolder.path) {
            try FileManager.default.copyItem(at:contextFolder,to:debug.appendingPathComponent("context",isDirectory:true))
        }
        let turns=view.readingTurns().map { turn -> [String:Any] in
            ["id":turn.id,"text":turn.item["text"] as? String ?? "","label":view.readingTurnLabel(turn),
             "parts":turn.parts.map { ["id":$0.0,"text":$0.1["text"] as? String ?? "",
                                      "name":view.naming.displayName(segment:$0.0)?.value as Any? ?? NSNull()] }]
        }
        let diagnostic:[String:Any]=[
            "error":String(describing:error),"session":session,"cache_id":cacheID,
            "active_session":view.activeSession as Any? ?? NSNull(),"current_cache_id":view.currentCacheID as Any? ?? NSNull(),
            "context_session":view.contextSession as Any? ?? NSNull(),"defer_presentation":view.deferPresentation,
            "output_exists":view.output != nil,"scroll_exists":view.scroll != nil,
            "context_folder":contextFolder.path,"context_files":contextFiles,"saved_names":savedNames,
            "manual_name":view.naming.displayName(segment:"known")?.value as Any? ?? NSNull(),
            "sentence_name":view.naming.sentenceName(segment:"known") as Any? ?? NSNull(),
            "correction_revision":view.naming.correctionRevision,
            "full_refresh_pending":view.fullTranscriptRefreshPending,"full_refresh_in_flight":view.fullRefreshBuildInFlight,
            "dirty_parent_count":view.dirtyTranscriptParents.count,"dirty_queue_remaining":max(0,view.dirtyTranscriptQueue.count-view.dirtyTranscriptQueueIndex),
            "publisher_error":resumedContext.lastError as Any? ?? NSNull(),"reader_failures":contextReaderFailures,
            "reader_script":view.root+"/meeting_context.py","turns":turns,"read":resumedPublished]
        try write(diagnostic,to:debug.appendingPathComponent("diagnostic.json"))
        throw Failure(code:"coarse_ui_resume_context_name_timeout_debug="+debug.path)
    }
    var resumedJSON=String(data:try JSONSerialization.data(withJSONObject:resumedPublished,options:[.sortedKeys]),encoding:.utf8) ?? ""
    try check(resumedJSON.contains("恢复后人工姓名") && view.speakerRefinementToken==lateToken,
              "manual_speaker_edits_and_publication_do_not_cancel_the_running_batch")
    let rawTail:[String:Any] = ["type":"segment","session":session,"source_id":"mic","track":"mic","epoch":"epoch-a",
        "segment_id":"new-tail","revision":1,"final":true,"end_time_known":true,"start":1.75,"end":1.9,
        "text":"这是继续录音后新增的一句话。","speaker":["basis":"unknown","reason":"no_speaker_evidence"],"quality_flags":[]]
    originalTranscript.append(try JSONSerialization.data(withJSONObject:rawTail,options:[.sortedKeys]));originalTranscript.append(10)
    try originalTranscript.write(to:transcript,options:.atomic)
    let afterCutoff:[String:Any] = ["type":"segment","session":session,"source_id":"mic","track":"mic","epoch":"epoch-a",
        "segment_id":"after-cutoff","revision":1,"final":true,"end_time_known":true,"start":1.96,"end":2.1,
        "text":"这句话属于下一次暂停之后。","speaker":["basis":"unknown","reason":"no_speaker_evidence"],"quality_flags":[]]
    originalTranscript.append(try JSONSerialization.data(withJSONObject:afterCutoff,options:[.sortedKeys]));originalTranscript.append(10)
    try originalTranscript.write(to:transcript,options:.atomic)
    // A second pause is queued while the original request is still running.
    // It must retain its newer cutoff even if capture resumes before the first
    // response returns.
    view.phase.elapsed=1.95;view.phase.phase = .paused
    view.scheduleCoarseRefinement(trigger:"pause",allowUnsealed:true,cutoff:1.95)
    try check(abs((view.pendingCoarseCutoffs[cacheID] ?? 0)-1.95)<0.000001,
              "second_pause_queues_its_own_audio_and_transcript_cutoff")
    view.phase.phase = .recording
    late.done(late.token,.success(try syntheticResponse(late.request)))
    resumedContext.flushForChecks()
    resumedPublished=try readPublished(resumedContext,directory:root.appendingPathComponent("resumed-agent-context"),["read","--session",session])
    resumedJSON=String(data:try JSONSerialization.data(withJSONObject:resumedPublished,options:[.sortedKeys]),encoding:.utf8) ?? ""
    try check(resumedJSON.contains("恢复后人工姓名") && !resumedJSON.contains("人工确认的顾问甲"),
              "late_resumed_result_does_not_revert_published_manual_name")
    guard let followup=takeRequest(until:Date().addingTimeInterval(5)) else{throw Failure(code:"coarse_ui_append_followup_missing")}
    let followupUnits=followup.request["units"] as? [[String:Any]] ?? []
    let followupIDs=Set(followupUnits.compactMap{$0["unit_id"] as? String})
    let followupAudio=(followup.request["audio_tracks"] as? [[String:Any]])?.first?["written_bytes"] as? Int
    try check(followupIDs.contains("new-tail") && !followupIDs.contains("after-cutoff") && followupAudio==64000,
              "queued_batch_runs_after_resume_and_excludes_text_and_pcm_beyond_its_cutoff")
    let partialProjection=try CachedMeeting(id:cacheID,directory:folder,date:Date(),writtenBytes:98304,pendingBytes:0,occupiedBytes:0,tracks:["mic"],audioCleaned:false,warning:false,retiredBytes:0).events()
    try check(partialProjection.first(where:{$0["segment_id"] as? String=="target"})?["text"] as? String=="这是已经校正的转写。" &&
              partialProjection.first(where:{$0["segment_id"] as? String=="new-tail"})?["text"] as? String=="这是继续录音后新增的一句话。",
              "late_pause_result_rebases_old_units_without_touching_appended_transcript")
    followup.done(followup.token,.success(try syntheticResponse(followup.request)))
    try wait("append_followup_commit",until:Date().addingTimeInterval(5)){view.savedCoarseJobs[cacheID]==nil && view.speakerRefinementToken==nil}
    let appendedProjection=try CachedMeeting(id:cacheID,directory:folder,date:Date(),writtenBytes:98304,pendingBytes:0,occupiedBytes:0,tracks:["mic"],audioCleaned:false,warning:false,retiredBytes:0).events()
    try check(appendedProjection.first(where:{$0["segment_id"] as? String=="target"})?["text"] as? String=="这是已经校正的转写。" &&
              appendedProjection.first(where:{$0["segment_id"] as? String=="new-tail"})?["text"] as? String=="这是继续录音后校正的新句。" &&
              appendedProjection.first(where:{$0["segment_id"] as? String=="after-cutoff"})?["text"] as? String=="这句话属于下一次暂停之后。",
              "second_pause_refines_only_the_new_snapshot_and_keeps_prior_result")
    let pcmUnchanged=try Data(contentsOf:pcmFile)==originalPCM
    let manifestUnchanged=try Data(contentsOf:manifestFile)==originalManifest
    try check(view.coarseProcessingSummary=="上一段已整理，可标记发言人" && pcmUnchanged && manifestUnchanged,
              "batch_completion_is_clear_and_original_pcm_and_manifest_remain_unchanged")
    partialArtifact=try MeetingCoarseAudioInput.object(sidecar)

    // If the old batch fails, one queued pause rebuilds its full bounded input
    // and includes the appended window without creating an unbounded retry loop.
    func appendSyntheticTail(_ id:String,_ start:Double)throws {
        let event:[String:Any] = ["type":"segment","session":session,"source_id":"mic","track":"mic","epoch":"epoch-a",
            "segment_id":id,"revision":1,"final":true,"end_time_known":true,"start":start,"end":start+0.15,
            "text":"合成的待整理句子 "+id+"。","speaker":["basis":"unknown","reason":"no_speaker_evidence"],"quality_flags":[]]
        var bytes=try Data(contentsOf:transcript)
        bytes.append(try JSONSerialization.data(withJSONObject:event,options:[.sortedKeys]));bytes.append(10)
        try bytes.write(to:transcript,options:.atomic)
    }
    try appendSyntheticTail("failure-tail",2.0)
    view.phase.elapsed=2.15;view.phase.phase = .paused
    view.scheduleCoarseRefinement(trigger:"pause",allowUnsealed:true,cutoff:2.15)
    guard let failing=takeRequest(until:Date().addingTimeInterval(5)) else{throw Failure(code:"coarse_ui_failure_fixture_missing")}
    let failingToken=failing.token
    view.cancelSpeakerRefinementForResume();view.phase.phase = .recording
    try check(view.speakerRefinementToken==failingToken,"resume_does_not_cancel_a_batch_that_may_need_recovery")
    try appendSyntheticTail("queued-tail",2.2)
    view.phase.elapsed=2.4;view.phase.phase = .paused
    view.scheduleCoarseRefinement(trigger:"pause",allowUnsealed:true,cutoff:2.4)
    view.phase.phase = .recording
    try check(view.speakerRefinementNeedsRetry,"second_pause_retains_followup_request_while_old_job_runs")
    failing.done(failing.token,.failure(Failure(code:"synthetic_failure")))
    guard let recovered=takeRequest(until:Date().addingTimeInterval(5)) else{throw Failure(code:"coarse_ui_failure_followup_missing")}
    let recoveryIDs=Set((recovered.request["units"] as? [[String:Any]] ?? []).compactMap{$0["unit_id"] as? String})
    try check(recoveryIDs.contains("failure-tail") && recoveryIDs.contains("queued-tail"),
              "queued_pause_rebuilds_failed_and_new_windows_after_resume")
    recovered.done(recovered.token,.success(try syntheticResponse(recovered.request)))
    try wait("failure_followup_commit",until:Date().addingTimeInterval(5)){view.savedCoarseJobs[cacheID]==nil && view.speakerRefinementToken==nil}

    func restoreOldMeetingInPrimaryView() {
        view.activeSession=session;view.currentCacheID=cacheID;view.phase.phase = .stopped
        view.cachedTranscriptionComplete=true;view.sessionLocalOnly=false
        view.speakerRefinementLifecycle.begin(session:session)
        view.segments=Dictionary(uniqueKeysWithValues:originalEvents.compactMap{event in
            (event["segment_id"] as? String).map{($0,event)}
        })
        view.sequence=originalEvents.compactMap{$0["segment_id"] as? String}
        view.naming.reset()
        for event in originalEvents {view.naming.register(segment:event["segment_id"] as! String,item:event)}
        view.naming.set(segment:"known",name:"人工确认的顾问甲")
    }
    restoreOldMeetingInPrimaryView()
    let contextPublisher=MeetingContextPublisher(directory:root.appendingPathComponent("agent-context",isDirectory:true))
    view.contextPublisher=contextPublisher
    view.meetingTitle="合成旧会议"
    view.beginMeetingContext()
    try view.settleTranscriptForOfflineReview()
    contextPublisher.flushForChecks()
    let contextBefore=try readPublished(contextPublisher,directory:root.appendingPathComponent("agent-context"),["read","--session",session])
    try check(contextBefore["session"] as? String==session,"background_projection_fixture_starts_from_published_old_session")
    // Require this detached request to create its own artifact; earlier phases
    // already exercised reuse of an existing coarse sidecar.
    try FileManager.default.removeItem(at:sidecar)
    view.scheduleSpeakerRefinement(trigger:"manual_retry",allowUnsealed:false)
    guard let detached=takeRequest(until:Date().addingTimeInterval(5)),
          let detachedJob=view.savedCoarseJobs[cacheID],detachedJob === view.speakerRefinementJob else {
        throw Failure(code:"coarse_ui_new_meeting_detach_fixture_missing")
    }
    func appendSwitchScopeEvent(_ id:String,start:Double,end:Double)throws {
        let event:[String:Any] = ["type":"segment","session":session,"source_id":"mic","track":"mic","epoch":"epoch-a",
            "segment_id":id,"revision":1,"final":true,"end_time_known":true,"start":start,"end":end,
            "text":"切换会议时仍属于旧会议的句子 "+id+"。","speaker":["basis":"unknown","reason":"no_speaker_evidence"],"quality_flags":[]]
        var bytes=try Data(contentsOf:transcript)
        bytes.append(try JSONSerialization.data(withJSONObject:event,options:[.sortedKeys]));bytes.append(10)
        try bytes.write(to:transcript,options:.atomic)
    }
    try appendSwitchScopeEvent("switch-queued-tail",start:2.2,end:2.3)
    try appendSwitchScopeEvent("switch-after-cutoff",start:2.45,end:2.6)
    view.phase.elapsed=2.4;view.phase.phase = .paused
    view.scheduleCoarseRefinement(trigger:"pause",allowUnsealed:true,cutoff:2.4)
    try check(abs((view.pendingCoarseCutoffs[cacheID] ?? 0)-2.4)<0.000001,
              "old_meeting_pause_cutoff_remains_queued_before_switch")
    view.phase.phase = .stopped
    view.newMeeting()
    contextPublisher.flushForChecks()
    let contextAfterSwitch=try readPublished(contextPublisher,directory:root.appendingPathComponent("agent-context"),["read","--session",session])
    try check(view.currentCacheID==nil && view.activeSession==nil && view.segments.isEmpty &&
              view.speakerRefinementToken==nil && view.speakerRefinementJob !== detachedJob &&
              view.savedCoarseJobs[cacheID] === detachedJob,
              "new_meeting_detaches_inflight_refinement_without_carrying_old_transcript")
    let transcriptBeforeDetachedResult=try Data(contentsOf:transcript)
    detached.done(detached.token,.success(try syntheticResponse(detached.request)))
    do {
        try wait("detached_result_commit",until:Date().addingTimeInterval(5)){
            FileManager.default.fileExists(atPath:sidecar.path) && view.savedCoarseJobs[cacheID] !== detachedJob
        }
    } catch {
        throw Failure(code:"coarse_ui_detached_result_commit_timeout:sidecar=\(FileManager.default.fileExists(atPath:sidecar.path));saved_job=\(view.savedCoarseJobs[cacheID] != nil);job_current=\(detachedJob.isCurrent(detached.token));failure=\(String(describing:view.speakerRefinementFailureCode));message=\(String(describing:view.speakerRefinementMessage));phase=\(view.phase.phase.rawValue)")
    }
    guard let switchedBatchJob=view.savedCoarseJobs[cacheID],switchedBatchJob !== detachedJob,
          switchedBatchJob !== view.speakerRefinementJob else {
        throw Failure(code:"coarse_ui_switched_followup_not_detached")
    }
    let detachedProjection=try CachedMeeting(id:cacheID,directory:folder,date:Date(),writtenBytes:98304,pendingBytes:0,
        occupiedBytes:0,tracks:["mic"],audioCleaned:false,warning:false,retiredBytes:0).events()
    let detachedTranscript=try Data(contentsOf:transcript)
    let detachedTarget=detachedProjection.first(where:{$0["segment_id"] as? String=="target"})
    let detachedTargetWasProjected=detachedTarget?["text"] as? String=="这是已经校正的转写。"
    let newMeetingRemainsEmpty=view.currentCacheID==nil && view.activeSession==nil && view.segments.isEmpty
    let providerTranscriptWasPreserved=detachedTranscript==transcriptBeforeDetachedResult
    guard detachedTargetWasProjected && newMeetingRemainsEmpty && providerTranscriptWasPreserved else {
        throw Failure(code:"coarse_ui_detached_result_scope_invalid:target=\(String(describing:detachedTarget?["text"]));new_meeting_empty=\(newMeetingRemainsEmpty);transcript_unchanged=\(providerTranscriptWasPreserved);before_bytes=\(transcriptBeforeDetachedResult.count);after_bytes=\(detachedTranscript.count);artifact_exists=\(FileManager.default.fileExists(atPath:sidecar.path));saved_job_present=\(view.savedCoarseJobs[cacheID] != nil);phase=\(view.phase.phase.rawValue)")
    }
    checks.append("detached_result_commits_only_to_its_original_cache_and_never_leaks_into_new_meeting")
    let published=try readPublished(contextPublisher,directory:root.appendingPathComponent("agent-context"),["read","--session",session])
    let publishedJSON=String(data:try JSONSerialization.data(withJSONObject:published,options:[.sortedKeys]),encoding:.utf8) ?? ""
    let publishedMeeting=published["meeting"] as? [String:Any] ?? [:]
    let current=try readPublished(contextPublisher,directory:root.appendingPathComponent("agent-context"),["current"])
    let contextAfterResult=String(data:try JSONSerialization.data(withJSONObject:published,options:[.sortedKeys]),encoding:.utf8) ?? ""
    let contextAtSwitch=String(data:try JSONSerialization.data(withJSONObject:contextAfterSwitch,options:[.sortedKeys]),encoding:.utf8) ?? ""
    let switchMeeting=contextAfterSwitch["meeting"] as? [String:Any] ?? [:]
    guard view.contextSession==nil && published["status"] as? String=="ok" &&
          publishedMeeting["projection_updating"] as? Bool==switchMeeting["projection_updating"] as? Bool &&
          publishedMeeting["title"] as? String=="合成旧会议" && current["status"] as? String=="no_current_meeting" &&
          !publishedJSON.contains("这是已经校正的转写。") && publishedJSON==contextAtSwitch && contextAfterResult==contextAtSwitch else {
        throw Failure(code:"coarse_ui_detached_context_projection_invalid:context=\(String(describing:view.contextSession));status=\(String(describing:published["status"]));title=\(String(describing:publishedMeeting["title"]));updating=\(String(describing:publishedMeeting["projection_updating"]));current=\(String(describing:current["status"]))")
    }
    checks.append("detached_projection_commits_only_to_saved_sidecar_without_rewriting_old_context")
    checks.append("new_meeting_keeps_authorized_background_result_scoped_to_old_session")

    guard let switchedFollowup=takeRequest(until:Date().addingTimeInterval(5)) else {
        throw Failure(code:"coarse_ui_switched_followup_missing")
    }
    let switchedUnits=switchedFollowup.request["units"] as? [[String:Any]] ?? []
    let switchedIDs=Set(switchedUnits.compactMap{$0["unit_id"] as? String})
    try check(switchedIDs.contains("switch-queued-tail") && !switchedIDs.contains("switch-after-cutoff") &&
              switchedFollowup.token != view.speakerRefinementToken && view.currentCacheID==nil && view.activeSession==nil,
              "queued_old_batch_restarts_after_new_meeting_without_crossing_cutoff_or_claiming_new_ui")
    switchedFollowup.done(switchedFollowup.token,.success(try syntheticResponse(switchedFollowup.request)))
    try wait("switched_followup_commit",until:Date().addingTimeInterval(5)){
        view.savedCoarseJobs[cacheID]==nil && view.currentCacheID==nil && view.speakerRefinementToken==nil
    }
    let switchedArtifact=try MeetingCoarseAudioInput.object(sidecar)
    let switchedRecords=switchedArtifact["records"] as? [[String:Any]] ?? []
    let switchedRecordIDs=Set(switchedRecords.compactMap{$0["unit_id"] as? String})
    try check(switchedRecordIDs.contains("switch-queued-tail") && !switchedRecordIDs.contains("switch-after-cutoff") &&
              view.currentCacheID==nil && view.activeSession==nil && view.segments.isEmpty,
              "switched_followup_commits_only_to_old_cache_and_leaves_new_meeting_untouched")
    checks.append("queued_old_meeting_cutoff_survives_new_meeting_and_finishes_in_its_saved_scope")

    try FileManager.default.removeItem(at:sidecar)
    restoreOldMeetingInPrimaryView()
    view.scheduleSpeakerRefinement(trigger:"manual_retry",allowUnsealed:false)
    guard let background=takeRequest(until:Date().addingTimeInterval(5)),
          let backgroundJob=view.savedCoarseJobs[cacheID] else {
        throw Failure(code:"coarse_ui_background_stop_fixture_missing")
    }
    view.newMeeting()
    let history=Delegate();history.previewRenderOnly=true;history.deferPresentation=true
    history.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    history.recoveryRootOverride=root;history.isHistoryReader=true;history.workspaceOwner=view
    history.currentCacheID=cacheID;history.activeSession=session;history.phase.phase = .stopped
    history.cachedTranscriptionComplete=true;history.sessionLocalOnly=false
    try check(history.hasRunningCoarseRefinement && !history.canRetrySpeakerRefinement,
              "selected_history_exposes_stop_without_offering_duplicate_retry")
    let preference=folder.appendingPathComponent("coarse-refinement-preference.json")
    let preferenceBefore=try Data(contentsOf:preference)
    history.toggleCoarseProjection()
    try check(try Data(contentsOf:preference)==preferenceBefore,
              "running_background_job_blocks_original_projection_toggle")
    try check(clickSpeakerReviewStopForChecks(owner:history),"selected_history_stop_control_is_enabled_and_labeled_for_background_job")
    try check(view.savedCoarseJobs[cacheID]==nil && !backgroundJob.isCurrent(background.token),
              "selected_history_stop_cancels_detached_refinement_job")
    let transcriptBeforeCancelledResult=try Data(contentsOf:transcript)
    background.done(background.token,.success(try syntheticResponse(background.request)))
    RunLoop.main.run(until:Date().addingTimeInterval(0.2))
    let cancelledTranscript=try Data(contentsOf:transcript)
    try check(!FileManager.default.fileExists(atPath:sidecar.path) && view.currentCacheID==nil && view.segments.isEmpty &&
              cancelledTranscript==transcriptBeforeCancelledResult,
              "cancelled_background_result_cannot_commit_or_change_new_meeting")
    checks.append("historical_stop_cancels_only_selected_background_job_and_rejects_late_response")

    // A background result must refresh the history reader's visible completion
    // receipt as well as its transcript projection.
    let completionReader=Delegate();completionReader.previewRenderOnly=true;completionReader.deferPresentation=false
    completionReader.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    completionReader.recoveryRootOverride=root;completionReader.isHistoryReader=true;completionReader.workspaceOwner=view
    try completionReader.applyRecovery(fixtureItem,payload:RecoveryPayload(fixtureItem));view.historyReader=completionReader
    restoreOldMeetingInPrimaryView()
    view.scheduleSpeakerRefinement(trigger:"manual_retry",allowUnsealed:false)
    guard let historyCompletion=takeRequest(until:Date().addingTimeInterval(5)) else{throw Failure(code:"coarse_ui_history_completion_fixture_missing")}
    view.newMeeting()
    historyCompletion.done(historyCompletion.token,.success(try syntheticResponse(historyCompletion.request)))
    try wait("history_completion_refresh",until:Date().addingTimeInterval(5)){
        completionReader.coarseProcessingSummary=="上一段已整理，可标记发言人" &&
        completionReader.segments["target"]?["text"] as? String=="这是已经校正的转写。"
    }
    try check(completionReader.coarseProcessingProgress==nil && completionReader.coarseProgressTimer==nil &&
              completionReader.coarseProcessingSummary=="上一段已整理，可标记发言人" && completionReader.hasCoarseResult,
              "detached_commit_refreshes_history_projection_and_finished_status")

    try appendSyntheticTail("history-partial",2.7)
    restoreOldMeetingInPrimaryView()
    view.phase.elapsed=3.0;view.scheduleSpeakerRefinement(trigger:"pause",allowUnsealed:true)
    guard let historyPartial=takeRequest(until:Date().addingTimeInterval(5)) else{throw Failure(code:"coarse_ui_history_partial_fixture_missing")}
    view.newMeeting()
    historyPartial.done(historyPartial.token,.success(try syntheticResponse(historyPartial.request,warning:"semantic_assignment_incomplete")))
    try wait("history_partial_refresh",until:Date().addingTimeInterval(5)){
        completionReader.coarseProcessingSummary=="部分内容已整理，其余可重试；原文保留"
    }
    try check(completionReader.coarseProcessingProgress==nil &&
              completionReader.coarseProcessingSummary=="部分内容已整理，其余可重试；原文保留" &&
              completionReader.coarseProcessingSummary != "上一段已整理，可标记发言人",
              "detached_partial_commit_never_claims_full_completion")
    view.historyReader=nil;completionReader.window.orderOut(nil)

    partialArtifact["warning"]="semantic_assignment_incomplete"
    try write(partialArtifact,to:sidecar)
    try view.writeCoarsePreference(directory:folder,session:session,enabled:true)
    try view.applyRecovery(fixtureItem,payload:RecoveryPayload(fixtureItem))
    try check(view.speakerRefinementMessage=="文字已整理，部分发言人未整理完，可重试","partial_refinement_warning_is_visible_after_history_reopen")
    partialArtifact.removeValue(forKey:"warning")
    try write(partialArtifact,to:sidecar)
    try view.applyRecovery(fixtureItem,payload:RecoveryPayload(fixtureItem))
    try check(view.speakerRefinementMessage==nil,"opening_complete_history_clears_previous_partial_warning")
    let previousCache=UUID().uuidString,previousJob=view.speakerRefinementJob
    let previousToken=previousJob.reserve()
    view.currentCacheID=previousCache
    view.speakerRefinementScope=(previousCache,session,view.meetingDocumentGeneration,view.naming.correctionRevision)
    view.speakerRefinementToken=previousToken;view.savedCoarseJobs[previousCache]=previousJob
    try view.applyRecovery(fixtureItem,payload:RecoveryPayload(fixtureItem))
    try check(previousJob.isCurrent(previousToken) && view.savedCoarseJobs[previousCache] === previousJob &&
              view.speakerRefinementJob !== previousJob && view.speakerRefinementToken==nil,
              "recovering_another_meeting_keeps_prior_cleanup_worker_and_token_alive")
    view.cancelSpeakerRefinement(cacheID:previousCache)
    view.coarseRefinementExecutorOverride=nil;view.window.orderOut(nil)
    return checks
}
