import Foundation
import Darwin
// Independent analogue of native capture callbacks; UI/model consumer cannot stall production.
final class IndependentFixtureProducer {
    let lock=NSLock()
    let queue=DispatchQueue(label:"meeting.fixture.producer",qos:.userInitiated)
    let start:Double;let cachedPackets:[Data];let sourcePause:Double;var pauseInjected=false;var packetIndex=0;var sampleOrigin=0.0;var coalescedTicks=0;var preservedCoalescedTicks=0;var duePacketsTotal=0;var offeredPacketsTotal=0;var unofferedPackets=0;var sourceOverflowed=false;var notices:[[String:Any]]=[]
    var timer:DispatchSourceTimer?
    var boxes:[Mailbox]=[]
    var last:Double?
    var lags:[Double]=[];var workTimes:[Double]=[]
    var gaps:[[String:Any]]=[]
    init(start:Double,sourcePause:Double=0){self.start=start;self.sourcePause=sourcePause;cachedPackets=[440.0,660.0,0.0].map {frequency in var packet=Data(capacity:3200);for sample in 0..<1600 {let v=frequency==0 ? Int16(0):Int16(1200*sin(2*Double.pi*frequency*Double(sample)/16000));let b=UInt16(bitPattern:v);packet.append(UInt8(b&255));packet.append(UInt8(b>>8))};return packet}}
    func begin(_ newBoxes:[Mailbox]) {
        lock.lock();boxes=newBoxes;last=nil;packetIndex=0;sourceOverflowed=false;sampleOrigin=ProcessInfo.processInfo.systemUptime-start;lock.unlock()
        let source=DispatchSource.makeTimerSource(queue:queue)
        source.schedule(deadline:.now(),repeating:.milliseconds(100),leeway:.milliseconds(1))
        source.setEventHandler{[self] in
            if sourceOverflowed {return};let now=ProcessInfo.processInfo.systemUptime-start
            lock.lock();let current=boxes
            if let previous=last {let lag=max(0,now-previous-0.1);lags.append(lag);if lag>0.15 {notices.append(["type":"scheduling_notice","reason":"synthetic_producer_deadline_missed","start":previous+0.1,"end":now,"sources":["remote","mic"]])}}
            last=now;lock.unlock()
            if sourcePause>0 && !pauseInjected && packetIndex>=100 {pauseInjected=true;Thread.sleep(forTimeInterval:sourcePause)}
            let workStart=ProcessInfo.processInfo.systemUptime;let due=max(1,Int(timer?.data ?? 1))
            lock.lock();coalescedTicks+=max(0,due-1);duePacketsTotal+=due
            if due>1 {notices.append(["type":"scheduling_notice","reason":"timer_coalesced","due_packets":due,"at":now])};lock.unlock()
            // The synthetic signal is predetermined, equivalent to a bounded audio-device buffer.
            // Preserve at most 2s of due PCM; never discard a timer count or fabricate an unbounded catch-up burst.
            if due>20 {sourceOverflowed=true;unofferedPackets+=due;for box in current {box.fail("audio_backpressure")};lock.lock();gaps.append(["type":"coverage_gap","reason":"synthetic_source_buffer_budget_exceeded","due_packets":due,"start":sampleOrigin+Double(packetIndex)*0.1,"end":now]);lock.unlock()}
            else {preservedCoalescedTicks+=max(0,due-1);offeredPacketsTotal+=due;for _ in 0..<due {let stamp=sampleOrigin+Double(packetIndex)*0.1;let tick=Int(stamp*10);for lane in 0..<current.count {let voiced=(tick/50+lane)%3 != 2;current[lane].put(cachedPackets[voiced ? lane:2],at:stamp+Double(lane)*0.025)};packetIndex+=1}}
            lock.lock();workTimes.append(ProcessInfo.processInfo.systemUptime-workStart);lock.unlock()
        }
        timer=source;source.resume()
    }
    func stop(){timer?.cancel();queue.sync{};timer?.setEventHandler{};timer=nil;lock.lock();boxes=[];last=nil;lock.unlock()}
    func schedulingEvidence()->[String:Any] {lock.lock();defer{lock.unlock()};return ["coalesced_ticks_observed":coalescedTicks,"coalesced_ticks_preserved":preservedCoalescedTicks,"source_packets_due":duePacketsTotal,"source_packets_offered":offeredPacketsTotal,"source_packets_unoffered_after_budget_failure":unofferedPackets,"notices":notices,"source_pause_injected_seconds":pauseInjected ? sourcePause:0,"source_buffer_limit_packets":20]}
    func workEvidence()->[String:Any]{lock.lock();defer{lock.unlock()};let a=workTimes.sorted();return ["count":a.count,"p95_seconds":a.isEmpty ? 0:a[Int(Double(a.count-1)*0.95)],"max_seconds":a.max() ?? 0,"total_seconds":a.reduce(0,+)]}
    func evidence()->([Double],[[String:Any]]){lock.lock();defer{lock.unlock()};return(lags,gaps)}
}

