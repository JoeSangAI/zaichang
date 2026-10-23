import Foundation
import CryptoKit
import CoreFoundation

enum MeetingCoarseRefinementError:Error,Equatable {
    case invalidScope
    case invalidArtifact
    case sourceChanged
    case snapshotChanged
    case eventChanged
    case unknownSpeaker
    case invalidLayout
    case fileTooLarge
}

/// Reversible, hash-bound meeting cleanup. Provider JSONL and saved PCM are
/// never changed; this artifact only projects display text and local speakers.
enum MeetingCoarseRefinement {
    static let filename="automatic-coarse-refinement.json"
    static let method="audio_coarse_v1"
    static let maximumBytes=8*1024*1024
    private static let maximumRecords=50_000
    private static let maximumTextBytes=256*1024

    struct Projection {
        let events:[[String:Any]]
        let artifact:[String:Any]
    }
    struct RequestUnit:Codable {
        let unit_id:String
        let original_text_sha256:String
        let text:String
        let start:Double
        let end:Double
        let source_id:String
        let manual:Bool
        let speaker_locked:Bool
        let approximate_window:Bool
        let speaker_key:SessionSpeakerKey?
        let speaker_name:String?
        var unitJSON:[String:Any] {get throws {try JSONSerialization.jsonObject(with:JSONEncoder().encode(self)) as? [String:Any] ?? [:]}}
    }
    struct RosterEntry:Codable {
        let key:SessionSpeakerKey
        let name:String?
    }
    struct RequestPayload:Codable {
        let schema:Int
        let method:String
        let cache_id:String
        let session:String
        let source_sha256:String
        let snapshot_sha256:String
        let roster:[RosterEntry]
        let units:[RequestUnit]
        /// True when the journal contains saved audio beyond the last durable
        /// ASR cursor. The model may process only the committed prefix; the UI
        /// must keep this result partial until that tail is transcribed.
        let incomplete_audio:Bool
        var object:[String:Any] {get throws {try JSONSerialization.jsonObject(with:JSONEncoder().encode(self)) as? [String:Any] ?? [:]}}
    }

    private struct Unit {
        let id:String
        let parent:String
        let runIndex:Int?
        let text:String
        let start:Double
        let end:Double
        let speaker:[String:Any]?
        let approximate:Bool
    }
    private struct ManualLabels {
        let speakers:[SessionSpeakerKey:String]
        let segments:[String:String]
        let sentenceIDs:Set<String>
        let anchors:[[String:Any]]
    }
    private struct VerifiedAudioCoverage {
        let ends:[String:Double]
        let incompleteTracks:Set<String>
    }

