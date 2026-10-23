import Foundation
import CryptoKit

/// Read-only diagnostic for a real SessionCache entry. This intentionally
/// skips recovery and returns counts/hashes only: it never writes the meeting,
/// invokes a model, touches credentials, or captures audio.
func meetingCoarseRefinementReadOnlyPrepare(cacheID:String,
                                            root:URL=meetingCacheRoot())throws->[String:Any] {
    guard UUID(uuidString:cacheID) != nil else{return ["ok":false,"stage":"scope","code":"invalid_cache_id"]}
    let meeting:CachedMeeting
    do {
        guard let found=try cachedMeetings(in:root,recoverInterrupted:false).first(where:{$0.id==cacheID}) else {
            return ["ok":false,"stage":"lookup","code":"meeting_not_found"]
        }
        meeting=found
    } catch {return ["ok":false,"stage":"lookup","code":"cache_listing_failed"]}
    let metadata:[String:Any]
    do {metadata=try meeting.metadata()}
    catch {return ["ok":false,"stage":"metadata","code":"meeting_metadata_read_failed"]}
    guard let session=metadata["session"] as? String,!session.isEmpty else {
        return ["ok":false,"stage":"metadata","code":"session_missing"]
    }
    let events:[[String:Any]]
    do {events=try meeting.events(includeAutomaticRefinement:false,includeCoarseRefinement:false)}
    catch {return ["ok":false,"stage":"events","code":"transcript_projection_failed"]}
    let hashes:[String:String]
    do {hashes=try meeting.transcriptHashes()}
    catch {return ["ok":false,"stage":"transcript_hashes","code":"transcript_hash_failed"]}
    let mismatched=events.filter{$0["session"] as? String != session}.count
    guard !events.isEmpty,mismatched==0 else {
        return ["ok":false,"stage":"event_snapshot","code":events.isEmpty ? "empty_events":"session_mismatch",
                "event_count":events.count,"mismatched_session_events":mismatched]
    }
    let speakerSnapshot:String
    do {speakerSnapshot=try SpeakerRefinementArtifact.snapshotSHA256(directory:meeting.directory,cacheID:cacheID,sourceHashes:hashes)}
    catch let error as SpeakerRefinementArtifactError {
        let code:String
        switch error {
        case .invalidSnapshot:code="invalid_snapshot"
        case .invalidScope:code="invalid_scope"
        case .invalidPath:code="invalid_path"
        case .invalidArtifact:code="invalid_artifact"
        case .sourceChanged:code="source_changed"
        case .eventChanged:code="event_changed"
        case .unsupportedSpeakerChange:code="unsupported_speaker_change"
        case .unknownSlot:code="unknown_slot"
        case .fileTooLarge:code="file_too_large"
        }
        return ["ok":false,"stage":"speaker_snapshot","code":code,"event_count":events.count,
                "transcript_source_count":hashes.count,"writes":false,"cloud":false,"capture":false]
    } catch {return ["ok":false,"stage":"speaker_snapshot","code":"speaker_snapshot_failed",
                    "event_count":events.count,"transcript_source_count":hashes.count,
                    "writes":false,"cloud":false,"capture":false]}
    do {
        let payload=try MeetingCoarseRefinement.prepareRequest(directory:meeting.directory,session:session,
            cacheID:cacheID,events:events,transcriptHashes:hashes)
        return ["ok":true,"stage":"prepared","cache_id":cacheID,"session":session,
                "track_count":meeting.tracks.count,"transcript_source_count":hashes.count,
                "event_count":events.count,"unit_count":payload.units.count,
                "source_sha256":payload.source_sha256,"snapshot_sha256":payload.snapshot_sha256,
                "speaker_snapshot_sha256":speakerSnapshot,
                "writes":false,"cloud":false,"capture":false]
    } catch let error as MeetingCoarseRefinementError {
        let code:String
        switch error {
        case .invalidScope:code="invalid_scope"
        case .invalidArtifact:code="invalid_artifact"
        case .sourceChanged:code="source_changed"
        case .snapshotChanged:code="invalid_snapshot"
        case .eventChanged:code="event_changed"
        case .unknownSpeaker:code="unknown_speaker"
        case .invalidLayout:code="invalid_layout"
        case .fileTooLarge:code="file_too_large"
        }
        return ["ok":false,"stage":"prepare_request","code":code,"event_count":events.count,
                "transcript_source_count":hashes.count,"writes":false,"cloud":false,"capture":false]
    } catch let error as Failure {
        return ["ok":false,"stage":"prepare_request","code":error.code,
                "error_type":"Failure","event_count":events.count,
                "transcript_source_count":hashes.count,"writes":false,"cloud":false,"capture":false]
    } catch let error as SpeakerRefinementArtifactError {
        return ["ok":false,"stage":"prepare_request","code":"speaker_"+String(describing:error),
                "error_type":"SpeakerRefinementArtifactError","event_count":events.count,
                "transcript_source_count":hashes.count,"writes":false,"cloud":false,"capture":false]
    } catch {
        let nsError=error as NSError
        let safeDomain=[NSCocoaErrorDomain,NSPOSIXErrorDomain,"NSOSStatusErrorDomain"].contains(nsError.domain) ? nsError.domain:"other"
        return ["ok":false,"stage":"prepare_request","code":"request_preparation_failed",
                "error_type":String(reflecting:type(of:error)),"error_domain":safeDomain,"error_code":nsError.code,
                "event_count":events.count,"transcript_source_count":hashes.count,
                "writes":false,"cloud":false,"capture":false]
    }
}

