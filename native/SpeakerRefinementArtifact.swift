import Foundation
import CryptoKit
import CoreFoundation

enum SpeakerRefinementArtifactError:Error,Equatable {
    case invalidScope
    case invalidPath
    case invalidSnapshot
    case invalidArtifact
    case sourceChanged
    case eventChanged
    case unsupportedSpeakerChange
    case unknownSlot
    case fileTooLarge
}

/// A reversible, hash-bound speaker projection layered over the legacy
/// reconciliation sidecar. It never mutates provider transcript or audio.
enum SpeakerRefinementArtifact {
    static let filename="automatic-speaker-refinement.json"
    static let method="longer_context_v1"
    static let model="nemotron3-fast128:25a90f97f254428d4b30374b76af9c74fdee8327"
    static let offlineMethod="whole_meeting_v2"
    static let offlineModel="pyannote-community-1-coreml:df2625ac79a7ac6b65ad868fee6d80f320da4232"
    static let maximumBytes=8*1024*1024
    private static let maximumEventCount=50_000
    private static let maximumSources=32

    struct Prepared {
        let projectedEvents:[[String:Any]]
        fileprivate let target:URL
        fileprivate let directory:URL
        fileprivate let cacheID:String
        fileprivate let data:Data
        fileprivate init(target:URL,directory:URL,cacheID:String,data:Data,projectedEvents:[[String:Any]]) {
            self.target=target;self.directory=directory;self.cacheID=cacheID;self.data=data;self.projectedEvents=projectedEvents
        }
    }

