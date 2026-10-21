import Foundation
import CryptoKit
import Security
struct ProfileStorageGrant {
    var purposeAccepted=false;var keychainKeyAccepted=false;var localFolderAccepted=false;var backupDeletionAccepted=false
    var complete:Bool {purposeAccepted && keychainKeyAccepted && localFolderAccepted && backupDeletionAccepted}
}
protocol ProfileKeyProvider {func key(create:Bool)throws->SymmetricKey;func deleteKey()throws}
enum ProfileStoreError:Error {case permission,domain,invalid,missingKey}
final class FakeProfileKeyProvider:ProfileKeyProvider {
    private var value:SymmetricKey?=SymmetricKey(data:Data(repeating:0x31,count:32))
    func key(create:Bool)throws->SymmetricKey {if let key=value {return key};if create {let key=SymmetricKey(data:Data(repeating:0x31,count:32));value=key;return key};throw ProfileStoreError.missingKey}
    func deleteKey()throws{value=nil}
}
struct KeychainProfileProvider:ProfileKeyProvider {
    let permitted:Bool;static let service="com.zaichang.app.identity-v2"
    func key(create:Bool)throws->SymmetricKey {
        guard permitted,Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool != true else{throw ProfileStoreError.permission}
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:Self.service,kSecAttrAccount as String:"archive-aes-256",kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var item:CFTypeRef?;let status=SecItemCopyMatching(query as CFDictionary,&item)
        if status==errSecSuccess,let data=item as? Data,data.count==32 {return SymmetricKey(data:data)}
        guard status==errSecItemNotFound,create else{throw ProfileStoreError.missingKey}
        var bytes=[UInt8](repeating:0,count:32);guard SecRandomCopyBytes(kSecRandomDefault,32,&bytes)==errSecSuccess else{throw ProfileStoreError.invalid}
        var trusted:SecTrustedApplication?;var access:SecAccess?
        guard SecTrustedApplicationCreateFromPath(Bundle.main.executablePath,&trusted)==errSecSuccess,let trusted=trusted,SecAccessCreate("在场本机身份档案密钥" as CFString,[trusted] as CFArray,&access)==errSecSuccess,let access=access else{throw ProfileStoreError.permission}
        let attributes:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:Self.service,kSecAttrAccount as String:"archive-aes-256",kSecAttrAccess as String:access,kSecValueData as String:Data(bytes)]
        guard SecItemAdd(attributes as CFDictionary,nil)==errSecSuccess else{throw ProfileStoreError.permission};return SymmetricKey(data:Data(bytes))
    }
    func deleteKey()throws {
        guard permitted,Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool != true else{throw ProfileStoreError.permission}
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:Self.service,kSecAttrAccount as String:"archive-aes-256"]
        let code=SecItemDelete(query as CFDictionary);guard code==errSecSuccess || code==errSecItemNotFound else{throw ProfileStoreError.permission}
    }
}
struct ProfileArchiveEnvelope:Codable {let schema:Int;let partition:String;let domain:String;let state:Data}
final class ProfileArchiveStore {
    let folder:URL;let domain:String;let keys:ProfileKeyProvider;let grant:ProfileStorageGrant
    var main:URL {folder.appendingPathComponent("identity.aesgcm")};var backup:URL {folder.appendingPathComponent("identity.backup.aesgcm")}
    init(folder:URL,domain:String,keys:ProfileKeyProvider,grant:ProfileStorageGrant){self.folder=folder;self.domain=domain;self.keys=keys;self.grant=grant}
    func persistableState(_ state:[String:Any])->[String:Any] {
        guard domain=="consented_live_audio" else{return state}
        let consents=state["consents"] as? [String:[String:Any]] ?? [:]
        let allowed=Set(consents.filter{$0.value["active"] as? Bool==true && $0.value["persistent_allowed"] as? Bool==true}.map{$0.key})
        let people=state["people"] as? [String:String] ?? [:]
        // Compare who, not how many: a stale consent for someone no longer listed must
        // not let an unconsented person's samples through when the counts happen to match.
        guard allowed != Set(people.keys) else{return state}
        var filtered=state;filtered["people"]=people.filter{allowed.contains($0.key)};filtered["consents"]=consents.filter{allowed.contains($0.key)}
        let samples=(state["samples"] as? [[String:Any]] ?? []).filter{allowed.contains($0["person_id"] as? String ?? "")};filtered["samples"]=samples
        let sampleIDs=Set(samples.compactMap{$0["sample_id"] as? String})
        filtered["sample_sources"]=(state["sample_sources"] as? [String:Any] ?? [:]).filter{sampleIDs.contains($0.key)}
        filtered["manual"]=(state["manual"] as? [String:String] ?? [:]).filter{allowed.contains($0.value)}
        filtered["feedback"]=(state["feedback"] as? [String:[String:Any]] ?? [:]).filter{allowed.contains($0.value["person_id"] as? String ?? "")}
        // A withdrawn storage purpose must not survive in undo history or replay receipts.
        filtered["journal"]=[];filtered["receipts"]=[String:Any]()
        return filtered
    }
    private func validate(_ state:[String:Any])throws {
        guard grant.complete,domain=="synthetic_model_output" || domain=="consented_live_audio",state["schema"] as? Int==1,state["partition"] as? String==SpeakerEmbeddingBackend.partition,state["input_kind"] as? String==domain,let people=state["people"] as? [String:String],let consents=state["consents"] as? [String:[String:Any]],let samples=state["samples"] as? [[String:Any]],samples.count<=60,people.count<=12 else{throw ProfileStoreError.domain}
        for sample in samples {
            guard let person=sample["person_id"] as? String,people[person] != nil,let consent=consents[person],consent["active"] as? Bool==true,sample["consent_id"] as? String==consent["consent_id"] as? String,sample["model_version"] as? String==SpeakerEmbeddingBackend.partition,domain=="synthetic_model_output" || consent["persistent_allowed"] as? Bool==true,let vector=sample["vector"] as? [Double],vector.count==192,vector.allSatisfy({$0.isFinite}),abs(vector.reduce(0){$0+$1*$1}-1)<0.001 else{throw ProfileStoreError.invalid}
        }
    }
    private func prepareFolder()throws {
        if FileManager.default.fileExists(atPath:folder.path) {guard try folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else{throw ProfileStoreError.invalid}}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:folder.path)
        for url in [main,backup] where FileManager.default.fileExists(atPath:url.path) {guard try url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else{throw ProfileStoreError.invalid}}
    }
    func save(_ state:[String:Any],rewriteBackup:Bool=false)throws {
        try validate(state);try prepareFolder();let payload=try JSONSerialization.data(withJSONObject:state,options:[.sortedKeys]);guard payload.count<=4_000_000 else{throw ProfileStoreError.invalid}
        let envelope=ProfileArchiveEnvelope(schema:2,partition:SpeakerEmbeddingBackend.partition,domain:domain,state:payload)
        let key=try keys.key(create:true);let encrypted=try AES.GCM.seal(JSONEncoder().encode(envelope),using:key,authenticating:Data(("meeting-profile-v2:"+domain).utf8)).combined!
        guard encrypted.count<=4_000_000 else{throw ProfileStoreError.invalid}
        if rewriteBackup {try encrypted.write(to:backup,options:.atomic)} else if FileManager.default.fileExists(atPath:main.path) {let previous=try Data(contentsOf:main);try previous.write(to:backup,options:.atomic)}
        try encrypted.write(to:main,options:.atomic)
        for url in [main,backup] where FileManager.default.fileExists(atPath:url.path) {try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
    }
    func load(useBackup:Bool=false)throws->[String:Any] {
        guard grant.complete else{throw ProfileStoreError.permission};let url=useBackup ? backup : main
        guard try folder.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true,try url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else{throw ProfileStoreError.invalid}
        let attrs=try FileManager.default.attributesOfItem(atPath:url.path);let size=(attrs[.size] as? NSNumber)?.intValue ?? 4_000_001;guard size<=4_000_000 else{throw ProfileStoreError.invalid}
        let key=try keys.key(create:false);let sealed=try Data(contentsOf:url)
        let raw=try AES.GCM.open(AES.GCM.SealedBox(combined:sealed),using:key,authenticating:Data(("meeting-profile-v2:"+domain).utf8))
        let envelope=try JSONDecoder().decode(ProfileArchiveEnvelope.self,from:raw);guard envelope.schema==2,envelope.partition==SpeakerEmbeddingBackend.partition,envelope.domain==domain,let state=try JSONSerialization.jsonObject(with:envelope.state) as? [String:Any] else{throw ProfileStoreError.domain}
        try validate(state);return state
    }
    func removeAll()throws {
        guard grant.complete else{throw ProfileStoreError.permission}
        for url in [main,backup] where FileManager.default.fileExists(atPath:url.path) {try FileManager.default.removeItem(at:url)}
        try keys.deleteKey() // no promise of forensic disk or external-system-backup erasure
    }
}
func profileFileChecks(folder:URL)throws->Int {
    var count=0;let grant=ProfileStorageGrant(purposeAccepted:true,keychainKeyAccepted:true,localFolderAccepted:true,backupDeletionAccepted:true);let keys=FakeProfileKeyProvider();let store=ProfileArchiveStore(folder:folder,domain:"synthetic_model_output",keys:keys,grant:grant)
    let sample:[String:Any]=["sample_id":"fake-s","person_id":"fake-p","vector":[1.0]+[Double](repeating:0,count:191),"model_version":SpeakerEmbeddingBackend.partition,"consent_id":"fake-c","feedback_id":"fake-f","quality_ok":true,"overlap":false]
    var state:[String:Any]=["schema":1,"partition":SpeakerEmbeddingBackend.partition,"input_kind":"synthetic_model_output","people":["fake-p":"假人物"],"consents":["fake-p":["consent_id":"fake-c","active":true,"persistent_allowed":false]],"samples":[sample],"journal":[]]
    try store.save(state);let loaded=try store.load();precondition(loaded["samples"] is [[String:Any]]);count+=1
    try store.save(state);precondition(FileManager.default.fileExists(atPath:store.backup.path));count+=1
    let mode=(try FileManager.default.attributesOfItem(atPath:store.main.path)[.posixPermissions] as? NSNumber)?.intValue;precondition(mode==0o600);count+=1
    let forbidden=ProfileArchiveStore(folder:folder,domain:"consented_live_audio",keys:keys,grant:grant)
    do {_ = try forbidden.load();preconditionFailure()}catch{count+=1}
    var tampered=try Data(contentsOf:store.main);tampered[tampered.count-1] ^= 1;try tampered.write(to:store.main)
    do {_ = try store.load();preconditionFailure()}catch{count+=1}
    let restoredBackup=try store.load(useBackup:true);precondition(restoredBackup["people"] is [String:String]);count+=1
    state["samples"]=[];state["people"]=[String:String]();state["consents"]=[String:[String:Any]]();try store.save(state,rewriteBackup:true)
    let deletedBackup=try store.load(useBackup:true);precondition((deletedBackup["samples"] as! [[String:Any]]).isEmpty);count+=1
    try store.removeAll();precondition(!FileManager.default.fileExists(atPath:store.main.path) && !FileManager.default.fileExists(atPath:store.backup.path));count+=1
    do {_ = try keys.key(create:false);preconditionFailure()}catch{count+=1}
    let denied=ProfileArchiveStore(folder:folder,domain:"synthetic_model_output",keys:FakeProfileKeyProvider(),grant:ProfileStorageGrant())
    do {try denied.save(state);preconditionFailure()}catch{count+=1}
    var mismatch=state;mismatch["people"]=["fake-p":"假人物"];mismatch["consents"]=["fake-p":["consent_id":"different","active":true]];mismatch["samples"]=[sample]
    do {try store.save(mismatch);preconditionFailure()}catch{count+=1}
    var withdrawal=mismatch;withdrawal["consents"]=["fake-p":["consent_id":"fake-c","active":true,"persistent_allowed":false]];withdrawal["input_kind"]="consented_live_audio";withdrawal["journal"]=[["state":withdrawal]]
    let cleaned=forbidden.persistableState(withdrawal);precondition((cleaned["samples"] as! [[String:Any]]).isEmpty && (cleaned["journal"] as! [Any]).isEmpty);count+=1
    // Equal counts must not skip the filter: B is not allowed to persist, while a
    // stale consent for C (no longer listed) keeps the allowed count at two.
    var equalCounts=withdrawal;equalCounts["people"]=["fake-a":"甲","fake-b":"乙"]
    equalCounts["consents"]=["fake-a":["active":true,"persistent_allowed":true],"fake-b":["active":true,"persistent_allowed":false],"fake-c":["active":true,"persistent_allowed":true]]
    equalCounts["samples"]=[["person_id":"fake-a","sample_id":"s-a"],["person_id":"fake-b","sample_id":"s-b"]]
    let equalCleaned=forbidden.persistableState(equalCounts)
    precondition((equalCleaned["people"] as! [String:String]).keys.sorted()==["fake-a"] && (equalCleaned["samples"] as! [[String:Any]]).count==1);count+=1
    return count
}
