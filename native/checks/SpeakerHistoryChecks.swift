import Foundation

// Deterministic, audio-free checks for the bounded compressed speaker timeline.
// The main build harness calls this explicitly; no capture, ASR, or model is loaded.
func speakerHistoryChecks() async throws -> [String:Any] {
    var passed=0
    func check(_ condition:@autoclosure ()->Bool,_ name:String) {
        precondition(condition(),"speaker history check failed: \(name)")
        passed+=1
    }
    func frame(_ start:Double,_ end:Double,_ slots:[Int],_ revision:Int=1,
               source:String="remote",epoch:String="history-check")->SpeakerFrame {
        SpeakerFrame(sourceID:source,epoch:epoch,revision:revision,start:start,end:end,activeSlots:slots)
    }
    func event(_ id:String,_ start:Double,_ end:Double,source:String="remote",epoch:String="history-check")->[String:Any] {
        ["segment_id":id,"source_id":source,"epoch":epoch,"start":start,"end":end,"end_time_known":true,"final":true,"text":"测试"]
    }

    var leveler=SpeakerInputLeveler()
    let quiet=[Float](repeating:0.0005,count:1600),raised=leveler.process(quiet)
    check(raised.count==quiet.count && raised.allSatisfy{abs($0-0.008)<1e-6},"quiet voice reaches recognizer without changing PCM length")
    check(leveler.process([Float](repeating:0,count:1600)).allSatisfy{$0==0},"silence is never fabricated by input gain")
    var loud=SpeakerInputLeveler();let loudInput:[Float]=[0.9,-0.99,0.6,-0.2]
    check(zip(loud.process(loudInput),loudInput).allSatisfy{abs($0.0)<=1 && abs($0.0)>=abs($0.1)},"recognition gain neither clips nor suppresses loud input")
    var whole=SpeakerInputLeveler(),parts=SpeakerInputLeveler();let signal=quiet+loudInput+quiet
    let combined=parts.process(Array(signal.prefix(533)))+parts.process(Array(signal.dropFirst(533)))
    check(whole.process(signal)==combined,"recognition gain is independent of packet boundaries")

    // A final ASR event arriving 309 seconds after its audio must still use its
    // original speaker evidence, including per-word attribution across a turn.
    var delayed=SpeakerTimeline();delayed.setHistoryOriginIfNeeded(0)
    for batchStart in stride(from:0,to:61_800,by:1_000) {
        let revision=batchStart/1_000+1
        let batch=(batchStart..<min(batchStart+1_000,61_800)).map {index -> SpeakerFrame in
            let start=Double(index)*SpeakerTimeline.frameDuration
            return frame(start,start+SpeakerTimeline.frameDuration,index<30_400 ? [0] : [1],revision)
        }
        delayed.append(batch)
    }
    var lateFinal=event("late-final",300,309);lateFinal["received_at"]=618.0
    let delayedResult=delayed.join(lateFinal,source:"remote",epoch:"history-check")
    check(delayedResult["basis"] as? String=="multiple" && delayedResult["reason"] as? String=="speaker_change","309-second delayed final")
    var delayedWords=event("late-word-spans",300,309)
    delayedWords["text"]="甲乙"
    delayedWords["word_spans"]=[["start":300.0,"end":304.0,"text":"甲"],["start":304.0,"end":309.0,"text":"乙"]]
    delayed.annotateWords(&delayedWords,source:"remote",epoch:"history-check")
    let wordRuns=delayedWords["speaker_runs"] as? [[String:Any]] ?? []
    check(wordRuns.count==2 && (wordRuns[0]["speaker"] as? [String:Any])?["cluster_id"] as? Int==0 &&
          (wordRuns[1]["speaker"] as? [String:Any])?["cluster_id"] as? Int==1,"late word-span attribution")
    check(delayed.retainedFrameCount==61_800 && delayed.compressedRunCount==2,"same-slot frame run compression")

    var trueGap=SpeakerTimeline()
    trueGap.append([frame(0,0.10,[0]),frame(0.20,0.30,[0])])
    check(trueGap.compressedRunCount==2 && trueGap.join(event("real-gap",0,0.30),source:"remote",epoch:"history-check")["reason"] as? String=="coverage_gap","real coverage gap retained")

    var single=SpeakerTimeline();single.append([frame(0,0.30,[3])])
    let provisional=single.join(event("single-provisional",0,0.30),source:"remote",epoch:"history-check")
    check(provisional["basis"] as? String=="unknown" && provisional["reason"] as? String=="slot_not_matured","short slot stays provisional")
    single.append([frame(0.30,0.80,[3])])
    let one=single.join(event("single",0,0.30),source:"remote",epoch:"history-check")
    check(one["basis"] as? String=="anonymous_cluster" && one["cluster_id"] as? Int==3,"stable slot promotes earlier evidence")

    var interjection=SpeakerTimeline();interjection.append([frame(0,0.90,[0]),frame(0.90,1.02,[1]),frame(1.02,1.92,[0])])
    check(interjection.join(event("brief-interjection",0,1.92),source:"remote",epoch:"history-check")["reason"] as? String=="slot_not_matured","unmatured sustained interruption stays unresolved")

    var overlap=SpeakerTimeline();overlap.append([frame(0,0.80,[0]),frame(0.80,1.60,[1]),frame(1.60,1.70,[0]),frame(1.70,1.80,[0,1]),frame(1.80,1.90,[0])])
    check(overlap.join(event("overlap",1.60,1.90),source:"remote",epoch:"history-check")["reason"] as? String=="overlap","overlap preserved")

    var speakerChange=SpeakerTimeline();speakerChange.append([frame(0,0.80,[0]),frame(0.80,1.60,[1]),frame(1.60,1.75,[0]),frame(1.75,1.90,[1])])
    check(speakerChange.join(event("speaker-change",1.60,1.90),source:"remote",epoch:"history-check")["reason"] as? String=="speaker_change","speaker change preserved")

    var thirdSpeaker=SpeakerTimeline();thirdSpeaker.append([frame(0,0.80,[0]),frame(0.80,1.60,[1]),frame(1.60,2.40,[2])])
    check(thirdSpeaker.join(event("third-speaker",1.70,2.30),source:"remote",epoch:"history-check")["cluster_id"] as? Int==2,"stable third slot is not capped")

    var noEvidence=SpeakerTimeline();noEvidence.append([frame(0,0.30,[])])
    check(noEvidence.join(event("no-evidence",0,0.30),source:"remote",epoch:"history-check")["reason"] as? String=="no_speaker_evidence","unknown stays unknown")

    var shortWord=SpeakerTimeline();shortWord.append([frame(0,0.50,[0]),frame(0.50,0.51,[0]),frame(0.51,1.01,[0])])
    var shortWordEvent=event("short-word",0,1.01);shortWordEvent["text"]="前嗯后"
    shortWordEvent["word_spans"]=[["start":0.05,"end":0.45,"text":"前"],["start":0.50,"end":0.51,"text":"嗯"],["start":0.56,"end":0.96,"text":"后"]]
    shortWord.annotateWords(&shortWordEvent,source:"remote",epoch:"history-check")
    let filled=shortWordEvent["speaker_runs"] as? [[String:Any]] ?? []
    check(filled.isEmpty && shortWordEvent["text"] as? String=="前嗯后" && shortWord.join(shortWordEvent,source:"remote",epoch:"history-check")["cluster_id"] as? Int==0,"brief partly voiced word inherits adjacent same speaker without redundant single run")

    var pausedWord=SpeakerTimeline();pausedWord.append([frame(0,0.50,[0]),frame(0.50,0.51,[]),frame(0.51,1.01,[0])])
    var pausedEvent=shortWordEvent;pausedEvent["segment_id"]="pause-stays-unknown"
    pausedWord.annotateWords(&pausedEvent,source:"remote",epoch:"history-check")
    let pausedRuns=pausedEvent["speaker_runs"] as? [[String:Any]] ?? []
    check(pausedRuns.count==3 && (pausedRuns[1]["speaker"] as? [String:Any])?["basis"] as? String=="unknown","true pause is not bridged")

    // Word islands can be weakly voiced one word at a time while the same
    // mature speaker is still evidenced on both sides. Keep these deterministic
    // cases in the timeline owner; no recordings or acoustic models are loaded.
    func tenMillisecondFrames(_ start:Double,_ end:Double,_ slots:[Int],source:String="remote",epoch:String="history-check")->[SpeakerFrame] {
        let first=Int((start*100).rounded()),last=Int((end*100).rounded())
        return (first..<last).map{index in frame(Double(index)/100,Double(index+1)/100,slots,1,source:source,epoch:epoch)}
    }
    func matureTwoSpeakerContext()->[SpeakerFrame] {
        tenMillisecondFrames(0,0.8,[0])+tenMillisecondFrames(0.8,1.6,[1])+tenMillisecondFrames(1.6,2.4,[0])
    }
    func joinedFrames(_ segments:[[SpeakerFrame]])->[SpeakerFrame] { segments.flatMap{$0} }
    func word(_ start:Double,_ end:Double,_ text:String)->[String:Any] { ["start":start,"end":end,"text":text] }
    func annotated(_ timeline:inout SpeakerTimeline,_ id:String,_ words:[[String:Any]],final:Bool=true)->[String:Any] {
        let start=words.first!["start"] as! Double,end=words.last!["end"] as! Double
        var value=event(id,start,end);value["final"]=final;value["text"]=words.map{$0["text"] as! String}.joined();value["word_spans"]=words
        timeline.annotateWords(&value,source:"remote",epoch:"history-check");return value
    }
    func directWord(_ timeline:SpeakerTimeline,_ id:String,_ start:Double,_ end:Double)->[String:Any] {
        timeline.join(event(id,start,end),source:"remote",epoch:"history-check")
    }
    func containsUnknownRun(_ value:[String:Any],text:String)->Bool {
        (value["speaker_runs"] as? [[String:Any]] ?? []).contains{run in
            (run["text"] as? String ?? "").contains(text) && ((run["speaker"] as? [String:Any])?["basis"] as? String)=="unknown"
        }
    }
    func containsUnknownToken(_ value:[String:Any],text:String)->Bool {containsUnknownRun(value,text:text)}
    func allTokensRemainUnknown(_ value:[String:Any],tokens:[String])->Bool {
        tokens.allSatisfy{token in containsUnknownToken(value,text:token)}
    }
    func hasOneSpeakerRun(_ value:[String:Any],slot:Int)->Bool {
        guard let runs=value["speaker_runs"] as? [[String:Any]] else{return true}
        return runs.allSatisfy{run in
            let speaker=run["speaker"] as? [String:Any] ?? [:]
            return speaker["basis"] as? String=="anonymous_cluster" && speaker["cluster_id"] as? Int==slot
        }
    }
    func parentSpeaker(_ timeline:SpeakerTimeline,_ value:[String:Any])->[String:Any] {
        timeline.join(value,source:"remote",epoch:"history-check")
    }
    func annotatedWithParent(_ timeline:inout SpeakerTimeline,_ id:String,_ start:Double,_ end:Double,
                             _ words:[[String:Any]],text:String)->[String:Any] {
        var value=event(id,start,end);value["text"]=text;value["word_spans"]=words
        value["speaker"]=timeline.join(value,source:"remote",epoch:"history-check")
        timeline.annotateWords(&value,source:"remote",epoch:"history-check")
        return value
    }

    let islandWords=[word(3.0,3.2,"前"),word(3.2,3.4,"乙"),word(3.4,3.6,"丙"),word(3.6,3.8,"后")]
    var voicedIsland=SpeakerTimeline()
    var voicedIslandFrames=matureTwoSpeakerContext()
    voicedIslandFrames += tenMillisecondFrames(3.0,3.2,[0]);voicedIslandFrames += tenMillisecondFrames(3.2,3.26,[0])
    voicedIslandFrames += tenMillisecondFrames(3.26,3.4,[]);voicedIslandFrames += tenMillisecondFrames(3.4,3.46,[0])
    voicedIslandFrames += tenMillisecondFrames(3.46,3.6,[]);voicedIslandFrames += tenMillisecondFrames(3.6,3.8,[0])
    voicedIsland.append(voicedIslandFrames)
    let firstIslandWord=directWord(voicedIsland,"island-first",3.2,3.4),secondIslandWord=directWord(voicedIsland,"island-second",3.4,3.6)
    let voicedIslandEvent=annotated(&voicedIsland,"two-word-island",islandWords)
    let recoveredParent=parentSpeaker(voicedIsland,voicedIslandEvent)
    check(firstIslandWord["basis"] as? String=="unknown" && secondIslandWord["basis"] as? String=="unknown" &&
          firstIslandWord["reason"] as? String=="insufficient_voiced_evidence" && secondIslandWord["reason"] as? String=="insufficient_voiced_evidence",
          "two 200ms island words each have only 60ms same-slot voice")
    check(!containsUnknownRun(voicedIslandEvent,text:"乙丙") && hasOneSpeakerRun(voicedIslandEvent,slot:0) &&
          recoveredParent["basis"] as? String=="anonymous_cluster" && recoveredParent["cluster_id"] as? Int==0,
          "two weak words recover only between the same known speaker")

    // Sentence-boundary words have only one neighboring anchor. Their 80 ms
    // continuous same-speaker evidence exceeds the stricter 50% edge rule.
    var endingWord=SpeakerTimeline()
    endingWord.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[0]),tenMillisecondFrames(3.2,3.28,[0]),tenMillisecondFrames(3.28,3.3,[])]))
    let endingDirect=directWord(endingWord,"ending-direct",3.2,3.3)
    var endingEvent=annotated(&endingWord,"ending-word",[word(3.0,3.2,"前"),word(3.2,3.3,"嗯")],final:false)
    check(endingDirect["basis"] as? String=="unknown" && endingDirect["reason"] as? String=="insufficient_voiced_evidence" &&
          containsUnknownRun(endingEvent,text:"嗯"),
          "partial sentence-final word waits for the final word boundary")
    endingEvent["final"]=true;endingWord.annotateWords(&endingEvent,source:"remote",epoch:"history-check")
    let endingParent=parentSpeaker(endingWord,endingEvent)
    check(
          hasOneSpeakerRun(endingEvent,slot:0) && endingParent["cluster_id"] as? Int==0,
          "final 100ms sentence-final word recovers with 80ms same-slot evidence and a continuous known neighbor")

    var beginningWord=SpeakerTimeline()
    beginningWord.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.08,[0]),tenMillisecondFrames(3.08,3.1,[]),tenMillisecondFrames(3.1,3.3,[0])]))
    let beginningDirect=directWord(beginningWord,"beginning-direct",3.0,3.1)
    var beginningEvent=annotated(&beginningWord,"beginning-word",[word(3.0,3.1,"嗯"),word(3.1,3.3,"后")],final:false)
    check(beginningDirect["basis"] as? String=="unknown" && beginningDirect["reason"] as? String=="insufficient_voiced_evidence" &&
          containsUnknownRun(beginningEvent,text:"嗯"),
          "partial sentence-initial word waits for the final word boundary")
    beginningEvent["final"]=true;beginningWord.annotateWords(&beginningEvent,source:"remote",epoch:"history-check")
    let beginningParent=parentSpeaker(beginningWord,beginningEvent)
    check(
          hasOneSpeakerRun(beginningEvent,slot:0) && beginningParent["cluster_id"] as? Int==0,
          "final 100ms sentence-initial word recovers with 80ms same-slot evidence and a continuous known neighbor")

    // The island shortcut must reject evidence that could hide a real boundary
    // or a word with no acoustic support of its own.
    var silentIsland=SpeakerTimeline()
    silentIsland.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[0]),tenMillisecondFrames(3.2,3.6,[]),tenMillisecondFrames(3.6,3.8,[0])]))
    let silentEvent=annotated(&silentIsland,"silent-island",islandWords)
    check(containsUnknownRun(silentEvent,text:"乙丙"),"fully unvoiced unknown island remains unknown")

    var otherSpeakerIsland=SpeakerTimeline()
    var otherSpeakerFrames=matureTwoSpeakerContext()
    otherSpeakerFrames += tenMillisecondFrames(3.0,3.2,[0]);otherSpeakerFrames += tenMillisecondFrames(3.2,3.26,[0])
    otherSpeakerFrames += tenMillisecondFrames(3.26,3.4,[]);otherSpeakerFrames += tenMillisecondFrames(3.4,3.46,[1])
    otherSpeakerFrames += tenMillisecondFrames(3.46,3.6,[]);otherSpeakerFrames += tenMillisecondFrames(3.6,3.8,[0])
    otherSpeakerIsland.append(otherSpeakerFrames)
    let otherSpeakerEvent=annotated(&otherSpeakerIsland,"other-speaker-island",islandWords)
    check(containsUnknownRun(otherSpeakerEvent,text:"乙丙"),"different mature speaker evidence blocks island attribution")

    var overlappingIsland=SpeakerTimeline()
    var overlappingFrames=matureTwoSpeakerContext()
    overlappingFrames += tenMillisecondFrames(3.0,3.2,[0]);overlappingFrames += tenMillisecondFrames(3.2,3.26,[0])
    overlappingFrames += tenMillisecondFrames(3.26,3.32,[0,1]);overlappingFrames += tenMillisecondFrames(3.32,3.4,[])
    overlappingFrames += tenMillisecondFrames(3.4,3.46,[0]);overlappingFrames += tenMillisecondFrames(3.46,3.6,[])
    overlappingFrames += tenMillisecondFrames(3.6,3.8,[0]);overlappingIsland.append(overlappingFrames)
    let overlapIslandEvent=annotated(&overlappingIsland,"overlap-island",islandWords)
    check(directWord(overlappingIsland,"overlap-direct",3.2,3.4)["reason"] as? String=="overlap" &&
          containsUnknownToken(overlapIslandEvent,text:"丙") && !hasOneSpeakerRun(overlapIslandEvent,slot:0),
          "overlap in unknown island is not bridged")

    var clockGapIsland=SpeakerTimeline()
    var clockGapFrames=matureTwoSpeakerContext()
    clockGapFrames += tenMillisecondFrames(3.0,3.2,[0]);clockGapFrames += tenMillisecondFrames(3.2,3.26,[0])
    clockGapFrames += tenMillisecondFrames(3.27,3.4,[]);clockGapFrames += tenMillisecondFrames(3.4,3.46,[0])
    clockGapFrames += tenMillisecondFrames(3.46,3.6,[]);clockGapFrames += tenMillisecondFrames(3.6,3.8,[0])
    clockGapIsland.append(clockGapFrames)
    let clockGapEvent=annotated(&clockGapIsland,"clock-gap-island",islandWords)
    check(containsUnknownToken(clockGapEvent,text:"乙"),"10ms timestamp gap blocks island attribution")

    var sourceSwitchIsland=SpeakerTimeline()
    var sourceSwitchFrames=matureTwoSpeakerContext()
    sourceSwitchFrames += tenMillisecondFrames(3.0,3.2,[0]);sourceSwitchFrames += tenMillisecondFrames(3.2,3.26,[0])
    sourceSwitchFrames += tenMillisecondFrames(3.26,3.4,[],source:"mic");sourceSwitchFrames += tenMillisecondFrames(3.4,3.46,[0])
    sourceSwitchFrames += tenMillisecondFrames(3.46,3.6,[]);sourceSwitchFrames += tenMillisecondFrames(3.6,3.8,[0])
    sourceSwitchIsland.append(sourceSwitchFrames)
    let sourceSwitchEvent=annotated(&sourceSwitchIsland,"source-switch-island",islandWords)
    check(containsUnknownToken(sourceSwitchEvent,text:"乙"),"source switch inside island blocks attribution")

    var epochSwitchIsland=SpeakerTimeline()
    var epochSwitchFrames=matureTwoSpeakerContext()
    epochSwitchFrames += tenMillisecondFrames(3.0,3.2,[0]);epochSwitchFrames += tenMillisecondFrames(3.2,3.26,[0])
    epochSwitchFrames += tenMillisecondFrames(3.26,3.4,[],epoch:"other-epoch");epochSwitchFrames += tenMillisecondFrames(3.4,3.46,[0])
    epochSwitchFrames += tenMillisecondFrames(3.46,3.6,[]);epochSwitchFrames += tenMillisecondFrames(3.6,3.8,[0])
    epochSwitchIsland.append(epochSwitchFrames)
    let epochSwitchEvent=annotated(&epochSwitchIsland,"epoch-switch-island",islandWords)
    check(containsUnknownToken(epochSwitchEvent,text:"乙"),"epoch switch inside island blocks attribution")

    var longPauseIsland=SpeakerTimeline()
    longPauseIsland.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[0]),tenMillisecondFrames(3.2,3.3,[]),
        tenMillisecondFrames(3.3,3.36,[0]),tenMillisecondFrames(3.36,3.6,[]),tenMillisecondFrames(3.6,3.8,[0])]))
    let longPauseEvent=annotated(&longPauseIsland,"long-pause-island",[word(3.0,3.2,"前"),word(3.3,3.5,"嗯"),word(3.6,3.8,"后")])
    check(containsUnknownRun(longPauseEvent,text:"嗯"),"long pauses on both sides leave no bounded acoustic anchor")

    var sparseEndingWord=SpeakerTimeline()
    sparseEndingWord.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[0]),tenMillisecondFrames(3.2,3.22,[0]),tenMillisecondFrames(3.22,3.3,[])]))
    let sparseEndingEvent=annotatedWithParent(&sparseEndingWord,"sparse-ending-word",3.0,3.3,
        [word(3.0,3.2,"前"),word(3.2,3.3,"嗯")],text:"前嗯")
    check(sparseEndingEvent["speaker_runs"]==nil &&
          (sparseEndingEvent["speaker"] as? [String:Any])?["cluster_id"] as? Int==0 &&
          sparseEndingEvent["text"] as? String=="前嗯",
          "20-percent final word recovers with a strong original same-speaker parent; text remains unverified")

    var longEndingIsland=SpeakerTimeline()
    var longEndingFrames=matureTwoSpeakerContext()
    longEndingFrames += tenMillisecondFrames(3.0,3.2,[0])
    longEndingFrames += tenMillisecondFrames(3.2,3.23,[]);longEndingFrames += tenMillisecondFrames(3.23,3.31,[0])
    longEndingFrames += tenMillisecondFrames(3.31,3.35,[]);longEndingFrames += tenMillisecondFrames(3.35,3.38,[])
    longEndingFrames += tenMillisecondFrames(3.38,3.46,[0]);longEndingFrames += tenMillisecondFrames(3.46,3.5,[])
    longEndingFrames += tenMillisecondFrames(3.5,3.53,[]);longEndingFrames += tenMillisecondFrames(3.53,3.61,[0])
    longEndingFrames += tenMillisecondFrames(3.61,3.65,[])
    longEndingIsland.append(longEndingFrames)
    let longEndingEvent=annotatedWithParent(&longEndingIsland,"long-ending-island",3.0,3.65,
        [word(3.0,3.2,"前"),word(3.2,3.35,"尾一"),word(3.35,3.5,"尾二"),word(3.5,3.65,"尾三")],text:"前尾一尾二尾三")
    check((longEndingEvent["speaker"] as? [String:Any])?["cluster_id"] as? Int==0 &&
          longEndingEvent["speaker_runs"]==nil && longEndingEvent["text"] as? String=="前尾一尾二尾三",
          "450ms phrase-end island with direct voice and a strong anchor fits the new 600ms bounded limit")

    // A complete, mature single-speaker parent can safely supply context when
    // ASR inserts a short, fully-covered silence between words. The unknown
    // word still needs its own voiced support; only the aggregate gets the
    // stronger parent evidence.
    let shortContextWords=[word(3.0,3.2,"前"),word(3.2,3.36,"嗯"),word(3.4,3.6,"后")]
    var strongParentIsland=SpeakerTimeline()
    strongParentIsland.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[0]),
        tenMillisecondFrames(3.2,3.27,[0]),tenMillisecondFrames(3.27,3.4,[]),
        tenMillisecondFrames(3.4,3.5,[0]),tenMillisecondFrames(3.5,3.6,[])]))
    let strongParentBefore=strongParentIsland.join(event("strong-parent-before",3.0,3.6),source:"remote",epoch:"history-check")
    let weakShortDirect=directWord(strongParentIsland,"strong-parent-word",3.2,3.36)
    let strongParentEvent=annotatedWithParent(&strongParentIsland,"strong-parent-island",3.0,3.6,
        shortContextWords,text:"前嗯后")
    let strongParentAfter=strongParentEvent["speaker"] as? [String:Any] ?? [:]
    check(strongParentBefore["basis"] as? String=="anonymous_cluster" &&
          strongParentIsland.singleVoiceCoverage(start:3.0,end:3.6,slot:0,source:"remote",epoch:"history-check") != nil &&
          weakShortDirect["basis"] as? String=="unknown" && weakShortDirect["reason"] as? String=="insufficient_voiced_evidence" &&
          strongParentEvent["speaker_runs"]==nil && !containsUnknownRun(strongParentEvent,text:"嗯") &&
          strongParentAfter["basis"] as? String=="anonymous_cluster" && strongParentAfter["cluster_id"] as? Int==0,
          "strong single-speaker parent and 80ms neighboring voice recover a 160ms word with 70ms direct voice across a covered 40ms silence")

    var secondRawSlotParent=SpeakerTimeline()
    secondRawSlotParent.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[0]),
        tenMillisecondFrames(3.2,3.27,[0]),tenMillisecondFrames(3.27,3.4,[]),
        tenMillisecondFrames(3.4,3.5,[0]),tenMillisecondFrames(3.5,3.6,[]),
        tenMillisecondFrames(3.6,3.8,[1])]))
    let secondSlotWords=[word(3.0,3.2,"前"),word(3.2,3.36,"嗯"),word(3.4,3.6,"后"),word(3.6,3.8,"另")]
    let secondSlotStrongEvent=annotatedWithParent(&secondRawSlotParent,"strong-parent-second-slot",3.0,3.8,
        secondSlotWords,text:"前嗯后另")
    let secondSlotStrongRuns=secondSlotStrongEvent["speaker_runs"] as? [[String:Any]] ?? []
    check((secondSlotStrongEvent["speaker"] as? [String:Any])?["basis"] as? String=="multiple" &&
          !containsUnknownRun(secondSlotStrongEvent,text:"嗯") &&
          secondSlotStrongRuns.contains(where:{($0["text"] as? String)=="另" && (($0["speaker"] as? [String:Any])?["cluster_id"] as? Int)==1}),
          "a later different-speaker run keeps the parent multiple while local same-speaker anchors resolve the earlier word")

    var silentWordStrongParent=SpeakerTimeline()
    silentWordStrongParent.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[0]),
        tenMillisecondFrames(3.2,3.4,[]),tenMillisecondFrames(3.4,3.5,[0]),tenMillisecondFrames(3.5,3.6,[])]))
    let silentStrongEvent=annotatedWithParent(&silentWordStrongParent,"strong-parent-silent-word",3.0,3.6,
        shortContextWords,text:"前嗯后")
    check((silentStrongEvent["speaker"] as? [String:Any])?["basis"] as? String=="anonymous_cluster" &&
          silentStrongEvent["speaker_runs"]==nil && silentStrongEvent["text"] as? String=="前嗯后",
          "a short silent ASR span may inherit speaker context without changing or validating its text")

    var isolatedSilentWord=SpeakerTimeline()
    isolatedSilentWord.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[])]))
    let isolatedSilentEvent=annotatedWithParent(&isolatedSilentWord,"isolated-silent-word",3.0,3.2,
        [word(3.0,3.2,"嗯")],text:"嗯")
    check((isolatedSilentEvent["speaker"] as? [String:Any])?["basis"] as? String=="unknown" &&
          (isolatedSilentEvent["speaker"] as? [String:Any])?["reason"] as? String=="no_speaker_evidence" &&
          isolatedSilentEvent["speaker_runs"]==nil,
          "a wholly silent utterance without original word anchors remains unknown")

    var coveredSilenceTail=SpeakerTimeline()
    coveredSilenceTail.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[0]),
        tenMillisecondFrames(3.2,3.4,[])]))
    let silentTail=annotatedWithParent(&coveredSilenceTail,"covered-silent-tail",3.0,3.4,
        [word(3.0,3.2,"前"),word(3.2,3.4,"候选词")],text:"前候选词")
    check((silentTail["speaker"] as? [String:Any])?["cluster_id"] as? Int==0 && silentTail["speaker_runs"]==nil &&
          silentTail["text"] as? String=="前候选词",
          "a final 200ms fully-covered silent tail can receive only the neighboring speaker, not text validation")

    var tooLongSilentTail=SpeakerTimeline()
    tooLongSilentTail.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[0]),
        tenMillisecondFrames(3.2,3.46,[])]))
    let longSilentTail=annotatedWithParent(&tooLongSilentTail,"long-silent-tail",3.0,3.46,
        [word(3.0,3.2,"前"),word(3.2,3.46,"候选词")],text:"前候选词")
    check(containsUnknownRun(longSilentTail,text:"候选词"),
          "a completely silent tail over 250ms is not filled by parent context")

    var oversizedIsland=SpeakerTimeline()
    oversizedIsland.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[0]),
        tenMillisecondFrames(3.2,3.24,[0]),tenMillisecondFrames(3.24,3.81,[]),tenMillisecondFrames(3.81,4.01,[0])]))
    let oversizedEvent=annotatedWithParent(&oversizedIsland,"oversized-bounded-island",3.0,4.01,
        [word(3.0,3.2,"前"),word(3.2,3.81,"候选词"),word(3.81,4.01,"后")],text:"前候选词后")
    check(containsUnknownRun(oversizedEvent,text:"候选词"),
          "an unknown island over 600ms exceeds the bounded phrase limit")

    var differentNeighbor=SpeakerTimeline()
    differentNeighbor.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[0]),
        tenMillisecondFrames(3.2,3.25,[0]),tenMillisecondFrames(3.25,3.4,[]),
        tenMillisecondFrames(3.4,3.6,[1])]))
    let differentNeighborEvent=annotatedWithParent(&differentNeighbor,"different-original-neighbor",3.0,3.6,
        [word(3.0,3.2,"前"),word(3.2,3.4,"候选词"),word(3.4,3.6,"后")],text:"前候选词后")
    check((differentNeighborEvent["speaker"] as? [String:Any])?["basis"] as? String=="multiple" &&
          containsUnknownRun(differentNeighborEvent,text:"候选词"),
          "a real different-speaker neighbor blocks phrase-context attribution")

    var wrongEpochPhrase=SpeakerTimeline()
    wrongEpochPhrase.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[0]),
        tenMillisecondFrames(3.2,3.4,[])]))
    var wrongEpochEvent=event("wrong-epoch-phrase",3.0,3.4,epoch:"other-epoch")
    wrongEpochEvent["text"]="前候选词";wrongEpochEvent["word_spans"]=[word(3.0,3.2,"前"),word(3.2,3.4,"候选词")]
    wrongEpochEvent["speaker"]=wrongEpochPhrase.join(wrongEpochEvent,source:"remote",epoch:"other-epoch")
    wrongEpochPhrase.annotateWords(&wrongEpochEvent,source:"remote",epoch:"other-epoch")
    check((wrongEpochEvent["speaker"] as? [String:Any])?["basis"] as? String=="unknown" &&
          (wrongEpochEvent["speaker"] as? [String:Any])?["reason"] as? String=="coverage_gap" &&
          wrongEpochEvent["speaker_runs"]==nil,
          "phrase context never crosses the event's diarization epoch")

    var voicedShortContext=SpeakerTimeline()
    voicedShortContext.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[0]),
        tenMillisecondFrames(3.2,3.25,[0]),tenMillisecondFrames(3.25,3.5,[])]))
    let shortContextRecovered=annotatedWithParent(&voicedShortContext,"voiced-short-context",3.0,3.5,
        [word(3.0,3.2,"前"),word(3.2,3.5,"候选词")],text:"前候选词")
    check((shortContextRecovered["speaker"] as? [String:Any])?["cluster_id"] as? Int==0 &&
          shortContextRecovered["speaker_runs"]==nil && shortContextRecovered["text"] as? String=="前候选词",
          "a 300ms word with 50ms direct voice may use a strong local same-slot anchor without changing text")

    var longWeakContext=SpeakerTimeline()
    longWeakContext.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(2.85,3.2,[0]),
        tenMillisecondFrames(3.2,3.24,[0]),tenMillisecondFrames(3.24,3.6,[]),tenMillisecondFrames(3.6,3.8,[0])]))
    let longWeakRecovered=annotatedWithParent(&longWeakContext,"long-weak-word",2.85,3.8,
        [word(3.0,3.2,"前"),word(3.2,3.6,"候选词"),word(3.6,3.8,"后")],text:"前候选词后")
    check((longWeakRecovered["speaker"] as? [String:Any])?["cluster_id"] as? Int==0 &&
          longWeakRecovered["speaker_runs"]==nil && longWeakRecovered["text"] as? String=="前候选词后",
          "a 400ms island with 40ms direct voice can use a sufficiently strong bounded phrase context")

    var shortSilentIsland=SpeakerTimeline()
    shortSilentIsland.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[0]),
        tenMillisecondFrames(3.2,3.3,[]),tenMillisecondFrames(3.3,3.4,[])]))
    let shortSilentIslandEvent=annotatedWithParent(&shortSilentIsland,"short-silent-island",3.0,3.4,
        [word(3.0,3.2,"前"),word(3.2,3.3,"候选一"),word(3.3,3.4,"候选二")],text:"前候选一候选二")
    check((shortSilentIslandEvent["speaker"] as? [String:Any])?["cluster_id"] as? Int==0 &&
          shortSilentIslandEvent["speaker_runs"]==nil && shortSilentIslandEvent["text"] as? String=="前候选一候选二",
          "a short silent word island inherits one original same-speaker anchor while preserving unverified text")

    var nonfinalContext=SpeakerTimeline()
    nonfinalContext.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[0]),
        tenMillisecondFrames(3.2,3.4,[])]))
    let nonfinalTail=annotatedWithParent(&nonfinalContext,"nonfinal-silent-tail",3.0,3.4,
        [word(3.0,3.2,"前"),word(3.2,3.4,"候选词")],text:"前候选词")
    var partialTail=nonfinalTail;partialTail["final"]=false
    nonfinalContext.annotateWords(&partialTail,source:"remote",epoch:"history-check")
    check(containsUnknownRun(partialTail,text:"候选词"),
          "bounded phrase context waits until ASR finalizes the span")

    let cascadeGuard=SpeakerPipeline(source:"remote",epoch:"bounded-phrase-isolation",syntheticInput:true)
    var cascadeFrames=matureTwoSpeakerContext()
    cascadeFrames += tenMillisecondFrames(3.0,3.2,[0],source:"remote",epoch:"history-check")
    cascadeFrames += tenMillisecondFrames(3.2,3.4,[],source:"remote",epoch:"history-check")
    cascadeFrames=cascadeFrames.map{
            frame($0.start,$0.end,$0.activeSlots,1,source:"remote",epoch:"bounded-phrase-isolation")
        }
    _=try await cascadeGuard.syntheticTimelineRevision(cascadeFrames,revision:1)
    var contextualFinal=event("contextual-final",3.0,3.4,epoch:"bounded-phrase-isolation")
    contextualFinal["text"]="前候选词";contextualFinal["word_spans"]=[word(3.0,3.2,"前"),word(3.2,3.4,"候选词")]
    let firstContextualResult=await cascadeGuard.accept(contextualFinal)
    let standaloneFollowup=event("standalone-followup",3.2,3.4,epoch:"bounded-phrase-isolation")
    let secondContextualResult=await cascadeGuard.accept(standaloneFollowup)
    check((firstContextualResult["speaker"] as? [String:Any])?["cluster_id"] as? Int==0 &&
          (secondContextualResult["speaker"] as? [String:Any])?["basis"] as? String=="unknown" &&
          (secondContextualResult["speaker"] as? [String:Any])?["reason"] as? String=="no_speaker_evidence",
          "a prior contextual fill never becomes acoustic evidence for a later standalone event")
    _=try await cascadeGuard.close(flush:false)

    // A phrase-end word can sit in the middle of a longer ASR event. Its later
    // same-speaker word comes after a long breath, so the regular two-sided
    // island path rejects it; final phrase-end evidence can use the prior
    // acoustic neighbor without borrowing an inferred word.
    func phraseEndTimeline(targetVoiceEnd:Double)->SpeakerTimeline {
        var timeline=SpeakerTimeline()
        timeline.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[0]),
            tenMillisecondFrames(3.2,targetVoiceEnd,[0]),tenMillisecondFrames(targetVoiceEnd,3.6,[]),
            tenMillisecondFrames(3.6,3.7,[0]),tenMillisecondFrames(3.7,3.8,[])]))
        return timeline
    }
    let phraseEndWords=[word(3.0,3.2,"前"),word(3.2,3.36,"嗯"),word(3.6,3.8,"后")]
    var phraseEndTimelineValue=phraseEndTimeline(targetVoiceEnd:3.27)
    let phraseEndEvent=annotatedWithParent(&phraseEndTimelineValue,"phrase-end-160ms",3.0,3.8,
        phraseEndWords,text:"前嗯后")
    let phraseEndParent=phraseEndEvent["speaker"] as? [String:Any] ?? [:]
    check(phraseEndParent["basis"] as? String=="anonymous_cluster" && phraseEndParent["cluster_id"] as? Int==0 &&
          phraseEndEvent["speaker_runs"]==nil && !containsUnknownRun(phraseEndEvent,text:"嗯"),
          "final 160ms phrase-end word with 70ms direct voice recovers before a later same-speaker word after 240ms breath")

    func checkStrongContextPhraseEnd(_ targetEnd:Double,_ targetVoiceEnd:Double,_ id:String,_ percentage:String) {
        var timeline=phraseEndTimeline(targetVoiceEnd:targetVoiceEnd)
        let words=[word(3.0,3.2,"前"),word(3.2,targetEnd,"嗯"),word(3.6,3.8,"后")]
        let value=annotatedWithParent(&timeline,id,3.0,3.8,words,text:"前嗯后")
        let parent=value["speaker"] as? [String:Any] ?? [:]
        check(parent["basis"] as? String=="anonymous_cluster" && parent["cluster_id"] as? Int==0 &&
              value["speaker_runs"]==nil && value["text"] as? String=="前嗯后",
              "final phrase-end word with \(percentage) direct voice may use strong pure-parent context without changing text")
    }
    checkStrongContextPhraseEnd(3.3,3.22,"phrase-end-20-percent", "20%")
    checkStrongContextPhraseEnd(3.3,3.23,"phrase-end-30-percent", "30%")

    var longCoveredGapParent=SpeakerTimeline()
    longCoveredGapParent.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.2,[0]),
        tenMillisecondFrames(3.2,3.3,[]),tenMillisecondFrames(3.3,3.37,[0]),
        tenMillisecondFrames(3.37,3.55,[]),tenMillisecondFrames(3.55,3.65,[0]),tenMillisecondFrames(3.65,3.75,[])]))
    let longGapWords=[word(3.0,3.2,"前"),word(3.3,3.46,"嗯"),word(3.55,3.75,"后")]
    let longGapStrongEvent=annotatedWithParent(&longCoveredGapParent,"strong-parent-long-gap",3.0,3.75,
        longGapWords,text:"前嗯后")
    let longGapStrongRuns=longGapStrongEvent["speaker_runs"] as? [[String:Any]] ?? []
    check((longGapStrongEvent["speaker"] as? [String:Any])?["basis"] as? String=="anonymous_cluster" &&
          longGapStrongRuns.contains(where:{($0["text"] as? String)=="嗯" && (($0["speaker"] as? [String:Any])?["basis"] as? String)=="unknown"}),
          "covered silence over 80ms on both sides leaves no eligible acoustic anchor")

    var weakEdgeWithoutStrongParent=SpeakerTimeline()
    weakEdgeWithoutStrongParent.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,4.4,[]),
        tenMillisecondFrames(4.4,4.5,[0]),tenMillisecondFrames(4.5,4.6,[]),
        tenMillisecondFrames(4.6,4.632,[0]),tenMillisecondFrames(4.632,5.0,[])]))
    let weakEdgeWords=[word(4.4,4.6,"后"),word(4.6,4.76,"嗯")]
    let weakEdgeParent=weakEdgeWithoutStrongParent.join(event("weak-edge-parent",3.0,5.0),source:"remote",epoch:"history-check")
    let weakEdgeEvent=annotatedWithParent(&weakEdgeWithoutStrongParent,"weak-edge-no-parent",3.0,5.0,
        weakEdgeWords,text:"后嗯")
    let weakEdgeRuns=weakEdgeEvent["speaker_runs"] as? [[String:Any]] ?? []
    check(weakEdgeParent["basis"] as? String=="unknown" && weakEdgeParent["reason"] as? String=="insufficient_voiced_evidence" &&
          weakEdgeRuns.contains(where:{($0["text"] as? String)=="嗯" && (($0["speaker"] as? [String:Any])?["basis"] as? String)=="unknown"}),
          "20-percent one-sided word remains unknown without a strong parent and a 50-percent edge")

    var noAnchor=SpeakerTimeline()
    noAnchor.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.06,[0]),tenMillisecondFrames(3.06,3.2,[])]))
    let noAnchorWord=directWord(noAnchor,"no-neighbor",3.0,3.2)
    _=annotated(&noAnchor,"no-neighbor-event",[word(3.0,3.2,"嗯")])
    check(noAnchorWord["basis"] as? String=="unknown" && noAnchorWord["reason"] as? String=="insufficient_voiced_evidence",
          "weak single word without a known neighboring utterance remains unknown")

    // The annotation result must survive the parent projection when all child
    // words coalesce to one identity and therefore omit speaker_runs.
    let sparseWords=[word(3.0,3.1,"甲"),word(6.0,6.1,"乙")]
    var sparseParent=SpeakerTimeline()
    sparseParent.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.1,[0]),tenMillisecondFrames(3.1,6.0,[]),tenMillisecondFrames(6.0,6.1,[0])]))
    var sparseParentItem=event("sparse-parent",3.0,6.1);sparseParentItem["text"]="甲乙";sparseParentItem["word_spans"]=sparseWords
    sparseParentItem["speaker"]=sparseParent.join(sparseParentItem,source:"remote",epoch:"history-check")
    check((sparseParentItem["speaker"] as? [String:Any])?["basis"] as? String=="unknown" &&
          (sparseParentItem["speaker"] as? [String:Any])?["reason"] as? String=="insufficient_voiced_evidence",
          "sparse parent starts unknown although each word is individually attributable")
    sparseParent.annotateWords(&sparseParentItem,source:"remote",epoch:"history-check")
    let sparseResolved=sparseParentItem["speaker"] as? [String:Any] ?? [:]
    check(sparseParentItem["speaker_runs"]==nil && sparseResolved["basis"] as? String=="anonymous_cluster" &&
          sparseResolved["cluster_id"] as? Int==0 && sparseResolved["contextual_fill"] as? Bool==true,
          "single coalesced child identity promotes only an insufficient-evidence parent")

    var secondSlotParent=SpeakerTimeline()
    secondSlotParent.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.1,[0]),tenMillisecondFrames(3.1,6.0,[1]),tenMillisecondFrames(6.0,6.1,[0])]))
    var secondSlotItem=event("second-slot-parent",3.0,6.1);secondSlotItem["text"]="甲乙";secondSlotItem["word_spans"]=sparseWords
    secondSlotItem["speaker"]=secondSlotParent.join(secondSlotItem,source:"remote",epoch:"history-check")
    let beforeSecondSlot=secondSlotItem["speaker"] as? [String:Any] ?? [:]
    secondSlotParent.annotateWords(&secondSlotItem,source:"remote",epoch:"history-check")
    let afterSecondSlot=secondSlotItem["speaker"] as? [String:Any] ?? [:]
    check(beforeSecondSlot["basis"] as? String=="multiple" && beforeSecondSlot["reason"] as? String=="speaker_change" &&
          afterSecondSlot["basis"] as? String=="multiple" && afterSecondSlot["reason"] as? String=="speaker_change",
          "single child run never erases parent evidence for another speaker")

    var gapParent=SpeakerTimeline()
    gapParent.append(joinedFrames([matureTwoSpeakerContext(),tenMillisecondFrames(3.0,3.1,[0]),tenMillisecondFrames(6.0,6.1,[0])]))
    var gapParentItem=event("gap-parent",3.0,6.1);gapParentItem["text"]="甲乙";gapParentItem["word_spans"]=sparseWords
    gapParentItem["speaker"]=gapParent.join(gapParentItem,source:"remote",epoch:"history-check")
    gapParent.annotateWords(&gapParentItem,source:"remote",epoch:"history-check")
    let gapParentSpeaker=gapParentItem["speaker"] as? [String:Any] ?? [:]
    check(gapParentSpeaker["basis"] as? String=="unknown" && gapParentSpeaker["reason"] as? String=="coverage_gap",
          "single child run never promotes a parent with missing speaker-clock coverage")

    // Exercise the real actor publication path: a segment accepted before its
    // speaker frames arrive must be reannotated and published after completion.
    let delayedIsland=SpeakerPipeline(source:"mic",epoch:"island-refresh",syntheticInput:true)
    var delayedIslandPrefix=tenMillisecondFrames(0,0.8,[0],source:"mic",epoch:"island-refresh")
    delayedIslandPrefix += tenMillisecondFrames(0.8,1.6,[1],source:"mic",epoch:"island-refresh")
    delayedIslandPrefix += tenMillisecondFrames(1.6,2.4,[0],source:"mic",epoch:"island-refresh")
    delayedIslandPrefix += tenMillisecondFrames(3.0,3.2,[0],source:"mic",epoch:"island-refresh")
    _=try await delayedIsland.syntheticTimelineRevision(delayedIslandPrefix,revision:1)
    var delayedIslandItem=event("delayed-island",3.0,3.8,source:"mic",epoch:"island-refresh")
    delayedIslandItem["text"]="前乙丙后";delayedIslandItem["word_spans"]=islandWords
    let initialIslandPublication=await delayedIsland.accept(delayedIslandItem)
    check((initialIslandPublication["speaker"] as? [String:Any])?["basis"] as? String=="unknown",
          "actor publishes incomplete speaker history as unknown before the missing frames arrive")
    var delayedIslandTail=tenMillisecondFrames(3.2,3.26,[0],source:"mic",epoch:"island-refresh")
    delayedIslandTail += tenMillisecondFrames(3.26,3.4,[],source:"mic",epoch:"island-refresh")
    delayedIslandTail += tenMillisecondFrames(3.4,3.46,[0],source:"mic",epoch:"island-refresh")
    delayedIslandTail += tenMillisecondFrames(3.46,3.6,[],source:"mic",epoch:"island-refresh")
    delayedIslandTail += tenMillisecondFrames(3.6,3.8,[0],source:"mic",epoch:"island-refresh")
    let delayedIslandUpdates=try await delayedIsland.syntheticTimelineAppend(delayedIslandTail)
    let resolvedIslandUpdate=delayedIslandUpdates.first ?? [:]
    let resolvedIslandSpeaker=resolvedIslandUpdate["speaker"] as? [String:Any] ?? [:]
    check(delayedIslandUpdates.count==1 && resolvedIslandUpdate["annotation_only"] as? Bool==true &&
          resolvedIslandSpeaker["basis"] as? String=="anonymous_cluster" && resolvedIslandSpeaker["cluster_id"] as? Int==0 &&
          resolvedIslandUpdate["speaker_runs"]==nil,
          "actor refresh publishes the resolved parent after delayed same-speaker frames")
    _=try await delayedIsland.close(flush:false)

    var isolated=SpeakerTimeline();isolated.append([frame(0,1,[9],1,source:"mic",epoch:"other-epoch")])
    let wrongEpoch=isolated.join(event("wrong-epoch",0,1,source:"remote",epoch:"new-epoch"),source:"remote",epoch:"other-epoch")
    let wrongSource=isolated.join(event("wrong-source",0,1,source:"mic",epoch:"other-epoch"),source:"remote",epoch:"other-epoch")
    let noCrossSource=isolated.join(event("no-cross-source",0,1,source:"remote",epoch:"other-epoch"),source:"remote",epoch:"other-epoch")
    check(wrongEpoch["reason"] as? String=="source_or_epoch_mismatch","epoch mismatch rejected")
    check(wrongSource["reason"] as? String=="source_or_epoch_mismatch","source mismatch rejected")
    check(noCrossSource["reason"] as? String=="coverage_gap","other source never supplies slot")

    // Short standalone ASR words need the same conservative acoustic context as
    // short words inside a sentence; text content supplies no identity evidence.
    var shortStandalone=SpeakerTimeline()
    shortStandalone.append([frame(0,0.81,[0]),frame(0.81,1.61,[1])])
    let shortA=shortStandalone.join(event("standalone-a",0.40,0.41),source:"remote",epoch:"history-check")
    let shortB=shortStandalone.join(event("standalone-b",1.20,1.21),source:"remote",epoch:"history-check")
    check(shortA["cluster_id"] as? Int==0 && shortB["cluster_id"] as? Int==1 && shortA["contextual_fill"] as? Bool==true,"standalone 10ms words follow distinct established voices")
    check(shortStandalone.join(event("short-at-change",0.80,0.81),source:"remote",epoch:"history-check")["basis"] as? String=="unknown","short word at another person's boundary stays unknown")
    var shortSilence=SpeakerTimeline();shortSilence.append([frame(0,0.4,[0]),frame(0.4,0.41,[]),frame(0.41,1.21,[0])])
    check(shortSilence.join(event("silent-word",0.4,0.41),source:"remote",epoch:"history-check")["basis"] as? String=="unknown","silent standalone word cannot borrow its neighbors")
    var shortOverlap=SpeakerTimeline();shortOverlap.append([frame(0,0.4,[0]),frame(0.4,0.41,[0,1]),frame(0.41,1.21,[0]),frame(1.21,2.01,[1])])
    check(shortOverlap.join(event("overlap-word",0.4,0.41),source:"remote",epoch:"history-check")["basis"] as? String != "anonymous_cluster","short overlap cannot be forced to one person")
    let shortPending=SpeakerPipeline(source:"mic",epoch:"short-pending",syntheticInput:true)
    _=try await shortPending.syntheticTimelineRevision([frame(0,0.81,[0],source:"mic",epoch:"short-pending")],revision:1)
    var shortPartial=event("short-partial",0.80,0.81,source:"mic",epoch:"short-pending");shortPartial["text"]="对";shortPartial["final"]=false
    let initialShort=await shortPending.accept(shortPartial)
    check((initialShort["speaker"] as? [String:Any])?["basis"] as? String=="unknown","short partial waits for trailing voice evidence")
    let shortUpdates=try await shortPending.syntheticTimelineAppend([frame(0.81,0.90,[0],2,source:"mic",epoch:"short-pending")])
    check(shortUpdates.count==1 && (shortUpdates[0]["speaker"] as? [String:Any])?["cluster_id"] as? Int==0 && shortUpdates[0]["text"] as? String=="对" && shortUpdates[0]["annotation_only"] as? Bool==true,"later same-mic evidence resolves short partial without new ASR text")
    shortPartial["final"]=true;shortPartial["revision"]=2
    let finalShort=await shortPending.accept(shortPartial)
    check(finalShort["final"] as? Bool==true && finalShort["text"] as? String=="对" && (finalShort["speaker"] as? [String:Any])?["cluster_id"] as? Int==0,"short partial final converges without duplicate or guessed text")
    _=try await shortPending.close(flush:false)

    // Public compatibility view expands compressed 10 ms frames and preserves
    // revision boundaries, while custom longer synthetic frames stay one frame.
    var compatibility=SpeakerTimeline()
    compatibility.replace([frame(0,0.01,[4],11),frame(0.01,0.02,[4],12),frame(0.02,0.22,[5],13)],revision:1)
    let expanded=compatibility.frames
    check(expanded.count==3 && expanded[0].revision==11 && expanded[1].revision==12 &&
          expanded[2].start==0.02 && expanded[2].end==0.22 && expanded[2].activeSlots==[5],"frames/revision compatibility")

    // Stress real production-like revisions, which change between model batches.
    // Compare 1h and 2h histories at the same 200-frame (2s) revision cadence;
    // a retained COW alias would make this scale quadratically in revision spans.
    func buildRevisionHistory(frameCount:Int)->(SpeakerTimeline,Double) {
        var timeline=SpeakerTimeline();timeline.setHistoryOriginIfNeeded(0)
        let start=ProcessInfo.processInfo.systemUptime
        for batchStart in stride(from:0,to:frameCount,by:200) {
            let revision=batchStart/200+1
            let batch=(batchStart..<min(batchStart+200,frameCount)).map {index -> SpeakerFrame in
                let time=Double(index)*SpeakerTimeline.frameDuration
                return frame(time,time+SpeakerTimeline.frameDuration,[7],revision)
            }
            timeline.append(batch)
        }
        return (timeline,ProcessInfo.processInfo.systemUptime-start)
    }
    let (oneHour,oneHourSeconds)=buildRevisionHistory(frameCount:360_000)
    var (twoHours,twoHourSeconds)=buildRevisionHistory(frameCount:720_000)
    let linearScale=twoHourSeconds/max(oneHourSeconds,0.001)
    check(oneHour.retainedFrameCount==360_000 && oneHour.revisionSpanCount==1_800,"one-hour per-batch revision history")
    check(twoHours.retainedFrameCount==720_000 && twoHours.revisionSpanCount==3_600 && twoHours.compressedRunCount==1 && !twoHours.historyLimitReached,"two-hour per-batch revision retention")
    check(linearScale<3.5,"revision-history append scales approximately linearly")
    check(twoHours.join(event("two-hour-tail",7199.90,7200),source:"remote",epoch:"history-check")["cluster_id"] as? Int==7,"last in-budget interval")
    twoHours.append([frame(7200,7200.01,[2])])
    check(twoHours.historyLimitReached && twoHours.retainedFrameCount==720_000 &&
          twoHours.join(event("over-budget",7200,7200.01),source:"remote",epoch:"history-check")["reason"] as? String=="speaker_history_limit","explicit two-hour cap")

    // Many runs verify lower-bound lookup work stays logarithmic plus matches.
    var indexed=SpeakerTimeline();indexed.setHistoryOriginIfNeeded(0)
    indexed.append((0..<16_384).map {index -> SpeakerFrame in
        let start=Double(index)*SpeakerTimeline.frameDuration
        return frame(start,start+SpeakerTimeline.frameDuration,index.isMultiple(of:2) ? [0] : [1])
    })
    let search=indexed.searchWork(start:81.92,end:81.94)
    check(indexed.compressedRunCount==16_384 && search.binarySearchComparisons<=15 && search.candidateRunCount==2,"binary range query")

    // Closing the actor releases the retained timeline as well as transient PCM.
    let closing=SpeakerPipeline(source:"remote",epoch:"history-close",syntheticInput:true)
    _=try await closing.syntheticTimelineRevision([frame(0,1,[0],1,epoch:"history-close")],revision:1)
    _=try await closing.close(flush:false)
    let closeState=await closing.status()
    check(closeState["retained_frames"] as? Int==0 && closeState["retained_frame_runs"] as? Int==0,"close releases history")

    let pending=SpeakerPipeline(source:"remote",epoch:"history-pending",syntheticInput:true)
    _=try await pending.syntheticTimelineRevision([frame(0,0.30,[5],1,epoch:"history-pending")],revision:1)
    var early=event("early-slot",0.05,0.20,epoch:"history-pending");early["text"]="稍早到达"
    let earlyEvent=await pending.accept(early)
    check((earlyEvent["speaker"] as? [String:Any])?["reason"] as? String=="slot_not_matured","early transcript waits for slot maturity")
    let promotedUpdates=try await pending.syntheticTimelineAppend([frame(0.30,0.80,[5],2,epoch:"history-pending")])
    check(promotedUpdates.count==1 && (promotedUpdates[0]["speaker"] as? [String:Any])?["cluster_id"] as? Int==5 && promotedUpdates[0]["annotation_only"] as? Bool==true,"promotion incrementally refreshes pending segment")
    _=try await pending.close(flush:false)

    // Features are generated independently of ASR and retained after model input
    // ends. A late long final can use only a contained same-slot tile.
    let features=SpeakerPipeline(source:"remote",epoch:"features",syntheticInput:true)
    _=try await features.syntheticTimelineRevision([frame(0,10,[0],1,epoch:"features"),frame(10,20,[1],1,epoch:"features")],revision:1)
    let vector=EmbeddingVector(values:[Float](repeating:0.1,count:192),partition:SpeakerEmbeddingBackend.partition,inputKind:"synthetic_model_output")
    try await features.syntheticFeatureEvidence(SpeakerFeatureEvidence(start:2,end:4,slot:0,vector:vector))
    _=try await features.finishInput(flush:false)
    var longFinal=event("late-feature",0,9,epoch:"features");longFinal["received_at"]=318.0
    let withFeature=await features.accept(longFinal)
    check((withFeature["identity_features"] as? [String:Any])?["evidence_start"] as? Double==2,"late long final retains its original feature after model release")
    var mixed=event("mixed-feature",0,20,epoch:"features")
    mixed["text"]="第一人第二人";mixed["word_spans"]=[["text":"第一人","start":0.0,"end":10.0],["text":"第二人","start":10.0,"end":20.0]]
    let mixedResult=await features.accept(mixed),mixedRuns=mixedResult["speaker_runs"] as? [[String:Any]] ?? []
    check(mixedResult["identity_features"]==nil && mixedRuns.count==2 && mixedRuns[0]["identity_features"] != nil && mixedRuns[1]["identity_features"]==nil,"clear child turn retains own voice feature when parent has speaker change")
    let otherVoice=await features.accept(event("other-voice",10,19,epoch:"features"))
    check(otherVoice["identity_features"]==nil,"neighboring person cannot borrow feature")
    let outsideSpan=await features.accept(event("outside-span",5,9,epoch:"features"))
    check(outsideSpan["identity_features"]==nil,"feature outside sentence cannot be borrowed")
    let delayedFeatures=SpeakerPipeline(source:"remote",epoch:"features",syntheticInput:true)
    _=try await delayedFeatures.syntheticTimelineRevision([frame(0,10,[0],1,epoch:"features")],revision:1)
    let beforeFeature=await delayedFeatures.accept(event("before-feature",0,9,epoch:"features"))
    check(beforeFeature["identity_features"]==nil,"final ASR can precede embedding result")
    try await delayedFeatures.syntheticFeatureEvidence(SpeakerFeatureEvidence(start:2,end:4,slot:0,vector:vector))
    let delivered=await delayedFeatures.drainFeatureUpdates()
    check(delivered.count==1 && delivered[0]["annotation_only"] as? Bool==true && delivered[0]["text"] as? String==beforeFeature["text"] as? String && (delivered[0]["revision"] as? Int ?? 0)>(beforeFeature["revision"] as? Int ?? 0),"late embedding publishes current final without new PCM or changed words")
    let drainedAgain=await delayedFeatures.drainFeatureUpdates();check(drainedAgain.isEmpty,"late feature delivered once")
    _=await delayedFeatures.accept(event("superseded-feature",5,9,epoch:"features"))
    try await delayedFeatures.syntheticFeatureEvidence(SpeakerFeatureEvidence(start:6,end:8,slot:0,vector:vector))
    var changed=event("superseded-feature",8.1,9,epoch:"features");changed["revision"]=2
    let newer=await delayedFeatures.accept(changed)
    check(newer["identity_features"]==nil,"changed ASR span cannot retain an out-of-span feature")
    let stale=await delayedFeatures.drainFeatureUpdates();check(stale.isEmpty,"new ASR supersedes queued feature revision")
    _=try await delayedFeatures.close(flush:false)
    let liveForbidden=SpeakerPipeline(source:"remote",epoch:"features")
    do {try await liveForbidden.syntheticFeatureEvidence(SpeakerFeatureEvidence(start:2,end:4,slot:0,vector:vector));preconditionFailure()}catch{check(true,"synthetic feature insertion forbidden for real input")}
    _=try await features.close(flush:false);let featureClosed=await features.status()
    check(featureClosed["retained_feature_tiles"] as? Int==0,"close releases meeting-local feature vectors")

    return ["type":"speaker_history_checks","passed":passed,"delayed_final_seconds":309,
            "history_limit_seconds":SpeakerTimeline.maximumHistorySeconds,"two_hour_frames_retained":720_000,
            "two_hour_compressed_runs":twoHours.compressedRunCount,"two_hour_revision_spans":twoHours.revisionSpanCount,
            "one_hour_append_seconds":oneHourSeconds,"two_hour_append_seconds":twoHourSeconds,"two_hour_to_one_hour_elapsed_ratio":linearScale,"indexed_runs":indexed.compressedRunCount,
            "indexed_binary_comparisons":search.binarySearchComparisons,"indexed_candidate_runs":search.candidateRunCount,
            "capture":false,"cloud":false,"model_loaded":false]
}
