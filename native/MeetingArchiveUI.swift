import AppKit
import Foundation
import WebKit
import ObjectiveC

enum MeetingArchiveEligibility {
    static func historyReaderBlocked(historyReader:Bool,automatic:Bool)->Bool {historyReader && automatic}
    static func transcriptComplete(phase:RecordingPhase,cachedComplete:Bool,pausedTail:[String:String],historyReader:Bool=false)->Bool {
        if historyReader {return cachedComplete}
        if phase == .stopped {return cachedComplete}
        return phase == .paused && !pausedTail.isEmpty && pausedTail.values.allSatisfy{$0=="complete"}
    }
    static func coarseSettled(hasArtifact:Bool,errorCode:String?)->Bool {
        hasArtifact || ["coarse_no_complete_text","coarse_audio_missing"].contains(errorCode)
    }
    static func coarseTokenMatches(cacheID:String,session:String,generation:Int,revision:Int,sourceSHA256:String,snapshotSHA256:String,
                                   currentCacheID:String?,currentSession:String?,currentGeneration:Int,currentRevision:Int,artifactExists:Bool)->Bool {
        artifactExists && cacheID==currentCacheID && session==currentSession && generation==currentGeneration && revision==currentRevision &&
        !sourceSHA256.isEmpty && !snapshotSHA256.isEmpty
    }
    static func allows(phase:RecordingPhase,transcriptionComplete:Bool,localOnly:Bool,historyReader:Bool,automatic:Bool=false,
                       refinementBusy:Bool,projectionPending:Bool,coarseSettled:Bool=true,qaOrMock:Bool,resumePending:Bool)->Bool {
        let phaseReady=[.paused,.stopped].contains(phase) || (historyReader && !automatic && transcriptionComplete)
        return phaseReady && transcriptionComplete && !localOnly && !(historyReader && automatic) &&
        !refinementBusy && !projectionPending && coarseSettled && !(automatic && qaOrMock) && !resumePending
    }
}

enum MeetingArchiveRequest {
    static var origin:String {RuntimeConfiguration.archiveConfiguration?.url ?? ""}
    static let acceptedMessage="已发起归档准备，正在读取最新进度。"
    static let requestTimeout:TimeInterval=8
    static let resourceTimeout:TimeInterval=15
    static let bootstrapPath="/api/meeting-archives-bootstrap"

    static func bootstrapURL()->URL? {RuntimeConfiguration.archiveEnabled ? URL(string:origin+bootstrapPath):nil}

    static func validatedCSRFToken(data:Data?,response:URLResponse?,error:Error?)throws->String {
        guard error==nil,let response=response as? HTTPURLResponse,(200..<300).contains(response.statusCode),
              let data,let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              RuntimeConfiguration.archiveEnabled,
              value["app_id"] as? String==RuntimeConfiguration.archiveConfiguration?.appID,
              let token=value["csrf_token"] as? String,!token.isEmpty else{throw Failure(code:"meeting_archive_bootstrap_invalid")}
        return token
    }

    static func pageURL(session:String)throws->URL {
        guard RuntimeConfiguration.archiveEnabled,var components=URLComponents(string:origin+"/") else{throw Failure(code:"meeting_archive_unconfigured")}
        components.queryItems=[URLQueryItem(name:"page",value:"archive"),URLQueryItem(name:"session",value:session)]
        guard let url=components.url else{throw Failure(code:"meeting_archive_url_invalid")}
        return url
    }

    static func prepareURL(session:String)throws->URL {
        guard RuntimeConfiguration.archiveEnabled,let safe=session.addingPercentEncoding(withAllowedCharacters:CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")),
              let url=URL(string:origin+"/api/meeting-archives/"+safe+"/prepare") else {
            throw Failure(code:"meeting_archive_url_invalid")
        }
        return url
    }

    static func prepareRequest(session:String,csrfToken:String)throws->URLRequest {
        guard !csrfToken.isEmpty else{throw Failure(code:"meeting_archive_csrf_missing")}
        var request=URLRequest(url:try prepareURL(session:session));request.httpMethod="POST"
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue(origin,forHTTPHeaderField:"Origin")
        request.setValue(csrfToken,forHTTPHeaderField:"X-CSRF-Token")
        request.httpBody=Data("{}".utf8)
        return request
    }
}

private final class MeetingArchiveSheetWindow:NSWindow {
    weak var panelController:MeetingArchivePanel?
    override func cancelOperation(_ sender:Any?) {panelController?.closePanel()}
}

private final class MeetingArchivePanel:NSObject,NSWindowDelegate,WKNavigationDelegate {
    weak var owner:Delegate?
    private(set) var window:NSWindow?
    private var webView:WKWebView?
    private var status:NSTextField?
    private var retryButton:NSButton?
    private(set) var closeButton:NSButton?
    private var inFlight=Set<String>()
    private var attempted=Set<String>()
    private var preparationEpoch=0
    weak var button:NSButton?
    private let networkSession:URLSession = {
        let configuration=URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest=MeetingArchiveRequest.requestTimeout
        configuration.timeoutIntervalForResource=MeetingArchiveRequest.resourceTimeout
        configuration.waitsForConnectivity=false
        return URLSession(configuration:configuration)
    }()

