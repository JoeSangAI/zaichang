import Foundation

// Whole-recording speaker turns from an independent segmentation/embedding/VBx
// pipeline. Overlapping voices remain explicit; labels never come from text.
struct WholeMeetingSpeakerTimeline {
    struct Span {let start:Double;let end:Double;let voices:Set<String>}
    let spans:[Span]
    init(segments:[OfflineSpeakerSegment],origin:Double,duration:Double) {
        var changes:[Double:[(String,Int)]]=[:]
        for segment in segments {
            let lo=max(0,segment.start),hi=min(duration,segment.end)
            guard lo.isFinite,hi.isFinite,hi>lo,!segment.speakerID.isEmpty else{continue}
            changes[lo+origin,default:[]].append((segment.speakerID,1))
            changes[hi+origin,default:[]].append((segment.speakerID,-1))
        }
        var result:[Span]=[],counts:[String:Int]=[:],previous:Double?
        for time in changes.keys.sorted() {
            if let prior=previous,time>prior {result.append(Span(start:prior,end:time,voices:Set(counts.filter{$0.value>0}.keys)))}
            for (voice,delta) in changes[time]! {counts[voice,default:0]+=delta}
            previous=time
        }
        spans=result
    }
    func evidence(start:Double,end:Double)->(solo:[String:Double],overlap:Double) {
        var lo=0,hi=spans.count
        while lo<hi {let mid=(lo+hi)/2;if spans[mid].end<=start {lo=mid+1}else{hi=mid}}
        var totals:[String:Double]=[:],overlap=0.0,index=lo
        while index<spans.count,spans[index].start<end {
            let span=spans[index],seconds=max(0,min(end,span.end)-max(start,span.start))
            if span.voices.count==1,let voice=span.voices.first {totals[voice,default:0]+=seconds}
            else if span.voices.count>1 {overlap+=seconds}
            index+=1
        }
        return (totals,overlap)
    }
}

