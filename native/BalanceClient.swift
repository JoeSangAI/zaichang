import Foundation
import CryptoKit
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
struct BalanceCredentials {
    var accountLabel:String;var accessID:String;var secret:String;var securityToken:String
    func validate() throws {
        for value in [accessID,secret] {guard !value.isEmpty,value.count<=512,!value.contains(where:{$0.isWhitespace || $0.isNewline}),!value.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}),!value.hasPrefix("sk-") else{throw BalanceFailure.invalidCredentials}}
        guard securityToken.count<=8192,!securityToken.contains("\n"),!securityToken.contains("\r"),!securityToken.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{throw BalanceFailure.invalidCredentials}
    }
}
enum BalanceFailure:Error {case invalidCredentials,permissionUnconfirmed,notAuthorized,invalidResponse,transport,capacity}
func groupedDecimal(_ value:String)->String {let parts=value.split(separator:".",omittingEmptySubsequences:false);let integer=String(parts[0]);let sign=integer.hasPrefix("-") ? "-":"";let digits=sign.isEmpty ? integer:String(integer.dropFirst());let groups=stride(from:digits.count,to:0,by:-3).map {end -> String in let lo=digits.index(digits.startIndex,offsetBy:max(0,end-3));let hi=digits.index(digits.startIndex,offsetBy:end);return String(digits[lo..<hi])};return sign+groups.reversed().joined(separator:",")+(parts.count>1 ? "."+String(parts[1]):"")}
struct BalanceSnapshotState {
    var cash:String?;var available:String?;var currency:String?;var checked:Date?;var stale=false;var status="余额未连接"
    mutating func accept(_ data:Data,at:Date)throws {
        guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],let success=object["Success"] as? NSNumber,CFGetTypeID(success)==CFBooleanGetTypeID(),success.boolValue,let values=object["Data"] as? [String:Any],let currency=values["Currency"] as? String,["CNY","USD","JPY"].contains(currency) else{fail();throw BalanceFailure.invalidResponse}
        func amount(_ key:String)throws->String {
            guard let raw=values[key] as? String,raw.range(of:"^-?(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\\.[0-9]{1,8})?$",options:.regularExpression) != nil,let decimal=Decimal(string:raw.replacingOccurrences(of:",",with:"")),!decimal.isNaN else{throw BalanceFailure.invalidResponse}
            return NSDecimalNumber(decimal:decimal).stringValue
        }
        do {let c=try amount("AvailableCashAmount");let a=try amount("AvailableAmount");cash=c;available=a;self.currency=currency;checked=at;stale=false;status="余额已更新"} catch {fail();throw error}
    }
    mutating func fail(){stale=checked != nil;status=checked==nil ? "余额查询失败" : "余额快照已过期"}
    var display:String {guard let cash=cash else{return status};return "账户现金 "+(currency=="CNY" ? "¥" : (currency ?? "")+" ")+groupedDecimal(cash)+(stale ? "（过期）" : "")}
}
func balanceRequest(_ credentials:BalanceCredentials,at:Date,nonce:String,permissionConfirmed:Bool)throws->URLRequest {
    try credentials.validate();guard permissionConfirmed else{throw BalanceFailure.permissionUnconfirmed}
    let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime];formatter.timeZone=TimeZone(secondsFromGMT:0)
    var values=["Action":"QueryAccountBalance","Version":"2017-12-14","Format":"JSON","AccessKeyId":credentials.accessID,"SignatureMethod":"HMAC-SHA1","SignatureVersion":"1.0","SignatureNonce":nonce,"Timestamp":formatter.string(from:at)]
    if !credentials.securityToken.isEmpty {values["SecurityToken"]=credentials.securityToken}
    let allowed=CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    func encode(_ value:String)->String {value.addingPercentEncoding(withAllowedCharacters:allowed)!}
    let canonical=values.keys.sorted().map{encode($0)+"="+encode(values[$0]!)}.joined(separator:"&")
    let signature=HMAC<Insecure.SHA1>.authenticationCode(for:Data(("GET&%2F&"+encode(canonical)).utf8),using:SymmetricKey(data:Data((credentials.secret+"&").utf8)))
    values["Signature"]=Data(signature).base64EncodedString()
    let query=values.keys.sorted().map{encode($0)+"="+encode(values[$0]!)}.joined(separator:"&")
    var request=URLRequest(url:URL(string:"https://business.aliyuncs.com/?"+query)!);request.httpMethod="GET";request.cachePolicy = .reloadIgnoringLocalCacheData;request.timeoutInterval=10
    return request // Never print the URL; it includes access ID/token/signature.
}
final class BalanceTransport:NSObject,URLSessionDataDelegate,URLSessionTaskDelegate {
    private var data=Data();private var continuation:CheckedContinuation<Data,Error>?;private var session:URLSession?;private var finished=false;private var resultError:Error?
    func fetch(_ request:URLRequest) async throws->Data {
        guard request.url?.scheme=="https",request.url?.host=="business.aliyuncs.com" else{throw BalanceFailure.notAuthorized}
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation=continuation;let config=URLSessionConfiguration.ephemeral;config.urlCache=nil;config.httpCookieStorage=nil;config.urlCredentialStorage=nil;config.timeoutIntervalForRequest=10;config.timeoutIntervalForResource=15
            let queue=OperationQueue();queue.maxConcurrentOperationCount=1;let session=URLSession(configuration:config,delegate:self,delegateQueue:queue);self.session=session;session.dataTask(with:request).resume()
        }
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void){completionHandler(nil);resultError=BalanceFailure.transport}
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping (URLSession.ResponseDisposition)->Void) {
        guard let http=response as? HTTPURLResponse,http.statusCode==200,response.expectedContentLength<=65536 else{resultError=BalanceFailure.transport;completionHandler(.cancel);return};completionHandler(.allow)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive chunk:Data) {if data.count+chunk.count>65536 {resultError=BalanceFailure.capacity;dataTask.cancel()} else{data.append(chunk)}}
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        guard !finished else{return};finished=true;let completion=continuation;continuation=nil
        if let error=resultError ?? error {completion?.resume(throwing:error)} else{completion?.resume(returning:data)}
        data=Data();session.finishTasksAndInvalidate();self.session=nil
    }
}
func balanceNativeChecks()->Int {
    var count=0;let c=BalanceCredentials(accountLabel:"fake",accessID:"fake-id",secret:"fake-secret",securityToken:"")
    let request=try! balanceRequest(c,at:Date(timeIntervalSince1970:1790899200),nonce:"fake-nonce",permissionConfirmed:true)
    let parts=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!;precondition(parts.first{$0.name=="Signature"}!.value=="oFUbqyehzSNQ/gOrEtE3dORz+5o=");count+=1
    do {_ = try balanceRequest(c,at:Date(),nonce:"x",permissionConfirmed:false);preconditionFailure()}catch{count+=1}
    var snapshot=BalanceSnapshotState();try! snapshot.accept(Data("{\"Success\":true,\"Data\":{\"AvailableCashAmount\":\"1,234.56\",\"AvailableAmount\":\"2345.67\",\"Currency\":\"CNY\"}}".utf8),at:Date(timeIntervalSince1970:1));precondition(snapshot.cash=="1234.56" && snapshot.display=="账户现金 ¥1,234.56");count+=1
    do {try snapshot.accept(Data("{\"Success\":false}".utf8),at:Date());preconditionFailure()} catch {precondition(snapshot.cash=="1234.56" && snapshot.stale);count+=1}
    do {try snapshot.accept(Data("{\"Success\":1,\"Data\":{\"AvailableCashAmount\":\"9\",\"AvailableAmount\":\"9\",\"Currency\":\"CNY\"}}".utf8),at:Date());preconditionFailure()}catch{precondition(snapshot.cash=="1234.56");count+=1}
    return count
}
