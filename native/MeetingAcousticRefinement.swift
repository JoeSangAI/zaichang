import Foundation

/// Meeting-local acoustic identity pass. No names, network, enrollment or
/// recording devices. Original PCM, provider words and time bounds are inputs.
enum MeetingAcousticRefinement {
    static let method="meeting_acoustic_v1"
    static let model="campplus:f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11+"+MeetingSpeechIntervals.modelID
    struct Unit {
        let parent:Int;let run:Int?;let id:String;let source:String;let start:Double;let end:Double
        let key:SessionSpeakerKey?;let text:String;let usable:Bool;let overlap:Bool
    }
    struct Anchor {let key:SessionSpeakerKey;let source:String;let start:Double;let end:Double;let text:String;let vector:[Double]}
    struct Profile {let key:SessionSpeakerKey;let anchors:[Anchor];let center:[Double]}
    struct Match {let key:SessionSpeakerKey;let score:Double;let margin:Double}
    // Language uncertainty concerns words, not the speaker's voice.
    static func usableVoice(_ event:[String:Any])->Bool {
        event["final"] as? Bool==true && event["end_time_known"] as? Bool==true &&
        Decoder.speakerEvidenceAllowed(event)
    }
    static func dot(_ a:[Double],_ b:[Double])->Double {zip(a,b).reduce(0){$0+$1.0*$1.1}}
    static func center(_ rows:[[Double]])->[Double] {
        guard let first=rows.first else{return []};var value=[Double](repeating:0,count:first.count)
        for row in rows {for i in value.indices {value[i]+=row[i]}}
        let norm=sqrt(dot(value,value));return norm>0 ? value.map{$0/norm}:[]
    }
    static func normalized(_ text:String)->String {String(text.lowercased().unicodeScalars.filter{CharacterSet.alphanumerics.contains($0)})}
    static func sameWords(_ microphone:String,_ remote:String)->Bool {
        if remote.contains(microphone) {return true}
        // The two ASR streams often spell the same audible sentence slightly
        // differently. Only long, almost identical text may use edit distance;
        // acoustic identity and simultaneous coverage are still required below.
        let a=Array(microphone),b=Array(remote),largest=max(a.count,b.count)
        guard min(a.count,b.count)>=12,largest<=1200 else{return false}
        let limit=Int(Double(largest)*0.15)
        guard abs(a.count-b.count)<=limit else{return false}
        var previous=Array(0...b.count)
        for (i,char) in a.enumerated() {
            var next=[Int](repeating:limit+1,count:b.count+1);next[0]=i+1
            for j in max(1,i+1-limit)...min(b.count,i+1+limit) {
                next[j]=min(previous[j]+1,next[j-1]+1,previous[j-1]+(char==b[j-1] ? 0:1))
            }
            if next.min()!>limit {return false};previous=next
        }
        return previous[b.count]<=limit
    }

