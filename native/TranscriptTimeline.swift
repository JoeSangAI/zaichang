import Foundation

struct ReadingTurn {
    var id:String
    let parent:String
    var item:[String:Any]
    var parts:[(String,[String:Any])]
    var uncertain:Bool
}

// One provider sentence remains one record. Speaker runs are evidence attached
// to that record, never destructive replacements or separately ordered sentences.
struct TranscriptTimeline {
    private var storedRecords: [String: [String: Any]] = [:]
    private var storedArrival: [String] = []
    private var sortedIDs: [String] = []
    private var arrivalRanks: [String:Int] = [:]
    private(set) var orderingComparisons = 0
    private(set) var fullOrderingRebuilds = 0
    var records: [String:[String:Any]] {
        get { storedRecords }
        set { storedRecords = newValue; rebuildOrdering() }
    }
    var arrivalOrder: [String] {
        get { storedArrival }
        set { storedArrival = newValue; arrivalRanks = Dictionary(newValue.enumerated().map{($0.element,$0.offset)},uniquingKeysWith:{a,_ in a});rebuildOrdering() }
    }
    var discardedIDs: Set<String> = []
    // Sorting belongs to mutations; ordinary view/state reads return this index.
    var orderedIDs: [String] { sortedIDs }
    private func precedes(_ lhs:String,_ rhs:String)->Bool {
        let a=Self.start(storedRecords[lhs]!),b=Self.start(storedRecords[rhs]!)
        if a != b {return a<b}
        if a == .greatestFiniteMagnitude {return (arrivalRanks[lhs] ?? Int.max)<(arrivalRanks[rhs] ?? Int.max)}
        return lhs<rhs
    }
    private mutating func rebuildOrdering() {
        fullOrderingRebuilds+=1
        sortedIDs=storedRecords.keys.sorted{precedes($0,$1)}
    }
    private mutating func insertOrdered(_ id:String) {
        if let last=sortedIDs.last {orderingComparisons+=1;if !precedes(id,last) {sortedIDs.append(id);return}}
        var lo=0,hi=sortedIDs.count
        while lo<hi {let mid=(lo+hi)/2;orderingComparisons+=1;if precedes(sortedIDs[mid],id) {lo=mid+1}else{hi=mid}}
        sortedIDs.insert(id,at:lo)
    }
    static func start(_ event: [String: Any]) -> Double {
        guard let n = event["start"] as? Double, n.isFinite, n >= 0 else { return .greatestFiniteMagnitude }
        return n
    }
    func accepts(_ event: [String: Any]) -> Bool {
        guard let id = event["segment_id"] as? String, !id.isEmpty, event["text"] is String else { return false }
        guard !discardedIDs.contains(id) else { return false }
        guard let old = records[id] else { return true }
        if old["session"] as? String != event["session"] as? String { return false }
        if let previous = old["revision"] as? Int {
            guard let next = event["revision"] as? Int, next > previous else { return false }
        }
        if let previous = old["asr_revision"] as? Int, let next = event["asr_revision"] as? Int, next < previous { return false }
        if old["final"] as? Bool == true && event["final"] as? Bool != true { return false }
        return true
    }
    mutating func put(_ event: [String: Any]) {
        guard let id = event["segment_id"] as? String else { return }
        let previous=storedRecords[id]
        let needsPosition=previous==nil || Self.start(previous!) != Self.start(event)
        if previous==nil {arrivalRanks[id]=storedArrival.count;storedArrival.append(id)}
        if previous != nil && needsPosition {sortedIDs.removeAll{$0==id}}
        storedRecords[id]=event
        if needsPosition {insertOrdered(id)}
    }
    /// Reading-only fields on a stored record; never moves it. A nil value removes the key.
    mutating func annotate(_ id:String,_ fields:[String:Any?]) {
        guard var record=storedRecords[id] else{return}
        for (key,value) in fields {record[key]=value}
        storedRecords[id]=record
    }
    /// Records starting in [lo, hi), in reading order.
    func ids(startingFrom lo:Double,before hi:Double)->ArraySlice<String> {
        func lower(_ t:Double)->Int {var a=0,b=sortedIDs.count;while a<b {let m=(a+b)/2;if Self.start(storedRecords[sortedIDs[m]]!)<t {a=m+1}else{b=m}};return a}
        let a=lower(lo),b=max(a,lower(hi));return sortedIDs[a..<b]
    }
    mutating func discard(_ ids: Set<String>) {
        discardedIDs.formUnion(ids)
        for id in ids { storedRecords.removeValue(forKey:id);arrivalRanks.removeValue(forKey:id) }
        storedArrival.removeAll { ids.contains($0) };sortedIDs.removeAll{ids.contains($0)}
    }
    static func timestamp(_ value: Any?, precise: Bool = false) -> String {
        guard let seconds = value as? Double, seconds.isFinite, seconds >= 0, seconds < 1e8 else { return "时间待确认" }
        let ms = Int((seconds * 1000).rounded())
        return precise ? String(format: "%02d:%02d.%03d", ms / 60000, (ms / 1000) % 60, ms % 1000) : String(format: "%02d:%02d", ms / 60000, (ms / 1000) % 60)
    }
    // Validate optional evidence before using it for display or name editing.
    // Coalesce equal identities even when model revision metadata differs.
    static func speakerRuns(_ item: [String: Any]) -> [[String: Any]] {
        guard let raw = item["speaker_runs"] as? [[String: Any]], raw.count > 1,
              let start = item["start"] as? Double, let end = item["end"] as? Double,
              start.isFinite, end.isFinite, start >= 0, end < 1e8, end > start else { return [] }
        var runs: [[String: Any]] = [], cursor = start, text = ""
        for run in raw {
            guard let lo = run["start"] as? Double, let hi = run["end"] as? Double,
                  lo.isFinite, hi.isFinite, lo >= cursor - 0.001, hi > lo, hi <= end + 0.001,
                  let body = run["text"] as? String, let speaker = run["speaker"] as? [String: Any] else { return [] }
            cursor = hi; text += body
            var next = run
            next["session"] = item["session"]; next["source_id"] = item["source_id"]; next["epoch"] = item["epoch"]; next["track"] = item["track"]
            next["reading_echo_of"] = item["reading_echo_of"] ?? speaker["echo_of"]
            next["reading_aside_of"] = item["reading_aside_of"]
            next["reading_draft"] = item["reading_draft"]
            next["coarse_source_word_spans"] = item["coarse_source_word_spans"];next["parent_segment_id"] = item["segment_id"];next["revision"] = item["revision"];next["final"] = item["final"];next["end_time_known"] = item["end_time_known"];next["quality_flags"] = item["quality_flags"]
            func identity(_ value: [String: Any]) -> NSDictionary {
                var copy = value; copy.removeValue(forKey: "revision"); copy.removeValue(forKey: "label"); if copy["basis"] as? String == "unknown" { copy.removeValue(forKey: "reason") }; return NSDictionary(dictionary: copy)
            }
            if var last = runs.last, let prior = last["speaker"] as? [String: Any], identity(prior).isEqual(identity(speaker)), lo - (last["end"] as! Double) < 0.2 {
                last["text"] = (last["text"] as! String) + body; last["end"] = hi; runs[runs.count - 1] = last
            } else { runs.append(next) }
        }
        return text == item["text"] as? String ? runs : []
    }
    static func runID(parent: String, run: [String: Any]) -> String {
        // Int() traps on non-finite values; a malformed run must not crash rendering.
        let start=(run["start"] as? Double).flatMap{$0.isFinite && abs($0)<1e9 ? $0:nil} ?? 0
        return parent + ":word:" + String(Int((start * 1000).rounded()))
    }
    static func readingTurns(_ rows:[(id:String,parent:String,item:[String:Any])],
                             identity:(String,[String:Any])->String?)->[ReadingTurn] {
        struct Group {
            let parent:String
            var token:String?
            var parts:[(String,[String:Any])]
            var knownPart:Int?
            var uncertain:Bool
            var allShortAmbiguity:Bool
        }
        func shortAmbiguity(_ item:[String:Any])->Bool {
            // A detected overlap or speaker change is a real boundary, even
            // for one short word. Only unresolved single-speaker evidence may
            // borrow reading context; never spread a multiple-speaker label
            // over the clear speech on either side.
            guard (item["speaker"] as? [String:Any])?["basis"] as? String=="unknown",
                  (item["speaker"] as? [String:Any])?["reason"] as? String != "acoustic_unresolved",
                  let start=item["start"] as? Double,let end=item["end"] as? Double,
                  start.isFinite,end.isFinite,end>start,end-start<=3,
                  let body=item["text"] as? String else{return false}
            let count=body.unicodeScalars.filter{CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)}.count
            return count<=6
        }
        func closeEnough(_ group:Group,_ item:[String:Any])->Bool {
            guard let previous=group.parts.last?.1["end"] as? Double,
                  let next=item["start"] as? Double,
                  previous.isFinite,next.isFinite else{return false}
            let gap=next-previous
            return gap >= -0.001 && gap<=3
        }
        func isManual(_ token:String?)->Bool {token?.hasPrefix("manual:")==true}
        var groups:[Group]=[]
        for row in rows where row.item["reading_draft"] as? Bool != true && row.item["reading_echo_of"] == nil && row.item["reading_aside_of"] == nil && (row.item["speaker"] as? [String:Any])?["echo_of"] == nil {
            let token=identity(row.id,row.item)
            let brief=token==nil && shortAmbiguity(row.item)
            if var current=groups.last,current.parent==row.parent,closeEnough(current,row.item) {
                if let token=token,current.token==token {
                    current.parts.append((row.id,row.item));current.allShortAmbiguity=false
                    groups[groups.count-1]=current;continue
                }
                if let token=token,current.token==nil,current.allShortAmbiguity,!isManual(token) {
                    current.token=token;current.knownPart=current.parts.count
                    current.parts.append((row.id,row.item));current.allShortAmbiguity=false
                    groups[groups.count-1]=current;continue
                }
                if brief && !isManual(current.token) && (current.token != nil || current.allShortAmbiguity) {
                    current.parts.append((row.id,row.item));current.uncertain=true
                    groups[groups.count-1]=current;continue
                }
            }
            groups.append(Group(parent:row.parent,token:token,parts:[(row.id,row.item)],
                                knownPart:token==nil ? nil:0,uncertain:token==nil,
                                allShortAmbiguity:brief))
        }
        return groups.map {group in
            let first=group.parts[0],last=group.parts[group.parts.count-1]
            let rawStart=first.1["start"] as? Double ?? 0
            let start=rawStart.isFinite && rawStart>=0 && rawStart<1e8 ? rawStart:0
            let id=group.parts.count==1 ? first.0:group.parent+":turn:"+String(Int((start*1000).rounded()))
            var item=group.parts[group.knownPart ?? 0].1
            item.removeValue(forKey:"speaker_runs");item.removeValue(forKey:"word_spans")
            item["segment_id"]=id;item["parent_segment_id"]=group.parent
            item["start"]=first.1["start"];item["end"]=last.1["end"]
            item["text"]=group.parts.map{$0.1["text"] as? String ?? ""}.joined()
            return ReadingTurn(id:id,parent:group.parent,item:item,parts:group.parts,
                               uncertain:group.knownPart != nil && group.uncertain)
        }
    }

    /// Raw-text mode reveals every retained utterance, including echo copies.
    /// This only removes reading metadata; stored evidence remains unchanged.
    static func revealReadingEchoes(_ events:[[String:Any]])->[[String:Any]] {
        func reveal(_ input:[String:Any])->[String:Any] {
            var row=input;for key in crossTrackKeys {row.removeValue(forKey:key)};row.removeValue(forKey:"reading_draft");row.removeValue(forKey:"reading_projection_notice")
            if var speaker=row["speaker"] as? [String:Any] {speaker.removeValue(forKey:"echo_of");row["speaker"]=speaker}
            return row
        }
        return events.map {event in
            var row=reveal(event)
            if let runs=event["speaker_runs"] as? [[String:Any]] {row["speaker_runs"]=runs.map(reveal)}
            return row
        }
    }

    /// The computer's own track is the record of what the far end said. A
    /// microphone sentence that repeats it at the same moment is that sound
    /// heard again through the speakers, whatever the device, room or echo
    /// delay; a few microphone words inside far-end speech are an aside to it,
    /// not a turn of their own. This is the only place either is decided, from
    /// text and times every path has. Events, their text and audio stay intact;
    /// the original-transcript view shows them all.
    enum CrossTrackRole:Equatable {case echo(String),aside(String)}
    static let crossTrackSlack=1.5
    static func crossTrackText(_ value:Any?)->[Character] {
        guard let text=value as? String else{return []}
        var scalars=String.UnicodeScalarView()
        scalars.append(contentsOf:text.lowercased().unicodeScalars.filter{CharacterSet.alphanumerics.contains($0)})
        return Array(String(scalars).prefix(2000))
    }
    /// true for the microphone, false for computer sound, nil for anything else.
    static func isMicrophone(_ event:[String:Any])->Bool? {
        guard let source=event["source_id"] as? String ?? event["track"] as? String,let core=audioSourceCoreID(source) else{return nil}
        if core=="mic" {return true}
        return core=="remote" || core.hasPrefix("app-") ? false:nil
    }
    static func crossTrackRole(_ mic:[String:Any],among remote:[[String:Any]])->CrossTrackRole? {
        guard mic["final"] as? Bool==true,isMicrophone(mic)==true,
              let start=mic["start"] as? Double,let end=mic["end"] as? Double,start.isFinite,end.isFinite,end>start else{return nil}
        let text=crossTrackText(mic["text"]);guard !text.isEmpty else{return nil}
        let near=remote.compactMap { other -> (id:String,start:Double,end:Double,text:[Character])? in
            guard other["final"] as? Bool==true,isMicrophone(other)==false,other["session"] as? String==mic["session"] as? String,
                  let id=other["segment_id"] as? String,let lo=other["start"] as? Double,let hi=other["end"] as? Double,
                  lo.isFinite,hi.isFinite,hi>lo,lo<end+crossTrackSlack,hi>start-crossTrackSlack else{return nil}
            return (id,lo,hi,crossTrackText(other["text"]))
        }.sorted{$0.start<$1.start}
        guard !near.isEmpty else{return nil}
        let overlaps=near.map{max(0,min(end,$0.end)-max(start,$0.start))}
        var host=0
        for i in near.indices.dropFirst() where overlaps[i]>overlaps[host] || (overlaps[i]==overlaps[host] && abs(near[i].start-start)<abs(near[host].start-start)) {host=i}
        let shared=longestCommonRun(text,near.flatMap(\.text))
        if text.count>=3 && shared>=3 && Double(shared)>=0.6*Double(text.count) {return .echo(near[host].id)}
        if text.count<=6 && overlaps[host]>0 && overlaps.reduce(0,+)>=0.3*(end-start) {return .aside(near[host].id)}
        return nil
    }
    static func longestCommonRun(_ a:[Character],_ b:[Character])->Int {
        guard !a.isEmpty,!b.isEmpty else{return 0}
        var previous=[Int](repeating:0,count:b.count+1),current=previous,best=0
        for x in a {
            for j in 1...b.count {current[j]=x==b[j-1] ? previous[j-1]+1:0;best=max(best,current[j])}
            swap(&previous,&current)
        }
        return best
    }
    static func crossTrackRoles(_ events:[[String:Any]],protected:Set<String>)->[String:CrossTrackRole] {
        let usable=events.filter{$0["final"] as? Bool==true && isMicrophone($0) != nil && start($0) != .greatestFiniteMagnitude}.sorted{start($0)<start($1)}
        let remote=usable.filter{isMicrophone($0)==false}
        var roles:[String:CrossTrackRole]=[:],cursor=0,active:[[String:Any]]=[]
        for mic in usable where isMicrophone(mic)==true {
            guard let id=mic["segment_id"] as? String,!protected.contains(id),let end=mic["end"] as? Double,end.isFinite else{continue}
            while cursor<remote.count && start(remote[cursor])<end+crossTrackSlack {active.append(remote[cursor]);cursor+=1}
            active.removeAll{($0["end"] as? Double ?? 0)<=start(mic)-crossTrackSlack}
            if let role=crossTrackRole(mic,among:active) {roles[id]=role}
        }
        return roles
    }
    static let crossTrackKeys=["reading_echo_of","reading_aside_of"]
    static func crossTrackFields(_ role:CrossTrackRole?)->[String:Any] {
        switch role {case .echo(let host)?:return ["reading_echo_of":host];case .aside(let host)?:return ["reading_aside_of":host];case nil:return [:]}
    }
    static func markCrossTrack(_ events:[[String:Any]],protected:Set<String>)->[[String:Any]] {
        let roles=crossTrackRoles(events,protected:protected)
        return events.map {event in
            var row=event;for key in crossTrackKeys {row.removeValue(forKey:key)}
            if let id=event["segment_id"] as? String {row.merge(crossTrackFields(roles[id])){$1}}
            return row
        }
    }
}

