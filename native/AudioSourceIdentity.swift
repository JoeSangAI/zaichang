import Foundation
import CryptoKit

// Persisted IDs are filename-safe. Original two-lane caches remain compatible.
func isTranscriptAudioTrack(_ value:String)->Bool {
    value=="mic" || value=="remote" ||
        value.range(of:"^mic-g[1-9][0-9]{0,2}$",options:.regularExpression) == (value.startIndex..<value.endIndex) ||
        value.range(of:"^remote-g[1-9][0-9]{0,2}$",options:.regularExpression) == (value.startIndex..<value.endIndex) ||
        value.range(of:"^app-[a-f0-9]{16}(-g[1-9][0-9]{0,2})?$",options:.regularExpression) == (value.startIndex..<value.endIndex)
}
func isMeetingAudioTrack(_ value:String)->Bool {
    isTranscriptAudioTrack(value) || ["mic-raw","reference"].contains(value) ||
    value.range(of:"^(mic-raw|reference)-g[1-9][0-9]{0,2}$",options:.regularExpression)==(value.startIndex..<value.endIndex)
}
func meetingAudioTracks(in directory:URL,transcriptOnly:Bool=true)throws->[String] {
    try FileManager.default.contentsOfDirectory(atPath:directory.path).compactMap { name in
        guard name.hasSuffix("-manifest.json") else{return nil}
        let track=String(name.dropLast("-manifest.json".count))
        return (transcriptOnly ? isTranscriptAudioTrack(track):isMeetingAudioTrack(track)) ? track:nil
    }.sorted()
}
// A retired track may have no manifest or PCM left. Its source ID still belongs
// to the old timeline and must never be reused by a later capture epoch.
func reservedMeetingAudioTracks(in directory:URL,metadata:[String:Any])->Set<String> {
    var reserved=Set((try? meetingAudioTracks(in:directory,transcriptOnly:false)) ?? [])
    let suffixes=["-transcript.jsonl","-speaker.jsonl","-manifest.json"]
    for name in (try? FileManager.default.contentsOfDirectory(atPath:directory.path)) ?? [] {
        for suffix in suffixes where name.hasSuffix(suffix) {
            let track=String(name.dropLast(suffix.count))
            if isMeetingAudioTrack(track) {reserved.insert(track)}
        }
    }
    for source in metadata["audio_sources"] as? [[String:Any]] ?? [] {
        if let track=source["source_id"] as? String,isMeetingAudioTrack(track) {reserved.insert(track)}
    }
    for key in ["raw_microphone_track","playback_reference_track"] {
        if let track=metadata[key] as? String,isMeetingAudioTrack(track) {reserved.insert(track)}
    }
    if let data=try? Data(contentsOf:directory.appendingPathComponent("audio-retirement.json")),
       let receipt=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
        for track in receipt["tracks"] as? [String] ?? [] where isMeetingAudioTrack(track) {reserved.insert(track)}
    }
    return reserved
}
func applicationAudioSourceID(_ bundle:String)->String {"app-"+SHA256.hash(data:Data(bundle.utf8)).prefix(8).map{String(format:"%02x",$0)}.joined()}
func applicationAudioTrackID(_ coreID:String,generation:Int)->String? {
    guard coreID.range(of:"^app-[a-f0-9]{16}$",options:.regularExpression)==(coreID.startIndex..<coreID.endIndex),
          (1...999).contains(generation) else{return nil}
    return coreID+"-g"+String(generation)
}
func sourceGenerationTrackID(_ coreID:String,generation:Int)->String? {
    guard (1...999).contains(generation) else{return nil}
    if coreID=="remote" {return "remote-g"+String(generation)}
    return applicationAudioTrackID(coreID,generation:generation)
}
func audioSourceCoreID(_ track:String)->String? {
    guard isTranscriptAudioTrack(track) else{return nil}
    if track=="mic" || track.hasPrefix("mic-g") {return "mic"}
    if track=="remote" || track.hasPrefix("remote-g") {return "remote"}
    return applicationAudioCoreID(track)
}
func applicationAudioCoreID(_ track:String)->String? {
    guard isTranscriptAudioTrack(track),track.hasPrefix("app-") else{return nil}
    return String(track.prefix(20))
}
func audioSourceLabel(_ item:[String:Any])->String {
    let track=item["source_id"] as? String ?? item["track"] as? String ?? ""
    if track=="mic" || track.hasPrefix("mic-g") {return "麦克风"}
    guard let bundle=item["bundle_id"] as? String,!bundle.isEmpty,
          applicationAudioSourceID(bundle)==applicationAudioCoreID(track),
          let name=item["application_name"] as? String,!name.isEmpty,name.count<=80,
          !name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{return "电脑声音"}
    return name
}

// Attempts across all streams share one ceiling; retries consume it as well.
final class SessionUploadBudget {
    private let lock=NSLock();private let maximumBytes:Int;private var attemptedBytes=0
    init(maxSeconds:Double) {maximumBytes=Int(max(0,maxSeconds)*32000)}
    func reserve(_ bytes:Int)->Bool {lock.lock();defer{lock.unlock()};guard bytes>=0,bytes<=maximumBytes-attemptedBytes else{return false};attemptedBytes+=bytes;return true}
    var usedBytes:Int {lock.lock();defer{lock.unlock()};return attemptedBytes}
}
