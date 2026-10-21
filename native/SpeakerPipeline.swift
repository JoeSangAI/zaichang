import Foundation

private struct SpeakerRevisionSpan {
    var start:Double
    var end:Double
    let revision:Int
    let frameStep:Double?
    var frameCount:Int
}

private struct SpeakerEvidenceRun {
    var sourceID:String
    var epoch:String
    var activeSlots:[Int]
    var start:Double
    var end:Double
    var revisions:[SpeakerRevisionSpan]

    func matches(_ frame:SpeakerFrame)->Bool {
        sourceID==frame.sourceID && epoch==frame.epoch && activeSlots==frame.activeSlots.sorted()
    }
}

struct SpeakerTimelineSearchWork {
    let binarySearchComparisons:Int
    let candidateRunCount:Int
}

// Shared with capture and offline native UI. Source namespaces never imply a person.
// Adjacent 10 ms evidence is run-length encoded and retained for the two-hour
// session budget. `frames` remains an expanded compatibility view for offline use.
struct SpeakerTimeline {
    static let frameDuration=0.01
    static let maximumHistorySeconds=7200.0
    private static let timeTolerance=1e-7
    private static let intersectionTolerance=1e-8

    private var evidenceRuns:[SpeakerEvidenceRun]=[]
    private var prefixMaximumEnds:[Double]=[]
    private var storedFrameCount=0
    private(set) var maturedSpeakerSlots=Set<Int>()
    private var slotSoloSeconds:[Int:Double]=[:]
    private var slotLongestSoloSeconds:[Int:Double]=[:]
    private var activeSoloSlot:Int?
    private var activeSoloStart:Double?
    private var activeSoloEnd:Double?
    private(set) var historyOrigin:Double?
    private(set) var historyLimitReached=false
    var revision=0

    var frames:[SpeakerFrame] {
        var result:[SpeakerFrame]=[]
        for run in evidenceRuns {
            for span in run.revisions {
                if let step=span.frameStep {
                    for index in 0..<span.frameCount {
                        let start=span.start+Double(index)*step
                        let end=min(start+step,span.end)
                        if end>start {result.append(SpeakerFrame(sourceID:run.sourceID,epoch:run.epoch,revision:span.revision,start:start,end:end,activeSlots:run.activeSlots))}
                    }
                } else if span.end>span.start {
                    result.append(SpeakerFrame(sourceID:run.sourceID,epoch:run.epoch,revision:span.revision,start:span.start,end:span.end,activeSlots:run.activeSlots))
                }
            }
        }
        return result
    }
    // Exact logical frame count, cached so status/diagnostic reads stay O(1).
    var retainedFrameCount:Int {storedFrameCount}
    var revisionSpanCount:Int {evidenceRuns.reduce(0){$0+$1.revisions.count}}
    var compressedRunCount:Int {evidenceRuns.count}
    var firstFrameStart:Double? {evidenceRuns.first?.start}
    var lastFrameEnd:Double? {prefixMaximumEnds.last}
    var historyEndLimit:Double? {historyOrigin.map{$0+Self.maximumHistorySeconds}}

    mutating func setHistoryOriginIfNeeded(_ origin:Double) {
        guard historyOrigin==nil,origin.isFinite else{return}
        historyOrigin=origin
    }

    mutating func append(_ incoming:[SpeakerFrame]) {
        guard !incoming.isEmpty else{return}
        if historyOrigin==nil,let first=incoming.map(\.start).filter({$0.isFinite}).min(){historyOrigin=first}
        var reordered=false
        for frame in incoming where frame.start.isFinite && frame.end.isFinite && frame.end>frame.start {
            if let last=evidenceRuns.last,frame.start<last.end-Self.timeTolerance {reordered=true}
            if appendBounded(frame) {storedFrameCount+=1;if !reordered {updateMaturity(frame)}}
            revision=max(revision,frame.revision)
        }
        if reordered {rebuildMaturity()}
    }

    mutating func replace(_ incoming:[SpeakerFrame],revision next:Int) {
        guard next>revision else{return}
        evidenceRuns=[];prefixMaximumEnds=[];storedFrameCount=0;historyLimitReached=false
        maturedSpeakerSlots=[];slotSoloSeconds=[:];slotLongestSoloSeconds=[:];activeSoloSlot=nil;activeSoloStart=nil;activeSoloEnd=nil
        if historyOrigin==nil,let first=incoming.map(\.start).filter({$0.isFinite}).min(){historyOrigin=first}
        for frame in incoming where frame.start.isFinite && frame.end.isFinite && frame.end>frame.start {
            if appendBounded(frame) {storedFrameCount+=1;updateMaturity(frame)}
        }
        revision=next
    }

    mutating func clear() {
        evidenceRuns=[];prefixMaximumEnds=[];storedFrameCount=0;historyOrigin=nil;historyLimitReached=false;revision=0
        maturedSpeakerSlots=[];slotSoloSeconds=[:];slotLongestSoloSeconds=[:];activeSoloSlot=nil;activeSoloStart=nil;activeSoloEnd=nil
    }

    private mutating func updateMaturity(_ frame:SpeakerFrame) {
        let slots=frame.activeSlots.sorted(),duration=frame.end-frame.start
        guard slots.count==1 else {finishSoloRun(at:frame.start);return}
        let slot=slots[0]
        if activeSoloSlot==slot,let end=activeSoloEnd,abs(end-frame.start)<=Self.timeTolerance {
            activeSoloEnd=frame.end
        } else {
            finishSoloRun(at:frame.start);activeSoloSlot=slot;activeSoloStart=frame.start;activeSoloEnd=frame.end
        }
        slotSoloSeconds[slot,default:0]+=duration
        if let start=activeSoloStart {slotLongestSoloSeconds[slot]=max(slotLongestSoloSeconds[slot] ?? 0,frame.end-start)}
        // Engineering gate, not a calibrated confidence score or a speaker cap.
        if (slotSoloSeconds[slot] ?? 0)+Self.timeTolerance>=0.8 && (slotLongestSoloSeconds[slot] ?? 0)+Self.timeTolerance>=0.4 {
            maturedSpeakerSlots.insert(slot)
        }
    }

    private mutating func rebuildMaturity() {
        maturedSpeakerSlots=[];slotSoloSeconds=[:];slotLongestSoloSeconds=[:];activeSoloSlot=nil;activeSoloStart=nil;activeSoloEnd=nil
        for run in evidenceRuns {
            updateMaturity(SpeakerFrame(sourceID:run.sourceID,epoch:run.epoch,revision:revision,start:run.start,end:run.end,activeSlots:run.activeSlots))
        }
    }

    private mutating func finishSoloRun(at time:Double) {
        if let slot=activeSoloSlot,let start=activeSoloStart {
            slotLongestSoloSeconds[slot]=max(slotLongestSoloSeconds[slot] ?? 0,min(time,activeSoloEnd ?? time)-start)
        }
        activeSoloSlot=nil;activeSoloStart=nil;activeSoloEnd=nil
    }

