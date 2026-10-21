import Foundation
import AppKit
import Darwin

// Independent analogue of native capture callbacks; UI/model consumer cannot stall production.
final class FixtureProducer {
    let lock=NSLock()
    let queue=DispatchQueue(label:"meeting.fixture.producer",qos:.userInitiated)
    let start:Double
    var timer:DispatchSourceTimer?
    var boxes:[Mailbox]=[]
    var last:Double?
    var lags:[Double]=[]
    var gaps:[[String:Any]]=[]
    init(start:Double){self.start=start}
    func begin(_ newBoxes:[Mailbox]) {
        lock.lock();boxes=newBoxes;last=nil;lock.unlock()
        let source=DispatchSource.makeTimerSource(queue:queue)
        source.schedule(deadline:.now(),repeating:.milliseconds(100),leeway:.milliseconds(1))
        source.setEventHandler{[self] in
            let now=ProcessInfo.processInfo.systemUptime-start
            lock.lock();let current=boxes
            if let previous=last {let lag=max(0,now-previous-0.1);lags.append(lag);if lag>0.15 {gaps.append(["type":"coverage_gap","reason":"synthetic_producer_deadline_missed","start":previous+0.1,"end":now,"sources":["remote","mic"]])}}
            last=now;lock.unlock()
            let tick=Int(now*10)
            for lane in 0..<current.count {
                let voiced=(tick/50+lane)%3 != 2;let frequency=lane==0 ? 440.0 : 660.0
                var packet=Data(capacity:3200)
                for sample in 0..<1600 {let v=voiced ? Int16(1200*sin(2*Double.pi*frequency*Double(tick*1600+sample)/16000)) : Int16(0);let b=UInt16(bitPattern:v);packet.append(UInt8(b&255));packet.append(UInt8(b>>8))}
                current[lane].put(packet,at:now+Double(lane)*0.025)
            }
        }
        timer=source;source.resume()
    }
    func stop(){timer?.cancel();timer=nil;queue.sync{};lock.lock();boxes=[];last=nil;lock.unlock()}
    func evidence()->([Double],[[String:Any]]){lock.lock();defer{lock.unlock()};return(lags,gaps)}
}

