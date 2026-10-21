import Foundation
import CryptoKit
import Darwin

enum HistoricalVoiceLearningError:Error,Equatable {case invalidRequest,changedConfirmation,unavailableAudio,invalidAudio,ambiguousSpeech,insufficientAudio,cancelled}
// Metadata-only UI eligibility; the extractor independently rechecks disk,
// PCM integrity and acoustic coherence before any reference can be learned.
func historicalVoiceClearSelection(_ items:[[String:Any]],session:String)->Bool {
    guard !items.isEmpty,items.count<=128 else{return false}
    var keys=Set<SessionSpeakerKey>(),hasUsableDuration=false
    for item in items {
        guard let key=SessionSpeakerKey.from(item),key.session==session,isTranscriptAudioTrack(key.source),!key.epoch.isEmpty,key.epoch.count<=160,
              (item["speaker"] as? [String:Any])?["basis"] as? String=="anonymous_cluster",
              item["final"] as? Bool==true,item["end_time_known"] as? Bool==true,
              (item["quality_flags"] as? [String] ?? []).isEmpty,
              let start=item["start"] as? Double,let end=item["end"] as? Double,start.isFinite,end.isFinite,start>=0,end>start,end<=86400 else{return false}
        keys.insert(key);if keys.count>1{return false}
        hasUsableDuration = hasUsableDuration || end-start>=2
    }
    return hasUsableDuration
}
struct HistoricalVoiceLearningRequest:Codable {
    let folder:String
    let session:String
    let confirmationID:String
    let namesSHA256:String
    let segmentIDs:[String]
    let environmentLabel:String?
    let inputKind:String
    init(folder:String,session:String,confirmationID:String,namesSHA256:String,segmentIDs:[String],environmentLabel:String?=nil,inputKind:String="consented_live_audio") {
        self.folder=folder;self.session=session;self.confirmationID=confirmationID;self.namesSHA256=namesSHA256;self.segmentIDs=segmentIDs;self.environmentLabel=environmentLabel;self.inputKind=inputKind
    }
}
struct HistoricalVoiceLearningResult:Codable {
    let partition:String
    let inputKind:String
    let confirmationID:String
    let session:String
    let namesSHA256:String
    let sourceHashes:[String:String]
    let samples:[VoiceprintSample]
}
func historicalVoiceHash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
private func historicalVoiceRead(_ file:URL,limit:Int)throws->Data {
    let info=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
    guard info.isRegularFile==true,info.isSymbolicLink != true,let size=info.fileSize,size>=0,size<=limit else{throw HistoricalVoiceLearningError.unavailableAudio}
    let data=try Data(contentsOf:file);guard data.count==size else{throw HistoricalVoiceLearningError.unavailableAudio};return data
}
func historicalVoiceValidateConfirmation(_ request:HistoricalVoiceLearningRequest)throws->[String:Any] {
    let folder=URL(fileURLWithPath:request.folder)
    guard folder.standardizedFileURL.path==request.folder,UUID(uuidString:folder.lastPathComponent) != nil,
          !request.session.isEmpty,request.session.count<=160,UUID(uuidString:request.confirmationID) != nil,
          ["synthetic_model_output","consented_live_audio"].contains(request.inputKind),
          request.namesSHA256.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,
          !request.segmentIDs.isEmpty,request.segmentIDs.count<=128,Set(request.segmentIDs).count==request.segmentIDs.count,
          request.segmentIDs.allSatisfy({!$0.isEmpty && $0.count<=256}),
          VoiceprintAcousticContext(channel:"microphone",environmentLabel:request.environmentLabel).valid,
          try folder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]).isDirectory==true,
          try folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else{throw HistoricalVoiceLearningError.invalidRequest}
    let data=try historicalVoiceRead(folder.appendingPathComponent("session-names.json"),limit:4*1024*1024)
    guard historicalVoiceHash(data)==request.namesSHA256,
          let names=try JSONSerialization.jsonObject(with:data) as? [String:Any],names["session"] as? String==request.session,
          let records=names["voiceConfirmations"] as? [[String:Any]],records.count<=128,
          let record=records.first(where:{$0["id"] as? String==request.confirmationID}),record["session"] as? String==request.session,
          let ids=record["segmentIDs"] as? [String],Set(ids)==Set(request.segmentIDs) else{throw HistoricalVoiceLearningError.changedConfirmation}
    return record
}
// Recheck every file used by extraction before committing a contribution. This
// API performs no extraction or enrollment and is safe on the service's queue.
func historicalVoiceValidateResult(_ result:HistoricalVoiceLearningResult,request:HistoricalVoiceLearningRequest)throws {
    _ = try historicalVoiceValidateConfirmation(request)
    guard result.partition==SpeakerEmbeddingBackend.partition,result.inputKind==request.inputKind,
          result.confirmationID==request.confirmationID,result.session==request.session,result.namesSHA256==request.namesSHA256,
          !result.samples.isEmpty,result.samples.count<=8,result.sourceHashes.count<=80,
          result.sourceHashes["meeting.json"] != nil else{throw HistoricalVoiceLearningError.invalidRequest}
    let root=URL(fileURLWithPath:request.folder)
    for (name,expected) in result.sourceHashes {
        guard !name.contains("/"),!name.contains("\\"),name != ".",name != "..",
              expected.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else{throw HistoricalVoiceLearningError.invalidRequest}
        let limit=name.hasSuffix(".pcm") ? 320000:32*1024*1024
        guard historicalVoiceHash(try historicalVoiceRead(root.appendingPathComponent(name),limit:limit))==expected else{throw HistoricalVoiceLearningError.unavailableAudio}
    }
}
// The injectable extractor supports offline synthetic tests. Production calls
// the overload below, which uses only the bundled local Campplus model.
func historicalVoiceSamples(request:HistoricalVoiceLearningRequest,extract:([Float])throws->[Double],cancelled:()->Bool={false})throws->HistoricalVoiceLearningResult {
    _ = try historicalVoiceValidateConfirmation(request)
    if cancelled(){throw HistoricalVoiceLearningError.cancelled}
    let root=URL(fileURLWithPath:request.folder)
    var hashes:[String:String]=[:]
    func object(_ name:String,_ limit:Int=1024*1024)throws->[String:Any] {
        let data=try historicalVoiceRead(root.appendingPathComponent(name),limit:limit);hashes[name]=historicalVoiceHash(data)
        guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw HistoricalVoiceLearningError.invalidRequest};return value
    }
    let meeting=try object("meeting.json")
    guard meeting["session"] as? String==request.session,let captureOrigin=meeting["capture_origin_uptime"] as? Double,captureOrigin.isFinite else{throw HistoricalVoiceLearningError.invalidRequest}
    if let retired=try? object("audio-retirement.json"),retired["state"] as? String=="trashed" {throw HistoricalVoiceLearningError.unavailableAudio}
    let files=try FileManager.default.contentsOfDirectory(atPath:root.path)
    let transcripts=files.filter{$0.hasSuffix("-transcript.jsonl") && isTranscriptAudioTrack(String($0.dropLast("-transcript.jsonl".count)))}
    guard !transcripts.isEmpty,transcripts.count<=16 else{throw HistoricalVoiceLearningError.unavailableAudio}
    var timeline=TranscriptTimeline();var total=0
    for file in transcripts.sorted() {
        if cancelled(){throw HistoricalVoiceLearningError.cancelled}
        let data=try historicalVoiceRead(root.appendingPathComponent(file),limit:32*1024*1024);total+=data.count
        guard total<=64*1024*1024 else{throw HistoricalVoiceLearningError.invalidRequest};hashes[file]=historicalVoiceHash(data)
        for line in data.split(separator:10) {
            guard let event=(try? JSONSerialization.jsonObject(with:Data(line))) as? [String:Any] else{throw HistoricalVoiceLearningError.invalidRequest}
            guard event["session"] as? String==request.session else{continue}
            if event["type"] as? String=="segment",event["source_id"] as? String != String(file.dropLast("-transcript.jsonl".count)) {throw HistoricalVoiceLearningError.invalidRequest}
            if event["type"] as? String=="asr_replay" {timeline.discard(Set(event["discard_segment_ids"] as? [String] ?? []))}
            else if event["type"] as? String=="segment",timeline.accepts(event) {timeline.put(event)}
        }
    }
    let wanted=Set(request.segmentIDs)
    var selections:[String:[String:Any]]=[:]
    for item in timeline.records.values {
        if let id=item["segment_id"] as? String,wanted.contains(id) {selections[id]=item}
        let runs=TranscriptTimeline.speakerRuns(item)
        for run in runs {
            guard let parent=item["segment_id"] as? String else{continue}
            let id=TranscriptTimeline.runID(parent:parent,run:run)
            if wanted.contains(id){var row=run;row["segment_id"]=id;selections[id]=row}
        }
    }
    // The saved model scope is checked even if a user edited an unknown label:
    // a human name alone cannot certify a mixed acoustic span as a clean sample.
    guard selections.count==wanted.count else{throw HistoricalVoiceLearningError.ambiguousSpeech}
    var samples:[VoiceprintSample]=[];var selectedScopes=Set<SessionSpeakerKey>()
    for id in request.segmentIDs.sorted(by:{(selections[$0]?["start"] as? Double ?? 0)<(selections[$1]?["start"] as? Double ?? 0)}) {
        if cancelled(){throw HistoricalVoiceLearningError.cancelled}
        guard let item=selections[id],let key=SessionSpeakerKey.from(item),key.session==request.session,isTranscriptAudioTrack(key.source),!key.epoch.isEmpty,key.epoch.count<=160,
              (item["speaker"] as? [String:Any])?["basis"] as? String=="anonymous_cluster",
              item["final"] as? Bool==true,item["end_time_known"] as? Bool==true,
              (item["quality_flags"] as? [String] ?? []).isEmpty,
              let start=item["start"] as? Double,let end=item["end"] as? Double,start.isFinite,end.isFinite,start>=0,end>start,end<=86400 else{throw HistoricalVoiceLearningError.ambiguousSpeech}
        selectedScopes.insert(key)
        guard selectedScopes.count<=1 else{throw HistoricalVoiceLearningError.ambiguousSpeech}
        // One independent tile per explicitly selected sentence. Do not expand
        // a single confirmed sentence to its group or to later speech.
        guard end-start>=2 else{continue}
        let duration=min(3,end-start),lo=start+(end-start-duration)/2,hi=lo+duration
        if samples.contains(where:{$0.session==key.session && $0.start<hi && $0.end>lo}) {continue}
        let manifest=try object(key.source+"-manifest.json")
        guard manifest["schema"] as? Int==1,manifest["track"] as? String==key.source,manifest["format"] as? String=="pcm_s16le",
              manifest["sample_rate"] as? Int==16000,manifest["channels"] as? Int==1,manifest["ended"] as? Bool==true,
              manifest["audio_cleaned"] as? Bool != true,!(manifest["error"] is String),
              let trackOrigin=manifest["origin_uptime"] as? Double,trackOrigin.isFinite,
              trackOrigin>=captureOrigin,trackOrigin-captureOrigin<=86400,
              let chunks=manifest["chunks"] as? [[String:Any]],chunks.count<=2000,
              let written=manifest["written_bytes"] as? Int,written>=0,written<=512*1024*1024 else{throw HistoricalVoiceLearningError.unavailableAudio}
        let offset=trackOrigin-captureOrigin
        let first=Int(((lo-offset)*16000).rounded())*2,last=Int(((hi-offset)*16000).rounded())*2
        guard first>=0,last>first,last<=written else{throw HistoricalVoiceLearningError.unavailableAudio}
        var cursor=0,pcm=Data()
        for (index,chunk) in chunks.enumerated() {
            guard chunk["index"] as? Int==index,let bytes=chunk["bytes"] as? Int,bytes>=0,bytes<=320000,bytes%2==0 else{throw HistoricalVoiceLearningError.invalidAudio}
            let next=cursor+bytes;defer{cursor=next}
            guard next>first,cursor<last else{continue}
            guard let hash=chunk["sha256"] as? String else{throw HistoricalVoiceLearningError.unavailableAudio}
            let name=key.source+String(format:"-%06d.pcm",index),data=try historicalVoiceRead(root.appendingPathComponent(key.source+String(format:"-%06d.pcm",index)),limit:320000)
            guard data.count==bytes,historicalVoiceHash(data)==hash else{throw HistoricalVoiceLearningError.invalidAudio}
            hashes[name]=hash;pcm.append(data[max(0,first-cursor)..<min(bytes,last-cursor)])
        }
        guard cursor==written,pcm.count==last-first,(64000...128000).contains(pcm.count) else{throw HistoricalVoiceLearningError.invalidAudio}
        let raw=pcm.withUnsafeBytes {buffer->[Float] in let p=buffer.bindMemory(to:UInt8.self);return stride(from:0,to:p.count,by:2).map{i in Float(Int16(bitPattern:UInt16(p[i]) | UInt16(p[i+1])<<8))/32768}}
        let peak=raw.reduce(Float(0)){max($0,abs($1))},gain=min(Float(16),max(Float(1),0.8/max(peak,0.000001)))
        let raised=raw.map{$0*gain}
        guard raised.reduce(0.0,{$0+Double($1)*Double($1)})/Double(raised.count)>=1e-6,
              raised.filter({abs($0)>=0.98}).count*100<raised.count else{throw HistoricalVoiceLearningError.insufficientAudio}
        let vector=try extract(raised)
        guard vector.count==192,vector.allSatisfy(\.isFinite),abs(vector.reduce(0,{$0+$1*$1})-1)<0.001 else{throw HistoricalVoiceLearningError.invalidAudio}
        // Device UID is optional factual metadata, hashed locally. Device IDs
        // assigned for one OS session are not stable device identities.
        let microphone=meeting["microphone_capture_diagnostics"] as? [String:Any]
        let device=(microphone?["input_device"] as? [String:Any])?["uid"] as? String
        let fingerprint=VoiceprintAcousticContext.channel(for:key.source)=="microphone" ? device.map{historicalVoiceHash(Data($0.utf8))}:nil
        let context=VoiceprintAcousticContext(channel:VoiceprintAcousticContext.channel(for:key.source),deviceFingerprint:fingerprint,environmentLabel:request.environmentLabel)
        samples.append(VoiceprintSample(session:key.session,source:key.source,epoch:key.epoch,start:lo,end:hi,vector:vector,context:context))
        if samples.count==8 {break}
    }
    guard !samples.isEmpty else{throw HistoricalVoiceLearningError.insufficientAudio}
    for i in samples.indices {for j in samples.indices where j>i {
        guard zip(samples[i].vector,samples[j].vector).reduce(0.0,{$0+$1.0*$1.1})>=0.60 else{throw HistoricalVoiceLearningError.ambiguousSpeech}
    }}
    let result=HistoricalVoiceLearningResult(partition:SpeakerEmbeddingBackend.partition,inputKind:request.inputKind,confirmationID:request.confirmationID,session:request.session,namesSHA256:request.namesSHA256,sourceHashes:hashes,samples:samples)
    try historicalVoiceValidateResult(result,request:request)
    if cancelled(){throw HistoricalVoiceLearningError.cancelled}
    return result
}
func historicalVoiceSamples(request:HistoricalVoiceLearningRequest,model:URL)throws->HistoricalVoiceLearningResult {
    _ = try historicalVoiceValidateConfirmation(request)
    let backend=try SpeakerEmbeddingBackend(model:model);defer{backend.close()}
    return try historicalVoiceSamples(request:request,extract:{samples in try backend.extract(samples,qualityOK:true,overlap:false,inputKind:request.inputKind).values.map(Double.init)})
}