// Foundation-only model/transport regression; no windows or UI interaction.
func independentClockFixture(directory:URL,target:Double) async throws->[String:Any] {
    guard [60.0,1800.0].contains(target) else {throw Failure(code:"invalid_fixture_duration")}
    let start=ProcessInfo.processInfo.systemUptime;let producer=IndependentFixtureProducer(start:start)
    let embedding=directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("local-embedding-install/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")
    var pipes:[SpeakerPipeline]=[];var boxes:[Mailbox]=[];var decoders:[Decoder]=[];var counts=[0,0];var total=[0,0];var origins=[Double?](repeating:nil,count:2)
    var epoch=0;var released=0;var gaps:[[String:Any]]=[];var rss=rusage();var rssSamples:[[String:Any]]=[];var consumerLags:[Double]=[];var names:[String:String]=[:]
    var finals=0;var revisions=0;var highFrames=0;var highPCM=0;var highSegments=0;var highKeys=0;var highQueue=0
    func close() async throws {producer.stop();for p in pipes {_ = try await p.close(flush:false);let state=await p.status();precondition(state["retained_frames"] as? Int==0 && state["retained_pcm_samples"] as? Int==0 && state["embedding_loaded"] as? Bool==false);released+=1};for b in boxes {b.clear();precondition(b.metrics()["queued_bytes"] as? Int==0)};names=[:]}
    func begin() async throws {epoch+=1;pipes=[];boxes=[Mailbox(),Mailbox()];decoders=[Decoder(),Decoder()];counts=[0,0];origins=[nil,nil];for track in ["remote","mic"] {let p=SpeakerPipeline(source:track,epoch:"clock-\(epoch)-\(track)",syntheticInput:true);try await p.load(directory:directory,embeddingModel:embedding);pipes.append(p)};producer.begin(boxes)}
    try await begin()
    let pauseAt=target==60 ? 5.0:60.0;let pressureAt=target==60 ? 10.0:180.0;let restartAt=target==60 ? 30.0:900.0
    var paused=false;var pressured=false;var restarted=false;var pauseEnd:Double?;var pressureStart:Double?;var pauseDrained=false;var highPauseQueue=0;var lastProgress=0
    while ProcessInfo.processInfo.systemUptime-start<target {
        let before=ProcessInfo.processInfo.systemUptime;try await Task.sleep(nanoseconds:50_000_000);let elapsed=ProcessInfo.processInfo.systemUptime-start;consumerLags.append(max(0,ProcessInfo.processInfo.systemUptime-before-0.05));if elapsed>=target {break}
        if elapsed>=pauseAt && !paused {paused=true;pauseEnd=elapsed+0.7}
        if elapsed>=pressureAt && !pressured {pressured=true;pressureStart=elapsed}
        if elapsed>=restartAt && !restarted {restarted=true;let before=elapsed;try await close();try await begin();gaps.append(["reason":"simulated_user_stop_and_restart","start":before,"end":ProcessInfo.processInfo.systemUptime-start,"sources":["remote","mic"]]);continue}
        var fault=false
        for b in boxes {do {try b.checkFault()}catch let e as Failure {precondition(e.code=="audio_backpressure");fault=true};highQueue=max(highQueue,b.metrics()["max_queued_bytes"] as? Int ?? 0)}
        if fault {let stoppedBoxes=boxes;let gapStart:Any=pressureStart as Any? ?? NSNull();let why=pressureStart != nil ? "simulated_backpressure":"actual_consumer_backpressure";try await close();gaps.append(["reason":why,"start":gapStart,"end":elapsed,"discarded_bytes_after_both_tracks_stopped":stoppedBoxes.map{$0.metrics()["discarded_bytes"] as! Int},"sources":["remote","mic"]]);pressureStart=nil;try await begin();continue}
        let holding=(pauseEnd.map{elapsed<$0} ?? false)||(pressureStart.map{elapsed<$0+2.3} ?? false)
        if holding {if pressureStart==nil {highPauseQueue=max(highPauseQueue,boxes.map{$0.metrics()["queued_bytes"] as? Int ?? 0}.max() ?? 0)};continue}
        if paused && !pauseDrained {precondition(boxes.allSatisfy{$0.metrics()["discarded_bytes"] as? Int==0});pauseDrained=true}
        // Fair round-robin: a continuously backlogged track cannot monopolize this fixture.
        while boxes.contains(where:{$0.hasFrames()}) {for lane in 0..<2 {guard let (packet,stamp)=try boxes[lane].takePacket(now:ProcessInfo.processInfo.systemUptime-start) else{continue}
            if origins[lane]==nil {origins[lane]=stamp};_ = try await pipes[lane].ingest(packet,captureOrigin:stamp);counts[lane]+=1;total[lane]+=1
            let mod=counts[lane]%20
            if [5,10,19].contains(mod) {let task="clock-\(epoch)-\(lane)";let sid=counts[lane]/20+1;let beginMS=Double(counts[lane]/20*2000);var sentence:[String:Any]=["sentence_id":sid,"begin_time":beginMS,"sentence_end":mod==19,"text":mod==5 ? "合成初稿":mod==10 ? "合成修订":"合成最终文字"];if mod==19 {sentence["end_time"]=Double(counts[lane]*100)}
                if let decoded=try decoders[lane].decode(["header":["task_id":task,"event":"result-generated"],"payload":["output":["sentence":sentence]]],task:task,track:lane==0 ? "remote":"mic",session:"synthetic-clock",bundle:"synthetic",origin:origins[lane]!,received:elapsed) {let event=await pipes[lane].accept(decoded);let id=event["segment_id"] as! String;precondition(abs((event["start"] as! Double)-(origins[lane]!+beginMS/1000))<1e-6);if mod==5 {names[id]="合成人物";while names.count>200 {names.removeValue(forKey:names.keys.sorted().first!)}};if mod==10 {let old=names[id];names[id]="纠正";names[id]=old;precondition(names[id]==old);revisions+=1};if mod==19 {finals+=1}}
            }
        }}
        if Int(elapsed)>=lastProgress+(target==60 ? 10:60) {lastProgress=Int(elapsed);for (index,p) in pipes.enumerated(){let state=await p.status();highFrames=max(highFrames,state["retained_frames"] as! Int);highPCM=max(highPCM,state["retained_pcm_samples"] as! Int);highSegments=max(highSegments,state["retained_segments"] as! Int);highKeys=max(highKeys,decoders[index].payloads.count)};precondition(highFrames<=720000 && highPCM<=96000 && highSegments<=4096 && highKeys<=200 && names.count<=200);getrusage(RUSAGE_SELF,&rss);rssSamples.append(["elapsed_seconds":elapsed,"max_rss_bytes":Int(rss.ru_maxrss)]);print("independent_clock_seconds=\(lastProgress) packets=\(total) max_rss=\(rss.ru_maxrss)");fflush(stdout)}
    }
    try await close();getrusage(RUSAGE_SELF,&rss);let (lags,producerGaps)=producer.evidence();gaps.append(contentsOf:producerGaps)
    func p95(_ v:[Double])->Double {let sorted=v.sorted();return sorted.isEmpty ? 0:sorted[Int(Double(sorted.count-1)*0.95)]}
    return ["type":"independent_clock_dual_synthetic_validation","wall_seconds":ProcessInfo.processInfo.systemUptime-start,"target_wall_seconds":target,"tracks":2,"packets_per_track":total,"epochs":epoch,"models_released":released,"independent_producer":true,"producer_p95_lag_seconds":p95(lags),"producer_max_lag_seconds":lags.max() ?? 0,"consumer_p95_lag_seconds":p95(consumerLags),"consumer_max_lag_seconds":consumerLags.max() ?? 0,"explicit_gaps":gaps,"short_network_pause_seconds":0.7,"short_pause_drained_without_loss":pauseDrained,"short_pause_max_queue_bytes":highPauseQueue,"partial_revision_checks":revisions,"asr_final_count":finals,"max_retained_frames":highFrames,"max_retained_pcm_samples":highPCM,"max_retained_segments":highSegments,"max_decoder_keys":highKeys,"max_pcm_queue_bytes":highQueue,"max_rss_bytes":Int(rss.ru_maxrss),"rss_samples":rssSamples,"buffers_released":true,"names_released":names.isEmpty,"capture":false,"network_audio":false,"asr_network_mock":true,"keychain":false,"persistent_archive":false,"actual_window_QA":false,"real_voice_quality_verified":false,"producer_scheduling":producer.schedulingEvidence(),"clock_basis":"bounded_predetermined_synthetic_device_buffer_due_counts_shared_monotonic_mic_offset_25ms"]
}