    @discardableResult private mutating func appendBounded(_ original:SpeakerFrame)->Bool {
        var frame=SpeakerFrame(sourceID:original.sourceID,epoch:original.epoch,revision:original.revision,
                               start:original.start,end:original.end,activeSlots:original.activeSlots.sorted())
        if let limit=historyEndLimit {
            if frame.end>limit+Self.timeTolerance {historyLimitReached=true}
            if frame.start>=limit-Self.timeTolerance {return false}
            if frame.end>limit {frame=SpeakerFrame(sourceID:frame.sourceID,epoch:frame.epoch,revision:frame.revision,start:frame.start,end:limit,activeSlots:frame.activeSlots)}
        }
        guard frame.end>frame.start else{return false}

        // Avoid binding the final run to a local value: SpeakerEvidenceRun owns
        // a revisions array, and retaining that value across the mutation below
        // triggers copy-on-write of the entire span history for every append.
        if !evidenceRuns.isEmpty && frame.start>=evidenceRuns[evidenceRuns.count-1].start-Self.timeTolerance {
            let index=evidenceRuns.count-1
            let extendsLastRun=evidenceRuns[index].matches(frame) && abs(evidenceRuns[index].end-frame.start)<=Self.timeTolerance
            if extendsLastRun {
                Self.appendFrame(frame,to:&evidenceRuns[index])
                prefixMaximumEnds[index]=max(index==0 ? -Double.infinity : prefixMaximumEnds[index-1],evidenceRuns[index].end)
            } else {
                evidenceRuns.append(makeRun(frame))
                prefixMaximumEnds.append(max(prefixMaximumEnds.last ?? -Double.infinity,frame.end))
            }
            return true
        }

        let insertion=lowerBoundRunStart(frame.start)
        evidenceRuns.insert(makeRun(frame),at:insertion)
        rebuildPrefixMaximumEnds(from:insertion)
        coalesceNeighbors(around:insertion)
        return true
    }

    private func makeRun(_ frame:SpeakerFrame)->SpeakerEvidenceRun {
        SpeakerEvidenceRun(sourceID:frame.sourceID,epoch:frame.epoch,activeSlots:frame.activeSlots.sorted(),start:frame.start,end:frame.end,
                           revisions:[Self.makeRevisionSpan(frame)])
    }

    private static func makeRevisionSpan(_ frame:SpeakerFrame)->SpeakerRevisionSpan {
        let step=(frame.end-frame.start<=Self.frameDuration+Self.timeTolerance) ? Self.frameDuration : nil
        return SpeakerRevisionSpan(start:frame.start,end:frame.end,revision:frame.revision,frameStep:step,frameCount:1)
    }

    private static func appendFrame(_ frame:SpeakerFrame,to run:inout SpeakerEvidenceRun) {
        let duration=frame.end-frame.start
        if duration<=Self.frameDuration+Self.timeTolerance,
           let index=run.revisions.indices.last,
           run.revisions[index].revision==frame.revision,
           let step=run.revisions[index].frameStep,
           abs(step-Self.frameDuration)<=Self.timeTolerance,
           abs(run.revisions[index].start+Double(run.revisions[index].frameCount)*step-frame.start)<=Self.timeTolerance {
            run.revisions[index].frameCount+=1;run.revisions[index].end=frame.end
        } else {
            run.revisions.append(makeRevisionSpan(frame))
        }
        run.end=max(run.end,frame.end)
    }

    private mutating func coalesceNeighbors(around initial:Int) {
        guard !evidenceRuns.isEmpty else{return}
        var index=min(initial,evidenceRuns.count-1)
        if index>0,canMerge(evidenceRuns[index-1],evidenceRuns[index]) {merge(index,into:index-1);index-=1}
        if index+1<evidenceRuns.count,canMerge(evidenceRuns[index],evidenceRuns[index+1]) {merge(index+1,into:index)}
        rebuildPrefixMaximumEnds(from:max(0,index))
    }

    private func canMerge(_ left:SpeakerEvidenceRun,_ right:SpeakerEvidenceRun)->Bool {
        left.sourceID==right.sourceID && left.epoch==right.epoch && left.activeSlots==right.activeSlots &&
        abs(left.end-right.start)<=Self.timeTolerance
    }

    private mutating func merge(_ sourceIndex:Int,into destinationIndex:Int) {
        var left=evidenceRuns[destinationIndex];let right=evidenceRuns[sourceIndex]
        left.revisions.append(contentsOf:right.revisions);left.end=max(left.end,right.end)
        evidenceRuns[destinationIndex]=left;evidenceRuns.remove(at:sourceIndex)
    }

    private func lowerBoundRunStart(_ value:Double)->Int {
        var low=0,high=evidenceRuns.count
        while low<high {let middle=(low+high)/2;if evidenceRuns[middle].start<value {low=middle+1}else{high=middle}}
        return low
    }

    private mutating func rebuildPrefixMaximumEnds(from start:Int) {
        var first=max(0,start)
        if prefixMaximumEnds.count != evidenceRuns.count {
            prefixMaximumEnds=Array(repeating:-Double.infinity,count:evidenceRuns.count);first=0
        }
        var maximum=first>0 ? prefixMaximumEnds[first-1] : -Double.infinity
        for index in first..<evidenceRuns.count {maximum=max(maximum,evidenceRuns[index].end);prefixMaximumEnds[index]=maximum}
    }

    private func overlappingRunRange(start:Double,end:Double)->(range:Range<Int>,comparisons:Int) {
        var low=0,high=prefixMaximumEnds.count,comparisons=0
        let target=start+Self.intersectionTolerance
        while low<high {
            comparisons+=1;let middle=(low+high)/2
            if prefixMaximumEnds[middle]<=target {low=middle+1}else{high=middle}
        }
        let first=low;var upper=first
        while upper<evidenceRuns.count && evidenceRuns[upper].start<end-Self.intersectionTolerance {upper+=1}
        return (first..<upper,comparisons)
    }

    func searchWork(start:Double,end:Double)->SpeakerTimelineSearchWork {
        let result=overlappingRunRange(start:start,end:end)
        return SpeakerTimelineSearchWork(binarySearchComparisons:result.comparisons,candidateRunCount:result.range.count)
    }

