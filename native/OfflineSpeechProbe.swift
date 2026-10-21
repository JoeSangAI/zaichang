import Foundation

// OfflineOnly command. Public licensed recordings with known source speaker IDs;
// no ASR, device, enrollment or persisted embedding vectors.
func offlineSpeechProbe(directory:URL,fixture:URL) async throws->[String:Any] {
    let pcm=try Data(contentsOf:fixture.appendingPathComponent("input.pcm"))
    let reference=(try JSONSerialization.jsonObject(with:Data(contentsOf:fixture.appendingPathComponent("reference.json")))) as! [String:Any]
    let source=reference["source_id"] as? String ?? "remote"
    guard ["mic","remote"].contains(source) else{throw Failure(code:"offline_fixture_scope_invalid")}
    let pipeline=SpeakerPipeline(source:source,epoch:"public-offline-probe")
    let started=Date();try await pipeline.load(directory:directory)
    let loadSeconds=Date().timeIntervalSince(started);var delays:[Double]=[]
    for offset in stride(from:0,to:pcm.count,by:3200) {
        _ = try await pipeline.ingest(Data(pcm[offset..<min(offset+3200,pcm.count)]),captureOrigin:Double(offset)/32000)
        let snapshot=await pipeline.offlineFrames()
        if let last=snapshot.last {delays.append(max(0,Double(min(offset+3200,pcm.count))/32000-last.end))}
    }
    let beforeTail=await pipeline.offlineFrames()
    let frames=try await pipeline.finishOfflineFrames()
    var annotations:[[String:Any]]=[]
    for (i,turn) in (reference["turns"] as! [[String:Any]]).enumerated() {
        var item:[String:Any]=["type":"segment","session":"public-offline-probe","source_id":source,"epoch":"public-offline-probe","segment_id":"turn-\(i)","revision":1,"received_at":Double(pcm.count)/32000,"start":turn["start"]!,"end":turn["end"]!,"end_time_known":true,"text":"离线测试片段","final":true]
        item=await pipeline.accept(item)
        annotations.append(["turn":i,"speaker":item["speaker"] ?? [:]])
    }
    _ = try await pipeline.close(flush:false)
    return ["type":"public_recording_speaker_probe","source_id":source,"input_seconds":Double(pcm.count)/32000,"sample_rate":16000,"channels":1,"load_seconds":loadSeconds,"wall_seconds":Date().timeIntervalSince(started),"pre_flush_frame_count":beforeTail.count,"final_frame_count":frames.count,"frames":frames.map{["start":$0.start,"end":$0.end,"active_slots":$0.activeSlots]},"annotation_results":annotations,"frame_delivery_lag_input_clock_max_seconds":delays.max() ?? 0,"capture":false,"network":false,"asr":false,"embeddings_saved":false,"speaker_accuracy_generalized":false]
}
