import Foundation
import CryptoKit

func speakerRefinementArtifactChecks(directory:URL)throws->[String] {
    guard directory.path.contains("/.runtime/") else{throw Failure(code:"speaker_refinement_fixture_scope")}
    let root=directory.appendingPathComponent("speaker-refinement-artifact-"+UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:root)}
    let cacheID=UUID().uuidString,folder=root.appendingPathComponent(cacheID,isDirectory:true)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let session=UUID().uuidString,sourceHash=String(repeating:"a",count:64)
    let sourceHashes=["mic-transcript.jsonl":sourceHash]
    func writeJSON(_ object:Any,to url:URL)throws {try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:url,options:.atomic)}
    let meetingURL=folder.appendingPathComponent("meeting.json")
    try writeJSON(["schema":1,"session":session,"title":"无姓名合成会议"],to:meetingURL)
    let manifestURL=folder.appendingPathComponent("mic-manifest.json")
    let pcmURL=folder.appendingPathComponent("mic-000000.pcm")
    let pcm=Data([1,2,3,4]);try pcm.write(to:pcmURL)
    let manifest:[String:Any]=["schema":1,"track":"mic","ended":true,"chunks":[["index":0,"bytes":4,"sha256":String(repeating:"b",count:64)]]]
    try writeJSON(manifest,to:manifestURL)
    try Data("raw audio manifest".utf8).write(to:folder.appendingPathComponent("mic-raw-manifest.json"))
    try Data("reference manifest".utf8).write(to:folder.appendingPathComponent("reference-manifest.json"))
    let transcriptURL=folder.appendingPathComponent("mic-transcript.jsonl")
    let transcript=Data("synthetic source transcript\n".utf8);try transcript.write(to:transcriptURL)

    let known:[String:Any]=["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":"epoch-a"]
    let unknown:[String:Any]=["basis":"unknown","reason":"no_reliable_span"]
    let multiple:[String:Any]=["basis":"multiple","cluster_ids":[0,1]]
    let runUnknown:[String:Any]=["start":0.0,"end":1.0,"text":"甲","speaker":unknown]
    let runKnown:[String:Any]=["start":1.0,"end":2.0,"text":"乙","speaker":known]
    let target:[String:Any]=["type":"segment","segment_id":"target","session":session,"source_id":"mic","epoch":"epoch-a","revision":1,"start":0.0,"end":2.0,"text":"甲乙","final":true,"end_time_known":true,"speaker":multiple,"speaker_runs":[runUnknown,runKnown]]
    let evidence:[String:Any]=["type":"segment","segment_id":"evidence","session":session,"source_id":"mic","epoch":"epoch-a","revision":1,"start":3.0,"end":4.0,"text":"丙","final":true,"end_time_known":true,"speaker":known]
    let autoTarget:[String:Any]=["type":"segment","segment_id":"auto-target","session":session,"source_id":"mic","epoch":"epoch-a","revision":1,"start":5.0,"end":6.0,"text":"丁","final":true,"end_time_known":true,"speaker":unknown]
    let events=[target,evidence,autoTarget]

    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:name)};checks.append(name)}
    func equalJSON(_ left:Any?,_ right:Any?) ->Bool {
        guard let left=left,let right=right,
              let a=try? JSONSerialization.data(withJSONObject:left,options:[.sortedKeys]),
              let b=try? JSONSerialization.data(withJSONObject:right,options:[.sortedKeys]) else{return false}
        return a==b
    }
    func textSHA256(_ text:String)->String {SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined()}
    func rejected(_ name:String,_ body:()throws->Void)throws {
        do {try body();throw Failure(code:"accepted_"+name)}
        catch is SpeakerRefinementArtifactError {checks.append(name)}
    }
    func changedUnknown(_ slot:Int=0)->[String:Any] {
        var changed=runUnknown
        changed["speaker"]=["basis":"anonymous_cluster","cluster_id":slot,"source_id":"mic","epoch":"epoch-a"]
        return changed
    }
    func record(for event:[String:Any],speaker:[String:Any]?=nil,runs:[[String:Any]]?=nil)throws->[String:Any] {
        ["segment_id":event["segment_id"]!,"original_sha256":try SpeakerRefinementArtifact.originalEventSHA256(event),
         "speaker":speaker ?? (event["speaker"] as! [String:Any]),"speaker_runs":runs ?? (event["speaker_runs"] as? [[String:Any]] ?? [])]
    }
    func artifact(_ rows:[[String:Any]],cache:String=cacheID,source:[String:String]=sourceHashes,snapshot:String?=nil,
                  method:String=SpeakerRefinementArtifact.method,model:String=SpeakerRefinementArtifact.model)throws->[String:Any] {
        let currentSnapshot=try SpeakerRefinementArtifact.snapshotSHA256(directory:folder,cacheID:cacheID,sourceHashes:sourceHashes)
        return ["schema":1,"method":method,"model":model,
         "cache_id":cache,"session":session,"source_sha256":source,
         "snapshot_sha256":snapshot ?? currentSnapshot,"records":rows]
    }
    func encoded(_ object:[String:Any])throws->Data {try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])}

    var changedRuns=[changedUnknown(),runKnown]
    let validRecord=try record(for:target,runs:changedRuns)
    let object=try artifact([validRecord])
    let initialSnapshot=try SpeakerRefinementArtifact.snapshotHashes(directory:folder,cacheID:cacheID,sourceHashes:sourceHashes)
    try check(initialSnapshot["mic-raw-manifest.json"]==nil && initialSnapshot["reference-manifest.json"]==nil,"speaker_refinement_snapshot_skips_raw_and_reference_manifests")
    let projected=try SpeakerRefinementArtifact.validateApply(object:object,events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)
    let projectedTarget=projected[0],projectedRuns=projectedTarget["speaker_runs"] as! [[String:Any]]
    try check((projectedRuns[0]["speaker"] as? [String:Any])?["cluster_id"] as? Int==0 && equalJSON(projectedRuns[1]["speaker"],known),"speaker_refinement_unknown_run_uses_existing_same_scope_slot")
    try check(projectedTarget["text"] as? String==target["text"] as? String && projectedTarget["start"] as? Double==target["start"] as? Double && projectedTarget["end"] as? Double==target["end"] as? Double && projectedTarget["revision"] as? Int==target["revision"] as? Int,"speaker_refinement_preserves_provider_text_time_and_revision")
    try check(!FileManager.default.fileExists(atPath:folder.appendingPathComponent("session-names.json").path),"speaker_refinement_does_not_require_manual_names_or_a_roster")

    let multipleChange=try record(for:target,speaker:["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":"epoch-a"])
    let multipleArtifact=try artifact([multipleChange])
    try rejected("speaker_refinement_multiple_parent_is_immutable"){_ = try SpeakerRefinementArtifact.validateApply(object:multipleArtifact,events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)}

    let autoSpeaker:[String:Any]=["basis":"anonymous_cluster","cluster_id":0,"source_id":"mic","epoch":"epoch-a"]
    let protectedObject=try artifact([validRecord,record(for:autoTarget,speaker:autoSpeaker)])
    let snapshotWithoutNames=try SpeakerRefinementArtifact.snapshotSHA256(directory:folder,cacheID:cacheID,sourceHashes:sourceHashes)
    try writeJSON(["schema":2,"session":session,"sentences":["target":"人工姓名"],"speakers":[],"assignments":[],"runAnchors":[]] as [String:Any],to:folder.appendingPathComponent("session-names.json"))
    let protected=try SpeakerRefinementArtifact.protectedIDs(directory:folder,session:session)
    try check(protected.contains("target") && !protected.contains("auto-target"),"speaker_refinement_manual_sentence_protects_only_its_parent")
    try check(try SpeakerRefinementArtifact.snapshotSHA256(directory:folder,cacheID:cacheID,sourceHashes:sourceHashes)==snapshotWithoutNames,"speaker_refinement_manual_names_do_not_invalidate_snapshot")
    try writeJSON(["schema":2,"session":UUID().uuidString,"sentences":["target":"人工姓名"],"speakers":[],"assignments":[],"runAnchors":[]] as [String:Any],to:folder.appendingPathComponent("session-names.json"))
    try rejected("speaker_refinement_manual_names_from_another_session_are_rejected"){_ = try SpeakerRefinementArtifact.protectedIDs(directory:folder,session:session)}
    try writeJSON(["schema":2,"session":session,"sentences":["target":"人工姓名"],"speakers":[],"assignments":[],"runAnchors":[]] as [String:Any],to:folder.appendingPathComponent("session-names.json"))
    let protectedProjection=try SpeakerRefinementArtifact.validateApply(object:protectedObject,events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)
    try check(equalJSON((protectedProjection[0]["speaker_runs"] as? [[String:Any]])?[0]["speaker"],unknown) && equalJSON(protectedProjection[2]["speaker"],autoSpeaker),"speaker_refinement_skips_manual_parent_and_applies_unrelated_candidate")

    let runID=TranscriptTimeline.runID(parent:"target",run:runUnknown)
    let runProtection:[String:Any]=["schema":2,"session":session,"sentences":[:],"speakers":[],"assignments":[["id":runID,"key":["session":session,"source":"mic","epoch":"epoch-a","identity":"slot:0"]]],"runAnchors":[]]
    try writeJSON(runProtection,to:folder.appendingPathComponent("session-names.json"))
    let runProtected=try SpeakerRefinementArtifact.protectedIDs(directory:folder,session:session)
    try check(runProtected.contains(runID) && !runProtected.contains("target"),"speaker_refinement_manual_run_assignment_protects_exact_run")
    let runProjection=try SpeakerRefinementArtifact.validateApply(object:protectedObject,events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)
    try check(equalJSON((runProjection[0]["speaker_runs"] as? [[String:Any]])?[0]["speaker"],unknown) && equalJSON((runProjection[0]["speaker_runs"] as? [[String:Any]])?[1]["speaker"],known),"speaker_refinement_manual_run_keeps_original_without_blocking_other_records")

    let anchorRunA:[String:Any]=["start":7.0,"end":8.0,"text":"戊","speaker":unknown]
    let anchorRunB:[String:Any]=["start":8.0,"end":9.0,"text":"己","speaker":unknown]
    let anchorRunC:[String:Any]=["start":9.0,"end":10.0,"text":"庚","speaker":unknown]
    let anchorEvent:[String:Any]=["type":"segment","segment_id":"anchor-target","session":session,"source_id":"mic","epoch":"epoch-a","revision":1,"start":7.0,"end":10.0,"text":"戊己庚","final":true,"end_time_known":true,"speaker":multiple,"speaker_runs":[anchorRunA,anchorRunB,anchorRunC],"word_spans":[["start":7.0,"end":8.0,"text":"戊"],["start":8.0,"end":9.0,"text":"己"],["start":9.0,"end":10.0,"text":"庚"]]]
    let anchorEvents=events+[anchorEvent]
    let anchorRuns=(0..<3).map { index -> [String:Any] in
        var run=changedUnknown();run["start"]=7.0+Double(index);run["end"]=8.0+Double(index);run["text"]=["戊","己","庚"][index];return run
    }
    let anchorRecord=try record(for:anchorEvent,runs:anchorRuns)
    let anchorObject=try artifact([anchorRecord])
    let wordAnchor:[String:Any]=["id":"anchor-target:word:7000","parent":"anchor-target","session":session,"source":"mic","epoch":"epoch-a","start":7.0,"end":8.0,"textSHA256":textSHA256("戊")]
    try writeJSON(["schema":2,"session":session,"sentences":[:],"speakers":[],"assignments":[],"runAnchors":[wordAnchor]] as [String:Any],to:folder.appendingPathComponent("session-names.json"))
    let wordProtected=try SpeakerRefinementArtifact.protectedIDs(directory:folder,session:session,events:anchorEvents)
    try check(wordProtected.contains("anchor-target:word:7000") && !wordProtected.contains("anchor-target"),"speaker_refinement_manual_word_anchor_protects_only_its_parent_run")
    let wordProjection=try SpeakerRefinementArtifact.validateApply(object:anchorObject,events:anchorEvents,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)
    let wordProjectedRuns=wordProjection[3]["speaker_runs"] as! [[String:Any]]
    try check(equalJSON(wordProjectedRuns[0]["speaker"],unknown) && equalJSON(wordProjectedRuns[1]["speaker"],autoSpeaker) && equalJSON(wordProjectedRuns[2]["speaker"],autoSpeaker),"speaker_refinement_same_parent_nonoverlapping_runs_remain_eligible")

    let turnAnchor:[String:Any]=["id":"anchor-target:turn:7000","parent":"anchor-target","session":session,"source":"mic","epoch":"epoch-a","start":7.0,"end":9.0,"textSHA256":textSHA256("戊己")]
    try writeJSON(["schema":2,"session":session,"sentences":[:],"speakers":[],"assignments":[],"runAnchors":[turnAnchor]] as [String:Any],to:folder.appendingPathComponent("session-names.json"))
    let turnProtected=try SpeakerRefinementArtifact.protectedIDs(directory:folder,session:session,events:anchorEvents)
    try check(turnProtected.contains("anchor-target:word:7000") && turnProtected.contains("anchor-target:word:8000") && !turnProtected.contains("anchor-target:word:9000"),"speaker_refinement_turn_anchor_protects_every_strictly_overlapping_run")
    let turnProjection=try SpeakerRefinementArtifact.validateApply(object:anchorObject,events:anchorEvents,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)
    let turnProjectedRuns=turnProjection[3]["speaker_runs"] as! [[String:Any]]
    try check(equalJSON(turnProjectedRuns[0]["speaker"],unknown) && equalJSON(turnProjectedRuns[1]["speaker"],unknown) && equalJSON(turnProjectedRuns[2]["speaker"],autoSpeaker),"speaker_refinement_turn_overlap_is_preserved_and_third_run_refined")
    try FileManager.default.removeItem(at:folder.appendingPathComponent("session-names.json"))

    let artifactData=try encoded(object)
    let prepared=try SpeakerRefinementArtifact.prepareValidated(data:artifactData,events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)
    let artifactURL=folder.appendingPathComponent(SpeakerRefinementArtifact.filename)
    try check(!FileManager.default.fileExists(atPath:artifactURL.path) && equalJSON(prepared.projectedEvents[0],projected[0]),"speaker_refinement_prepare_validates_without_writing")
    try SpeakerRefinementArtifact.writePrepared(prepared)
    try SpeakerRefinementArtifact.writeValidated(data:artifactData,events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)
    let loaded=SpeakerRefinementArtifact.loadApply(events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)
    try check(equalJSON((loaded[0]["speaker_runs"] as? [[String:Any]])?[0]["speaker"],changedRuns[0]["speaker"]),"speaker_refinement_sidecar_round_trips_on_reopen")
    let transcriptAfter=try Data(contentsOf:transcriptURL),pcmAfter=try Data(contentsOf:pcmURL)
    try check(transcriptAfter==transcript && pcmAfter==pcm,"speaker_refinement_never_rewrites_transcript_or_pcm")

    var bad=object;bad["source_sha256"]=["mic-transcript.jsonl":String(repeating:"c",count:64)]
    try rejected("speaker_refinement_changed_source_hash_rejected"){_ = try SpeakerRefinementArtifact.validateApply(object:bad,events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)}
    bad=object;bad["snapshot_sha256"]=String(repeating:"0",count:64)
    try rejected("speaker_refinement_changed_snapshot_rejected"){_ = try SpeakerRefinementArtifact.validateApply(object:bad,events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)}
    bad=object;bad["cache_id"]=UUID().uuidString
    try rejected("speaker_refinement_old_cache_id_rejected"){_ = try SpeakerRefinementArtifact.validateApply(object:bad,events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)}
    try rejected("speaker_refinement_duplicate_segment_ids_are_rejected_without_trap"){_ = try SpeakerRefinementArtifact.validateApply(object:object,events:[target,target],sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)}
    bad=object;var badRecords=bad["records"] as! [[String:Any]];badRecords[0]["original_sha256"]=String(repeating:"f",count:64);bad["records"]=badRecords
    try rejected("speaker_refinement_changed_input_event_hash_rejected"){_ = try SpeakerRefinementArtifact.validateApply(object:bad,events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)}

    badRecords=(object["records"] as! [[String:Any]]);changedRuns[0]["text"]="改字";badRecords[0]["speaker_runs"]=changedRuns;bad=object;bad["records"]=badRecords
    try rejected("speaker_refinement_run_text_change_rejected"){_ = try SpeakerRefinementArtifact.validateApply(object:bad,events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)}
    changedRuns=[changedUnknown(),runKnown];changedRuns[0]["end"]=1.25;badRecords=(object["records"] as! [[String:Any]]);badRecords[0]["speaker_runs"]=changedRuns;bad=object;bad["records"]=badRecords
    try rejected("speaker_refinement_run_boundary_change_rejected"){_ = try SpeakerRefinementArtifact.validateApply(object:bad,events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)}

    let knownRecord=try record(for:evidence,speaker:["basis":"anonymous_cluster","cluster_id":1,"source_id":"mic","epoch":"epoch-a"])
    bad=try artifact([knownRecord]);
    try rejected("speaker_refinement_original_known_speaker_is_immutable"){_ = try SpeakerRefinementArtifact.validateApply(object:bad,events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)}

    let slotOne:[String:Any]=["basis":"anonymous_cluster","cluster_id":1,"source_id":"mic","epoch":"epoch-a"]
    let slotOneEvidence:[String:Any]=["type":"segment","segment_id":"evidence-slot-one","session":session,"source_id":"mic","epoch":"epoch-a","revision":1,"start":11.0,"end":12.0,"text":"辛","final":true,"end_time_known":true,"speaker":slotOne]
    let remapEvent:[String:Any]=["type":"segment","segment_id":"automatic-remap","session":session,"source_id":"mic","epoch":"epoch-a","revision":1,"start":13.0,"end":15.0,"text":"壬癸","final":true,"end_time_known":true,"speaker":multiple,
         "speaker_runs":[["start":13.0,"end":14.0,"text":"壬","speaker":known],["start":14.0,"end":15.0,"text":"癸","speaker":known]]]
    let remapEvents=events+[slotOneEvidence,remapEvent]

    let manualRaw:[String:Any]=["type":"segment","segment_id":"manual-slot-remap","session":session,"source_id":"mic","epoch":"epoch-a","revision":1,"start":16.0,"end":18.0,"text":"子丑","final":true,"end_time_known":true,"speaker":known]
    let sentenceOnly:[String:Any]=["type":"segment","segment_id":"manual-sentence-only","session":session,"source_id":"mic","epoch":"epoch-a","revision":1,"start":18.0,"end":19.0,"text":"寅","final":true,"end_time_known":true,"speaker":known]
    let alignmentInput=remapEvents+[manualRaw,sentenceOnly]
    let assignedSlotOne:[String:Any]=["schema":2,"session":session,"sentences":["manual-sentence-only":"人工姓名"],"speakers":[],"assignments":[["id":"manual-slot-remap","key":["session":session,"source":"mic","epoch":"epoch-a","identity":"slot:1"]]],"runAnchors":[]]
    try writeJSON(assignedSlotOne,to:folder.appendingPathComponent("session-names.json"))
    let aligned=try SpeakerRefinementArtifact.alignmentEvents(directory:folder,session:session,events:alignmentInput)
    let alignedRaw=aligned.first(where:{$0["segment_id"] as? String=="manual-slot-remap"})!
    let alignedSentence=aligned.first(where:{$0["segment_id"] as? String=="manual-sentence-only"})!
    try check((alignedRaw["speaker"] as? [String:Any])?["cluster_id"] as? Int==1 && (manualRaw["speaker"] as? [String:Any])?["cluster_id"] as? Int==0,"speaker_refinement_alignment_projection_uses_valid_manual_slot_without_mutating_source")
    try check((alignedSentence["speaker"] as? [String:Any])?["basis"] as? String=="unknown" && (sentenceOnly["speaker"] as? [String:Any])?["cluster_id"] as? Int==0,"speaker_refinement_alignment_projection_excludes_sentence_name_without_guessing_slot")

    let anchoredRaw:[String:Any]=["type":"segment","segment_id":"manual-anchor-parent","session":session,"source_id":"mic","epoch":"epoch-a","revision":1,"start":20.0,"end":22.0,"text":"卯辰","final":true,"end_time_known":true,"speaker":multiple,
        "speaker_runs":[["start":20.0,"end":21.0,"text":"卯","speaker":known],["start":21.0,"end":22.0,"text":"辰","speaker":known]],
        "word_spans":[["start":20.0,"end":20.5,"text":"卯"],["start":21.0,"end":22.0,"text":"辰"]]]
    let partialAnchor:[String:Any]=["id":"manual-anchor-parent:word:20000","parent":"manual-anchor-parent","session":session,"source":"mic","epoch":"epoch-a","start":20.0,"end":20.5,"textSHA256":textSHA256("卯")]
    let fullAnchor:[String:Any]=["id":"manual-anchor-parent:word:21000","parent":"manual-anchor-parent","session":session,"source":"mic","epoch":"epoch-a","start":21.0,"end":22.0,"textSHA256":textSHA256("辰")]
    let partialAnchorNames:[String:Any]=["schema":2,"session":session,"sentences":[:],"speakers":[],"assignments":[["id":partialAnchor["id"]!,"key":["session":session,"source":"mic","epoch":"epoch-a","identity":"slot:1"]]],"runAnchors":[partialAnchor]]
    try writeJSON(partialAnchorNames,to:folder.appendingPathComponent("session-names.json"))
    let partialProjection=try SpeakerRefinementArtifact.alignmentEvents(directory:folder,session:session,events:[slotOneEvidence,anchoredRaw])
    let partialRuns=partialProjection[1]["speaker_runs"] as! [[String:Any]]
    try check((partialRuns[0]["speaker"] as? [String:Any])?["basis"] as? String=="unknown" && (partialRuns[1]["speaker"] as? [String:Any])?["cluster_id"] as? Int==0,"speaker_refinement_partial_run_anchor_excludes_old_slot")
    let fullAnchorNames:[String:Any]=["schema":2,"session":session,"sentences":[:],"speakers":[],"assignments":[["id":fullAnchor["id"]!,"key":["session":session,"source":"mic","epoch":"epoch-a","identity":"slot:1"]]],"runAnchors":[fullAnchor]]
    try writeJSON(fullAnchorNames,to:folder.appendingPathComponent("session-names.json"))
    let fullProjection=try SpeakerRefinementArtifact.alignmentEvents(directory:folder,session:session,events:[slotOneEvidence,anchoredRaw])
    let fullRuns=fullProjection[1]["speaker_runs"] as! [[String:Any]]
    try check((fullRuns[1]["speaker"] as? [String:Any])?["cluster_id"] as? Int==1,"speaker_refinement_full_word_anchor_maps_to_assigned_existing_slot")
    let anchorWithoutKey:[String:Any]=["schema":2,"session":session,"sentences":[:],"speakers":[],"assignments":[],"runAnchors":[fullAnchor]]
    try writeJSON(anchorWithoutKey,to:folder.appendingPathComponent("session-names.json"))
    let noKeyProjection=try SpeakerRefinementArtifact.alignmentEvents(directory:folder,session:session,events:[slotOneEvidence,anchoredRaw])
    let noKeyRuns=noKeyProjection[1]["speaker_runs"] as! [[String:Any]]
    try check((noKeyRuns[1]["speaker"] as? [String:Any])?["basis"] as? String=="unknown","speaker_refinement_anchor_without_resolvable_key_excludes_old_slot")
    let foreignAnchor:[String:Any]=["id":"manual-anchor-parent:word:20000","parent":"manual-anchor-parent","session":session,"source":"remote","epoch":"remote-epoch","start":20.0,"end":20.5,"textSHA256":textSHA256("卯")]
    let foreignNames:[String:Any]=["schema":2,"session":session,"sentences":[:],"speakers":[],"assignments":[["id":foreignAnchor["id"]!,"key":["session":session,"source":"mic","epoch":"epoch-a","identity":"slot:1"]]],"runAnchors":[foreignAnchor]]
    try writeJSON(foreignNames,to:folder.appendingPathComponent("session-names.json"))
    let foreignProjection=try SpeakerRefinementArtifact.alignmentEvents(directory:folder,session:session,events:[slotOneEvidence,anchoredRaw])
    let foreignRuns=foreignProjection[1]["speaker_runs"] as! [[String:Any]]
    try check((foreignRuns[0]["speaker"] as? [String:Any])?["basis"] as? String=="unknown","speaker_refinement_cross_scope_anchor_cannot_leave_old_slot_as_alignment")
    try FileManager.default.removeItem(at:folder.appendingPathComponent("session-names.json"))

    let foreignParentNames:[String:Any]=["schema":2,"session":session,"sentences":[:],"speakers":[],"assignments":[["id":"manual-anchor-parent","key":["session":session,"source":"remote","epoch":"epoch-a","identity":"slot:1"]]],"runAnchors":[]]
    try writeJSON(foreignParentNames,to:folder.appendingPathComponent("session-names.json"))
    let parentProjection=try SpeakerRefinementArtifact.alignmentEvents(directory:folder,session:session,events:[slotOneEvidence,anchoredRaw])
    try check((parentProjection[1]["speaker_runs"] as! [[String:Any]]).allSatisfy{($0["speaker"] as? [String:Any])?["basis"] as? String=="unknown"},"speaker_refinement_unresolved_parent_assignment_excludes_all_old_run_slots")
    var noRunsAnchor=anchoredRaw;noRunsAnchor.removeValue(forKey:"speaker_runs");noRunsAnchor["speaker"]=known
    try writeJSON(fullAnchorNames,to:folder.appendingPathComponent("session-names.json"))
    let parentOnlyProjection=try SpeakerRefinementArtifact.alignmentEvents(directory:folder,session:session,events:[slotOneEvidence,noRunsAnchor])
    try check((parentOnlyProjection[1]["speaker"] as? [String:Any])?["basis"] as? String=="unknown","speaker_refinement_anchored_unsplit_parent_not_used_with_old_slot")
    try FileManager.default.removeItem(at:folder.appendingPathComponent("session-names.json"))

    let remappedRuns:[[String:Any]]=[["start":13.0,"end":14.0,"text":"壬","speaker":slotOne],["start":14.0,"end":15.0,"text":"癸","speaker":slotOne]]
    let remapRecord=try record(for:remapEvent,runs:remappedRuns)
    let offlineObject=try artifact([remapRecord],method:SpeakerRefinementArtifact.offlineMethod,model:SpeakerRefinementArtifact.offlineModel)
    let offlineProjection=try SpeakerRefinementArtifact.validateApply(object:offlineObject,events:remapEvents,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)
    let offlineMappedRuns=offlineProjection[4]["speaker_runs"] as! [[String:Any]]
    try check(equalJSON(offlineMappedRuns[0]["speaker"],slotOne) && equalJSON(offlineMappedRuns[1]["speaker"],slotOne),"speaker_refinement_community1_remaps_anonymous_to_existing_same_scope_slot")
    try rejected("speaker_refinement_legacy_fast128_cannot_remap_existing_anonymous_slot"){_ = try SpeakerRefinementArtifact.validateApply(object:try artifact([remapRecord]),events:remapEvents,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)}
    let offlineKnownChange=try artifact([knownRecord],method:SpeakerRefinementArtifact.offlineMethod,model:SpeakerRefinementArtifact.offlineModel)
    let offlineKnownProjection=try SpeakerRefinementArtifact.validateApply(object:offlineKnownChange,events:remapEvents,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)
    try check(equalJSON(offlineKnownProjection[1]["speaker"],slotOne),"speaker_refinement_community1_can_correct_existing_automatic_slot")
    var pairMismatch=offlineObject;pairMismatch["model"]=SpeakerRefinementArtifact.model
    try rejected("speaker_refinement_method_model_pair_must_match"){_ = try SpeakerRefinementArtifact.validateApply(object:pairMismatch,events:remapEvents,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)}
    pairMismatch=offlineObject;pairMismatch["method"]=SpeakerRefinementArtifact.method
    try rejected("speaker_refinement_legacy_method_cannot_claim_community_model"){_ = try SpeakerRefinementArtifact.validateApply(object:pairMismatch,events:remapEvents,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)}
    var crossRemapRuns=remappedRuns;crossRemapRuns[0]["speaker"]=["basis":"anonymous_cluster","cluster_id":1,"source_id":"remote","epoch":"epoch-a"]
    let crossRemap=try artifact([record(for:remapEvent,runs:crossRemapRuns)],method:SpeakerRefinementArtifact.offlineMethod,model:SpeakerRefinementArtifact.offlineModel)
    try rejected("speaker_refinement_community1_cross_source_remap_rejected"){_ = try SpeakerRefinementArtifact.validateApply(object:crossRemap,events:remapEvents,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)}

    let manualRunID=TranscriptTimeline.runID(parent:"automatic-remap",run:(remapEvent["speaker_runs"] as! [[String:Any]])[0])
    let manualRunNames:[String:Any]=["schema":2,"session":session,"sentences":[:],"speakers":[],"assignments":[["id":manualRunID,"key":["session":session,"source":"mic","epoch":"epoch-a","identity":"slot:0"]]],"runAnchors":[]]
    try writeJSON(manualRunNames,to:folder.appendingPathComponent("session-names.json"))
    let protectedRemap=try SpeakerRefinementArtifact.validateApply(object:offlineObject,events:remapEvents,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)
    let protectedRemapRuns=protectedRemap[4]["speaker_runs"] as! [[String:Any]]
    try check(equalJSON(protectedRemapRuns[0]["speaker"],known) && equalJSON(protectedRemapRuns[1]["speaker"],slotOne),"speaker_refinement_community1_preserves_manual_run_and_remaps_unprotected_neighbor")
    try FileManager.default.removeItem(at:folder.appendingPathComponent("session-names.json"))

    try rejected("speaker_refinement_community1_cannot_invent_a_new_slot"){let impossible=try artifact([record(for:remapEvent,runs:[["start":13.0,"end":14.0,"text":"壬","speaker":changedUnknown(7)["speaker"] as! [String:Any]],["start":14.0,"end":15.0,"text":"癸","speaker":changedUnknown(7)["speaker"] as! [String:Any]]])],method:SpeakerRefinementArtifact.offlineMethod,model:SpeakerRefinementArtifact.offlineModel);_ = try SpeakerRefinementArtifact.validateApply(object:impossible,events:remapEvents,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)}
    var cross=changedUnknown();cross["speaker"]=["basis":"anonymous_cluster","cluster_id":0,"source_id":"remote","epoch":"epoch-a"]
    badRecords=(object["records"] as! [[String:Any]]);badRecords[0]["speaker_runs"]=[cross,runKnown];bad=object;bad["records"]=badRecords
    try rejected("speaker_refinement_cross_source_slot_rejected"){_ = try SpeakerRefinementArtifact.validateApply(object:bad,events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)}
    badRecords=(object["records"] as! [[String:Any]]);badRecords[0]["speaker_runs"]=[changedUnknown(7),runKnown];bad=object;bad["records"]=badRecords
    try rejected("speaker_refinement_unknown_slot_rejected"){_ = try SpeakerRefinementArtifact.validateApply(object:bad,events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)}

    let priorSnapshot=try SpeakerRefinementArtifact.snapshotSHA256(directory:folder,cacheID:cacheID,sourceHashes:sourceHashes)
    try writeJSON(["schema":1,"session":session,"title":"后来改名"],to:meetingURL)
    try check(try SpeakerRefinementArtifact.snapshotSHA256(directory:folder,cacheID:cacheID,sourceHashes:sourceHashes) != priorSnapshot,"speaker_refinement_meeting_metadata_change_invalidates_snapshot")
    let fallback=SpeakerRefinementArtifact.loadApply(events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)
    try check(fallback[0]["speaker_refinement_warning"] as? String != nil && equalJSON(fallback[0]["speaker_runs"],target["speaker_runs"]),"speaker_refinement_stale_sidecar_falls_back_with_warning")
    let beforeLegacy=try SpeakerRefinementArtifact.snapshotSHA256(directory:folder,cacheID:cacheID,sourceHashes:sourceHashes)
    try Data("legacy annotation".utf8).write(to:folder.appendingPathComponent("speaker-reconciliation.json"))
    try check(try SpeakerRefinementArtifact.snapshotSHA256(directory:folder,cacheID:cacheID,sourceHashes:sourceHashes) != beforeLegacy,"speaker_refinement_legacy_sidecar_change_invalidates_snapshot")

    let tailManifest:[String:Any]=["schema":1,"track":"mic","ended":false,"chunks":[["index":0,"bytes":pcm.count]]]
    try writeJSON(tailManifest,to:manifestURL)
    let beforeTail=try SpeakerRefinementArtifact.snapshotHashes(directory:folder,cacheID:cacheID,sourceHashes:sourceHashes)
    try check(beforeTail["snapshot-tail/mic-000000.pcm"]?.hasPrefix("4:")==true,"speaker_refinement_unsealed_tail_binds_chunk_length_and_hash")
    try Data([1,2,3,5]).write(to:pcmURL)
    var recoveredTail=tailManifest
    recoveredTail["ended"]=true;recoveredTail["error"]="cache_unclean_shutdown"
    recoveredTail["written_bytes"]=pcm.count;recoveredTail["asr_committed_bytes"]=pcm.count
    try writeJSON(recoveredTail,to:manifestURL)
    let recoveredSnapshot=try SpeakerRefinementArtifact.snapshotHashes(directory:folder,cacheID:cacheID,sourceHashes:sourceHashes)
    try check(recoveredSnapshot["snapshot-tail/mic-000000.pcm"] != beforeTail["snapshot-tail/mic-000000.pcm"],"recovered_unsealed_tail_is_hashed_and_content_changes_are_detected")
    var malformedTail=recoveredTail
    malformedTail["chunks"]=[["index":0,"bytes":pcm.count,"sha256":NSNull()]]
    try writeJSON(malformedTail,to:manifestURL)
    try rejected("malformed_digest_is_not_treated_as_missing_recovered_tail_hash"){_ = try SpeakerRefinementArtifact.snapshotHashes(directory:folder,cacheID:cacheID,sourceHashes:sourceHashes)}
    recoveredTail["asr_committed_bytes"]=0;try writeJSON(recoveredTail,to:manifestURL)
    try rejected("recovered_tail_requires_completed_transcription"){_ = try SpeakerRefinementArtifact.snapshotHashes(directory:folder,cacheID:cacheID,sourceHashes:sourceHashes)}
    recoveredTail["asr_committed_bytes"]=pcm.count;recoveredTail["error"]="cache_transcript_write_failed";try writeJSON(recoveredTail,to:manifestURL)
    try rejected("damaged_tail_cannot_use_recovery_exception"){_ = try SpeakerRefinementArtifact.snapshotHashes(directory:folder,cacheID:cacheID,sourceHashes:sourceHashes)}
    try writeJSON(tailManifest,to:manifestURL)
    let afterTail=try SpeakerRefinementArtifact.snapshotHashes(directory:folder,cacheID:cacheID,sourceHashes:sourceHashes)
    try check(beforeTail["snapshot-tail/mic-000000.pcm"] != afterTail["snapshot-tail/mic-000000.pcm"],"speaker_refinement_unsealed_tail_change_invalidates_snapshot")

    let outside=root.appendingPathComponent("outside.json");try Data("{}".utf8).write(to:outside)
    let artifactFile=artifactURL
    try FileManager.default.removeItem(at:artifactFile)
    try FileManager.default.createSymbolicLink(at:artifactFile,withDestinationURL:outside)
    try rejected("speaker_refinement_prepared_commit_rejects_replaced_symlink") {try SpeakerRefinementArtifact.writePrepared(prepared)}
    let symlinkFallback=SpeakerRefinementArtifact.loadApply(events:events,sourceHashes:sourceHashes,directory:folder,cacheID:cacheID)
    try check(symlinkFallback[0]["speaker_refinement_warning"] as? String != nil,"speaker_refinement_sidecar_symlink_is_rejected")
    try FileManager.default.removeItem(at:artifactFile)
    let alias=root.appendingPathComponent("parent-link",isDirectory:true)
    try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:root)
    let aliased=alias.appendingPathComponent(cacheID,isDirectory:true)
    try rejected("speaker_refinement_symlink_parent_is_rejected"){_ = try SpeakerRefinementArtifact.snapshotSHA256(directory:aliased,cacheID:cacheID,sourceHashes:sourceHashes)}

    return checks
}
