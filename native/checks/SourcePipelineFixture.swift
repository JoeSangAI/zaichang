import Foundation

func sourcePipelineFixture(directory:URL) async throws->[String:Any] {
    // Keep this run independent of historical synthetic sessions, while the
    // command entry point continues to enforce its fixed offline-only root.
    let directory=directory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    var checks=processAudioSourceSyntheticChecks()+sourceCaptureSessionSyntheticChecks()
    guard checks.isEmpty else {throw Failure(code:checks.joined(separator:","))}
    let clock=CaptureBudgetClock();let box=Mailbox(captureClock:clock)
    box.put(Data([1,0]),at:100);clock.pause(at:105)
    precondition(clock.elapsed(200)==5);box.put(Data([2,0]),at:150)
    clock.resume(at:205);box.put(Data([3,0]),at:206)
    precondition(clock.elapsed(207)==7)
    let first=try box.take();let second=try box.take();let third=try box.take()
    precondition(first?.1==100 && second?.1==106 && third==nil)
    checks.append("paused_hardware_time_excluded_without_new_origin")
    let budget=SessionUploadBudget(maxSeconds:0.2)
    precondition(budget.reserve(3200) && budget.reserve(3200) && !budget.reserve(2) && budget.usedBytes==6400)
    checks.append("multiple_sources_and_retry_share_upload_ceiling")
    let bundle="com.tencent.meeting";let track=applicationAudioSourceID(bundle)
    precondition(isTranscriptAudioTrack(track) && !isTranscriptAudioTrack("mic-raw") && !isTranscriptAudioTrack("reference"))
    for invalid in ["../mic","app-ABCDEF0123456789","app-abc",track+"\n","",
                    track+"-g0",track+"-g01",track+"-g1000",track+"-g1/../mic",
                    "remote-g0","remote-g01","remote-g1000","remote-g1/../mic"] {
        precondition(!isMeetingAudioTrack(invalid))
    }
    checks.append("only_safe_source_filenames_admitted")
    precondition(audioSourceLabel(["source_id":track,"bundle_id":bundle,"application_name":"腾讯会议"])=="腾讯会议")
    precondition(audioSourceLabel(["source_id":track,"bundle_id":"wrong.app","application_name":"腾讯会议"])=="电脑声音")
    checks.append("application_label_requires_matching_source_identity")
    let id=UUID().uuidString;let cache=directory.appendingPathComponent(id)
    let store=try RecordingJournal(directory:cache,track:track,freeSpace:{1_000_000_000},alignCaptureTime:true)
    let frame=Data(repeating:7,count:3200)
    try store.enqueue(frame,at:100);try store.enqueue(frame,at:100.1);try store.enqueue(frame,at:100.6);store.finish();store.wait()
    precondition(store.bytes()==22400 && store.isEnded());var cursor=0;var result=Data()
    while let (pcm,stamp)=try store.read(cursor) {precondition(abs(stamp-(100+Double(cursor)/32000))<1e-7);result.append(pcm);cursor+=pcm.count}
    precondition(result==frame+frame+Data(repeating:0,count:12800)+frame)
    checks.append("returning_application_preserves_timeline_position")
    let raw=try RecordingJournal(directory:cache,track:"mic-raw",freeSpace:{1_000_000_000})
    let reference=try RecordingJournal(directory:cache,track:"reference",freeSpace:{1_000_000_000})
    try raw.enqueue(frame,at:100);try reference.enqueue(frame,at:100);raw.finish();reference.finish();raw.wait();reference.wait()
    let event:[String:Any]=["type":"segment","session":"source-fixture","segment_id":"s","track":track,"source_id":track,"bundle_id":bundle,"application_name":"腾讯会议","epoch":"e","revision":1,"start":0.6,"end":0.7,"end_time_known":true,"text":"来源原文完整。","final":true,"speaker":["basis":"anonymous_cluster","cluster_id":0,"source_id":track,"epoch":"e"]]
    store.record(event);store.commitAfterTranscript(store.bytes());store.wait()
    let metadata:[String:Any]=["session":"source-fixture","bundle":"*system*","asr_model":"qwen-audio-3.0-asr-flash-streaming","created_at":Date().timeIntervalSince1970,"recording_elapsed_seconds":4.7,"audio_sources":[["source_id":track,"bundle_id":bundle,"application_name":"腾讯会议"]]]
    try JSONSerialization.data(withJSONObject:metadata).write(to:cache.appendingPathComponent("meeting.json"))
    let cached=try cachedMeetings(in:directory).first{$0.id==id}!
    precondition(cached.tracks==[track] && cached.pendingBytes==0 && cached.writtenBytes==22400 && cached.durationSeconds==4.7)
    let events=try cached.events();precondition(events.count==1 && events[0]["application_name"] as? String=="腾讯会议" && events[0]["text"] as? String=="来源原文完整。")
    let allTracks=try meetingAudioTracks(in:cache,transcriptOnly:false)
    precondition(allTracks.count==3)
    checks.append("history_keeps_app_metadata_and_excludes_raw_reference_from_asr")
    // A Core Audio callback can fail after PCM has already entered its journal.
    // Recovery must replace only that writer; queued PCM, clock and consumers
    // remain attached to the original journal and session.
    let recoveryCache=directory.appendingPathComponent(UUID().uuidString)
    let recoveryClock=CaptureBudgetClock();let recoveryState=CaptureRunState()
    let appStore=try RecordingJournal(directory:recoveryCache,track:track,freeSpace:{1_000_000_000},alignCaptureTime:true)
    let otherTrack=applicationAudioSourceID("com.example.other")
    let otherStore=try RecordingJournal(directory:recoveryCache,track:otherTrack,freeSpace:{1_000_000_000},alignCaptureTime:true)
    let micStore=try RecordingJournal(directory:recoveryCache,track:"mic-raw",freeSpace:{1_000_000_000},alignCaptureTime:true)
    let refStore=try RecordingJournal(directory:recoveryCache,track:"reference",freeSpace:{1_000_000_000},alignCaptureTime:true)
    var appWriter=Mailbox(captureClock:recoveryClock,totalByteLimit:6_400,journal:appStore)
    let otherWriter=Mailbox(captureClock:recoveryClock,journal:otherStore)
    let micWriter=Mailbox(captureClock:recoveryClock,journal:micStore)
    var refWriter=Mailbox(captureClock:recoveryClock,journal:refStore)
    let oldPCM=Data(repeating:0x11,count:3_200)
    let newPCM=Data(repeating:0x22,count:3_200)
    appWriter.put(oldPCM,at:100);otherWriter.put(oldPCM,at:100);micWriter.put(oldPCM,at:100)
    refWriter.put(oldPCM,at:100)
    let oldWriter=appWriter
    appWriter.fail("app_tap_conversion");refWriter.fail("tap_conversion")
    precondition(renewOptionalCaptureWriter(&appWriter)=="app_tap_conversion")
    precondition(renewOptionalCaptureWriter(&refWriter)=="tap_conversion")
    precondition(oldWriter !== appWriter && appWriter.journal === appStore && refWriter.journal === refStore)
    precondition(recoveryState.snapshot().2 == nil && recoveryClock.origin()==100)
    recoveryClock.pause(at:100.2)
    appWriter.put(Data(repeating:0x33,count:3_200),at:105)
    recoveryClock.resume(at:110.2)
    appWriter.put(newPCM,at:110.3);otherWriter.put(newPCM,at:110.3)
    micWriter.put(newPCM,at:110.3);refWriter.put(newPCM,at:110.3)
    appWriter.put(Data(repeating:0x44,count:3_200),at:110.4)
    for writer in [appWriter,otherWriter,micWriter,refWriter] {try writer.checkFault();writer.seal()}
    for journal in [appStore,otherStore,micStore,refStore] {journal.wait();precondition(journal.fault()==nil)}
    precondition(appWriter.totalBytes==6_400 && appWriter.boundaryTrimmedBytes==3_200)
    precondition(abs(recoveryClock.elapsed(110.4)-0.4)<0.0001)
    var recovered=Data();var recoveryCursor=0
    while let (pcm,_) = try appStore.read(recoveryCursor) {recovered.append(pcm);recoveryCursor+=pcm.count}
    precondition(recovered==oldPCM+Data(repeating:0,count:6_400)+newPCM)
    precondition(otherStore.bytes()==12_800 && micStore.bytes()==12_800 && refStore.bytes()==12_800)
    precondition(isTranscriptAudioTrack(track) && isTranscriptAudioTrack(otherTrack) &&
                 !isTranscriptAudioTrack("mic-raw") && !isTranscriptAudioTrack("reference"))
    precondition(recoveryState.snapshot().2==nil)
    checks.append("single_tap_failure_preserves_queued_pcm_and_recovers_same_session")
    checks.append("reference_failure_recovers_without_cloud_lane_or_clock_reset")
    let brokenStore=try RecordingJournal(directory:recoveryCache,track:"remote",freeSpace:{1_000_000_000})
    var brokenWriter=Mailbox(journal:brokenStore)
    brokenWriter.fail("app_tap_conversion");brokenStore.setError("cache_disk_space_low")
    precondition(renewOptionalCaptureWriter(&brokenWriter)==nil && brokenWriter.captureCallbackError() != nil)
    checks.append("permanent_journal_fault_is_not_recovered_as_tap_fault")
    let generationCache=directory.appendingPathComponent(UUID().uuidString)
    let generationClock=CaptureBudgetClock();let generationState=CaptureRunState()
    let generations=AudioTrackGenerations()
    let firstTrack=try generations.open(track)
    let firstStore=try RecordingJournal(directory:generationCache,track:firstTrack,freeSpace:{1_000_000_000},alignCaptureTime:true)
    let firstWriter=Mailbox(captureClock:generationClock,journal:firstStore)
    let oneSecond=Data(repeating:0x25,count:32_000)
    firstWriter.put(oneSecond,at:500)
    let resumedTrack=try generations.open(track) // route restart during a pause keeps this generation
    precondition(resumedTrack==firstTrack)
    firstWriter.fail("app_tap_conversion");firstWriter.seal()
    precondition(generations.retire(track)==firstTrack)
    let secondTrack=try generations.open(track)
    let secondStore=try RecordingJournal(directory:generationCache,track:secondTrack,freeSpace:{1_000_000_000},alignCaptureTime:true)
    let secondWriter=Mailbox(captureClock:generationClock,journal:secondStore)
    secondWriter.put(oneSecond,at:4_101);secondWriter.seal()
    firstStore.wait();secondStore.wait()
    precondition(firstTrack != secondTrack && firstStore.bytes()==32_000 && secondStore.bytes()==32_000)
    var firstAudio=Data();var firstCursor=0
    while let (packet,_) = try firstStore.read(firstCursor) {firstAudio.append(packet);firstCursor+=packet.count}
    precondition(firstAudio==oneSecond && firstStore.fault()==nil)
    precondition(firstTrack==track+"-g1" && secondTrack==track+"-g2" &&
                 isTranscriptAudioTrack(firstTrack) && isTranscriptAudioTrack(secondTrack))
    precondition(firstStore.firstOrigin()==500 && secondStore.firstOrigin()==4_101 && generationClock.origin()==500)
    let exactUpload=SessionUploadBudget(maxSeconds:2)
    precondition(exactUpload.reserve(firstStore.bytes()) && exactUpload.reserve(secondStore.bytes()) &&
                 exactUpload.usedBytes==64_000 && generationState.snapshot().2==nil)
    let sourceRows:[[String:Any]]=[firstTrack,secondTrack].map {
        ["source_id":$0,"core_source_id":track,"bundle_id":bundle,"application_name":"腾讯会议"]
    }
    for (index,pair) in [(firstTrack,firstStore),(secondTrack,secondStore)].enumerated() {
        let offset=(pair.1.firstOrigin() ?? 500)-500
        pair.1.record(["type":"segment","session":"generation-fixture","segment_id":"g\(index)",
                       "track":pair.0,"source_id":pair.0,"bundle_id":bundle,"application_name":"腾讯会议",
                       "epoch":"e\(index)","revision":1,"start":offset,"end":offset+1,
                       "end_time_known":true,"text":index==0 ? "第一段。":"一小时后。","final":true])
        pair.1.wait()
    }
    let generationMetadata:[String:Any]=["session":"generation-fixture","bundle":"*system*",
        "asr_model":"qwen-audio-3.0-asr-flash-streaming","created_at":Date().timeIntervalSince1970,
        "capture_origin_uptime":500,"audio_sources":sourceRows]
    try JSONSerialization.data(withJSONObject:generationMetadata).write(to:generationCache.appendingPathComponent("meeting.json"))
    let generationMeeting=try cachedMeetings(in:directory).first{$0.id==generationCache.lastPathComponent}!
    let generationEvents=try generationMeeting.events()
    precondition(generationMeeting.tracks==[firstTrack,secondTrack] && generationMeeting.writtenBytes==64_000)
    precondition(generationMeeting.durationSeconds==3_602)
    precondition(generationEvents.count==2 && (generationEvents[0]["start"] as? Double)==0 &&
                 (generationEvents[1]["start"] as? Double)==3_601)
    precondition(sourceRows.allSatisfy{audioSourceLabel($0)=="腾讯会议"})
    checks.append("one_hour_app_absence_uploads_only_two_seconds_in_one_meeting")
    checks.append("generation_tracks_preserve_absolute_text_time_and_history_app_label")
    // Only the pending generation is replayed, with the original meeting time
    // base and a shared ceiling; completed generations create no ASR socket.
    try firstStore.commit("asr",cursor:firstStore.bytes());firstStore.wait()
    var replayConfig=Config(session:"generation-fixture",bundle:"*system*",key:"",confirmed:true,maxSeconds:1,
        model:"qwen-audio-3.0-asr-flash-streaming",silenceMS:1300,micEnabled:true,
        localSpeakerDirectory:nil,localEmbeddingModel:nil,userLaunchConfirmed:nil)
    replayConfig.remainingUploadSeconds=1
    let replaySockets=NetworkFixtureState()
    try await resumeCachedMeeting(config:replayConfig,id:generationCache.lastPathComponent,base:directory,
        factory:{_ = replaySockets.connection();return FixtureSocket(fail:false)},retryDelay:0.001)
    let replayedMeeting=try cachedMeetings(in:directory).first{$0.id==generationCache.lastPathComponent}!
    let replayedEvents=try replayedMeeting.events()
    precondition(replaySockets.connections()==1 && replayedMeeting.pendingBytes==0 &&
        replayedEvents.contains{($0["track"] as? String)==secondTrack && ($0["start"] as? Double)==3_601 &&
            ($0["text"] as? String)=="离线协议占位文本"})
    interrupted=0
    checks.append("resume_skips_completed_generations_and_preserves_original_meeting_clock")
    try secondStore.commit("asr",cursor:secondStore.bytes());secondStore.wait()
    // Reload after the replay because its consumer persisted the commit.
    let retirement=directory.appendingPathComponent("retired-generation-audio-"+UUID().uuidString)
    let retiredGeneration=try archiveAndCleanSessionAt(generationCache,text:"完整代际原文",retire:{stage in
        try FileManager.default.moveItem(at:stage,to:retirement);return retirement})
    precondition(retiredGeneration)
    let retiredFiles=try FileManager.default.contentsOfDirectory(atPath:retirement.path)
    precondition(Set(retiredFiles)==Set([firstTrack+"-000000.pcm",secondTrack+"-000000.pcm"]))
    checks.append("generation_audio_retirement_retains_all_chunk_files_recoverably")
    let sharedCache=directory.appendingPathComponent(UUID().uuidString)
    let sharedTracks=["remote-g1","remote-g2"]
    for name in sharedTracks {
        let store=try RecordingJournal(directory:sharedCache,track:name,freeSpace:{1_000_000_000})
        try store.enqueue(oneSecond,at:500);store.finish();store.wait()
    }
    try JSONSerialization.data(withJSONObject:["session":"generation-fixture","bundle":"*system*",
        "capture_origin_uptime":500]).write(to:sharedCache.appendingPathComponent("meeting.json"))
    try await resumeCachedMeeting(config:replayConfig,id:sharedCache.lastPathComponent,base:directory,
        factory:{FixtureSocket(fail:false)},retryDelay:0.001)
    let limitedMeeting=try cachedMeetings(in:directory).first{$0.id==sharedCache.lastPathComponent}!
    precondition(limitedMeeting.writtenBytes==64_000 && limitedMeeting.pendingBytes>0 &&
        sharedTracks.allSatisfy{FileManager.default.fileExists(atPath:sharedCache.appendingPathComponent($0+"-000000.pcm").path)})
    interrupted=0
    checks.append("resume_generations_share_remaining_upload_ceiling_and_retain_pending_audio")
    let unknownCache=directory.appendingPathComponent(UUID().uuidString)
    let unknownGenerations=AudioTrackGenerations()
    let unknownFirst=try unknownGenerations.open("remote")
    let unknownOld=try RecordingJournal(directory:unknownCache,track:unknownFirst,freeSpace:{1_000_000_000},alignCaptureTime:true)
    let unknownOldWriter=Mailbox(journal:unknownOld)
    unknownOldWriter.put(frame,at:100);unknownOldWriter.seal()
    precondition(unknownGenerations.retire("remote")==unknownFirst)
    let unknownSecond=try unknownGenerations.open("remote")
    let unknownNew=try RecordingJournal(directory:unknownCache,track:unknownSecond,freeSpace:{1_000_000_000},alignCaptureTime:true)
    let unknownNewWriter=Mailbox(journal:unknownNew)
    unknownNewWriter.put(frame,at:3_700.1);unknownNewWriter.seal()
    unknownOld.wait();unknownNew.wait()
    precondition(unknownFirst=="remote-g1" && unknownSecond=="remote-g2" &&
                 isTranscriptAudioTrack(unknownFirst) && isTranscriptAudioTrack(unknownSecond) &&
                 unknownOld.bytes()==3_200 && unknownNew.bytes()==3_200)
    precondition(audioSourceLabel(["source_id":unknownFirst,"application_name":"其他电脑声音"])=="电脑声音" &&
                 audioSourceLabel(["source_id":unknownSecond,"application_name":"其他电脑声音"])=="电脑声音")
    checks.append("unknown_computer_source_generations_do_not_pad_one_hour_gap")
    return ["type":"source_pipeline_checks","passed":checks.count,"checks":checks,"capture":false,"cloud":false,"keychain":false]
}
