import Foundation

// Reuses saved audio for matching only. No enrollment, network, capture or
// transcript writes. Features live only in this bounded helper response.
struct SavedVoiceRecognitionRequest:Codable {
    let folder:String
    let session:String
    let inputKind:String
    let keys:[SessionSpeakerKey]
    var selectedIDs:[String]?=nil
    var sampleLimit:Int?=nil
}
struct SavedVoiceRecognitionEvidence:Codable {
    let id:String
    let revision:Int
    let key:SessionSpeakerKey
    let sample:VoiceprintSample
}
struct SavedVoiceAudioCheck:Codable {
    let bytes:Int
    let sha256:String
}
struct SavedVoiceRecognitionResult:Codable {
    let session:String
    let partition:String
    let inputKind:String
    let inputHashes:[String:String]
    let audioChecks:[String:SavedVoiceAudioCheck]
    let evidence:[SavedVoiceRecognitionEvidence]
    let skipped:Int
}
enum SavedVoiceRecognition {
    static let projectionFiles=["speaker-reconciliation.json",SpeakerRefinementArtifact.filename,MeetingCoarseRefinement.filename,"coarse-refinement-preference.json"]
    static func read(_ file:URL,limit:Int)throws->Data {
        let attrs=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard attrs.isRegularFile==true,attrs.isSymbolicLink != true,(attrs.fileSize ?? Int.max)<=limit,
              file.standardizedFileURL==file.resolvingSymlinksInPath().standardizedFileURL else{throw Failure(code:"saved_voice_source_invalid")}
        let data=try Data(contentsOf:file)
        guard data.count<=limit else{throw Failure(code:"saved_voice_source_invalid")};return data
    }
    static func folder(_ request:SavedVoiceRecognitionRequest)throws->URL {
        let folder=URL(fileURLWithPath:request.folder)
        guard folder.standardizedFileURL.path==request.folder,UUID(uuidString:folder.lastPathComponent) != nil,
              folder.standardizedFileURL==folder.resolvingSymlinksInPath().standardizedFileURL,
              !request.session.isEmpty,request.session.count<=160,
              ["synthetic_model_output","consented_live_audio"].contains(request.inputKind),
              !request.keys.isEmpty,request.keys.count<=32,Set(request.keys).count==request.keys.count,
              (8...24).contains(request.sampleLimit ?? 8),
              request.keys.allSatisfy({key in
                  guard let slot=Int(key.identity.replacingOccurrences(of:"slot:",with:"")) else{return false}
                  return key.session==request.session && isTranscriptAudioTrack(key.source) && !key.epoch.isEmpty && key.epoch.count<=160 && (0..<8).contains(slot) && key.identity=="slot:\(slot)"
              }) else{throw Failure(code:"saved_voice_scope_invalid")}
        if let ids=request.selectedIDs {guard !ids.isEmpty,ids.count<=4096,Set(ids).count==ids.count,ids.allSatisfy({!$0.isEmpty && $0.count<=256}) else{throw Failure(code:"saved_voice_scope_invalid")}}
        return folder
    }
    static func validate(_ result:SavedVoiceRecognitionResult,request:SavedVoiceRecognitionRequest)throws {
        let folder=try folder(request)
        guard result.session==request.session,result.partition==SpeakerEmbeddingBackend.partition,result.inputKind==request.inputKind,
              result.evidence.count<=256,result.inputHashes.count<=80,result.audioChecks.count<=512,
              result.inputHashes["meeting.json"] != nil else{throw Failure(code:"saved_voice_result_invalid")}
        for (name,hash) in result.inputHashes {
            guard !name.contains("/"),!name.contains("\\"),name=="meeting.json" || projectionFiles.contains(name) || name.hasSuffix("-manifest.json") || name.hasSuffix("-transcript.jsonl") else{throw Failure(code:"saved_voice_result_invalid")}
            let file=folder.appendingPathComponent(name)
            if hash=="absent" {guard !FileManager.default.fileExists(atPath:file.path) else{throw Failure(code:"saved_voice_source_changed")}}
            else {guard historicalVoiceHash(try read(file,limit:32*1024*1024))==hash else{throw Failure(code:"saved_voice_source_changed")}}
        }
        for (name,check) in result.audioChecks {
            guard name.range(of:"^[a-z0-9-]+-[0-9]{6}\\.pcm$",options:.regularExpression) != nil,check.bytes>0,check.bytes<=320000 else{throw Failure(code:"saved_voice_result_invalid")}
            guard historicalVoiceHash(try readPrefix(folder.appendingPathComponent(name),bytes:check.bytes))==check.sha256 else{throw Failure(code:"saved_voice_source_changed")}
        }
        for row in result.evidence {
            guard request.keys.contains(row.key),row.sample.session==request.session,
                  isTranscriptAudioTrack(row.sample.source),row.revision>=0,!row.id.isEmpty,row.id.count<=256,
                  row.sample.start.isFinite,row.sample.start>=0,row.sample.end.isFinite,
                  (1.99...4.01).contains(row.sample.end-row.sample.start),
                  row.sample.vector.count==192,row.sample.vector.allSatisfy(\.isFinite),
                  abs(row.sample.vector.reduce(0,{$0+$1*$1})-1)<0.001 else{throw Failure(code:"saved_voice_result_invalid")}
        }
    }
    static func readPrefix(_ file:URL,bytes:Int)throws->Data {
        let attrs=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard attrs.isRegularFile==true,attrs.isSymbolicLink != true,(attrs.fileSize ?? 0)>=bytes else{throw Failure(code:"saved_voice_audio_missing")}
        let handle=try FileHandle(forReadingFrom:file);defer{try? handle.close()}
        let data=try handle.read(upToCount:bytes) ?? Data()
        guard data.count==bytes else{throw Failure(code:"saved_voice_audio_missing")};return data
    }
    static func run(_ request:SavedVoiceRecognitionRequest,extract:([Float])throws->[Double])throws->SavedVoiceRecognitionResult {
        let directory=try folder(request)
        let metadataData=try read(directory.appendingPathComponent("meeting.json"),limit:1024*1024)
        guard let metadata=try JSONSerialization.jsonObject(with:metadataData) as? [String:Any],metadata["session"] as? String==request.session,
              let origin=metadata["capture_origin_uptime"] as? Double,origin.isFinite else{throw Failure(code:"saved_voice_scope_invalid")}
        let tracks=try meetingAudioTracks(in:directory)
        let meeting=CachedMeeting(id:directory.lastPathComponent,directory:directory,date:Date(),writtenBytes:0,pendingBytes:0,occupiedBytes:0,tracks:tracks,audioCleaned:false,warning:false,retiredBytes:0)
        var hashes=["meeting.json":historicalVoiceHash(metadataData)]
        for name in projectionFiles+tracks.map({$0+"-transcript.jsonl"}) {
            let file=directory.appendingPathComponent(name)
            hashes[name]=FileManager.default.fileExists(atPath:file.path) ? historicalVoiceHash(try read(file,limit:32*1024*1024)):"absent"
        }
        // Text cleanup may infer a different speaker, including across audio
        // sources. Feeding those inferred groups back into voice recognition
        // lets microphone echo contaminate a previously consistent voice.
        // Extract from the acoustic segmentation, before text cleanup. Keep
        // projection hashes above so an in-flight result still expires safely.
        let events=try meeting.events(includeCoarseRefinement:false)
        var groups:[SessionSpeakerKey:[(String,[String:Any])]]=[:]
        for event in events {
            guard let parent=event["segment_id"] as? String else{continue}
            let runs=TranscriptTimeline.speakerRuns(event)
            for item in runs.isEmpty ? [event]:runs {
                guard let key=SessionSpeakerKey.from(item),request.keys.contains(key),item["final"] as? Bool==true,item["end_time_known"] as? Bool==true,
                      (item["speaker"] as? [String:Any])?["echo_of"] == nil,
                      (item["speaker"] as? [String:Any])?["slot_continuity"] as? Bool != true,
                      (item["speaker"] as? [String:Any])?["local_continuity"] as? Bool != true,
                      audioSourceCoreID(item["source_id"] as? String ?? "") != "mic" || audioSourceCoreID(key.source)=="mic",
                      (item["quality_flags"] as? [String] ?? []).isEmpty,
                      let start=item["start"] as? Double,let end=item["end"] as? Double,start.isFinite,end.isFinite,start>=0,end-start>=2,end<=86400,
                      item["coarse_refinement_approximate_window"] as? Bool != true else{continue}
                let id=runs.isEmpty ? parent:TranscriptTimeline.runID(parent:parent,run:item)
                if let selected=request.selectedIDs,!selected.contains(id) {continue}
                groups[key,default:[]].append((id,item))
            }
        }
        var audioChecks:[String:SavedVoiceAudioCheck]=[:],evidence:[SavedVoiceRecognitionEvidence]=[],skipped=0
        var manifests:[String:[String:Any]]=[:]
        func snippet(source:String,start:Double,end:Double)throws->[Float] {
            let manifest:[String:Any]
            if let saved=manifests[source] {manifest=saved}
            else {
                let name=source+"-manifest.json",data=try read(directory.appendingPathComponent(name),limit:1024*1024)
                guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw Failure(code:"saved_voice_manifest_invalid")}
                hashes[name]=historicalVoiceHash(data);manifests[source]=value;manifest=value
            }
            guard manifest["track"] as? String==source,manifest["format"] as? String=="pcm_s16le",manifest["sample_rate"] as? Int==16000,manifest["channels"] as? Int==1,
                  manifest["audio_cleaned"] as? Bool != true,
                  let trackOrigin=manifest["origin_uptime"] as? Double,trackOrigin.isFinite,trackOrigin>=origin-0.25,trackOrigin-origin<=86400,
                  let written=manifest["written_bytes"] as? Int,written>=0,written<=2764800000,
                  let chunks=manifest["chunks"] as? [[String:Any]],chunks.count<=10000 else{throw Failure(code:"saved_voice_manifest_invalid")}
            let first=Int(((start-(trackOrigin-origin))*16000).rounded())*2,last=Int(((end-(trackOrigin-origin))*16000).rounded())*2
            guard first>=0,last>first,last<=written else{throw Failure(code:"saved_voice_audio_missing")}
            var cursor=0,pcm=Data()
            for (index,chunk) in chunks.enumerated() {
                guard chunk["index"] as? Int==index,let bytes=chunk["bytes"] as? Int,bytes>0,bytes<=320000,bytes%2==0 else{throw Failure(code:"saved_voice_manifest_invalid")}
                let next=cursor+bytes;defer{cursor=next}
                guard next>first,cursor<last else{continue}
                let name=source+String(format:"-%06d.pcm",index),data=try readPrefix(directory.appendingPathComponent(name),bytes:bytes),hash=historicalVoiceHash(data)
                if let expected=chunk["sha256"] as? String {guard hash==expected else{throw Failure(code:"saved_voice_audio_changed")}}
                else {guard index==chunks.count-1,manifest["ended"] as? Bool==false || SpeakerRefinementArtifact.isRecoveredTranscription(manifest) else{throw Failure(code:"saved_voice_manifest_invalid")}}
                audioChecks[name]=SavedVoiceAudioCheck(bytes:bytes,sha256:hash)
                pcm.append(data[max(0,first-cursor)..<min(bytes,last-cursor)])
            }
            guard cursor==written,pcm.count==last-first else{throw Failure(code:"saved_voice_audio_missing")}
            let raw=pcm.withUnsafeBytes{buffer->[Float] in let p=buffer.bindMemory(to:UInt8.self);return stride(from:0,to:p.count,by:2).map{i in Float(Int16(bitPattern:UInt16(p[i]) | UInt16(p[i+1])<<8))/32768}}
            let peak=raw.reduce(Float(0)){max($0,abs($1))},gain=min(Float(16),max(Float(1),0.8/max(peak,0.000001))),raised=raw.map{$0*gain}
            guard raised.reduce(0.0,{$0+Double($1)*Double($1)})/Double(raised.count)>=1e-6,raw.filter({abs($0)>=0.98}).count*100<raw.count else{throw Failure(code:"saved_voice_audio_weak")}
            return raised
        }
        for key in request.keys {
            let rows=(groups[key] ?? []).sorted{($0.1["start"] as! Double)<($1.1["start"] as! Double)}
            var selected:[(String,[String:Any],Double,Double)]=[]
            for (id,item) in rows {
                let lo=item["start"] as! Double,hi=item["end"] as! Double,duration=min(3,hi-lo),start=lo+(hi-lo-duration)/2
                // The same utterance can appear on both microphone and system
                // audio after reconciliation. It is still one piece of evidence.
                guard !selected.contains(where:{$0.2<start+duration && $0.3>start}) else{continue}
                selected.append((id,item,start,start+duration))
            }
            let limit=min(request.sampleLimit ?? 8,256/request.keys.count)
            let chosen=selected.count<=limit ? selected:(0..<limit).map{selected[Int((Double($0)*Double(selected.count-1)/Double(limit-1)).rounded())]}
            for (id,item,start,end) in chosen {
                do {
                    guard let source=item["source_id"] as? String,isTranscriptAudioTrack(source),let epoch=item["epoch"] as? String else{throw Failure(code:"saved_voice_scope_invalid")}
                    let vector=try extract(snippet(source:source,start:start,end:end))
                    guard vector.count==192,vector.allSatisfy(\.isFinite),abs(vector.reduce(0,{$0+$1*$1})-1)<0.001 else{throw Failure(code:"saved_voice_vector_invalid")}
                    let sample=VoiceprintSample(session:request.session,source:source,epoch:epoch,start:start,end:end,vector:vector)
                    evidence.append(SavedVoiceRecognitionEvidence(id:id,revision:item["revision"] as? Int ?? 0,key:key,sample:sample))
                }catch {skipped+=1}
            }
        }
        let result=SavedVoiceRecognitionResult(session:request.session,partition:SpeakerEmbeddingBackend.partition,inputKind:request.inputKind,inputHashes:hashes,audioChecks:audioChecks,evidence:evidence,skipped:skipped)
        try validate(result,request:request);return result
    }
    static func run(_ request:SavedVoiceRecognitionRequest,model:URL)throws->SavedVoiceRecognitionResult {
        let backend=try SpeakerEmbeddingBackend(model:model);defer{backend.close()}
        return try run(request,extract:{try backend.extract($0,qualityOK:true,overlap:false,inputKind:request.inputKind).values.map(Double.init)})
    }
}
