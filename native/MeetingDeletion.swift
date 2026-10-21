import Foundation

struct MeetingDeletionReceipt:Codable {
    let schema:Int;let id:String;let cacheID:String;let session:String;let title:String;let createdAt:Double;let resources:[String]
    var state:String
}
// This application recycle bin retains originals indefinitely. Each transaction
// moves exact session-owned directories; there is no purge or filename glob.
final class MeetingDeletionStore {
    let cacheRoot:URL;let binRoot:URL;let exportsRoot:URL
    let legacyAudioTrashRoot:URL
    let fm=FileManager.default
    var beforeMove:((Int)throws->Void)?
    init(cacheRoot:URL,binRoot:URL?=nil,exportsRoot:URL?=nil,legacyAudioTrashRoot:URL?=nil){self.legacyAudioTrashRoot=(legacyAudioTrashRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")).standardizedFileURL;self.cacheRoot=cacheRoot.standardizedFileURL;self.binRoot=(binRoot ?? cacheRoot.deletingLastPathComponent().appendingPathComponent("DeletedMeetings")).standardizedFileURL;self.exportsRoot=(exportsRoot ?? cacheRoot.deletingLastPathComponent().appendingPathComponent("MeetingExports")).standardizedFileURL}
    private func safe(_ url:URL,recursive:Bool=true)throws {
        guard url.path==url.resolvingSymlinksInPath().standardizedFileURL.path else{throw Failure(code:"meeting_delete_symlink")}
        if fm.fileExists(atPath:url.path) {
            let attrs=try fm.attributesOfItem(atPath:url.path)
            guard attrs[.type] as? FileAttributeType != .typeSymbolicLink else{throw Failure(code:"meeting_delete_symlink")}
            if recursive,attrs[.type] as? FileAttributeType == .typeDirectory {
                var enumerationError:Error?
                guard let it=fm.enumerator(at:url,includingPropertiesForKeys:[.isSymbolicLinkKey],options:[],errorHandler:{_,error in enumerationError=error;return false}) else{throw Failure(code:"meeting_delete_unreadable")}
                for case let file as URL in it {guard try file.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else{throw Failure(code:"meeting_delete_symlink")}}
                if let enumerationError {throw enumerationError}
            }
        }
    }
    private func roots()throws {
        // Explicit roots cannot nest inside one another or shared Voiceprints.
        let paths=[cacheRoot.path,binRoot.path,exportsRoot.path];guard Set(paths).count==3,!paths.contains(where:{a in paths.contains(where:{b in a != b && a.hasPrefix(b+"/")})}) else{throw Failure(code:"meeting_delete_root_scope")}
        for url in [cacheRoot,binRoot,exportsRoot] {try safe(url,recursive:false)}
    }
    private func source(_ resource:String,_ cacheID:String)throws->URL {
        guard UUID(uuidString:cacheID) != nil else{throw Failure(code:"meeting_delete_id")}
        switch resource {case "cache":return cacheRoot.appendingPathComponent(cacheID);case "retired":return cacheRoot.appendingPathComponent(".retired").appendingPathComponent(cacheID);case "exports":return exportsRoot.appendingPathComponent(cacheID);default:throw Failure(code:"meeting_delete_resource")}
    }
    func folder(_ receipt:MeetingDeletionReceipt)throws->URL {
        guard receipt.schema==1,UUID(uuidString:receipt.id) != nil,UUID(uuidString:receipt.cacheID) != nil,!receipt.session.isEmpty,Set(receipt.resources).count==receipt.resources.count,receipt.resources.contains("cache"),receipt.resources.allSatisfy({["cache","retired","exports"].contains($0)}),["prepared","trashed","restoring","restored","rolled_back","recovery_required"].contains(receipt.state) else{throw Failure(code:"meeting_delete_receipt")}
        let folder=binRoot.appendingPathComponent(receipt.id);try safe(folder);return folder
    }
    private func save(_ receipt:MeetingDeletionReceipt)throws {let target=try folder(receipt);try JSONEncoder().encode(receipt).write(to:target.appendingPathComponent("receipt.json"),options:.atomic)}
    func receipts(includeRestored:Bool=false)throws->[MeetingDeletionReceipt] {
        try roots();guard fm.fileExists(atPath:binRoot.path) else{return []}
        return try fm.contentsOfDirectory(at:binRoot,includingPropertiesForKeys:nil).filter{UUID(uuidString:$0.lastPathComponent) != nil}.compactMap{url in
            try safe(url);let receipt=try JSONDecoder().decode(MeetingDeletionReceipt.self,from:Data(contentsOf:url.appendingPathComponent("receipt.json")));guard receipt.id==url.lastPathComponent else{throw Failure(code:"meeting_delete_receipt")};_=try folder(receipt);return (["trashed","prepared","restoring","recovery_required"].contains(receipt.state) || (includeRestored && receipt.state=="restored")) ? receipt:nil
        }.sorted{$0.createdAt>$1.createdAt}
    }
    func trash(_ item:CachedMeeting,afterMove:((String)throws->Void)?=nil)throws->MeetingDeletionReceipt {
        try roots();let cache=try source("cache",item.id)
        guard cache.path==item.directory.standardizedFileURL.path else{throw Failure(code:"meeting_delete_scope")};try safe(cache)
        guard fm.fileExists(atPath:cache.path) else{throw Failure(code:"meeting_already_deleted")}
        let metadata=try item.metadata();guard (metadata["cache_id"] as? String ?? item.id)==item.id,let session=metadata["session"] as? String,!session.isEmpty else{throw Failure(code:"meeting_delete_session")}
        var resources:[String]=[]
        let retirement=cache.appendingPathComponent("audio-retirement.json")
        if fm.fileExists(atPath:retirement.path) {
            let info=try JSONSerialization.jsonObject(with:Data(contentsOf:retirement)) as? [String:Any]
            if info?["state"] as? String=="trashed" {
                let expected=try source("retired",item.id)
                guard info?["cache_id"] as? String==item.id,let destination=info?["destination"] as? String,info?["recoverable"] as? Bool==true else{throw Failure(code:"meeting_delete_retirement_scope")}
                if destination==expected.path {
                    guard fm.fileExists(atPath:expected.path) else{throw Failure(code:"meeting_delete_retirement_scope")}
                    try safe(expected);resources.append("retired")
                } else {
                    // Older versions retired audio to macOS Trash. Preserve the
                    // reference with the cache, without accessing that location.
                    let legacy=URL(fileURLWithPath:destination),prefix=".audio-retirement-"
                    guard legacy.path==legacy.standardizedFileURL.path,legacy.deletingLastPathComponent().path==legacyAudioTrashRoot.path,legacy.lastPathComponent.hasPrefix(prefix),UUID(uuidString:String(legacy.lastPathComponent.dropFirst(prefix.count))) != nil else{throw Failure(code:"meeting_delete_retirement_scope")}
                }
            }
        }
        let exports=try source("exports",item.id)
        if fm.fileExists(atPath:exports.path) {
            try safe(exports)
            let owner=try JSONSerialization.jsonObject(with:Data(contentsOf:exports.appendingPathComponent("meeting-owner.json"))) as? [String:Any]
            guard owner?["cache_id"] as? String==item.id,owner?["session"] as? String==session else{throw Failure(code:"meeting_delete_export_scope")}
            resources.append("exports")
        }
        resources.append("cache")
        var receipt=MeetingDeletionReceipt(schema:1,id:UUID().uuidString,cacheID:item.id,session:session,title:item.displayTitle,createdAt:Date().timeIntervalSince1970,resources:resources,state:"prepared")
        try fm.createDirectory(at:binRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let transaction=try folder(receipt);try fm.createDirectory(at:transaction,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);try save(receipt)
        var moved:[String]=[]
        do {
            for (index,resource) in resources.enumerated() {try beforeMove?(index);let origin=try source(resource,item.id);try safe(origin);try fm.moveItem(at:origin,to:transaction.appendingPathComponent(resource));moved.append(resource)}
            receipt.state="trashed";try save(receipt)
            // Projection removal runs after the folder moves. A failed SQLite
            // transaction restores all originals before returning failure.
            try afterMove?(session)
            return receipt
        } catch {
            var rollbackFailed=false
            for resource in moved.reversed() {do {try fm.moveItem(at:transaction.appendingPathComponent(resource),to:source(resource,item.id))}catch{rollbackFailed=true}}
            receipt.state=rollbackFailed ? "recovery_required":"rolled_back";try? save(receipt)
            if rollbackFailed {throw Failure(code:"meeting_delete_rollback_recovery_required")};throw error
        }
    }
    func restore(_ original:MeetingDeletionReceipt,afterMove:((String)throws->Void)?=nil)throws {
        try roots();let transaction=try folder(original)
        var receipt=try JSONDecoder().decode(MeetingDeletionReceipt.self,from:Data(contentsOf:transaction.appendingPathComponent("receipt.json")))
        _=try folder(receipt)
        guard receipt.id==original.id,receipt.cacheID==original.cacheID,receipt.session==original.session,receipt.resources==original.resources,receipt.state != "restored",receipt.state != "rolled_back" else{throw Failure(code:"meeting_restore_receipt")}
        // Check every collision before moving anything, including dangling links.
        var resources:[String]=[]
        for resource in receipt.resources {
            let payload=transaction.appendingPathComponent(resource),destination=try source(resource,receipt.cacheID);try safe(payload);try safe(destination)
            if fm.fileExists(atPath:payload.path) {guard !fm.fileExists(atPath:destination.path) else{throw Failure(code:"meeting_restore_collision")};resources.append(resource)}
            else {guard ["prepared","restoring","recovery_required"].contains(receipt.state),fm.fileExists(atPath:destination.path) else{throw Failure(code:"meeting_restore_payload_missing")}}
        }
        let cache=resources.contains("cache") ? transaction.appendingPathComponent("cache"):cacheRoot.appendingPathComponent(receipt.cacheID)
        let metadata=try JSONSerialization.jsonObject(with:Data(contentsOf:cache.appendingPathComponent("meeting.json"))) as? [String:Any]
        guard metadata?["session"] as? String==receipt.session else{throw Failure(code:"meeting_restore_session")}
        receipt.state="restoring";try save(receipt);var moved:[String]=[]
        do {
            for (index,resource) in resources.enumerated(){try beforeMove?(index);let destination=try source(resource,receipt.cacheID);try fm.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true);try fm.moveItem(at:transaction.appendingPathComponent(resource),to:destination);moved.append(resource)}
            receipt.state="restored";try save(receipt);try afterMove?(receipt.session)
        } catch {
            var rollbackFailed=false
            for resource in moved.reversed(){do {try fm.moveItem(at:source(resource,receipt.cacheID),to:transaction.appendingPathComponent(resource))}catch{rollbackFailed=true}}
            receipt.state=rollbackFailed ? "recovery_required":"trashed";try? save(receipt)
            if rollbackFailed {throw Failure(code:"meeting_restore_rollback_recovery_required")};throw error
        }
    }
}