// Real wall-clock simulation. No audio devices, sockets, Keychain or persistent profiles.
@MainActor func wallClockFixture(directory:URL,targetSeconds:Double=1800) async throws->[String:Any] {
    _ = NSApplication.shared
    let view=Delegate();view.mock=true;view.heading=NSTextField(labelWithString:"");view.source=NSTextField(labelWithString:"");view.action=ImmediateButton();view.meter=NSTextField(labelWithString:"");view.empty=NSTextField(labelWithString:"");view.diagnostic=NSTextField(labelWithString:"");view.latest=NSButton();view.scroll=NSScrollView(frame:NSRect(x:0,y:0,width:600,height:400));view.output=NSTextView(frame:NSRect(x:0,y:0,width:600,height:1000));view.scroll.documentView=view.output
    let embedding=directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("local-embedding-install/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")
    var epoch=0;var pipelines:[SpeakerPipeline]=[];var boxes:[Mailbox]=[];var decoders:[Decoder]=[];var counts=[0,0];var origins=[Double?](repeating:nil,count:2)
    var released=0;var gaps:[[String:Any]]=[];var totalPackets=[0,0];var revisions=0;var finals=0;var names=0;var highFrames=0;var highPCM=0;var highSegments=0;var highDecodeKeys=0;var highQueue=0;var rss:rusage=rusage();var rssSamples:[[String:Any]]=[]
    let start=ProcessInfo.processInfo.systemUptime
    let producer=FixtureProducer(start:start)
    func release() async throws {
        producer.stop()
        for p in pipelines {_ = try await p.close(flush:false);let s=await p.status();precondition(s["retained_frames"] as? Int==0 && s["retained_pcm_samples"] as? Int==0 && s["retained_segments"] as? Int==0 && s["embedding_loaded"] as? Bool==false);released+=1}
        for box in boxes {box.clear();precondition(box.metrics()["queued_bytes"] as? Int==0)}
    }
    func restart() async throws {
        pipelines=[];boxes=[Mailbox(),Mailbox()];decoders=[Decoder(),Decoder()];counts=[0,0];origins=[nil,nil];epoch+=1
        for track in ["remote","mic"] {let p=SpeakerPipeline(source:track,epoch:"wall-\(epoch)-\(track)",syntheticInput:true);try await p.load(directory:directory,embeddingModel:embedding);pipelines.append(p)}
        producer.begin(boxes)
        view.receive(["type":"started","session":"wall"])
    }
    try await restart()
    var tick=Int((ProcessInfo.processInfo.systemUptime-start)*10);var lastProgress=0;var shortPauseDone=false;var pressureDone=false;var userStopDone=false;var shortPauseEnd:Double?;var pressureStart:Double?;var scheduleLags:[Double]=[]
    let pauseAt=targetSeconds<1800 ? 5.0 : 60.0;let pressureAt=targetSeconds<1800 ? 10.0 : 180.0;let restartAt=targetSeconds<1800 ? 30.0 : 900.0;let progressEvery=targetSeconds<1800 ? 10 : 60
    while ProcessInfo.processInfo.systemUptime-start<targetSeconds {
        let loopStart=ProcessInfo.processInfo.systemUptime;let delay=0.05
        if delay>0 {try await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))}
        let elapsed=ProcessInfo.processInfo.systemUptime-start;if elapsed>=targetSeconds {break};scheduleLags.append(max(0,elapsed-loopStart-0.05))
        if elapsed>=pauseAt && !shortPauseDone {shortPauseDone=true;shortPauseEnd=elapsed+0.7}
        if elapsed>=pressureAt && !pressureDone {pressureDone=true;pressureStart=elapsed}
        if elapsed>=restartAt && !userStopDone {
            userStopDone=true;view.receive(["type":"stopped","reason":"user_stop"]);try await release();let before=elapsed;try await restart();let after=ProcessInfo.processInfo.systemUptime-start;gaps.append(["type":"coverage_gap","reason":"simulated_user_stop_and_restart","start":before,"end":after,"sources":["remote","mic"]]);tick=Int(after*10);continue
        }
        let holding=(shortPauseEnd.map{elapsed<$0} ?? false) || (pressureStart.map{elapsed<$0+2.3} ?? false)
        var fault=false
        for box in boxes {do {try box.checkFault()}catch let error as Failure {precondition(error.code=="audio_backpressure");fault=true};highQueue=max(highQueue,box.metrics()["max_queued_bytes"] as? Int ?? 0)}
        if fault {
            precondition(boxes.allSatisfy{$0.metrics()["coverage_gap"] as? Bool==true});view.receive(["type":"stopped","reason":"audio_backpressure"])
            gaps.append(["type":"coverage_gap","reason":pressureStart != nil ? "simulated_backpressure" : "actual_consumer_backpressure","start":pressureStart ?? elapsed ,"end":elapsed,"discarded_bytes":boxes.map{$0.metrics()["discarded_bytes"] as! Int},"sources":["remote","mic"]]);pressureStart=nil;try await release();try await restart();tick=Int((ProcessInfo.processInfo.systemUptime-start)*10);continue
        }
        if !holding {
            for lane in 0..<2 {
                while let (packet,stamp)=try boxes[lane].takePacket(now:elapsed) {
                    if origins[lane]==nil {origins[lane]=stamp}
                    for event in try await pipelines[lane].ingest(packet,captureOrigin:stamp) {view.receive(event)}
                    counts[lane]+=1;totalPackets[lane]+=1
                    let mod=counts[lane]%20
                    if [5,10,19].contains(mod) {
                        let track=lane==0 ? "remote" : "mic";let task="wall-\(epoch)-\(track)";let sid=counts[lane]/20+1;let begin=Double((counts[lane]/20)*2000)
                        var sentence:[String:Any]=["sentence_id":sid,"begin_time":begin,"sentence_end":mod==19,"text":mod==5 ? "模拟初稿" : mod==10 ? "模拟修订稿" : "模拟最终文字"]
                        if mod==19 {sentence["end_time"]=Double(counts[lane]*100)}
                        let response:[String:Any]=["header":["task_id":task,"event":"result-generated"],"payload":["output":["sentence":sentence]]]
                        if let asr=try decoders[lane].decode(response,task:task,track:track,session:"wall",bundle:"synthetic",origin:origins[lane]!,received:elapsed) {
                            let event=await pipelines[lane].accept(asr);view.receive(event);let id=event["segment_id"] as! String
                            precondition(abs((event["start"] as! Double)-(origins[lane]!+begin/1000))<1e-6)
                            if mod==5 {view.naming.set(segment:id,name:lane==0 ? "合成人物A" : "合成人物B");names+=1}
                            if mod==10 {view.naming.set(segment:id,name:"合成人物纠正");view.renderText();view.undoName();precondition(view.naming.values[id]==(lane==0 ? "合成人物A" : "合成人物B"));revisions+=1}
                            if mod==19 {finals+=1}
                        }
                    }
                }
            }
        }
        if Int(elapsed)>=lastProgress+progressEvery {
            lastProgress=Int(elapsed);getrusage(RUSAGE_SELF,&rss);rssSamples.append(["elapsed_seconds":elapsed,"max_rss_bytes":Int(rss.ru_maxrss)])
            for (index,p) in pipelines.enumerated() {let s=await p.status();highFrames=max(highFrames,s["retained_frames"] as! Int);highPCM=max(highPCM,s["retained_pcm_samples"] as! Int);highSegments=max(highSegments,s["retained_segments"] as! Int);highDecodeKeys=max(highDecodeKeys,decoders[index].payloads.count);precondition(highFrames<=720000 && highPCM<=96000 && highSegments<=4096 && highDecodeKeys<=200)}
            precondition(view.segments.count<=200 && view.naming.values.count<=200 && view.profileStore==nil && view.balanceCredentials==nil && !view.identityCandidatesEnabled)
            print("wall_clock_progress_seconds=\(lastProgress) packets=\(totalPackets) max_rss=\(rss.ru_maxrss)");fflush(stdout)
        }
        tick+=1
    }
    try await release();view.receive(["type":"stopped","reason":"user_stop"]);precondition(view.profileStore==nil && view.identitySnapshot==nil)
    let producerEvidence=producer.evidence();gaps.append(contentsOf:producerEvidence.1);let producerSorted=producerEvidence.0.sorted()
    let sorted=scheduleLags.sorted();getrusage(RUSAGE_SELF,&rss)
    return ["type":"wall_clock_dual_synthetic_validation","wall_seconds":ProcessInfo.processInfo.systemUptime-start,"target_wall_seconds":targetSeconds,"tracks":2,"packets_per_track":totalPackets,"epoch_count":epoch,"models_released":released,"asr_partial_revision_checks":revisions,"asr_final_count":finals,"human_name_changes":names,"explicit_gaps":gaps,"short_network_pause_seconds":0.7,"short_pause_queued_not_discarded":true,"max_pcm_queue_bytes":highQueue,"max_retained_model_frames":highFrames,"max_retained_pcm_samples":highPCM,"max_retained_pipeline_segments":highSegments,"max_retained_decoder_keys":highDecodeKeys,"max_rss_bytes":Int(rss.ru_maxrss),"rss_samples":rssSamples,"independent_producer":true,"producer_p95_lag_seconds":producerSorted.isEmpty ? 0 : producerSorted[Int(Double(producerSorted.count-1)*0.95)],"producer_max_lag_seconds":producerSorted.last ?? 0,"p95_schedule_lag_seconds":sorted[Int(Double(sorted.count-1)*0.95)],"max_schedule_lag_seconds":sorted.last!,"clock_basis":"independent_100ms_callbacks_actual_shared_monotonic_clock_mic_offset_25ms_no_catchup_burst","buffers_released":true,"capture":false,"network_audio":false,"asr_network_mock":true,"persistent_archive_opened":false,"keychain":false,"window_opened":false,"speaker_quality_verified":false]
}
