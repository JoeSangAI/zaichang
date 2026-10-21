import Foundation

func speakerRefinementChecks()->[String] {
    let source="mic",epoch="refine-epoch",session="refine-session"
    func who(_ slot:Int)->[String:Any]{["basis":"anonymous_cluster","cluster_id":slot,"source_id":source,"epoch":epoch]}
    func event(_ id:String,_ lo:Double,_ hi:Double,_ speaker:[String:Any])->[String:Any]{["type":"segment","segment_id":id,"session":session,"source_id":source,"epoch":epoch,"start":lo,"end":hi,"end_time_known":true,"final":true,"text":"测试","speaker":speaker,"revision":1]}
    var timeline=SpeakerTimeline()
    timeline.append((0..<700).map{SpeakerFrame(sourceID:source,epoch:epoch,revision:1,start:Double($0)/100,end:Double($0+1)/100,activeSlots:[2])})
    let anchors=[event("a",0,1,who(0)),event("b",2,3,who(0))]
    precondition(SpeakerRefinement.mapping(events:anchors,timeline:timeline,source:source,epoch:epoch)==[2:0])
    precondition(SpeakerRefinement.mapping(events:[anchors[0]],timeline:timeline,source:source,epoch:epoch).isEmpty)
    let conflict=anchors+[event("c",4,5,who(1))]
    precondition(SpeakerRefinement.mapping(events:conflict,timeline:timeline,source:source,epoch:epoch).isEmpty)
    var inferred=anchors[1];var s=who(0);s["contextual_fill"]=true;inferred["speaker"]=s
    precondition(SpeakerRefinement.mapping(events:[anchors[0],inferred],timeline:timeline,source:source,epoch:epoch).isEmpty)
    let unknown=event("u",5,6,["basis":"unknown","reason":"slot_not_matured"])
    let records=try! SpeakerRefinement.corrections(events:anchors+[unknown],timeline:timeline,source:source,epoch:epoch)
    precondition(records.count==1 && records[0]["segment_id"] as? String=="u")
    precondition((records[0]["speaker"] as? [String:Any])?["cluster_id"] as? Int==0)
    precondition(try! SpeakerRefinement.corrections(events:anchors,timeline:timeline,source:source,epoch:epoch).isEmpty)
    var partial=unknown;partial["final"]=false
    precondition(try! SpeakerRefinement.corrections(events:anchors+[partial],timeline:timeline,source:source,epoch:epoch).isEmpty)
    var untimed=unknown;untimed["end_time_known"]=false
    precondition(try! SpeakerRefinement.corrections(events:anchors+[untimed],timeline:timeline,source:source,epoch:epoch).isEmpty)
    var overlap=unknown;overlap["speaker"]=["basis":"multiple","reason":"overlap","cluster_ids":[0,1]]
    precondition(try! SpeakerRefinement.corrections(events:anchors+[overlap],timeline:timeline,source:source,epoch:epoch).isEmpty)
    precondition(try! SpeakerRefinement.corrections(events:anchors+[unknown],timeline:timeline,source:source,epoch:epoch,protectedIDs:["u"]).isEmpty)
    let empty=SpeakerTimeline()
    precondition(try! SpeakerRefinement.corrections(events:anchors+[unknown],timeline:empty,source:source,epoch:epoch).isEmpty)
    var foreign=unknown;foreign["epoch"]="other"
    precondition(try! SpeakerRefinement.corrections(events:anchors+[foreign],timeline:timeline,source:source,epoch:epoch).isEmpty)
    let whole=WholeMeetingSpeakerTimeline(segments:[OfflineSpeakerSegment(start:0,end:10,speakerID:"S7")],origin:0,duration:10)
    let longAnchors=[event("la",0,1.5,who(0)),event("lb",2,3.5,who(0)),event("lc",4,5.5,who(0))]
    let short=event("short",6,6.16,["basis":"unknown","reason":"no_speaker_evidence"])
    let mislabeled=event("wrong",7,7.2,who(1))
    let wholeRecords=try! WholeMeetingSpeakerRefinement.corrections(events:longAnchors+[short,mislabeled],timeline:whole,source:source,epoch:epoch,protectedIDs:[])
    precondition(wholeRecords.count==2 && wholeRecords.allSatisfy{($0["speaker"] as? [String:Any])?["cluster_id"] as? Int==0})
    precondition(try! WholeMeetingSpeakerRefinement.corrections(events:longAnchors+[short,mislabeled],timeline:whole,source:source,epoch:epoch,protectedIDs:["short","wrong"]).isEmpty)
    let disputed=WholeMeetingSpeakerTimeline(segments:[OfflineSpeakerSegment(start:0,end:10,speakerID:"S7"),OfflineSpeakerSegment(start:6,end:6.16,speakerID:"S8")],origin:0,duration:10)
    precondition(try! WholeMeetingSpeakerRefinement.corrections(events:longAnchors+[short],timeline:disputed,source:source,epoch:epoch,protectedIDs:[]).isEmpty)
    let silence=WholeMeetingSpeakerTimeline(segments:[OfflineSpeakerSegment(start:0,end:5.5,speakerID:"S7")],origin:0,duration:10)
    precondition(try! WholeMeetingSpeakerRefinement.corrections(events:longAnchors+[short],timeline:silence,source:source,epoch:epoch,protectedIDs:[]).isEmpty)
    let shifted=WholeMeetingSpeakerTimeline(segments:[OfflineSpeakerSegment(start:0,end:1,speakerID:"S7")],origin:5,duration:1)
    precondition(shifted.evidence(start:5,end:6).solo["S7"]==1 && shifted.evidence(start:0,end:1).solo.isEmpty)
    precondition(WholeMeetingSpeakerRefinement.mapping(events:longAnchors+[event("conflict",8,9,who(1))],timeline:whole,source:source,epoch:epoch).isEmpty)
    var noClock=short;noClock["end_time_known"]=false
    precondition(try! WholeMeetingSpeakerRefinement.corrections(events:longAnchors+[noClock],timeline:whole,source:source,epoch:epoch,protectedIDs:[]).isEmpty)
    let humanAligned=longAnchors.map { original -> [String:Any] in var row=original;row["speaker"]=who(1);return row }
    let humanAlignedOutput=try! WholeMeetingSpeakerRefinement.corrections(events:longAnchors+[short],timeline:whole,source:source,epoch:epoch,protectedIDs:["la","lb","lc"],alignmentEvents:humanAligned)
    precondition(humanAlignedOutput.count==1 && (humanAlignedOutput[0]["speaker"] as? [String:Any])?["cluster_id"] as? Int==1)
    var recovered=short;recovered["speaker"]=who(0)
    let kept=try! WholeMeetingSpeakerRefinement.preservingRecoveries(originals:longAnchors+[short],previous:longAnchors+[recovered],records:[])
    precondition(kept.count==1 && (kept[0]["speaker"] as? [String:Any])?["cluster_id"] as? Int==0)
    let stale=try! WholeMeetingSpeakerRefinement.preservingRecoveries(originals:longAnchors+[short],previous:longAnchors+[short],records:[])
    precondition(stale.isEmpty)
    return ["human_corrected_anchor_targets_drive_identity_alignment","previous_valid_unknown_recovery_preserved_without_becoming_anchor","invalid_previous_recovery_does_not_enter_output"] + ["whole_meeting_independent_cluster_matches_existing_identity", "whole_meeting_short_reply_and_wrong_automatic_label_corrected", "whole_meeting_human_labels_immutable", "whole_meeting_overlap_not_forced_single", "whole_meeting_silence_not_invented", "whole_meeting_origin_applied_once", "whole_meeting_competing_anchor_rejected", "whole_meeting_missing_clock_preserved"] + ["independent_model_slots_align_by_evidence","one_anchor_rejected","conflicting_existing_voices_not_merged","inferred_labels_not_anchors","unknown_promoted_only_to_supported_existing_slot","known_text_and_identity_preserved","partial_not_invented","missing_clock_not_invented","overlap_preserved","silent_evidence_not_assigned","foreign_epoch_not_assigned","human_confirmed_utterance_excluded"]
}