    /// A bounded window reader, shared by all windows in this one subprocess.
    /// The LRU holds at most 12 ten-second chunks, never a whole long meeting.
    final class Audio {
        let directory:URL;let origin:Double;let allowUnsealed:Bool
        var manifests:[String:[String:Any]]=[:],cache:[String:Data]=[:],lru:[String]=[]
        init(_ directory:URL,_ origin:Double,_ allowUnsealed:Bool) {self.directory=directory;self.origin=origin;self.allowUnsealed=allowUnsealed}
        func window(_ source:String,_ start:Double,_ end:Double)throws->[Float] {
            guard isMeetingAudioTrack(source),start.isFinite,end.isFinite,end>start,end-start<=10 else{throw Failure(code:"acoustic_window_invalid")}
            let m:[String:Any]
            if let value=manifests[source] {m=value} else {
                m=try SpeakerRefinement.object(directory.appendingPathComponent(source+"-manifest.json"));manifests[source]=m
            }
            guard m["track"] as? String==source,m["format"] as? String=="pcm_s16le",m["sample_rate"] as? Int==16000,m["channels"] as? Int==1,
                  m["audio_cleaned"] as? Bool != true,m["ended"] as? Bool==true || allowUnsealed,
                  let at=m["origin_uptime"] as? Double,at.isFinite,abs(at-origin)<=86400,
                  let written=m["written_bytes"] as? Int,written>=0,
                  let chunks=m["chunks"] as? [[String:Any]],chunks.count<=10000 else{throw Failure(code:"acoustic_audio_invalid")}
            let lo=Int(((start-(at-origin))*16000).rounded())*2,hi=Int(((end-(at-origin))*16000).rounded())*2
            guard lo>=0,hi<=written,hi>lo else{throw Failure(code:"acoustic_window_missing")}
            var bytes=Data(),cursor=0
            for (index,chunk) in chunks.enumerated() {
                guard chunk["index"] as? Int==index,let count=chunk["bytes"] as? Int,count>0,count<=320000,count%2==0 else{throw Failure(code:"acoustic_audio_invalid")}
                let next=cursor+count;defer{cursor=next};guard next>lo,cursor<hi else{continue}
                let name=source+String(format:"-%06d.pcm",index);let data:Data
                if let saved=cache[name] {data=saved} else {
                    data=try SavedVoiceRecognition.readPrefix(directory.appendingPathComponent(name),bytes:count)
                    if let hash=chunk["sha256"] as? String {guard MeetingSpeakerReconciliation.hash(data)==hash else{throw Failure(code:"acoustic_audio_changed")}}
                    else {guard index==chunks.count-1,allowUnsealed || SpeakerRefinementArtifact.isRecoveredTranscription(m) else{throw Failure(code:"acoustic_audio_invalid")}}
                    if lru.count>=12 {cache.removeValue(forKey:lru.removeFirst())};cache[name]=data;lru.append(name)
                }
                bytes.append(data[max(0,lo-cursor)..<min(count,hi-cursor)])
            }
            guard bytes.count==hi-lo else{throw Failure(code:"acoustic_window_missing")}
            return bytes.withUnsafeBytes { buffer in let p=buffer.bindMemory(to:UInt8.self);return stride(from:0,to:p.count,by:2).map{Float(Int16(bitPattern:UInt16(p[$0]) | UInt16(p[$0+1])<<8))/32768} }
        }
        func bounds(_ source:String)->(Double,Double)? {
            let m=manifests[source] ?? (try? SpeakerRefinement.object(directory.appendingPathComponent(source+"-manifest.json"))) ?? [:]
            guard let at=m["origin_uptime"] as? Double,at.isFinite,let bytes=m["written_bytes"] as? Int,bytes>0 else{return nil}
            return (at-origin,at-origin+Double(bytes)/32000)
        }
        func voiceSource(_ source:String)->String {
            guard audioSourceCoreID(source)=="mic" else{return source}
            let raw="mic-raw"+source.dropFirst(3)
            return FileManager.default.fileExists(atPath:directory.appendingPathComponent(raw+"-manifest.json").path) ? raw:source
        }
        func suppression(_ source:String,_ lo:Double,_ hi:Double)->Double? {
            let raw=voiceSource(source);guard raw != source,let a=try? window(raw,lo,hi),let b=try? window(source,lo,hi),!a.isEmpty else{return nil}
            let ar=a.reduce(0.0){$0+Double($1*$1)},br=b.reduce(0.0){$0+Double($1*$1)}
            return ar>1e-8 ? sqrt(br/ar):nil
        }
    }