func meetingCoarseRefinementChecks(directory:URL)->[String] {
    func fail(_ message:String)->Never {preconditionFailure("coarse refinement check failed: \(message)")}
    func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    func textHash(_ text:String)->String {hash(Data(text.utf8))}
    func key(_ slot:Int)->SessionSpeakerKey {SessionSpeakerKey(session:"fixture-session",source:"mic",epoch:"epoch-1",identity:"slot:\(slot)")}
    func speaker(_ slot:Int)->[String:Any] {["basis":"anonymous_cluster","cluster_id":slot,"source_id":"mic","epoch":"epoch-1"]}
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("coarse-check-\(UUID().uuidString)",isDirectory:true)
    let cacheID=UUID().uuidString.uppercased(),cache=root.appendingPathComponent(cacheID,isDirectory:true)
    do {try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)} catch {fail("fixture cache")}
    defer {try? FileManager.default.removeItem(at:root)}

    let anchorText="小小章说明。"
    let cleanAnchorText="小张说明。"
    let events:[[String:Any]]=[
        ["session":"fixture-session","segment_id":"plain","source_id":"mic","track":"mic","epoch":"epoch-1","start":100.0,"end":102.0,"end_time_known":true,"final":true,"text":"原始文字需要纠正。","speaker":["basis":"unknown"],"word_spans":[["start":100.0,"end":102.0,"text":"原始文字需要纠正。"]]],
        ["session":"fixture-session","segment_id":"runs","source_id":"mic","track":"mic","epoch":"epoch-1","start":110.0,"end":112.0,"end_time_known":true,"final":true,"text":"待改内容。\(anchorText)","speaker":["basis":"unknown"],"speaker_runs":[
            ["start":110.0,"end":111.0,"text":"待改内容。","speaker":["basis":"unknown"]],
            ["start":111.0,"end":112.0,"text":anchorText,"speaker":speaker(0)]],
          "word_spans":[["start":110.0,"end":111.0,"text":"待改内容。"],["start":111.0,"end":112.0,"text":anchorText]]],
        ["session":"fixture-session","segment_id":"roster0","source_id":"mic","track":"mic","epoch":"epoch-1","start":120.0,"end":121.0,"end_time_known":true,"final":true,"text":"张三发言。","speaker":speaker(0)],
        ["session":"fixture-session","segment_id":"roster1","source_id":"mic","track":"mic","epoch":"epoch-1","start":121.2,"end":121.8,"end_time_known":true,"final":true,"text":"另一个人发言。","speaker":speaker(1)],
        ["session":"fixture-session","segment_id":"tail","source_id":"mic","track":"mic","epoch":"epoch-1","start":122.0,"end_time_known":false,"final":false,"text":"尾部短句需要识别。","speaker":["basis":"unknown"]],
        ["session":"fixture-session","segment_id":"missing-epoch-final","source_id":"mic","track":"mic","start":123.0,"end":124.0,"end_time_known":true,"final":true,"text":"缺少epoch的可靠终句。","speaker":["basis":"unknown"]],
        ["session":"fixture-session","segment_id":"missing-epoch-tail","source_id":"mic","track":"mic","start":124.0,"end_time_known":false,"final":false,"text":"缺少epoch的尾句。","speaker":["basis":"unknown"]],
        ["session":"fixture-session","segment_id":"whole-parent","source_id":"mic","track":"mic","epoch":"epoch-1","start":130.0,"end":132.0,"end_time_known":true,"final":true,"text":"整句人工标注。保留两段。","speaker":["basis":"unknown"],"speaker_runs":[
            ["start":130.0,"end":131.0,"text":"整句人工标注。","speaker":["basis":"unknown"]],
            ["start":131.0,"end":132.0,"text":"保留两段。","speaker":["basis":"unknown"]]],
          "word_spans":[["start":130.0,"end":131.0,"text":"整句人工标注。"],["start":131.0,"end":132.0,"text":"保留两段。"]]],
        ["session":"fixture-session","segment_id":"blank-run-parent","source_id":"mic","track":"mic","epoch":"epoch-1","start":140.0,"end":143.0,"end_time_known":true,"final":true,"text":"前文。 后文。","speaker":["basis":"unknown"],"speaker_runs":[
            ["start":140.0,"end":141.0,"text":"前文。","speaker":["basis":"unknown"]],
            ["start":141.0,"end":142.0,"text":" ","speaker":["basis":"unknown"]],
            ["start":142.0,"end":143.0,"text":"后文。","speaker":["basis":"unknown"]]],
          "word_spans":[["start":140.0,"end":141.0,"text":"前文。"],["start":141.0,"end":142.0,"text":" "],["start":142.0,"end":143.0,"text":"后文。"]]],
        ["session":"fixture-session","segment_id":"short-word","source_id":"mic","track":"mic","epoch":"epoch-1","start":144.0,"end":144.5,"end_time_known":true,"final":true,"text":"嗯","speaker":["basis":"unknown"]]
    ]

    // Real meetings persist microphone/source diagnostics in meeting.json;
    // the current user cache is 25 KB; coarse preparation must accept it.
    let metadata:[String:Any]=["schema":1,"session":"fixture-session","capture_origin_uptime":100.0,
                              "diagnostic_fixture_padding":String(repeating:"x",count:18_000)]
    let manifest:[String:Any]=["schema":1,"track":"mic","format":"pcm_s16le","sample_rate":16000,"channels":1,
                               "ended":true,"origin_uptime":99.95,"written_bytes":4033600,"offered_bytes":4033600,"asr_committed_bytes":4033600,
                               "chunks":[]]
    let emptyTrack="app-0123456789abcdef"
    let emptyManifest:[String:Any]=["schema":1,"track":emptyTrack,"format":"pcm_s16le","sample_rate":16000,"channels":1,
                                    "ended":false,"origin_uptime":NSNull(),"written_bytes":0,"offered_bytes":0,
                                    "asr_committed_bytes":0,"error":NSNull(),"chunks":[]]
    let transcript=Data("synthetic source transcript\n".utf8)
    let transcriptFile=cache.appendingPathComponent("mic-transcript.jsonl")
    let keyData=try! JSONSerialization.jsonObject(with:JSONEncoder().encode(key(0)))
    let anchor:[String:Any]=["id":"runs:word:111000","parent":"runs","session":"fixture-session","source":"mic","epoch":"epoch-1","start":111.0,"end":112.0,"textSHA256":textHash(anchorText)]
    let names:[String:Any]=["schema":2,"session":"fixture-session","sentences":["whole-parent":"整句人工标注"],
                            "speakers":[["key":keyData,"name":"张三"]],"assignments":[],"runAnchors":[anchor]]
    do {
        try JSONSerialization.data(withJSONObject:metadata,options:[.sortedKeys]).write(to:cache.appendingPathComponent("meeting.json"),options:.atomic)
        try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys]).write(to:cache.appendingPathComponent("mic-manifest.json"),options:.atomic)
        try JSONSerialization.data(withJSONObject:emptyManifest,options:[.sortedKeys]).write(to:cache.appendingPathComponent(emptyTrack+"-manifest.json"),options:.atomic)
        try JSONSerialization.data(withJSONObject:names,options:[.sortedKeys]).write(to:cache.appendingPathComponent("session-names.json"),options:.atomic)
        try transcript.write(to:transcriptFile,options:.atomic)
    } catch {fail("fixture files")}
    let hashes=["mic-transcript.jsonl":hash(transcript)]
    let metadataAttributes=try! cache.appendingPathComponent("meeting.json").resourceValues(forKeys:[.fileSizeKey])
    let metadataSize=metadataAttributes.fileSize ?? 0
    precondition(metadataSize>16_384 && metadataSize<=64*1024)
    let payload:MeetingCoarseRefinement.RequestPayload
    do {payload=try MeetingCoarseRefinement.prepareRequest(directory:cache,session:"fixture-session",cacheID:cacheID,events:events,transcriptHashes:hashes)}
    catch {fail("prepare request: \(error)")}
    let archivePrelude:[String:Any]=["session":"fixture-session","segment_id":"!archive-prelude-fixture","source_id":"remote-g999","epoch":"archive-text-only","start":0.0,"end":0.001,"final":true,"end_time_known":true,"text":"旧归档原文保持原样","quality_flags":["archive_text_only"]]
    do {
        let continued=try MeetingCoarseRefinement.prepareRequest(directory:cache,session:"fixture-session",cacheID:cacheID,events:[archivePrelude]+events,transcriptHashes:hashes)
        guard continued.units.count==payload.units.count,!continued.units.contains(where:{$0.unit_id=="!archive-prelude-fixture"}) else{fail("archive text entered acoustic refinement")}
    }catch{fail("archive-only text blocked new acoustic refinement: \(error)")}
    do {try MeetingDisplayInfoStore.saveManual("长诊断metadata测试",in:cache)}
    catch {fail("large metadata title scope: \(error)")}
    guard let partial=payload.units.first(where:{$0.unit_id=="tail"}),partial.approximate_window,
          partial.start==122.0,partial.end==126.0,
          let named=payload.units.first(where:{$0.unit_id=="roster0"}),named.speaker_name=="张三",
          !named.manual,named.speaker_locked,
          let missingEpochFinal=payload.units.first(where:{$0.unit_id=="missing-epoch-final"}),!missingEpochFinal.approximate_window,
          missingEpochFinal.start==123.0,missingEpochFinal.end==124.0,missingEpochFinal.speaker_key==nil,
          let missingEpochTail=payload.units.first(where:{$0.unit_id=="missing-epoch-tail"}),missingEpochTail.approximate_window,
          missingEpochTail.start==124.0,missingEpochTail.end==126.0,
          payload.units.first(where:{$0.unit_id=="runs:word:110000"})?.manual==false,
          payload.units.first(where:{$0.unit_id=="whole-parent:word:130000"})?.manual==false && payload.units.first(where:{$0.unit_id=="whole-parent:word:130000"})?.speaker_locked==true,
          payload.units.first(where:{$0.unit_id=="whole-parent:word:131000"})?.manual==false && payload.units.first(where:{$0.unit_id=="whole-parent:word:131000"})?.speaker_locked==true,
          payload.units.first(where:{$0.unit_id=="runs:word:111000"})?.manual==false && payload.units.first(where:{$0.unit_id=="runs:word:111000"})?.speaker_locked==true,
          !payload.units.contains(where:{$0.unit_id=="blank-run-parent:word:141000"}),
          payload.units.first(where:{$0.unit_id=="blank-run-parent:word:140000"})?.text=="前文。",
          payload.units.first(where:{$0.unit_id=="blank-run-parent:word:142000"})?.text=="后文。",
          payload.units.first(where:{$0.unit_id=="short-word"})?.text=="嗯" else{fail("unit window, blank-slice exclusion, and scoped human labels")}
    let missingEpochEvents=events.filter{$0["segment_id"] as? String=="missing-epoch-final" || $0["segment_id"] as? String=="missing-epoch-tail"}
    guard missingEpochEvents.count==2,missingEpochEvents.allSatisfy({$0["epoch"]==nil}) else{fail("missing-epoch synthetic sources")}
    var malformedEmpty=emptyManifest;malformedEmpty["written_bytes"]=2
    do {
        try JSONSerialization.data(withJSONObject:malformedEmpty,options:[.sortedKeys]).write(to:cache.appendingPathComponent(emptyTrack+"-manifest.json"),options:.atomic)
        do { _ = try MeetingCoarseRefinement.prepareRequest(directory:cache,session:"fixture-session",cacheID:cacheID,events:events,transcriptHashes:hashes);fail("nonempty track accepted without an origin") }
        catch MeetingCoarseRefinementError.invalidScope { }
        try JSONSerialization.data(withJSONObject:emptyManifest,options:[.sortedKeys]).write(to:cache.appendingPathComponent(emptyTrack+"-manifest.json"),options:.atomic)
    } catch {fail("strict empty-track validation: \(error)")}
    let emptyTrackEvent:[String:Any]=["session":"fixture-session","segment_id":"empty-track-event","source_id":emptyTrack,
                                     "track":emptyTrack,"epoch":"epoch-1","start":1.0,"end":2.0,
                                     "end_time_known":true,"final":true,"text":"这段话没有录音。","speaker":["basis":"unknown"]]
    do {
        _ = try MeetingCoarseRefinement.prepareRequest(directory:cache,session:"fixture-session",cacheID:cacheID,
            events:events+[emptyTrackEvent],transcriptHashes:hashes)
        fail("transcript event accepted without source audio")
    } catch MeetingCoarseRefinementError.invalidScope { }
      catch {fail("empty-track event validation: \(error)")}
    let payloadObject=try! payload.object
    guard payloadObject["source_sha256"] as? String==payload.source_sha256,
          payloadObject["snapshot_sha256"] as? String==payload.snapshot_sha256 else{fail("serialized request hashes")}
    do {
        let prefixEvents:[[String:Any]]=[
            ["session":"fixture-session","segment_id":"safe-prefix","source_id":"mic","track":"mic","epoch":"epoch-1","start":0.2,"end":1.5,"end_time_known":true,"final":true,"text":"已提交的原文。","speaker":["basis":"unknown"]],
            ["session":"fixture-session","segment_id":"uncovered-tail","source_id":"mic","track":"mic","epoch":"epoch-1","start":2.2,"end":3.0,"end_time_known":true,"final":true,"text":"尚未提交的原文。","speaker":["basis":"unknown"]],
            ["session":"fixture-session","segment_id":"open-tail","source_id":"mic","track":"mic","epoch":"epoch-1","start":1.6,"final":false,"end_time_known":false,"text":"未闭合尾句","speaker":["basis":"unknown"]]
        ]
        var partialVariants:[(String,[String:Any])]=[]
        var cleanTruncated=manifest;cleanTruncated["asr_committed_bytes"]=64_000
        partialVariants.append(("ended_clean_asr_lag",cleanTruncated))
        var checkpointFault=cleanTruncated;checkpointFault["processing_error"]="cache_checkpoint_write_failed"
        partialVariants.append(("processing_checkpoint_fault",checkpointFault))
        var pausedFault=checkpointFault;pausedFault["ended"]=false
        partialVariants.append(("paused_unsealed_processing_fault",pausedFault))
        var writerBackpressure=cleanTruncated;writerBackpressure["error"]="cache_writer_backpressure"
        partialVariants.append(("capture_writer_backpressure",writerBackpressure))
        for (label,candidate) in partialVariants {
            try JSONSerialization.data(withJSONObject:candidate,options:[.sortedKeys]).write(to:cache.appendingPathComponent("mic-manifest.json"),options:.atomic)
            let partial=try MeetingCoarseRefinement.prepareRequest(directory:cache,session:"fixture-session",cacheID:cacheID,events:prefixEvents,transcriptHashes:hashes)
            guard partial.incomplete_audio,partial.units.map(\.unit_id)==["safe-prefix"] else {
                fail("\(label) must refine only the durable ASR prefix and keep the tail pending")
            }
        }
        var recoveredCapture=manifest;recoveredCapture["error"]="cache_writer_backpressure"
        let recoveredBytes=try JSONSerialization.data(withJSONObject:recoveredCapture,options:[.sortedKeys])
        try recoveredBytes.write(to:cache.appendingPathComponent("mic-manifest.json"),options:.atomic)
        let recovered=try MeetingCoarseRefinement.prepareRequest(directory:cache,session:"fixture-session",cacheID:cacheID,events:events,transcriptHashes:hashes)
        guard !recovered.incomplete_audio,
              try Data(contentsOf:cache.appendingPathComponent("mic-manifest.json"))==recoveredBytes else {
            fail("completed ASR after a capture cutoff must not stay pending or erase the original fault")
        }
        for rejected in ["cache_unclean_shutdown","cache_disk_space_low"] {
            var invalid=cleanTruncated;invalid["error"]=rejected;invalid["processing_error"]="cache_checkpoint_write_failed"
            try JSONSerialization.data(withJSONObject:invalid,options:[.sortedKeys]).write(to:cache.appendingPathComponent("mic-manifest.json"),options:.atomic)
            do {
                _ = try MeetingCoarseRefinement.prepareRequest(directory:cache,session:"fixture-session",cacheID:cacheID,events:prefixEvents,transcriptHashes:hashes)
                fail("unverified audio error must not be relaxed for partial refinement: \(rejected)")
            } catch MeetingCoarseRefinementError.invalidScope { }
        }
        let partialDisplay=MeetingCoarseRefinement.eventsWithStatus(prefixEvents,["incomplete_audio":true])
        guard partialDisplay.first?["coarse_refinement_warning"] as? String=="已有转写内容已整理，仍有录音待补转写；完成转写后可重试整理",
              partialDisplay.first?["text"] as? String==prefixEvents.first?["text"] as? String else {
            fail("partial refinement must show pending transcription without changing original wording")
        }
        try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys]).write(to:cache.appendingPathComponent("mic-manifest.json"),options:.atomic)
    } catch {fail("safe partial audio coverage: \(error)")}
    var tooEarly=manifest;tooEarly["origin_uptime"]=99.7
    do {
        try JSONSerialization.data(withJSONObject:tooEarly,options:[.sortedKeys]).write(to:cache.appendingPathComponent("mic-manifest.json"),options:.atomic)
        do {
            _ = try MeetingCoarseRefinement.prepareRequest(directory:cache,session:"fixture-session",cacheID:cacheID,events:events,transcriptHashes:hashes)
            fail("excessive pre-roll offset accepted")
        } catch MeetingCoarseRefinementError.invalidScope { }
        try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys]).write(to:cache.appendingPathComponent("mic-manifest.json"),options:.atomic)
    } catch {fail("signed pre-roll boundary: \(error)")}

    let key0=try! JSONSerialization.jsonObject(with:JSONEncoder().encode(key(0)))
    let key1=try! JSONSerialization.jsonObject(with:JSONEncoder().encode(key(1)))
    var records:[[String:Any]]=[]
    for unit in payload.units {
        var text=unit.text
        var speaker:Any?
        switch unit.unit_id {
        case "plain":text="修正后的完整内容。";speaker=key1
        case "runs:word:110000":text="已经修改内容。";speaker=key1
        case "runs:word:111000":text=cleanAnchorText;speaker=key1
        case "roster0":text="张三的内容已纠字。";speaker=key1
        case "tail":text="尾部内容已补齐。";speaker=key0
        case "missing-epoch-final":text="缺少epoch的可靠终句已校正。";speaker=key0
        case "missing-epoch-tail":text="缺少epoch的尾句已校正。";speaker=key1
        case "whole-parent:word:130000":text="整句已确认姓名。";speaker=key1
        case "whole-parent:word:131000":text="仍然保留两段。";speaker=key1
        default:break
        }
        var row:[String:Any]=["unit_id":unit.unit_id,"original_text_sha256":unit.original_text_sha256,"text":text]
        if let speaker {row["speaker_key"]=speaker}
        if unit.unit_id=="runs:word:111000" {
            row["name_changes"]=[["unit_id":unit.unit_id,"old":"小小章","new":"小张"]]
        }
        records.append(row)
    }
    let projection:MeetingCoarseRefinement.Projection
    do {
        projection=try MeetingCoarseRefinement.project(events:events,session:"fixture-session",cacheID:cacheID,
            sourceSHA256:payload.source_sha256,snapshotSHA256:payload.snapshot_sha256,records:records,
            directory:cache,transcriptHashes:hashes)
    } catch {fail("valid response rejected: \(error)")}

    guard let plain=projection.events.first(where:{$0["segment_id"] as? String=="plain"}),
          plain["text"] as? String=="修正后的完整内容。",
          plain["coarse_refinement_applied"] as? Bool==true,
          SessionSpeakerKey.from(plain)==key(1) else{fail("parent text and known speaker projection")}
    guard let runEvent=projection.events.first(where:{$0["segment_id"] as? String=="runs"}),
          runEvent["text"] as? String=="已经修改内容。\(cleanAnchorText)",
          let projectedRuns=runEvent["speaker_runs"] as? [[String:Any]],projectedRuns.count==2,
          projectedRuns[0]["text"] as? String=="已经修改内容。",
          projectedRuns[1]["text"] as? String==cleanAnchorText,
          TranscriptTimeline.speakerRuns(runEvent).count==2 else{fail("stable run IDs and text projection")}
    guard let rebased=runEvent["word_spans"] as? [[String:Any]],rebased.count==2,
          rebased[0]["text"] as? String=="已经修改内容。",rebased[1]["text"] as? String==cleanAnchorText,
          (try? SpeakerRefinementArtifact.protectedIDs(directory:cache,session:"fixture-session",events:projection.events))?.contains("runs:word:111000")==true else {
        fail("manual run anchor survives nearby edit")
    }
    guard (runEvent["coarse_name_changes"] as? [[String:String]]) ==
        [["unit_id":"runs:word:111000","old":"小小章","new":"小张"]] else{fail("name changes survive projection")}
    let exportRows=projection.events.compactMap { event -> (id:String,parent:String,item:[String:Any])? in
        guard let id=event["segment_id"] as? String else{return nil}
        return (id:id,parent:id,item:event)
    }
    let exportTurns=TranscriptTimeline.readingTurns(exportRows){_,_ in nil}
    let exported=TranscriptExportSnapshot(turns:exportTurns,names:SessionNames(),meetingTitle:"术语回归",
        sessionSource:"麦克风",phase:.stopped,incomplete:false,observedTracks:["mic"],applicationNames:[],
        recoveredArchiveText:nil,absoluteTime:nil).text()
    guard exported.components(separatedBy:"· 小小章 → 小张").count==2,
          exported.contains("专名改动：") else{fail("export lists complete name change once")}
    guard let named=projection.events.first(where:{$0["segment_id"] as? String=="roster0"}),
          named["text"] as? String=="张三的内容已纠字。",SessionSpeakerKey.from(named)==key(0) else{fail("speaker name locks identity only")}
    guard let wholeParent=projection.events.first(where:{$0["segment_id"] as? String=="whole-parent"}),
          wholeParent["text"] as? String=="整句已确认姓名。仍然保留两段。",
          let wholeRuns=wholeParent["speaker_runs"] as? [[String:Any]],wholeRuns.count==2,
          wholeRuns[0]["text"] as? String=="整句已确认姓名。",wholeRuns[1]["text"] as? String=="仍然保留两段。",
          SessionSpeakerKey.from(wholeRuns[0])==nil,SessionSpeakerKey.from(wholeRuns[1])==nil else {
        fail("explicit whole-parent manual name protects every child run")
    }
    guard let blankParent=projection.events.first(where:{$0["segment_id"] as? String=="blank-run-parent"}),
          blankParent["text"] as? String=="前文。 后文。",
          let blankRuns=blankParent["speaker_runs"] as? [[String:Any]],blankRuns.count==3,
          blankRuns[1]["text"] as? String==" ",
          projection.events.first(where:{$0["segment_id"] as? String=="short-word"})?["text"] as? String=="嗯" else {
        fail("whitespace-only run stays untouched while ordinary one-character speech remains processable")
    }
    guard let tail=projection.events.first(where:{$0["segment_id"] as? String=="tail"}),
          tail["text"] as? String=="尾部内容已补齐。",tail["start"] as? Double==122.0,
          tail["end"] == nil,tail["final"] as? Bool==false,tail["end_time_known"] as? Bool==false else {
        fail("approximate listening window never changes event time or finality")
    }
    for (id,expectedKey,expectedText) in [("missing-epoch-final",key(0),"缺少epoch的可靠终句已校正。"),("missing-epoch-tail",key(1),"缺少epoch的尾句已校正。")] {
        guard let event=projection.events.first(where:{$0["segment_id"] as? String==id}),
              event["text"] as? String==expectedText,event["epoch"]==nil,
              SessionSpeakerKey.from(event)==expectedKey,
              (event["speaker"] as? [String:Any])?["epoch"]==nil else {
            fail("missing-epoch projection preserves known roster identity without adding an event epoch")
        }
        if id=="missing-epoch-final" {
            guard event["start"] as? Double==123.0,event["end"] as? Double==124.0,
                  event["final"] as? Bool==true,event["end_time_known"] as? Bool==true else{fail("reliable missing-epoch time/finality")}
        } else {
            guard event["start"] as? Double==124.0,event["end"]==nil,
                  event["final"] as? Bool==false,event["end_time_known"] as? Bool==false else{fail("approximate missing-epoch time/finality")}
        }
    }
    precondition(try! Data(contentsOf:transcriptFile)==transcript)

    var uncertainRecords=records
    for i in uncertainRecords.indices where ["roster0","roster1"].contains(uncertainRecords[i]["unit_id"] as? String ?? "") {
        uncertainRecords[i]["speaker_key"]=NSNull()
    }
    let uncertain=try! MeetingCoarseRefinement.project(events:events,session:"fixture-session",cacheID:cacheID,
        sourceSHA256:payload.source_sha256,snapshotSHA256:payload.snapshot_sha256,records:uncertainRecords,
        directory:cache,transcriptHashes:hashes)
    guard let unresolved=uncertain.events.first(where:{$0["segment_id"] as? String=="roster1"}),
          SessionSpeakerKey.from(unresolved)==nil,
          (unresolved["speaker"] as? [String:Any])?["reason"] as? String=="refinement_unassigned",
          uncertain.artifact["records"] is [[String:Any]],
          uncertain.events.first(where:{$0["segment_id"] as? String=="roster0"}).flatMap(SessionSpeakerKey.from)==key(0) else {
        fail("explicit uncertainty clears unconfirmed slot without erasing manual identity")
    }

    func rejected(_ candidate:[[String:Any]],_ candidateEvents:[[String:Any]]=events)->Bool {
        (try? MeetingCoarseRefinement.project(events:candidateEvents,session:"fixture-session",cacheID:cacheID,
            sourceSHA256:payload.source_sha256,snapshotSHA256:payload.snapshot_sha256,records:candidate,
            directory:cache,transcriptHashes:hashes)) == nil
    }
    var checks=["relative audio end includes a late track origin and ignores an unused empty track",
                "coarse preparation accepts valid meeting metadata above 16 KiB while terms are disabled",
                "automatic title storage accepts the same valid meeting metadata bound",
                "reliable and approximate units without an epoch use stable IDs, preserve times, and map only to an existing roster key",
                "whole-parent manual sentence names lock every run while a single manual run anchor stays scoped",
                "whitespace-only acoustic runs remain in original transcript but are excluded from model units; short speech remains eligible",
                "rejects nonempty audio without origin and events without recorded source audio",
                "unit hashes and known roster are encoded"]
    var bad=records;bad[0]["original_text_sha256"]=String(repeating:"0",count:64)
    precondition(rejected(bad));checks.append("rejects stale source text hashes")
    precondition(rejected(Array(records.dropLast())));checks.append("rejects incomplete model coverage")
    bad=records;bad[0]["unit_id"]="unknown-unit";precondition(rejected(bad));checks.append("rejects unknown unit IDs")
    bad=records;bad[0]["text"]="删";precondition(rejected(bad));checks.append("rejects empty or severely truncated corrections")
    bad=records;bad[0]["speaker_key"]=["session":"fixture-session","source":"mic","epoch":"epoch-1","identity":"slot:7"]
    precondition(rejected(bad));checks.append("rejects speaker keys absent from meeting roster")
    precondition((try? MeetingCoarseRefinement.project(events:events,session:"other-session",cacheID:cacheID,
        sourceSHA256:payload.source_sha256,snapshotSHA256:payload.snapshot_sha256,records:records,directory:cache,
        transcriptHashes:hashes)) == nil);checks.append("rejects cross-session responses")
    var invalidTime=events;invalidTime[0]["end"] = -1.0
    precondition((try? MeetingCoarseRefinement.project(events:invalidTime,session:"fixture-session",cacheID:cacheID,
        sourceSHA256:payload.source_sha256,snapshotSHA256:(try! MeetingCoarseRefinement.transcriptSnapshotSHA256(events:invalidTime)),
        records:records,directory:cache)) == nil);checks.append("rejects malformed reliable time spans")
    bad=records;bad[0]["unit_id"]="plain:word:0";precondition(rejected(bad));checks.append("rejects unstable or unmatched record IDs")

    func projectPartialFixture(_ candidate:[[String:Any]])->MeetingCoarseRefinement.Projection? {
        try? MeetingCoarseRefinement.project(events:events,session:"fixture-session",cacheID:cacheID,
            sourceSHA256:payload.source_sha256,snapshotSHA256:payload.snapshot_sha256,records:candidate,
            directory:cache,transcriptHashes:hashes,allowPartial:true)
    }
    var oldUnitRecords=records
    oldUnitRecords[0]["unit_id"]="removed-unit"
    precondition(projectPartialFixture(oldUnitRecords) != nil)
    bad=oldUnitRecords;bad[0]["original_text_sha256"]="malformed"
    precondition(projectPartialFixture(bad)==nil)
    bad=oldUnitRecords;bad[0]["text"]=42
    precondition(projectPartialFixture(bad)==nil)
    bad=oldUnitRecords;bad.append(oldUnitRecords[0])
    precondition(projectPartialFixture(bad)==nil)
    checks.append("partial replay skips valid stale unit identities but still rejects malformed stale record shapes")

    var partialResponse=projection.artifact
    partialResponse["model"]="synthetic-model"
    partialResponse["warning"]="semantic_assignment_incomplete"
    let partialProjection=try! MeetingCoarseRefinement.project(response:partialResponse,events:events,directory:cache,transcriptHashes:hashes)
    precondition(partialProjection.events.first?["coarse_refinement_warning"] as? String=="文字已整理，部分发言人未整理完，可重试")
    try! MeetingCoarseRefinement.save(partialProjection.artifact,directory:cache,cacheID:cacheID)
    let reloadedPartial=MeetingCoarseRefinement.loadApply(events:events,directory:cache,session:"fixture-session",cacheID:cacheID,transcriptHashes:hashes)
    precondition(reloadedPartial.first?["coarse_refinement_warning"] as? String=="文字已整理，部分发言人未整理完，可重试")
    checks.append("partial semantic failure preserves audio corrections and visible status through reload")

    // A pause batch may finish after recording has resumed. Rebase only its
    // unchanged unit identities onto the appended transcript, while current
    // manual labels and the new tail remain authoritative.
    let appended:[String:Any]=["session":"fixture-session","segment_id":"appended-during-refinement",
        "source_id":"mic","track":"mic","epoch":"epoch-1","start":150.0,"end":151.0,
        "end_time_known":true,"final":true,"text":"恢复录音后的新内容。","speaker":["basis":"unknown"]]
    let currentEvents=events+[appended]
    let updatedTranscript=Data("synthetic source transcript\nappend after resume\n".utf8)
    try! updatedTranscript.write(to:transcriptFile,options:.atomic)
    let currentHashes=["mic-transcript.jsonl":hash(updatedTranscript)]
    // Change only the sentence annotation. Replacing the whole names document
    // here would accidentally erase the existing speaker and run annotations.
    var manualNames=names
    var manualSentences=manualNames["sentences"] as? [String:String] ?? [:]
    manualSentences["plain"]="用户已确认原句"
    manualNames["sentences"]=manualSentences
    try! JSONSerialization.data(withJSONObject:manualNames,options:[.sortedKeys]).write(to:cache.appendingPathComponent("session-names.json"),options:.atomic)
    precondition(manualSentences["whole-parent"]=="整句人工标注" && manualSentences["plain"]=="用户已确认原句")
    var completedBatch=projection.artifact;completedBatch["model"]="synthetic-model"
    try! MeetingCoarseRefinement.save(completedBatch,directory:cache,cacheID:cacheID)
    let appendedReload=MeetingCoarseRefinement.loadApply(events:currentEvents,directory:cache,session:"fixture-session",
        cacheID:cacheID,transcriptHashes:currentHashes)
    guard appendedReload.first(where:{$0["segment_id"] as? String=="roster0"})?["text"] as? String=="张三的内容已纠字。",
          appendedReload.first(where:{$0["segment_id"] as? String=="runs"})?["text"] as? String=="已经修改内容。\(cleanAnchorText)",
          appendedReload.first(where:{$0["segment_id"] as? String=="appended-during-refinement"})?["text"] as? String=="恢复录音后的新内容。" else {
        fail("load after append must retain matching old records and leave the new unit raw")
    }
    checks.append("load after append replays matching old records and leaves the newly appended unit raw")
    var editedCurrentEvents=currentEvents
    let rosterIndex=editedCurrentEvents.firstIndex(where:{$0["segment_id"] as? String=="roster0"})!
    editedCurrentEvents[rosterIndex]["text"]="用户修改后的原句。"
    let editedReload=MeetingCoarseRefinement.loadApply(events:editedCurrentEvents,directory:cache,session:"fixture-session",
        cacheID:cacheID,transcriptHashes:currentHashes)
    guard editedReload.first(where:{$0["segment_id"] as? String=="roster0"})?["text"] as? String=="用户修改后的原句。",
          editedReload.first(where:{$0["segment_id"] as? String=="runs"})?["text"] as? String=="已经修改内容。\(cleanAnchorText)",
          editedReload.first(where:{$0["segment_id"] as? String=="appended-during-refinement"})?["text"] as? String=="恢复录音后的新内容。",
          editedReload.first? ["coarse_refinement_warning"] as? String=="部分原文已更新，相关整理结果已跳过；其余结果保留" else {
        fail("load with one changed unit must skip that stale record while retaining matching results and raw new units: roster0=\(String(describing:editedReload.first(where:{$0["segment_id"] as? String=="roster0"})?["text"])); runs=\(String(describing:editedReload.first(where:{$0["segment_id"] as? String=="runs"})?["text"])); warning=\(String(describing:editedReload.first?["coarse_refinement_warning"]))")
    }
    checks.append("load skips only the changed unit, retains matching old results, and keeps the new unit raw")
    var partialStaleBatch=completedBatch
    partialStaleBatch["warning"]="semantic_assignment_incomplete"
    try! MeetingCoarseRefinement.save(partialStaleBatch,directory:cache,cacheID:cacheID)
    let partialStaleReload=MeetingCoarseRefinement.loadApply(events:editedCurrentEvents,directory:cache,session:"fixture-session",
        cacheID:cacheID,transcriptHashes:currentHashes)
    guard partialStaleReload.first(where:{$0["segment_id"] as? String=="runs"})?["text"] as? String=="已经修改内容。\(cleanAnchorText)",
          partialStaleReload.first? ["coarse_refinement_warning"] as? String=="部分原文已更新，相关结果已跳过；发言人整理也未完整完成" else {
        fail("recovery must preserve both source-change and semantic-partial warnings")
    }
    checks.append("recovery keeps semantic-partial status while warning only about changed source units")
    let appendedProjection=try! MeetingCoarseRefinement.rebaseResponse(completedBatch,request:payload,events:currentEvents,
        directory:cache,transcriptHashes:currentHashes)
    let rebasedPlain=appendedProjection.events.first(where:{$0["segment_id"] as? String=="plain"})!
    precondition(rebasedPlain["text"] as? String=="修正后的完整内容。" && SessionSpeakerKey.from(rebasedPlain)==nil)
    let appendedEvent=appendedProjection.events.first(where:{$0["segment_id"] as? String=="appended-during-refinement"})!
    precondition(appendedEvent["text"] as? String=="恢复录音后的新内容。")
    let rebasedRunEvent=appendedProjection.events.first(where:{$0["segment_id"] as? String=="runs"})!
    guard rebasedRunEvent["text"] as? String=="已经修改内容。\(cleanAnchorText)" else {
        fail("append rebase changed a still-present manual run anchor: actual=\(String(describing:rebasedRunEvent["text"])); expected=已经修改内容。\(anchorText)")
    }
    checks.append("pause batch rebases exact old units after append, keeps new units raw, and preserves intervening human edits")

    var staleBatch=completedBatch
    staleBatch["source_sha256"]="stale-source"
    let staleResult=try? MeetingCoarseRefinement.rebaseResponse(staleBatch,request:payload,events:currentEvents,
        directory:cache,transcriptHashes:currentHashes)
    precondition(staleResult==nil)
    checks.append("append rebase rejects a response that does not belong to its immutable request")
    do {try MeetingCoarseRefinement.save(projection.artifact,directory:cache,cacheID:cacheID)} catch {fail("save sidecar: \(error)")}
    let loaded=MeetingCoarseRefinement.loadApply(events:events,directory:cache,session:"fixture-session",cacheID:cacheID,transcriptHashes:hashes)
    let loadedPlain=loaded.first(where:{$0["segment_id"] as? String=="plain"})
    let loadedWhole=loaded.first(where:{$0["segment_id"] as? String=="whole-parent"})
    let loadedWholeRuns=loadedWhole?["speaker_runs"] as? [[String:Any]] ?? []
    let parentExpectation=loadedPlain?["text"] as? String=="修正后的完整内容。" &&
        loadedWhole?["text"] as? String=="整句已确认姓名。仍然保留两段。" && loadedWholeRuns.count==2 &&
        loadedWholeRuns[0]["text"] as? String=="整句已确认姓名。" && loadedWholeRuns[1]["text"] as? String=="仍然保留两段。" &&
        SessionSpeakerKey.from(loadedWholeRuns[0])==nil && SessionSpeakerKey.from(loadedWholeRuns[1])==nil
    guard parentExpectation else {
        fail("reversible sidecar reload preserves whole-parent manual annotation: plain=\(String(describing:loadedPlain?["text"])); parent=\(String(describing:loadedWhole?["text"])); runs=\(loadedWholeRuns.map{String(describing:$0["text"])}); speakers=\(loadedWholeRuns.map{String(describing:SessionSpeakerKey.from($0))}); current_sentences=\(manualSentences)")
    }
    checks.append("replays reversible sidecar against exact snapshots without overwriting whole-parent annotations")
    let preferenceFile=cache.appendingPathComponent("coarse-refinement-preference.json")
    do {
        try JSONSerialization.data(withJSONObject:["schema":1,"session":"fixture-session","enabled":false]).write(to:preferenceFile,options:.atomic)
    } catch {fail("preference fixture")}
    let original=MeetingCoarseRefinement.loadApply(events:events,directory:cache,session:"fixture-session",cacheID:cacheID,transcriptHashes:hashes)
    guard original.first(where:{$0["segment_id"] as? String=="plain"})?["text"] as? String=="原始文字需要纠正。",
          original.first(where:{$0["segment_id"] as? String=="plain"})?["coarse_refinement_applied"] == nil else{fail("original transcript preference")}
    checks.append("preference restores the unprojected transcript")
    checks.append("archive-only text stays outside acoustic refinement while new speech remains eligible")
    checks.append("name changes survive projection and text export")
    return checks
}