    func join(_ item:[String:Any],source:String,epoch:String)->[String:Any] {
        guard item["source_id"] as? String==source,item["epoch"] as? String==epoch else{return ["basis":"unknown","reason":"source_or_epoch_mismatch"]}
        guard item["end_time_known"] as? Bool==true,let lo=item["start"] as? Double,let hi=item["end"] as? Double,lo.isFinite,hi.isFinite,hi>lo else{return ["basis":"unknown","reason":"no_reliable_span"]}
        if (item["quality_flags"] as? [String])?.isEmpty==false {return ["basis":"unknown","reason":"asr_quality"]}
        if let limit=historyEndLimit,hi>limit+Self.timeTolerance {return ["basis":"unknown","reason":"speaker_history_limit"]}
        let candidateRange=overlappingRunRange(start:lo,end:hi).range
        var cursor=lo;var voicedSeconds=0.0
        var slotSeconds:[Int:Double]=[:];var longestSlotRun:[Int:Double]=[:];var slotRunStart:[Int:Double]=[:]
        var rawSlotSeconds:[Int:Double]=[:];var longestRawRun:[Int:Double]=[:];var rawRunStart:[Int:Double]=[:]
        var longestOverlap=0.0;var overlapStart:Double?;var overlapSlots=Set<Int>()
        for f in candidateRange.map({evidenceRuns[$0]}) where f.sourceID==source && f.epoch==epoch {
            if f.start>cursor+1e-7 {return ["basis":"unknown","reason":"coverage_gap"]}
            let start=max(lo,f.start,cursor);let end=min(hi,f.end)
            cursor=max(cursor,f.end)
            guard end>start else{continue}
            let rawActive=Set(f.activeSlots)
            for slot in rawRunStart.keys.filter({!rawActive.contains($0)}) {
                longestRawRun[slot]=max(longestRawRun[slot] ?? 0,start-rawRunStart[slot]!);rawRunStart.removeValue(forKey:slot)
            }
            for slot in rawActive {rawSlotSeconds[slot,default:0]+=end-start;if rawRunStart[slot]==nil {rawRunStart[slot]=start}}
            let active=Set(rawActive.filter{maturedSpeakerSlots.contains($0)})
            for slot in slotRunStart.keys.filter({!active.contains($0)}) {
                longestSlotRun[slot]=max(longestSlotRun[slot] ?? 0,start-slotRunStart[slot]!)
                slotRunStart.removeValue(forKey:slot)
            }
            if active.isEmpty {overlapStart=nil;continue}
            voicedSeconds+=end-start
            for slot in active {slotSeconds[slot,default:0]+=end-start;if slotRunStart[slot]==nil {slotRunStart[slot]=start}}
            if active.count>1 {
                if overlapStart==nil {overlapStart=start}
                if end-overlapStart!>longestOverlap {longestOverlap=end-overlapStart!;overlapSlots=active}
            } else {overlapStart=nil}
        }
        guard cursor>=hi-1e-7 else{return ["basis":"unknown","reason":"coverage_gap"]}
        for (slot,start) in rawRunStart {longestRawRun[slot]=max(longestRawRun[slot] ?? 0,min(hi,cursor)-start)}
        guard !slotSeconds.isEmpty else {
            let observed=Set(candidateRange.flatMap{evidenceRuns[$0].activeSlots}).sorted()
            return ["basis":"unknown","reason":observed.isEmpty ? "no_speaker_evidence" : "slot_not_matured","cluster_ids":observed]
        }
        let unstableSupport=max(0.02,min(0.1,voicedSeconds*0.15))
        let unresolved=rawSlotSeconds.keys.filter{!maturedSpeakerSlots.contains($0) &&
            rawSlotSeconds[$0]!+1e-7>=unstableSupport && (longestRawRun[$0] ?? 0)+1e-7>=unstableSupport}.sorted()
        if !unresolved.isEmpty {return ["basis":"unknown","reason":"slot_not_matured","cluster_ids":unresolved]}
        // Engineering guard, not a calibrated accuracy/confidence estimate.
        func shortContinuousEvidence()->[String:Any]? {
            guard hi-lo<=0.35,lo>=0.08 else{return nil}
            let candidates=rawSlotSeconds.keys.filter{maturedSpeakerSlots.contains($0)}
            guard candidates.count==1,let slot=candidates.first,
                  (singleVoiceCoverage(start:lo-0.08,end:lo,slot:slot,source:source,epoch:epoch) ?? 0)>=0.999,
                  (singleVoiceCoverage(start:hi,end:hi+0.08,slot:slot,source:source,epoch:epoch) ?? 0)>=0.999,
                  canBridgeShortWord(start:lo,end:hi,slot:slot,source:source,epoch:epoch) else{return nil}
            return ["basis":"anonymous_cluster","cluster_id":slot,"source_id":source,"epoch":epoch,"revision":revision,"contextual_fill":true]
        }
        guard voicedSeconds>=min(0.1,hi-lo)-1e-7,voicedSeconds/(hi-lo)>=0.2 else{return shortContinuousEvidence() ?? ["basis":"unknown","reason":"insufficient_voiced_evidence"]}
        for (slot,start) in slotRunStart {longestSlotRun[slot]=max(longestSlotRun[slot] ?? 0,min(hi,cursor)-start)}
        // A 10 ms model spike must not label an entire word or sentence as multiple.
        // A sustained second voice or turn still needs its own continuous evidence.
        let support=max(0.02,min(0.1,voicedSeconds*0.15))
        if longestOverlap+1e-7>=support {return ["basis":"multiple","reason":"overlap","cluster_ids":overlapSlots.sorted()]}
        let supported=slotSeconds.keys.filter{slotSeconds[$0]!+1e-7>=support && (longestSlotRun[$0] ?? 0)+1e-7>=support}.sorted()
        guard !supported.isEmpty else{return shortContinuousEvidence() ?? ["basis":"unknown","reason":"insufficient_voiced_evidence"]}
        guard supported.count==1 else{return ["basis":"multiple","reason":"speaker_change","cluster_ids":supported]}
        return ["basis":"anonymous_cluster","cluster_id":supported[0],"source_id":source,"epoch":epoch,"revision":revision]
    }
    static func sameSpeakerEvidence(_ first:[String:Any],_ second:[String:Any])->Bool {
        var a=first,b=second
        for key in ["label","revision","contextual_fill","contextual_basis"] {a.removeValue(forKey:key);b.removeValue(forKey:key)}
        return NSDictionary(dictionary:a).isEqual(to:b)
    }

    // Compact evidence for a second pass: count only single, mature voices.
    // Callers align each independent model slot to established meeting slots.
    func soloEvidence(start:Double,end:Double,source:String,epoch:String)->[Int:Double] {
        guard start.isFinite,end.isFinite,end>start else{return [:]}
        var seconds:[Int:Double]=[:]
        for index in overlappingRunRange(start:start,end:end).range {
            let run=evidenceRuns[index]
            guard run.sourceID==source,run.epoch==epoch,run.activeSlots.count==1,
                  let slot=run.activeSlots.first,maturedSpeakerSlots.contains(slot) else{continue}
            seconds[slot,default:0]+=max(0,min(end,run.end)-max(start,run.start))
        }
        return seconds
    }