    init(owner:Delegate){self.owner=owner}

    func eligible(_ owner:Delegate,requireCoarse:Bool)->Bool {
        guard RuntimeConfiguration.archiveEnabled else{return false}
        let transcriptionComplete=MeetingArchiveEligibility.transcriptComplete(phase:owner.phase.phase,cachedComplete:owner.cachedTranscriptionComplete,pausedTail:owner.pausedTailStates,historyReader:owner.isHistoryReader)
        let settledFailure=owner.speakerRefinementFailureRevision==owner.naming.correctionRevision ? owner.speakerRefinementFailureCode:nil
        let coarseSettled=MeetingArchiveEligibility.coarseSettled(hasArtifact:owner.hasCurrentCoarseResult,errorCode:settledFailure)
        return MeetingArchiveEligibility.allows(phase:owner.phase.phase,transcriptionComplete:transcriptionComplete,
            localOnly:owner.sessionLocalOnly || owner.localOnlyMode,
            historyReader:owner.isHistoryReader,automatic:requireCoarse,
            refinementBusy:owner.hasRunningCoarseRefinement,
            projectionPending:owner.fullTranscriptRefreshPending || owner.fullRefreshBuildInFlight ||
                !owner.dirtyTranscriptParents.isEmpty || owner.dirtyTranscriptQueueIndex<owner.dirtyTranscriptQueue.count ||
                owner.indexedCorrectionRevision != owner.naming.correctionRevision,
            coarseSettled:requireCoarse ? coarseSettled:true,qaOrMock:Credential.offline || owner.mock || owner.previewRenderOnly || owner.speakerRefinementCheckMode,
            resumePending:owner.recordingControlInFlight=="resume")
    }

    func requestKey(_ owner:Delegate)->String? {
        guard let session=owner.activeSession else{return nil}
        return "\(session)|\(owner.meetingDocumentGeneration)|\(owner.naming.correctionRevision)|\(preparationEpoch)"
    }

    func scheduleIfEligible(trigger:String) {
        guard let owner,eligible(owner,requireCoarse:true),requestKey(owner) != nil else{return}
        prepare(force:false,requireCoarse:true)
    }

    func open() {
        guard RuntimeConfiguration.archiveEnabled else{return}
        guard let owner else{return}
        present()
        if let session=owner.activeSession,let url=try? MeetingArchiveRequest.pageURL(session:session) {webView?.load(URLRequest(url:url))}
        prepare(force:false,requireCoarse:false)
    }

    func present() {
        guard RuntimeConfiguration.archiveEnabled else{return}
        guard let owner else{return}
        if window == nil {buildPanel()}
        if let window,window.sheetParent == nil,window.isVisible==false {owner.window?.beginSheet(window,completionHandler:nil)}
    }

