import Foundation
import CryptoKit
import Darwin

struct MeetingAudioAssetInfo {
    let name:String
    let folder:URL?
    let urls:[URL]
    var exported:Bool {!urls.isEmpty}
    var needsRecovery=false
}

// Call from the existing background I/O queue. No capture, decoding, resampling,
// mixing, or automatic export occurs here. Names never share display-info.json.
final class MeetingAudioAssetsStore {
    let cacheRoot:URL
    let exportsRoot:URL
    var beforeStep:((String)throws->Void)?
    private static let mutex=NSRecursiveLock()
    private let fm=FileManager.default
    private let metadataName="audio-export.json"
    private let transactionName=".audio-export-transaction.json"
    private struct Asset:Codable,Equatable {let track:String;let label:String;var file:String;let bytes:Int;let source:String}
    private struct Record:Codable,Equatable {let schema:Int;let cacheID:String;let session:String;var name:String;var assets:[Asset]}
    private struct Transaction:Codable {let schema:Int;let cacheID:String;let session:String;let stage:String;let kind:String;let hadFolder:Bool;let oldData:Data?;let old:Record?;let new:Record}
    private struct Chunk {let url:URL;let bytes:Int;let hash:String}
    private struct Plan {let track:String;let label:String;let bytes:Int;let fingerprint:String;let chunks:[Chunk];let manifest:URL;let manifestData:Data}
    init(cacheRoot:URL,exportsRoot:URL?=nil) {
        self.cacheRoot=cacheRoot.standardizedFileURL
        self.exportsRoot=(exportsRoot ?? cacheRoot.deletingLastPathComponent().appendingPathComponent("MeetingExports")).standardizedFileURL
    }
    private func locked<T>(_ body:()throws->T)throws->T {Self.mutex.lock();defer{Self.mutex.unlock()};return try body()}
    static func validatedName(_ raw:String)throws->String {
        let name=raw.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        let invalid=CharacterSet.controlCharacters.union(.illegalCharacters).union(CharacterSet(charactersIn:"/\\:*?\"<>|"))
        guard !name.isEmpty,name.count<=80,name.utf8.count<=180,!name.hasPrefix("."),!name.hasSuffix("."),!name.unicodeScalars.contains(where:{invalid.contains($0) || CharacterSet(charactersIn:"\u{200B}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0)}) else{throw Failure(code:"audio_asset_name_invalid")}
        return name
    }
    private func folded(_ name:String)->String {name.precomposedStringWithCanonicalMapping.folding(options:[.caseInsensitive],locale:Locale(identifier:"en_US_POSIX"))}
    private func exists(_ url:URL)->Bool {(try? fm.attributesOfItem(atPath:url.path)) != nil}
    private func safe(_ url:URL,directory:Bool?=nil)throws {
        guard url.standardizedFileURL.path==url.resolvingSymlinksInPath().standardizedFileURL.path else{throw Failure(code:"audio_asset_path_invalid")}
        if exists(url) {
            let a=try fm.attributesOfItem(atPath:url.path),type=a[.type] as? FileAttributeType
            guard type != .typeSymbolicLink else{throw Failure(code:"audio_asset_path_invalid")}
            if let directory {guard type == (directory ? .typeDirectory:.typeRegular) else{throw Failure(code:"audio_asset_path_invalid")}}
            if type == .typeRegular {guard (a[.referenceCount] as? NSNumber)?.intValue==1 else{throw Failure(code:"audio_asset_hardlink")}}
        } else if directory != nil {throw Failure(code:"audio_asset_missing")}
    }
    private func read(_ url:URL,limit:Int=1024*1024)throws->Data {
        try safe(url,directory:false)
        guard let size=try fm.attributesOfItem(atPath:url.path)[.size] as? NSNumber,size.intValue<=limit else{throw Failure(code:"audio_asset_metadata_capacity")}
        return try Data(contentsOf:url)
    }
    private func object(_ url:URL)throws->[String:Any] {guard let value=try JSONSerialization.jsonObject(with:read(url)) as? [String:Any] else{throw Failure(code:"audio_asset_metadata_invalid")};return value}
    private func write<T:Encodable>(_ value:T,to url:URL)throws {try safe(url);let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];try encoder.encode(value).write(to:url,options:.atomic)}
    private func scope(_ item:CachedMeeting)throws->String {
        guard UUID(uuidString:item.id) != nil,item.directory.standardizedFileURL==cacheRoot.appendingPathComponent(item.id),cacheRoot.path != exportsRoot.path,!cacheRoot.path.hasPrefix(exportsRoot.path+"/"),!exportsRoot.path.hasPrefix(cacheRoot.path+"/"),!exportsRoot.pathComponents.contains("Voiceprints") else{throw Failure(code:"audio_asset_scope")}
        try safe(cacheRoot,directory:true);try safe(exportsRoot);try safe(item.directory,directory:true)
        let metadata=try object(item.directory.appendingPathComponent("meeting.json"))
        guard let session=metadata["session"] as? String,!session.isEmpty,session.utf8.count<=256,(metadata["cache_id"] as? String ?? item.id)==item.id else{throw Failure(code:"audio_asset_session")}
        return session
    }
    private func defaultName(_ item:CachedMeeting)->String {
        let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone=TimeZone.current;f.dateFormat="yyyy-MM-dd HH.mm.ss"
        let icon=item.recordingMode=="local_only" ? "🎙️ ":item.recordingMode=="record_and_transcribe" ? "📝 ":""
        return icon+f.string(from:item.date)+" 录音"
    }
    private func fileName(_ name:String,_ label:String)->String {name+"－"+label+".wav"}
    private func validate(_ record:Record,item:CachedMeeting,session:String)throws {
        guard record.schema==1,record.cacheID==item.id,record.session==session,try Self.validatedName(record.name)==record.name,record.assets.count<=64,Set(record.assets.map{$0.track}).count==record.assets.count else{throw Failure(code:"audio_asset_record_invalid")}
        for asset in record.assets {
            guard isTranscriptAudioTrack(asset.track),asset.label=="麦克风" || asset.label.range(of:"^电脑声音[1-9][0-9]?$",options:.regularExpression) != nil,asset.file==fileName(record.name,asset.label),asset.bytes>0,asset.bytes<=512*1024*1024,asset.bytes%2==0,asset.source.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else{throw Failure(code:"audio_asset_record_invalid")}
        }
        guard Set(record.assets.map{folded($0.file)}).count==record.assets.count else{throw Failure(code:"audio_asset_collision")}
    }
    private func load(_ item:CachedMeeting,session:String)throws->Record? {
        let url=item.directory.appendingPathComponent(metadataName);guard exists(url) else{return nil}
        let record=try JSONDecoder().decode(Record.self,from:read(url));try validate(record,item:item,session:session);return record
    }
    private func ownedFolder(_ folder:URL,item:CachedMeeting,session:String)throws {
        try safe(folder,directory:true);let owner=try object(folder.appendingPathComponent("meeting-owner.json"))
        guard owner["cache_id"] as? String==item.id,owner["session"] as? String==session else{throw Failure(code:"audio_asset_owner")}
        guard let iterator=fm.enumerator(at:folder,includingPropertiesForKeys:nil) else{throw Failure(code:"audio_asset_unreadable")}
        var count=0;for case let file as URL in iterator {count+=1;guard count<=4096 else{throw Failure(code:"audio_asset_capacity")};try safe(file)}
    }
    private func validateFiles(_ record:Record,folder:URL)throws {
        for asset in record.assets {
            let url=folder.appendingPathComponent(asset.file);try safe(url,directory:false)
            guard (try fm.attributesOfItem(atPath:url.path)[.size] as? NSNumber)?.intValue==asset.bytes+44 else{throw Failure(code:"audio_asset_changed")}
            let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
            guard try handle.read(upToCount:44)==Self.wavHeader(asset.bytes) else{throw Failure(code:"audio_asset_changed")}
        }
    }
    func info(_ item:CachedMeeting)throws->MeetingAudioAssetInfo {try locked {
        let session=try scope(item),record=try load(item,session:session)
        if exists(item.directory.appendingPathComponent(transactionName)) {return MeetingAudioAssetInfo(name:record?.name ?? defaultName(item),folder:nil,urls:[],needsRecovery:true)}
        let folder=exportsRoot.appendingPathComponent(item.id,isDirectory:true)
        if exists(folder) {try ownedFolder(folder,item:item,session:session)}
        guard let record,!record.assets.isEmpty else{return MeetingAudioAssetInfo(name:record?.name ?? defaultName(item),folder:nil,urls:[])}
        try ownedFolder(folder,item:item,session:session);try validateFiles(record,folder:folder)
        return MeetingAudioAssetInfo(name:record.name,folder:folder,urls:record.assets.map{folder.appendingPathComponent($0.file)})
    }}
    private func plans(_ item:CachedMeeting)throws->[Plan] {
        let tracks=try meetingAudioTracks(in:item.directory);guard !tracks.isEmpty,tracks.count<=64 else{throw Failure(code:"audio_asset_no_audio")}
        var result:[Plan]=[],computer=0
        for track in tracks {
            let rawTrack=track=="mic" ? "mic-raw":track.hasPrefix("mic-g") ? "mic-raw-"+String(track.dropFirst(4)):""
            let actualTrack=rawTrack != "" && exists(item.directory.appendingPathComponent(rawTrack+"-manifest.json")) ? rawTrack:track
            let manifest=item.directory.appendingPathComponent(actualTrack+"-manifest.json"),data=try read(manifest)
            guard let v=try JSONSerialization.jsonObject(with:data) as? [String:Any],v["schema"] as? Int==1,v["track"] as? String==actualTrack,v["format"] as? String=="pcm_s16le",v["sample_rate"] as? Int==16000,v["channels"] as? Int==1,v["ended"] as? Bool==true,v["error"] as? String==nil,let written=v["written_bytes"] as? Int,written>=0,written<=512*1024*1024,let chunks=v["chunks"] as? [[String:Any]],chunks.count<=2000 else{throw Failure(code:"audio_asset_unsealed")}
            var total=0,list:[Chunk]=[]
            for (index,chunk) in chunks.enumerated() {
                guard chunk["index"] as? Int==index,chunk["start_sample"] as? Int==total/2,let bytes=chunk["bytes"] as? Int,bytes>0,bytes<=320000,bytes%2==0,let hash=chunk["sha256"] as? String,hash.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else{throw Failure(code:"audio_asset_unsealed")}
                list.append(Chunk(url:item.directory.appendingPathComponent(String(format:"%@-%06d.pcm",actualTrack,index)),bytes:bytes,hash:hash));total+=bytes
            }
            guard total==written else{throw Failure(code:"audio_asset_source_invalid")};if total==0 {continue}
            if audioSourceCoreID(track) != "mic" {computer+=1}
            // ASR cursors do not change the identity of sealed audio.
            let evidence:[String:Any]=["track":actualTrack,"bytes":written,"chunks":chunks]
            let fingerprint=Self.digest(try JSONSerialization.data(withJSONObject:evidence,options:.sortedKeys))
            result.append(Plan(track:track,label:audioSourceCoreID(track)=="mic" ? "麦克风":"电脑声音"+String(computer),bytes:total,fingerprint:fingerprint,chunks:list,manifest:manifest,manifestData:data))
        }
        guard !result.isEmpty else{throw Failure(code:"audio_asset_no_audio")};return result
    }
    private static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func wavHeader(_ bytes:Int)->Data {
        var data=Data();func tag(_ value:String){data.append(contentsOf:value.utf8)}
        func n<T:FixedWidthInteger>(_ value:T){var little=value.littleEndian;withUnsafeBytes(of:&little){data.append(contentsOf:$0)}}
        tag("RIFF");n(UInt32(bytes+36));tag("WAVEfmt ");n(UInt32(16));n(UInt16(1));n(UInt16(1));n(UInt32(16000));n(UInt32(32000));n(UInt16(2));n(UInt16(16));tag("data");n(UInt32(bytes));return data
    }
    private func stream(_ plan:Plan,to destination:URL?)throws {
        var output:FileHandle?
        if let destination {try safe(destination);guard !exists(destination),fm.createFile(atPath:destination.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw Failure(code:"audio_asset_collision")};output=try FileHandle(forWritingTo:destination);try output?.write(contentsOf:Self.wavHeader(plan.bytes))}
        defer{try? output?.close()}
        for chunk in plan.chunks {
            try safe(chunk.url,directory:false)
            let before=try fm.attributesOfItem(atPath:chunk.url.path)
            guard (before[.size] as? NSNumber)?.intValue==chunk.bytes else{throw Failure(code:"audio_asset_source_invalid")}
            let fd=open(chunk.url.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{throw Failure(code:"audio_asset_source_invalid")}
            let input=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer{try? input.close()}
            var hash=SHA256(),remaining=chunk.bytes
            while remaining>0 {let data=try input.read(upToCount:min(65536,remaining)) ?? Data();guard !data.isEmpty else{throw Failure(code:"audio_asset_short_read")};hash.update(data:data);try output?.write(contentsOf:data);remaining-=data.count}
            guard try input.read(upToCount:1)?.isEmpty != false,hash.finalize().map({String(format:"%02x",$0)}).joined()==chunk.hash else{throw Failure(code:"audio_asset_hash_mismatch")}
            let after=try fm.attributesOfItem(atPath:chunk.url.path)
            guard before[.systemFileNumber] as? NSNumber==after[.systemFileNumber] as? NSNumber,before[.modificationDate] as? Date==after[.modificationDate] as? Date else{throw Failure(code:"audio_asset_source_changed")}
        }
        guard try read(plan.manifest)==plan.manifestData else{throw Failure(code:"audio_asset_source_changed")}
        try output?.synchronize()
    }
    private func ensureNoCollisions(_ files:[String],in folder:URL,excluding:Set<String>=[])throws {
        let names=exists(folder) ? try fm.contentsOfDirectory(atPath:folder.path):[]
        let occupied=Set(names.filter{!excluding.contains($0)}.map{folded($0)})
        for name in files {guard !occupied.contains(folded(name)) else{throw Failure(code:"audio_asset_collision")}}
    }
    private func restoreMetadata(_ transaction:Transaction,item:CachedMeeting)throws {
        let target=item.directory.appendingPathComponent(metadataName);try safe(target)
        if let data=transaction.oldData {try data.write(to:target,options:.atomic)}else if exists(target){try fm.removeItem(at:target)}
    }
    private func rollback(_ transaction:Transaction,item:CachedMeeting)throws {
        let final=exportsRoot.appendingPathComponent(item.id,isDirectory:true),stage=exportsRoot.appendingPathComponent(transaction.stage,isDirectory:true)
        guard !(exists(final) && exists(stage)) else{throw Failure(code:"audio_asset_recovery_collision")}
        let folder=exists(stage) ? stage:final
        if exists(folder) {
            // A first export can be interrupted between mkdir and owner write.
            // Only our exact empty staging directory is safe to discard here.
            if !transaction.hadFolder,folder==stage,!exists(folder.appendingPathComponent("meeting-owner.json")) {
                try safe(folder,directory:true)
                guard try fm.contentsOfDirectory(atPath:folder.path).isEmpty else{throw Failure(code:"audio_asset_recovery_owner_missing")}
                try fm.removeItem(at:folder);try restoreMetadata(transaction,item:item);try fm.removeItem(at:item.directory.appendingPathComponent(transactionName));return
            }
            try ownedFolder(folder,item:item,session:transaction.session)
            if transaction.kind=="rename",let old=transaction.old {
                for (index,asset) in old.assets.enumerated() {
                    let names=try fm.contentsOfDirectory(atPath:folder.path),temp=".audio-rename-"+String(index),new=transaction.new.assets[index].file
                    if names.contains(asset.file) {continue}
                    let source=folder.appendingPathComponent(names.contains(temp) ? temp:new)
                    try safe(source,directory:false)
                    // A temporary hop is necessary for case-only renames on APFS.
                    let hop=folder.appendingPathComponent(temp)
                    if source != hop {guard !exists(hop) else{throw Failure(code:"audio_asset_recovery_collision")};try fm.moveItem(at:source,to:hop)}
                    let destination=folder.appendingPathComponent(asset.file);guard !exists(destination) else{throw Failure(code:"audio_asset_recovery_collision")};try fm.moveItem(at:hop,to:destination)
                }
            } else if transaction.kind=="export" {
                for asset in transaction.new.assets {let file=folder.appendingPathComponent(asset.file);if exists(file){try safe(file,directory:false);try fm.removeItem(at:file)}}
            }
            if transaction.hadFolder {
                if folder==stage {try fm.moveItem(at:stage,to:final)}
            } else {try fm.removeItem(at:folder)}
        } else if transaction.hadFolder {throw Failure(code:"audio_asset_recovery_missing")}
        try restoreMetadata(transaction,item:item)
        try fm.removeItem(at:item.directory.appendingPathComponent(transactionName))
    }
    private func recover(_ item:CachedMeeting,session:String)throws {
        let file=item.directory.appendingPathComponent(transactionName);guard exists(file) else{return}
        let tx=try JSONDecoder().decode(Transaction.self,from:read(file))
        guard tx.schema==1,tx.cacheID==item.id,tx.session==session,tx.stage.hasPrefix(".audio-txn-"),UUID(uuidString:String(tx.stage.dropFirst(11))) != nil,["rename","export"].contains(tx.kind) else{throw Failure(code:"audio_asset_transaction_invalid")}
        try validate(tx.new,item:item,session:session)
        if let old=tx.old {try validate(old,item:item,session:session);guard let data=tx.oldData,try JSONDecoder().decode(Record.self,from:data)==old else{throw Failure(code:"audio_asset_transaction_invalid")}}
        else {guard tx.oldData==nil else{throw Failure(code:"audio_asset_transaction_invalid")}}
        if tx.kind=="rename" {guard let old=tx.old,old.assets.count==tx.new.assets.count,zip(old.assets,tx.new.assets).allSatisfy({$0.track==$1.track && $0.label==$1.label && $0.bytes==$1.bytes && $0.source==$1.source}) else{throw Failure(code:"audio_asset_transaction_invalid")}}
        else {guard tx.old?.assets.isEmpty != false else{throw Failure(code:"audio_asset_transaction_invalid")}}
        try rollback(tx,item:item)
    }
    private func transact(_ item:CachedMeeting,session:String,old:Record?,new:Record,kind:String,body:(URL)throws->Void)throws {
        let final=exportsRoot.appendingPathComponent(item.id,isDirectory:true),hadFolder=exists(final)
        if hadFolder {try ownedFolder(final,item:item,session:session)}
        try safe(exportsRoot);try fm.createDirectory(at:exportsRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let stageName=".audio-txn-"+UUID().uuidString,stage=exportsRoot.appendingPathComponent(stageName,isDirectory:true),metadata=item.directory.appendingPathComponent(metadataName),receipt=item.directory.appendingPathComponent(transactionName)
        let transaction=Transaction(schema:1,cacheID:item.id,session:session,stage:stageName,kind:kind,hadFolder:hadFolder,oldData:exists(metadata) ? try read(metadata):nil,old:old,new:new)
        try write(transaction,to:receipt)
        do {
            if hadFolder {try fm.moveItem(at:final,to:stage)}else {
                try fm.createDirectory(at:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                try JSONSerialization.data(withJSONObject:["schema":1,"cache_id":item.id,"session":session],options:.sortedKeys).write(to:stage.appendingPathComponent("meeting-owner.json"),options:.atomic)
            }
            try beforeStep?("staged");try body(stage);try beforeStep?("metadata")
            try write(new,to:metadata);try beforeStep?("publish")
            guard !exists(final) else{throw Failure(code:"audio_asset_collision")};try fm.moveItem(at:stage,to:final);try beforeStep?("published")
            try fm.removeItem(at:receipt)
        } catch {
            do {try rollback(transaction,item:item)}catch{throw Failure(code:"audio_asset_recovery_required")}
            throw error
        }
    }
    // Deletion calls this on its I/O queue before moving the cache and exports.
    // It never starts export work or touches another session's staging folder.
    func recoverPending(_ item:CachedMeeting)throws {try locked {let session=try scope(item);try recover(item,session:session)}}
    func rename(_ item:CachedMeeting,to raw:String,active:Bool)throws->MeetingAudioAssetInfo {try locked {
        guard !active else{throw Failure(code:"audio_asset_active")};let name=try Self.validatedName(raw),session=try scope(item)
        try recover(item,session:session);_=try plans(item)
        let old=try load(item,session:session)
        if old?.name==name {return try info(item)}
        var new=old ?? Record(schema:1,cacheID:item.id,session:session,name:defaultName(item),assets:[]);new.name=name
        new.assets=new.assets.map{Asset(track:$0.track,label:$0.label,file:fileName(name,$0.label),bytes:$0.bytes,source:$0.source)}
        if new.assets.isEmpty {_=try info(item);try beforeStep?("metadata");try write(new,to:item.directory.appendingPathComponent(metadataName));return try info(item)}
        let folder=exportsRoot.appendingPathComponent(item.id,isDirectory:true);try ownedFolder(folder,item:item,session:session);try validateFiles(old!,folder:folder)
        try ensureNoCollisions(new.assets.map{$0.file},in:folder,excluding:Set(old!.assets.map{$0.file}))
        try transact(item,session:session,old:old,new:new,kind:"rename") {stage in
            for (index,asset) in old!.assets.enumerated() {try beforeStep?("rename_"+String(index));let temp=stage.appendingPathComponent(".audio-rename-"+String(index));guard !exists(temp) else{throw Failure(code:"audio_asset_collision")};try fm.moveItem(at:stage.appendingPathComponent(asset.file),to:temp)}
            for (index,asset) in new.assets.enumerated() {let destination=stage.appendingPathComponent(asset.file);guard !exists(destination) else{throw Failure(code:"audio_asset_collision")};try fm.moveItem(at:stage.appendingPathComponent(".audio-rename-"+String(index)),to:destination)}
        }
        return try info(item)
    }}
    func export(_ item:CachedMeeting,active:Bool)throws->URL {try locked {
        guard !active else{throw Failure(code:"audio_asset_active")};let session=try scope(item);try recover(item,session:session)
        let source=try plans(item),old=try load(item,session:session),folder=exportsRoot.appendingPathComponent(item.id,isDirectory:true)
        if let old,!old.assets.isEmpty {
            guard old.assets.count==source.count,zip(old.assets,source).allSatisfy({$0.track==$1.track && $0.source==$1.fingerprint}) else{throw Failure(code:"audio_asset_source_changed")}
            try ownedFolder(folder,item:item,session:session);try validateFiles(old,folder:folder)
            return folder
        }
        let retirement=item.directory.appendingPathComponent("audio-retirement.json")
        if exists(retirement),try object(retirement)["state"] as? String=="trashed" {throw Failure(code:"audio_asset_retired")}
        let name=old?.name ?? defaultName(item)
        let new=Record(schema:1,cacheID:item.id,session:session,name:name,assets:source.map{Asset(track:$0.track,label:$0.label,file:fileName(name,$0.label),bytes:$0.bytes,source:$0.fingerprint)})
        if exists(folder){try ownedFolder(folder,item:item,session:session)}
        try ensureNoCollisions(new.assets.map{$0.file},in:folder)
        try transact(item,session:session,old:old,new:new,kind:"export") {stage in
            for (index,plan) in source.enumerated(){try beforeStep?("export_"+String(index));try stream(plan,to:stage.appendingPathComponent(new.assets[index].file))}
        }
        return folder
    }}
}