enum WholeMeetingSpeakerRefinement {
    struct Alignment {let slot:Int;let seconds:Double;let parents:Int}
    static func mapping(events:[[String:Any]],timeline:WholeMeetingSpeakerTimeline,source:String,epoch:String)->[String:Alignment] {
        var weights:[String:[Int:Double]]=[:],parents:[String:[Int:Set<String>]]=[:]
        var anchors:[(String,[String:Any])]=[]
        for event in events where event["source_id"] as? String==source && event["epoch"] as? String==epoch && event["final"] as? Bool==true && event["end_time_known"] as? Bool==true && (event["quality_flags"] as? [String] ?? []).isEmpty {
            guard let id=event["segment_id"] as? String else{continue}
            anchors+=SpeakerRefinement.units(event).map{(id,$0)}
        }
        anchors.sort{($0.1["start"] as? Double ?? 0)<($1.1["start"] as? Double ?? 0)}
        var previousEnd = -1.0
        for (id,row) in anchors {
            guard let old=SpeakerRefinement.knownSlot(row),let lo=row["start"] as? Double,let hi=row["end"] as? Double,
                  lo.isFinite,hi.isFinite,hi-lo>=0.4,lo>=previousEnd-0.001 else{continue}
            previousEnd=hi
            let evidence=timeline.evidence(start:lo,end:hi)
            // A disputed/overlapping anchor cannot name a global cluster.
            guard evidence.overlap<=0.04 else{continue}
            for (voice,seconds) in evidence.solo where seconds>=0.2 {
                weights[voice,default:[:]][old,default:0]+=seconds
                parents[voice,default:[:]][old,default:[]].insert(id)
            }
        }
        var result:[String:Alignment]=[:]
        for (voice,values) in weights {
            guard let best=values.max(by:{$0.value<$1.value}) else{continue}
            let total=values.values.reduce(0,+),count=parents[voice]?[best.key]?.count ?? 0
            guard best.value>=1.5,count>=2,best.value/total>=0.9,total-best.value<=max(0.2,best.value*0.05) else{continue}
            result[voice]=Alignment(slot:best.key,seconds:best.value,parents:count)
        }
        return result
    }
    // A valid earlier pass may have recovered a short tail that this model did
    // not detect. Keep that recovery, without using it to train/align clusters.
    static func preservingRecoveries(originals:[[String:Any]],previous:[[String:Any]],records:[[String:Any]])throws->[[String:Any]] {
        let previousByID=Dictionary(uniqueKeysWithValues:previous.compactMap{e -> (String,[String:Any])? in guard let id=e["segment_id"] as? String else{return nil};return (id,e)})
        let candidates=Dictionary(uniqueKeysWithValues:records.compactMap{e -> (String,[String:Any])? in guard let id=e["segment_id"] as? String else{return nil};return (id,e)})
        var output:[[String:Any]]=[]
        for event in originals {
            guard let id=event["segment_id"] as? String else{continue}
            let originalRows=SpeakerRefinement.units(event),priorRows=SpeakerRefinement.units(previousByID[id] ?? event)
            let candidate=candidates[id]
            var rows=candidate.map { record in
                let runs=record["speaker_runs"] as? [[String:Any]] ?? []
                if !runs.isEmpty {return runs}
                var row=event;row["speaker"]=record["speaker"];return [row]
            } ?? originalRows
            guard rows.count==originalRows.count,priorRows.count==originalRows.count else{throw Failure(code:"refinement_source_changed")}
            var recovered=false
            for index in rows.indices {
                let original=originalRows[index]["speaker"] as? [String:Any] ?? [:]
                let current=rows[index]["speaker"] as? [String:Any] ?? [:]
                let prior=priorRows[index]["speaker"] as? [String:Any] ?? [:]
                if original["basis"] as? String=="unknown",current["basis"] as? String=="unknown",prior["basis"] as? String=="anonymous_cluster" {
                    rows[index]["speaker"]=prior;recovered=true
                }
            }
            guard candidate != nil || recovered else{continue}
            let originalRuns=event["speaker_runs"] as? [[String:Any]] ?? []
            output.append(["segment_id":id,"original_sha256":try SpeakerRefinementArtifact.originalEventSHA256(event),
                           "speaker":rows.count==1 ? rows[0]["speaker"] ?? [:]:candidate?["speaker"] ?? event["speaker"] ?? [:],
                           "speaker_runs":originalRuns.isEmpty ? []:rows])
        }
        return output
    }
    static func corrections(events:[[String:Any]],timeline:WholeMeetingSpeakerTimeline,source:String,epoch:String,protectedIDs:Set<String>,alignmentEvents:[[String:Any]]?=nil)throws->[[String:Any]] {
        let mapping=mapping(events:alignmentEvents ?? events,timeline:timeline,source:source,epoch:epoch)
        var records:[[String:Any]]=[]
        for event in events {
            guard event["source_id"] as? String==source,event["epoch"] as? String==epoch,
                  event["final"] as? Bool==true,event["end_time_known"] as? Bool==true,
                  (event["quality_flags"] as? [String] ?? []).isEmpty,
                  let id=event["segment_id"] as? String,!protectedIDs.contains(id) else{continue}
            var rows=SpeakerRefinement.units(event),changed=false
            for index in rows.indices {
                let row=rows[index],prior=row["speaker"] as? [String:Any] ?? [:],basis=prior["basis"] as? String
                guard basis=="unknown" || basis=="anonymous_cluster",
                      let start=row["start"] as? Double,let end=row["end"] as? Double,start.isFinite,end.isFinite,end>start,
                      !protectedIDs.contains(id+":word:"+String(Int((start*1000).rounded()))) else{continue}
                let evidence=timeline.evidence(start:start,end:end),duration=end-start
                guard evidence.overlap<=0.02,evidence.solo.count==1,let best=evidence.solo.first,
                      let aligned=mapping[best.key],best.value>=min(0.12,duration*0.8),
                      best.value/duration>=0.7,duration-best.value<=0.25 else{continue}
                if basis=="anonymous_cluster" {
                    guard prior["cluster_id"] as? Int != aligned.slot,
                          aligned.seconds>=4,aligned.parents>=3,best.value/duration>=0.9 else{continue}
                }
                rows[index]["speaker"]=["basis":"anonymous_cluster","cluster_id":aligned.slot,"source_id":source,"epoch":epoch]
                changed=true
            }
            guard changed else{continue}
            let originalRuns=event["speaker_runs"] as? [[String:Any]] ?? []
            records.append(["segment_id":id,"original_sha256":try SpeakerRefinementArtifact.originalEventSHA256(event),
                            "speaker":rows.count==1 ? rows[0]["speaker"] ?? [:]:event["speaker"] ?? [:],
                            "speaker_runs":originalRuns.isEmpty ? []:rows])
        }
        return records
    }
}
