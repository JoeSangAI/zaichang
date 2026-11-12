import Foundation
import CryptoKit

/// After a meeting, every longer stretch is compared with the voices the user
/// personally named: names typed for one line and lines moved to a person.
/// A name a voice merely carried (the live diarizer may have mixed people into
/// it) is never evidence. Local and derived: voice-check.json beside the
/// meeting; a name the user set for a line always wins, and nothing is renamed.
enum MeetingVoiceCheck {
    static let filename="voice-check.json"
    static let method="voice_check_v1"
    static let minimumScore=0.70
    static let minimumMargin=0.15
    static let longSeconds=3.0
    static let windowSeconds=3.0
    static let neighbourGap=1.0
    static let anchorWindowLimit=40

    struct Span:Equatable {let id:String;let parent:String;let source:String;let start:Double;let end:Double}
    struct Verdict:Equatable {let name:String;let score:Double;let margin:Double;let between:Bool}

    // MARK: names

    /// Stable fingerprint of what the user named. A check made for other
    /// names is not shown.
    static func namesDigest(_ object:[String:Any])->String? {
        func canonical(_ value:Any?)->Any {
            guard let rows=value as? [Any] else{return value ?? NSNull()}
            return rows.compactMap{row -> (String,Any)? in
                guard let data=try? JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]) else{return nil}
                return (String(decoding:data,as:UTF8.self),row)
            }.sorted{$0.0<$1.0}.map{$0.1}
        }
        let fields:[String:Any]=["session":object["session"] ?? NSNull(),"sentences":object["sentences"] ?? [:],
                                 "assignments":canonical(object["assignments"]),"speakers":canonical(object["speakers"]),
                                 "aliases":canonical(object["aliases"])]
        guard let data=try? JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys]) else{return nil}
        return SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    }

    /// Lines the user named personally: a typed line name, or a line moved to
    /// a named person. Inherited voice names are left out on purpose.
    static func pinnedNames(_ object:[String:Any])->[String:String] {
        func key(_ value:Any?)->String? {
            guard let row=value as? [String:Any] else{return nil}
            return ["session","source","epoch","identity"].map{row[$0] as? String ?? ""}.joined(separator:"\u{1F}")
        }
        var aliases:[String:String]=[:]
        for row in object["aliases"] as? [[String:Any]] ?? [] {if let from=key(row["from"]),let to=key(row["to"]) {aliases[from]=to}}
        func canonical(_ value:String)->String {var current=value;for _ in 0..<128 {guard let next=aliases[current],next != current else{break};current=next};return current}
        var speakers:[String:String]=[:]
        for row in object["speakers"] as? [[String:Any]] ?? [] {
            if let k=key(row["key"]),let name=row["name"] as? String,!name.isEmpty {speakers[canonical(k)]=name}
        }
        var result:[String:String]=[:]
        for row in object["assignments"] as? [[String:Any]] ?? [] {
            if let id=row["id"] as? String,let k=key(row["key"]),let name=speakers[canonical(k)] {result[id]=name}
        }
        for (id,name) in object["sentences"] as? [String:String] ?? [:] where !name.isEmpty {result[id]=name}
        return result
    }

    // MARK: decision (pure, tested offline with synthetic vectors)

    static func windows(_ start:Double,_ end:Double)->[(Double,Double)] {
        let length=end-start
        guard length>=1.5 else{return []}
        guard length>windowSeconds else{return [(start,end)]}
        var result:[(Double,Double)]=[]
        let count=Int(length/windowSeconds)
        for index in 0..<count {
            let lo:Double=start+Double(index)*windowSeconds
            result.append((lo,lo+windowSeconds))
        }
        return result
    }

    /// `vectors` holds normalized window embeddings per span id.
    static func decide(spans:[Span],pinned:[String:String],vectors:[String:[[Double]]])->[String:Verdict] {
        func pin(_ span:Span)->String? {pinned[span.id] ?? pinned[span.parent]}
        var byName:[String:[[Double]]]=[:]
        for span in spans {if let name=pin(span) {byName[name,default:[]].append(contentsOf:vectors[span.id] ?? [])}}
        let profiles=byName.compactMapValues{rows -> (center:[Double],count:Int)? in
            let center=MeetingAcousticRefinement.center(rows);return center.isEmpty ? nil:(center,rows.count)
        }
        var verdicts:[String:Verdict]=[:]
        guard profiles.values.contains(where:{$0.count>=2}) else{return verdicts}
        for span in spans where pin(span)==nil && span.end-span.start>=longSeconds {
            let center=MeetingAcousticRefinement.center(vectors[span.id] ?? [])
            guard !center.isEmpty else{continue}
            let ranked=profiles.map{($0.key,MeetingAcousticRefinement.dot(center,$0.value.center),$0.value.count)}
                .sorted{$0.1 != $1.1 ? $0.1>$1.1 : $0.0<$1.0}
            guard let best=ranked.first,best.2>=2,best.1>=minimumScore else{continue}
            let margin=best.1-(ranked.dropFirst().first?.1 ?? 0)
            guard margin>=minimumMargin else{continue}
            verdicts[span.id]=Verdict(name:best.0,score:best.1,margin:margin,between:false)
        }
        // A brief line between two lines of the same person, with no pause,
        // is that person too. Only direct verdicts or the user's own names
        // count as neighbours; one bridged line never bridges another.
        for (_,rows) in Dictionary(grouping:spans,by:\.source) {
            let ordered=rows.sorted{$0.start != $1.start ? $0.start<$1.start : $0.id<$1.id}
            func resolved(_ span:Span)->String? {pin(span) ?? verdicts[span.id].flatMap{$0.between ? nil:$0.name}}
            for i in ordered.indices.dropFirst().dropLast() {
                let span=ordered[i],before=ordered[i-1],after=ordered[i+1]
                guard pin(span)==nil,verdicts[span.id]==nil,span.end-span.start<longSeconds,
                      span.start-before.end<=neighbourGap,after.start-span.end<=neighbourGap,
                      let left=resolved(before),let right=resolved(after),left==right else{continue}
                verdicts[span.id]=Verdict(name:left,score:0,margin:0,between:true)
            }
        }
        return verdicts
    }

    // MARK: helper process

    static func run(folder:URL,session:String,modelURL:URL)throws->[String:Any] {
        let cacheID=folder.lastPathComponent
        guard UUID(uuidString:cacheID) != nil else{throw Failure(code:"voice_check_scope")}
        let metadata=try SpeakerRefinement.object(folder.appendingPathComponent("meeting.json"))
        guard metadata["session"] as? String==session,let origin=metadata["capture_origin_uptime"] as? Double,origin.isFinite else{throw Failure(code:"voice_check_scope")}
        let names=try SpeakerRefinement.object(folder.appendingPathComponent("session-names.json"))
        guard names["session"] as? String==session,let digest=namesDigest(names) else{throw Failure(code:"voice_check_names")}
        let pinned=pinnedNames(names)
        let tracks=try meetingAudioTracks(in:folder)
        let meeting=CachedMeeting(id:cacheID,directory:folder,date:Date(),writtenBytes:0,pendingBytes:0,occupiedBytes:0,tracks:tracks,audioCleaned:false,warning:false,retiredBytes:0)
        let events=try meeting.events()
        guard events.count<=15000 else{throw Failure(code:"voice_check_capacity")}
        var spans:[Span]=[]
        for event in events {
            guard let id=event["segment_id"] as? String,let source=event["source_id"] as? String,
                  MeetingAcousticRefinement.usableVoice(event) else{continue}
            let runs=event["speaker_runs"] as? [[String:Any]] ?? []
            for row in runs.isEmpty ? [event]:runs {
                guard let lo=row["start"] as? Double,let hi=row["end"] as? Double,lo.isFinite,hi.isFinite,lo>=0,hi>lo else{continue}
                let speaker=row["speaker"] as? [String:Any] ?? [:]
                if speaker["basis"] as? String=="multiple" || speaker["reason"] as? String=="playback_echo" {continue}
                spans.append(Span(id:runs.isEmpty ? id:TranscriptTimeline.runID(parent:id,run:row),parent:id,source:source,start:lo,end:hi))
            }
        }
        guard spans.count<=30000 else{throw Failure(code:"voice_check_capacity")}
        var result:[String:Any]=["schema":1,"method":method,"session":session,"cache_id":cacheID,"names_sha256":digest,"capture":false,"cloud":false]
        let anchors=spans.filter{pinned[$0.id] != nil || pinned[$0.parent] != nil}
        guard Set(anchors.map{pinned[$0.id] ?? pinned[$0.parent]!}).count>=1,!anchors.isEmpty else{
            result["records"]=[[String:Any]]();result["summary"]=["spans":spans.count,"anchors":0,"checked":0,"decided":0];return result
        }
        let audio=MeetingAcousticRefinement.Audio(folder,origin,false)
        let backend=try SpeakerEmbeddingBackend(model:modelURL);defer{backend.close()}
        func vector(_ source:String,_ lo:Double,_ hi:Double)->[Double]? {
            if audioSourceCoreID(source)=="mic",let ratio=audio.suppression(source,lo,hi),ratio<=MeetingAcousticRefinement.playbackSuppression {return nil}
            guard let pcm=try? audio.window(audio.voiceSource(source),lo,hi) else{return nil}
            let peak=pcm.reduce(Float(0)){max($0,abs($1))},gain=min(Float(16),max(Float(1),0.8/max(peak,0.000001)))
            let raised=pcm.map{$0*gain}
            guard raised.reduce(0.0,{$0+Double($1)*Double($1)})/Double(max(1,raised.count))>=1e-6,
                  let values=try? backend.extract(raised,qualityOK:true,overlap:false,inputKind:"consented_live_audio",allowShortWindow:true).values else{return nil}
            let v=values.map(Double.init),norm=sqrt(MeetingAcousticRefinement.dot(v,v))
            return norm>0 ? v.map{$0/norm}:nil
        }
        var vectors:[String:[[Double]]]=[:]
        // The user's own lines: a bounded, evenly spread sample per person.
        var perName:[String:[(Span,(Double,Double))]]=[:]
        for span in anchors {for w in windows(span.start,span.end) {perName[pinned[span.id] ?? pinned[span.parent]!,default:[]].append((span,w))}}
        for (_,rows) in perName {
            let count=min(anchorWindowLimit,rows.count)
            for i in 0..<count {
                let (span,w)=rows[count==1 ? 0:Int((Double(i)*Double(rows.count-1)/Double(count-1)).rounded())]
                if let v=vector(span.source,w.0,w.1) {vectors[span.id,default:[]].append(v)}
            }
        }
        var checked=0
        for span in spans where pinned[span.id]==nil && pinned[span.parent]==nil && span.end-span.start>=longSeconds {
            let rows=windows(span.start,span.end).compactMap{vector(span.source,$0.0,$0.1)}
            if !rows.isEmpty {vectors[span.id]=rows;checked+=1}
        }
        let verdicts=decide(spans:spans,pinned:pinned,vectors:vectors)
        result["records"]=verdicts.keys.sorted().map{id -> [String:Any] in
            let v=verdicts[id]!;return ["id":id,"name":v.name,"score":(v.score*1000).rounded()/1000,"margin":(v.margin*1000).rounded()/1000,"between":v.between]
        }
        result["summary"]=["spans":spans.count,"anchors":anchors.count,"checked":checked,"decided":verdicts.count]
        return result
    }

    // MARK: reading the result

    struct Checked {let digest:String;let names:[String:String]}

    static func validated(_ data:Data,session:String,cacheID:String)throws->Checked {
        guard data.count<=8*1024*1024,let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              object["schema"] as? Int==1,object["method"] as? String==method,
              object["session"] as? String==session,object["cache_id"] as? String==cacheID,
              let digest=object["names_sha256"] as? String,digest.count==64,digest.allSatisfy({"0123456789abcdef".contains($0)}),
              let records=object["records"] as? [[String:Any]],records.count<=30000 else{throw Failure(code:"voice_check_invalid")}
        var names:[String:String]=[:]
        for row in records {
            guard let id=row["id"] as? String,!id.isEmpty,id.count<=256,let name=row["name"] as? String,
                  !name.isEmpty,name.count<=80,!name.contains("\n"),names[id]==nil else{throw Failure(code:"voice_check_invalid")}
            names[id]=name
        }
        return Checked(digest:digest,names:names)
    }

    /// The saved check, only when it was made for exactly these names.
    static func load(directory:URL,session:String,namesData:Data)->[String:String] {
        let file=directory.appendingPathComponent(filename)
        guard let values=try? file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]),values.isRegularFile==true,values.isSymbolicLink != true,
              let data=try? Data(contentsOf:file),
              let checked=try? validated(data,session:session,cacheID:directory.lastPathComponent),
              let names=(try? JSONSerialization.jsonObject(with:namesData)) as? [String:Any],
              namesDigest(names)==checked.digest else{return [:]}
        return checked.names
    }

    /// Whether the saved check is missing or was made for other names.
    static func isStale(directory:URL,session:String)->Bool {
        guard let names=try? Data(contentsOf:directory.appendingPathComponent("session-names.json")),
              let object=(try? JSONSerialization.jsonObject(with:names)) as? [String:Any],!pinnedNames(object).isEmpty else{return false}
        guard let data=try? Data(contentsOf:directory.appendingPathComponent(filename)),
              let checked=try? validated(data,session:session,cacheID:directory.lastPathComponent) else{return true}
        return namesDigest(object) != checked.digest
    }

    static func write(_ data:Data,directory:URL) throws {
        let file=directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath:file.path),try file.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink==true {throw Failure(code:"voice_check_scope")}
        try data.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
}