    func singleVoiceCoverage(start:Double,end:Double,slot:Int,source:String,epoch:String)->Double? {
        guard end>start else{return nil}
        let range=overlappingRunRange(start:start,end:end).range
        var cursor=start,voiced=0.0
        for run in range.map({evidenceRuns[$0]}) {
            guard run.sourceID==source,run.epoch==epoch,run.start<=cursor+1e-7,
                  run.activeSlots.allSatisfy({$0==slot}) else{return nil}
            let lo=max(start,run.start,cursor),hi=min(end,run.end);cursor=max(cursor,run.end)
            if hi>lo,run.activeSlots==[slot] {voiced+=hi-lo}
        }
        guard cursor>=end-1e-7 else{return nil};return voiced/(end-start)
    }
    private func canBridgeShortWord(start:Double,end:Double,slot:Int,source:String,epoch:String)->Bool {
        guard end>start,end-start<=0.35 else{return false}
        let range=overlappingRunRange(start:start,end:end).range
        guard !range.isEmpty else{return false}
        var cursor=start,voiced=0.0
        for run in range.map({evidenceRuns[$0]}) {
            guard run.sourceID==source,run.epoch==epoch else{return false}
            if run.start>cursor+1e-7{return false}
            let lo=max(start,run.start,cursor),hi=min(end,run.end)
            cursor=max(cursor,run.end)
            guard hi>lo else{continue}
            let rawActive=Set(run.activeSlots)
            if rawActive.contains(where:{$0 != slot}) || rawActive.count>1{return false}
            if rawActive.contains(slot){voiced+=hi-lo}
        }
        return cursor>=end-1e-7 && voiced>=max(min(Self.frameDuration,end-start),(end-start)*0.5)-1e-7
    }
    // Reusable for live annotation and read-only replay of a saved, fully timed timeline.
    func annotateWords(_ item:inout [String:Any],source:String,epoch:String) {
        item.removeValue(forKey:"speaker_runs")
        guard item["end_time_known"] as? Bool==true,
              let start=item["start"] as? Double,let end=item["end"] as? Double,
              start.isFinite,end.isFinite,end>start,
              let original=item["text"] as? String,
              let words=item["word_spans"] as? [[String:Any]],!words.isEmpty,words.count<=1000 else{return}
        var validated:[[String:Any]]=[];var cursor=start;var combined=""
        for word in words {
            guard let lo=word["start"] as? Double,let hi=word["end"] as? Double,
                  lo.isFinite,hi.isFinite,lo>=cursor,hi>lo,hi<=end,
                  let body=word["text"] as? String,!body.isEmpty else{return}
            validated.append(word);combined+=body;cursor=hi
        }
        guard combined==original else{return}
        var speakers:[[String:Any]]=[]
        for word in validated {
            var fragment=item;fragment["start"]=word["start"];fragment["end"]=word["end"]
            var speaker=join(fragment,source:source,epoch:epoch)
            speaker["label"]=anonymousSpeakerLabel(speaker,track:source)
            speakers.append(speaker)
        }
        // Work from the original word decisions, so an inferred word cannot
        // become an anchor for another inference. Never borrow a human name,
        // another source, or a second speaker's evidence.
        let originalSpeakers=speakers
        var index=0
        while index<validated.count {
            guard originalSpeakers[index]["basis"] as? String=="unknown" else{index+=1;continue}
            let first=index
            while index<validated.count,originalSpeakers[index]["basis"] as? String=="unknown" {index+=1}
            let last=index-1
            guard (first...last).allSatisfy({originalSpeakers[$0]["reason"] as? String=="insufficient_voiced_evidence"}),
                  last-first<4 else{continue}
            let prior=first>0 ? originalSpeakers[first-1]:nil
            let next=index<validated.count ? originalSpeakers[index]:nil
            let anchor:[String:Any]
            let edge:Bool
            if let prior=prior,let next=next {
                guard Self.sameSpeakerEvidence(prior,next) else{continue}
                anchor=prior;edge=false
            } else if first==0,let next=next {anchor=next;edge=true}
            else if index==validated.count,let prior=prior {anchor=prior;edge=true}
            else {continue} // An entirely unknown utterance has no trusted anchor.
            guard anchor["basis"] as? String=="anonymous_cluster",
                  anchor["source_id"] as? String==source,anchor["epoch"] as? String==epoch,
                  let slot=anchor["cluster_id"] as? Int,maturedSpeakerSlots.contains(slot),
                  let lo=validated[first]["start"] as? Double,
                  let hi=validated[last]["end"] as? Double,
                  hi-lo<=(edge ? 0.35:0.60)+Self.timeTolerance else{continue}
            // ASR word timestamps can include a brief unvoiced boundary or
            // breath. Only a final, acoustically single-speaker parent permits
            // that tolerance. Every word still needs its own voice evidence.
            let parentSpeaker=join(item,source:source,epoch:epoch)
            let strongParent=item["final"] as? Bool==true && parentSpeaker["basis"] as? String=="anonymous_cluster" &&
                parentSpeaker["cluster_id"] as? Int==slot && singleVoiceCoverage(start:start,end:end,slot:slot,source:source,epoch:epoch) != nil
            if edge {
                guard item["final"] as? Bool==true else{continue}
                if !strongParent {
                    let a=first==0 ? hi:lo-0.08, b=first==0 ? hi+0.08:lo
                    guard (singleVoiceCoverage(start:a,end:b,slot:slot,source:source,epoch:epoch) ?? 0)>=0.999 else{continue}
                }
            }
            var safe=true
            for wordIndex in first...last {
                let a=validated[wordIndex]["start"] as! Double,b=validated[wordIndex]["end"] as! Double
                guard let fraction=singleVoiceCoverage(start:a,end:b,slot:slot,source:source,epoch:epoch),
                      fraction+Self.timeTolerance >= (edge ? (strongParent ? 0.30:0.50):0.20),
                      fraction*(b-a)+Self.timeTolerance >= min(edge && strongParent ? 0.03:0.02,b-a) else{safe=false;break}
            }
            guard safe else{continue}
            // Include every inter-word gap and both joins to the anchors.
            // A strong parent permits at most 80 ms of covered breathing room;
            // a missing clock interval or any competing raw slot always blocks.
            let connectionStart=first>0 ? first:1
            let connectionEnd=index<validated.count ? index:last
            if connectionStart<=connectionEnd {
                for boundary in connectionStart...connectionEnd {
                    let a=validated[boundary-1]["end"] as! Double,b=validated[boundary]["start"] as! Double
                    let fraction=b>a ? singleVoiceCoverage(start:a,end:b,slot:slot,source:source,epoch:epoch):1
                    guard b-a<=0.08+Self.timeTolerance,b>=a-Self.timeTolerance,
                          let fraction=fraction,(strongParent || fraction>=0.999) else{safe=false;break}
                }
            }
            guard safe else{continue}
            if strongParent {
                let contextLo=first>0 ? max(start,(validated[first-1]["end"] as! Double)-0.08):lo
                let contextHi=index<validated.count ? min(end,(validated[index]["start"] as! Double)+0.08):hi
                var window=item;window["start"]=contextLo;window["end"]=contextHi
                let joined=join(window,source:source,epoch:epoch)
                guard joined["basis"] as? String=="anonymous_cluster",joined["cluster_id"] as? Int==slot,
                      let fraction=singleVoiceCoverage(start:contextLo,end:contextHi,slot:slot,source:source,epoch:epoch),
                      !edge || fraction+Self.timeTolerance>=0.50 else{continue}
            } else if !edge {
                var island=item;island["start"]=lo;island["end"]=hi
                let joined=join(island,source:source,epoch:epoch)
                let aggregateMatches=joined["basis"] as? String=="anonymous_cluster" && joined["cluster_id"] as? Int==slot
                let originalSingleWordBridge=first==last && canBridgeShortWord(start:lo,end:hi,slot:slot,source:source,epoch:epoch)
                guard aggregateMatches || originalSingleWordBridge else{continue}
            }
            for wordIndex in first...last {
                var bridged=anchor;bridged["contextual_fill"]=true
                bridged["label"]=anonymousSpeakerLabel(bridged,track:source)
                speakers[wordIndex]=bridged
            }
        }
        // A short word before a breath can be inside an ASR sentence, yet at
        // the acoustic end of a phrase. It must not require voice on both sides
        // of that breath. This final-only path uses stronger direct word support
        // (40 ms / 40%) and one tightly bounded acoustic anchor; it never fills
        // silent words, uses a new inference as an anchor, or crosses a voice.
        let whole=join(item,source:source,epoch:epoch)
        if item["final"] as? Bool==true,whole["basis"] as? String=="anonymous_cluster",
           let slot=whole["cluster_id"] as? Int,maturedSpeakerSlots.contains(slot) {
            var position=0
            while position<validated.count {
                guard originalSpeakers[position]["basis"] as? String=="unknown" else{position+=1;continue}
                let first=position
                while position<validated.count,originalSpeakers[position]["basis"] as? String=="unknown" {position+=1}
                let last=position-1,lo=validated[first]["start"] as! Double,hi=validated[last]["end"] as! Double
                guard last-first<4,hi-lo<=0.35+Self.timeTolerance,
                      (first...last).allSatisfy({originalSpeakers[$0]["reason"] as? String=="insufficient_voiced_evidence" && speakers[$0]["basis"] as? String=="unknown"}) else{continue}
                var supported=true
                for wordIndex in first...last {
                    let a=validated[wordIndex]["start"] as! Double,b=validated[wordIndex]["end"] as! Double
                    guard let fraction=singleVoiceCoverage(start:a,end:b,slot:slot,source:source,epoch:epoch),
                          fraction+Self.timeTolerance>=0.40,fraction*(b-a)+Self.timeTolerance>=min(0.04,b-a) else{supported=false;break}
                }
                guard supported else{continue}
                let neighborIndices=[first-1,position].filter{validated.indices.contains($0)}
                // A named different voice or a detected overlap is a boundary,
                // even if the long parent's dominant identity is this slot.
                guard neighborIndices.allSatisfy({neighbor in
                    let speaker=originalSpeakers[neighbor]
                    return speaker["basis"] as? String=="anonymous_cluster" && speaker["cluster_id"] as? Int==slot &&
                        speaker["source_id"] as? String==source && speaker["epoch"] as? String==epoch
                }) else{continue}
                var bridge:[String:Any]?
                for neighbor in neighborIndices {
                    let left=neighbor<first
                    let boundary=validated[neighbor][left ? "end":"start"] as! Double
                    let gap=left ? lo-boundary:boundary-hi
                    guard gap >= -Self.timeTolerance,gap<=0.08+Self.timeTolerance else{continue}
                    let a=left ? max(start,boundary-0.08):lo,b=left ? hi:min(end,boundary+0.08)
                    guard let fraction=singleVoiceCoverage(start:a,end:b,slot:slot,source:source,epoch:epoch),fraction+Self.timeTolerance>=0.50 else{continue}
                    var window=item;window["start"]=a;window["end"]=b
                    let joined=join(window,source:source,epoch:epoch)
                    guard joined["basis"] as? String=="anonymous_cluster",joined["cluster_id"] as? Int==slot else{continue}
                    bridge=originalSpeakers[neighbor];break
                }
                guard var bridge=bridge else{continue}
                bridge["contextual_fill"]=true;bridge["label"]=anonymousSpeakerLabel(bridge,track:source)
                for wordIndex in first...last {speakers[wordIndex]=bridge}
            }
        }
        // Provider word ends are not phoneme boundaries. A short final word
        // can include the unvoiced tail of a well-evidenced phrase. Resolve the
        // bounded phrase against original acoustic anchors, rather than asking
        // each character to contain a standalone speaker sample.
        if item["final"] as? Bool==true {
            var position=0
            let recoverableReasons:Set<String>=["insufficient_voiced_evidence","no_speaker_evidence"]
            while position<validated.count {
                guard originalSpeakers[position]["basis"] as? String=="unknown",
                      recoverableReasons.contains(originalSpeakers[position]["reason"] as? String ?? "") else{position+=1;continue}
                let first=position
                while position<validated.count,originalSpeakers[position]["basis"] as? String=="unknown",
                      recoverableReasons.contains(originalSpeakers[position]["reason"] as? String ?? "") {position+=1}
                let last=position-1,lo=validated[first]["start"] as! Double,hi=validated[last]["end"] as! Double
                guard last-first<4,hi-lo>=0.04-Self.timeTolerance,hi-lo<=0.60+Self.timeTolerance else{continue}
                let neighbors=[first-1,position].filter{validated.indices.contains($0)}
                guard let anchorIndex=neighbors.first else{continue}
                let anchor=originalSpeakers[anchorIndex]
                guard anchor["basis"] as? String=="anonymous_cluster",let slot=anchor["cluster_id"] as? Int,
                      maturedSpeakerSlots.contains(slot),neighbors.allSatisfy({Self.sameSpeakerEvidence(originalSpeakers[$0],anchor)}),
                      let direct=singleVoiceCoverage(start:lo,end:hi,slot:slot,source:source,epoch:epoch),
                      hi-lo<=0.30+Self.timeTolerance || direct*(hi-lo)>=0.04-Self.timeTolerance else{continue}
                // With no local model voice at all, only a short timestamp tail
                // inside a completely single-speaker parent can inherit its
                // phrase. A mixed parent, isolated utterance or long silence
                // remains unresolved.
                if direct*(hi-lo)<0.02-Self.timeTolerance {
                    guard hi-lo<=0.25+Self.timeTolerance,whole["basis"] as? String=="anonymous_cluster",
                          whole["cluster_id"] as? Int==slot,
                          singleVoiceCoverage(start:start,end:end,slot:slot,source:source,epoch:epoch) != nil else{continue}
                }
                var supported=false
                for neighbor in neighbors {
                    let left=neighbor<first,boundary=validated[neighbor][left ? "end":"start"] as! Double
                    let gap=left ? lo-boundary:boundary-hi
                    guard gap >= -Self.timeTolerance,gap<=0.08+Self.timeTolerance else{continue}
                    let a=left ? max(start,boundary-0.35):lo,b=left ? hi:min(end,boundary+0.35)
                    guard let fraction=singleVoiceCoverage(start:a,end:b,slot:slot,source:source,epoch:epoch),
                          fraction>=0.50-Self.timeTolerance,fraction*(b-a)>=0.20-Self.timeTolerance else{continue}
                    var phrase=item;phrase["start"]=a;phrase["end"]=b
                    let evidence=join(phrase,source:source,epoch:epoch)
                    guard evidence["basis"] as? String=="anonymous_cluster",evidence["cluster_id"] as? Int==slot else{continue}
                    supported=true;break
                }
                if supported {
                    var speaker=anchor;speaker["contextual_fill"]=true;speaker["contextual_basis"]="bounded_phrase"
                    for wordIndex in first...last {speakers[wordIndex]=speaker}
                }
            }
        }
        var runs:[[String:Any]]=[]
        for (index,word) in validated.enumerated() {
            let speaker=speakers[index]
            if var last=runs.last,let prior=last["speaker"] as? [String:Any],
               Self.sameSpeakerEvidence(prior,speaker) {
                last["text"]=(last["text"] as! String)+(word["text"] as! String)
                last["end"]=word["end"];runs[runs.count-1]=last
            } else {var run=word;run["speaker"]=speaker;runs.append(run)}
        }
        if runs.count>1 {item["speaker_runs"]=runs}
        else if let single=runs.first?["speaker"] as? [String:Any],
                single["basis"] as? String=="anonymous_cluster",
                let slot=single["cluster_id"] as? Int,
                let parent=item["speaker"] as? [String:Any],parent["basis"] as? String=="unknown",
                parent["reason"] as? String=="insufficient_voiced_evidence",
                singleVoiceCoverage(start:start,end:end,slot:slot,source:source,epoch:epoch) != nil {
            // All timed words agree; the parent's low voiced fraction may be
            // caused by silence between words. Preserve their identity when
            // coalescing the single run, without swallowing another raw voice
            // or a clock gap anywhere in the full parent interval.
            var joined=single;joined["contextual_fill"]=true;item["speaker"]=joined
        }
    }
}
func anonymousSpeakerLabel(_ speaker:[String:Any],track:String)->String {
    switch speaker["basis"] as? String {
    case "anonymous_cluster":return (track=="mic" ? "麦克风" : "远端")+"说话人 "+String((speaker["cluster_id"] as? Int ?? 0)+1)
    case "multiple":return speaker["reason"] as? String=="overlap" ? "多人同时发言" : "句内说话人变化"
    default:return "说话人未知"
    }
}
struct SpeakerFeatureEvidence {
    let start:Double;let end:Double;let slot:Int;let vector:EmbeddingVector
}
struct SpeakerFeatureIndex {
    private(set) var rows:[SpeakerFeatureEvidence]=[]
    static let maximumRows=3600
    @discardableResult mutating func append(_ row:SpeakerFeatureEvidence)->Bool {
        guard rows.count<Self.maximumRows,row.start.isFinite,row.end>row.start,
              rows.last.map({$0.end<=row.start+1e-7}) ?? true else{return false}
        rows.append(row);return true
    }
    func contained(start:Double,end:Double,slot:Int)->SpeakerFeatureEvidence? {
        var lo=0,hi=rows.count
        while lo<hi {let mid=(lo+hi)/2;if rows[mid].start<start-1e-7 {lo=mid+1}else{hi=mid}}
        let center=(start+end)/2
        var best:SpeakerFeatureEvidence?
        for row in rows[lo...] {
            if row.end>end+1e-7 {break}
            if row.slot==slot,best.map({abs((row.start+row.end)/2-center)<abs(($0.start+$0.end)/2-center)}) ?? true {best=row}
        }
        return best
    }
    mutating func clear(){rows=[]}
}
// Recognition-only gain: never changes the journal or ASR samples. A decaying
// peak follower caps amplification at 16x and never attenuates an existing signal.
// State is sample-based so capture packet boundaries cannot change the result.
struct SpeakerInputLeveler {
    private var peak:Float=0
    private(set) var gain:Float=1
    mutating func process(_ samples:[Float])->[Float] {
        samples.map {sample in
            peak=max(abs(sample),peak*0.9999)
            gain=min(16,max(1,0.8/max(peak,0.000001)))
            return sample*gain
        }
    }
}
actor SpeakerPipeline {
    var inputLeveler=SpeakerInputLeveler()
    private var pcmRetentionSamples=96000
    let source:String;let epoch:String
    var backend:LocalSpeakerBackend?;var timeline=SpeakerTimeline();var cursor=0;var origin:Double?
    var segments:[String:[String:Any]]=[:];var order:[String]=[];var transcriptCapacity=TranscriptCapacity();var closed=false;var loaded=false;var inputEnded=false
    var deliverySequence=0;var deliveryRevisions:[String:Int]=[:];var lastReceived=0.0;var clockUptime:Double?
    var embedding:SpeakerEmbeddingBackend?;var pcmWindow:[Float]=[];var pcmBase=0
    var pendingMaturity:[Int:Set<String>]=[:]
    var featureIndex=SpeakerFeatureIndex();var nextFeatureSample=0
    var featureTask:Task<Void,Never>?
    var pendingFeatureUpdates:[String:[String:Any]]=[:]
    var backendCalls=0;var backendSeconds=0.0;var backendMaxSeconds=0.0;var embeddingCalls=0;var embeddingSeconds=0.0;var embeddingMaxSeconds=0.0
    var totalSpeakerFrames=0;var singleSpeakerFrames=0;var overlapSpeakerFrames=0;var unvoicedSpeakerFrames=0
    var annotationCounts:[String:Int]=[:];var unknownReasonCounts:[String:Int]=[:]
    let syntheticInput:Bool
    init(source:String,epoch:String,syntheticInput:Bool=false){self.source=source;self.epoch=epoch;self.syntheticInput=syntheticInput}
    func load(directory:URL,embeddingModel:URL?=nil,longContext:Bool=false) async throws {
        guard !closed,!inputEnded else{throw SpeakerBackendError.closed}
        let value=LocalSpeakerBackend(sourceID:source,epoch:epoch,origin:0)
        try await value.loadLocal(directory:directory,longContext:longContext)
        pcmRetentionSamples=longContext ? 320000:96000
        if closed {await value.release();throw SpeakerBackendError.closed}
        if let model=embeddingModel {embedding=try SpeakerEmbeddingBackend(model:model)}
        backend=value;loaded=true
    }
    func warmStandby() async throws {
        guard !closed,loaded,let backend=backend else {throw SpeakerBackendError.closed}
        try await backend.warmSyntheticSilence()
    }
    func ingest(_ pcm:Data,captureOrigin:Double) async throws->[[String:Any]] {
        guard !closed,loaded,let backend=backend else{throw SpeakerBackendError.closed}
        guard pcm.count%2==0,pcm.count<=32768,captureOrigin.isFinite,captureOrigin>=0 else{throw SpeakerBackendError.invalidPCM}
        if origin==nil {origin=captureOrigin;clockUptime=ProcessInfo.processInfo.systemUptime-captureOrigin}
        timeline.setHistoryOriginIfNeeded(captureOrigin)
        // The same packet and cursor go to ASR; no second queue, resampling or dropped frames.
        let samples=pcm.withUnsafeBytes {raw in stride(from:0,to:raw.count,by:2).map{Float(Int16(bitPattern:UInt16(raw[$0]) | UInt16(raw[$0+1])<<8))/32768}}
        let samplesForRecognition=inputLeveler.process(samples)
        let modelStart=ProcessInfo.processInfo.systemUptime;let frames=try await backend.append(samplesForRecognition,startSample:cursor,threshold:0.5);let modelSeconds=ProcessInfo.processInfo.systemUptime-modelStart;backendCalls+=1;backendSeconds+=modelSeconds;backendMaxSeconds=max(backendMaxSeconds,modelSeconds);cursor+=samples.count
        pcmWindow.append(contentsOf:samplesForRecognition)
        if pcmWindow.count>pcmRetentionSamples {let remove=pcmWindow.count-pcmRetentionSamples;pcmWindow.removeFirst(remove);pcmBase+=remove}
        if closed {throw SpeakerBackendError.closed}
        let promoted=add(frames);scheduleFeatureEvidence()
        return drainFeatureUpdates()+refreshAfterFrames(frames,promoted:promoted)
    }
    private func refreshAfterFrames(_ frames:[SpeakerFrame],promoted:Set<Int>)->[[String:Any]] {
        guard let first=frames.first,let last=frames.last else{return []}
        // A standalone short ASR span can acquire its strict 80 ms trailing
        // continuity in this batch; revisit only that bounded look-behind.
        var updates=refresh(range:(max(0,first.start+(origin ?? 0)-0.08),last.end+(origin ?? 0)))
        var pending=Set<String>();for slot in promoted {pending.formUnion(pendingMaturity.removeValue(forKey:slot) ?? [])}
        if !pending.isEmpty {updates+=refresh(ids:pending)}
        return updates
    }
    private func add(_ frames:[SpeakerFrame])->Set<Int> {
        let prior=timeline.maturedSpeakerSlots
        let frames=frames.map {frame -> SpeakerFrame in
            guard !frame.activeSlots.isEmpty,frame.activeSlots.contains(where:{!prior.contains($0)}),!pcmWindow.isEmpty else{return frame}
            let lo=Int((frame.start*16000).rounded())-pcmBase,hi=Int((frame.end*16000).rounded())-pcmBase
            guard lo>=0,hi>lo,hi<=pcmWindow.count else{return frame}
            let energy=pcmWindow[lo..<hi].reduce(0.0){$0+Double($1)*Double($1)}/Double(hi-lo)
            if energy<1e-6 {return SpeakerFrame(sourceID:frame.sourceID,epoch:frame.epoch,revision:frame.revision,start:frame.start,end:frame.end,activeSlots:frame.activeSlots.filter{prior.contains($0)})}
            return frame
        }
        for frame in frames {totalSpeakerFrames+=1;if frame.activeSlots.isEmpty {unvoicedSpeakerFrames+=1}else if frame.activeSlots.count==1 {singleSpeakerFrames+=1}else{overlapSpeakerFrames+=1}}
        let offset=origin ?? 0
        timeline.append(frames.map{SpeakerFrame(sourceID:$0.sourceID,epoch:$0.epoch,revision:$0.revision,start:$0.start+offset,end:min($0.end+offset,offset+Double(cursor)/16000),activeSlots:$0.activeSlots)})
        return timeline.maturedSpeakerSlots.subtracting(prior)
    }
    func discard(_ ids:Set<String>) {for id in ids {segments.removeValue(forKey:id);deliveryRevisions.removeValue(forKey:id);pendingFeatureUpdates.removeValue(forKey:id);transcriptCapacity.remove(id);removePendingMaturity(id)};order.removeAll{ids.contains($0)}}
    func accept(_ original:[String:Any])->[String:Any] {
        var item=original;item["source_id"]=source;item["epoch"]=epoch
        guard !closed else{item["speaker"]=["basis":"unknown","reason":"closed"];return item}
        guard let id=item["segment_id"] as? String else{return item}
        guard let bytes=try? JSONSerialization.data(withJSONObject:item),transcriptCapacity.reserve(id,textBytes:(item["text"] as? String ?? "").utf8.count,eventBytes:bytes.count) else {item["speaker"]=["basis":"unknown","reason":"speaker_context_capacity"];item["annotation_capacity_reached"]=true;return item}
        pendingFeatureUpdates.removeValue(forKey:id)
        if segments[id]==nil {order.append(id)}
        item["asr_revision"]=original["revision"];item["annotation_only"]=false
        item["speaker"]=timeline.join(item,source:source,epoch:epoch);features(&item);publish(&item);segments[id]=item;trackPendingMaturity(id,item)
        while order.count>4096 {let old=order.removeFirst();segments.removeValue(forKey:old);deliveryRevisions.removeValue(forKey:old);transcriptCapacity.remove(old);removePendingMaturity(old)}
        return item
    }
    private func featureObject(_ evidence:SpeakerFeatureEvidence)->[String:Any] {
        ["values":evidence.vector.values,"partition":evidence.vector.partition,"input_kind":evidence.vector.inputKind,
         "quality_gate":"single_model_slot_asr_final_unclipped","source_id":source,"epoch":epoch,
         "evidence_start":evidence.start,"evidence_end":evidence.end]
    }
    private func scheduleFeatureEvidence() {
        guard featureTask==nil,!closed,let embedding=embedding,let origin=origin else{return}
        nextFeatureSample=max(nextFeatureSample,((pcmBase+31999)/32000)*32000)
        while nextFeatureSample+32000<=cursor {
            let start=origin+Double(nextFeatureSample)/16000,end=start+2
            let probe:[String:Any]=["source_id":source,"epoch":epoch,"start":start,"end":end,"end_time_known":true]
            let joined=timeline.join(probe,source:source,epoch:epoch)
            if joined["reason"] as? String=="coverage_gap" {return} // Model frames have not caught up yet.
            let lo=nextFeatureSample-pcmBase,hi=lo+32000;nextFeatureSample+=32000
            guard lo>=0,hi<=pcmWindow.count,joined["basis"] as? String=="anonymous_cluster",
                  let slot=joined["cluster_id"] as? Int,
                  (timeline.singleVoiceCoverage(start:start,end:end,slot:slot,source:source,epoch:epoch) ?? 0)>=0.8 else{continue}
            let samples=Array(pcmWindow[lo..<hi])
            guard samples.reduce(0.0,{$0+Double($1)*Double($1)})/Double(samples.count)>=1e-6,
                  samples.filter({abs($0)>=0.98}).count*100<samples.count else{continue}
            let kind=syntheticInput ? "synthetic_model_output":"consented_live_audio"
            // One in-flight tile only. The speaker/control/ASR actors do not
            // wait for embedding inference and no unbounded PCM queue forms.
            featureTask=Task.detached(priority:.utility) { [weak self] in
                let began=ProcessInfo.processInfo.systemUptime
                let vector=try? embedding.extract(samples,qualityOK:true,overlap:false,inputKind:kind)
                await self?.featureComputed(vector,start:start,end:end,slot:slot,seconds:ProcessInfo.processInfo.systemUptime-began)
            }
            return
        }
    }
    private func featureComputed(_ vector:EmbeddingVector?,start:Double,end:Double,slot:Int,seconds:Double) {
        featureTask=nil;embeddingCalls+=1;embeddingSeconds+=seconds;embeddingMaxSeconds=max(embeddingMaxSeconds,seconds)
        guard !closed else{return}
        if let vector {retainFeature(SpeakerFeatureEvidence(start:start,end:end,slot:slot,vector:vector))}
    }
    private func retainFeature(_ evidence:SpeakerFeatureEvidence) {
        guard featureIndex.append(evidence) else{return}
        // Inference may complete after the final ASR event. Publish its feature
        // against the current segment revision without waiting for new speech.
        for id in order {
            guard var item=segments[id],item["final"] as? Bool==true else{continue}
            let units=(item["speaker_runs"] as? [[String:Any]]) ?? [item]
            let eligible=units.contains {unit in
                guard let speaker=unit["speaker"] as? [String:Any],speaker["basis"] as? String=="anonymous_cluster",
                      speaker["cluster_id"] as? Int==evidence.slot,
                      let start=unit["start"] as? Double,let end=unit["end"] as? Double else{return false}
                return unit["identity_features"]==nil && evidence.start>=start && evidence.end<=end
            }
            guard eligible else{continue}
            features(&item);item["annotation_only"]=true
            publish(&item);segments[id]=item;pendingFeatureUpdates[id]=item
        }
    }

    func drainFeatureUpdates()->[[String:Any]] {
        let updates=order.compactMap {id -> [String:Any]? in
            guard let item=pendingFeatureUpdates[id],item["revision"] as? Int==segments[id]?["revision"] as? Int else{return nil}
            return item
        }
        pendingFeatureUpdates.removeAll();return updates
    }
    private func features(_ item:inout [String:Any]) {
        guard item["identity_features"]==nil,item["final"] as? Bool==true,
              let speaker=item["speaker"] as? [String:Any],speaker["basis"] as? String=="anonymous_cluster",
              let slot=speaker["cluster_id"] as? Int,
              let start=item["start"] as? Double,let end=item["end"] as? Double,end>start else{return}
        if let evidence=featureIndex.contained(start:start,end:end,slot:slot) {item["identity_features"]=featureObject(evidence);return}
        // Preserve the precise short-segment path when its PCM is still in the
        // ring. Never race the same extractor's independent tile inference.
        guard featureTask==nil,let embedding=embedding,let origin=origin,(2.0...4.0).contains(end-start) else{return}
        let lo=Int(((start-origin)*16000).rounded())-pcmBase,hi=Int(((end-origin)*16000).rounded())-pcmBase
        guard lo>=0,hi>lo,hi<=pcmWindow.count else{return}
        let samples=Array(pcmWindow[lo..<hi])
        guard samples.reduce(0.0,{$0+Double($1)*Double($1)})/Double(samples.count)>=1e-6,samples.filter({abs($0)>=0.98}).count*100<samples.count else{return}
        let began=ProcessInfo.processInfo.systemUptime;defer{let seconds=ProcessInfo.processInfo.systemUptime-began;embeddingCalls+=1;embeddingSeconds+=seconds;embeddingMaxSeconds=max(embeddingMaxSeconds,seconds)}
        if let vector=try? embedding.extract(samples,qualityOK:true,overlap:false,inputKind:syntheticInput ? "synthetic_model_output":"consented_live_audio") {item["identity_features"]=featureObject(SpeakerFeatureEvidence(start:start,end:end,slot:slot,vector:vector))}
    }
    private func publish(_ item:inout [String:Any]) {
        guard let id=item["segment_id"] as? String else{return}
        deliverySequence+=1;deliveryRevisions[id,default:0]+=1
        item["revision"]=deliveryRevisions[id]!;item["source_seq"]=deliverySequence;item["event_id"]=epoch+":local-delivery:"+String(deliverySequence)
        lastReceived=max(lastReceived,max(item["received_at"] as? Double ?? 0,clockUptime.map{ProcessInfo.processInfo.systemUptime-$0} ?? 0))
        item["received_at"]=lastReceived
        var speaker=item["speaker"] as? [String:Any] ?? [:];speaker["label"]=anonymousSpeakerLabel(speaker,track:source);item["speaker"]=speaker
        timeline.annotateWords(&item,source:source,epoch:epoch)
        let annotatedSpeaker=item["speaker"] as? [String:Any] ?? speaker
        let basis=annotatedSpeaker["basis"] as? String ?? "unknown";annotationCounts[basis,default:0]+=1
        if basis=="unknown" {unknownReasonCounts[annotatedSpeaker["reason"] as? String ?? "unknown",default:0]+=1}
        if var runs=item["speaker_runs"] as? [[String:Any]] {
            for index in runs.indices {
                var leaf=item;leaf.removeValue(forKey:"speaker_runs");leaf.removeValue(forKey:"identity_features")
                for (key,value) in runs[index] {leaf[key]=value}
                features(&leaf)
                if let feature=leaf["identity_features"] {runs[index]["identity_features"]=feature}
            }
            item["speaker_runs"]=runs
        }
        item["local_speaker_model"]="nemotron3-low:25a90f97f254428d4b30374b76af9c74fdee8327"
    }
    private func trackPendingMaturity(_ id:String,_ item:[String:Any]) {
        func collect(_ value:[String:Any],into result:inout Set<Int>) {
            guard value["basis"] as? String=="unknown",value["reason"] as? String=="slot_not_matured" else{return}
            result.formUnion(value["cluster_ids"] as? [Int] ?? [])
        }
        var slots=Set<Int>();collect(item["speaker"] as? [String:Any] ?? [:],into:&slots)
        for run in item["speaker_runs"] as? [[String:Any]] ?? [] {collect(run["speaker"] as? [String:Any] ?? [:],into:&slots)}
        for slot in slots {pendingMaturity[slot,default:[]].insert(id)}
    }
    private func removePendingMaturity(_ id:String) {
        for slot in Array(pendingMaturity.keys) {pendingMaturity[slot]?.remove(id);if pendingMaturity[slot]?.isEmpty==true {pendingMaturity.removeValue(forKey:slot)}}
    }
    private func refresh(range:(Double,Double)?=nil,ids:Set<String>?=nil)->[[String:Any]] {
        var changed:[[String:Any]]=[]
        for id in (ids.map{wanted in order.filter{wanted.contains($0)}} ?? order) {
            guard var item=segments[id],let end=item["end"] as? Double,end>=(timeline.firstFrameStart ?? Double.greatestFiniteMagnitude) else{continue}
            if let range=range,let start=item["start"] as? Double,!(end>range.0 && start<range.1) {continue}
            let next=timeline.join(item,source:source,epoch:epoch)
            var prior=item["speaker"] as? [String:Any] ?? [:];var semantic=next
            prior.removeValue(forKey:"revision");prior.removeValue(forKey:"label");semantic.removeValue(forKey:"revision")
            let oldRuns=item["speaker_runs"] as? [[String:Any]] ?? [];if !NSDictionary(dictionary:prior).isEqual(to:semantic) {item.removeValue(forKey:"identity_features")};item["speaker"]=next;timeline.annotateWords(&item,source:source,epoch:epoch);segments[id]=item;removePendingMaturity(id);trackPendingMaturity(id,item)
            let newRuns=item["speaker_runs"] as? [[String:Any]] ?? []
            var annotated=item["speaker"] as? [String:Any] ?? [:]
            annotated.removeValue(forKey:"revision");annotated.removeValue(forKey:"label")
            if !NSDictionary(dictionary:prior).isEqual(to:annotated) || !NSArray(array:oldRuns).isEqual(to:newRuns) {item["annotation_only"]=true;features(&item);publish(&item);segments[id]=item;changed.append(item)}
        }
        return changed
    }
    // Capture/model input can finish long before a delayed ASR result. Release
    // expensive inference state now, while keeping the compact evidence index.
    func finishInput(flush:Bool=true) async throws->[[String:Any]] {
        guard !closed,!inputEnded else{return []};inputEnded=true
        var updates:[[String:Any]]=[];var failure:Error?
        if let backend=backend {
            if flush {do {add(try await backend.finish(threshold:0.5));scheduleFeatureEvidence();updates=refresh()}catch{failure=error}}
            await backend.release()
        }
        if let task=featureTask {await task.value};featureTask=nil
        updates+=drainFeatureUpdates()
        backend=nil;embedding?.close();embedding=nil;pcmWindow=[];pcmBase=cursor;loaded=false
        if let failure {throw failure}
        return updates
    }
    func close(flush:Bool) async throws->[[String:Any]] {
        guard !closed else{return []};closed=true
        if let task=featureTask {await task.value};featureTask=nil;featureIndex.clear();pendingFeatureUpdates.removeAll()
        var updates:[[String:Any]]=[]
        if let backend=backend {
            if flush {
                do {let tail=try await backend.finish(threshold:0.5);add(tail);updates=refresh()}
                catch {await backend.release();self.backend=nil;embedding?.close();embedding=nil;pcmWindow=[];pcmBase=cursor;loaded=false;timeline.clear();segments=[:];order=[];deliveryRevisions=[:];pendingMaturity=[:];transcriptCapacity.reset();throw error}
            }
            await backend.release()
        }
        backend=nil;embedding?.close();embedding=nil;pcmWindow=[];pcmBase=cursor;loaded=false;timeline.clear();segments=[:];order=[];deliveryRevisions=[:];pendingMaturity=[:];transcriptCapacity.reset()
        return updates
    }
    // Explicit synthetic test seam; never reachable for a real-input pipeline.
    func syntheticTimelineRevision(_ frames:[SpeakerFrame],revision:Int) throws->[[String:Any]] {
        guard syntheticInput,!closed else{throw SpeakerBackendError.invalidPCM}
        timeline.replace(frames,revision:revision);return refresh()
    }
    func syntheticTimelineAppend(_ frames:[SpeakerFrame]) throws->[[String:Any]] {
        guard syntheticInput,!closed else{throw SpeakerBackendError.invalidPCM}
        let prior=timeline.maturedSpeakerSlots;timeline.append(frames)
        return refreshAfterFrames(frames,promoted:timeline.maturedSpeakerSlots.subtracting(prior))
    }
    func syntheticFeatureEvidence(_ evidence:SpeakerFeatureEvidence) throws {
        guard syntheticInput,!closed else{throw SpeakerBackendError.invalidPCM};retainFeature(evidence)
    }
    func syntheticFeatureSampling(from sample:Int) throws {
        guard syntheticInput,!closed,loaded,featureTask==nil,sample>=pcmBase,sample+32000<=cursor else{throw SpeakerBackendError.invalidPCM}
        nextFeatureSample=sample;scheduleFeatureEvidence()
    }
    func timingSnapshot()->[String:Any] {["backend_calls":backendCalls,"backend_seconds":backendSeconds,"backend_max_seconds":backendMaxSeconds,"embedding_calls":embeddingCalls,"embedding_seconds":embeddingSeconds,"embedding_max_seconds":embeddingMaxSeconds]}
    func diagnosticSnapshot()->[String:Any] {
        var result:[String:Any]=["speaker_input_gain":Double(inputLeveler.gain),"speaker_feature_tiles":featureIndex.rows.count,"speaker_embedding_calls":embeddingCalls,"speaker_frames_total":totalSpeakerFrames,"speaker_single_frames":singleSpeakerFrames,"speaker_overlap_frames":overlapSpeakerFrames,"speaker_unvoiced_frames":unvoicedSpeakerFrames,"speaker_annotation_known_count":annotationCounts["anonymous_cluster"] ?? 0,"speaker_annotation_unknown_count":annotationCounts["unknown"] ?? 0,"speaker_annotation_multiple_count":annotationCounts["multiple"] ?? 0]
        for reason in ["coverage_gap","speaker_history_limit","no_speaker_evidence","slot_not_matured","insufficient_voiced_evidence","asr_quality","no_reliable_span","source_or_epoch_mismatch"] {result["speaker_unknown_"+reason]=unknownReasonCounts[reason] ?? 0};return result
    }
    func offlineFrames()->[SpeakerFrame] {timeline.frames}
    func finishOfflineFrames() async throws->[SpeakerFrame] {
        guard !closed,let backend=backend else{throw SpeakerBackendError.closed}
        add(try await backend.finish(threshold:0.5));return timeline.frames
    }
    func status()->[String:Any] {["closed":closed,"loaded":loaded,"retained_frames":timeline.retainedFrameCount,"retained_frame_runs":timeline.compressedRunCount,"speaker_history_limit_reached":timeline.historyLimitReached,"speaker_history_limit_seconds":SpeakerTimeline.maximumHistorySeconds,"retained_segments":segments.count,"retained_revision_keys":deliveryRevisions.count,"pending_maturity_segments":Set(pendingMaturity.values.flatMap{$0}).count,"pcm_samples":cursor,"retained_pcm_samples":pcmWindow.count,"retained_feature_tiles":featureIndex.rows.count,"feature_worker_in_flight":featureTask != nil,"embedding_loaded":embedding != nil,"source_id":source,"epoch":epoch]}
}
