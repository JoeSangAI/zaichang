import AppKit
import CryptoKit
import Security

/// New versions of the public edition. Each release publishes a small latest.json next to its zips. 在场 reads
/// it now and then, fetches the new version quietly when nothing is recording, and swaps it in only after a
/// quit that the normal quit gate let through: meetings are saved first, and the swap never kills anything.
/// Nothing is installed unless it carries the release signature, which keeps the system permissions across updates.
final class AppUpdater:NSObject {
    static let shared=AppUpdater()
    static let feed=ProcessInfo.processInfo.environment["ZAICHANG_UPDATE_FEED"].flatMap(URL.init(string:))
        ?? URL(string:"https://github.com/JoeSangAI/zaichang/releases/latest/download/latest.json")!
    static let teamID="3BVM9N9HS4"
    static let requirement="identifier \"com.joesang.zaichang.standalone\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    static let checkEvery:TimeInterval=6*3600
    static let retryFetchAfter:TimeInterval=30*60
    static let resumeAfter:TimeInterval=60
    static var current:String {Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0"}
    /// Only the public edition has a feed; a QA build must never touch the network.
    static var enabled:Bool {!Credential.offline && Bundle.main.object(forInfoDictionaryKey:"OfflineQA") as? Bool != true}

    /// `models` is set on the small package: everything but the models, usable only where those same models are already installed.
    struct Package:Sendable {let url:URL,sha256:String,models:String?}
    struct Release:Sendable {let version:String,notes:String,whole:Package,small:Package?}
    enum Card {case checking,current,unreachable,offer,whatsNew(version:String,notes:String)}

    private weak var owner:Delegate?
    private var latest:Release?
    private var fetching=false
    private var ready:String?           // the version already fetched, checked and waiting for a quit
    private var problem:String?
    private var fraction:Double?
    private var reopen=false
    private var lastCheck:Date?
    private var retryAt=Date.distantPast
    private var clock:Timer?
    private var resumable:ResumableFetch?
    private var card:Card?
    private var whatsNew:(version:String,notes:String)?
    private let accessory=NSTitlebarAccessoryViewController()
    private lazy var pill=SpeakerPillButton(title:"",primary:false,small:true) {[weak self] in self?.pillPressed()}
    private let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:460,height:200),styleMask:[.titled],backing:.buffered,defer:false)
    private let heading=NSTextField(labelWithString:""),detail=NSTextField(wrappingLabelWithString:""),status=NSTextField(wrappingLabelWithString:"")
    private let notes=NSTextView(),notesFrame=NSScrollView(),bar=NSProgressIndicator()
    private lazy var primary=SpeakerPillButton(title:"更新并重启",primary:true) {[weak self] in self?.installNow()}
    private lazy var secondary=SpeakerPillButton(title:"稍后",primary:false) {[weak self] in self?.closePanel()}
    private var folder:URL {RuntimeConfiguration.dataRoot().appendingPathComponent("Update",isDirectory:true)}
    private var installed:URL {Bundle.main.bundleURL.resolvingSymlinksInPath()}

    static func isNewer(_ a:String,than b:String)->Bool {
        let parts={(v:String) in v.split(separator:".").map{Int($0) ?? 0}}
        let (x,y)=(parts(a),parts(b))
        for i in 0..<max(x.count,y.count) {
            let (l,r)=(i<x.count ? x[i]:0,i<y.count ? y[i]:0)
            if l != r {return l>r}
        }
        return false
    }
    static func allowed(_ url:URL)->Bool {url.scheme=="https" || (url.scheme=="http" && url.host=="127.0.0.1")}
    static func release(from data:Data)->Release? {
        guard let found=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let version=found["version"] as? String,let text=found["zip"] as? String,let zip=URL(string:text),allowed(zip),
              let sha=found["sha256"] as? String else{return nil}
        var small:Package?
        if let patch=found["patch"] as? [String:Any],let text=patch["zip"] as? String,let url=URL(string:text),allowed(url),
           let hash=patch["sha256"] as? String,let models=patch["models"] as? String {small=Package(url:url,sha256:hash,models:models)}
        return Release(version:version,notes:found["notes"] as? String ?? "",whole:Package(url:zip,sha256:sha,models:nil),small:small)
    }
    /// The sections of the bundled CHANGELOG.md newer than the version this one replaced.
    static func changes(in text:String,since version:String)->String {
        var sections:[(name:String,lines:[String])]=[],keeping=false
        for line in text.components(separatedBy:"\n") {
            if line.hasPrefix("## ") {
                let name=line.dropFirst(3).split(separator:" ").first.map(String.init) ?? ""
                keeping=isNewer(name,than:version)
                if keeping {sections.append((name,[]))}
            } else if keeping {sections[sections.count-1].lines.append(line)}
        }
        return sections.map{(sections.count>1 ? $0.name+"\n":"")+$0.lines.joined(separator:"\n")}
            .joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
    }

    // ---- when ----
    func start(owner:Delegate) {
        guard AppUpdater.enabled,clock==nil else{return}
        self.owner=owner
        buildPanel();announceIfJustUpdated()
        accessory.layoutAttribute = .trailing
        let holder=NSView(frame:NSRect(x:0,y:0,width:170,height:38));holder.addSubview(pill)
        NSLayoutConstraint.activate([pill.trailingAnchor.constraint(equalTo:holder.trailingAnchor,constant:-10),pill.centerYAnchor.constraint(equalTo:holder.centerYAnchor)])
        accessory.view=holder;accessory.isHidden=true
        owner.window.addTitlebarAccessoryViewController(accessory)
        NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main) {[weak self] _ in self?.swapOnExit()}
        refresh()
        DispatchQueue.main.asyncAfter(deadline:.now()+20) {[weak self] in self?.check(quietly:true)}
        // One clock: it re-evaluates the pill, the deferred download and the next check.
        clock=Timer.scheduledTimer(withTimeInterval:30,repeats:true) {_ in DispatchQueue.main.async {AppUpdater.shared.tick()}}
    }
    private func tick() {
        if let lastCheck,Date().timeIntervalSince(lastCheck)>=AppUpdater.checkEvery {check(quietly:true)}
        if let latest,Date()>=retryAt {fetch(latest)}
        refresh()
    }

    /// The menu item. With something known it shows it; otherwise it asks now and reports either way.
    func showOrCheck() {
        guard AppUpdater.enabled else{return}
        if latest != nil {present(.offer);return}
        present(.checking);check(quietly:false)
    }
    private func check(quietly:Bool) {
        lastCheck=Date()
        // GitHub caches the "latest" redirect for minutes; a fresh query string asks past it.
        var parts=URLComponents(url:AppUpdater.feed,resolvingAgainstBaseURL:false)
        parts?.queryItems=[URLQueryItem(name:"t",value:"\(Int(Date().timeIntervalSince1970))")]
        var request=URLRequest(url:parts?.url ?? AppUpdater.feed,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:30)
        request.setValue("Zaichang/\(AppUpdater.current)",forHTTPHeaderField:"User-Agent")
        URLSession.shared.dataTask(with:request) {data,response,_ in
            let ok=(response as? HTTPURLResponse)?.statusCode==200
            let found=ok ? data.flatMap(AppUpdater.release(from:)):nil
            DispatchQueue.main.async {AppUpdater.shared.heard(found,quietly:quietly)}
        }.resume()
    }
    private func heard(_ found:Release?,quietly:Bool) {
        guard let found else {
            // A check that fails says nothing unless someone asked; the next one is hours away anyway.
            if !quietly {present(.unreachable)}
            return
        }
        guard AppUpdater.isNewer(found.version,than:AppUpdater.current) else {
            latest=nil
            if !quietly {present(.current)}
            return
        }
        if latest?.version != found.version {ready=nil;problem=nil;retryAt = .distantPast}
        latest=found;fetch(found);refresh()
        if !quietly {present(.offer)}
    }

    // ---- fetching: quiet, and never while a meeting is being recorded ----
    private func fetch(_ release:Release) {
        guard !fetching,ready != release.version,owner?.recordingBusy != true else{return}
        fetching=true;problem=nil
        let small=release.small.flatMap{$0.models==AppUpdater.modelsID(in:Bundle.main.bundleURL) ? $0:nil}
        download(small ?? release.whole,of:release)
    }
    /// The bytes received so far stay in "<sha256>.part" across quits and dropped connections, and the next
    /// attempt asks only for the rest: on a slow line an update arrives over several short sessions.
    private func download(_ package:Package,of release:Release) {
        let folder=self.folder,part=folder.appendingPathComponent(package.sha256.lowercased()+".part")
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath:folder.path)) ?? [] where name != part.lastPathComponent {
            try? FileManager.default.removeItem(at:folder.appendingPathComponent(name))
        }
        resumable=ResumableFetch(part:part,progress:{value in
            DispatchQueue.main.async {AppUpdater.shared.fraction=value;AppUpdater.shared.renderCard()}
        }) {arrived in
            var problem:String?,network=false
            if arrived {
                let kept=folder.appendingPathComponent("update.zip")
                if (try? FileManager.default.moveItem(at:part,to:kept)) != nil {problem=AppUpdater.prepare(kept,package,version:release.version,in:folder)}
                else {problem="下载的文件读不出来，再试一次。"}
            } else {problem="下载没有完成，会自动接着下载。";network=true}
            DispatchQueue.main.async {AppUpdater.shared.fetched(package,of:release,problem:problem,network:network)}
        }
        resumable?.start(package.url)
    }
    private func fetched(_ package:Package,of release:Release,problem failure:String?,network:Bool) {
        resumable=nil
        // The small package arrived but didn't come together: the whole one doesn't depend on anything here.
        // A dropped connection is no reason to fetch eight times as much.
        if failure != nil,!network,package.models != nil {download(release.whole,of:release);return}
        fetching=false;fraction=nil
        if let failure {
            problem=failure;retryAt=Date().addingTimeInterval(network ? AppUpdater.resumeAfter:AppUpdater.retryFetchAfter)
        } else {ready=release.version;problem=nil}
        refresh()
    }
    /// Off the main thread. Returns what went wrong, in words for the panel.
    private static func prepare(_ zip:URL,_ package:Package,version:String,in folder:URL)->String? {
        guard let data=try? Data(contentsOf:zip,options:.mappedIfSafe) else{return "下载的文件读不出来，再试一次。"}
        let digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        guard digest==package.sha256.lowercased() else{return "下载的文件不完整，再试一次。"}
        let unpacked=folder.appendingPathComponent("unpacked")
        guard run("/usr/bin/ditto",["-x","-k",zip.path,unpacked.path]) else{return "解压失败，再试一次。"}
        let app=unpacked.appendingPathComponent("在场.app")
        if package.models != nil {
            // Cloned, so it costs neither time nor disk. The signature check below covers every file of it.
            for relative in modelFolders {
                let mine=Bundle.main.bundleURL.appendingPathComponent(relative)
                guard run("/bin/cp",["-Rc",mine.path,app.appendingPathComponent(relative).path]) else{return "解压失败，再试一次。"}
            }
        }
        _=run("/usr/bin/xattr",["-dr","com.apple.quarantine",app.path])
        guard signedForRelease(app) else{return "这个版本的签名不对，没有安装。"}
        // The new version must at least start on this Mac before it replaces the one that works.
        let probe=Process(),out=Pipe()
        probe.executableURL=app.appendingPathComponent("Contents/MacOS/MeetingAssistant");probe.arguments=["--update-probe"]
        probe.standardOutput=out;probe.standardError=FileHandle.nullDevice;probe.standardInput=FileHandle.nullDevice
        guard (try? probe.run()) != nil else{return "这个版本在这台 Mac 上启动不了，没有安装。"}
        let said=String(decoding:out.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        probe.waitUntilExit()
        guard probe.terminationStatus==0,said==version else{return "这个版本在这台 Mac 上启动不了，没有安装。"}
        return nil
    }
    static let modelFolders=["Contents/Resources/Runtime/native/local-speaker-install","Contents/Resources/Runtime/native/local-embedding-install"]
    static func modelsID(in app:URL)->String? {
        (try? String(contentsOf:app.appendingPathComponent("Contents/Resources/Runtime/models.id"),encoding:.utf8))?.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    @discardableResult private static func run(_ tool:String,_ arguments:[String])->Bool {
        let task=Process();task.executableURL=URL(fileURLWithPath:tool);task.arguments=arguments
        task.standardOutput=FileHandle.nullDevice;task.standardError=FileHandle.nullDevice
        do {try task.run()}catch{return false}
        task.waitUntilExit();return task.terminationStatus==0
    }
    /// The candidate must be ours, with every nested file intact, wherever the running copy came from.
    static func signedForRelease(_ app:URL)->Bool {
        var parsed:SecRequirement?,candidate:SecStaticCode?
        guard SecRequirementCreateWithString(requirement as CFString,[],&parsed)==errSecSuccess,let parsed,
              SecStaticCodeCreateWithPath(app as CFURL,[],&candidate)==errSecSuccess,let candidate else{return false}
        let strict=SecCSFlags(rawValue:kSecCSCheckAllArchitectures|kSecCSCheckNestedCode|kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(candidate,strict,parsed)==errSecSuccess
    }
    /// A copy someone built from source has no stable identity: moving to the release asks for permissions once more.
    static var runningRelease:Bool {
        var running:SecCode?,mine:SecStaticCode?,info:CFDictionary?
        guard SecCodeCopySelf([],&running)==errSecSuccess,let running,SecCodeCopyStaticCode(running,[],&mine)==errSecSuccess,let mine,
              SecCodeCopySigningInformation(mine,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,let info else{return false}
        return (info as NSDictionary)[kSecCodeInfoTeamIdentifier as String] as? String==teamID
    }

    // ---- the swap ----
    private var canReplace:Bool {
        FileManager.default.isWritableFile(atPath:installed.deletingLastPathComponent().path) && !installed.path.contains("/AppTranslocation/")
    }
    private func installNow() {
        guard let owner,let latest,ready==latest.version else{return}
        if let reason=owner.updateBlockedReason {problem=reason;renderCard();return}
        guard canReplace else {problem="没有权限替换 \(installed.path)。把在场放回“应用程序”后再试。";renderCard();return}
        reopen=true
        owner.window.endSheet(panel);panel.orderOut(nil);card=nil
        NSApp.terminate(nil)
    }
    /// Runs only once the quit gate has saved everything. A later quit installs what is ready, so "稍后" still arrives.
    private func swapOnExit() {
        guard let latest,ready==latest.version,canReplace,reopen || AppUpdater.runningRelease else{return}
        let script="""
        #!/bin/sh
        pid="$1"; old="$2"; new="$3"; keep="$4"; again="$5"
        for _ in $(seq 1 600); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
        kill -0 "$pid" 2>/dev/null && exit 0
        rm -rf "$keep"
        if mv "$old" "$keep"; then
          if ! mv "$new" "$old"; then mv "$keep" "$old"; fi
        fi
        [ "$again" = 1 ] && open "$old"
        rm -rf "$(dirname "$0")"
        """
        let file=folder.appendingPathComponent("swap.sh")
        guard (try? script.write(to:file,atomically:true,encoding:.utf8)) != nil else{return}
        let task=Process();task.executableURL=URL(fileURLWithPath:"/bin/sh")
        task.arguments=[file.path,"\(getpid())",installed.path,folder.appendingPathComponent("unpacked/在场.app").path,
                        RuntimeConfiguration.dataRoot().appendingPathComponent("previous-version.app").path,reopen ? "1":"0"]
        task.standardInput=FileHandle.nullDevice;task.standardOutput=FileHandle.nullDevice;task.standardError=FileHandle.nullDevice
        try? task.run()
    }

    // ---- telling the owner: a small pill in the title bar, never a notification on a screen being shared ----
    private func announceIfJustUpdated() {
        let key="lastRunVersion",defaults=UserDefaults.standard
        let before=defaults.string(forKey:key)
        defaults.set(AppUpdater.current,forKey:key)
        guard let before,AppUpdater.isNewer(AppUpdater.current,than:before) else{return}
        let bundled=Bundle.main.resourceURL?.appendingPathComponent("Runtime/CHANGELOG.md")
        let text=bundled.flatMap{try? String(contentsOf:$0,encoding:.utf8)} ?? ""
        whatsNew=(AppUpdater.current,AppUpdater.changes(in:text,since:before))
        // What this version replaced is no longer needed once the new one has started.
        try? FileManager.default.removeItem(at:folder)
    }
    private func refresh() {
        let quiet=owner?.recordingBusy==true
        let pending=latest.flatMap{ready==$0.version ? $0.version:nil}
        if let pending,!quiet {
            AppUpdater.retitle(pill,"更新到 \(pending)");accessory.isHidden=false
        } else if let whatsNew,!quiet {
            AppUpdater.retitle(pill,"\(whatsNew.version) 更新了什么");accessory.isHidden=false
        } else {accessory.isHidden=true}
        renderCard()
    }
    /// The pill draws its title when it is enabled or disabled, so that is what makes a new one show.
    private static func retitle(_ button:SpeakerPillButton,_ text:String) {
        guard button.title != text else{return}
        button.title=text;button.isEnabled=button.isEnabled;button.setAccessibilityLabel(text);button.invalidateIntrinsicContentSize()
        // A title bar accessory isn't laid out again by itself: without this the pill keeps the width of its first, empty title.
        button.superview?.needsLayout=true;button.superview?.layoutSubtreeIfNeeded()
    }
    private func pillPressed() {
        if latest != nil,ready==latest?.version {present(.offer)}
        else if let shown=whatsNew {whatsNew=nil;present(.whatsNew(version:shown.version,notes:shown.notes));refresh()}
    }
    private func present(_ next:Card) {
        guard let owner else{return}
        card=next;renderCard()
        if panel.sheetParent==nil {owner.window.beginSheet(panel)}
    }
    private func closePanel() {
        owner?.window.endSheet(panel);panel.orderOut(nil);card=nil;problem=nil
    }
    private func buildPanel() {
        panel.isReleasedWhenClosed=false;panel.backgroundColor=MeetingVisualStyle.surface
        heading.font=MeetingVisualStyle.titleFont(20);heading.textColor=MeetingVisualStyle.ink
        for (field,color) in [(detail,MeetingVisualStyle.muted),(status,MeetingVisualStyle.accentText)] {
            field.font = .systemFont(ofSize:13);field.textColor=color;field.isSelectable=false;field.preferredMaxLayoutWidth=404
            field.translatesAutoresizingMaskIntoConstraints=false;field.widthAnchor.constraint(equalToConstant:404).isActive=true
        }
        notes.isEditable=false;notes.drawsBackground=false;notes.font=MeetingVisualStyle.textFont(13);notes.textColor=MeetingVisualStyle.ink
        notes.textContainerInset=NSSize(width:0,height:2);notes.isVerticallyResizable=true;notes.isHorizontallyResizable=false;notes.autoresizingMask=[.width]
        notes.textContainer?.widthTracksTextView=true;notes.textContainer?.containerSize=NSSize(width:404,height:CGFloat.greatestFiniteMagnitude)
        notesFrame.documentView=notes;notesFrame.hasVerticalScroller=true;notesFrame.drawsBackground=false;notesFrame.borderType = .noBorder
        notesFrame.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([notesFrame.widthAnchor.constraint(equalToConstant:404),notesFrame.heightAnchor.constraint(equalToConstant:190)])
        notes.frame=NSRect(x:0,y:0,width:404,height:190)
        bar.style = .bar;bar.minValue=0;bar.maxValue=1;bar.isIndeterminate=false;bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints=false;bar.widthAnchor.constraint(equalToConstant:404).isActive=true
        let footer=NSStackView(views:[NSView(),secondary,primary]);footer.orientation = .horizontal;footer.spacing=10
        let page=NSStackView(views:[heading,detail,notesFrame,bar,status,footer]);page.orientation = .vertical;page.alignment = .leading;page.spacing=12
        page.translatesAutoresizingMaskIntoConstraints=false
        let content=panel.contentView!;content.addSubview(page)
        NSLayoutConstraint.activate([page.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:28),page.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-28),
                                     page.topAnchor.constraint(equalTo:content.topAnchor,constant:24),page.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-20),
                                     content.widthAnchor.constraint(equalToConstant:460),footer.widthAnchor.constraint(equalTo:page.widthAnchor)])
    }
    private func renderCard() {
        guard let card else{return}
        var title="",body="",text="",line="",showBar=false,showPrimary=false,enabled=false,close="关闭"
        switch card {
        case .checking:title="正在检查更新…"
        case .current:title="已是最新版本";body="当前版本 \(AppUpdater.current)。"
        case .unreachable:title="现在连不上更新服务器";body="检查网络后再试一次。没有新版本时什么都不用做。"
        case .whatsNew(let version,let notes):title="已更新到 \(version)";text=notes;close="好"
        case .offer:
            guard let latest else {self.card=nil;return}
            title="在场 \(latest.version) 可以更新了";text=latest.notes;close="稍后";showPrimary=true
            let isReady=ready==latest.version
            let blocked=owner?.updateBlockedReason
            enabled=isReady && blocked==nil
            if !isReady {
                line=problem ?? (owner?.recordingBusy==true ? "录音结束后开始下载。":"正在下载…")
                showBar=fetching;bar.doubleValue=fraction ?? 0
            } else if let blocked {line=blocked}
            else if let problem {line=problem}
            else {body=AppUpdater.runningRelease ? "会议和设置都不受影响。选“稍后”的话，下次退出在场时会自动换上。":"你现在用的是自己编译的版本。换成正式版后，系统会再问一次麦克风和电脑声音权限，也可能要再确认一次钥匙串，以后都不用再问。"}
        }
        heading.stringValue=title;detail.stringValue=body;detail.isHidden=body.isEmpty
        notes.string=text.replacingOccurrences(of:"\n- ",with:"\n• ").replacingOccurrences(of:"^- ",with:"• ",options:.regularExpression)
        notesFrame.isHidden=text.isEmpty;bar.isHidden=(!showBar);status.stringValue=line;status.isHidden=line.isEmpty
        primary.isHidden=(!showPrimary);primary.isEnabled=enabled;AppUpdater.retitle(secondary,close)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
    }
}

