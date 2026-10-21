import Foundation
import CryptoKit

struct SpeakerAudioClip {
    let wav:Data
    let duration:Double
    let truncated:Bool
}

// A bounded, local-only preview of the selected source and clock range. Never
// decodes another source, changes PCM, exports a file, or learns an identity.
enum SpeakerAudioPreview {
    static func listeningData(_ wav:Data)->Data {
        guard wav.count>44,(wav.count-44)%2==0 else{return wav}
        let bytes=[UInt8](wav.dropFirst(44))
        let samples=stride(from:0,to:bytes.count,by:2).map{Int(Int16(bitPattern:UInt16(bytes[$0]) | UInt16(bytes[$0+1])<<8))}
        let peak=samples.map{abs($0)}.max() ?? 0
        guard peak>0,peak<16384 else{return wav}
        let gain=min(16.0,26214.0/Double(peak))
        var result=Data(wav.prefix(44))
        for sample in samples {var value=Int16(max(-32768,min(32767,Int((Double(sample)*gain).rounded())))).littleEndian;withUnsafeBytes(of:&value){result.append(contentsOf:$0)}}
        return result
    }
    static func read(root:URL,cacheID:String,session:String,items:[[String:Any]])throws->SpeakerAudioClip {
        let fm=FileManager.default,folder=root.appendingPathComponent(cacheID)
        guard UUID(uuidString:cacheID) != nil,!session.isEmpty,!items.isEmpty,items.count<=128 else{throw Failure(code:"speaker_preview_scope")}
        func safe(_ file:URL,directory:Bool)throws {
            let v=try file.resourceValues(forKeys:[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey])
            guard file.standardizedFileURL==file.resolvingSymlinksInPath().standardizedFileURL,v.isSymbolicLink != true,
                  directory ? v.isDirectory==true:v.isRegularFile==true else{throw Failure(code:"speaker_preview_unavailable")}
        }
        func read(_ file:URL,limit:Int)throws->Data {
            try safe(file,directory:false)
            let v=try file.resourceValues(forKeys:[.fileSizeKey]);guard let bytes=v.fileSize,bytes>=0,bytes<=limit else{throw Failure(code:"speaker_preview_invalid")}
            let data=try Data(contentsOf:file);guard data.count==bytes else{throw Failure(code:"speaker_preview_changed")};return data
        }
        func object(_ file:URL)throws->[String:Any] {
            guard let value=try JSONSerialization.jsonObject(with:read(file,limit:1024*1024)) as? [String:Any] else{throw Failure(code:"speaker_preview_invalid")};return value
        }
        try safe(root,directory:true);try safe(folder,directory:true)
        let meeting=try object(folder.appendingPathComponent("meeting.json"))
        guard meeting["session"] as? String==session,let origin=meeting["capture_origin_uptime"] as? Double,origin.isFinite else{throw Failure(code:"speaker_preview_scope")}
        var sources=Set<String>(),starts:[Double]=[],ends:[Double]=[]
        for item in items {
            guard item["session"] as? String==session,let source=item["source_id"] as? String,isTranscriptAudioTrack(source),
                  item["end_time_known"] as? Bool != false,let start=item["start"] as? Double,let end=item["end"] as? Double,
                  start.isFinite,end.isFinite,start>=0,end>start,end<=86400 else{throw Failure(code:"speaker_preview_time")}
            sources.insert(source);starts.append(start);ends.append(end)
        }
        guard sources.count==1,let source=sources.first,let first=starts.min(),let last=ends.max() else{throw Failure(code:"speaker_preview_source")}
        // Preserve the original microphone for human listening when available.
        let rawTrack=source=="mic" ? "mic-raw":source.hasPrefix("mic-g") ? "mic-raw-"+String(source.dropFirst(4)):""
        let track=rawTrack != "" && fm.fileExists(atPath:folder.appendingPathComponent(rawTrack+"-manifest.json").path) ? rawTrack:source
        let manifestURL=folder.appendingPathComponent(track+"-manifest.json"),manifestData=try read(manifestURL,limit:1024*1024)
        guard let manifest=try JSONSerialization.jsonObject(with:manifestData) as? [String:Any],manifest["schema"] as? Int==1,
              manifest["track"] as? String==track,manifest["format"] as? String=="pcm_s16le",manifest["sample_rate"] as? Int==16000,
              manifest["channels"] as? Int==1,manifest["ended"] as? Bool==true,manifest["error"] as? String==nil,
              let trackOrigin=manifest["origin_uptime"] as? Double,trackOrigin.isFinite,trackOrigin>=origin,trackOrigin-origin<=86400,
              let chunks=manifest["chunks"] as? [[String:Any]],chunks.count<=2000,
              let written=manifest["written_bytes"] as? Int,written>=0,written<=512*1024*1024 else{throw Failure(code:"speaker_preview_unavailable")}
        var pcmFolder=folder
        let retirement=folder.appendingPathComponent("audio-retirement.json")
        if fm.fileExists(atPath:retirement.path) {
            let receipt=try object(retirement)
            if receipt["state"] as? String=="trashed" {
                let retired=root.appendingPathComponent(".retired").appendingPathComponent(cacheID)
                guard receipt["schema"] as? Int==1,receipt["cache_id"] as? String==cacheID,
                      receipt["recoverable"] as? Bool==true,receipt["destination"] as? String==retired.path else{throw Failure(code:"speaker_preview_unavailable")}
                try safe(retired,directory:true);pcmFolder=retired
            }
        }
        let offset=trackOrigin-origin,lo=Int(((first-offset)*16000).rounded())*2
        let requestedHi=Int(((last-offset)*16000).rounded())*2,hi=min(requestedHi,lo+30*32000)
        guard lo>=0,hi>lo,hi<=written else{throw Failure(code:"speaker_preview_time")}
        var cursor=0,pcm=Data()
        for (index,chunk) in chunks.enumerated() {
            guard chunk["index"] as? Int==index,chunk["start_sample"] as? Int==cursor/2,
                  let bytes=chunk["bytes"] as? Int,bytes>0,bytes<=320000,bytes%2==0 else{throw Failure(code:"speaker_preview_invalid")}
            let next=cursor+bytes;defer{cursor=next}
            guard next>lo,cursor<hi else{continue}
            let data=try read(pcmFolder.appendingPathComponent(String(format:"%@-%06d.pcm",track,index)),limit:320000)
            guard data.count==bytes,chunk["sha256"] as? String==SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined() else{throw Failure(code:"speaker_preview_changed")}
            pcm.append(data[max(0,lo-cursor)..<min(bytes,hi-cursor)])
        }
        guard cursor==written,pcm.count==hi-lo,try read(manifestURL,limit:1024*1024)==manifestData else{throw Failure(code:"speaker_preview_changed")}
        return SpeakerAudioClip(wav:MeetingAudioAssetsStore.wavHeader(pcm.count)+pcm,duration:Double(pcm.count)/32000,truncated:requestedHi>hi)
    }
}