// Diagnostic-only synthetic probes: fixed runtime mailboxes, no device, network or keychain.
actor ClockProbeLane {
    let lane:Int;let box:Mailbox;let pipeline:SpeakerPipeline;let base:Double;let delayProbe:Bool;var injectedDelayAt:Double?
    var firstStamp:Double?;var packets=0;var ages:[Double]=[];var ingestTimes:[Double]=[];var acceptTimes:[Double]=[];var slow:[[String:Any]]=[];var failed:String?;var decoder=Decoder()
    init(lane:Int,box:Mailbox,pipeline:SpeakerPipeline,base:Double,delayProbe:Bool=false){self.lane=lane;self.box=box;self.pipeline=pipeline;self.base=base;self.delayProbe=delayProbe}
    func step() async ->Bool {
        do {
            let now=ProcessInfo.processInfo.systemUptime-base
            guard let (pcm,stamp)=try box.takePacket(now:now) else{return false}
            if firstStamp==nil {firstStamp=stamp};let age=max(0,now-stamp);ages.append(age);if delayProbe && lane==0 && packets==100 {injectedDelayAt=now;try await Task.sleep(nanoseconds:1_850_000_000)};let t=ProcessInfo.processInfo.systemUptime
            _ = try await pipeline.ingest(pcm,captureOrigin:stamp);let ingest=ProcessInfo.processInfo.systemUptime-t;ingestTimes.append(ingest);packets+=1
            if ingest>0.15 || age>0.5 {if slow.count<40 {slow.append(["at":now,"age_seconds":age,"ingest_seconds":ingest,"queued_bytes_after_ingest":box.metrics()["queued_bytes"] as! Int])}}
            if packets%30==29 {let t=ProcessInfo.processInfo.systemUptime;let end=firstStamp!+Double(packets)*0.1;let lo=end-2.4;_ = try await pipeline.syntheticTimelineRevision([SpeakerFrame(sourceID:lane==0 ? "remote":"mic",epoch:"probe-\(lane)",revision:packets*1000,start:lo,end:end,activeSlots:[0])],revision:packets*1000);let event:[String:Any]=["segment_id":"probe-\(lane)-\(packets)","source_id":lane==0 ? "remote":"mic","epoch":"probe-\(lane)","start":lo,"end":end,"end_time_known":true,"final":true,"revision":1,"text":"合成计时正文","received_at":now];_ = await pipeline.accept(event);acceptTimes.append(ProcessInfo.processInfo.systemUptime-t)}
            return true
        }catch{failed=(error as? Failure)?.code ?? String(describing:error);return false}
    }
    func evidence() async->[String:Any] {
        func stats(_ v:[Double])->[String:Any]{let a=v.sorted();return ["count":a.count,"p95_seconds":a.isEmpty ? 0:a[Int(Double(a.count-1)*0.95)],"max_seconds":a.max() ?? 0,"total_seconds":a.reduce(0,+)]}
        return ["injected_single_lane_delay_seconds":delayProbe && lane==0 ? 1.85:0,"injected_delay_at":injectedDelayAt as Any? ?? NSNull(),"lane":lane,"packets":packets,"queue_age":stats(ages),"ingest":stats(ingestTimes),"accept":stats(acceptTimes),"slow_events":slow,"failure":failed as Any? ?? NSNull(),"mailbox":box.metrics(),"model":await pipeline.timingSnapshot()]
    }
}
func clockDiagnostic(directory:URL,target:Double,mode:String) async throws->[String:Any] {
    guard [30.0,120.0,600.0,1800.0].contains(target),["serial","fair","parallel","serial-delay","fair-delay","parallel-delay","parallel-source-pause","parallel-source-overflow"].contains(mode) else{throw Failure(code:"invalid_probe")}
    var initialUsage=rusage();getrusage(RUSAGE_SELF,&initialUsage);var initialLoad=[Double](repeating:0,count:3);_ = getloadavg(&initialLoad,3)
    let base=ProcessInfo.processInfo.systemUptime;let embedding=directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("local-embedding-install/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")
    var pipelines:[SpeakerPipeline]=[];let boxes=[Mailbox(),Mailbox()];var lanes:[ClockProbeLane]=[];var loads:[Double]=[]
    for i in 0..<2 {let p=SpeakerPipeline(source:i==0 ? "remote":"mic",epoch:"probe-\(i)",syntheticInput:true);let t=ProcessInfo.processInfo.systemUptime;try await p.load(directory:directory,embeddingModel:embedding);loads.append(ProcessInfo.processInfo.systemUptime-t);pipelines.append(p);lanes.append(ClockProbeLane(lane:i,box:boxes[i],pipeline:p,base:base,delayProbe:mode.hasSuffix("-delay")))}
    let producer=IndependentFixtureProducer(start:base,sourcePause:mode=="parallel-source-pause" ? 1.2:mode=="parallel-source-overflow" ? 2.3:0);let runStart=ProcessInfo.processInfo.systemUptime;producer.begin(boxes);var tasks:[Task<Void,Never>]=[];var fault=false
    if mode.hasPrefix("parallel") {for lane in lanes {tasks.append(Task {while !Task.isCancelled && ProcessInfo.processInfo.systemUptime-runStart<target {if !(await lane.step()) {try? await Task.sleep(nanoseconds:5_000_000)}}})}}
    while ProcessInfo.processInfo.systemUptime-runStart<target {
        if boxes.contains(where:{$0.metrics()["coverage_gap"] as? Bool==true}) {fault=true;break}
        if mode.hasPrefix("serial") {for lane in lanes {while await lane.step(){}}}
        if mode.hasPrefix("fair") {for lane in lanes {_ = await lane.step()}}
        try await Task.sleep(nanoseconds:mode.hasPrefix("parallel") ? 50_000_000:5_000_000)
    }
    producer.stop();for t in tasks {t.cancel()};for t in tasks {await t.value};let stopPending=boxes.map{$0.metrics()["queued_bytes"] as! Int};let drainDeadline=ProcessInfo.processInfo.systemUptime+5;while !fault && boxes.contains(where:{$0.hasFrames()}) && ProcessInfo.processInfo.systemUptime<drainDeadline {for lane in lanes {_ = await lane.step()}};var evidence:[[String:Any]]=[]
    for lane in lanes {evidence.append(await lane.evidence())}
    for p in pipelines {_ = try await p.close(flush:false);let s=await p.status();precondition(s["retained_pcm_samples"] as? Int==0 && s["embedding_loaded"] as? Bool==false)};for b in boxes {b.clear()}
    let (lags,gaps)=producer.evidence();let a=lags.sorted();var usage=rusage();getrusage(RUSAGE_SELF,&usage)
    var endLoad=[Double](repeating:0,count:3);_ = getloadavg(&endLoad,3);func cpu(_ t:timeval)->Double {Double(t.tv_sec)+Double(t.tv_usec)/1_000_000}
    return ["process_cpu_user_seconds":cpu(usage.ru_utime)-cpu(initialUsage.ru_utime),"process_cpu_system_seconds":cpu(usage.ru_stime)-cpu(initialUsage.ru_stime),"host_load_average_start":initialLoad,"host_load_average_end":endLoad,"type":"clock_diagnostic","mode":mode,"target_seconds":target,"run_wall_seconds":ProcessInfo.processInfo.systemUptime-runStart,"loads_seconds":loads,"producer_callback_work":producer.workEvidence(),"producer_scheduling":producer.schedulingEvidence(),"synthetic_packet_generation":"immutable_cached_100ms_integer_cycle_tones_with_bounded_due_count_accounting","lanes":evidence,"production_p95_lag_seconds":a.isEmpty ? 0:a[Int(Double(a.count-1)*0.95)],"production_max_lag_seconds":a.max() ?? 0,"producer_gaps":gaps,"fault":fault,"stop_pending_pcm_bytes":stopPending,"synthetic_single_slot_for_CAM":true,"injected_faults":mode.hasSuffix("-delay") || mode.contains("-source-"),"automatic_retries":0,"models_released":2,"max_rss_bytes":Int(usage.ru_maxrss),"capture":false,"network":false,"keychain":false,"data":"synthetic_tones_only"]
}