extension Delegate {
    /// Why "更新并重启" must wait. Quitting stops a recording and cancels what is being organized, so the button
    /// refuses and says so; choosing to quit anyway stays the owner's call and goes through the normal quit gate.
    var updateBlockedReason:String? {
        if recordingBusy {return "正在录音，结束后就能更新。"}
        if audioAssetOperationBusy || meetingDeletionBusy {return "录音文件正在处理，完成后就能更新。"}
        if savedCoarseJobs.values.contains(where:{$0.hasPendingWork}) || speakerRefinementJob.hasPendingWork || savedVoiceRecognitionJob.hasPendingWork {return "这场会议还在整理，整理完就能更新。"}
        return nil
    }
    @objc func checkForUpdates() {AppUpdater.shared.showOrCheck()}
}

/// One download that appends to its .part file as bytes arrive and, when that file already holds some, asks only
/// for the rest. A server that ignores the range answers 200 and the file starts over.
final class ResumableFetch:NSObject,URLSessionDataDelegate {
    private let part:URL,progress:(Double)->Void,done:(Bool)->Void
    private var session:URLSession?,handle:FileHandle?,have:Int64=0,total:Int64=0,finished=false
    init(part:URL,progress:@escaping (Double)->Void,done:@escaping (Bool)->Void) {self.part=part;self.progress=progress;self.done=done}
    func start(_ url:URL) {
        have=((try? FileManager.default.attributesOfItem(atPath:part.path))?[.size] as? NSNumber)?.int64Value ?? 0
        var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:60)
        if have>0 {request.setValue("bytes=\(have)-",forHTTPHeaderField:"Range")}
        session=URLSession(configuration:.default,delegate:self,delegateQueue:nil)
        session?.dataTask(with:request).resume()
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping (URLSession.ResponseDisposition)->Void) {
        let code=(response as? HTTPURLResponse)?.statusCode ?? 0
        if code==416 && have>0 {finished=true;completionHandler(.cancel);return}  // the part is already whole
        guard code==200 || code==206 else {completionHandler(.cancel);return}
        if code==200 {have=0;try? FileManager.default.removeItem(at:part)}
        if !FileManager.default.fileExists(atPath:part.path) {FileManager.default.createFile(atPath:part.path,contents:nil)}
        handle=try? FileHandle(forWritingTo:part);_=try? handle?.seekToEnd()
        total=have+max(0,response.expectedContentLength)
        completionHandler(handle==nil ? .cancel:.allow)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
        guard (try? handle?.write(contentsOf:data)) != nil else {dataTask.cancel();return}
        have+=Int64(data.count);if total>0 {progress(min(1,Double(have)/Double(total)))}
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        try? handle?.close();handle=nil;session.finishTasksAndInvalidate()
        let code=(task.response as? HTTPURLResponse)?.statusCode ?? 0
        done(finished || (error==nil && (code==200 || code==206)))
    }
}
