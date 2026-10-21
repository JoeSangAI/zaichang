import Foundation

struct SessionSpeakerKey:Hashable,Codable {
    let session:String;let source:String;let epoch:String;let identity:String
    func sameScope(_ other:Self)->Bool {session==other.session && source==other.source && epoch==other.epoch}
    static func from(_ item:[String:Any])->Self? {
        // Only the hash-validated, meeting-local sidecar reader creates this
        // basis. Acoustic identity can cross sources without changing the audio
        // origin. Human SessionNames bindings are applied afterwards.
        if let speaker=item["speaker"] as? [String:Any],speaker["basis"] as? String=="meeting_reconciliation",
           speaker["source_id"] as? String==item["source_id"] as? String,
           speaker["epoch"] as? String==item["epoch"] as? String,
           let object=speaker["identity_key"] as? [String:Any],
           let data=try? JSONSerialization.data(withJSONObject:object),
           let key=try? JSONDecoder().decode(Self.self,from:data),
           key.session==item["session"] as? String,isTranscriptAudioTrack(key.source),
           !key.epoch.isEmpty,key.epoch.count<=160,
           let slot=Int(key.identity.replacingOccurrences(of:"slot:",with:"")),
           key.identity=="slot:\(slot)",(0..<8).contains(slot) {return key}
        guard let speaker=item["speaker"] as? [String:Any],speaker["basis"] as? String=="anonymous_cluster",
              let session=item["session"] as? String,!session.isEmpty,
              let source=item["source_id"] as? String,let epoch=item["epoch"] as? String,
              speaker["source_id"] as? String==source,speaker["epoch"] as? String==epoch,
              let slot=speaker["cluster_id"] as? Int,(0..<8).contains(slot) else{return nil}
        return Self(session:session,source:source,epoch:epoch,identity:"slot:\(slot)")
    }
}