    static func run(request:SpeakerRefinementRequest,modelURL:URL)throws->[String:Any] {
        let directory=URL(fileURLWithPath:request.folder),cacheID=directory.lastPathComponent
        let snapshot=try SpeakerRefinementArtifact.snapshotSHA256(directory:directory,cacheID:cacheID,includeAuxiliaryAudio:true)
        let metadata=try SpeakerRefinement.object(directory.appendingPathComponent("meeting.json"))
        guard metadata["session"] as? String==request.session,let origin=metadata["capture_origin_uptime"] as? Double,origin.isFinite else{throw Failure(code:"acoustic_scope_invalid")}
        let tracks=try meetingAudioTracks(in:directory)
        let meeting=CachedMeeting(id:cacheID,directory:directory,date:Date(),writtenBytes:0,pendingBytes:0,occupiedBytes:0,tracks:tracks,audioCleaned:false,warning:false,retiredBytes:0)
        let hashes=try meeting.transcriptHashes(),events=try meeting.events(includeAutomaticRefinement:false)
        guard events.count<=15000 else{throw Failure(code:"acoustic_capacity")}
        let protected=try SpeakerRefinementArtifact.protectedIDs(directory:directory,session:request.session,events:events)
        let nameFile=directory.appendingPathComponent("session-names.json")
        let nameSnapshot=(try? SpeakerRefinement.object(nameFile)) ?? [:]
        var confirmedNames:[SessionSpeakerKey:String]=[:]
        for row in nameSnapshot["speakers"] as? [[String:Any]] ?? [] {
            if let object=row["key"] as? [String:Any],let name=row["name"] as? String,!name.isEmpty,
               let data=try? JSONSerialization.data(withJSONObject:object),let key=try? JSONDecoder().decode(SessionSpeakerKey.self,from:data),key.session==request.session {confirmedNames[key]=name}
        }
        let audio=Audio(directory,origin,request.allow_unsealed)
        let backend=try SpeakerEmbeddingBackend(model:modelURL);defer{backend.close()}
        func vector(_ source:String,_ lo:Double,_ hi:Double)->[Double]? {
            guard hi-lo>=0.4,let pcm=try? audio.window(audio.voiceSource(source),lo,hi) else{return nil}
            let peak=pcm.reduce(Float(0)){max($0,abs($1))},gain=min(Float(16),max(Float(1),0.8/max(peak,0.000001)))
            let raised=pcm.map{$0*gain}
            guard raised.reduce(0.0,{$0+Double($1)*Double($1)})/Double(raised.count)>=1e-6 else{return nil}
            return try? backend.extract(raised,qualityOK:true,overlap:false,inputKind:"consented_live_audio",allowShortWindow:true).values.map(Double.init)
        }
        var units:[Unit]=[],anchorCandidates:[SessionSpeakerKey:[Anchor]]=[:],singleUtteranceCandidates:[SessionSpeakerKey:[Anchor]]=[:]
        for (index,event) in events.enumerated() {
            guard let id=event["segment_id"] as? String,let source=event["source_id"] as? String else{continue}
            let raw=event["speaker_runs"] as? [[String:Any]] ?? [],rows=raw.isEmpty ? [event]:raw
            for (run,row) in rows.enumerated() {
                guard let lo=row["start"] as? Double,let hi=row["end"] as? Double,hi>lo,lo>=0,hi.isFinite else{continue}
                var scoped=row;for name in ["session","source_id","epoch"] {scoped[name]=event[name]}
                let speaker=row["speaker"] as? [String:Any] ?? [:]
                let rid=raw.isEmpty ? id:TranscriptTimeline.runID(parent:id,run:row)
                units.append(Unit(parent:index,run:raw.isEmpty ? nil:run,id:rid,source:source,start:lo,end:hi,key:SessionSpeakerKey.from(scoped),text:row["text"] as? String ?? "",usable:usableVoice(event) && !protected.contains(id) && !protected.contains(rid),overlap:speaker["basis"] as? String=="multiple" || speaker["reason"] as? String=="overlap"))
            }
            guard event["final"] as? Bool==true,event["end_time_known"] as? Bool==true,(event["quality_flags"] as? [String] ?? []).isEmpty else{continue}
            let joined=TranscriptTimeline.speakerRuns(event)
            for row in joined.isEmpty ? [event]:joined {
                guard let key=SessionSpeakerKey.from(row),let lo=row["start"] as? Double,let hi=row["end"] as? Double,hi-lo>=1.5 else{continue}
                let length=min(3,hi-lo),count=min(3,max(1,Int((hi-lo)/3)))
                let middle=(lo+hi)/2,a=middle-length/2,b=middle+length/2
                if !(audioSourceCoreID(source)=="mic" && audio.suppression(source,a,b).map{$0<0.25}==true) {
                    anchorCandidates[key,default:[]].append(Anchor(key:key,source:source,start:a,end:b,text:row["text"] as? String ?? "",vector:[]))
                }
                // Even one long utterance can supply separate, non-overlapping
                // acoustic windows. This is meeting-local grouping, never voice
                // enrollment or multiple independent consent examples.
                for i in 0..<count where count>1 {
                    let a=count==1 ? (lo+hi-length)/2:lo+Double(i)*(hi-lo-length)/Double(count-1),b=a+length
                    if audioSourceCoreID(source)=="mic",let ratio=audio.suppression(source,a,b),ratio<0.25 {continue}
                    singleUtteranceCandidates[key,default:[]].append(Anchor(key:key,source:source,start:a,end:b,text:row["text"] as? String ?? "",vector:[]))
                }
            }
        }
        for (key,rows) in singleUtteranceCandidates where (anchorCandidates[key]?.count ?? 0)<2 {anchorCandidates[key]=rows}
        guard units.count<=30000 else{throw Failure(code:"acoustic_capacity")}
        var profiles:[Profile]=[]
        let keys=anchorCandidates.keys.sorted{[$0.source,$0.epoch,$0.identity].joined()<[$1.source,$1.epoch,$1.identity].joined()}
        for key in keys {
            let choices=anchorCandidates[key]!.sorted{$0.start<$1.start},count=min(12,choices.count)
            var anchors:[Anchor]=[]
            for i in 0..<count {
                let row=choices[count==1 ? 0:Int((Double(i)*Double(choices.count-1)/Double(count-1)).rounded())]
                if let v=vector(row.source,row.start,row.end) {anchors.append(Anchor(key:key,source:row.source,start:row.start,end:row.end,text:row.text,vector:v))}
            }
            guard anchors.count>=2 else{continue}
            let medoid=anchors.max {a,b in anchors.filter{dot(a.vector,$0.vector)>=0.65}.count<anchors.filter{dot(b.vector,$0.vector)>=0.65}.count}!
            let stable=anchors.filter{dot(medoid.vector,$0.vector)>=0.65}
            guard stable.count>=2,Double(stable.count)/Double(anchors.count)>=0.6 else{continue}
            profiles.append(Profile(key:key,anchors:stable,center:center(stable.map(\.vector))))
        }
        // Microphone copies of system audio have room/device coloration. Do
        // not create a competing person from that coloration: require two
        // simultaneous matching phrases as well as independent voice evidence.
        func echoed(_ mic:Profile,_ remote:Profile)->Bool {
            guard audioSourceCoreID(mic.key.source)=="mic",audioSourceCoreID(remote.key.source) != "mic",
                  dot(mic.center,remote.center)>=0.65 else{return false}
            var proven:[Anchor]=[]
            for anchor in mic.anchors {
                guard !proven.contains(where:{$0.start<anchor.end && $0.end>anchor.start}),dot(anchor.vector,remote.center)>=0.65 else{continue}
                let rows=units.filter{$0.source==remote.key.source && $0.key==remote.key && $0.start<anchor.end && $0.end>anchor.start}.sorted{$0.start<$1.start}
                let covered=rows.reduce(0.0){$0+max(0,min(anchor.end,$1.end)-max(anchor.start,$1.start))}
                guard covered/(anchor.end-anchor.start)>=0.85 else{continue}
                let a=Array(normalized(anchor.text)),b=normalized(rows.map(\.text).joined())
                guard a.count>=6,b.count>=6,(0...(a.count-6)).contains(where:{b.contains(String(a[$0..<($0+6)]))}) else{continue}
                proven.append(anchor)
                if proven.count>=2 {return true}
            }
            return false
        }
        profiles.sort {
            let a=audioSourceCoreID($0.key.source)=="mic",b=audioSourceCoreID($1.key.source)=="mic"
            if a != b {return !a}
            return ($0.anchors.first?.start ?? 0)<($1.anchors.first?.start ?? 0)
        }
        var groups:[[Profile]]=[],echoProfiles=Set<SessionSpeakerKey>()
        func sameVoice(_ a:Profile,_ b:Profile)->Bool {
            // A new capture generation changes the diarizer's slot numbers,
            // not the person. Require multiple independent voice samples on
            // both sides. Cross-device room coloration must instead pass the
            // simultaneous-phrase echo check below, even at high similarity.
            guard audioSourceCoreID(a.key.source)==audioSourceCoreID(b.key.source),
                  a.key.epoch != b.key.epoch,
                  dot(a.center,b.center)>=0.85 else{return false}
            func supports(_ from:Profile,_ to:Profile)->Bool {
                let alternatives=profiles.filter{$0.key.epoch==to.key.epoch && $0.key != to.key && audioSourceCoreID($0.key.source)==audioSourceCoreID(to.key.source)}
                guard alternatives.allSatisfy({dot(from.center,to.center)-dot(from.center,$0.center)>=0.15}) else{return false}
                return from.anchors.filter{dot($0.vector,to.center)>=0.70}.count>=2
            }
            return supports(a,b) && supports(b,a)
        }
        for profile in profiles {
            let compatible:(Profile)->Bool={prior in
                if let a=confirmedNames[prior.key],let b=confirmedNames[profile.key],a != b {return false}
                return true
            }
            if let index=groups.firstIndex(where:{$0.allSatisfy{compatible($0) && sameVoice($0,profile)}}) {groups[index].append(profile)}
            else if let index=groups.firstIndex(where:{group in
                group.allSatisfy{compatible($0) && dot($0.center,profile.center)>=0.65} && group.contains{echoed(profile,$0)}
            }) {groups[index].append(profile);echoProfiles.insert(profile.key)}
            else {groups.append([profile])}
        }
        // Keep short-form exemplars as well as sentence-length anchors. A
        // vowel-only answer should be compared with other brief speech, not
        // only with the centroid of several phonetic-rich sentences. These
        // exemplars must agree with both the original slot and independent
        // long-form audio; they are never enrollment samples.
        var references=groups.map{$0.flatMap(\.anchors)}
        let sentenceReferences=references
        func score(_ v:[Double],_ anchors:[Anchor])->Double? {
            let values=anchors.map{dot(v,$0.vector)}.sorted(by:>)
            guard values.count>=2 else{return nil};let top=values.prefix(3)
            return top.reduce(0,+)/Double(top.count)
        }
        for i in groups.indices {
            let keys=Set(groups[i].map(\.key))
            let candidates=units.filter{$0.usable && !$0.overlap && $0.key.map{keys.contains($0)}==true && $0.end-$0.start>=0.4 && $0.end-$0.start<1.5}
            var additions:[Anchor]=[]
            for u in candidates.prefix(48) {
                guard let v=vector(u.source,u.start,u.end) else{continue}
                let ranked=groups.indices.compactMap{j -> (Int,Double)? in
                    let available=sentenceReferences[j].filter{!($0.source==u.source && $0.start<u.end && $0.end>u.start)}
                    return score(v,available).map{(j,$0)}
                }.sorted{$0.1>$1.1}
                guard ranked.first?.0==i,ranked[0].1>=0.45,ranked[0].1-(ranked.dropFirst().first?.1 ?? 0)>=0.2 else{continue}
                additions.append(Anchor(key:u.key!,source:u.source,start:u.start,end:u.end,text:u.text,vector:v))
            }
            if additions.count>=2 {references[i].append(contentsOf:additions.prefix(12))}
        }
        // A capture generation can consist entirely of brief acknowledgements.
        // Long-sentence-only anchors lose that generation's person. Recover a
        // coherent original slot from several separate short utterances, then
        // bridge it to another generation of the SAME remote source. Repeated
        // evidence and a clear competing-voice margin are both required.
        var shortProfiles:[Profile]=[]
        let profiled=Set(profiles.map(\.key))
        let shortKeys=Set(units.compactMap{$0.usable && !$0.overlap && $0.end-$0.start>=0.4 && $0.end-$0.start<1.5 ? $0.key:nil})
        for key in shortKeys.sorted(by:{($0.source+$0.epoch+$0.identity)<($1.source+$1.epoch+$1.identity)}) where !profiled.contains(key) && audioSourceCoreID(key.source) != "mic" {
            let rows=units.filter{$0.usable && !$0.overlap && $0.key==key && $0.end-$0.start>=0.4 && $0.end-$0.start<1.5}
            var anchors:[Anchor]=[]
            for u in rows.prefix(24) {
                if let v=vector(u.source,u.start,u.end) {anchors.append(Anchor(key:key,source:u.source,start:u.start,end:u.end,text:u.text,vector:v))}
            }
            guard anchors.count>=3 else{continue}
            let medoid=anchors.max {a,b in anchors.filter{dot(a.vector,$0.vector)>=0.75}.count<anchors.filter{dot(b.vector,$0.vector)>=0.75}.count}!
            let stable=anchors.filter{dot(medoid.vector,$0.vector)>=0.75}
            guard stable.count>=3,Double(stable.count)/Double(anchors.count)>=0.8 else{continue}
            let p=Profile(key:key,anchors:stable,center:center(stable.map(\.vector)))
            let ranked=groups.indices.compactMap {i -> (Int,Double)? in
                let compatible=groups[i].filter{audioSourceCoreID($0.key.source)==audioSourceCoreID(key.source) && $0.key.epoch != key.epoch}
                guard !compatible.isEmpty,!groups[i].contains(where:{confirmedNames[$0.key] != nil && confirmedNames[key] != nil && confirmedNames[$0.key] != confirmedNames[key]}) else{return nil}
                let anchors=references[i].filter{audioSourceCoreID($0.source)==audioSourceCoreID(key.source) && $0.key.epoch != key.epoch}
                return score(p.center,anchors).map{(i,$0)}
            }.sorted{$0.1>$1.1}
            guard let best=ranked.first,best.1>=0.5,best.1-(ranked.dropFirst().first?.1 ?? 0)>=0.2 else{continue}
            let supported=stable.filter {a in
                let scores=ranked.map{entry in
                    (entry.0,score(a.vector,references[entry.0].filter{audioSourceCoreID($0.source)==audioSourceCoreID(key.source)}) ?? 0)
                }.sorted{$0.1>$1.1}
                return scores.first?.0==best.0 && scores[0].1>=0.45 && scores[0].1-(scores.dropFirst().first?.1 ?? 0)>=0.15
            }
            guard supported.count>=3,Double(supported.count)/Double(stable.count)>=0.8 else{continue}
            groups[best.0].append(p);references[best.0].append(contentsOf:p.anchors);shortProfiles.append(p)
        }
        for i in groups.indices {
            let preferred=groups[i].firstIndex(where:{confirmedNames[$0.key] != nil}) ?? groups[i].firstIndex(where:{audioSourceCoreID($0.key.source) != "mic"}) ?? 0
            if preferred>0 {groups[i].swapAt(0,preferred)}
        }
        let echoGroups=Set(groups.filter{$0.contains{echoProfiles.contains($0.key)}}.map{$0[0].key})
        func match(_ v:[Double],_ unit:Unit,window:(Double,Double))->Match? {
            let ranked=groups.indices.compactMap { index -> (SessionSpeakerKey,Double)? in
                let group=groups[index]
                let values=references[index].filter{!($0.source==unit.source && $0.start<window.1 && $0.end>window.0)}.map{dot(v,$0.vector)}.sorted(by:>)
                let required=group.contains(where:{$0.key==unit.key}) ? 1:2
                guard values.count>=required else{return nil};let top=values.prefix(3);return (group[0].key,top.reduce(0,+)/Double(top.count))
            }.sorted{$0.1>$1.1}
            guard let best=ranked.first else{return nil}
            return Match(key:best.0,score:best.1,margin:best.1-(ranked.dropFirst().first?.1 ?? 0))
        }
        var matches=[Match?](repeating:nil,count:units.count),direct=[Match?](repeating:nil,count:units.count),echoes:[Int:String]=[:]
        for (i,u) in units.enumerated() where u.usable && u.end-u.start>=0.4 {
            let duration=min(3,u.end-u.start),mid=(u.start+u.end)/2
            if let v=vector(u.source,mid-duration/2,mid+duration/2),let m=match(v,u,window:(mid-duration/2,mid+duration/2)) {
                direct[i]=m;if !u.overlap,m.score>=0.62,m.margin>=0.18 {matches[i]=m}
            }
        }
        var soloVerified=Set<Int>()
        let segmentationDirectory=modelURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("local-speaker-install/runtime-models/community-1/Segmentation.mlmodelc")
        let segmentation=try MeetingSpeechIntervals(directory:segmentationDirectory)
        for (i,u) in units.enumerated() where u.usable && matches[i]==nil && (u.end-u.start<2 || u.overlap) {
            guard let span=try segmentation.solo(source:u.source,start:u.start,end:u.end,audio:audio) else{continue}
            let duration=min(3,span.1-span.0),lo=max(span.0,min((u.start+u.end-duration)/2,span.1-duration))
            guard let v=vector(u.source,lo,lo+duration),let m=match(v,u,window:(lo,lo+duration)),m.score>=0.68,m.margin>=0.20,
                  !(direct[i].map{$0.score>=0.45 && $0.margin>=0.1 && $0.key != m.key} ?? false) else{continue}
            matches[i]=m;soloVerified.insert(i)
        }
        // Before the online diarizer emits its first slot, there can already
        // be several complete answers on that source. A verified short-only
        // profile can resolve those too; a channel alone never supplies a name.
        for (i,u) in units.enumerated() where u.usable && !u.overlap && matches[i]==nil {
            let local=shortProfiles.filter{$0.key.source==u.source}
            let observed=Set(units.filter{$0.source==u.source}.compactMap(\.key))
            guard local.count==1,observed==Set(local.map(\.key)),u.key==nil || u.key==local[0].key,
                  let m=direct[i],m.score>=0.45,m.margin>=0.2,
                  let g=groups.first(where:{$0.contains(where:{$0.key==local[0].key})}),g[0].key==m.key,
                  try segmentation.solo(source:u.source,start:u.start,end:u.end,audio:audio) != nil else{continue}
            matches[i]=m;soloVerified.insert(i)
        }
        // Keep a well-supported original slot for brief speech when its own
        // acoustic best match agrees. A short vowel has less phonetic variety
        // than a sentence; it must not be reset just for missing the long-form
        // threshold. Independent segmentation still has to prove solo speech.
        for (i,u) in units.enumerated() where u.usable && !u.overlap && matches[i]==nil && u.end-u.start<2 {
            guard let original=u.key,let group=groups.first(where:{$0.contains(where:{$0.key==original})}),
                  let m=direct[i],m.key==group[0].key,m.score>=0.45,m.margin>=0.2,
                  try segmentation.solo(source:u.source,start:u.start,end:u.end,audio:audio) != nil else{continue}
            matches[i]=m;soloVerified.insert(i)
        }
        // Missing short-window evidence is not contrary evidence. Preserve an
        // existing online slot once its meeting-level voice has been verified;
        // only an independently conflicting voice should withdraw that label.
        // This maps the original slot across generations, never a neighbour's
        // name, and is kept separate from per-span verified voice samples.
        var retainedSlots=Set<Int>()
        for (i,u) in units.enumerated() where u.usable && !u.overlap && matches[i]==nil && u.end-u.start<1.5 {
            guard let original=u.key,let group=groups.first(where:{$0.contains(where:{$0.key==original})}),
                  !(direct[i].map{$0.key != group[0].key && $0.score>=0.45 && $0.margin>=0.1} ?? false) else{continue}
            matches[i]=Match(key:group[0].key,score:0,margin:0);retainedSlots.insert(i)
        }
        // Echo removal is a reading projection, never deletion of the source.
        // Require independent audio identity, AEC attenuation, matching words
        // and simultaneous remote speech. Double talk / local questions stay.
        let remote=units.indices.filter{audioSourceCoreID(units[$0].source) != "mic" && matches[$0] != nil}
        for (i,u) in units.enumerated() where u.usable && audioSourceCoreID(u.source)=="mic" {
            guard let m=matches[i],m.score>=0.65 else{continue}
            let a=normalized(u.text);guard a.count>=4 else{continue}
            let duration=min(3,u.end-u.start),mid=(u.start+u.end)/2
            guard duration>=0.25 else{continue}
            let ratio=audio.suppression(u.source,mid-duration/2,mid+duration/2)
            guard ratio.map{$0<0.20}==true || echoGroups.contains(m.key) else{continue}
            if let j=remote.first(where:{j in
                let r=units[j],overlap=max(0,min(u.end,r.end)-max(u.start,r.start))
                return matches[j]!.key==m.key && overlap/(u.end-u.start)>=0.85 && sameWords(a,normalized(r.text))
            }) {echoes[i]=units[j].id}
        }
        var projected=events,changed=Set<Int>(),resolved=0
        for (i,u) in units.enumerated() where u.usable && (!u.overlap || soloVerified.contains(i)) {
            var speaker:[String:Any]
            if let m=matches[i] {
                speaker=["basis":"meeting_reconciliation","source_id":u.source,"epoch":events[u.parent]["epoch"] ?? NSNull(),"identity_key":try JSONSerialization.jsonObject(with:JSONEncoder().encode(m.key)),"acoustic_verified":true]
                if soloVerified.contains(i) {speaker["solo_verified"]=true}
                if retainedSlots.contains(i) {speaker["slot_continuity"]=true}
                if let echo=echoes[i] {speaker["echo_of"]=echo};resolved+=1
            } else {speaker=["basis":"unknown","reason":"acoustic_unresolved"]}
            if let run=u.run {var rows=projected[u.parent]["speaker_runs"] as! [[String:Any]];rows[run]["speaker"]=speaker;projected[u.parent]["speaker_runs"]=rows}
            else {projected[u.parent]["speaker"]=speaker}
            changed.insert(u.parent)
        }
        let records=try changed.sorted().map{index -> [String:Any] in
            ["segment_id":events[index]["segment_id"]!,"original_sha256":try SpeakerRefinementArtifact.originalEventSHA256(events[index]),"speaker":projected[index]["speaker"] ?? events[index]["speaker"] ?? [:],"speaker_runs":projected[index]["speaker_runs"] ?? []]
        }
        guard try meeting.transcriptHashes()==hashes,try SpeakerRefinementArtifact.snapshotSHA256(directory:directory,cacheID:cacheID,includeAuxiliaryAudio:true)==snapshot else{throw Failure(code:"acoustic_source_changed")}
        let result:[String:Any] = ["schema":1,"method":method,"model":model,"cache_id":cacheID,"session":request.session,"source_sha256":hashes,"snapshot_sha256":snapshot,"records":records,"summary":["units":units.count,"resolved":resolved,"echoes":echoes.count,"original_profiles":profiles.count,"short_profiles":shortProfiles.count,"voices":groups.count,"solo_recovered":soloVerified.count,"slot_retained":retainedSlots.count,"segmentation_windows":segmentation.predictions],"capture":false,"cloud":false]
        _=try SpeakerRefinementArtifact.validateApply(object:result,events:events,sourceHashes:hashes,directory:directory,cacheID:cacheID)
        return result
    }
}
