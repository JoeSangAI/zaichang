import Foundation

func speakerReviewChecks()->Int {
    var checks=0
    func item(_ id:String,_ slot:Int?,source:String="remote",epoch:String="epoch",text:String="发言",start:Double=0)->[String:Any] {
        var speaker:[String:Any]=["basis":"unknown","reason":"no_speaker_evidence"]
        if let slot=slot {speaker=["basis":"anonymous_cluster","cluster_id":slot,"source_id":source,"epoch":epoch]}
        return ["segment_id":id,"session":"review-session","source_id":source,"epoch":epoch,
                "start":start,"end":start+0.5,"text":text,"speaker":speaker]
    }
    func turn(_ id:String,_ parts:[(String,[String:Any])],uncertain:Bool=false)->ReadingTurn {
        var value=parts.first?.1 ?? item(id,nil)
        value["segment_id"]=id;value["parent_segment_id"]=id
        value["start"]=parts.first? .1["start"] as? Double ?? 0
        value["end"]=parts.last? .1["end"] as? Double ?? 0.5
        value["text"]=parts.map{$0.1["text"] as? String ?? ""}.joined()
        return ReadingTurn(id:id,parent:id,item:value,parts:parts,uncertain:uncertain)
    }

    var names=SessionNames()
    let contaminatedA=item("a1",0,text:"甲",start:0),contaminatedB=item("a2",0,text:"乙",start:2)
    let targetItem=item("b1",1,text:"丙",start:1)
    let sameNameItem=item("c1",2,text:"丁",start:3)
    let unknownA=item("u1",nil,text:"嗯",start:4),unknownB=item("u2",nil,text:"啊",start:5)
    let micItem=item("mic1",0,source:"mic",epoch:"mic-epoch",text:"麦克风发言",start:6)
    let sourceItems=[contaminatedA,contaminatedB,targetItem,sameNameItem,unknownA,unknownB,micItem]
    for value in sourceItems {names.register(segment:value["segment_id"] as! String,item:value)}
    let keyA=names.key(segment:"a1")!,keyB=names.key(segment:"b1")!,keyC=names.key(segment:"c1")!,keyMic=names.key(segment:"mic1")!
    var unpinned=names
    let noopRevision=unpinned.correctionRevision
    check(!unpinned.assignBatch(segmentIDs:["a1"],to:keyA,humanConfirmed:true) &&
          !unpinned.assign(segment:"a1",to:keyA,humanConfirmed:true) && unpinned.correctionRevision==noopRevision,"same-person assignment creates no history or model pin")
    unpinned.register(segment:"a1",item:item("a1",1))
    check(unpinned.key(segment:"a1")==keyB,"no-op assignment permits later model correction")
    var partial=names
    check(partial.assignBatch(segmentIDs:["a1","b1"],to:keyB,humanConfirmed:true),"mixed selection assigns changed parts")
    partial.register(segment:"b1",item:item("b1",2))
    partial.register(segment:"a1",item:item("a1",2))
    check(partial.key(segment:"b1")==keyC && partial.key(segment:"a1")==keyB,"mixed batch pins changed parts only")
    checks+=4
    names.setSpeaker(segment:"a1",name:"同名")
    names.setSpeaker(segment:"c1",name:"同名")
    names.setSpeaker(segment:"mic1",name:"同名")

    let ordinary=[turn("a1",[("a1",contaminatedA)]),turn("a2",[("a2",contaminatedB)]),
                  turn("b1",[("b1",targetItem)]),turn("c1",[("c1",sameNameItem)]),
                  turn("u1",[("u1",unknownA)]),turn("u2",[("u2",unknownB)]),turn("mic1",[("mic1",micItem)])]
    let review=SpeakerReviewIndex.build(session:"review-session",turns:ordinary,names:names)
    let sameNamePerson=review.people.first(where:{$0.key==keyA})
    check(review.people.count==2 && sameNamePerson?.entries.map(\.id)==["a1","a2","c1","mic1"],"same manually confirmed person is one review choice with merged turns")
    check(Set(sameNamePerson?.keys ?? [])==Set([keyA,keyC,keyMic]) && names.key(segment:"a1")==keyA && names.key(segment:"c1")==keyC && names.key(segment:"mic1")==keyMic,
          "same-name presentation grouping retains distinct source identity keys")
    check(review.unassigned.map(\.id)==["u1","u2"] && review.unassigned.allSatisfy{$0.personKey==nil},"unknown turns remain separate")
    checks+=3

    let mixed=turn("mixed",[("a1",contaminatedA),("u1",unknownA)],uncertain:true)
    let mixedReview=SpeakerReviewIndex.build(session:"review-session",turns:[mixed],names:names)
    let mixedKnown=mixedReview.people.first(where:{$0.key==keyA})?.entries.first
    let mixedUnknown=mixedReview.unassigned.first
    check(mixedKnown?.partIDs==["a1","u1"] && mixedKnown?.unresolvedPartIDs==["u1"] && mixedKnown?.turn.parts.map{$0.0}==["a1","u1"],
          "single known person retains full mixed-turn context and marks unknown part")
    check(mixedReview.unassigned.count==1 && mixedUnknown?.possiblePeople==[keyA] && mixedUnknown?.partIDs==["u1"] && mixedUnknown?.turn.parts.map{$0.0}==["u1"] && mixedUnknown?.start==4 && mixedUnknown?.end==4.5 && mixedUnknown?.text=="嗯",
          "unassigned projection contains only actual unknown part")

    let multi=turn("multi",[("a1",contaminatedA),("b1",targetItem),("u1",unknownA)],uncertain:true)
    let multiReview=SpeakerReviewIndex.build(session:"review-session",turns:[multi],names:names)
    check(multiReview.people.first(where:{$0.key==keyA})?.entries.first?.partIDs==["a1"] &&
          multiReview.people.first(where:{$0.key==keyB})?.entries.first?.partIDs==["b1"] &&
          multiReview.unassigned.map(\.partIDs)==[["u1"]],"multi-person turn is grouped by known part and unknown remains isolated")
    checks+=3

    var overlapNames=SessionNames()
    let overlapSlot0=item("overlap-slot-0",0,text:"甲发言",start:10)
    let overlapSlot1=item("overlap-slot-1",1,text:"乙发言",start:10)
    overlapNames.register(segment:"overlap-slot-0",item:overlapSlot0);overlapNames.register(segment:"overlap-slot-1",item:overlapSlot1)
    let overlapKey0=overlapNames.key(segment:"overlap-slot-0")!,overlapKey1=overlapNames.key(segment:"overlap-slot-1")!
    overlapNames.setSpeaker(segment:"overlap-slot-0",name:"甲")
    overlapNames.setSpeaker(segment:"overlap-slot-1",name:"乙")
    var overlapItem=item("overlap-turn",nil,text:"两人同时说话",start:11)
    overlapItem["speaker"]=["basis":"multiple","reason":"overlap","cluster_ids":[0,1]]
    overlapNames.register(segment:"overlap-turn",item:overlapItem)
    let overlapTurn=turn("overlap-turn",[("overlap-turn",overlapItem)])
    let overlapReview=SpeakerReviewIndex.build(session:"review-session",turns:[overlapTurn],names:overlapNames)
    check(overlapReview.unassigned.isEmpty && overlapReview.simultaneous.map(\.id)==["overlap-turn"] &&
          overlapReview.people.isEmpty && overlapReview.simultaneous.first?.text=="两人同时说话" &&
          SpeakerReviewIndex.simultaneousTitle(overlapReview.simultaneous[0],names:overlapNames)=="甲、乙 · 同时发言",
          "manually named overlap is separated, names both participants, and preserves the original turn without counting it as a single person")
    var samePersonOverlapNames=SessionNames()
    for (id,value) in [("overlap-slot-0",overlapSlot0),("overlap-slot-1",overlapSlot1)] {
        samePersonOverlapNames.register(segment:id,item:value);samePersonOverlapNames.setSpeaker(segment:id,name:"张三")
    }
    var samePersonOverlapItem=overlapItem;samePersonOverlapItem["speaker"]=["basis":"multiple","reason":"overlap","cluster_ids":[0,1]]
    samePersonOverlapNames.register(segment:"overlap-turn",item:samePersonOverlapItem)
    let samePersonOverlap=SpeakerReviewIndex.build(session:"review-session",turns:[turn("overlap-turn",[("overlap-turn",samePersonOverlapItem)])],names:samePersonOverlapNames)
    check(samePersonOverlap.simultaneous.isEmpty && samePersonOverlap.unassigned.isEmpty &&
          samePersonOverlap.people.first?.title=="张三" && samePersonOverlap.people.first?.entries.map(\.id)==["overlap-turn"] &&
          SpeakerReviewIndex.simultaneousTitle(item:samePersonOverlapItem,session:"review-session",names:samePersonOverlapNames)=="张三",
          "same manually confirmed name across diarizer slots is one person, not false simultaneous speech")
    var oneUnnamed=SessionNames()
    oneUnnamed.register(segment:"overlap-slot-0",item:overlapSlot0);oneUnnamed.register(segment:"overlap-slot-1",item:overlapSlot1)
    oneUnnamed.setSpeaker(segment:"overlap-slot-0",name:"甲")
    let unknownOverlap=SpeakerReviewIndex.build(session:"review-session",turns:[overlapTurn],names:oneUnnamed)
    check(unknownOverlap.simultaneous.isEmpty && unknownOverlap.unassigned.map(\.id)==["overlap-turn"] &&
          unknownOverlap.unassigned[0].reason=="overlap" &&
          SpeakerReviewIndex.simultaneousTitle(item:overlapItem,session:"review-session",names:oneUnnamed)==nil,
          "overlap stays unknown unless every participant has an explicit manual name")
    var foreignOverlap=overlapItem;foreignOverlap["segment_id"]="foreign-overlap";foreignOverlap["session"]="another-session"
    var wrongEpochOverlap=overlapItem;wrongEpochOverlap["segment_id"]="wrong-epoch-overlap";wrongEpochOverlap["epoch"]="another-epoch"
    let crossScopeReview=SpeakerReviewIndex.build(session:"review-session",
        turns:[turn("foreign-overlap",[("foreign-overlap",foreignOverlap)]),turn("wrong-epoch-overlap",[("wrong-epoch-overlap",wrongEpochOverlap)])],names:overlapNames)
    check(crossScopeReview.simultaneous.isEmpty && crossScopeReview.unassigned.map(\.id)==["foreign-overlap","wrong-epoch-overlap"] &&
          SpeakerReviewIndex.simultaneousTitle(item:foreignOverlap,session:"review-session",names:overlapNames)==nil &&
          SpeakerReviewIndex.simultaneousTitle(item:wrongEpochOverlap,session:"review-session",names:overlapNames)==nil,
          "overlap participant mapping cannot cross meeting or source epoch")
    var correctedOverlapNames=overlapNames
    check(correctedOverlapNames.assign(segment:"overlap-turn",to:overlapKey0,humanConfirmed:true),"overlap can be manually corrected to one person")
    let correctedOverlap=SpeakerReviewIndex.build(session:"review-session",turns:[overlapTurn],names:correctedOverlapNames)
    check(correctedOverlap.people.first(where:{$0.key==overlapKey0})?.entries.map(\.id)==["overlap-turn"] &&
          correctedOverlap.simultaneous.isEmpty && correctedOverlap.unassigned.isEmpty,
          "explicit single-person correction leaves the simultaneous filter")
    var labeledOverlapNames=overlapNames
    check(labeledOverlapNames.confirmSegments(["overlap-turn"],name:"单句人工标签",learn:false),"single overlap row can receive an explicit human label")
    let labeledOverlap=SpeakerReviewIndex.build(session:"review-session",turns:[overlapTurn],names:labeledOverlapNames)
    check(labeledOverlap.simultaneous.isEmpty && labeledOverlap.unassigned.map(\.id)==["overlap-turn"] &&
          labeledOverlap.unassigned.first?.reason=="overlap","manual single-row label removes an overlap from the named-participant filter")
    var semanticOverlapNames=SessionNames()
    func introduction(_ id:String,_ start:Double)->[String:Any] {
        var value=overlapSlot0;value["segment_id"]=id;value["start"]=start;value["end"]=start+1.0
        value["text"]="我叫张三。";value["revision"]=1;value["final"]=true;value["end_time_known"]=true;value["quality_flags"]=[]
        return value
    }
    let introA=introduction("intro-a",20),introB=introduction("intro-b",25)
    semanticOverlapNames.register(segment:"intro-a",item:introA);_=semanticOverlapNames.observeSemanticName(introA)
    semanticOverlapNames.register(segment:"intro-b",item:introB);_=semanticOverlapNames.observeSemanticName(introB)
    semanticOverlapNames.register(segment:"overlap-slot-1",item:overlapSlot1);semanticOverlapNames.setSpeaker(segment:"overlap-slot-1",name:"乙")
    var semanticOverlap=overlapItem;semanticOverlap["segment_id"]="semantic-overlap"
    semanticOverlapNames.register(segment:"semantic-overlap",item:semanticOverlap)
    check(semanticOverlapNames.displayName(speaker:semanticOverlapNames.key(segment:"intro-a")!)?.origin == .semantic &&
          SpeakerReviewIndex.build(session:"review-session",turns:[turn("semantic-overlap",[("semantic-overlap",semanticOverlap)])],names:semanticOverlapNames).unassigned.map(\.id)==["semantic-overlap"] &&
          SpeakerReviewIndex.simultaneousTitle(item:semanticOverlap,session:"review-session",names:semanticOverlapNames)==nil,
          "semantic-name candidates do not resolve overlap participants as confirmed people")
    var voiceOverlapNames=SessionNames(),voiceEvidence:[VoiceprintEvidenceRef]=[]
    for i in 0..<3 {
        let id="voice-overlap-\(i)";var evidence=overlapSlot0;evidence["segment_id"]=id;evidence["revision"]=1
        voiceOverlapNames.register(segment:id,item:evidence);voiceEvidence.append(VoiceprintEvidenceRef(id:id,revision:1))
    }
    let voiceKey=voiceOverlapNames.key(segment:"voice-overlap-0")!
    let voiceCandidate=VoiceprintRecommendation(personID:UUID().uuidString,name:"声音候选",archiveRevision:1,evidenceCount:3,support:voiceEvidence)
    _=voiceOverlapNames.reconcileAutoVoiceprint(key:voiceKey,candidate:voiceCandidate)
    voiceOverlapNames.register(segment:"overlap-slot-1",item:overlapSlot1);voiceOverlapNames.setSpeaker(segment:"overlap-slot-1",name:"乙")
    var voiceOverlap=overlapItem;voiceOverlap["segment_id"]="voice-overlap-turn"
    voiceOverlapNames.register(segment:"voice-overlap-turn",item:voiceOverlap)
    check(voiceOverlapNames.displayName(speaker:voiceKey)?.origin == .voiceprint &&
          SpeakerReviewIndex.build(session:"review-session",turns:[turn("voice-overlap-turn",[("voice-overlap-turn",voiceOverlap)])],names:voiceOverlapNames).unassigned.map(\.id)==["voice-overlap-turn"] &&
          SpeakerReviewIndex.simultaneousTitle(item:voiceOverlap,session:"review-session",names:voiceOverlapNames)==nil,
          "voiceprint candidates do not resolve overlap participants as confirmed people")
    _=overlapKey0;_=overlapKey1
    checks+=10

    check(!names.assignBatch(segmentIDs:["a1","a2"],to:keyB,humanConfirmed:false),"batch assignment requires explicit confirmation")
    let beforeBatchRevision=names.correctionRevision
    check(names.assignBatch(segmentIDs:["a1","a2"],to:keyB,humanConfirmed:true),"selected utterances can move together")
    check(names.key(segment:"a1")==keyB && names.key(segment:"a2")==keyB && names.key(segment:"b1")==keyB && names.key(segment:"c1")==keyC && names.correctionRevision==beforeBatchRevision+1,"batch assignment leaves unselected contamination intact")
    // A later provider revision cannot overwrite the explicitly corrected identity.
    names.register(segment:"a1",item:item("a1",7,text:"模型修订",start:0))
    check(names.key(segment:"a1")==keyB,"manual assignment survives provider revision")
    let batchUndoID=names.undo()
    check(batchUndoID != nil && names.lastUndoSegmentIDs==["a1","a2"] && names.key(segment:"a1")==keyA && names.key(segment:"a2")==keyA,"one undo atomically restores selected assignments")
    checks+=4

    check(names.assignBatch(segmentIDs:["u1"],to:keyB,humanConfirmed:true) && names.key(segment:"u1")==keyB && names.key(segment:"u2")==nil,
          "selected unknown part can be assigned without identifying its neighbor")
    let partialSnapshot=try! names.snapshot(session:"review-session")
    var partialReload=SessionNames()
    for value in sourceItems {partialReload.register(segment:value["segment_id"] as! String,item:value)}
    try! partialReload.restore(partialSnapshot,session:"review-session")
    check(partialReload.key(segment:"u1")==keyB && partialReload.key(segment:"u2")==nil,"selected assignment persists without absorbing unknown neighbor")
    names.undo()
    check(names.key(segment:"u1")==nil && names.key(segment:"u2")==nil,"unknown-part assignment undo")
    checks+=3

    names.set(segment:"a2",name:"单句名")
    check(names.renameSpeaker(key:keyA,name:"整组名") && names.name(segment:"a1")=="整组名" && names.name(segment:"a2")=="整组名","group rename applies across associated turns")
    check(names.key(segment:"u1")==nil && names.name(segment:"u1")==nil,"group rename does not absorb unresolved parts from mixed context")
    names.undo()
    check(names.lastUndoSegmentIDs==["a1","a2"] && names.name(segment:"a1")=="同名" && names.name(segment:"a2")=="单句名","group rename undo restores per-turn overrides")
    checks+=3

    names.setSpeaker(segment:"mic1",name:"远端姓名")
    check(!names.mergeSpeaker(from:keyMic,to:keyA,humanConfirmed:false),"cross-source merge requires explicit confirmation")
    check(names.mergeSpeaker(from:keyMic,to:keyA,humanConfirmed:true),"explicit same-meeting cross-source merge")
    check(names.key(segment:"mic1")==keyA && names.displayLabel(speaker:keyMic)==names.displayLabel(speaker:keyA) && names.name(segment:"mic1")=="同名" && names.key(segment:"u1")==nil,
          "merge resolves only known identity parts and leaves mixed-turn unknown untouched")
    let saved=try! names.snapshot(session:"review-session")
    var reopened=SessionNames()
    for value in sourceItems {reopened.register(segment:value["segment_id"] as! String,item:value)}
    try! reopened.restore(saved,session:"review-session")
    check(reopened.key(segment:"mic1")==reopened.key(segment:"a1") && reopened.name(segment:"a1")=="同名","merged identity persists after reopening")
    check(reopened.undo() != nil && reopened.key(segment:"mic1")==keyMic && reopened.key(segment:"a1")==keyA,"persisted undo restores only the original session mapping")
    names.undo()
    check(names.lastUndoSegmentIDs.contains("mic1") && names.lastUndoSegmentIDs.contains("a1") && names.key(segment:"mic1")==keyMic && names.key(segment:"a1")==keyA && names.name(segment:"mic1")=="远端姓名","merge undo atomically restores prior source name")
    checks+=6

    var multiKeyRename=names
    let renameRevision=multiKeyRename.correctionRevision
    check(multiKeyRename.renameSpeaker(keys:[keyA,keyC],name:"统一确认") &&
          multiKeyRename.name(speaker:keyA)=="统一确认" && multiKeyRename.name(speaker:keyC)=="统一确认" &&
          multiKeyRename.correctionRevision==renameRevision+1,
          "renaming a same-name presentation group updates every source key in one change")
    check(multiKeyRename.undo() != nil && multiKeyRename.name(speaker:keyA)=="同名" && multiKeyRename.name(speaker:keyC)=="同名" &&
          multiKeyRename.key(segment:"a1")==keyA && multiKeyRename.key(segment:"c1")==keyC,
          "grouped rename undo restores names without merging source identities")
    var multiKeyMerge=names
    check(multiKeyMerge.mergeSpeakers(from:[keyA,keyC],to:keyB,humanConfirmed:true) &&
          multiKeyMerge.key(segment:"a1")==keyB && multiKeyMerge.key(segment:"c1")==keyB,
          "explicit merge of a multi-key human choice applies to all its source keys")
    check(multiKeyMerge.undo() != nil && multiKeyMerge.key(segment:"a1")==keyA && multiKeyMerge.key(segment:"c1")==keyC,
          "multi-key explicit merge has one undo restoring source mappings")
    checks+=4

    let foreign=SessionSpeakerKey(session:"different-session",source:"mic",epoch:"mic-epoch",identity:"slot:0")
    check(!names.mergeSpeaker(from:keyA,to:foreign,humanConfirmed:true),"merge cannot cross meeting boundary")
    checks+=1

    // A single on-demand index build remains practical for a long session and
    // returns every complete turn in chronological order without changing source rows.
    var longTurns:[ReadingTurn]=[];longTurns.reserveCapacity(10_000)
    for index in (0..<10_000).reversed() {
        let row=item("long-\(index)",4,text:"片段\(index)",start:Double(index))
        longTurns.append(turn("long-\(index)",[("long-\(index)",row)]))
    }
    let began=ProcessInfo.processInfo.systemUptime
    let longReview=SpeakerReviewIndex.build(session:"review-session",turns:longTurns,names:names)
    let elapsed=ProcessInfo.processInfo.systemUptime-began
    let longPerson=longReview.people.first(where:{$0.key.identity=="slot:4"})
    check(longPerson?.entries.count==10_000 && longPerson?.entries.first?.start==0 && longPerson?.entries.last?.start==9_999 && elapsed<3,"10k-turn review index is chronological and bounded")
    check(longTurns.first?.item["start"] as? Double==9_999,"review index preserves source turn order and payload")
    checks+=2
    return checks
}

private func check(_ condition:@autoclosure ()->Bool,_ label:String) {
    precondition(condition(),"speaker review check failed: \(label)")
}
