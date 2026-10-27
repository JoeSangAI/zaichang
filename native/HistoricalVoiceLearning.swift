import Foundation
import CryptoKit

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
func historicalVoiceHash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