func readingTurnChecks()->Int {
    typealias Row=(id:String,parent:String,item:[String:Any])
    func leaf(_ id:String,_ parent:String,_ start:Double,_ end:Double,_ text:String,_ who:String?)->Row {
        var speaker:[String:Any]=["basis":"unknown"]
        if let who=who {speaker=["basis":"anonymous_cluster","cluster_id":who=="Alice" ? 0:1]}
        var item:[String:Any]=["start":start,"end":end,"text":text,
                               "speaker":speaker]
        item["test_identity"]=who
        return (id,parent,item)
    }
    let rows:[Row]=[
        leaf("a1","p",0,0.6,"Alice先说，","Alice"),
        leaf("u1","p",0.6,0.8,"嗯，",nil),
        leaf("a2","p",0.8,1.4,"继续解释。","Alice"),
        leaf("j1","p",1.4,2.0,"Bob回应。","Bob"),
        leaf("u2","p",2.0,3.5,"这里有一长段暂时无法判断的发言。",nil),
        leaf("a3","p",3.5,4.0,"Alice补充。","Alice"),
        leaf("j2","p",4.0,4.5,"Bob收尾。","Bob")]
    let identity:(String,[String:Any])->String?={_,item in item["test_identity"] as? String}
    let turns=TranscriptTimeline.readingTurns(rows,identity:identity)
    precondition(turns.count==5 && turns.map{$0.parts.count}==[3,1,1,1,1] &&
                 turns.map{$0.uncertain}==[true,false,false,false,false]);var checks=1
    precondition(turns[0].item["speaker"] as? [String:Any] != nil &&
                 (turns[0].item["speaker"] as! [String:Any])["cluster_id"] as? Int==0 &&
                 (turns[2].item["speaker"] as! [String:Any])["basis"] as? String=="unknown");checks+=1
    let original=rows.map{$0.item["text"] as! String}.joined()
    precondition(turns.map{$0.item["text"] as! String}.joined()==original &&
                 turns.flatMap{$0.parts}.map{$0.1["text"] as! String}.joined()==original &&
                 turns[0].id=="p:turn:0" && turns[1].id=="j1");checks+=1
    let leading:[Row]=[leaf("lead","q",10,10.2,"嗯",nil),leaf("known","q",10.2,11,"接着说。","Alice")]
    let attached=TranscriptTimeline.readingTurns(leading,identity:identity)
    precondition(attached.count==1 && attached[0].uncertain && attached[0].parts.map{$0.0}==["lead","known"] &&
                 (attached[0].item["speaker"] as! [String:Any])["cluster_id"] as? Int==0);checks+=1
    let interleaved:[Row]=[leaf("p1","p",0,1,"甲","Alice"),leaf("q1","q",1,2,"乙","Bob"),leaf("p2","p",2,3,"丙","Alice")]
    precondition(TranscriptTimeline.readingTurns(interleaved,identity:identity).map{$0.id}==["p1","q1","p2"]);checks+=1
    let manual:[Row]=[leaf("m1","r",0,1,"同一人","Alice"),leaf("m2","r",1,2,"人工独立确认","manual:m2"),leaf("m3","r",2,3,"仍为同一人","Alice")]
    precondition(TranscriptTimeline.readingTurns(manual,identity:identity).count==3);checks+=1
    let manualBoundary:[Row]=[leaf("before","b",0,0.2,"嗯",nil),leaf("confirmed","b",0.2,1,"人工已确认","manual:confirmed"),leaf("after","b",1,1.2,"啊",nil)]
    let separated=TranscriptTimeline.readingTurns(manualBoundary,identity:identity)
    precondition(separated.map{$0.parts.count}==[1,1,1] && separated.allSatisfy{!$0.uncertain});checks+=1
    let longGap:[Row]=[leaf("g1","g",0,1,"前句","Alice"),leaf("g2","g",4.5,5.5,"后句","Alice")]
    precondition(TranscriptTimeline.readingTurns(longGap,identity:identity).count==2);checks+=1
    // A short confirmed acoustic boundary must stay local. Otherwise one
    // overlapped word would label an entire clear paragraph as multiple voices.
    for reason in ["overlap","speaker_change"] {
        var boundary=leaf("boundary","edge",2,2.2,"对。",nil)
        boundary.item["speaker"]=["basis":"multiple","reason":reason,"cluster_ids":[0,1]]
        let source:[Row]=[leaf("left","edge",0,2,"甲清楚解释。","Alice"),boundary,leaf("right","edge",2.2,4,"甲继续解释。","Alice")]
        let bounded=TranscriptTimeline.readingTurns(source,identity:identity)
        precondition(bounded.count==3 && bounded.allSatisfy{!$0.uncertain} && bounded.map{$0.parts.count}==[1,1,1]);checks+=1
        precondition((bounded[0].item["speaker"] as? [String:Any])?["basis"] as? String=="anonymous_cluster" &&
                     (bounded[1].item["speaker"] as? [String:Any])?["basis"] as? String=="multiple" &&
                     (bounded[1].item["speaker"] as? [String:Any])?["reason"] as? String==reason &&
                     (bounded[2].item["speaker"] as? [String:Any])?["basis"] as? String=="anonymous_cluster");checks+=1
        precondition(bounded.map{$0.item["text"] as! String}.joined()==source.map{$0.item["text"] as! String}.joined() &&
                     bounded.flatMap{$0.parts}.map{$0.0}==source.map{$0.id} &&
                     zip(bounded,source).allSatisfy{turn,row in
                         turn.item["start"] as? Double==row.item["start"] as? Double &&
                         turn.item["end"] as? Double==row.item["end"] as? Double &&
                         NSDictionary(dictionary:turn.parts[0].1).isEqual(to:row.item)
                     });checks+=1
        let manualEdges:[Row]=[leaf("manual-left","edge",0,2,"本人已确认。","manual:left"),boundary,leaf("manual-right","edge",2.2,4,"另一明确标注。","manual:right")]
        let manualTurns=TranscriptTimeline.readingTurns(manualEdges,identity:identity)
        precondition(manualTurns.count==3 && manualTurns.map{$0.parts[0].0}==manualEdges.map{$0.id} &&
                     manualTurns[0].item["test_identity"] as? String=="manual:left" &&
                     manualTurns[2].item["test_identity"] as? String=="manual:right");checks+=1
    }
    let ordinaryUnknown:[Row]=[leaf("clear-before","unknown",0,2,"解释前半句。","Alice"),leaf("brief-unknown","unknown",2,2.2,"嗯。",nil),leaf("clear-after","unknown",2.2,4,"解释后半句。","Alice")]
    let ordinaryTurns=TranscriptTimeline.readingTurns(ordinaryUnknown,identity:identity)
    precondition(ordinaryTurns.count==1 && ordinaryTurns[0].uncertain && ordinaryTurns[0].parts.map{$0.0}==ordinaryUnknown.map{$0.id});checks+=1
    let sharedText="这是同一段通过电脑播放又被麦克风录到的发言。"
    func echoEvent(_ id:String,_ source:String,_ start:Double,_ end:Double,_ text:String)->[String:Any] {
        ["segment_id":id,"source_id":source,"session":"echo-fixture","start":start,"end":end,"text":text,"final":true,"end_time_known":true]
    }
    let echoEvents=[echoEvent("remote","app-1234567890abcdef-g1",0,5,sharedText),
                    echoEvent("mic","mic-g1",0.1,4.9,sharedText),
                    echoEvent("repeat-later","mic-g1",10,15,sharedText),
                    echoEvent("different","mic-g1",0,5,"另一位同时讲话，内容并不相同，要完整留下。")]
    let echoView=TranscriptTimeline.markCrossTrack(echoEvents,protected:[])
    precondition(echoView.count==echoEvents.count && echoView[1]["reading_echo_of"] as? String=="remote" &&
                 echoView[2]["reading_echo_of"]==nil && echoView[3]["reading_echo_of"]==nil);checks+=1
    let echoRows=echoView.map{(id:$0["segment_id"] as! String,parent:$0["segment_id"] as! String,item:$0)}
    precondition(TranscriptTimeline.readingTurns(echoRows,identity:{_,_ in nil}).count==3 &&
                 echoView.map{$0["text"] as! String}==echoEvents.map{$0["text"] as! String});checks+=1
    let protectedEcho=TranscriptTimeline.markCrossTrack(echoEvents,protected:["mic"])
    precondition(protectedEcho.allSatisfy{$0["reading_echo_of"]==nil});checks+=1
    // Echo arrives late and garbled; a short reply inside far-end speech is an
    // aside to it; a short phrase alone or a long sentence of one's own stays.
    let crossEvents=[echoEvent("far","app-1234567890abcdef-g1",10,16,"广告投放过来，导向到蚂蚁阿福，然后最终形成一个场域。"),
                     echoEvent("late-echo","mic-g1",16.4,18,"导向到蚂蚁阿福，然后最终"),
                     echoEvent("short-echo","mic-g1",11,11.6,"广告投放"),
                     echoEvent("nod","mic-g1",12,12.5,"嗯，对对。"),
                     echoEvent("grain","mic-g1",13,13.2,"腐。"),
                     echoEvent("alone","mic-g1",30,30.5,"嗯。"),
                     echoEvent("own","mic-g1",12.5,15.5,"我插一句，退款这块还没扣，要先算清楚再定预算。")]
    let cross=TranscriptTimeline.markCrossTrack(crossEvents,protected:[])
    func field(_ id:String,_ key:String)->Any? {cross.first{$0["segment_id"] as? String==id}?[key]}
    precondition(field("late-echo","reading_echo_of") as? String=="far" && field("short-echo","reading_echo_of") as? String=="far" &&
                 field("nod","reading_aside_of") as? String=="far" && field("grain","reading_aside_of") as? String=="far" &&
                 cross.filter{["alone","own"].contains($0["segment_id"] as! String)}.allSatisfy{row in TranscriptTimeline.crossTrackKeys.allSatisfy{row[$0]==nil}});checks+=1
    let crossRows=cross.map{(id:$0["segment_id"] as! String,parent:$0["segment_id"] as! String,item:$0)}
    precondition(TranscriptTimeline.readingTurns(crossRows,identity:{_,_ in nil}).map{$0.id}.sorted()==["alone","far","own"]);checks+=1
    precondition(TranscriptTimeline.revealReadingEchoes(cross).allSatisfy{row in TranscriptTimeline.crossTrackKeys.allSatisfy{row[$0]==nil}});checks+=1
    // 50k chronologically arriving segments must not sort the prior meeting.
    var indexed=TranscriptTimeline()
    for i in 0..<50_000 {indexed.put(["segment_id":String(format:"%06d",i),"start":Double(i),"text":"合成记录"])}
    let comparisons=indexed.orderingComparisons,rebuilds=indexed.fullOrderingRebuilds
    for _ in 0..<1000 {precondition(indexed.orderedIDs.count==50_000 && indexed.orderedIDs.first=="000000" && indexed.orderedIDs.last=="049999")}
    precondition(indexed.orderingComparisons==comparisons && rebuilds==0 && comparisons<=50_000);checks+=1
    indexed.put(["segment_id":"025000","start":25_000.0,"text":"正文修订"])
    precondition(indexed.orderingComparisons==comparisons && indexed.orderedIDs[25_000]=="025000");checks+=1
    indexed.put(["segment_id":"025000","start":-1.0,"text":"无可靠时间"])
    indexed.put(["segment_id":"late","start":0.5,"text":"晚到段落"])
    precondition(indexed.orderedIDs[1]=="late" && indexed.orderedIDs.last=="025000");checks+=1
    indexed.discard(["late","025000"])
    precondition(indexed.orderedIDs.count==49_999 && !indexed.orderedIDs.contains("late"));checks+=1
    var disorder=TranscriptTimeline()
    for i in (0..<2000).reversed() {disorder.put(["segment_id":String(format:"r%04d",i),"start":Double(i/2),"text":"乱序同时间"])}
    precondition(disorder.orderedIDs==disorder.records.keys.sorted{let a=TranscriptTimeline.start(disorder.records[$0]!),b=TranscriptTimeline.start(disorder.records[$1]!);return a != b ? a<b:$0<$1});checks+=1
    return checks
}

