import Foundation
import AppKit
import CryptoKit

struct MeetingFilesBuildResult {
    let folder:URL
    let audioCount:Int
    let transcriptState:String
}

/// Adds readable documents alongside the existing WAVs inside MeetingExports/<cache-id>.
/// That keeps the app's existing ownership, deletion, and restoration transaction intact.
final class MeetingFilesExportStore {
    let cacheRoot:URL
    let exportsRoot:URL
    private let fm=FileManager.default
    private let markerName=".meeting-files.json"
    private struct GeneratedFile:Codable {let name:String;let sha256:String}
    private struct Marker:Codable {let schema:Int;let cacheID:String;let session:String;let generated:[GeneratedFile]}

    init(cacheRoot:URL,exportsRoot:URL?=nil) {
        self.cacheRoot=cacheRoot.standardizedFileURL
        self.exportsRoot=(exportsRoot ?? cacheRoot.deletingLastPathComponent().appendingPathComponent("MeetingExports")).standardizedFileURL
    }
    private func exists(_ url:URL)->Bool {(try? fm.attributesOfItem(atPath:url.path)) != nil}
    private func safe(_ url:URL,directory:Bool?=nil)throws {
        guard url.standardizedFileURL.path==url.resolvingSymlinksInPath().standardizedFileURL.path else{throw Failure(code:"meeting_files_path_invalid")}
        if exists(url) {
            let values=try fm.attributesOfItem(atPath:url.path),kind=values[.type] as? FileAttributeType
            guard kind != .typeSymbolicLink else{throw Failure(code:"meeting_files_path_invalid")}
            if let directory {guard kind == (directory ? .typeDirectory:.typeRegular) else{throw Failure(code:"meeting_files_path_invalid")}}
            if kind == .typeRegular {guard (values[.referenceCount] as? NSNumber)?.intValue==1 else{throw Failure(code:"meeting_files_hardlink")}}
        } else if directory != nil {throw Failure(code:"meeting_files_missing")}
    }
    private func safeTitle(_ raw:String)->String {
        let forbidden=CharacterSet.controlCharacters.union(CharacterSet(charactersIn:"/:\\:*?\"<>|"))
        let value=String(raw.unicodeScalars.map{forbidden.contains($0) ? "_":String($0)}.joined().trimmingCharacters(in:.whitespacesAndNewlines).prefix(64))
        return value.isEmpty || value.allSatisfy({$0=="."}) ? "会议":value
    }
    private static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private func readMarker(_ folder:URL,item:CachedMeeting,session:String)throws->Marker? {
        let file=folder.appendingPathComponent(markerName);guard exists(file) else{return nil}
        try safe(file,directory:false);let data=try Data(contentsOf:file);guard data.count<=128*1024 else{throw Failure(code:"meeting_files_marker_invalid")}
        let value=try JSONDecoder().decode(Marker.self,from:data)
        guard value.schema==1,value.cacheID==item.id,value.session==session,value.generated.count<=128,
              Set(value.generated.map(\.name)).count==value.generated.count,
              value.generated.allSatisfy({($0.name=="会议说明.txt" || $0.name.hasSuffix("－转写原文.txt") || $0.name.hasSuffix("－AI整理稿.txt")) && $0.name.range(of:"^[^/\\\\]+$",options:.regularExpression) != nil && $0.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}) else{throw Failure(code:"meeting_files_marker_scope")}
        return value
    }
    private func ensureOwnedFolder(_ item:CachedMeeting,session:String)throws->URL {
        let folder=exportsRoot.appendingPathComponent(item.id,isDirectory:true)
        try safe(exportsRoot)
        if exists(folder) {
            try safe(folder,directory:true)
            let ownerFile=folder.appendingPathComponent("meeting-owner.json");try safe(ownerFile,directory:false)
            let owner=try JSONSerialization.jsonObject(with:Data(contentsOf:ownerFile)) as? [String:Any]
            guard owner?["cache_id"] as? String==item.id,owner?["session"] as? String==session else{throw Failure(code:"audio_asset_owner")}
        } else {
            try fm.createDirectory(at:exportsRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);try safe(exportsRoot,directory:true)
            let stage=exportsRoot.appendingPathComponent(".meeting-files-stage-"+UUID().uuidString,isDirectory:true)
            try fm.createDirectory(at:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            do {
                try JSONSerialization.data(withJSONObject:["schema":1,"cache_id":item.id,"session":session],options:.sortedKeys).write(to:stage.appendingPathComponent("meeting-owner.json"),options:.atomic)
                guard !exists(folder) else{throw Failure(code:"meeting_files_collision")};try fm.moveItem(at:stage,to:folder)
            } catch {if exists(stage){try? fm.removeItem(at:stage)};throw error}
        }
        var owner=folder.appendingPathComponent("meeting-owner.json")
        try safe(owner,directory:false)
        var values=URLResourceValues();values.isHidden=true
        do {try owner.setResourceValues(values)}catch{try? fm.setAttributes([.extensionHidden:true],ofItemAtPath:owner.path)}
        return folder
    }
    private func transcript(_ item:CachedMeeting,files:MeetingLibraryFiles,includeCoarse:Bool=true)throws->(String,String,[String]) {
        let metadata=try item.metadata(),session=files.session
        var names=SessionNames()
        let events=try item.events(includeCoarseRefinement:includeCoarse)
        for event in events {
            guard let parent=event["segment_id"] as? String else{continue}
            names.register(segment:parent,item:event)
            for run in TranscriptTimeline.speakerRuns(event) {names.register(segment:TranscriptTimeline.runID(parent:parent,run:run),item:run)}
        }
        let namesFile=item.directory.appendingPathComponent("session-names.json")
        if exists(namesFile) {try safe(namesFile,directory:false);let data=try Data(contentsOf:namesFile);guard data.count<=4*1024*1024 else{throw Failure(code:"meeting_files_names_capacity")};try names.restore(data,session:session,events:events,directory:item.directory)}
        names.validateVoiceprintArchive(meetingSummaryVoiceArchive())
        let rows=events.compactMap { event -> (id:String,parent:String,item:[String:Any])? in
            guard event["type"] as? String=="segment",let id=event["segment_id"] as? String else{return nil}
            return (id:id,parent:event["parent_segment_id"] as? String ?? id,item:event)
        }
        let turns=TranscriptTimeline.readingTurns(rows) { id,event in
            if names.sentenceName(segment:id) != nil {return "manual:"+id}
            if let key=names.key(segment:id) ?? SessionSpeakerKey.from(event) {
                if let name=names.displayName(segment:id),name.origin == .voiceprint,names.displayName(speaker:key)==nil {return [key.session,key.source,key.epoch,key.identity,"voiceprint",name.value].joined(separator:"\u{001F}")}
                return [key.session,key.source,key.epoch,key.identity].joined(separator:"\u{001F}")
            }
            return nil
        }
        var observed=Set<String>();var applications=Set<String>()
        for event in events {
            if let track=event["track"] as? String,isTranscriptAudioTrack(track) {observed.insert(track)}
            if let source=event["source_id"] as? String,isTranscriptAudioTrack(source),source != "mic" {
                let label=audioSourceLabel(event);if label != "电脑声音" {applications.insert(label)}
            }
        }
        let source:String
        switch metadata["bundle"] as? String {
        case "*microphone*":source="仅麦克风"
        case "*system*":source="电脑声音（含浏览器）"+(item.tracks.contains("mic") ? " + 麦克风":"")
        case "com.tencent.meeting":source="腾讯会议声音"+(item.tracks.contains("mic") ? " + 麦克风":"")
        default:source=item.tracks.contains("mic") ? "电脑声音 + 麦克风":"来源未记录"
        }
        let archiveFile=item.directory.appendingPathComponent("archived-transcript.txt")
        let archive:String?
        if item.audioCleaned,exists(archiveFile) {try safe(archiveFile,directory:false);archive=try String(contentsOf:archiveFile,encoding:.utf8)}else{archive=nil}
        let hasFinalText = !rows.isEmpty && rows.allSatisfy{($0.item["final"] as? Bool)==true}
        let complete=item.transcriptionComplete && (hasFinalText || archive != nil)
        let phase:RecordingPhase=item.warning ? .failed:.stopped
        let snapshot=TranscriptExportSnapshot(turns:turns,names:names,meetingTitle:item.displayTitle,sessionSource:source,phase:phase,incomplete:!complete,observedTracks:observed,applicationNames:applications.sorted(),recoveredArchiveText:events.isEmpty ? archive:nil,absoluteTime:MeetingAbsoluteTime(metadata["absolute_clock"]))
        let state=complete ? "转写完整":(rows.isEmpty ? "尚未转写":"部分转写，仍有内容待核对或录音待处理")
        let summary=["会议："+item.displayTitle,"转写状态："+state,"待转录音："+String(format:"%.1f",Double(item.pendingBytes)/32000)+" 秒"]
        return (snapshot.text(),state,summary)
    }
    private func duration(_ seconds:Double)->String {
        let value=max(0,Int(seconds.rounded()));return String(format:"%02d:%02d:%02d",value/3600,(value/60)%60,value%60)
    }
    private func sourceManifest(_ item:CachedMeeting,logicalTrack:String,bytes:Int,sourceHash:String)throws->[String:Any]? {
        let candidates=logicalTrack=="mic" ? ["mic-raw","mic"]:[logicalTrack]
        for actualTrack in candidates {
            let manifest=item.directory.appendingPathComponent(actualTrack+"-manifest.json")
            guard exists(manifest) else{continue}
            try safe(manifest,directory:false)
            let values=try fm.attributesOfItem(atPath:manifest.path)
            guard (values[.size] as? NSNumber)?.intValue ?? Int.max <= 512*1024 else{throw Failure(code:"meeting_files_manifest_capacity")}
            guard let value=try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any],
                  value["track"] as? String==actualTrack,let written=value["written_bytes"] as? Int,written==bytes,
                  let chunks=value["chunks"] as? [[String:Any]] else{continue}
            let evidence:[String:Any]=["track":actualTrack,"bytes":written,"chunks":chunks]
            let fingerprint=Self.hash(try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys]))
            if fingerprint==sourceHash{return value}
        }
        return nil
    }
    private func audioDetails(_ item:CachedMeeting,urls:[URL])throws->[String] {
        guard !urls.isEmpty else{return []}
        let metadata=try item.metadata(),origin=metadata["capture_origin_uptime"] as? Double
        let exportFile=item.directory.appendingPathComponent("audio-export.json");try safe(exportFile,directory:false)
        let value=try JSONSerialization.jsonObject(with:Data(contentsOf:exportFile)) as? [String:Any]
        guard let assets=value?["assets"] as? [[String:Any]],assets.count==urls.count else{throw Failure(code:"meeting_files_asset_mapping")}
        let events=try item.events(),byName=Dictionary(uniqueKeysWithValues:urls.map{($0.lastPathComponent,$0)})
        var rows:[String]=[]
        for asset in assets {
            guard let name=asset["file"] as? String,let track=asset["track"] as? String,
                  let bytes=asset["bytes"] as? Int,bytes>0,let sourceHash=asset["source"] as? String,let file=byName[name] else{throw Failure(code:"meeting_files_asset_mapping")}
            let sourceEvent=events.first{($0["source_id"] as? String ?? $0["track"] as? String)==track}
            let source=sourceEvent.map(audioSourceLabel) ?? (track=="mic" ? "麦克风":"电脑声音")
            let manifestValue=try sourceManifest(item,logicalTrack:track,bytes:bytes,sourceHash:sourceHash)
            let trackOrigin=manifestValue?["origin_uptime"] as? Double
            let start=(origin != nil && trackOrigin != nil && origin!.isFinite && trackOrigin!.isFinite && trackOrigin!>=origin! && trackOrigin!-origin!<=86400) ? duration(trackOrigin!-origin!):"时间未记录"
            rows.append("· \(file.lastPathComponent)：来自\(source)，起于 \(start)，时长 \(duration(Double(bytes)/32000))，完整 WAV")
        }
        return rows
    }
    private func guide(audio:[String],audioStatus:String,retired:Bool,summary:[String],transcriptName:String)->String {
        var lines=["会议文件说明","",summary[0],"录音状态："+(retired && audio.isEmpty ? "原始录音已移入回收区":audioStatus),summary[1],summary[2],"", "文件列表："]
        if audio.isEmpty {lines.append(retired ? "没有 WAV 文件；请先从应用回收站恢复原始录音。":"没有可播放的 WAV 录音。")}
        else {lines.append(contentsOf:audio)}
        lines += ["· "+transcriptName,"", "转写文本按发言时间排列；未确认的人声会保留为“待确认”。"]
        return lines.joined(separator:"\n")+"\n"
    }
    private func atomicWrite(_ data:Data,to target:URL)throws {
        try safe(target);try data.write(to:target,options:.atomic);try safe(target,directory:false)
    }
    func build(_ item:CachedMeeting,library:MeetingLibraryFiles,audioStore:MeetingAudioAssetsStore)throws->MeetingFilesBuildResult {
        guard UUID(uuidString:item.id) != nil,item.directory.standardizedFileURL==cacheRoot.appendingPathComponent(item.id).standardizedFileURL else{throw Failure(code:"meeting_files_scope_invalid")}
        try safe(cacheRoot,directory:true);try safe(item.directory,directory:true)
        guard try item.metadata()["session"] as? String==library.session else{throw Failure(code:"meeting_files_session_invalid")}
        let (text,state,summary)=try transcript(item,files:library)
        var audioInfo=try audioStore.info(item)
        let retiredFile=item.directory.appendingPathComponent("audio-retirement.json");var retired=false
        if exists(retiredFile) {try safe(retiredFile,directory:false);let receipt=try JSONSerialization.jsonObject(with:Data(contentsOf:retiredFile)) as? [String:Any];retired=receipt?["schema"] as? Int==1 && receipt?["cache_id"] as? String==item.id && receipt?["state"] as? String=="trashed"}
        if audioInfo.needsRecovery {throw Failure(code:"audio_asset_recovery_required")}
        if !audioInfo.exported && !item.warning && !retired && library.audioFolder != nil {
            _=try audioStore.export(item,active:false);audioInfo=try audioStore.info(item)
        }
        let folder=try ensureOwnedFolder(item,session:library.session)
        let wavs=audioInfo.exported ? try audioDetails(item,urls:audioInfo.urls):[]
        guard wavs.count<=64 else{throw Failure(code:"meeting_files_audio_capacity")}
        let audioStatus:String
        if !wavs.isEmpty {audioStatus="已生成 \(wavs.count) 路完整 WAV"}
        else if item.warning {audioStatus="录音未完整保存，尚未生成 WAV；请检查原始录音状态"}
        else if retired {audioStatus="原始录音已移入回收区，当前没有已导出的 WAV"}
        else {audioStatus="没有已导出的 WAV"}
        let transcriptName=safeTitle(item.displayTitle)+"－转写原文.txt",guideName="会议说明.txt"
        let markerURL=folder.appendingPathComponent(markerName)
        let oldMarker=try readMarker(folder,item:item,session:library.session)
        let oldHashes=Dictionary(uniqueKeysWithValues:(oldMarker?.generated ?? []).map{($0.name,$0.sha256)})
        let raw=try transcript(item,files:library,includeCoarse:false).0
        var generated:[(String,Data)]=[(transcriptName,Data(raw.utf8)),(guideName,Data(guide(audio:wavs,audioStatus:audioStatus,retired:retired,summary:summary,transcriptName:transcriptName).utf8))]
        if text != raw {
            let name=safeTitle(item.displayTitle)+"－AI整理稿.txt"
            generated.append((name,Data(("AI粗整理稿｜请结合原始转写与录音核对重要信息\n\n"+text).utf8)))
        }
        // Only replace a file if its current bytes still match the last version
        // written here. Edited or unrelated files remain under the user's control.
        for (name,_) in generated {
            let target=folder.appendingPathComponent(name)
            if exists(target) {
                try safe(target,directory:false)
                guard let expected=oldHashes[name],Self.hash(try Data(contentsOf:target))==expected else{throw Failure(code:"meeting_files_user_file_collision")}
            }
        }
        let generatedNames=Set(generated.map{$0.0}),oldNames=Set(oldHashes.keys)
        let obsolete=oldNames.subtracting(generatedNames).filter{name in
            guard let expected=oldHashes[name] else{return false}
            let url=folder.appendingPathComponent(name)
            return exists(url) && ((try? Data(contentsOf:url)).map(Self.hash) == expected)
        }
        let touched=generatedNames.union(obsolete)
        var previous:[String:Data]=[:],absent=Set<String>()
        for name in touched {let url=folder.appendingPathComponent(name);if exists(url){previous[name]=try Data(contentsOf:url)}else{absent.insert(name)}}
        let oldMarkerData=exists(markerURL) ? try Data(contentsOf:markerURL):nil
        let marker=Marker(schema:1,cacheID:item.id,session:library.session,generated:generated.map{GeneratedFile(name:$0.0,sha256:Self.hash($0.1))})
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        do {
            for (name,data) in generated {try atomicWrite(data,to:folder.appendingPathComponent(name))}
            for name in obsolete {try fm.removeItem(at:folder.appendingPathComponent(name))}
            try atomicWrite(encoder.encode(marker),to:markerURL)
        } catch {
            for (name,old) in previous {try? old.write(to:folder.appendingPathComponent(name),options:.atomic)}
            for name in absent {try? fm.removeItem(at:folder.appendingPathComponent(name))}
            if let oldMarkerData {try? oldMarkerData.write(to:markerURL,options:.atomic)}else{try? fm.removeItem(at:markerURL)}
            throw error
        }
        return MeetingFilesBuildResult(folder:folder,audioCount:wavs.count,transcriptState:state)
    }
}
