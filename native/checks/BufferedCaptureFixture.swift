import Foundation
import CryptoKit
func replayEmit(_ event:[String:Any]){if let data=try? JSONSerialization.data(withJSONObject:event,options:[.sortedKeys]){FileHandle.standardOutput.write(data+Data([10]))}}

// Predetermined licensed public PCM, not a device capture or cloud-ASR quality test.
// Uses the actual production fanout mailbox and actual pinned speaker pipeline.
final class PublicReplayProducer {
    let queue=DispatchQueue(label:"meeting.public-replay.source");let data:Data;let transport:Mailbox;let model:Mailbox;let start:Double
    var position=0;var timer:DispatchSourceTimer?;var coalesced=0;var unoffered=0
    init(data:Data,transport:Mailbox,model:Mailbox,start:Double){self.data=data;self.transport=transport;self.model=model;self.start=start}
    func begin(){let timer=DispatchSource.makeTimerSource(queue:queue);self.timer=timer;timer.schedule(deadline:.now(),repeating:.milliseconds(100),leeway:.milliseconds(1));timer.setEventHandler{[self] in
        let due=max(1,Int(self.timer?.data ?? 1));coalesced+=max(0,due-1)
        guard due<=20 else{unoffered+=due;transport.fail("fixture_source_scheduling_gap");model.fail("fixture_source_scheduling_gap");self.timer?.cancel();return}
        for _ in 0..<due {guard position<data.count else{transport.seal();model.seal();self.timer?.cancel();return};let end=min(data.count,position+3200);transport.put(Data(data[position..<end]),at:start+Double(position)/32000);position=end}
    };timer.resume()}
    func stop(){timer?.cancel();queue.sync{};timer?.setEventHandler{};timer=nil}
    func evidence()->[String:Any]{queue.sync{return ["offered_bytes":position,"coalesced_due_ticks_preserved":coalesced,"unoffered_due_ticks":unoffered]}}
}
actor ReplayStats {
    var annotations:[String:[String:Any]]=[:];var transportData=Data();var modelBytes=0;var modelSeconds=0.0;var readyAt:Double?;var caughtAt:Double?
    var firstTransportAt:Double?;var firstUnknown=true
    func transport(_ data:Data,at:Double){transportData.append(data);if firstTransportAt==nil{firstTransportAt=at}}
    func model(_ data:Data,seconds:Double,caught:Bool,at:Double){modelBytes+=data.count;modelSeconds+=seconds;if caught && caughtAt==nil{caughtAt=at}}
    func ready(_ at:Double){readyAt=at}
    func annotation(_ event:[String:Any]){guard let id=event["segment_id"] as? String else{return};let revision=event["revision"] as? Int ?? 0;if revision<(annotations[id]?["revision"] as? Int ?? 0){return};annotations[id]=["revision":revision,"speaker":event["speaker"] ?? [:]]}
    func snapshot()->[String:Any]{["transport_bytes":transportData.count,"transport_sha256":SHA256.hash(data:transportData).map{String(format:"%02x",$0)}.joined(),"model_bytes":modelBytes,"model_ingest_seconds":modelSeconds,"model_ready_seconds":readyAt.map{$0 as Any} ?? NSNull(),"caught_up_seconds":caughtAt.map{$0 as Any} ?? NSNull(),"first_transport_seconds":firstTransportAt.map{$0 as Any} ?? NSNull(),"annotations":annotations]}
}
func bufferedCaptureFixture(directory:URL,fixture:URL,delay:Double) async throws->[String:Any] {
    guard [0.0,3.0,30.0].contains(delay) else{throw Failure(code:"invalid_fixture_delay")}
    let raw=try Data(contentsOf:fixture.appendingPathComponent("input.pcm"));guard !raw.isEmpty,raw.count<=2*1024*1024,raw.count%2==0 else{throw Failure(code:"invalid_fixture_pcm")}
    let reference=try JSONSerialization.jsonObject(with:Data(contentsOf:fixture.appendingPathComponent("reference.json"))) as! [String:Any]
    var input=raw;var turns=reference["turns"] as! [[String:Any]]
    // Longer than startup delay: prove catching up while new source frames arrive.
    if delay==30 {input.append(raw);let duration=Double(raw.count)/32000;turns+=turns.map{original in var turn=original;turn["start"]=(turn["start"] as! Double)+duration;turn["end"]=(turn["end"] as! Double)+duration;return turn}}
    let start=ProcessInfo.processInfo.systemUptime;let clock=CaptureBudgetClock();let journal=try RecordingJournal(directory:fixture.appendingPathComponent("journal-replay-"+UUID().uuidString),track:"mic");let model=Mailbox(journal:journal,producer:false)
    let transport=Mailbox(captureClock:clock,totalByteLimit:input.count,journal:journal)
    let producer=PublicReplayProducer(data:input,transport:transport,model:model,start:start);let stats=ReplayStats();let pipeline=SpeakerPipeline(source:"mic",epoch:"buffered-public")
    producer.begin()
    let modelTask=Task {
        try await Task.sleep(nanoseconds:UInt64(delay*1e9));try await pipeline.load(directory:directory);await stats.ready(ProcessInfo.processInfo.systemUptime-start)
        while true {
            if let (packet,stamp)=try model.takePacket(now:ProcessInfo.processInfo.systemUptime,flush:model.isSealed()) {
                let began=ProcessInfo.processInfo.systemUptime;let updates=try await pipeline.ingest(packet,captureOrigin:stamp-start)
                for event in updates {await stats.annotation(event)}
                await stats.model(packet,seconds:ProcessInfo.processInfo.systemUptime-began,caught:!model.isSealed() && (model.metrics()["queued_bytes"] as! Int)<=3200,at:ProcessInfo.processInfo.systemUptime-start)
            } else if model.isSealed(){break}else{try await Task.sleep(nanoseconds:2_000_000)}
        }
    }
    var consumed=0;var nextTurn=0;var lastProgress=0.0
    do {
        while true {
            if let (packet,stamp)=try transport.takePacket(now:ProcessInfo.processInfo.systemUptime,flush:transport.isSealed()) {
                consumed+=packet.count;await stats.transport(packet,at:ProcessInfo.processInfo.systemUptime-start)
                while nextTurn<turns.count,(turns[nextTurn]["end"] as! Double)<=Double(consumed)/32000+1e-7 {
                    let turn=turns[nextTurn];let item:[String:Any]=["type":"segment","session":"buffered-public","segment_id":"turn-\(nextTurn)","revision":1,"track":"mic","source_id":"mic","epoch":"buffered-public","start":turn["start"]!,"end":turn["end"]!,"end_time_known":true,"text":"离线占位文本","final":true,"received_at":stamp-start]
                    await stats.annotation(await pipeline.accept(item));nextTurn+=1
                }
            } else if transport.isSealed(){break}else{try await Task.sleep(nanoseconds:2_000_000)}
            let elapsed=ProcessInfo.processInfo.systemUptime-start
            if elapsed-lastProgress>=15 {lastProgress=elapsed;replayEmit(["type":"buffer_replay_progress","elapsed_seconds":elapsed,"transport_bytes":consumed,"model_backlog_seconds":model.metrics()["buffered_audio_seconds"]!,"capture":false,"network":false])}
        }
        try await modelTask.value
        for event in try await pipeline.close(flush:true){await stats.annotation(event)}
    } catch {producer.stop();modelTask.cancel();_ = try? await pipeline.close(flush:false);transport.clear();model.clear();throw error}
    producer.stop();let source=producer.evidence();transport.clear();model.clear();var result=await stats.snapshot()
    let expected=SHA256.hash(data:input).map{String(format:"%02x",$0)}.joined();let seconds=Double(input.count)/32000
    precondition(result["transport_sha256"] as? String==expected && result["transport_bytes"] as? Int==input.count && result["model_bytes"] as? Int==input.count)
    precondition(transport.metrics()["discarded_bytes"] as? Int==0 && model.metrics()["discarded_bytes"] as? Int==0)
    result.merge(["type":"buffered_public_speech_replay","input_seconds":seconds,"artificial_model_delay_seconds":delay,"same_pcm_hash_verified":true,"source":source,"transport":transport.metrics(),"model_queue":model.metrics(),"model_active_rtf":(result["model_ingest_seconds"] as! Double)/seconds,"capture":false,"network":false,"mock_asr":true,"real_speaker_model":true,"raw_user_audio_saved":false,"embeddings_saved":false,"natural_chinese_meeting_verified":false,"forced_cold_cache":false,"cloud_catchup_rate_verified":false,"word_text_accuracy_verified":false,"wall_seconds":ProcessInfo.processInfo.systemUptime-start]){_,new in new}
    return result
}
