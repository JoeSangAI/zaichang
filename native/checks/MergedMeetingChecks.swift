import Foundation
import CryptoKit

/// Reads one prepared merged SessionCache using the same recovery, transcript,
/// audio export, playback preview and readable-file contracts as the app.
/// `directory` is `.runtime/.../merged_recording/<cache-id>`.
func mergedMeetingChecks(directory:URL)throws->[String] {
    let fm=FileManager.default
    guard directory.path.contains("/.runtime/"),directory.standardizedFileURL==directory.resolvingSymlinksInPath().standardizedFileURL,
          UUID(uuidString:directory.lastPathComponent) != nil else{throw Failure(code:"merged_fixture_scope")}
    let cacheRoot=directory.deletingLastPathComponent(),package=cacheRoot.deletingLastPathComponent()
    func check(_ value:@autoclosure ()throws->Bool,_ name:String)throws {guard try value() else{throw Failure(code:name)};checks.append(name)}
    func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    func hashes(_ root:URL)throws->[String:String] {
        var result:[String:String]=[:]
        // Source manifests hash every file, including hidden runtime sidecars
        // such as .coarse-audio-progress.lock. Keep native verification exact.
        guard let enumerator=fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey]) else{throw Failure(code:"merged_source_list")}
        for case let file as URL in enumerator {
            let values=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else{throw Failure(code:"merged_source_symlink")}
            if values.isRegularFile==true {result[String(file.path.dropFirst(root.path.count+1))]=digest(try Data(contentsOf:file))}
        }
        return result
    }
    func json(_ url:URL)throws->[String:Any] {
        guard let result=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any] else{throw Failure(code:"merged_json_invalid")}
        return result
    }
    var checks:[String]=[]
    let packageManifest=try json(package.appendingPathComponent("merge-manifest.json"))
    let sourceEntries=packageManifest["sources"] as? [[String:Any]] ?? []
    guard sourceEntries.count==2,let mergedMeta=try? json(directory.appendingPathComponent("meeting.json")),
          mergedMeta["cache_id"] as? String==directory.lastPathComponent,
          mergedMeta["session"] as? String==packageManifest["merge_session"] as? String else{throw Failure(code:"merged_scope_invalid")}
    try check(packageManifest["app_cache"] as? [String:Any] != nil,"staging_contains_importable_cache")
    for source in sourceEntries {
        guard let id=source["cache_id"] as? String,let expected=source["files_sha256"] as? [String:String] else{throw Failure(code:"merged_source_manifest_invalid")}
        let actual=try hashes(package.appendingPathComponent("sources",isDirectory:true).appendingPathComponent(id,isDirectory:true))
        try check(actual==expected,"source_\(id)_backup_hashes_match")
    }
    guard let item=try cachedMeetings(in:cacheRoot).first(where:{$0.id==directory.lastPathComponent}) else{throw Failure(code:"merged_cache_not_enumerated")}
    try check(item.pendingBytes==0 && item.transcriptionComplete && !item.warning,"merged_cache_is_ready_without_pending_asr")
    try check(abs(item.date.timeIntervalSince1970-(mergedMeta["created_at"] as? Double ?? 0))<0.001,"merged_library_date_preserves_original_recording_start")
    let rawEvents=try item.events(includeAutomaticRefinement:false,includeCoarseRefinement:false)
    let events=try item.events()
    let mergedSession=try item.metadata()["session"] as? String ?? ""
    let sourceIDs=Set(sourceEntries.compactMap{$0["cache_id"] as? String})
    let represented=Set(events.compactMap{$0["merge_source_cache_id"] as? String})
    try check(!rawEvents.isEmpty && represented==sourceIDs && events.allSatisfy{$0["session"] as? String==mergedSession},"app_recovery_reads_one_session_with_both_source_timelines")
    for source in sourceIDs {
        let epochs=Set(events.filter{$0["merge_source_cache_id"] as? String==source}.flatMap { event -> [String] in
            let parent=(event["speaker"] as? [String:Any])?["epoch"] as? String
            let runs=(event["speaker_runs"] as? [[String:Any]] ?? []).compactMap{($0["speaker"] as? [String:Any])?["epoch"] as? String}
            return ([parent].compactMap{$0})+runs
        })
        try check(!epochs.isEmpty,"source_\(source)_retains_speaker_epochs")
        for other in sourceIDs where other != source {
            let otherEpochs=Set(events.filter{$0["merge_source_cache_id"] as? String==other}.flatMap { event -> [String] in
                let parent=(event["speaker"] as? [String:Any])?["epoch"] as? String
                let runs=(event["speaker_runs"] as? [[String:Any]] ?? []).compactMap{($0["speaker"] as? [String:Any])?["epoch"] as? String}
                return ([parent].compactMap{$0})+runs
            })
            try check(epochs.isDisjoint(with:otherEpochs),"speaker_epochs_are_not_cross_merged")
        }
    }

    // Assert that all previously optimized second-source strings were moved to
    // their shifted run IDs without changing text or its source hash.
    let secondID=sourceEntries[1]["cache_id"] as? String ?? ""
    let secondSource=package.appendingPathComponent("sources",isDirectory:true).appendingPathComponent(secondID,isDirectory:true)
    let offset=(sourceEntries[1]["offset_seconds"] as? NSNumber)?.doubleValue ?? 0
    let oldNames=try json(secondSource.appendingPathComponent("session-names.json"))
    let mergedNamesURL=directory.appendingPathComponent("session-names.json")
    let mergedNames=try json(mergedNamesURL)
    let oldSpeakers=oldNames["speakers"] as? [[String:Any]] ?? []
    let mergedSpeakers=mergedNames["speakers"] as? [[String:Any]] ?? []
    let oldAssignments=oldNames["assignments"] as? [[String:Any]] ?? []
    let mergedAssignments=mergedNames["assignments"] as? [[String:Any]] ?? []
    let oldAnchors=oldNames["runAnchors"] as? [[String:Any]] ?? []
    let mergedAnchors=mergedNames["runAnchors"] as? [[String:Any]] ?? []
    var restoredNames=SessionNames()
    try restoredNames.restore(Data(contentsOf:mergedNamesURL),session:mergedSession)
    struct NamedSpeaker:Decodable {let key:SessionSpeakerKey;let name:String}
    let decodedSpeakers=try JSONDecoder().decode([NamedSpeaker].self,from:JSONSerialization.data(withJSONObject:mergedSpeakers))
    let oldSpeakerLabels=(oldSpeakers.compactMap{$0["name"] as? String}).sorted()
    let mergedSpeakerLabels=decodedSpeakers.map(\.name).sorted()
    try check(oldSpeakerLabels.count==2 && mergedSpeakerLabels==oldSpeakerLabels && decodedSpeakers.allSatisfy({restoredNames.name(speaker:$0.key)==$0.name}),"app_restores_both_latest_manual_speaker_names")
    func shiftedID(_ id:String)->String {
        guard offset>0 else{return id}
        for marker in [":word:",":turn:"] {
            guard let range=id.range(of:marker,options:.backwards),let milliseconds=Int(id[range.upperBound...]) else{continue}
            return String(id[..<range.upperBound])+String(Int(Double(milliseconds)+offset*1000+0.5))
        }
        return id
    }
    let mergedAssignmentIDs=Set(mergedAssignments.compactMap{$0["id"] as? String})
    let expectedAssignmentIDs=Set(oldAssignments.compactMap{$0["id"] as? String}.map(shiftedID))
    try check(oldAssignments.count==68 && expectedAssignmentIDs.count==68 && expectedAssignmentIDs.isSubset(of:mergedAssignmentIDs),"all_68_manual_speaker_assignments_survive_with_shifted_ids")
    let mergedAnchorsByID=Dictionary(uniqueKeysWithValues:mergedAnchors.compactMap{row in (row["id"] as? String).map{($0,row)}})
    let anchorsPreserved=oldAnchors.allSatisfy {old in
        guard let oldID=old["id"] as? String,let oldStart=old["start"] as? Double,
              let oldEnd=old["end"] as? Double,let oldHash=old["textSHA256"] as? String,
              let migrated=mergedAnchorsByID[shiftedID(oldID)],let start=migrated["start"] as? Double,
              let end=migrated["end"] as? Double else{return false}
        return abs(start-(oldStart+offset))<0.000001 && abs(end-(oldEnd+offset))<0.000001 && migrated["textSHA256"] as? String==oldHash
    }
    try check(oldAnchors.count==65 && mergedAnchors.count>=oldAnchors.count && anchorsPreserved,"all_65_manual_run_anchors_restore_with_shifted_times")
    let oldArtifact=try json(secondSource.appendingPathComponent("automatic-coarse-refinement.json"))
    let mergedArtifact=try json(directory.appendingPathComponent("automatic-coarse-refinement.json"))
    let oldRecords=oldArtifact["records"] as? [[String:Any]] ?? [],newRecords=mergedArtifact["records"] as? [[String:Any]] ?? []
    let oldItem=try cachedMeetings(in:package.appendingPathComponent("sources",isDirectory:true)).first(where:{$0.id==secondID})
    guard let oldItem else{throw Failure(code:"merged_second_source_unreadable")}
    let oldEvents=try oldItem.events(includeAutomaticRefinement:false,includeCoarseRefinement:false)
    let remapped=Dictionary(uniqueKeysWithValues:newRecords.compactMap{row in (row["unit_id"] as? String).map{($0,row)}})
    var preserved=0
    for old in oldRecords {
        guard let oldID=old["unit_id"] as? String,let oldText=old["text"] as? String,
              let oldHash=old["original_text_sha256"] as? String else{throw Failure(code:"merged_old_coarse_record_invalid")}
        let marker=oldID.range(of:":word:",options:.backwards)
        let parent=marker.map{String(oldID[..<$0.lowerBound])} ?? oldID
        guard let event=oldEvents.first(where:{$0["segment_id"] as? String==parent}) else{throw Failure(code:"merged_old_coarse_parent_missing")}
        let run:[String:Any]?
        let newID:String
        if let marker {
            guard let oldMS=Int(oldID[marker.upperBound...]),
                  let matched=(event["speaker_runs"] as? [[String:Any]])?.first(where:{(($0["start"] as? Double).map{Int(($0*1000).rounded())})==oldMS}),
                  let start=matched["start"] as? Double else{throw Failure(code:"merged_old_coarse_run_missing")}
            run=matched
            newID=parent+":word:"+String(Int(((start+offset)*1000).rounded()))
        } else {
            run=nil
            newID=oldID
        }
        guard let migrated=remapped[newID],migrated["text"] as? String==oldText,
              migrated["original_text_sha256"] as? String==oldHash,
              let key=migrated["speaker_key"] as? [String:Any],key["session"] as? String==mergedSession else{throw Failure(code:"merged_coarse_record_changed")}
        let projectedEvent=events.first(where:{$0["segment_id"] as? String==parent})
        if let run {
            let newMS=Int((((run["start"] as? Double ?? 0)+offset)*1000).rounded())
            guard let projectedRun=(projectedEvent?["speaker_runs"] as? [[String:Any]])?.first(where:{(($0["start"] as? Double).map{Int(($0*1000).rounded())})==newMS}),
                  projectedRun["text"] as? String==oldText else{throw Failure(code:"merged_coarse_not_loaded_by_app")}
        } else {
            guard projectedEvent?["text"] as? String==oldText else{throw Failure(code:"merged_coarse_not_loaded_by_app")}
        }
        preserved+=1
    }
    try check(preserved==oldRecords.count && preserved==115,"all_115_existing_coarse_records_are_preserved_and_loaded")
    let status=try json(directory.appendingPathComponent("coarse-refinement-status.json"))
    try check(status["state"] as? String=="partial","missing_first_source_refinement_is_not_claimed_as_completed")

    let exports=package.appendingPathComponent(".native-acceptance-exports-"+UUID().uuidString,isDirectory:true)
    defer {
        try? fm.removeItem(at:exports)
        try? fm.removeItem(at:directory.appendingPathComponent("audio-export.json"))
    }
    let audioStore=MeetingAudioAssetsStore(cacheRoot:cacheRoot,exportsRoot:exports)
    let library=try MeetingLibraryFiles.read(item,root:cacheRoot)
    try check(library.session==mergedSession && library.audioFolder==directory && library.transcriptFolder==directory,"app_library_reads_transcript_and_audio")
    let wavFolder=try audioStore.export(item,active:false)
    let wavs=try fm.contentsOfDirectory(at:wavFolder,includingPropertiesForKeys:[.isRegularFileKey]).filter{$0.pathExtension.lowercased()=="wav"}
    let micManifest=try json(directory.appendingPathComponent("mic-manifest.json"))
    let micBytes=(micManifest["written_bytes"] as? NSNumber)?.intValue ?? -1
    guard let micWav=wavs.first(where:{$0.lastPathComponent.hasSuffix("－麦克风.wav")}) else{throw Failure(code:"merged_mic_wav_missing")}
    let wavData=try Data(contentsOf:micWav)
    try check(wavData.count==micBytes+44 && wavData.prefix(4)==Data("RIFF".utf8) && wavData.dropFirst(8).prefix(4)==Data("WAVE".utf8),"app_exports_aligned_mic_track_as_valid_wav")
    try check(!fm.fileExists(atPath:directory.appendingPathComponent("mic-raw-manifest.json").path) &&
              (try hashes(secondSource))["mic-raw-000000.pcm"] != nil,"raw_microphones_remain_only_in_verified_source_backups")
    if let event=events.first(where:{($0["merge_source_cache_id"] as? String)==sourceEntries[0]["cache_id"] as? String && $0["source_id"] as? String=="mic" && ($0["end_time_known"] as? Bool==true)}) {
        let clip=try SpeakerAudioPreview.read(root:cacheRoot,cacheID:item.id,session:mergedSession,items:[event])
        try check(clip.wav.count>44 && clip.duration>0 && !clip.truncated,"app_can_build_playable_preview_from_aligned_first_session")
    } else {throw Failure(code:"merged_preview_event_missing")}
    let files=try MeetingFilesExportStore(cacheRoot:cacheRoot,exportsRoot:exports).build(item,library:library,audioStore:audioStore)
    try check(files.audioCount==wavs.count && files.transcriptState=="转写完整" && fm.fileExists(atPath:files.folder.appendingPathComponent("会议说明.txt").path),"app_builds_readable_meeting_export_with_audio")
    return checks
}

private extension String {
    var nonEmpty:String? {isEmpty ? nil:self}
}
