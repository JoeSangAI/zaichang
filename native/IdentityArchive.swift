import Foundation
import CryptoKit
struct PersonConsent:Codable,Equatable {
    let personID:String;let consentID:String;let informedAt:Date
    var persistentVoiceprintAllowed:Bool;var revokedAt:Date?
    var active:Bool {persistentVoiceprintAllowed && revokedAt==nil}
}
struct IdentityArchive:Codable {
    var version=1;var consents:[PersonConsent]=[];var records:[String:Data]=[:]
    mutating func revoke(personID:String,at:Date) {
        for i in consents.indices where consents[i].personID==personID {consents[i].revokedAt=at;consents[i].persistentVoiceprintAllowed=false}
        records.removeValue(forKey:personID)
    }
    mutating func forget(personID:String) {consents.removeAll{$0.personID==personID};records.removeValue(forKey:personID)}
    func sealed(using key:SymmetricKey,personConfirmed:Bool)throws->Data {
        guard personConfirmed,records.keys.allSatisfy({ id in consents.contains{$0.personID==id && $0.active}}) else {throw CocoaError(.fileWriteNoPermission)}
        return try AES.GCM.seal(JSONEncoder().encode(self),using:key,authenticating:Data("meeting-identity-v1".utf8)).combined!
    }
    static func open(_ encrypted:Data,using key:SymmetricKey)throws->IdentityArchive {
        let raw=try AES.GCM.open(AES.GCM.SealedBox(combined:encrypted),using:key,authenticating:Data("meeting-identity-v1".utf8))
        return try JSONDecoder().decode(IdentityArchive.self,from:raw)
    }
}
struct BalanceConnectionDraft {
    var accountLabel=""
    let endpoint="https://business.aliyuncs.com/"
    let action="bss:DescribeAcccount"
    var personAuthorized=false
    var credentialService="com.zaichang.app.balance"
    var connected:Bool {false} // network client deliberately absent until RAM authorization
}
func identityArchiveChecks()->Int {
    let key=SymmetricKey(data:Data(repeating:0x11,count:32));var archive=IdentityArchive()
    archive.consents=[PersonConsent(personID:"fake-person",consentID:"fake-consent",informedAt:Date(timeIntervalSince1970:0),persistentVoiceprintAllowed:true,revokedAt:nil)]
    archive.records["fake-person"]=Data([1,2,3])
    let sealed=try! archive.sealed(using:key,personConfirmed:true)
    precondition(try! IdentityArchive.open(sealed,using:key).records["fake-person"]==Data([1,2,3]))
    do {_ = try archive.sealed(using:key,personConfirmed:false);preconditionFailure()}catch{}
    var tampered=sealed;tampered[tampered.count-1] ^= 1
    do {_ = try IdentityArchive.open(tampered,using:key);preconditionFailure()}catch{}
    do {_ = try IdentityArchive.open(sealed,using:SymmetricKey(data:Data(repeating:0x22,count:32)));preconditionFailure()}catch{}
    archive.revoke(personID:"fake-person",at:Date(timeIntervalSince1970:1));precondition(archive.records.isEmpty && !archive.consents[0].active)
    archive.forget(personID:"fake-person");precondition(archive.consents.isEmpty)
    return 6
}
