import Foundation
// Mockable message decoder: task + sentence, partial replacement, no inferred speaker.
final class Decoder {
    /// A language/spelling warning does not invalidate independent audio.
    /// Capture corruption and unknown quality flags still block attribution.
    static func speakerEvidenceAllowed(_ item:[String:Any])->Bool {
        (item["quality_flags"] as? [String] ?? []).allSatisfy{$0=="language_shift_needs_review"}
    }
    var revisions: [String: Int] = [:]
    var payloads: [String: String] = [:]
    var sequence = 0
    var retainedOrder:[String]=[]
    var partials: [String: String] = [:]
    func decode(_ object: [String: Any], task: String, track: String, session: String,
                bundle: String, origin: Double, received: Double) throws -> [String: Any]? {
        guard let header = object["header"] as? [String: Any], header["task_id"] as? String == task else { throw Failure(code: "task_mismatch") }
        guard header["event"] as? String == "result-generated" else { return nil }
        guard let payload = object["payload"] as? [String: Any],
              let output = payload["output"] as? [String: Any], let sentence = output["sentence"] as? [String: Any] else { throw Failure(code: "invalid_result") }
        if sentence["heartbeat"] as? Bool == true { return nil }
        guard let sid = sentence["sentence_id"] as? Int, sid > 0,
              let start = sentence["begin_time"] as? Double, start >= 0,
              let final = sentence["sentence_end"] as? Bool, let text = sentence["text"] as? String else { throw Failure(code: "invalid_sentence") }
        let end = sentence["end_time"] as? Double
        guard !final || end != nil, end == nil || end! >= start else { throw Failure(code: "invalid_end_time") }
        // Empty start/final packets are protocol activity, not recognized utterances.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let wordFingerprint=(sentence["words"] as? [[String:Any]]).flatMap{try? JSONSerialization.data(withJSONObject:$0,options:[.sortedKeys])}.flatMap{String(data:$0,encoding:.utf8)} ?? ""
        let fingerprint = wordFingerprint+"|"+"\(start)|\(end.map(String.init(describing:)) ?? "null")|\(final)|\(text)"
        let key = task + ":" + String(sid)
        if payloads[key] == fingerprint { return nil }
        if payloads[key]==nil {retainedOrder.append(key)}
        while retainedOrder.count>200 {let old=retainedOrder.removeFirst();payloads.removeValue(forKey:old);revisions.removeValue(forKey:old);partials.removeValue(forKey:old)}
        payloads[key] = fingerprint; revisions[key, default: 0] += 1; sequence += 1
        var result: [String: Any] = ["type": "segment", "session": session, "application": bundle,
                "event_id": task + ":delivery:" + String(sequence), "segment_id": key,
                "revision": revisions[key]!, "source_seq": sequence, "received_at": received,
                "start": origin + start / 1000, "end": origin + (end ?? start) / 1000,
                "end_time_known": end != nil, "text": text, "final": final,
                "speaker": ["basis": "channel", "label": track == "mic" ? "本地麦克风" : "远端混音"],
                "track": track, "coverage_basis": "local_received_results_not_provider_completeness"]
        // Provider word spans are optional evidence, never fabricated from text length.
        if let words=sentence["words"] as? [[String:Any]],!words.isEmpty,words.count<=1000,let end=end {
            var validated:[[String:Any]]=[];var last=start;var combined=""
            for word in words {
                guard let lo=word["begin_time"] as? Double,let hi=word["end_time"] as? Double,lo.isFinite,hi.isFinite,lo>=last,hi>lo,hi<=end,
                      let body=word["text"] as? String,!body.isEmpty else{validated=[];break}
                let punctuation=word["punctuation"] as? String ?? "";let piece=body+punctuation
                validated.append(["start":origin+lo/1000,"end":origin+hi/1000,"text":piece]);combined+=piece;last=hi
            }
            if !validated.isEmpty,combined==text {result["word_spans"]=validated}
        }
        if !final { partials[key] = text }
        else if let prior = partials[key] {
            func chineseCount(_ value: String) -> Int { value.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count }
            let latin = text.unicodeScalars.filter { (65...90).contains($0.value) || (97...122).contains($0.value) }.count
            if chineseCount(prior) >= 2 && chineseCount(text) == 0 && latin >= 4 {
                result["quality_flags"] = ["language_shift_needs_review"]
                result["previous_partial"] = prior // Local session memory only; never a corrected ground truth.
            }
        }
        if final {partials.removeValue(forKey:key)}
        return result
    }
}

