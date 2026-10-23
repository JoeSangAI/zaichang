import Foundation
import Darwin
func pipelineStress(directory:URL) async throws->[String:Any] {
    let p=SpeakerPipeline(source:"remote",epoch:"synthetic-stress",syntheticInput:true)
    let embedding=directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("local-embedding-install/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")
    try await p.load(directory:directory,embeddingModel:embedding)
    let start=Date();let packet=Data(repeating:0,count:3200);var highFrames=0;var highRuns=0;var highPCM=0;var highSegments=0;var highRevisions=0;var rss:rusage=rusage();var rssWarm:Int=0
    for i in 0..<18000 {
        _ = try await p.ingest(packet,captureOrigin:Double(i)*0.1)
        if i%20==0 {_ = await p.accept(["type":"segment","segment_id":"stress-\(i)","session":"stress","revision":1,"start":Double(i)*0.1,"end":Double(i)*0.1+0.1,"end_time_known":true,"text":"合成静音压力文本","final":true])}
        if i%100==0 {
            let state=await p.status();let frames=state["retained_frames"] as! Int;let pcm=state["retained_pcm_samples"] as! Int;let segments=state["retained_segments"] as! Int;let rev=state["retained_revision_keys"] as! Int
            let runs=state["retained_frame_runs"] as! Int;precondition(frames<=180_000 && runs<=100 && pcm<=96000 && segments<=4096 && rev<=4096);highRuns=max(highRuns,runs);highFrames=max(highFrames,frames);highPCM=max(highPCM,pcm);highSegments=max(highSegments,segments);highRevisions=max(highRevisions,rev)
        }
        if i==1200 {getrusage(RUSAGE_SELF,&rss);rssWarm=Int(rss.ru_maxrss)}
        if i>0 && i%3000==0 {print("synthetic_stress_progress_seconds=\(i/10)");fflush(stdout)}
    }
    getrusage(RUSAGE_SELF,&rss);let finalRSS=Int(rss.ru_maxrss);_ = try await p.close(flush:true);let closed=await p.status()
    precondition(closed["retained_frames"] as? Int==0 && closed["retained_segments"] as? Int==0 && closed["retained_pcm_samples"] as? Int==0 && closed["embedding_loaded"] as? Bool==false)
    return ["type":"true_model_synthetic_stress","virtual_seconds":1800,"packets":18000,"wall_seconds":Date().timeIntervalSince(start),"source_tracks":1,"max_retained_frames":highFrames,"max_retained_frame_runs":highRuns,"max_retained_pcm":highPCM,"max_retained_segments":highSegments,"max_retained_revision_keys":highRevisions,"max_rss_after_120_virtual_seconds_bytes":rssWarm,"max_rss_end_bytes":finalRSS,"buffers_released":true,"capture":false,"network_audio":false,"real_model":true,"real_embedding_loaded":true,"speech_quality_verified":false]
}
struct PipelineFixtureResult {let events:[[String:Any]];let evidence:[String:Any]}
func pipelineFixture(directory:URL) async throws->PipelineFixtureResult {
    var checks=0;var events:[[String:Any]]=[]
    let remote=SpeakerPipeline(source:"remote",epoch:"fixture-remote",syntheticInput:true)
    let mic=SpeakerPipeline(source:"mic",epoch:"fixture-mic",syntheticInput:true)
    events.append(["type":"speaker_model","state":"loading","capture":false])
    let embeddingURL=directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("local-embedding-install/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")
    let loadStart=Date();try await remote.load(directory:directory,embeddingModel:embeddingURL);try await mic.load(directory:directory,embeddingModel:embeddingURL)
    events.append(["type":"speaker_model","state":"ready","identity_available":false]);events.append(["type":"started"])
    // Real model, exact capture mailbox and synthetic PCM16 packets. No websocket or devices.
    let remoteDecoder=Decoder();let micDecoder=Decoder()
    let remoteBox=Mailbox();let micBox=Mailbox();var packetCounts=[0,0];let processing=Date()
    for step in 0..<40 {
        let bytes=Data((0..<1600).flatMap{ i->[UInt8] in
            let value:Int16=step<20 ? 0 : Int16(900*sin(2*Double.pi*440*Double(step*1600+i)/16000));let bits=UInt16(bitPattern:value);return [UInt8(bits&255),UInt8(bits>>8)]
        })
        remoteBox.put(bytes,at:100+Double(step)*0.1);micBox.put(Data(repeating:0,count:bytes.count),at:100.25+Double(step)*0.1)
        if let (packet,stamp)=try remoteBox.takePacket(now:100+Double(step)*0.1) {events+=try await remote.ingest(packet,captureOrigin:stamp-100);packetCounts[0]+=1}
        if let (packet,stamp)=try micBox.takePacket(now:100.25+Double(step)*0.1) {events+=try await mic.ingest(packet,captureOrigin:stamp-100);packetCounts[1]+=1}
        if step==4 {
            func provider(_ task:String)->[String:Any] {["header":["task_id":task,"event":"result-generated"],"payload":["output":["sentence":["sentence_id":1,"begin_time":100.0,"end_time":400.0,"sentence_end":true,"text":"离线模拟转写：确认创意方向。"]]]]}
            let remoteASR=try remoteDecoder.decode(provider("fixture-remote"),task:"fixture-remote",track:"remote",session:"fixture",bundle:"synthetic",origin:0,received:0.5)!
            let micASR=try micDecoder.decode(provider("fixture-mic"),task:"fixture-mic",track:"mic",session:"fixture",bundle:"synthetic",origin:0.25,received:0.5)!
            events.append(await remote.accept(remoteASR));events.append(await mic.accept(micASR))
        }
    }
    precondition(packetCounts==[40,40]);checks+=1
    let remoteState=await remote.status();let micState=await mic.status()
    precondition(remoteState["pcm_samples"] as? Int==64000 && micState["pcm_samples"] as? Int==64000);checks+=1
    // Real silence model must not be used to manufacture names or multi-speaker accuracy.
    precondition(events.filter{$0["type"] as? String=="segment"}.allSatisfy{($0["speaker"] as? [String:Any])?["basis"] as? String=="unknown"});checks+=1
    events+=try await remote.syntheticTimelineRevision([SpeakerFrame(sourceID:"remote",epoch:"fixture-remote",revision:100,start:0,end:4,activeSlots:[0])],revision:100)
    let featureEvent=await remote.accept(["type":"segment","segment_id":"embedding-test","application":"synthetic","session":"fixture","track":"remote","start":1.0,"end":4.0,"end_time_known":true,"text":"合成特征管线测试，不代表真人。","final":true,"speaker_timeline_fixture":true])
    let feature=featureEvent["identity_features"] as? [String:Any]
    precondition((feature?["values"] as? [Float])?.count==192 && feature?["input_kind"] as? String=="synthetic_model_output");events.append(featureEvent);checks+=1
    // Exercise the production asynchronous tile extractor on retained synthetic
    // tone PCM; model speaker labels are explicit fixtures, never accuracy proof.
    try await remote.syntheticFeatureSampling(from:32000)
    let extracting=await remote.status()
    precondition(extracting["feature_worker_in_flight"] as? Bool==true || (extracting["retained_feature_tiles"] as? Int ?? 0)>0);checks+=1
    events+=try await remote.finishInput(flush:false)
    let released=await remote.status()
    precondition(released["closed"] as? Bool==false && released["loaded"] as? Bool==false &&
        released["embedding_loaded"] as? Bool==false && (released["retained_frames"] as? Int ?? 0)>0);checks+=1
    let delayedAfterRelease=await remote.accept(["type":"segment","segment_id":"late-after-input-finished",
        "application":"synthetic","session":"fixture","track":"remote","start":1.0,"end":4.0,
        "end_time_known":true,"text":"迟到文字仍保留说话人依据。","final":true])
    precondition((delayedAfterRelease["speaker"] as? [String:Any])?["cluster_id"] as? Int==0);checks+=1
    let retained=delayedAfterRelease["identity_features"] as? [String:Any]
    precondition((retained?["values"] as? [Float])?.count==192 && retained?["evidence_start"] as? Double==2 && released["retained_feature_tiles"] as? Int==1);checks+=1
    events.append(delayedAfterRelease)
    let realGate=SpeakerPipeline(source:"remote",epoch:"real-gate")
    do {_ = try await realGate.syntheticTimelineRevision([],revision:1);preconditionFailure()} catch SpeakerBackendError.invalidPCM {checks+=1}
    events+=try await remote.close(flush:false);events+=try await mic.close(flush:true)
    remoteBox.clear();micBox.clear()
    for value in [await remote.status(),await mic.status()] {precondition(value["closed"] as? Bool==true && value["loaded"] as? Bool==false && value["retained_frames"] as? Int==0 && value["retained_segments"] as? Int==0 && value["retained_pcm_samples"] as? Int==0 && value["embedding_loaded"] as? Bool==false);checks+=1}
    do {_ = try await remote.ingest(Data([0,0]),captureOrigin:4);preconditionFailure()} catch SpeakerBackendError.closed {checks+=1}
    let repeatedClose=try await remote.close(flush:false);precondition(repeatedClose.isEmpty);checks+=1
    let overflow=Mailbox();for i in 0..<21 {overflow.put(Data(repeating:0,count:3200),at:Double(i)*0.1)}
    do {_ = try overflow.take();preconditionFailure()} catch let error as Failure {precondition(error.code=="audio_backpressure");checks+=1}
    let canceled=SpeakerPipeline(source:"remote",epoch:"canceled");_ = try await canceled.close(flush:false)
    do {try await canceled.load(directory:directory);preconditionFailure()} catch SpeakerBackendError.closed {checks+=1}
    let late=await canceled.accept(["segment_id":"late"]);precondition((late["speaker"] as? [String:Any])?["reason"] as? String=="closed");checks+=1
    // Explicit fabricated timelines exercise join branches; separate from real acoustic output.
    func frame(_ start:Double,_ end:Double,_ slots:[Int],_ rev:Int=1)->SpeakerFrame {SpeakerFrame(sourceID:"remote",epoch:"fixture-remote",revision:rev,start:start,end:end,activeSlots:slots)}
    var timeline=SpeakerTimeline();timeline.replace([frame(0,1,[0]),frame(1,2,[1]),frame(2,3,[0,1])],revision:1)
    func segment(_ id:String,_ start:Double,_ end:Double)->[String:Any] {["type":"segment","source_id":"remote","epoch":"fixture-remote","session":"fixture","track":"remote","segment_id":id,"start":start,"end":end,"end_time_known":true,"text":"离线时间线测试 "+id,"final":true]}
    var single=segment("manual",0.1,0.8);single["speaker"]=timeline.join(single,source:"remote",epoch:"fixture-remote");precondition((single["speaker"] as? [String:Any])?["basis"] as? String=="anonymous_cluster");events.append(single);checks+=1
    for (id,lo,hi,reason) in [("cross",0.5,1.5,"speaker_change"),("overlap",2.1,2.8,"overlap"),("gap",3.1,3.2,"coverage_gap")] {
        var item=segment(id,lo,hi);let joined=timeline.join(item,source:"remote",epoch:"fixture-remote");precondition(joined["reason"] as? String==reason);item["speaker"]=joined;events.append(item);checks+=1
    }
    var partial=segment("partial",0,0);partial["end_time_known"]=false;precondition(timeline.join(partial,source:"remote",epoch:"fixture-remote")["basis"] as? String=="unknown");checks+=1
    var unreliable=single;unreliable["quality_flags"]=["language_shift_needs_review"];precondition(timeline.join(unreliable,source:"remote",epoch:"fixture-remote")["basis"] as? String=="anonymous_cluster");checks+=1
    unreliable["quality_flags"]=["audio_corrupt"];precondition(timeline.join(unreliable,source:"remote",epoch:"fixture-remote")["reason"] as? String=="asr_quality");checks+=1
    var mismatch=single;mismatch["epoch"]="other";precondition(timeline.join(mismatch,source:"remote",epoch:"fixture-remote")["reason"] as? String=="source_or_epoch_mismatch");checks+=1
    timeline.replace([frame(0,1,[2],2)],revision:2);single["speaker"]=timeline.join(single,source:"remote",epoch:"fixture-remote");events.append(single)
    timeline.replace([frame(0,1,[7],1)],revision:1);precondition(timeline.revision==2 && timeline.frames[0].activeSlots==[2]);checks+=1
    var quietBoundary=SpeakerTimeline();quietBoundary.append([frame(0,0.8,[0]),frame(0.8,0.9,[0]),frame(0.9,0.95,[]),frame(0.95,1.05,[0]),frame(1.05,1.10,[])])
    precondition(quietBoundary.join(segment("quiet-boundary",0.8,1.10),source:"remote",epoch:"fixture-remote")["basis"] as? String=="anonymous_cluster");checks+=1
    var noSpeech=SpeakerTimeline();noSpeech.append([frame(0,1,[])])
    precondition(noSpeech.join(segment("no-speech",0,1),source:"remote",epoch:"fixture-remote")["reason"] as? String=="no_speaker_evidence");checks+=1
    var sparse=SpeakerTimeline();sparse.append([frame(0,0.8,[0]),frame(0.8,1.79,[]),frame(1.79,1.8,[0])])
    precondition(sparse.join(segment("sparse",0.8,1.8),source:"remote",epoch:"fixture-remote")["reason"] as? String=="insufficient_voiced_evidence");checks+=1
    var briefOverlap=SpeakerTimeline();briefOverlap.append([frame(0,0.8,[0]),frame(0.8,0.89,[0]),frame(0.89,0.90,[0,1]),frame(0.90,1.00,[0])])
    let brief=briefOverlap.join(segment("brief-overlap",0.8,1.00),source:"remote",epoch:"fixture-remote")
    precondition(brief["basis"] as? String=="anonymous_cluster" && brief["cluster_id"] as? Int==0);checks+=1
    var briefChange=SpeakerTimeline();briefChange.append([frame(0,0.8,[0]),frame(0.8,0.89,[0]),frame(0.89,0.90,[1]),frame(0.90,1.00,[0])])
    precondition(briefChange.join(segment("brief-change",0.8,1.00),source:"remote",epoch:"fixture-remote")["cluster_id"] as? Int==0);checks+=1
    var sustainedOverlap=SpeakerTimeline();sustainedOverlap.append([frame(0,0.8,[0]),frame(0.8,1.6,[1]),frame(1.6,1.70,[0]),frame(1.70,1.80,[0,1]),frame(1.80,1.90,[0])])
    precondition(sustainedOverlap.join(segment("sustained-overlap",1.6,1.90),source:"remote",epoch:"fixture-remote")["reason"] as? String=="overlap");checks+=1
    var withinWordTurn=SpeakerTimeline();withinWordTurn.append([frame(0,0.8,[0]),frame(0.8,1.6,[1]),frame(1.6,1.7,[0]),frame(1.7,1.8,[1])])
    precondition(withinWordTurn.join(segment("within-word-turn",1.65,1.75),source:"remote",epoch:"fixture-remote")["reason"] as? String=="speaker_change");checks+=1
    var silentMiddle=SpeakerTimeline();silentMiddle.append([frame(0,0.8,[0]),frame(0.8,0.9,[0]),frame(0.9,0.95,[]),frame(0.95,1.05,[0])])
    precondition(silentMiddle.join(segment("silent-middle",0.8,1.05),source:"remote",epoch:"fixture-remote")["cluster_id"] as? Int==0);checks+=1
    var missingMiddle=SpeakerTimeline();missingMiddle.append([frame(0,0.10,[0]),frame(0.15,0.25,[0])])
    precondition(missingMiddle.join(segment("missing-middle",0,0.25),source:"remote",epoch:"fixture-remote")["reason"] as? String=="coverage_gap");checks+=1
    let wordsPipeline=SpeakerPipeline(source:"remote",epoch:"fixture-remote",syntheticInput:true)
    _ = try await wordsPipeline.syntheticTimelineRevision([frame(0,1,[0]),frame(1,2,[1])],revision:1)
    var wordsSegment=segment("word-change",0,2);wordsSegment["text"]="甲乙";wordsSegment["word_spans"]=[["start":0.1,"end":0.9,"text":"甲"],["start":1.1,"end":1.9,"text":"乙"]]
    let split=await wordsPipeline.accept(wordsSegment);let runs=split["speaker_runs"] as! [[String:Any]]
    precondition(runs.count==2 && (runs[0]["speaker"] as! [String:Any])["cluster_id"] as? Int==0 && (runs[1]["speaker"] as! [String:Any])["cluster_id"] as? Int==1);checks+=1
    let updates=try await wordsPipeline.syntheticTimelineRevision([frame(0,1,[1],2),frame(1,2,[0],2)],revision:2)
    precondition(updates.count==1 && (updates[0]["speaker_runs"] as! [[String:Any]])[0]["text"] as? String=="甲" && ((updates[0]["speaker_runs"] as! [[String:Any]])[0]["speaker"] as! [String:Any])["cluster_id"] as? Int==1);checks+=1
    _ = try await wordsPipeline.close(flush:false)
    let naturalWords=SpeakerPipeline(source:"remote",epoch:"fixture-remote",syntheticInput:true)
    _ = try await naturalWords.syntheticTimelineRevision([frame(0,0.8,[0]),frame(0.8,1.6,[1]),frame(1.6,1.71,[0]),frame(1.71,1.72,[0,1]),frame(1.72,1.8,[0]),frame(1.8,1.9,[1])],revision:1)
    var naturalSegment=segment("natural-words",1.6,1.9);naturalSegment["text"]="甲，乙 丙。"
    naturalSegment["word_spans"]=[["start":1.6,"end":1.7,"text":"甲，"],["start":1.7,"end":1.8,"text":"乙 "],["start":1.8,"end":1.9,"text":"丙。"]]
    let natural=await naturalWords.accept(naturalSegment);let naturalRuns=natural["speaker_runs"] as! [[String:Any]]
    precondition(natural["text"] as? String=="甲，乙 丙。" && naturalRuns.map{$0["text"] as! String}.joined()=="甲，乙 丙。" &&
                 naturalRuns.count==2 && naturalRuns[0]["text"] as? String=="甲，乙 " &&
                 (naturalRuns[0]["speaker"] as! [String:Any])["cluster_id"] as? Int==0 &&
                 (naturalRuns[1]["speaker"] as! [String:Any])["cluster_id"] as? Int==1);checks+=1
    precondition(SpeakerTimeline.sameSpeakerEvidence(["basis":"anonymous_cluster","cluster_id":0,"revision":1,"label":"旧标签"],
                                                     ["basis":"anonymous_cluster","cluster_id":0,"revision":2,"label":"新标签"]) &&
                 !SpeakerTimeline.sameSpeakerEvidence(["basis":"anonymous_cluster","cluster_id":0],
                                                      ["basis":"anonymous_cluster","cluster_id":1]));checks+=1
    var reusableTimeline=SpeakerTimeline()
    reusableTimeline.replace([frame(0,0.20,[0]),frame(0.20,0.30,[1])],revision:1)
    var outOfBounds=naturalSegment
    outOfBounds["word_spans"]=[["start":0.0,"end":0.20,"text":"甲，乙 "],["start":0.20,"end":0.31,"text":"丙。"]]
    reusableTimeline.annotateWords(&outOfBounds,source:"remote",epoch:"fixture-remote")
    precondition(outOfBounds["speaker_runs"]==nil);checks+=1
    var changedText=naturalSegment;changedText["text"]="甲乙丙。"
    reusableTimeline.annotateWords(&changedText,source:"remote",epoch:"fixture-remote")
    precondition(changedText["speaker_runs"]==nil);checks+=1
    _ = try await naturalWords.close(flush:false)
    events.append(["type":"stopped","reason":"user_stop"])
    return PipelineFixtureResult(events:events,evidence:["type":"native_pipeline_validation","passed":checks,"real_model":true,"real_model_input":"synthetic_silence_and_tone","real_embedding_loaded_in_pipeline":true,"real_embedding_output_from_mock_single_speaker_interval":true,"mock_asr":true,"mock_speaker_timeline":true,"capture":false,"network_audio":false,"identity_enrollment":false,"coreml_cache_may_be_warm":true,"quality_verified":false,"packets_per_track":40,"seconds_per_track":4,"mic_origin":0.25,"model_load_seconds":Date().timeIntervalSince(loadStart)-Date().timeIntervalSince(processing),"pipeline_processing_seconds":Date().timeIntervalSince(processing)])
}