// Metadata only: bytes received are not proof of audible speech or transcription.
struct SourceActivity {
    var bytes: [String: Int] = [:]
    var transcribed: Set<String> = []
    var signal:[String:[String:Any]]=[:]
    var elapsed=0.0
    var paused=false
    mutating func receive(_ event: [String: Any]) {
        if event["type"] as? String == "segment", let track = event["track"] as? String { transcribed.insert(track) }
        if event["type"] as? String == "capture_status", let tracks = event["tracks"] as? [String: Int] {
            for (track,count) in tracks {bytes[track]=max(bytes[track] ?? 0,count)}
            if let value=event["signal"] as? [String:[String:Any]] {signal=value}
            elapsed=event["elapsed_seconds"] as? Double ?? elapsed;paused=event["paused"] as? Bool ?? false
        }
    }
    var microphoneMuted=false
    var microphoneWarning:String? {
        guard !paused,!microphoneMuted,elapsed>=8,let mic=signal["mic"],let raw=mic["raw_signal"] as? [String:Any] else{return nil}
        if (raw["hardware_pcm_frames"] as? Int ?? 0)==0 || (raw["last_packet_age_seconds"] as? Double ?? 0)>=3 {return "麦克风未收到音频；请检查输入设备"}
        if (raw["nonzero_samples"] as? Int ?? 0)==0 {
            let input=mic["input_diagnostics"] as? [String:Any] ?? [:]
            if (input["input_nonzero_samples"] as? Int ?? 0)>0 {return "麦克风设备有信号，转换后无声；请暂停检查"}
            return "麦克风一直无声；请讲话并检查输入设备"
        }
        if (raw["last_nonzero_age_seconds"] as? Double ?? 0)>=8 {return "麦克风已连续无声；请讲话确认仍能收音"}
        if let clean=mic["clean_signal"] as? [String:Any],(clean["nonzero_samples"] as? Int ?? 0)==0 {return "麦克风原声有信号，处理后无声；请暂停检查"}
        return nil
    }
    func label(_ track: String) -> String {
        if let values=signal[track] {
            let measured=track=="mic" ? (values["raw_signal"] as? [String:Any] ?? values):values
            if (measured["hardware_pcm_frames"] as? Int ?? 0)==0 {return "尚未收到音频"}
            if (measured["last_packet_age_seconds"] as? Double ?? 0)>=3 && !paused {return "音频中断"}
            if (measured["nonzero_samples"] as? Int ?? 0)==0 {return "收到全零音频，未收到声音"}
            let rms=measured["signal_rms"] as? Double ?? 0
            return rms>0 ? "有声音（\(Int(max(-96,20*log10(max(rms,0.000016))))) dB）":"当前无声"
        }
        if transcribed.contains(track) { return "已有转写" }
        if (bytes[track] ?? 0) > 0 { return "已收到音频，暂无文字" }
        return "尚未收到音频"
    }
}