    private func buildPanel() {
        guard let owner else{return}
        let panel=MeetingArchiveSheetWindow(contentRect:NSRect(x:0,y:0,width:980,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        panel.title="归档";panel.delegate=self;panel.panelController=self;panel.center()
        let root=NSView();root.translatesAutoresizingMaskIntoConstraints=false
        let label=NSTextField(labelWithString:"归档内容与每日工作台同步");label.textColor = .secondaryLabelColor;label.font = .systemFont(ofSize:12)
        let retry=NSButton(title:"重试",target:self,action:#selector(retryPreparation));retry.bezelStyle = .rounded;retry.isHidden=true
        let spacer=NSView();spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let close=NSButton(title:"关闭",target:self,action:#selector(closePanel));close.bezelStyle = .rounded;close.controlSize = .regular
        close.image=NSImage(systemSymbolName:"xmark",accessibilityDescription:"关闭归档");close.imagePosition = .imageLeading;close.setAccessibilityLabel("关闭归档")
        let row=NSStackView(views:[label,retry,spacer,close]);row.orientation = .horizontal;row.alignment = .centerY;row.spacing=10;row.translatesAutoresizingMaskIntoConstraints=false
        let web=WKWebView(frame:.zero);web.translatesAutoresizingMaskIntoConstraints=false;web.navigationDelegate=self
        root.addSubview(row);root.addSubview(web);panel.contentView=root
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:16),row.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-16),row.topAnchor.constraint(equalTo:root.topAnchor,constant:12),web.leadingAnchor.constraint(equalTo:root.leadingAnchor),web.trailingAnchor.constraint(equalTo:root.trailingAnchor),web.topAnchor.constraint(equalTo:row.bottomAnchor,constant:8),web.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
        self.window=panel;self.webView=web;self.status=label;self.retryButton=retry;self.closeButton=close
        if let url=try? MeetingArchiveRequest.pageURL(session:owner.activeSession ?? "") {web.load(URLRequest(url:url))}
    }

    private func show(_ text:String,retry:Bool=false) {
        status?.stringValue=text;retryButton?.isHidden = !retry
    }

    @objc private func retryPreparation(){prepare(force:true,requireCoarse:false)}

    @objc func closePanel() {
        guard let window else{return}
        if let parent=window.sheetParent {parent.endSheet(window,returnCode:.cancel)}
        else {window.close()}
    }

    private func prepare(force:Bool,requireCoarse:Bool) {
        guard let owner,eligible(owner,requireCoarse:requireCoarse),let session=owner.activeSession,let key=requestKey(owner) else {
            show("转写和整理完成后，可以在这里归档。")
            return
        }
        guard !inFlight.contains(key) else{return}
        if force {attempted.remove(key)}
        guard !attempted.contains(key) else{return}
        attempted.insert(key);inFlight.insert(key);show("正在准备归档…")
        owner.flushMeetingContext { [self,owner] success in
            DispatchQueue.main.async {
                guard self.isCurrent(key,owner:owner,requireCoarse:requireCoarse) else{self.inFlight.remove(key);return}
                guard success else{self.fail(key,"会议内容尚未保存到工作台，请重试归档准备。");return}
                self.requestPreparation(key:key,owner:owner,session:session,requireCoarse:requireCoarse)
            }
        }
    }

    private func requestPreparation(key:String,owner:Delegate,session:String,requireCoarse:Bool) {
        guard let bootstrapURL=MeetingArchiveRequest.bootstrapURL() else{fail(key,"工作台地址无效。稍后重试。");return}
        networkSession.dataTask(with:bootstrapURL) { [self,owner] data,response,error in
            DispatchQueue.main.async {
                guard self.isCurrent(key,owner:owner,requireCoarse:requireCoarse) else{self.inFlight.remove(key);return}
                guard let token=try? MeetingArchiveRequest.validatedCSRFToken(data:data,response:response,error:error),
                      let request=try? MeetingArchiveRequest.prepareRequest(session:session,csrfToken:token) else {
                    self.fail(key,"工作台暂时无法连接，录音和文字仍保留。请稍后重试。");return
                }
                self.networkSession.dataTask(with:request) { [self,owner] _,response,error in
                    DispatchQueue.main.async {
                        guard self.isCurrent(key,owner:owner,requireCoarse:requireCoarse) else{self.inFlight.remove(key);return}
                        guard error==nil,let response=response as? HTTPURLResponse,(200..<300).contains(response.statusCode) else {
                            self.fail(key,"归档准备暂未完成，原内容仍保留。可以稍后重试。");return
                        }
                        self.inFlight.remove(key);self.show(MeetingArchiveRequest.acceptedMessage)
                        self.webView?.reload()
                    }
                }.resume()
            }
        }.resume()
    }

    private func isCurrent(_ key:String,owner:Delegate,requireCoarse:Bool)->Bool {
        owner.activeSession != nil && requestKey(owner)==key && eligible(owner,requireCoarse:requireCoarse)
    }

    private func fail(_ key:String,_ message:String) {
        inFlight.remove(key);show(message,retry:true)
    }

    func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) {
        show("工作台暂时无法打开，录音和文字仍保留。请稍后重试。",retry:true)
    }

    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
        if inFlight.isEmpty,retryButton?.isHidden != false {show("归档内容与每日工作台同步")}
    }

    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) {
        show("工作台暂时无法打开，录音和文字仍保留。请稍后重试。",retry:true)
    }

