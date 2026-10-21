import Foundation

struct SpeakerRefinementRequest:Codable {
    let folder:String
    let session:String
    let allow_unsealed:Bool
}

// A second local pass owns no recording device, ASR connection, identity store,
// or cache writer. It returns a reversible candidate for the UI's commit gate.
enum SpeakerRefinement {
    static func read(_ file:URL,limit:Int)throws->Data {
        let attrs=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard attrs.isRegularFile==true,attrs.isSymbolicLink != true,let count=attrs.fileSize,count>=0,count<=limit else{throw Failure(code:"refinement_file_invalid")}
        let data=try Data(contentsOf:file)
        guard data.count==count else{throw Failure(code:"refinement_source_changed")}
        return data
    }
    static func object(_ file:URL,limit:Int=4*1024*1024)throws->[String:Any] {
        guard let result=try JSONSerialization.jsonObject(with:read(file,limit:limit)) as? [String:Any] else{throw Failure(code:"refinement_file_invalid")}
        return result
    }
    static func units(_ event:[String:Any])->[[String:Any]] {
        let runs=event["speaker_runs"] as? [[String:Any]] ?? []
        return runs.isEmpty ? [event]:runs
    }
    static func knownSlot(_ row:[String:Any])->Int? {
        let s=row["speaker"] as? [String:Any] ?? [:]
        guard s["basis"] as? String=="anonymous_cluster",s["contextual_fill"] as? Bool != true,
              let slot=s["cluster_id"] as? Int,(0..<8).contains(slot) else{return nil}
        return slot
    }
    // Map new-model voices back to existing meeting identities. Multiple new
    // slots may correspond to one existing voice; a new slot cannot merge two
    // existing voices. Independent utterance anchors prevent self-propagation.
    static func mapping(events:[[String:Any]],timeline:SpeakerTimeline,source:String,epoch:String)->[Int:Int] {
        var weights:[Int:[Int:Double]]=[:],parents:[Int:[Int:Set<String>]]=[:]
        let anchors=events.flatMap {event -> [(String,[String:Any])] in
            guard event["final"] as? Bool==true,event["end_time_known"] as? Bool==true,
                  event["source_id"] as? String==source,event["epoch"] as? String==epoch,
                  (event["quality_flags"] as? [String] ?? []).isEmpty,let id=event["segment_id"] as? String else{return []}
            return units(event).map{(id,$0)}
        }.sorted{($0.1["start"] as? Double ?? 0)<($1.1["start"] as? Double ?? 0)}
        var previousEnd = -1.0
        for (id,row) in anchors {
            guard let old=knownSlot(row),let start=row["start"] as? Double,let end=row["end"] as? Double,
                  start.isFinite,end.isFinite,end-start>=0.4,start>=previousEnd-0.001 else{continue}
            previousEnd=end
            for (fresh,seconds) in timeline.soloEvidence(start:start,end:end,source:source,epoch:epoch) where seconds>=0.2 {
                weights[fresh,default:[:]][old,default:0]+=seconds
                parents[fresh,default:[:]][old,default:[]].insert(id)
            }
        }
        var result:[Int:Int]=[:]
        for (fresh,candidates) in weights {
            let sorted=candidates.sorted{$0.value>$1.value}
            guard let best=sorted.first else{continue}
            let total=candidates.values.reduce(0,+),opposition=total-best.value
            guard best.value>=1.5,best.value/total>=0.9,opposition<=0.2,
                  (parents[fresh]?[best.key]?.count ?? 0)>=2 else{continue}
            result[fresh]=best.key
        }
        return result
    }
    static func corrections(events:[[String:Any]],timeline:SpeakerTimeline,source:String,epoch:String,protectedIDs:Set<String>=[])throws->[[String:Any]] {
        let slots=mapping(events:events,timeline:timeline,source:source,epoch:epoch)
        guard !slots.isEmpty else{return []}
        var records:[[String:Any]]=[]
        for event in events {
            guard event["final"] as? Bool==true,event["end_time_known"] as? Bool==true,
                  event["source_id"] as? String==source,event["epoch"] as? String==epoch,
                  (event["quality_flags"] as? [String] ?? []).isEmpty,
                  let id=event["segment_id"] as? String,!protectedIDs.contains(id) else{continue}
            var fresh=event
            fresh["speaker"]=timeline.join(event,source:source,epoch:epoch)
            timeline.annotateWords(&fresh,source:source,epoch:epoch)
            let newUnits=units(fresh)
            var oldUnits=units(event),changed=false
            for index in oldUnits.indices {
                let prior=oldUnits[index],who=prior["speaker"] as? [String:Any] ?? [:]
                // True simultaneous speech remains a separate review category.
                guard who["basis"] as? String=="unknown",let lo=prior["start"] as? Double,
                      let hi=prior["end"] as? Double,hi>lo,
                      lo>=(timeline.firstFrameStart ?? .infinity)-0.000001,hi<=(timeline.lastFrameEnd ?? -.infinity)+0.000001 else{continue}
                let runID=id+":word:"+String(Int((lo*1000).rounded()))
                guard !protectedIDs.contains(runID) else{continue}
                let matches=newUnits.filter{($0["start"] as? Double ?? .infinity)<hi-0.000001 && ($0["end"] as? Double ?? -.infinity)>lo+0.000001}.sorted{($0["start"] as? Double ?? 0)<($1["start"] as? Double ?? 0)}
                var cursor=lo,mapped=Set<Int>(),valid = !matches.isEmpty
                for row in matches {
                    let speaker=row["speaker"] as? [String:Any] ?? [:]
                    guard speaker["basis"] as? String=="anonymous_cluster",let freshSlot=speaker["cluster_id"] as? Int,
                          let oldSlot=slots[freshSlot],let start=row["start"] as? Double,let end=row["end"] as? Double,
                          start<=cursor+0.001,end>cursor else{valid=false;break}
                    cursor=max(cursor,min(hi,end));mapped.insert(oldSlot)
                }
                guard valid,cursor>=hi-0.001,mapped.count==1,let slot=mapped.first else{continue}
                oldUnits[index]["speaker"]=["basis":"anonymous_cluster","cluster_id":slot,"source_id":source,"epoch":epoch]
                changed=true
            }
            guard changed else{continue}
            let parentSpeaker=oldUnits.count==1 ? oldUnits[0]["speaker"] ?? [:]:event["speaker"] ?? [:]
            records.append(["segment_id":id,"original_sha256":try SpeakerRefinementArtifact.originalEventSHA256(event),"speaker":parentSpeaker,"speaker_runs":(event["speaker_runs"] as? [[String:Any]] ?? []).isEmpty ? []:oldUnits])
        }
        return records
    }
    static func run(request:SpeakerRefinementRequest,models:URL) async throws->[String:Any] {
        // Pinned, bundled assets only; this command never fetches a model.
        let offlineModels=models.appendingPathComponent("community-1",isDirectory:true)
        let expected:[String:String]=[
            "Embedding.mlmodelc/analytics/coremldata.bin":"8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682",
            "Embedding.mlmodelc/coremldata.bin":"4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004",
            "Embedding.mlmodelc/metadata.json":"1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5",
            "Embedding.mlmodelc/model.mil":"22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3",
            "Embedding.mlmodelc/weights/weight.bin":"99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b",
            "FBank.mlmodelc/analytics/coremldata.bin":"0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a",
            "FBank.mlmodelc/coremldata.bin":"57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759",
            "FBank.mlmodelc/metadata.json":"2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a",
            "FBank.mlmodelc/model.mil":"27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed",
            "FBank.mlmodelc/weights/weight.bin":"9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36",
            "PldaRho.mlmodelc/analytics/coremldata.bin":"8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7",
            "PldaRho.mlmodelc/coremldata.bin":"4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418",
            "PldaRho.mlmodelc/metadata.json":"b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945",
            "PldaRho.mlmodelc/model.mil":"83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041",
            "PldaRho.mlmodelc/weights/weight.bin":"80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36",
            "Segmentation.mlmodelc/analytics/coremldata.bin":"64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb",
            "Segmentation.mlmodelc/coremldata.bin":"ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc",
            "Segmentation.mlmodelc/metadata.json":"88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124",
            "Segmentation.mlmodelc/model.mil":"d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f",
            "Segmentation.mlmodelc/weights/weight.bin":"c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2",
            "plda-parameters.json":"38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f"]
        for (name,hash) in expected {
            guard MeetingSpeakerReconciliation.hash(try read(offlineModels.appendingPathComponent(name),limit:32*1024*1024))==hash else{throw Failure(code:"refinement_model_invalid")}
        }
        let directory=URL(fileURLWithPath:request.folder),cacheID=directory.lastPathComponent
        guard directory.standardizedFileURL.path==request.folder,directory.resolvingSymlinksInPath().path==request.folder,
              UUID(uuidString:cacheID) != nil,!request.session.isEmpty,request.session.count<=160 else{throw Failure(code:"refinement_scope_invalid")}
        let snapshot=try SpeakerRefinementArtifact.snapshotSHA256(directory:directory,cacheID:cacheID)
        let meta=try object(directory.appendingPathComponent("meeting.json"))
        guard meta["session"] as? String==request.session,let origin=meta["capture_origin_uptime"] as? Double,origin.isFinite else{throw Failure(code:"refinement_scope_invalid")}
        if let retired=try? object(directory.appendingPathComponent("audio-retirement.json")),retired["state"] as? String=="trashed" {throw Failure(code:"refinement_audio_missing")}
        let tracks=try meetingAudioTracks(in:directory)
        guard !tracks.isEmpty,tracks.count<=16 else{throw Failure(code:"refinement_capacity")}
        let item=CachedMeeting(id:cacheID,directory:directory,date:Date(),writtenBytes:0,pendingBytes:0,occupiedBytes:0,tracks:tracks,audioCleaned:false,warning:false,retiredBytes:0)
        let hashes=try item.transcriptHashes(),events=try item.events(includeAutomaticRefinement:false)
        guard !events.isEmpty,events.allSatisfy({$0["session"] as? String==request.session}) else{throw Failure(code:"refinement_scope_invalid")}
        let namesFile=directory.appendingPathComponent("session-names.json")
        func namesHash()throws->String {
            guard FileManager.default.fileExists(atPath:namesFile.path) else{return ""}
            return MeetingSpeakerReconciliation.hash(try read(namesFile,limit:4*1024*1024))
        }
        let namesSnapshot=try namesHash()
        let protected=try SpeakerRefinementArtifact.protectedIDs(directory:directory,session:request.session,events:events)
        let alignmentEvents=try SpeakerRefinementArtifact.alignmentEvents(directory:directory,session:request.session,events:events)
        var records:[[String:Any]]=[]
        let backend=OfflineSpeakerBackend(modelsDirectory:offlineModels)
        for source in tracks {
            let sourceEvents=events.filter{$0["source_id"] as? String==source}
            let epochs=Set(sourceEvents.compactMap{$0["epoch"] as? String})
            guard !sourceEvents.isEmpty else{continue}
            guard epochs.count==1,let epoch=epochs.first,!epoch.isEmpty,epoch.count<=160 else{continue}
            let manifest=try object(directory.appendingPathComponent(source+"-manifest.json"))
            guard manifest["schema"] as? Int==1,manifest["track"] as? String==source,manifest["format"] as? String=="pcm_s16le",
                  manifest["sample_rate"] as? Int==16000,manifest["channels"] as? Int==1,manifest["audio_cleaned"] as? Bool != true,
                  manifest["ended"] as? Bool==true || request.allow_unsealed,
                  let trackOrigin=manifest["origin_uptime"] as? Double,trackOrigin.isFinite,abs(trackOrigin-origin)<=86400,
                  let chunks=manifest["chunks"] as? [[String:Any]],chunks.count<=2000,
                  let written=manifest["written_bytes"] as? Int,written>0,written<=230400000,written%2==0 else{throw Failure(code:"refinement_audio_invalid")}
            var samples:[Float]=[]
            samples.reserveCapacity(written/2)
            var cursor=0
            for (index,chunk) in chunks.enumerated() {
                guard chunk["index"] as? Int==index,chunk["start_sample"] as? Int==cursor/2,
                      let count=chunk["bytes"] as? Int,count>=0,count<=320000,count%2==0 else{throw Failure(code:"refinement_audio_invalid")}
                let file=directory.appendingPathComponent(source+String(format:"-%06d.pcm",index))
                let pcm=try read(file,limit:320000)
                guard pcm.count==count else{throw Failure(code:"refinement_source_changed")}
                if let hash=chunk["sha256"] as? String {guard MeetingSpeakerReconciliation.hash(pcm)==hash else{throw Failure(code:"refinement_source_changed")}}
                else {
                    // An interrupted final chunk was never sealed by capture.
                    // Recovery has verified its saved byte count; accept only
                    // that final chunk after all saved audio was transcribed.
                    let recoveredTail=SpeakerRefinementArtifact.isRecoveredTranscription(manifest)
                    guard chunk["sha256"]==nil,index==chunks.count-1,
                          (request.allow_unsealed && manifest["ended"] as? Bool==false) || recoveredTail else{throw Failure(code:"refinement_audio_invalid")}
                }
                pcm.withUnsafeBytes { buffer in
                    for value in buffer.bindMemory(to:Int16.self) {samples.append(Float(Int16(littleEndian:value))/32768)}
                }
                cursor+=count
            }
            guard cursor==written else{throw Failure(code:"refinement_source_changed")}
            let segments=try await backend.diarize(samples:samples)
            let timeline=WholeMeetingSpeakerTimeline(segments:segments,origin:max(0,trackOrigin-origin),duration:Double(samples.count)/16000)
            records+=try WholeMeetingSpeakerRefinement.corrections(events:sourceEvents,timeline:timeline,source:source,epoch:epoch,protectedIDs:protected,alignmentEvents:alignmentEvents)
        }
        guard try namesHash()==namesSnapshot,try item.transcriptHashes()==hashes,try SpeakerRefinementArtifact.snapshotSHA256(directory:directory,cacheID:cacheID)==snapshot else{throw Failure(code:"refinement_source_changed")}
        let previous=SpeakerRefinementArtifact.loadApply(events:events,sourceHashes:hashes,directory:directory,cacheID:cacheID)
        records=try WholeMeetingSpeakerRefinement.preservingRecoveries(originals:events,previous:previous,records:records)
        let result:[String:Any]=["schema":1,"method":SpeakerRefinementArtifact.offlineMethod,"model":SpeakerRefinementArtifact.offlineModel,"cache_id":cacheID,"session":request.session,"source_sha256":hashes,"snapshot_sha256":snapshot,"records":records]
        _=try SpeakerRefinementArtifact.validateApply(object:result,events:events,sourceHashes:hashes,directory:directory,cacheID:cacheID)
        return result
    }
}