    private static func digest(_ data:Data)->String {
        SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    }
    private static func validDigest(_ value:String)->Bool {
        value.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil
    }
    private static func validCacheID(_ value:String)->Bool {
        UUID(uuidString:value) != nil && value.count<=64
    }
    private static func jsonData(_ object:Any)throws->Data {
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.fragmentsAllowed])
    }
    static func transcriptSnapshotSHA256(events:[[String:Any]])throws->String {
        digest(try jsonData(events))
    }
    private static func decodeKey(_ value:Any,session:String)throws->SessionSpeakerKey {
        guard let object=value as? [String:Any],
              Set(object.keys)==Set(["session","source","epoch","identity"]),
              let data=try? JSONSerialization.data(withJSONObject:object),
              let key=try? JSONDecoder().decode(SessionSpeakerKey.self,from:data),
              key.session==session,isTranscriptAudioTrack(key.source),
              !key.epoch.isEmpty,key.epoch.count<=160,
              let slot=Int(key.identity.replacingOccurrences(of:"slot:",with:"")),
              key.identity=="slot:\(slot)",(0..<8).contains(slot) else {
            throw MeetingCoarseRefinementError.invalidArtifact
        }
        return key
    }
    private static func keyForSpeaker(_ speaker:[String:Any]?,event:[String:Any])->SessionSpeakerKey? {
        guard let speaker=speaker else{return nil}
        var scoped=event;scoped["speaker"]=speaker
        return SessionSpeakerKey.from(scoped)
    }
    private static func acousticEpoch(_ event:[String:Any])throws->String? {
        guard let raw=event["epoch"] else{return nil}
        if raw is NSNull{return nil}
        guard let value=raw as? String else{throw MeetingCoarseRefinementError.invalidLayout}
        return value.isEmpty ? nil:value
    }
    private static func units(events:[[String:Any]],session:String,sourceAudioEnds:[String:Double],
                              strictAudioTracks:Set<String>=[])throws->([String:Unit],Set<SessionSpeakerKey>) {
        guard events.count<=maximumRecords else{throw MeetingCoarseRefinementError.invalidArtifact}
        struct StartRow {let source:String;let epoch:String?;let start:Double}
        var starts:[StartRow]=[]
        for event in events where !(event["quality_flags"] as? [String] ?? []).contains("archive_text_only") {
            guard event["session"] as? String==session,
                  let source=event["source_id"] as? String,isTranscriptAudioTrack(source),
                  let start=event["start"] as? Double,start.isFinite,start>=0,start<1e8 else{continue}
            if strictAudioTracks.contains(source),let safeEnd=sourceAudioEnds[source],start>=safeEnd {continue}
            starts.append(StartRow(source:source,epoch:try acousticEpoch(event),start:start))
        }
        var units:[String:Unit]=[:],keys=Set<SessionSpeakerKey>(),parents=Set<String>()
        for event in events where !(event["quality_flags"] as? [String] ?? []).contains("archive_text_only") {
            guard event["session"] as? String==session else{throw MeetingCoarseRefinementError.invalidScope}
            guard let source=event["source_id"] as? String,isTranscriptAudioTrack(source),
                  let start=event["start"] as? Double,start.isFinite,start>=0,start<1e8,
                  let text=event["text"] as? String,!text.isEmpty,text.utf8.count<=maximumTextBytes else{continue}
            guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{continue}
            let epoch=try acousticEpoch(event)
            let reliable=event["final"] as? Bool==true && event["end_time_known"] as? Bool==true
            let end:Double,approximate:Bool
            if reliable {
                guard let supplied=event["end"] as? Double,supplied.isFinite,supplied>start,supplied<1e8 else{throw MeetingCoarseRefinementError.invalidLayout}
                // A failed writer can leave more PCM on disk than the durable
                // transcript cursor covers. Do not send transcript events
                // beyond that verified prefix to the refinement model.
                if strictAudioTracks.contains(source),let safeEnd=sourceAudioEnds[source],supplied>safeEnd+0.000001 {continue}
                end=supplied;approximate=false
            } else {
                // Keep known epochs isolated. For a missing-epoch transcript,
                // use the nearest later event from the same audio source.
                let next=starts.filter{$0.source==source && (epoch==nil || $0.epoch==epoch) && $0.start>start &&
                    (!strictAudioTracks.contains(source) || $0.start<=(sourceAudioEnds[source] ?? .infinity))}.map(\.start).min()
                // The last approximate ASR event can still be an unfinished
                // hypothesis at a failed writer's durable cursor. Keep it as
                // original text until a later event closes its time window.
                if strictAudioTracks.contains(source),next==nil {continue}
                guard let candidate=[next,sourceAudioEnds[source]].compactMap({$0}).min(),candidate.isFinite,candidate>start,candidate<1e8 else{continue}
                end=min(candidate,start+10);approximate=true
            }
            guard end>start else{continue}
            guard let parent=event["segment_id"] as? String,!parent.isEmpty,parent.count<=256,
                  parents.insert(parent).inserted else{throw MeetingCoarseRefinementError.invalidLayout}
            let runs=event["speaker_runs"] as? [[String:Any]] ?? []
            if approximate && !runs.isEmpty {
                let fits=runs.allSatisfy { run in
                    guard let lo=run["start"] as? Double,let hi=run["end"] as? Double,
                          lo.isFinite,hi.isFinite else{return false}
                    return lo>=start-0.001 && hi<=end+0.001 && hi-lo<=10
                }
                if !fits {continue}
            }
            if runs.isEmpty {
                guard units[parent]==nil else{throw MeetingCoarseRefinementError.invalidArtifact}
                units[parent]=Unit(id:parent,parent:parent,runIndex:nil,text:text,start:start,end:end,speaker:event["speaker"] as? [String:Any],approximate:approximate)
                if let key=keyForSpeaker(event["speaker"] as? [String:Any],event:event){keys.insert(key)}
                continue
            }
            var cursor=start,joined=""
            for (index,run) in runs.enumerated() {
                guard let lo=run["start"] as? Double,let hi=run["end"] as? Double,
                      lo.isFinite,hi.isFinite,lo>=cursor-0.001,hi>lo,hi<=end+0.001,
                      let body=run["text"] as? String,!body.isEmpty,body.utf8.count<=maximumTextBytes else{throw MeetingCoarseRefinementError.invalidLayout}
                cursor=hi;joined+=body
                // Keep empty acoustic slices in the untouched source event,
                // but never ask a model to correct or assign them.
                guard !body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{continue}
                let id=TranscriptTimeline.runID(parent:parent,run:run)
                guard units[id]==nil else{throw MeetingCoarseRefinementError.invalidArtifact}
                units[id]=Unit(id:id,parent:parent,runIndex:index,text:body,start:lo,end:hi,speaker:run["speaker"] as? [String:Any],approximate:approximate)
                if let key=keyForSpeaker(run["speaker"] as? [String:Any],event:event){keys.insert(key)}
            }
            guard joined==text else{throw MeetingCoarseRefinementError.invalidLayout}
            if let key=keyForSpeaker(event["speaker"] as? [String:Any],event:event){keys.insert(key)}
        }
        return (units,keys)
    }
    private static func manualSpeakerLabels(directory:URL,session:String)throws->ManualLabels {
        let file=directory.appendingPathComponent("session-names.json",isDirectory:false)
        guard FileManager.default.fileExists(atPath:file.path) else{return ManualLabels(speakers:[:],segments:[:],sentenceIDs:[],anchors:[])}
        let attrs=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey])
        guard attrs.isSymbolicLink != true,attrs.isRegularFile==true,
              let size=attrs.fileSize,size>=0,size<=4*1024*1024 else{throw MeetingCoarseRefinementError.invalidScope}
        let data=try Data(contentsOf:file,options:[.mappedIfSafe])
        guard let snapshot=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              [1,2].contains(snapshot["schema"] as? Int ?? 0),snapshot["session"] as? String==session else {
            throw MeetingCoarseRefinementError.invalidScope
        }
        let rows=snapshot["speakers"] as? [[String:Any]] ?? []
        guard rows.count<=128 else{throw MeetingCoarseRefinementError.invalidArtifact}
        var result:[SessionSpeakerKey:String]=[:]
        for row in rows {
            guard let raw=row["key"],let name=row["name"] as? String,!name.isEmpty,name.count<=80 else{throw MeetingCoarseRefinementError.invalidArtifact}
            result[try decodeKey(raw,session:session)]=name
        }
        let sentenceNames=snapshot["sentences"] as? [String:String] ?? [:]
        var segments=sentenceNames
        if let sentences=snapshot["sentences"] as? [String:String] {
            guard sentences.count<=4096 else{throw MeetingCoarseRefinementError.invalidArtifact}
        } else if snapshot["sentences"] != nil {throw MeetingCoarseRefinementError.invalidArtifact}
        if let assignments=snapshot["assignments"] as? [[String:Any]] {
            guard assignments.count<=4096 else{throw MeetingCoarseRefinementError.invalidArtifact}
            for assignment in assignments {
                guard let id=assignment["id"] as? String,!id.isEmpty,let raw=assignment["key"] else{throw MeetingCoarseRefinementError.invalidArtifact}
                let key=try decodeKey(raw,session:session)
                if let name=result[key] {segments[id]=name}
            }
        } else if snapshot["assignments"] != nil {throw MeetingCoarseRefinementError.invalidArtifact}
        return ManualLabels(speakers:result,segments:segments,sentenceIDs:Set(sentenceNames.keys),anchors:snapshot["runAnchors"] as? [[String:Any]] ?? [])
    }
    private static func protectedUnits(directory:URL,session:String,events:[[String:Any]],units:[String:Unit],manualSentenceIDs:Set<String>)throws->Set<String> {
        var result=try SpeakerRefinementArtifact.protectedIDs(directory:directory,session:session,events:events)
        // A sentence-level name is a deliberate whole-parent annotation and
        // must protect every child run. A run anchor/assignment only protects
        // its own run; never promote that protection to neighboring runs.
        for unit in units.values where manualSentenceIDs.contains(unit.parent) {result.insert(unit.id)}
        for unit in units.values where unit.runIndex==nil && result.contains(unit.parent) {result.insert(unit.id)}
        return result
    }
    // Naming a person protects identity, not their spelling or disfluencies.
    // Keep text only where a human boundary falls inside a cleanup unit: without
    // word-level alignment we cannot safely move that boundary through a rewrite.
    private static func textProtectedUnits(labels:ManualLabels,units:[String:Unit],session:String)->Set<String> {
        var result=Set<String>()
        for anchor in labels.anchors where anchor["session"] as? String==session {
            guard let parent=anchor["parent"] as? String,let start=anchor["start"] as? Double,
                  let end=anchor["end"] as? Double else{continue}
            for unit in units.values where unit.parent==parent && unit.start<end && unit.end>start {
                if start>unit.start+1e-6 || end<unit.end-1e-6 {result.insert(unit.id)}
            }
        }
        return result
    }
    private static func validateNewText(_ proposed:String,original:String)throws {
        let text=proposed.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty,text.utf8.count<=maximumTextBytes,
              !text.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)}) else {
            throw MeetingCoarseRefinementError.invalidArtifact
        }
        let oldCount=original.unicodeScalars.filter{!CharacterSet.whitespacesAndNewlines.contains($0)}.count
        let newCount=text.unicodeScalars.filter{!CharacterSet.whitespacesAndNewlines.contains($0)}.count
        guard newCount>0,oldCount<=4 || Double(newCount)>=Double(oldCount)*0.45 else {
            throw MeetingCoarseRefinementError.invalidArtifact
        }
    }
    private static func targetSpeaker(_ key:SessionSpeakerKey,event:[String:Any])->[String:Any] {
        var speaker:[String:Any]=["basis":"meeting_reconciliation",
            "source_id":event["source_id"] as? String ?? key.source,
            "identity_key":["session":key.session,"source":key.source,"epoch":key.epoch,"identity":key.identity]]
        // Keep the roster key's existing epoch inside identity_key, but never
        // invent an event-level acoustic epoch when the transcript lacks one.
        if let epoch=event["epoch"] as? String,!epoch.isEmpty {speaker["epoch"]=epoch}
        return speaker
    }
    private static func validateInput(events:[[String:Any]],session:String,cacheID:String,sourceSHA256:String,snapshotSHA256:String)throws {
        guard validCacheID(cacheID),!session.isEmpty,session.count<=160,
              validDigest(sourceSHA256),validDigest(snapshotSHA256) else {
            throw MeetingCoarseRefinementError.invalidScope
        }
    }

    private static func fileDigest(_ file:URL,limit:Int)throws->String {
        guard FileManager.default.fileExists(atPath:file.path) else{return ""}
        let attrs=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard attrs.isRegularFile==true,attrs.isSymbolicLink != true,let size=attrs.fileSize,size>=0,size<=limit else {
            throw MeetingCoarseRefinementError.invalidScope
        }
        return digest(try Data(contentsOf:file,options:[.mappedIfSafe]))
    }
    static func sourceSHA256(transcriptHashes:[String:String])throws->String {
        guard !transcriptHashes.isEmpty,transcriptHashes.count<=32,transcriptHashes.allSatisfy({
            $0.key.hasSuffix("-transcript.jsonl") && validDigest($0.value)
        }) else{throw MeetingCoarseRefinementError.invalidArtifact}
        return digest(try jsonData(transcriptHashes))
    }
    private static func verifiedAudioEnds(directory:URL,session:String,events:[[String:Any]])throws->VerifiedAudioCoverage {
        let metadataData=try Data(contentsOf:directory.appendingPathComponent("meeting.json",isDirectory:false),options:[.mappedIfSafe])
        guard metadataData.count<=64*1024,
              let metadata=try JSONSerialization.jsonObject(with:metadataData) as? [String:Any],
              metadata["session"] as? String==session,
              let captureOrigin=metadata["capture_origin_uptime"] as? Double,captureOrigin.isFinite else{throw MeetingCoarseRefinementError.invalidScope}
        let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
        let eventTracks=Set(events.compactMap { event -> String? in
            guard event["session"] as? String==session,
                  !(event["quality_flags"] as? [String] ?? []).contains("archive_text_only"),
                  let source=event["source_id"] as? String,isTranscriptAudioTrack(source) else{return nil}
            return source
        })
        var result:[String:Double]=[:],incompleteTracks=Set<String>()
        for file in files where file.lastPathComponent.hasSuffix("-manifest.json") {
            let track=String(file.lastPathComponent.dropLast("-manifest.json".count))
            guard isTranscriptAudioTrack(track) else{continue}
            let attrs=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard attrs.isRegularFile==true,attrs.isSymbolicLink != true,
                  let size=attrs.fileSize,size>=0,size<=512*1024 else{throw MeetingCoarseRefinementError.invalidScope}
            let data=try Data(contentsOf:file,options:[.mappedIfSafe])
            guard let manifest=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  manifest["schema"] as? Int==1,manifest["track"] as? String==track,
                  manifest["format"] as? String=="pcm_s16le",manifest["sample_rate"] as? Int==16000,
                  manifest["channels"] as? Int==1,
                  let written=manifest["written_bytes"] as? Int,written>=0,written%2==0,written<=512*1024*1024,
                  let committed=manifest["asr_committed_bytes"] as? Int,committed>=0,committed%2==0,committed<=written,
                  let ended=manifest["ended"] as? Bool,
                  let chunks=manifest["chunks"] as? [[String:Any]],chunks.count<=10_000 else{throw MeetingCoarseRefinementError.invalidScope}
            let processingError:String?
            if let value=manifest["processing_error"],!(value is NSNull) {
                guard let code=value as? String,!code.isEmpty,code.count<=128,
                      !code.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{throw MeetingCoarseRefinementError.invalidScope}
                processingError=code
            } else {processingError=nil}
            let rawOrigin=manifest["origin_uptime"]
            if rawOrigin is NSNull {
                let offered=manifest["offered_bytes"] as? Int
                let emptyError=manifest["error"] == nil || manifest["error"] is NSNull
                guard written==0,committed==0,offered==0,chunks.isEmpty,emptyError,
                      !eventTracks.contains(track) else{throw MeetingCoarseRefinementError.invalidScope}
                continue
            }
            // Echo processing can emit a short microphone pre-roll before the
            // first raw hardware frame that anchors the meeting clock. Preserve
            // that signed offset; rejecting it strands the entire refinement.
            let offset=(rawOrigin as? Double).map{$0-captureOrigin}
            guard let origin=rawOrigin as? Double,origin.isFinite,
                  let offset,offset.isFinite,offset >= -0.25,offset<=86400,
                  !eventTracks.contains(track) || written>0 else{throw MeetingCoarseRefinementError.invalidScope}
            let error=manifest["error"] as? String
            let isWriterBackpressure=error=="cache_writer_backpressure"
            let errorAbsent=manifest["error"] == nil || manifest["error"] is NSNull
            let allowedJournalState=errorAbsent || isWriterBackpressure || (error=="cache_unclean_shutdown" && committed==written)
            guard allowedJournalState,
                  (isWriterBackpressure || processingError != nil || (ended && committed<written) || committed==written),
                  (ended || committed==written || isWriterBackpressure || processingError != nil) else{throw MeetingCoarseRefinementError.invalidScope}
            // Transcript positions are relative to the capture origin, while
            // journal origins use monotonic system uptime.
            // A past capture cutoff remains in the original manifest. It does
            // not mean already saved and fully transcribed PCM is still pending.
            let hasIncompleteCoverage=processingError != nil || committed<written
            let coveredBytes=hasIncompleteCoverage ? committed:written
            let end=offset+Double(coveredBytes)/32000
            guard end.isFinite,end>=0 else{throw MeetingCoarseRefinementError.invalidScope}
            result[track]=end
            if hasIncompleteCoverage {incompleteTracks.insert(track)}
        }
        guard eventTracks.isSubset(of:Set(result.keys)) else{throw MeetingCoarseRefinementError.invalidScope}
        return VerifiedAudioCoverage(ends:result,incompleteTracks:incompleteTracks)
    }
    static func snapshotSHA256(directory:URL,cacheID:String,session:String,
                               events:[[String:Any]],transcriptHashes:[String:String])throws->String {
        guard validCacheID(cacheID),directory.lastPathComponent==cacheID,
              events.allSatisfy({$0["session"] as? String==session}) else{throw MeetingCoarseRefinementError.invalidScope}
        let legacy=try SpeakerRefinementArtifact.snapshotSHA256(directory:directory,cacheID:cacheID,sourceHashes:transcriptHashes)
        let automatic=try fileDigest(directory.appendingPathComponent(SpeakerRefinementArtifact.filename),limit:SpeakerRefinementArtifact.maximumBytes)
        let names=try stableNamesSHA256(directory:directory,session:session)
        let eventDigest=try transcriptSnapshotSHA256(events:events)
        return digest(try jsonData(["legacy_snapshot_sha256":legacy,"automatic_speaker_sha256":automatic,
                                    "session_names_sha256":names,"events_sha256":eventDigest]))
    }
    private static func stableNamesSHA256(directory:URL,session:String)throws->String {
        let file=directory.appendingPathComponent("session-names.json",isDirectory:false)
        guard FileManager.default.fileExists(atPath:file.path) else{return ""}
        let attrs=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard attrs.isRegularFile==true,attrs.isSymbolicLink != true,
              let size=attrs.fileSize,size>=0,size<=4*1024*1024 else{throw MeetingCoarseRefinementError.invalidScope}
        let data=try Data(contentsOf:file,options:[.mappedIfSafe])
        guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              [1,2].contains(value["schema"] as? Int ?? 0),value["session"] as? String==session else{throw MeetingCoarseRefinementError.invalidScope}
        func sortedRows(_ raw:Any?)->[[String:Any]] {
            (raw as? [[String:Any]] ?? []).sorted {
                let lhs=(try? String(data:jsonData($0),encoding:.utf8)) ?? ""
                let rhs=(try? String(data:jsonData($1),encoding:.utf8)) ?? ""
                return lhs<rhs
            }
        }
        let stable:[String:Any]=["schema":value["schema"] ?? 0,"session":session,
                                "sentences":value["sentences"] ?? [:],"speakers":sortedRows(value["speakers"]),
                                "assignments":sortedRows(value["assignments"]),"aliases":sortedRows(value["aliases"]),
                                "runAnchors":sortedRows(value["runAnchors"])]
        return digest(try jsonData(stable))
    }

    static func prepareRequest(directory:URL,session:String,cacheID:String,events:[[String:Any]],
                               transcriptHashes:[String:String])throws->RequestPayload {
        let source=try sourceSHA256(transcriptHashes:transcriptHashes)
        let snapshot=try snapshotSHA256(directory:directory,cacheID:cacheID,session:session,events:events,transcriptHashes:transcriptHashes)
        let coverage=try verifiedAudioEnds(directory:directory,session:session,events:events)
        let (available,roster)=try units(events:events,session:session,sourceAudioEnds:coverage.ends,strictAudioTracks:coverage.incompleteTracks)
        let labels=try manualSpeakerLabels(directory:directory,session:session)
        let named=Set(labels.speakers.keys)
        let protected=try protectedUnits(directory:directory,session:session,events:events,units:available,manualSentenceIDs:labels.sentenceIDs)
        let textProtected=textProtectedUnits(labels:labels,units:available,session:session)
        let rows=try available.values.sorted{$0.start == $1.start ? $0.id<$1.id:$0.start<$1.start}.map {unit throws -> RequestUnit in
            // Malformed transcript events fail this refinement, never the app.
            guard let event=events.first(where:{$0["segment_id"] as? String==unit.parent}),
                  let sourceID=event["source_id"] as? String else{throw Failure(code:"coarse_unit_source_missing")}
            let key=keyForSpeaker(unit.speaker,event:event)
            return RequestUnit(unit_id:unit.id,original_text_sha256:digest(Data(unit.text.utf8)),text:unit.text,
                               start:unit.start,end:unit.end,source_id:sourceID,
                               manual:textProtected.contains(unit.id),
                               speaker_locked:protected.contains(unit.id) || key.map{named.contains($0)}==true,
                               approximate_window:unit.approximate,speaker_key:key,
                               speaker_name:labels.segments[unit.id] ?? key.flatMap{labels.speakers[$0]})
        }
        return RequestPayload(schema:1,method:method,cache_id:cacheID,session:session,source_sha256:source,
                              snapshot_sha256:snapshot,roster:roster.sorted{($0.source+$0.epoch+$0.identity)<($1.source+$1.epoch+$1.identity)}.map{RosterEntry(key:$0,name:labels.speakers[$0])},units:rows,
                              incomplete_audio:!coverage.incompleteTracks.isEmpty)
    }
    static func inputUnits(directory:URL,session:String,cacheID:String,events:[[String:Any]],
                          transcriptHashes:[String:String])throws->[RequestUnit] {
        try prepareRequest(directory:directory,session:session,cacheID:cacheID,events:events,transcriptHashes:transcriptHashes).units
    }

    /// Validates an API response, projects the accepted records, and returns a
    /// sidecar object ready for atomic persistence by the caller.
    static func project(events:[[String:Any]],session:String,cacheID:String,
                        sourceSHA256:String,snapshotSHA256:String,
                        records:[[String:Any]],directory:URL,
                        protectedIDs:Set<String>?=nil,
                        manualSpeakerKeys:Set<SessionSpeakerKey>?=nil,
                        transcriptHashes:[String:String]?=nil,
                        allowPartial:Bool=false)throws->Projection {
        try validateInput(events:events,session:session,cacheID:cacheID,sourceSHA256:sourceSHA256,snapshotSHA256:snapshotSHA256)
        if let transcriptHashes {
            guard try MeetingCoarseRefinement.sourceSHA256(transcriptHashes:transcriptHashes)==sourceSHA256,
                  try MeetingCoarseRefinement.snapshotSHA256(directory:directory,cacheID:cacheID,session:session,events:events,transcriptHashes:transcriptHashes)==snapshotSHA256 else {
                throw MeetingCoarseRefinementError.snapshotChanged
            }
        } else {
            guard try transcriptSnapshotSHA256(events:events)==snapshotSHA256 else{throw MeetingCoarseRefinementError.snapshotChanged}
        }
        guard records.count<=maximumRecords else{throw MeetingCoarseRefinementError.invalidArtifact}
        let coverage=try verifiedAudioEnds(directory:directory,session:session,events:events)
        let (available,knownKeys)=try units(events:events,session:session,sourceAudioEnds:coverage.ends,strictAudioTracks:coverage.incompleteTracks)
        let labels=try manualSpeakerLabels(directory:directory,session:session)
        let derivedProtected=try protectedUnits(directory:directory,session:session,events:events,units:available,manualSentenceIDs:labels.sentenceIDs)
        let protected=protectedIDs ?? derivedProtected
        let textProtected=textProtectedUnits(labels:labels,units:available,session:session)
        let named:Set<SessionSpeakerKey>
        if let manualSpeakerKeys { named=manualSpeakerKeys }
        else { named=Set(labels.speakers.keys) }
        let speakerLocked=Set(available.values.compactMap { unit -> String? in
            guard let event=events.first(where:{$0["segment_id"] as? String==unit.parent}),
                  let key=keyForSpeaker(unit.speaker,event:event),named.contains(key) else{return nil}
            return unit.id
        })
        var seen=Set<String>(),accepted:[[String:Any]]=[],textChanges:[String:String]=[:],speakerChanges:[String:SessionSpeakerKey]=[:]
        var unassignedSpeakers=Set<String>()
        // A meeting-level acoustic pass owns identity for the whole snapshot.
        // Old text artifacts can reference slots retired by that pass, including
        // in uncertain/unmodified parents. Keep their text without reviving the
        // retired identity or rejecting the entire clean transcript.
        let acousticIdentity=events.contains{$0["acoustic_refinement_applied"] as? Bool==true}
        var skippedStaleSourceUnits=false
        for record in records {
            let allowed=Set(["unit_id","original_text_sha256","text","speaker_key","notes","name_changes"])
            guard Set(record.keys).isSubset(of:allowed),
                  let id=record["unit_id"] as? String,!id.isEmpty,id.count<=256,seen.insert(id).inserted,
                  let originalHash=record["original_text_sha256"] as? String,validDigest(originalHash),
                  let proposed=record["text"] as? String else{throw MeetingCoarseRefinementError.eventChanged}
            var normalized=proposed.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !normalized.isEmpty,normalized.utf8.count<=maximumTextBytes,
                  !normalized.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)}) else {
                throw MeetingCoarseRefinementError.invalidArtifact
            }
            let notesValue:String?
            if let notes=record["notes"],!(notes is NSNull) {
                guard let notes=notes as? String,notes.utf8.count<=2048 else{throw MeetingCoarseRefinementError.invalidArtifact}
                notesValue=notes.isEmpty ? nil:notes
            } else {notesValue=nil}
            let proposedKey:SessionSpeakerKey?
            if let raw=record["speaker_key"],!(raw is NSNull) {
                proposedKey=try decodeKey(raw,session:session)
            } else {proposedKey=nil}

            guard let unit=available[id],originalHash==digest(Data(unit.text.utf8)) else {
                guard allowPartial else{throw MeetingCoarseRefinementError.eventChanged}
                skippedStaleSourceUnits=true
                continue
            }
            // The Python worker also checks fidelity. Keep an independent
            // bound here for older artifacts and unexpected provider output.
            let before=unit.text.unicodeScalars.filter{CharacterSet.alphanumerics.contains($0)}.count
            let after=normalized.unicodeScalars.filter{CharacterSet.alphanumerics.contains($0)}.count
            if after>before+max(12,before/2) {normalized=unit.text}
            try validateNewText(normalized,original:unit.text)
            var row:[String:Any]=["unit_id":id,"original_text_sha256":originalHash,"text":normalized]
            if let notesValue {row["notes"]=notesValue}
            if let key=proposedKey,!acousticIdentity {
                guard knownKeys.contains(key) else{throw MeetingCoarseRefinementError.unknownSpeaker}
                row["speaker_key"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(key))
                speakerChanges[id]=key
            } else if record["speaker_key"] is NSNull,!acousticIdentity {
                // Explicit uncertainty must clear an unreliable model slot.
                // An omitted field still means "keep the original attribution".
                row["speaker_key"]=NSNull()
                unassignedSpeakers.insert(id)
            }
            if !textProtected.contains(id),normalized != unit.text,
               let changes=record["name_changes"] as? [[String:String]] {
                let valid=changes.filter {
                    Set($0.keys)==Set(["unit_id","old","new"]) && $0["unit_id"]==id &&
                    $0["old"] != $0["new"] && !($0["old"] ?? "").isEmpty &&
                    unit.text.contains($0["old"]!) && normalized.contains($0["new"] ?? "")
                }
                if !valid.isEmpty {row["name_changes"]=valid}
            }
            accepted.append(row)
            if !textProtected.contains(id) {
                if normalized != unit.text{textChanges[id]=normalized}
            }
        }
        // A refinement may finish after the user resumed recording. Keep only
        // records whose exact source text still exists; newly appended units
        // remain raw until the next pause. Original hashes still reject stale
        // or hand-edited rows.
        guard allowPartial || seen==Set(available.keys) else{throw MeetingCoarseRefinementError.invalidArtifact}

        var projected=events
        var indexByParent:[String:Int]=[:]
        for index in projected.indices {indexByParent[projected[index]["segment_id"] as? String ?? ""]=index}
        var changedByParent=Set<String>()
        for (id,text) in textChanges {
            guard let unit=available[id],let index=indexByParent[unit.parent] else{throw MeetingCoarseRefinementError.eventChanged}
            var event=projected[index]
            if let words=events[index]["word_spans"] as? [[String:Any]] {
                event["coarse_source_word_spans"]=events[index]["coarse_source_word_spans"] ?? words
            }
            if let runIndex=unit.runIndex {
                guard var runs=event["speaker_runs"] as? [[String:Any]],runs.indices.contains(runIndex) else{throw MeetingCoarseRefinementError.eventChanged}
                runs[runIndex]["text"]=text;event["speaker_runs"]=runs
            } else {
                event["text"]=text
                if event["word_spans"] is [[String:Any]] {event["word_spans"]=[["start":unit.start,"end":unit.end,"text":text]]}
            }
            changedByParent.insert(unit.parent);projected[index]=event
        }
        for (id,key) in speakerChanges where !protected.contains(id) && !speakerLocked.contains(id) {
            guard let unit=available[id],let index=indexByParent[unit.parent] else{throw MeetingCoarseRefinementError.eventChanged}
            guard events[index]["acoustic_refinement_applied"] as? Bool != true else{continue}
            var event=projected[index]
            if let runIndex=unit.runIndex {
                guard var runs=event["speaker_runs"] as? [[String:Any]],runs.indices.contains(runIndex) else{throw MeetingCoarseRefinementError.eventChanged}
                runs[runIndex]["speaker"]=targetSpeaker(key,event:event);event["speaker_runs"]=runs
            } else {event["speaker"]=targetSpeaker(key,event:event)}
            changedByParent.insert(unit.parent);projected[index]=event
        }
        for id in unassignedSpeakers where !protected.contains(id) && !speakerLocked.contains(id) {
            guard let unit=available[id],let index=indexByParent[unit.parent] else{throw MeetingCoarseRefinementError.eventChanged}
            guard events[index]["acoustic_refinement_applied"] as? Bool != true else{continue}
            var event=projected[index]
            let unknown:[String:Any]=["basis":"unknown","reason":"refinement_unassigned"]
            if let runIndex=unit.runIndex {
                guard var runs=event["speaker_runs"] as? [[String:Any]],runs.indices.contains(runIndex) else{throw MeetingCoarseRefinementError.eventChanged}
                runs[runIndex]["speaker"]=unknown;event["speaker_runs"]=runs
            } else {event["speaker"]=unknown}
            changedByParent.insert(unit.parent);projected[index]=event
        }
        for parent in changedByParent {
            guard let index=indexByParent[parent],let eventRuns=projected[index]["speaker_runs"] as? [[String:Any]] else{continue}
            let joined=eventRuns.compactMap{$0["text"] as? String}.joined()
            guard eventRuns.allSatisfy({$0["text"] is String}),!joined.isEmpty else{throw MeetingCoarseRefinementError.invalidLayout}
            projected[index]["text"]=joined
            if projected[index]["word_spans"] is [[String:Any]] {
                projected[index]["word_spans"]=try rebasedWordSpans(event:events[indexByParent[parent]!],runs:eventRuns,changedUnitIDs:Set(textChanges.keys.filter{available[$0]?.parent==parent}),available:available)
            }
        }
        for row in accepted {
            if let id=row["unit_id"] as? String,let unit=available[id],let index=indexByParent[unit.parent],
               let changes=row["name_changes"] as? [[String:String]] {
                let previous=projected[index]["coarse_name_changes"] as? [[String:String]] ?? []
                projected[index]["coarse_name_changes"]=previous+changes
            }
        }
        for parent in changedByParent {
            if let index=indexByParent[parent] {projected[index]["coarse_refinement_applied"]=true}
        }
        let artifact:[String:Any]=["schema":1,"method":method,"cache_id":cacheID,"session":session,
                                  "source_sha256":sourceSHA256,"snapshot_sha256":snapshotSHA256,
                                  "records":accepted]
        var resultArtifact=artifact
        if skippedStaleSourceUnits {resultArtifact["stale_source_units_skipped"]=true}
        return Projection(events:projected,artifact:resultArtifact)
    }

    static func mergeRecords(directory:URL,session:String,cacheID:String,
                             incoming:[[String:Any]],currentUnits:[RequestUnit])throws->[[String:Any]] {
        let file=directory.appendingPathComponent(filename,isDirectory:false)
        var old:[[String:Any]]=[]
        if FileManager.default.fileExists(atPath:file.path) {
            let attrs=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard attrs.isRegularFile==true,attrs.isSymbolicLink != true,
                  let size=attrs.fileSize,size>=0,size<=maximumBytes else{throw MeetingCoarseRefinementError.invalidScope}
            let data=try Data(contentsOf:file,options:[.mappedIfSafe])
            guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  object["schema"] as? Int==1,object["method"] as? String==method,
                  object["cache_id"] as? String==cacheID,object["session"] as? String==session,
                  let records=object["records"] as? [[String:Any]] else{throw MeetingCoarseRefinementError.sourceChanged}
            old=records
        }
        let hashes=Dictionary(uniqueKeysWithValues:currentUnits.map{($0.unit_id,$0.original_text_sha256)})
        var merged:[String:[String:Any]]=[:]
        for record in old+incoming {
            guard let id=record["unit_id"] as? String,
                  let hash=record["original_text_sha256"] as? String,
                  hashes[id]==hash else{continue}
            merged[id]=record
        }
        return merged.keys.sorted().compactMap{merged[$0]}
    }

    /// Rebase a completed pause batch onto the latest transcript snapshot.
    /// The immutable request is the authority for what the model actually saw;
    /// current unit IDs and text hashes decide which of those results still fit.
    /// Newly appended units are left untouched until their own pause batch.
    static func rebaseResponse(_ response:[String:Any],request:RequestPayload,
                               events:[[String:Any]],directory:URL,
                               transcriptHashes:[String:String])throws->Projection {
        guard request.schema==1,request.method==method,validCacheID(request.cache_id),
              !request.session.isEmpty,request.session.count<=160,
              validDigest(request.source_sha256),validDigest(request.snapshot_sha256),
              response["schema"] as? Int==1,response["method"] as? String==method,
              response["cache_id"] as? String==request.cache_id,
              response["session"] as? String==request.session,
              response["source_sha256"] as? String==request.source_sha256,
              response["snapshot_sha256"] as? String==request.snapshot_sha256,
              response["model"] is String,
              let incomingRecords=response["records"] as? [[String:Any]] else {
            throw MeetingCoarseRefinementError.invalidArtifact
        }
        var requestHashes:[String:String]=[:]
        for unit in request.units {
            guard !unit.unit_id.isEmpty,requestHashes[unit.unit_id]==nil,
                  validDigest(unit.original_text_sha256) else{throw MeetingCoarseRefinementError.invalidArtifact}
            requestHashes[unit.unit_id]=unit.original_text_sha256
        }
        var seen=Set<String>()
        let incoming=recordsWithNameChanges(incomingRecords,response:response)
        guard incoming.count<=maximumRecords,incoming.allSatisfy({
                  guard let id=$0["unit_id"] as? String,
                        let hash=$0["original_text_sha256"] as? String,seen.insert(id).inserted else{return false}
                  return requestHashes[id]==hash
              }) else{throw MeetingCoarseRefinementError.eventChanged}

        let current=try prepareRequest(directory:directory,session:request.session,cacheID:request.cache_id,
                                       events:events,transcriptHashes:transcriptHashes)
        let records=try mergeRecords(directory:directory,session:request.session,cacheID:request.cache_id,
                                     incoming:incoming,currentUnits:current.units)
        var rebased=response
        rebased["source_sha256"]=current.source_sha256
        rebased["snapshot_sha256"]=current.snapshot_sha256
        rebased["records"]=records
        return try project(response:rebased,events:events,directory:directory,transcriptHashes:transcriptHashes)
    }

    private static func recordsWithNameChanges(_ records:[[String:Any]],response:[String:Any])->[[String:Any]] {
        guard let changes=response["name_changes"] as? [[String:String]] else{return records}
        let grouped=Dictionary(grouping:changes,by:{$0["unit_id"] ?? ""})
        return records.map { record in
            var row=record
            if let id=record["unit_id"] as? String,let values=grouped[id] {row["name_changes"]=values}
            return row
        }
    }

    static func project(response:[String:Any],events:[[String:Any]],directory:URL,
                        transcriptHashes:[String:String])throws->Projection {
        guard response["schema"] as? Int==1,response["method"] as? String==method,
              let session=response["session"] as? String,let cacheID=response["cache_id"] as? String,
              let source=response["source_sha256"] as? String,
              let snapshot=response["snapshot_sha256"] as? String,
              let records=response["records"] as? [[String:Any]],
              response["model"] is String else{throw MeetingCoarseRefinementError.invalidArtifact}
        var result=try project(events:events,session:session,cacheID:cacheID,sourceSHA256:source,
                               snapshotSHA256:snapshot,records:recordsWithNameChanges(records,response:response),directory:directory,
                               transcriptHashes:transcriptHashes,allowPartial:true)
        var artifact=result.artifact
        artifact["model"]=response["model"]
        if response["warning"] as? String=="semantic_assignment_incomplete" {
            artifact["warning"]="semantic_assignment_incomplete"
        }
        if response["incomplete_audio"] as? Bool==true {artifact["incomplete_audio"]=true}
        result=Projection(events:eventsWithStatus(result.events,artifact),artifact:artifact)
        return result
    }

    static func eventsWithStatus(_ events:[[String:Any]],_ artifact:[String:Any])->[[String:Any]] {
        guard !events.isEmpty else{return events}
        var result=events
        let semanticWarning=artifact["warning"] as? String=="semantic_assignment_incomplete"
        let audioWarning=artifact["incomplete_audio"] as? Bool==true
        if artifact["stale_source_units_skipped"] as? Bool==true {
            result[0]["coarse_refinement_warning"]=semanticWarning
                ? "部分原文已更新，相关结果已跳过；发言人整理也未完整完成"
                : "部分原文已更新，相关整理结果已跳过；其余结果保留"
        } else if audioWarning {
            result[0]["coarse_refinement_warning"]=semanticWarning
                ? "已有转写内容已整理，仍有录音待补转写且部分发言人未整理；完成转写后可重试"
                : "已有转写内容已整理，仍有录音待补转写；完成转写后可重试整理"
        } else if semanticWarning {
            result[0]["coarse_refinement_warning"]="文字已整理，部分发言人未整理完，可重试"
        }
        return result
    }

    /// Replaces word timings only for corrected runs with one stable run span.
    /// Unchanged spans keep their exact times and text, preserving manual anchors.
    private static func rebasedWordSpans(event:[String:Any],runs:[[String:Any]],changedUnitIDs:Set<String>,available:[String:Unit])throws->[[String:Any]] {
        guard let words=event["word_spans"] as? [[String:Any]],words.count<=1000 else{throw MeetingCoarseRefinementError.invalidLayout}
        var replacements:[[String:Any]]=[]
        for word in words {
            guard let start=word["start"] as? Double,let end=word["end"] as? Double,
                  start.isFinite,end.isFinite,end>start,let body=word["text"] as? String,!body.isEmpty else{throw MeetingCoarseRefinementError.invalidLayout}
            let hit=runs.indices.filter {idx in
                guard let lo=runs[idx]["start"] as? Double,let hi=runs[idx]["end"] as? Double else{return false}
                return start < hi && end > lo
            }
            guard hit.count<=1 else{throw MeetingCoarseRefinementError.invalidLayout}
            if let idx=hit.first {
                let id=TranscriptTimeline.runID(parent:event["segment_id"] as? String ?? "",run:runs[idx])
                if changedUnitIDs.contains(id) {continue}
            }
            replacements.append(word)
        }
        for id in changedUnitIDs {
            guard let unit=available[id],let runIndex=unit.runIndex,runs.indices.contains(runIndex),
                  let text=runs[runIndex]["text"] as? String else{throw MeetingCoarseRefinementError.invalidLayout}
            replacements.append(["start":unit.start,"end":unit.end,"text":text])
        }
        replacements.sort{($0["start"] as? Double ?? 0)<($1["start"] as? Double ?? 0)}
        var cursor=event["start"] as? Double ?? 0,joined=""
        for word in replacements {
            guard let start=word["start"] as? Double,let end=word["end"] as? Double,
                  start.isFinite,end.isFinite,start>=cursor-0.001,end>start,
                  let text=word["text"] as? String,!text.isEmpty else{throw MeetingCoarseRefinementError.invalidLayout}
            cursor=end;joined+=text
        }
        guard joined==(runs.compactMap{$0["text"] as? String}.joined()) else{throw MeetingCoarseRefinementError.invalidLayout}
        return replacements
    }

    static func save(_ artifact:[String:Any],directory:URL,cacheID:String)throws {
        guard validCacheID(cacheID),directory.lastPathComponent==cacheID else{throw MeetingCoarseRefinementError.invalidScope}
        let dirAttrs=try directory.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard dirAttrs.isDirectory==true,dirAttrs.isSymbolicLink != true else{throw MeetingCoarseRefinementError.invalidScope}
        let data=try jsonData(artifact);guard data.count<=maximumBytes else{throw MeetingCoarseRefinementError.fileTooLarge}
        let file=directory.appendingPathComponent(filename,isDirectory:false)
        if FileManager.default.fileExists(atPath:file.path) {
            let attrs=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard attrs.isRegularFile==true,attrs.isSymbolicLink != true else{throw MeetingCoarseRefinementError.invalidScope}
        }
        try data.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }

    static func loadApply(events:[[String:Any]],directory:URL,session:String,cacheID:String,
                          sourceSHA256:String,snapshotSHA256:String)->[[String:Any]] {
        do {
            if try isDisabled(directory:directory,session:session) {return TranscriptTimeline.revealReadingEchoes(events)}
            let file=directory.appendingPathComponent(filename,isDirectory:false)
            guard FileManager.default.fileExists(atPath:file.path) else{return events}
            let attrs=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard attrs.isRegularFile==true,attrs.isSymbolicLink != true,
                  let size=attrs.fileSize,size>=0,size<=maximumBytes else{throw MeetingCoarseRefinementError.invalidScope}
            let data=try Data(contentsOf:file,options:[.mappedIfSafe])
            guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  object["schema"] as? Int==1,object["method"] as? String==method,
                  object["cache_id"] as? String==cacheID,object["session"] as? String==session,
                  let records=object["records"] as? [[String:Any]] else{throw MeetingCoarseRefinementError.sourceChanged}
            let result=try project(events:events,session:session,cacheID:cacheID,sourceSHA256:sourceSHA256,
                                   snapshotSHA256:snapshotSHA256,records:records,directory:directory,allowPartial:true)
            return try readingProjection(original:events,projected:eventsWithStatus(result.events,object.merging(result.artifact){_,current in current}),directory:directory,session:session,reviewed:result.artifact["records"] as? [[String:Any]] ?? [])
        } catch {
            guard !events.isEmpty else{return events}
            var result=events;result[0]["coarse_refinement_warning"]="自动整理已跳过，原始会议记录可继续查看";return result
        }
    }

    static func loadApply(events:[[String:Any]],directory:URL,session:String,cacheID:String,
                          transcriptHashes:[String:String])->[[String:Any]] {
        do {
            if try isDisabled(directory:directory,session:session) {return TranscriptTimeline.revealReadingEchoes(events)}
            let file=directory.appendingPathComponent(filename,isDirectory:false)
            // Most sessions have no coarse artifact. Avoid hashing the entire
            // transcript and audio manifest on every normal recovery refresh.
            guard FileManager.default.fileExists(atPath:file.path) else{return events}
            let source=try sourceSHA256(transcriptHashes:transcriptHashes)
            let snapshot=try snapshotSHA256(directory:directory,cacheID:cacheID,session:session,events:events,transcriptHashes:transcriptHashes)
            let attrs=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard attrs.isRegularFile==true,attrs.isSymbolicLink != true,
                  let size=attrs.fileSize,size>=0,size<=maximumBytes else{throw MeetingCoarseRefinementError.invalidScope}
            let data=try Data(contentsOf:file,options:[.mappedIfSafe])
            guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  object["schema"] as? Int==1,object["method"] as? String==method,
                  object["cache_id"] as? String==cacheID,object["session"] as? String==session,
                  let records=object["records"] as? [[String:Any]] else{throw MeetingCoarseRefinementError.sourceChanged}
            let projection=try project(events:events,session:session,cacheID:cacheID,sourceSHA256:source,
                               snapshotSHA256:snapshot,records:records,directory:directory,
                               transcriptHashes:transcriptHashes,allowPartial:true)
            return try readingProjection(original:events,projected:eventsWithStatus(projection.events,object.merging(projection.artifact){_,current in current}),directory:directory,session:session,reviewed:projection.artifact["records"] as? [[String:Any]] ?? [])
        } catch {
            guard !events.isEmpty else{return events}
            var result=events;result[0]["coarse_refinement_warning"]="自动整理已跳过，原始会议记录可继续查看";return result
        }
    }

    private static func readingProjection(original:[[String:Any]],projected:[[String:Any]],directory:URL,session:String,reviewed:[[String:Any]])throws->[[String:Any]] {
        let labels=try manualSpeakerLabels(directory:directory,session:session)
        var protected=Set(labels.segments.keys).union(labels.sentenceIDs)
        protected.formUnion(labels.anchors.compactMap{$0["parent"] as? String})
        for event in original {
            if let key=SessionSpeakerKey.from(event),labels.speakers[key] != nil,let id=event["segment_id"] as? String {protected.insert(id)}
        }
        let reviewedIDs=Set(reviewed.compactMap{$0["unit_id"] as? String})
        // Closed but unfinished ASR hypotheses are not finished utterances.
        // Once reviewed, keep them in the original view rather than inventing
        // a speaker for a zero-duration fragment on the clean reading surface.
        var result=TranscriptTimeline.markReadingEchoes(original:original,projected:projected,protected:protected)
        var drafts=0
        for i in result.indices {
            guard let id=result[i]["segment_id"] as? String,reviewedIDs.contains(id),!protected.contains(id),
                  result[i]["final"] as? Bool != true else{continue}
            result[i]["reading_draft"]=true;drafts+=1
        }
        if drafts>0 {result[0]["reading_projection_notice"]="\(drafts)段未定稿转写保留在原稿中"}
        return result
    }

    private static func isDisabled(directory:URL,session:String)throws->Bool {
        let file=directory.appendingPathComponent("coarse-refinement-preference.json",isDirectory:false)
        guard FileManager.default.fileExists(atPath:file.path) else{return false}
        let attrs=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard attrs.isRegularFile==true,attrs.isSymbolicLink != true,
              let size=attrs.fileSize,size>=0,size<=4096 else{throw MeetingCoarseRefinementError.invalidScope}
        let data=try Data(contentsOf:file,options:[.mappedIfSafe])
        guard let preference=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              preference["schema"] as? Int==1,preference["session"] as? String==session,
              let enabled=preference["enabled"] as? Bool else{throw MeetingCoarseRefinementError.invalidScope}
        return !enabled
    }
}