// Dedicated bounded subprocess. Cancellation does not wait for inference and
// never terminates the capture helper or any process owned by another task.
final class HistoricalVoiceLearningWorker {
    private let queue=DispatchQueue(label:"meeting.voiceprint.historical-extraction",qos:.utility)
    private let lock=NSLock()
    private var generation=UUID()
    private var process:Process?
    // Capture the exact owned Process. Cleanup remains valid after its token is
    // invalidated; it never discovers or signals another job by name.
    private static func stop(_ child:Process) {
        guard child.isRunning else{return}
        let pid=child.processIdentifier
        child.terminate()
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+1) {
            guard child.isRunning,child.processIdentifier==pid,pid>0 else{return}
            _ = Darwin.kill(pid,SIGKILL)
        }
    }
    func cancel() {
        lock.lock();generation=UUID();let previous=process;process=nil;lock.unlock()
        if let previous {Self.stop(previous)}
    }
    func reserve()->UUID {cancel();let token=UUID();lock.lock();generation=token;lock.unlock();return token}
    func isCurrent(_ token:UUID)->Bool {lock.lock();defer{lock.unlock()};return generation==token}
    func commitIfCurrent(_ token:UUID,_ replace:()throws->Void)throws {
        lock.lock();defer{lock.unlock()}
        guard generation==token else{throw HistoricalVoiceLearningError.cancelled}
        try replace()
    }
    @discardableResult func start(request:HistoricalVoiceLearningRequest,executable:URL,model:URL,
        reservedToken:UUID?=nil,done:@escaping(UUID,Result<HistoricalVoiceLearningResult,Error>)->Void)->UUID {
        let token=reservedToken ?? reserve()
        queue.async {
            do {
                guard self.isCurrent(token) else{throw HistoricalVoiceLearningError.cancelled}
                _ = try historicalVoiceValidateConfirmation(request)
                let input=try JSONEncoder().encode(request);guard input.count<=65536 else{throw HistoricalVoiceLearningError.invalidRequest}
                let child=Process(),output=Pipe(),stdin=Pipe();child.executableURL=executable
                child.arguments=["--historical-voice-samples",model.path];child.standardOutput=output;child.standardError=FileHandle.nullDevice;child.standardInput=stdin;child.qualityOfService = .utility
                self.lock.lock()
                guard self.generation==token else{self.lock.unlock();throw HistoricalVoiceLearningError.cancelled}
                self.process=child
                do {try child.run();self.lock.unlock()}catch{self.process=nil;self.lock.unlock();throw error}
                // Every post-launch exit, including pipe errors and bounded
                // output rejection, closes/reaps this child before the next job.
                defer {
                    Self.stop(child)
                    try? stdin.fileHandleForWriting.close()
                    child.waitUntilExit()
                    try? output.fileHandleForReading.close()
                }
                DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+90) { [weak child] in
                    guard let child else{return};Self.stop(child)
                }
                try stdin.fileHandleForWriting.write(contentsOf:input+Data([10]));try stdin.fileHandleForWriting.close()
                var data=Data()
                while true {
                    let chunk=try output.fileHandleForReading.read(upToCount:16384) ?? Data();if chunk.isEmpty{break}
                    data.append(chunk);if data.count>512*1024 {throw HistoricalVoiceLearningError.invalidRequest}
                }
                child.waitUntilExit()
                guard self.isCurrent(token) else{throw HistoricalVoiceLearningError.cancelled}
                guard child.terminationStatus==0 else{throw HistoricalVoiceLearningError.unavailableAudio}
                let result=try JSONDecoder().decode(HistoricalVoiceLearningResult.self,from:data)
                try historicalVoiceValidateResult(result,request:request)
                guard self.isCurrent(token) else{throw HistoricalVoiceLearningError.cancelled}
                done(token,.success(result))
            }catch{done(token,.failure(error))}
            self.lock.lock();if self.generation==token {self.process=nil};self.lock.unlock()
        }
        return token
    }
    deinit {cancel()}
}
