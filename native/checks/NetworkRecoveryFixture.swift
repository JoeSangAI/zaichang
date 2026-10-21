import Foundation
final class NetworkFixtureState {
    private let lock=NSLock();private var count=0;private var online=false
    func connection()->(Int,Bool){lock.lock();defer{lock.unlock()};count+=1;return(count,online)}
    func connections()->Int{lock.lock();defer{lock.unlock()};return count}
    func recover(){lock.lock();online=true;lock.unlock()}
}
func networkRecoveryFixture(base:URL)async throws->[String:Any] {
    try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
    interrupted=0
    let start=ProcessInfo.processInfo.systemUptime;let folder=base.appendingPathComponent(UUID().uuidString);let store=try RecordingJournal(directory:folder,track:"mic",freeSpace:{1_000_000_000});let producer=Mailbox(journal:store);let box=Mailbox(journal:store,producer:false)
    let old=Data(repeating:2,count:160000);let tail=Data(repeating:4,count:64000)
    for offset in stride(from:0,to:old.count,by:3200){producer.put(old.subdata(in:offset..<offset+3200),at:start+Double(offset)/32000)};store.wait()
    let state=NetworkFixtureState();let config=Config(session:"network-long-offline",bundle:"*microphone*",key:"",confirmed:true,maxSeconds:20,model:"qwen-audio-3.0-asr-flash-streaming",silenceMS:1300,micEnabled:true,localSpeakerDirectory:nil,localEmbeddingModel:nil,userLaunchConfirmed:nil)
    let lane=Lane(track:"mic",config:config,socketFactory:{let (index,online)=state.connection();return FixtureSocket(fail:index==1,offline:index>1 && !online,delay:5_000_000)});await lane.attachJournal(store)
    let consumer=Task {await runJournalASR(lane:lane,box:box,store:store,track:"mic",origin:start,onCacheFailure:{_ in preconditionFailure()},retryDelay:0.001,retryAfterLimit:true,slowRetryDelay:0.01,stopReconnectOnCaptureStop:true)}
    let deadline=ProcessInfo.processInfo.systemUptime+5
    while state.connections()<18 && ProcessInfo.processInfo.systemUptime<deadline {try await Task.sleep(nanoseconds:1_000_000)};precondition(state.connections()>=18 && !store.isEnded())
    // The same producer keeps appending as the failed consumer retries. No new session.
    let duplicate=Task {await runJournalASR(lane:lane,box:Mailbox(journal:store,producer:false),store:store,track:"mic",origin:start,onCacheFailure:{_ in preconditionFailure()},retryAfterLimit:true)};await duplicate.value
    for offset in stride(from:0,to:tail.count,by:3200){producer.put(tail.subdata(in:offset..<offset+3200),at:start+Double(old.count+offset)/32000);if offset==0 {store.wait();state.recover()};try await Task.sleep(nanoseconds:10_000_000)}
    producer.seal();store.wait();await consumer.value;await lane.stop();store.wait()
    let metrics=await lane.metrics();precondition(store.bytes()==old.count+tail.count && store.committed("asr")==store.bytes() && store.fault()==nil)
    var restored=Data();var cursor=0;while let (packet,_)=try store.read(cursor){restored.append(packet);cursor+=packet.count};precondition(restored==old+tail)
    let events=try String(contentsOf:folder.appendingPathComponent("mic-transcript.jsonl")).split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any]}
    let finals=events.filter{$0["type"] as? String=="segment" && $0["final"] as? Bool==true};let starts=finals.compactMap{$0["start"] as? Double}.sorted();precondition(starts==[0,1,2,3,4,5,6] && Set(finals.compactMap{$0["segment_id"] as? String}).count==7)
    precondition((metrics["automatic_asr_retries"] as? Int ?? 0)>16 && (metrics["attempted_audio_seconds"] as! Double)>7 && (metrics["attempted_audio_seconds"] as! Double)<=20)
    // Stopping capture while in backoff must not create the next socket.
    interrupted=0;let stoppedRoot=base.appendingPathComponent(UUID().uuidString);let stoppedStore=try RecordingJournal(directory:stoppedRoot,track:"mic",freeSpace:{1_000_000_000});let stoppedProducer=Mailbox(journal:stoppedStore);stoppedProducer.put(Data(repeating:0,count:3200),at:start);stoppedStore.wait();let stoppedState=NetworkFixtureState();let stoppedLane=Lane(track:"mic",config:config,socketFactory:{_ = stoppedState.connection();return FixtureSocket(fail:false,offline:true)});await stoppedLane.attachJournal(stoppedStore)
    let stoppedTask=Task {await runJournalASR(lane:stoppedLane,box:Mailbox(journal:stoppedStore,producer:false),store:stoppedStore,track:"mic",origin:start,onCacheFailure:{_ in preconditionFailure()},retryDelay:0.5,retryAfterLimit:true,stopReconnectOnCaptureStop:true)}
    try await Task.sleep(nanoseconds:80_000_000);interrupted=1;stoppedProducer.seal();await stoppedTask.value;await stoppedLane.stop();precondition(stoppedState.connections()==1 && stoppedStore.committed("asr")==0)
    interrupted=0;let canceledRoot=base.appendingPathComponent(UUID().uuidString);let canceledStore=try RecordingJournal(directory:canceledRoot,track:"mic",freeSpace:{1_000_000_000});let canceledProducer=Mailbox(journal:canceledStore);canceledProducer.put(Data(repeating:0,count:3200),at:start);canceledStore.wait();let canceledState=NetworkFixtureState();let canceledLane=Lane(track:"mic",config:config,socketFactory:{_ = canceledState.connection();return FixtureSocket(fail:false,offline:true)});await canceledLane.attachJournal(canceledStore)
    let canceledTask=Task {await runJournalASR(lane:canceledLane,box:Mailbox(journal:canceledStore,producer:false),store:canceledStore,track:"mic",origin:start,onCacheFailure:{_ in preconditionFailure()},retryDelay:0.5,retryAfterLimit:true,stopReconnectOnCaptureStop:true)}
    try await Task.sleep(nanoseconds:80_000_000);canceledTask.cancel();await canceledTask.value;canceledProducer.seal();await canceledLane.stop();precondition(canceledState.connections()==1 && canceledStore.committed("asr")==0)
    // Shared attempted-audio ceiling includes failed sends and replay; never reset it.
    interrupted=0;let limitedRoot=base.appendingPathComponent(UUID().uuidString);let limitedStore=try RecordingJournal(directory:limitedRoot,track:"mic",freeSpace:{1_000_000_000});let limitedProducer=Mailbox(journal:limitedStore);for offset in stride(from:0,to:old.count,by:3200){limitedProducer.put(old.subdata(in:offset..<offset+3200),at:start+Double(offset)/32000)};limitedProducer.seal();limitedStore.wait();let limitedState=NetworkFixtureState();let limitedConfig=Config(session:"network-budget",bundle:"*microphone*",key:"",confirmed:true,maxSeconds:2,model:config.model,silenceMS:1300,micEnabled:true,localSpeakerDirectory:nil,localEmbeddingModel:nil,userLaunchConfirmed:nil);let limitedLane=Lane(track:"mic",config:limitedConfig,socketFactory:{let (index,_)=limitedState.connection();return FixtureSocket(fail:index==1,delay:5_000_000)});await limitedLane.attachJournal(limitedStore)
    await runJournalASR(lane:limitedLane,box:Mailbox(journal:limitedStore,producer:false),store:limitedStore,track:"mic",origin:start,onCacheFailure:{_ in preconditionFailure()},retryDelay:0.001,retryAfterLimit:true,slowRetryDelay:0.01);await limitedLane.stop();let limited=await limitedLane.metrics();precondition(limited["attempted_audio_seconds"] as? Double==2 && limitedStore.committed("asr")<limitedStore.bytes() && limitedState.connections()==2)
    interrupted=0
    return ["type":"network_recovery_fixture","over_16_failures_automatic_resume":true,"same_producer_appends_during_offline_and_catchup":true,"same_cache_id":folder.lastPathComponent,"raw_bytes":store.bytes(),"finals_once":7,"single_consumer":true,"stop_during_backoff_no_new_socket":true,"cancel_during_backoff_no_new_socket":true,"attempted_budget_not_reset":true,"normal_metrics":metrics,"budget_metrics":limited,"capture":false,"network":false,"keychain":false,"production_slow_retry_seconds":30,"test_retry_delays_accelerated":true]
}