    static func isRecoveredTranscription(_ manifest:[String:Any])->Bool {
        guard ["cache_unclean_shutdown","cache_writer_backpressure"].contains(manifest["error"] as? String ?? ""),
              !(manifest["processing_error"] is String),
              let written=manifest["written_bytes"] as? Int,
              let committed=manifest["asr_committed_bytes"] as? Int else{return false}
        return RecordingJournal.transcriptionIsComplete(ended:manifest["ended"] as? Bool==true,
            written:written,committed:committed,error:manifest["error"] as? String)
    }
    private static func digest(_ data:Data)->String {
        SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    }
    private static func jsonData(_ object:Any)throws->Data {
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
    }
    private static func validDigest(_ value:String)->Bool {
        value.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil
    }
    private static func validCacheID(_ cacheID:String)->Bool {
        UUID(uuidString:cacheID) != nil && cacheID.count<=64
    }
    private static func isSymlinkEntry(_ url:URL)->Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath:url.path)) != nil
    }
    private static func transcriptTrack(from filename:String)->String? {
        let suffix="-transcript.jsonl"
        guard filename.hasSuffix(suffix) else{return nil}
        let track=String(filename.dropLast(suffix.count))
        return isTranscriptAudioTrack(track) && track.count<=64 ? track:nil
    }
    private static func validateSourceHashes(_ sourceHashes:[String:String])throws->[String] {
        guard sourceHashes.count<=maximumSources else{throw SpeakerRefinementArtifactError.invalidSnapshot}
        var tracks:[String]=[]
        for (name,hash) in sourceHashes {
            guard let track=transcriptTrack(from:name),validDigest(hash),!tracks.contains(track) else{throw SpeakerRefinementArtifactError.invalidSnapshot}
            tracks.append(track)
        }
        return tracks.sorted()
    }
    private static func checkedDirectory(_ directory:URL,cacheID:String)throws->URL {
        guard validCacheID(cacheID),directory.isFileURL,directory.path.count<=4096,
              directory.lastPathComponent==cacheID,
              !directory.pathComponents.contains(".."),
              URL(fileURLWithPath:directory.path).standardizedFileURL.path==directory.standardizedFileURL.path else{throw SpeakerRefinementArtifactError.invalidScope}
        let values=try directory.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard values.isDirectory==true,values.isSymbolicLink != true else{throw SpeakerRefinementArtifactError.invalidPath}
        let parent=directory.deletingLastPathComponent()
        let parentValues=try parent.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard parentValues.isDirectory==true,parentValues.isSymbolicLink != true else{throw SpeakerRefinementArtifactError.invalidPath}
        // Require the directory entry itself to resolve to the supplied path;
        // no caller-provided cache path may escape through an alias component.
        let resolved=directory.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path==directory.standardizedFileURL.path else{throw SpeakerRefinementArtifactError.invalidPath}
        return directory.standardizedFileURL
    }
    private static func readOptional(_ name:String,in directory:URL,limit:Int)throws->Data? {
        let chunkMatch=name.range(of:"^([a-z0-9-]+)-([0-9]{6})\\.pcm$",options:.regularExpression)
        let chunkTrack=chunkMatch.map{String(name[$0].split(separator:"-").dropLast().joined(separator:"-"))}
        guard name=="meeting.json" || name=="speaker-reconciliation.json" ||
              (name.hasSuffix("-manifest.json") && isMeetingAudioTrack(String(name.dropLast("-manifest.json".count)))) ||
              (chunkTrack.map{isMeetingAudioTrack($0)} ?? false) else{throw SpeakerRefinementArtifactError.invalidPath}
        guard name.count<=128 else{throw SpeakerRefinementArtifactError.invalidPath}
        let file=directory.appendingPathComponent(name,isDirectory:false)
        guard FileManager.default.fileExists(atPath:file.path) || isSymlinkEntry(file) else{return nil}
        let values=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey])
        guard values.isSymbolicLink != true,values.isRegularFile==true else{throw SpeakerRefinementArtifactError.invalidPath}
        guard let count=values.fileSize,count>=0,count<=limit else{throw SpeakerRefinementArtifactError.fileTooLarge}
        return try Data(contentsOf:file,options:[.mappedIfSafe])
    }

    /// Returns the raw snapshot hash map, with empty strings for missing inputs.
    /// The map also includes every discovered manifest so a newly appearing
    /// track invalidates a result computed from an earlier snapshot.
    static func snapshotHashes(directory:URL,cacheID:String,sourceHashes:[String:String]=[:],includeAuxiliaryAudio:Bool=false)throws->[String:String] {
        let directory=try checkedDirectory(directory,cacheID:cacheID)
        let sourceTracks=try validateSourceHashes(sourceHashes)
        var tracks=Set(sourceTracks)
        let listing=try FileManager.default.contentsOfDirectory(atPath:directory.path)
        guard listing.count<=100_000 else{throw SpeakerRefinementArtifactError.invalidSnapshot}
        for name in listing {
            if name.hasSuffix("-manifest.json") {
                let suffix="-manifest.json",track=String(name.dropLast(suffix.count))
                guard isMeetingAudioTrack(track),track.count<=64 else{throw SpeakerRefinementArtifactError.invalidPath}
                if includeAuxiliaryAudio || isTranscriptAudioTrack(track) {tracks.insert(track)}
            } else if name.hasSuffix("-transcript.jsonl") {
                let suffix="-transcript.jsonl",track=String(name.dropLast(suffix.count))
                guard isTranscriptAudioTrack(track),track.count<=64 else{throw SpeakerRefinementArtifactError.invalidPath}
                tracks.insert(track)
            }
        }
        guard tracks.count<=(includeAuxiliaryAudio ? maximumSources*4:maximumSources) else{throw SpeakerRefinementArtifactError.invalidSnapshot}
        var hashes:[String:String]=[:]
        if let data=try readOptional("meeting.json",in:directory,limit:64*1024) {
            if includeAuxiliaryAudio {
                let metadata=try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
                // Health, costs and UI title may update while paused. Only
                // identity/clock/archive fields affect this local audio pass.
                let fields=Set(["schema","session","capture_origin_uptime","archive_only_before_append"])
                hashes["meeting.json"]=digest(try jsonData(metadata.filter{fields.contains($0.key)}))
            } else {hashes["meeting.json"]=digest(data)}
        } else {hashes["meeting.json"]=""}
        for track in tracks.sorted() {
            let name=track+"-manifest.json"
            guard let data=try readOptional(name,in:directory,limit:512*1024) else {hashes[name]="";continue}
            hashes[name]=digest(data)
            let manifest=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            guard let manifest=manifest,manifest["schema"] as? Int==1,manifest["track"] as? String==track,
                  let ended=manifest["ended"] as? Bool,let chunks=manifest["chunks"] as? [[String:Any]],chunks.count<=10_000 else{throw SpeakerRefinementArtifactError.invalidSnapshot}
            var priorIndex = -1
            for (position,chunk) in chunks.enumerated() {
                guard let index=chunk["index"] as? Int,index>=0,index<=999_999,index>priorIndex,
                      let count=chunk["bytes"] as? Int,count>0,count<=320_000 else{throw SpeakerRefinementArtifactError.invalidSnapshot}
                priorIndex=index
                let hasDigest=chunk["sha256"] as? String
                if let hasDigest {guard validDigest(hasDigest) else{throw SpeakerRefinementArtifactError.invalidSnapshot};continue}
                guard chunk["sha256"]==nil,(!ended || isRecoveredTranscription(manifest)),position==chunks.count-1 else{throw SpeakerRefinementArtifactError.invalidSnapshot}
                let chunkName=String(format:"%@-%06d.pcm",track,index)
                guard let pcm=try readOptional(chunkName,in:directory,limit:320_000),pcm.count==count else{throw SpeakerRefinementArtifactError.invalidSnapshot}
                let after=try readOptional(name,in:directory,limit:512*1024)
                guard after==data else{throw SpeakerRefinementArtifactError.invalidSnapshot}
                hashes["snapshot-tail/"+chunkName]="\(pcm.count):\(digest(pcm))"
            }
        }
        if let data=try readOptional("speaker-reconciliation.json",in:directory,limit:maximumBytes) {hashes["speaker-reconciliation.json"]=digest(data)} else {hashes["speaker-reconciliation.json"]=""}
        return hashes
    }

    /// Deterministic digest of meeting metadata, all track manifests and the
    /// legacy speaker sidecar. Callers can retain the returned hash for commit.
    static func snapshotSHA256(directory:URL,cacheID:String,sourceHashes:[String:String]=[:],includeAuxiliaryAudio:Bool=false)throws->String {
        digest(try jsonData(snapshotHashes(directory:directory,cacheID:cacheID,sourceHashes:sourceHashes,includeAuxiliaryAudio:includeAuxiliaryAudio)))
    }

    /// Hashes an input projected event while ignoring only transient warning
    /// decorations. Speaker state and the legacy-applied marker remain bound.
    static func originalEventSHA256(_ event:[String:Any])throws->String {
        var stable=event
        stable.removeValue(forKey:"speaker_reconciliation_warning")
        stable.removeValue(forKey:"speaker_refinement_warning")
        return digest(try jsonData(stable))
    }

    /// Manual sentence/run assignments take precedence over automatic output.
    /// A confirmed turn anchor protects its parent because one manual span can
    /// overlap more than one provider run.
    static func protectedIDs(directory:URL,session:String,events:[[String:Any]] = [])throws->Set<String> {
        guard !session.isEmpty,session.count<=160 else{throw SpeakerRefinementArtifactError.invalidScope}
        let directory=try checkedDirectory(directory,cacheID:directory.lastPathComponent)
        let file=directory.appendingPathComponent("session-names.json",isDirectory:false)
        guard FileManager.default.fileExists(atPath:file.path) || isSymlinkEntry(file) else{return []}
        let values=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey])
        guard values.isSymbolicLink != true,values.isRegularFile==true else{throw SpeakerRefinementArtifactError.invalidPath}
        guard let size=values.fileSize,size>=0,size<=4*1024*1024 else{throw SpeakerRefinementArtifactError.fileTooLarge}
        let data=try Data(contentsOf:file,options:[.mappedIfSafe])
        let normalized=try normalizedNameSnapshot(data,events:events,directory:directory,session:session)
        guard data.count<=4*1024*1024,let snapshot=try JSONSerialization.jsonObject(with:normalized) as? [String:Any],
              [1,2].contains(snapshot["schema"] as? Int ?? 0),snapshot["session"] as? String==session else{throw SpeakerRefinementArtifactError.invalidScope}
        var protected=Set<String>()
        if let sentences=snapshot["sentences"] as? [String:String] {
            guard sentences.count<=4096,sentences.keys.allSatisfy({!$0.isEmpty && $0.count<=256}) else{throw SpeakerRefinementArtifactError.invalidArtifact}
            protected.formUnion(sentences.keys)
        } else if snapshot["sentences"] != nil {throw SpeakerRefinementArtifactError.invalidArtifact}
        if let assignments=snapshot["assignments"] as? [[String:Any]] {
            guard assignments.count<=4096 else{throw SpeakerRefinementArtifactError.invalidArtifact}
            for assignment in assignments {
                guard let id=assignment["id"] as? String,!id.isEmpty,id.count<=256,
                      let key=assignment["key"] as? [String:Any],key["session"] as? String==session else{throw SpeakerRefinementArtifactError.invalidArtifact}
                protected.insert(id)
            }
        } else if snapshot["assignments"] != nil {throw SpeakerRefinementArtifactError.invalidArtifact}
        if let anchors=snapshot["runAnchors"] as? [[String:Any]] {
            guard anchors.count<=4096 else{throw SpeakerRefinementArtifactError.invalidArtifact}
            for anchor in anchors {
                guard let id=anchor["id"] as? String,!id.isEmpty,id.count<=256,
                      let parent=anchor["parent"] as? String,!parent.isEmpty,parent.count<=256,
                      anchor["session"] as? String==session,
                      let source=anchor["source"] as? String,isTranscriptAudioTrack(source),
                      let epoch=anchor["epoch"] as? String,!epoch.isEmpty,epoch.count<=160,
                      let start=anchor["start"] as? Double,start.isFinite,start>=0,
                      let end=anchor["end"] as? Double,end.isFinite,end>start,end<1e8,
                      let textHash=anchor["textSHA256"] as? String,validDigest(textHash) else{throw SpeakerRefinementArtifactError.invalidArtifact}
                let stamp=String(Int((start*1000).rounded()))
                guard id==parent+":word:"+stamp || id==parent+":turn:"+stamp else{throw SpeakerRefinementArtifactError.invalidArtifact}
                guard !events.isEmpty else{protected.insert(id);continue}
                guard let event=events.first(where:{$0["segment_id"] as? String==parent}),
                      event["session"] as? String==session,event["source_id"] as? String==source,
                      event["epoch"] as? String==epoch,anchorTextMatches(anchor:anchor,event:event) else{continue}
                protected.insert(id)
                let runs=event["speaker_runs"] as? [[String:Any]] ?? []
                if runs.isEmpty {protected.insert(parent);continue}
                var overlapping=0
                for run in runs {
                    guard let runStart=run["start"] as? Double,let runEnd=run["end"] as? Double,
                          runStart.isFinite,runEnd.isFinite,runEnd>runStart else{continue}
                    // Strict comparisons mean that touching endpoints do not
                    // make neighboring human and automatic spans overlap.
                    if runStart < end && runEnd > start {
                        protected.insert(TranscriptTimeline.runID(parent:parent,run:run));overlapping+=1
                    }
                }
                if overlapping==0 {continue}
            }
        } else if snapshot["runAnchors"] != nil {throw SpeakerRefinementArtifactError.invalidArtifact}
        return protected
    }

    /// Creates a temporary transcript projection for whole-meeting alignment.
    /// Manual labels are useful as anchors only when their persisted key can
    /// be tied to an existing anonymous slot in the exact same scope. Labels
    /// that cannot be resolved are changed to `unknown` in this projection so
    /// the old automatic slot cannot bias the global mapping.
    static func alignmentEvents(directory:URL,session:String,events:[[String:Any]])throws->[[String:Any]] {
        guard !session.isEmpty,session.count<=160,events.count<=maximumEventCount,
              events.allSatisfy({$0["session"] as? String==session}) else{throw SpeakerRefinementArtifactError.invalidScope}
        let protected=try protectedIDs(directory:directory,session:session,events:events)
        let file=directory.appendingPathComponent("session-names.json",isDirectory:false)
        guard FileManager.default.fileExists(atPath:file.path) || isSymlinkEntry(file) else{return events}
        let values=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey])
        guard values.isSymbolicLink != true,values.isRegularFile==true else{throw SpeakerRefinementArtifactError.invalidPath}
        guard let size=values.fileSize,size>=0,size<=4*1024*1024 else{throw SpeakerRefinementArtifactError.fileTooLarge}
        let data=try Data(contentsOf:file,options:[.mappedIfSafe])
        guard data.count<=4*1024*1024,let snapshot=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              [1,2].contains(snapshot["schema"] as? Int ?? 0),snapshot["session"] as? String==session else{throw SpeakerRefinementArtifactError.invalidScope}

        let names=snapshot["sentences"] as? [String:String] ?? [:]
        let assignmentRows=snapshot["assignments"] as? [[String:Any]] ?? []
        let anchorRows=snapshot["runAnchors"] as? [[String:Any]] ?? []
        guard names.count<=4096,assignmentRows.count<=4096,anchorRows.count<=4096 else{throw SpeakerRefinementArtifactError.invalidArtifact}
        var assignments:[String:[String:Any]]=[:]
        for row in assignmentRows {
            guard let id=row["id"] as? String,!id.isEmpty,id.count<=256,
                  let key=row["key"] as? [String:Any],key["session"] as? String==session,
                  assignments[id]==nil else{throw SpeakerRefinementArtifactError.invalidArtifact}
            assignments[id]=key
        }
        let evidence=knownEvidence(events)
        func resolvedTarget(_ raw:[String:Any]?,event:[String:Any])->[String:Any]? {
            guard let raw=raw,
                  let data=try? jsonData(raw),let key=try? JSONDecoder().decode(SessionSpeakerKey.self,from:data),
                  let scope=try? scope(event),key.session==session,key.sameScope(scope),
                  key.identity.hasPrefix("slot:"),evidence.contains(key),
                  let slot=Int(key.identity.dropFirst(5)),(0..<8).contains(slot) else{return nil}
            return ["basis":"anonymous_cluster","cluster_id":slot,"source_id":key.source,"epoch":key.epoch]
        }
        let hidden:[String:Any]=["basis":"unknown","reason":"manual_alignment_unresolved"]
        var output=events
        for index in output.indices {
            let event=output[index]
            guard let parent=event["segment_id"] as? String else{throw SpeakerRefinementArtifactError.invalidArtifact}
            let rows=event["speaker_runs"] as? [[String:Any]] ?? []
            var changed=event
            let sentenceNamed=names[parent] != nil
            let parentTarget=resolvedTarget(assignments[parent],event:event)
            if rows.isEmpty {
                if sentenceNamed {changed["speaker"]=hidden}
                else if assignments[parent] != nil {changed["speaker"]=parentTarget ?? hidden}
                else if protected.contains(parent) {changed["speaker"]=hidden}
                output[index]=changed
                continue
            }

            var projected:[[String:Any]]=[]
            for originalRun in rows {
                var run=originalRun
                let runID=TranscriptTimeline.runID(parent:parent,run:originalRun)
                if sentenceNamed {
                    run["speaker"]=hidden
                    projected.append(run)
                    continue
                }
                if assignments[parent] != nil {run["speaker"]=parentTarget ?? hidden}
                if assignments[runID] != nil {
                    run["speaker"]=resolvedTarget(assignments[runID],event:event) ?? hidden
                }
                var matchingAnchors:[([String:Any],Bool)]=[]
                for anchor in anchorRows where anchor["parent"] as? String==parent {
                    guard anchor["session"] as? String==session,
                          let start=anchor["start"] as? Double,let end=anchor["end"] as? Double,
                          start.isFinite,end.isFinite,end>start,
                          let runStart=originalRun["start"] as? Double,let runEnd=originalRun["end"] as? Double,
                          start < runEnd && end > runStart else{continue}
                    guard let source=anchor["source"] as? String,let epoch=anchor["epoch"] as? String,
                          source==event["source_id"] as? String,epoch==event["epoch"] as? String else {
                        run["speaker"]=hidden
                        matchingAnchors.append(([:],false))
                        continue
                    }
                    guard let anchorID=anchor["id"] as? String,
                          protected.contains(anchorID),anchorTextMatches(anchor:anchor,event:event) else {
                        // A same-scope anchor that no longer matches the source
                        // words must not leave the stale automatic label as
                        // alignment evidence.
                        run["speaker"]=hidden
                        matchingAnchors.append(([:],false))
                        continue
                    }
                    let fullyCovers=start<=runStart && end>=runEnd
                    matchingAnchors.append((anchor,fullyCovers))
                }
                if !matchingAnchors.isEmpty {
                    let candidates=matchingAnchors.compactMap { anchor,full -> [String:Any]? in
                        guard full,let id=anchor["id"] as? String else{return nil}
                        return resolvedTarget(assignments[id],event:event)
                    }
                    if matchingAnchors.count==candidates.count,
                       let first=candidates.first,
                       candidates.dropFirst().allSatisfy({(try? speakerJSONEqual($0,first))==true}) {
                        run["speaker"]=first
                    } else {run["speaker"]=hidden}
                }
                if names[runID] != nil {run["speaker"]=hidden}
                projected.append(run)
            }
            changed["speaker_runs"]=projected
            if names[parent] != nil {changed["speaker"]=hidden}
            else if assignments[parent] != nil {changed["speaker"]=parentTarget ?? hidden}
            output[index]=changed
        }
        return output
    }

    /// Older versions anchored names to the displayed clean text. Resolve only
    /// exact, hash-verified sidecar units back to source words; never guess from
    /// a matching name, timestamp alone, or a changed transcript. This is an
    /// in-memory compatibility view; the original names file stays untouched.
    static func normalizedNameSnapshot(_ data:Data,events:[[String:Any]],directory:URL,session:String)throws->Data {
        guard data.count<=4*1024*1024,!events.isEmpty,
              var snapshot=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              snapshot["session"] as? String==session,
              var anchors=snapshot["runAnchors"] as? [[String:Any]],!anchors.isEmpty else{return data}
        let file=directory.appendingPathComponent("automatic-coarse-refinement.json")
        guard let attrs=try? file.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey]),
              attrs.isSymbolicLink != true,attrs.isRegularFile==true,(attrs.fileSize ?? Int.max)<=32*1024*1024,
              let artifactData=try? Data(contentsOf:file),
              let artifact=(try? JSONSerialization.jsonObject(with:artifactData)) as? [String:Any],
              artifact["schema"] as? Int==1,artifact["method"] as? String=="audio_coarse_v1",
              artifact["session"] as? String==session,artifact["cache_id"] as? String==directory.lastPathComponent,
              let records=artifact["records"] as? [[String:Any]],records.count<=50_000 else{return data}
        var byID:[String:[String:Any]]=[:]
        for row in records {
            guard let id=row["unit_id"] as? String,byID[id]==nil else{return data}
            byID[id]=row
        }
        var eventsByParent:[String:[String:Any]]=[:]
        for event in events {
            guard let id=event["segment_id"] as? String,eventsByParent[id]==nil else{return data}
            eventsByParent[id]=event
        }
        var changed=false
        for index in anchors.indices {
            let anchor=anchors[index]
            guard let parent=anchor["parent"] as? String,let lo=anchor["start"] as? Double,
                  let hi=anchor["end"] as? Double,let expected=anchor["textSHA256"] as? String,
                  let event=eventsByParent[parent],
                  event["session"] as? String==session,event["source_id"] as? String==anchor["source"] as? String,
                  event["epoch"] as? String==anchor["epoch"] as? String,
                  let words=(event["coarse_source_word_spans"] ?? event["word_spans"]) as? [[String:Any]] else{continue}
            let sourceWords=words.filter{($0["start"] as? Double ?? -.infinity)>=lo-1e-6 && ($0["end"] as? Double ?? .infinity)<=hi+1e-6}
            let sourceText=sourceWords.compactMap{$0["text"] as? String}.joined()
            let sourceHash=digest(Data(sourceText.utf8))
            var sourceAnchor=anchor;sourceAnchor["textSHA256"]=sourceHash
            guard !sourceText.isEmpty,anchorTextMatches(anchor:sourceAnchor,event:event) else{continue}
            if sourceHash==expected {continue}
            let runs=event["speaker_runs"] as? [[String:Any]] ?? []
            let parts=runs.isEmpty ? [event]:runs
            var clean="",cursor=lo,valid=true
            for part in parts where (part["start"] as? Double ?? .infinity)<hi && (part["end"] as? Double ?? -.infinity)>lo {
                guard let start=part["start"] as? Double,let end=part["end"] as? Double,
                      abs(start-cursor)<1e-6,end<=hi+1e-6 else{valid=false;break}
                let id=runs.isEmpty ? parent:TranscriptTimeline.runID(parent:parent,run:part)
                let rawText=words.filter{($0["start"] as? Double ?? -.infinity)>=start-1e-6 && ($0["end"] as? Double ?? .infinity)<=end+1e-6}.compactMap{$0["text"] as? String}.joined()
                guard let row=byID[id],row["original_text_sha256"] as? String==digest(Data(rawText.utf8)),
                      let text=row["text"] as? String,!text.isEmpty else{valid=false;break}
                clean+=text;cursor=end
            }
            if valid,abs(cursor-hi)<1e-6,digest(Data(clean.utf8))==expected {
                anchors[index]["textSHA256"]=sourceHash;changed=true
            }
        }
        guard changed else{return data}
        snapshot["runAnchors"]=anchors
        return try JSONSerialization.data(withJSONObject:snapshot,options:[.sortedKeys])
    }

    private static func anchorTextMatches(anchor:[String:Any],event:[String:Any])->Bool {
        guard let start=anchor["start"] as? Double,let end=anchor["end"] as? Double,
              let expected=anchor["textSHA256"] as? String,
              let raw=(event["coarse_source_word_spans"] ?? event["word_spans"]) as? [[String:Any]],!raw.isEmpty,raw.count<=1000 else{return false}
        var words:[(Double,Double,String)]=[],cursor=event["start"] as? Double ?? 0
        for word in raw {
            guard let lo=word["start"] as? Double,let hi=word["end"] as? Double,
                  lo.isFinite,hi.isFinite,lo>=cursor,hi>lo,
                  let text=word["text"] as? String,!text.isEmpty else{return false}
            words.append((lo,hi,text));cursor=hi
        }
        guard let first=words.firstIndex(where:{abs($0.0-start)<1e-6}) else{return false}
        var text=""
        for word in words[first...] {
            if word.1>end+1e-6 {break}
            text+=word.2
            if abs(word.1-end)<1e-6 {return digest(Data(text.utf8))==expected}
        }
        return false
    }

    private static func scope(_ event:[String:Any])throws->SessionSpeakerKey {
        guard let session=event["session"] as? String,!session.isEmpty,session.count<=160,
              let source=event["source_id"] as? String,isTranscriptAudioTrack(source),source.count<=64,
              let epoch=event["epoch"] as? String,!epoch.isEmpty,epoch.count<=160 else{throw SpeakerRefinementArtifactError.invalidArtifact}
        return SessionSpeakerKey(session:session,source:source,epoch:epoch,identity:"scope")
    }
    private static func speakerJSONEqual(_ lhs:[String:Any],_ rhs:[String:Any])throws->Bool {
        try jsonData(lhs)==jsonData(rhs)
    }
    private static func withoutSpeaker(_ run:[String:Any])throws->Data {
        var copy=run;copy.removeValue(forKey:"speaker")
        return try jsonData(copy)
    }
    private static func knownEvidence(_ events:[[String:Any]])->Set<SessionSpeakerKey> {
        var result=Set<SessionSpeakerKey>()
        func isAnonymous(_ event:[String:Any])->Bool {
            guard let speaker=event["speaker"] as? [String:Any],speaker["basis"] as? String=="anonymous_cluster",
                  speaker["contextual_fill"] as? Bool != true,
                  let raw=speaker["cluster_id"] as? NSNumber,CFGetTypeID(raw) != CFBooleanGetTypeID(),
                  let slot=speaker["cluster_id"] as? Int,(0..<8).contains(slot) else{return false}
            return true
        }
        for event in events {
            if isAnonymous(event),
               let key=SessionSpeakerKey.from(event) {result.insert(key)}
            guard let rows=event["speaker_runs"] as? [[String:Any]] else{continue}
            for row in rows {
                var scoped=row
                for field in ["session","source_id","epoch"] {
                    if let supplied=row[field],String(describing:supplied) != String(describing:event[field] ?? "") {scoped.removeValue(forKey:"speaker");continue}
                    scoped[field]=event[field]
                }
                if isAnonymous(row),
                   let key=SessionSpeakerKey.from(scoped) {result.insert(key)}
            }
        }
        return result
    }
    private static func validateSpeaker(_ output:[String:Any],prior:[String:Any],event:[String:Any],evidence:Set<SessionSpeakerKey>,allowAnonymousRemap:Bool,acoustic:Bool=false,echoReferences:[String:(Double,Double)]=[:])throws {
        let oldBasis=prior["basis"] as? String
        guard oldBasis != nil else{throw SpeakerRefinementArtifactError.invalidArtifact}
        if acoustic,(["unknown","anonymous_cluster","meeting_reconciliation","channel"].contains(oldBasis!) || (oldBasis=="multiple" && output["solo_verified"] as? Bool==true)) {
            if try speakerJSONEqual(output,prior) {return}
            if output["basis"] as? String=="unknown",output["reason"] as? String=="acoustic_unresolved",Set(output.keys)==Set(["basis","reason"]) {return}
            guard output["basis"] as? String=="meeting_reconciliation",output["acoustic_verified"] as? Bool==true,
                  Set(output.keys).isSubset(of:Set(["basis","source_id","epoch","identity_key","acoustic_verified","echo_of","solo_verified","slot_continuity"])) else{throw SpeakerRefinementArtifactError.invalidArtifact}
            if output["slot_continuity"] != nil {
                guard output["slot_continuity"] as? Bool==true,oldBasis=="anonymous_cluster" || oldBasis=="meeting_reconciliation",
                      let lo=event["start"] as? Double,let hi=event["end"] as? Double,hi>lo,hi-lo<1.5 else{throw SpeakerRefinementArtifactError.invalidArtifact}
            }
            var scoped=event;scoped["speaker"]=output
            guard let key=SessionSpeakerKey.from(scoped),evidence.contains(key) else{throw SpeakerRefinementArtifactError.unknownSlot}
            if let echo=output["echo_of"] {
                guard audioSourceCoreID(event["source_id"] as? String ?? "")=="mic",let id=echo as? String,
                      let range=echoReferences[id],let lo=event["start"] as? Double,let hi=event["end"] as? Double,hi>lo,
                      max(0,min(hi,range.1)-max(lo,range.0))/(hi-lo)>=0.85 else{throw SpeakerRefinementArtifactError.invalidArtifact}
            }
            return
        }
        if oldBasis != "unknown" && !(allowAnonymousRemap && oldBasis=="anonymous_cluster") {
            guard try speakerJSONEqual(output,prior) else{throw SpeakerRefinementArtifactError.unsupportedSpeakerChange}
            return
        }
        if try speakerJSONEqual(output,prior) {return}
        guard output["basis"] as? String=="anonymous_cluster",
              Set(output.keys)==Set(["basis","cluster_id","source_id","epoch"]) else{throw SpeakerRefinementArtifactError.unsupportedSpeakerChange}
        guard let rawSlot=output["cluster_id"] as? NSNumber,CFGetTypeID(rawSlot) != CFBooleanGetTypeID(),
              let slot=output["cluster_id"] as? Int,(0..<8).contains(slot) else{throw SpeakerRefinementArtifactError.invalidArtifact}
        var scoped=event;scoped["speaker"]=output
        guard let key=SessionSpeakerKey.from(scoped),key.session==event["session"] as? String,
              key.source==event["source_id"] as? String,key.epoch==event["epoch"] as? String else{throw SpeakerRefinementArtifactError.invalidArtifact}
        if oldBasis=="anonymous_cluster" {
            var priorScoped=event;priorScoped["speaker"]=prior
            guard let priorKey=SessionSpeakerKey.from(priorScoped),priorKey.session==key.session,
                  priorKey.source==key.source,priorKey.epoch==key.epoch else{throw SpeakerRefinementArtifactError.invalidArtifact}
        }
        guard evidence.contains(key) else{throw SpeakerRefinementArtifactError.unknownSlot}
    }
    private static func validateRunLayout(_ rows:[[String:Any]],event:[String:Any])throws {
        guard let parentStart=event["start"] as? Double,let parentEnd=event["end"] as? Double,
              parentStart.isFinite,parentEnd.isFinite,parentStart>=0,parentEnd>parentStart,parentEnd<1e8,
              let text=event["text"] as? String,!text.isEmpty else{throw SpeakerRefinementArtifactError.invalidArtifact}
        var cursor=parentStart,joined=""
        for row in rows {
            guard let start=row["start"] as? Double,let end=row["end"] as? Double,
                  start.isFinite,end.isFinite,start>=cursor-0.001,end>start,end<=parentEnd+0.001,
                  let body=row["text"] as? String else{throw SpeakerRefinementArtifactError.invalidArtifact}
            cursor=end;joined+=body
        }
        guard joined==text else{throw SpeakerRefinementArtifactError.invalidArtifact}
    }

    static func validateApply(object:[String:Any],events:[[String:Any]],sourceHashes:[String:String],directory:URL,cacheID:String)throws->[[String:Any]] {
        _=try checkedDirectory(directory,cacheID:cacheID)
        let acoustic=object["method"] as? String==MeetingAcousticRefinement.method && object["model"] as? String==MeetingAcousticRefinement.model
        let currentSnapshot=try snapshotSHA256(directory:directory,cacheID:cacheID,sourceHashes:sourceHashes,includeAuxiliaryAudio:acoustic)
        guard events.count<=maximumEventCount,validCacheID(cacheID),
              object["schema"] as? Int==1,object["cache_id"] as? String==cacheID,
              let session=object["session"] as? String,!session.isEmpty,session.count<=160,
              events.allSatisfy({$0["session"] as? String==session}),
              object["source_sha256"] as? [String:String]==sourceHashes,
              let snapshot=object["snapshot_sha256"] as? String,validDigest(snapshot),snapshot==currentSnapshot,
              let records=object["records"] as? [[String:Any]],records.count<=maximumEventCount else{throw SpeakerRefinementArtifactError.invalidArtifact}
        let allowAnonymousRemap:Bool
        if object["method"] as? String==method,object["model"] as? String==model {allowAnonymousRemap=false}
        else if object["method"] as? String==offlineMethod,object["model"] as? String==offlineModel {allowAnonymousRemap=true}
        else if acoustic {allowAnonymousRemap=true}
        else {throw SpeakerRefinementArtifactError.invalidArtifact}
        _=try validateSourceHashes(sourceHashes)
        var originals:[String:[String:Any]]=[:]
        for event in events {
            guard let id=event["segment_id"] as? String,!id.isEmpty,originals[id]==nil else{throw SpeakerRefinementArtifactError.invalidArtifact}
            originals[id]=event
        }
        let evidence=knownEvidence(events)
        var echoReferences:[String:(Double,Double)]=[:]
        for event in events where audioSourceCoreID(event["source_id"] as? String ?? "") != "mic" {
            guard let parent=event["segment_id"] as? String else{continue}
            let runs=event["speaker_runs"] as? [[String:Any]] ?? []
            for row in runs.isEmpty ? [event]:runs {
                if let lo=row["start"] as? Double,let hi=row["end"] as? Double,hi>lo {echoReferences[runs.isEmpty ? parent:TranscriptTimeline.runID(parent:parent,run:row)]=(lo,hi)}
            }
        }
        let protected=try protectedIDs(directory:directory,session:session,events:events)
        var replacements:[String:[String:Any]]=[:]
        for record in records {
            guard Set(record.keys)==Set(["segment_id","original_sha256","speaker","speaker_runs"]),
                  let id=record["segment_id"] as? String,!id.isEmpty,id.count<=256,
                  replacements[id]==nil,let original=originals[id],
                  original["final"] as? Bool==true,original["end_time_known"] as? Bool==true,
                  let source=original["source_id"] as? String,isTranscriptAudioTrack(source),
                  sourceHashes[source+"-transcript.jsonl"] != nil,
                  let text=original["text"] as? String,!text.isEmpty,text.utf8.count<=2*1024*1024,
                  let originalHash=record["original_sha256"] as? String,validDigest(originalHash),
                  let beforeSpeaker=original["speaker"] as? [String:Any],
                  let afterSpeaker=record["speaker"] as? [String:Any] else{throw SpeakerRefinementArtifactError.eventChanged}
            let actualOriginalHash=try originalEventSHA256(original)
            guard originalHash==actualOriginalHash else{throw SpeakerRefinementArtifactError.eventChanged}
            if !acoustic || original["epoch"] as? String != nil {_=try scope(original)}
            let parentProtected=protected.contains(id)
            if !parentProtected {try validateSpeaker(afterSpeaker,prior:beforeSpeaker,event:original,evidence:evidence,allowAnonymousRemap:allowAnonymousRemap,acoustic:acoustic,echoReferences:echoReferences)}

            let originalRuns=original["speaker_runs"] as? [[String:Any]] ?? []
            let proposedRuns=record["speaker_runs"] as? [[String:Any]]
            guard let proposedRuns=proposedRuns,proposedRuns.count==originalRuns.count else{throw SpeakerRefinementArtifactError.eventChanged}
            if !originalRuns.isEmpty {try validateRunLayout(originalRuns,event:original)}
            var patchedRuns:[[String:Any]]=[]
            for (old,new) in zip(originalRuns,proposedRuns) {
                guard let oldSpeaker=old["speaker"] as? [String:Any],let newSpeaker=new["speaker"] as? [String:Any],
                      try withoutSpeaker(old)==withoutSpeaker(new) else{throw SpeakerRefinementArtifactError.eventChanged}
                var contextual=original
                contextual["start"]=old["start"];contextual["end"]=old["end"]
                for field in ["session","source_id","epoch"] {
                    if let supplied=old[field],String(describing:supplied) != String(describing:original[field] ?? "") {throw SpeakerRefinementArtifactError.invalidArtifact}
                    contextual[field]=original[field]
                }
                let runProtected=parentProtected || protected.contains(TranscriptTimeline.runID(parent:id,run:old))
                if !runProtected {try validateSpeaker(newSpeaker,prior:oldSpeaker,event:contextual,evidence:evidence,allowAnonymousRemap:allowAnonymousRemap,acoustic:acoustic,echoReferences:echoReferences)}
                var changed=old;changed["speaker"]=runProtected ? oldSpeaker:newSpeaker;patchedRuns.append(changed)
            }
            var replacement=original;replacement["speaker"]=parentProtected ? beforeSpeaker:afterSpeaker
            if !originalRuns.isEmpty {replacement["speaker_runs"]=patchedRuns}
            if acoustic {replacement["acoustic_refinement_applied"]=true}
            replacements[id]=replacement
        }
        return events.map{replacements[$0["segment_id"] as? String ?? ""] ?? $0}
    }

    private static func attachWarning(_ message:String,to events:[[String:Any]])->[[String:Any]] {
        guard !events.isEmpty else{return events}
        var result=events;result[0]["speaker_refinement_warning"]=message;return result
    }
    static func loadApply(events:[[String:Any]],sourceHashes:[String:String],directory:URL,cacheID:String)->[[String:Any]] {
        do {
            let directory=try checkedDirectory(directory,cacheID:cacheID)
            let file=directory.appendingPathComponent(filename,isDirectory:false)
            guard FileManager.default.fileExists(atPath:file.path) || isSymlinkEntry(file) else{return events}
            let attrs=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey])
            guard attrs.isSymbolicLink != true,attrs.isRegularFile==true else{throw SpeakerRefinementArtifactError.invalidPath}
            guard let size=attrs.fileSize,size>=0,size<=maximumBytes else{throw SpeakerRefinementArtifactError.fileTooLarge}
            let data=try Data(contentsOf:file,options:[.mappedIfSafe])
            guard data.count<=maximumBytes,let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw SpeakerRefinementArtifactError.invalidArtifact}
            return try validateApply(object:object,events:events,sourceHashes:sourceHashes,directory:directory,cacheID:cacheID)
        } catch {return attachWarning("人物修正已失效，已恢复原始识别；原音和文字保留",to:events)}
    }

    static func prepareValidated(data:Data,events:[[String:Any]],sourceHashes:[String:String],directory:URL,cacheID:String)throws->Prepared {
        guard data.count<=maximumBytes else{throw SpeakerRefinementArtifactError.fileTooLarge}
        let directory=try checkedDirectory(directory,cacheID:cacheID)
        guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw SpeakerRefinementArtifactError.invalidArtifact}
        let projected=try validateApply(object:object,events:events,sourceHashes:sourceHashes,directory:directory,cacheID:cacheID)
        let target=directory.appendingPathComponent(filename,isDirectory:false)
        if FileManager.default.fileExists(atPath:target.path) || isSymlinkEntry(target) {
            let values=try target.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey])
            guard values.isSymbolicLink != true,values.isRegularFile==true else{throw SpeakerRefinementArtifactError.invalidPath}
        }
        return Prepared(target:target,directory:directory,cacheID:cacheID,data:data,projectedEvents:projected)
    }

    /// Commit a previously validated candidate. This deliberately performs no
    /// transcript, manifest or model hashing so callers may place it inside a
    /// short cancellation/CAS gate.
    static func writePrepared(_ prepared:Prepared)throws {
        let directory=try checkedDirectory(prepared.directory,cacheID:prepared.cacheID)
        let expected=directory.appendingPathComponent(filename,isDirectory:false)
        guard prepared.target==expected else{throw SpeakerRefinementArtifactError.invalidPath}
        if FileManager.default.fileExists(atPath:expected.path) || isSymlinkEntry(expected) {
            let values=try expected.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey])
            guard values.isSymbolicLink != true,values.isRegularFile==true else{throw SpeakerRefinementArtifactError.invalidPath}
        }
        try prepared.data.write(to:expected,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:expected.path)
    }

    static func writeValidated(data:Data,events:[[String:Any]],sourceHashes:[String:String],directory:URL,cacheID:String)throws {
        let prepared=try prepareValidated(data:data,events:events,sourceHashes:sourceHashes,directory:directory,cacheID:cacheID)
        try writePrepared(prepared)
    }
}