    func refreshButton() {
        guard let owner else{return}
        button?.isHidden = !RuntimeConfiguration.archiveEnabled
        button?.isEnabled=eligible(owner,requireCoarse:false)
        button?.toolTip=eligible(owner,requireCoarse:false) ? "查看本场归档内容":"文字整理后自动归档"
    }

    func invalidateForResume(session:String?) {
        preparationEpoch &+= 1
        if let session {attempted=attempted.filter{!$0.hasPrefix(session+"|")};inFlight=inFlight.filter{!$0.hasPrefix(session+"|")}}
        else {attempted.removeAll();inFlight.removeAll()}
        show("会议有新内容，继续录音后将使用最新版本准备归档。")
        refreshButton()
    }

    func windowShouldClose(_ sender:NSWindow)->Bool {
        if let parent=sender.sheetParent {parent.endSheet(sender,returnCode:.cancel);return false}
        return true
    }
    func windowWillClose(_ notification:Notification) {window=nil;webView=nil;status=nil;retryButton=nil;closeButton=nil}
}

private var meetingArchivePanelKey:UInt8=0
extension Delegate {
    private var meetingArchivePanel:MeetingArchivePanel {
        if let panel=objc_getAssociatedObject(self,&meetingArchivePanelKey) as? MeetingArchivePanel {return panel}
        let panel=MeetingArchivePanel(owner:self);objc_setAssociatedObject(self,&meetingArchivePanelKey,panel,.OBJC_ASSOCIATION_RETAIN_NONATOMIC);return panel
    }

    var hasCurrentCoarseResult:Bool {
        guard let token=coarseResultToken else{return false}
        return MeetingArchiveEligibility.coarseTokenMatches(cacheID:token.cacheID,session:token.session,generation:token.generation,
            revision:token.revision,sourceSHA256:token.sourceSHA256,snapshotSHA256:token.snapshotSHA256,
            currentCacheID:currentCacheID,currentSession:activeSession,currentGeneration:meetingDocumentGeneration,
            currentRevision:naming.correctionRevision,artifactExists:hasCoarseResult)
    }
    var meetingArchiveEligible:Bool {meetingArchivePanel.eligible(self,requireCoarse:false)}
    func scheduleMeetingArchivePreparationIfEligible(trigger:String){meetingArchivePanel.scheduleIfEligible(trigger:trigger)}
    func refreshMeetingArchiveButtonState(){
        if isHistoryReader {workspaceOwner?.refreshMeetingArchiveButtonState();return}
        let target=historyReader ?? self
        if target !== self {meetingArchivePanel.button=nil}
        // The history reader's entire document view is the visible document;
        // its archive button is not the root delegate's hidden button.
        target.meetingArchivePanel.button=target.archiveButton
        target.meetingArchivePanel.refreshButton()
    }
    func meetingTranscriptProjectionDidSettle(){refreshMeetingArchiveButtonState();scheduleMeetingArchivePreparationIfEligible(trigger:"projection_synced")}
    func invalidateMeetingArchivePreparationOnResume(){meetingArchivePanel.invalidateForResume(session:activeSession)}

    func makeMeetingArchiveButton()->NSButton {
        let button=NSButton(title:"归档",target:self,action:#selector(openMeetingArchive));button.bezelStyle = .inline
        button.image=NSImage(systemSymbolName:"archivebox",accessibilityDescription:"归档");button.imagePosition = .imageLeading
        button.toolTip="查看并确认本场归档内容";button.isEnabled=meetingArchiveEligible
        button.isHidden = !RuntimeConfiguration.archiveEnabled
        meetingArchivePanel.button=button
        return button
    }

    func presentMeetingArchiveSheetForChecks(){meetingArchivePanel.present()}
    var meetingArchiveSheetCloseButtonForChecks:NSButton? {meetingArchivePanel.closeButton}
    func sendMeetingArchiveEscapeForChecks(){(meetingArchivePanel.window as? MeetingArchiveSheetWindow)?.cancelOperation(nil)}

    @objc func openMeetingArchive(){(isHistoryReader ? self:(historyReader ?? self)).meetingArchivePanel.open()}
}
