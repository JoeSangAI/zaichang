import AppKit

/// What a new install needs, in one list. A release that adds a permission or a
/// service adds a step here; people who already finished the guide see just that step.
struct FirstRunStep {
    enum Kind:String {case transcription,assistant,recording}
    let kind:Kind
    /// True when an unfinished step is worth interrupting the launch for.
    let opensGuide:Bool
    /// System permission prompts this step prepares people for. Checked against Info.plist.
    let usageKeys:[String]
    static let all=[
        FirstRunStep(kind:.transcription,opensGuide:true,usageKeys:[]),
        FirstRunStep(kind:.assistant,opensGuide:true,usageKeys:[]),
        FirstRunStep(kind:.recording,opensGuide:false,usageKeys:["NSMicrophoneUsageDescription","NSAudioCaptureUsageDescription"]),
    ]
}

enum FirstRunAssistantStatus {case checking,ready,notInstalled,needsLogin}

enum FirstRunCodexProbe {
    /// Same search path the assistant runtime starts with, so "connected" here means it will start.
    static func status(searchPaths:[String]=RuntimeConfiguration.toolSearchPaths,timeout:TimeInterval=8)->FirstRunAssistantStatus {
        guard let codex=searchPaths.map({$0+"/codex"}).first(where:{FileManager.default.isExecutableFile(atPath:$0)}) else{return .notInstalled}
        let child=Process();child.executableURL=URL(fileURLWithPath:codex);child.arguments=["login","status"]
        child.standardInput=FileHandle.nullDevice;child.standardOutput=FileHandle.nullDevice;child.standardError=FileHandle.nullDevice
        var environment=ProcessInfo.processInfo.environment;environment["PATH"]=(searchPaths+[environment["PATH"] ?? ""]).joined(separator:":");child.environment=environment
        let finished=DispatchSemaphore(value:0);child.terminationHandler={_ in finished.signal()}
        do {try child.run()} catch {return .notInstalled}
        // A slow answer is not evidence of a missing login; the assistant panel reports the real state.
        guard finished.wait(timeout:.now()+timeout) == .success else {child.terminate();return .ready}
        return child.terminationStatus == 0 ? .ready:.needsLogin
    }
}

final class FirstRunGuide:NSObject {
    static let keyURL=URL(string:"https://bailian.console.aliyun.com/?tab=model#/api-key")!
    static let installCommand="curl -fsSL https://chatgpt.com/codex/install.sh | sh && codex"
    private weak var owner:Delegate?
    private let seenFile:URL,meetings:URL,probe:()->FirstRunAssistantStatus
    private(set) var assistant=FirstRunAssistantStatus.checking
    private(set) var skipped=Set<FirstRunStep.Kind>()
    let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:500,height:420),styleMask:[.titled],backing:.buffered,defer:false)
    private let rows=NSStackView(),keyField=NSSecureTextField(),keyMessage=NSTextField(labelWithString:"")
    private var finish:SpeakerPillButton!
    private var activation:NSObjectProtocol?
    init(owner:Delegate,dataRoot:URL=RuntimeConfiguration.dataRoot(),meetings:URL?=nil,probe:@escaping ()->FirstRunAssistantStatus={FirstRunCodexProbe.status()}) {
        self.owner=owner;seenFile=dataRoot.appendingPathComponent("first-run.json")
        self.meetings=meetings ?? dataRoot.appendingPathComponent("SessionCache");self.probe=probe
        super.init();build()
    }
    var seen:Set<String> {
        get {
            guard let data=try? Data(contentsOf:seenFile),let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else{return []}
            return Set(value["seen"] as? [String] ?? [])
        }
        set {
            try? FileManager.default.createDirectory(at:seenFile.deletingLastPathComponent(),withIntermediateDirectories:true)
            if let data=try? JSONSerialization.data(withJSONObject:["schema":1,"seen":newValue.sorted()],options:[.sortedKeys]) {try? data.write(to:seenFile,options:.atomic)}
        }
    }
    private var hasRecorded:Bool {!((try? FileManager.default.contentsOfDirectory(atPath:meetings.path)) ?? []).filter{!$0.hasPrefix(".")}.isEmpty}
    func isDone(_ kind:FirstRunStep.Kind)->Bool {
        switch kind {
        case .transcription:return owner?.stored ?? false
        case .assistant:return assistant == .ready
        case .recording:return hasRecorded
        }
    }
    /// The one step waiting on the user; recording only informs, so it never holds the guide open.
    var activeStep:FirstRunStep.Kind? {
        FirstRunStep.all.first{$0.opensGuide && !isDone($0.kind) && !skipped.contains($0.kind)}?.kind
    }
    /// Launch path: stay quiet unless a step this person has not seen actually needs them.
    func presentIfNeeded(completion:(()->Void)?=nil) {
        recheckAssistant {[weak self] in
            guard let self,let owner=self.owner else{return}
            var seen=self.seen
            for step in FirstRunStep.all where self.isDone(step.kind) {seen.insert(step.kind.rawValue)}
            self.seen=seen
            let needed=FirstRunStep.all.filter{$0.opensGuide && !seen.contains($0.kind.rawValue) && !self.isDone($0.kind)}
            // Someone who has already started a meeting is not interrupted.
            if !needed.isEmpty,owner.window.attachedSheet==nil,owner.phase.phase == .idle,owner.currentCacheID==nil || owner.mock {self.present()}
            completion?()
        }
    }
    func present() {
        guard let owner,owner.window.attachedSheet==nil else{return}
        skipped=[];refresh();owner.window.beginSheet(panel)
        activation=NotificationCenter.default.addObserver(forName:NSApplication.didBecomeActiveNotification,object:nil,queue:.main) {[weak self] _ in
            // Coming back from the browser or Terminal: look again rather than asking.
            self?.recheckAssistant()
        }
    }
    private func recheckAssistant(then done:(()->Void)?=nil) {
        let probe=self.probe
        DispatchQueue.global(qos:.utility).async {
            let status=probe()
            DispatchQueue.main.async {[weak self] in
                guard let self else{return}
                self.assistant=status;self.refresh();done?()
            }
        }
    }
    private func build() {
        panel.isReleasedWhenClosed=false;panel.backgroundColor=MeetingVisualStyle.surface
        let title=NSTextField(labelWithString:"开始用在场");title.font=MeetingVisualStyle.titleFont(22);title.textColor=MeetingVisualStyle.ink
        let intro=wrapping("录音保存在这台 Mac。转写和助理用你自己的账号，费用也在你的账号里。",size:13,color:MeetingVisualStyle.muted,width:444)
        rows.orientation = .vertical;rows.alignment = .leading;rows.spacing=18
        keyField.placeholderString="粘贴 API 密钥";keyField.font = .systemFont(ofSize:13);keyField.bezelStyle = .roundedBezel;keyField.target=self;keyField.action=#selector(saveKey)
        keyMessage.font = .systemFont(ofSize:12);keyMessage.textColor=MeetingVisualStyle.accentText
        finish=SpeakerPillButton(title:"开始使用",primary:true) {[weak self] in self?.complete()}
        let footer=NSStackView(views:[NSView(),finish]);footer.orientation = .horizontal
        let page=NSStackView(views:[title,intro,rows,footer]);page.orientation = .vertical;page.alignment = .leading;page.spacing=14;page.setCustomSpacing(22,after:intro);page.setCustomSpacing(24,after:rows)
        page.translatesAutoresizingMaskIntoConstraints=false
        let content=panel.contentView!;content.addSubview(page)
        NSLayoutConstraint.activate([page.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:28),page.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-28),
                                     page.topAnchor.constraint(equalTo:content.topAnchor,constant:26),page.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-22),
                                     content.widthAnchor.constraint(equalToConstant:500),footer.widthAnchor.constraint(equalTo:page.widthAnchor)])
    }
    private func wrapping(_ text:String,size:CGFloat,color:NSColor,width:CGFloat)->NSTextField {
        let field=NSTextField(wrappingLabelWithString:text);field.font = .systemFont(ofSize:size);field.textColor=color;field.isSelectable=false
        field.preferredMaxLayoutWidth=width;field.translatesAutoresizingMaskIntoConstraints=false;field.widthAnchor.constraint(equalToConstant:width).isActive=true
        return field
    }
    private func link(_ title:String,_ handler:@escaping ()->Void)->SpeakerPillButton {SpeakerPillButton(title:title,primary:false,small:true,handler:handler)}
    func detail(_ kind:FirstRunStep.Kind)->String {
        switch kind {
        case .transcription:
            if isDone(kind) {return "密钥已保存在这台 Mac。"}
            if skipped.contains(kind) {return "先只录音，声音留在本机。以后可以在设置里填写密钥。"}
            return "把声音变成文字要用阿里云百炼。创建一个 API 密钥粘贴到这里，费用按你账号的实际用量计算。"
        case .assistant:
            if skipped.contains(kind) && assistant != .ready {return "先不用助理，录音和转写不受影响。"}
            if assistant != .ready && activeStep != kind {return "助理用你自己的 Codex 账号，稍后连接。"}
            switch assistant {
            case .checking:return "正在检查这台 Mac 上的 Codex…"
            case .ready:return "已连接你的 Codex 账号。"
            case .needsLogin:return "Codex 已安装，还没登录。在终端粘贴命令并回车，按提示登录，回到这里会自动刷新。"
            case .notInstalled:return "助理用你自己的 Codex 账号，这台 Mac 还没安装。在终端粘贴命令并回车，按提示登录，回到这里会自动刷新。"
            }
        case .recording:
            return isDone(kind) ? "这台 Mac 已经录过会议。":"开始录音时，系统会询问麦克风和电脑声音，两个都点允许。只问一次。"
        }
    }
    private func title(_ kind:FirstRunStep.Kind)->String {
        switch kind {case .transcription:return "连接转写服务";case .assistant:return "连接助理";case .recording:return "第一次录音"}
    }
    private func actions(_ kind:FirstRunStep.Kind)->[NSView] {
        switch kind {
        case .transcription:
            keyField.translatesAutoresizingMaskIntoConstraints=false;keyField.widthAnchor.constraint(equalToConstant:320).isActive=true
            let entry=NSStackView(views:[keyField,SpeakerPillButton(title:"保存",primary:true) {[weak self] in self?.saveKey()}]);entry.orientation = .horizontal;entry.spacing=8
            let more=NSStackView(views:[link("去百炼创建密钥 ↗") {NSWorkspace.shared.open(Self.keyURL)},link("先只录音") {[weak self] in self?.skipTranscription()}]);more.orientation = .horizontal;more.spacing=8
            return keyMessage.stringValue.isEmpty ? [entry,more]:[entry,keyMessage,more]
        case .assistant:
            guard assistant != .checking else{return [link("先跳过") {[weak self] in self?.skip(.assistant)}]}
            let command=assistant == .needsLogin ? "codex":Self.installCommand
            let copy=SpeakerPillButton(title:"复制命令并打开终端",primary:true) {[weak self] in self?.copyAndOpenTerminal(command)}
            let row=NSStackView(views:[copy,link("先跳过") {[weak self] in self?.skip(.assistant)}]);row.orientation = .horizontal;row.spacing=8
            return [row]
        case .recording:return []
        }
    }
    func refresh() {
        for view in rows.arrangedSubviews {rows.removeArrangedSubview(view);view.removeFromSuperview()}
        let active=activeStep
        for (index,step) in FirstRunStep.all.enumerated() {
            let kind=step.kind,isActive=kind==active,done=isDone(kind)
            let name=NSTextField(labelWithString:title(kind));name.font = .systemFont(ofSize:14,weight:.semibold);name.textColor=isActive || !done ? MeetingVisualStyle.ink:MeetingVisualStyle.muted
            let words=NSStackView(views:[name,wrapping(detail(kind),size:12.5,color:MeetingVisualStyle.muted,width:412)]+(isActive ? actions(kind):[]))
            words.orientation = .vertical;words.alignment = .leading;words.spacing=5
            if isActive,words.arrangedSubviews.count>2 {words.setCustomSpacing(10,after:words.arrangedSubviews[1])}
            let marker=FirstRunMarker(number:index+1,state:done ? .done:isActive ? .active:.waiting)
            let row=NSStackView(views:[marker,words]);row.orientation = .horizontal;row.alignment = .top;row.spacing=12
            rows.addArrangedSubview(row)
        }
        finish.isHidden=active != nil
        panel.contentView?.layoutSubtreeIfNeeded()
        if let size=panel.contentView?.fittingSize,size.height>0 {panel.setContentSize(NSSize(width:500,height:size.height))}
        if active == .transcription,panel.isVisible {panel.makeFirstResponder(keyField)}
    }
    @objc func saveKey() {
        guard let owner else{return}
        if let problem=owner.storeBailianKey(keyField.stringValue) {keyMessage.stringValue=problem;refresh();return}
        keyField.stringValue="";keyMessage.stringValue="";refresh()
    }
    func fillKeyForChecks(_ value:String) {keyField.stringValue=value}
    private func skipTranscription() {owner?.selectRecordingModeFromChip(1);skip(.transcription)}
    func skip(_ kind:FirstRunStep.Kind) {skipped.insert(kind);refresh()}
    private func copyAndOpenTerminal(_ command:String) {
        NSPasteboard.general.clearContents();NSPasteboard.general.setString(command,forType:.string)
        NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/Utilities/Terminal.app"))
    }
    func complete() {
        var seen=self.seen;seen.formUnion(FirstRunStep.all.map{$0.kind.rawValue});self.seen=seen
        if let activation {NotificationCenter.default.removeObserver(activation);self.activation=nil}
        owner?.window.endSheet(panel);panel.orderOut(nil)
    }
}

private final class FirstRunMarker:NSView {
    enum State {case waiting,active,done}
    private let number:Int,state:State
    init(number:Int,state:State) {
        self.number=number;self.state=state;super.init(frame:.zero);translatesAutoresizingMaskIntoConstraints=false;setAccessibilityElement(false)
        widthAnchor.constraint(equalToConstant:20).isActive=true;heightAnchor.constraint(equalToConstant:20).isActive=true
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    override func draw(_ dirtyRect:NSRect) {
        let circle=NSBezierPath(ovalIn:bounds.insetBy(dx:1,dy:1))
        switch state {
        case .active:MeetingVisualStyle.accent.setFill();circle.fill()
        case .done:MeetingVisualStyle.quietFill.setFill();circle.fill()
        case .waiting:MeetingVisualStyle.border.setStroke();circle.lineWidth=1;circle.stroke()
        }
        let text=state == .done ? "✓":"\(number)"
        let color:NSColor=state == .active ? .white:MeetingVisualStyle.muted
        let string=NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:11,weight:.semibold),.foregroundColor:color]),size=string.size()
        string.draw(at:NSPoint(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2))
    }
}

extension Delegate {
    /// Saves the transcription key; returns what to show when it could not be saved.
    func storeBailianKey(_ raw:String)->String? {
        let value=CredentialInput(raw:raw)
        if let issue=value.issue {return issue}
        do {
            if mock {try vault.save(value.normalized)} else {guard authorized else{return "没能保存密钥，请重试。"};try Credential.save(value.normalized)}
            clearMissingCredentialHint();return nil
        } catch {return stored ? "没能更换密钥，原密钥仍可用。请重试。":"没能保存密钥，请重试。"}
    }
    func clearMissingCredentialHint() {
        if diagnostic.stringValue=="去设置里填写百炼密钥" {diagnostic.stringValue="密钥已保存";if currentCacheID==nil {empty?.stringValue="开始后，会议文字会出现在这里"}}
    }
    @objc func showFirstRunGuide() {
        guard !recordingBusy else{return}
        let guide=firstRunGuide ?? FirstRunGuide(owner:self);firstRunGuide=guide;guide.present()
    }
    func presentFirstRunGuideIfNeeded() {
        guard !mock,!offlineQA,!Credential.offline else{return}
        let guide=FirstRunGuide(owner:self);firstRunGuide=guide;guide.presentIfNeeded()
    }
}

@MainActor func firstRunGuideChecks(directory:URL) throws -> [String] {
    guard Credential.offline,directory.path.contains("/.runtime/") else{throw Failure(code:"first_run_scope")}
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:"first_run_"+name)};checks.append(name)}
    let fm=FileManager.default,root=directory.appendingPathComponent("first-run-\(UUID().uuidString)")
    try fm.createDirectory(at:root,withIntermediateDirectories:true)
    defer {try? fm.removeItem(at:root)}

    // A release that adds a system permission cannot ship until the guide prepares people for it.
    let covered=Set(FirstRunStep.all.flatMap(\.usageKeys))
    let requested=Set((Bundle.main.infoDictionary ?? [:]).keys.filter{$0.hasSuffix("UsageDescription")})
    try check(requested.isSubset(of:covered),"guide_covers_every_system_permission_\(requested.subtracting(covered).sorted())")
    try check(RuntimeConfiguration.toolSearchPaths.contains(NSHomeDirectory()+"/.local/bin"),"assistant_search_path_includes_user_install")

    // The probe runs a real executable and reads only its exit status.
    func fakeCodex(_ script:String?)throws->[String] {
        let bin=root.appendingPathComponent(UUID().uuidString);try fm.createDirectory(at:bin,withIntermediateDirectories:true)
        if let script {
            let file=bin.appendingPathComponent("codex");try ("#!/bin/sh\n"+script+"\n").write(to:file,atomically:true,encoding:.utf8)
            try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:file.path)
        }
        return [bin.path]
    }
    try check(FirstRunCodexProbe.status(searchPaths:try fakeCodex(nil)) == .notInstalled,"probe_finds_missing_codex")
    try check(FirstRunCodexProbe.status(searchPaths:try fakeCodex("exit 0")) == .ready,"probe_accepts_login")
    try check(FirstRunCodexProbe.status(searchPaths:try fakeCodex("exit 1")) == .needsLogin,"probe_reports_missing_login")
    try check(FirstRunCodexProbe.status(searchPaths:try fakeCodex("sleep 5"),timeout:0.2) == .ready,"probe_timeout_does_not_nag")

    let owner=Delegate();owner.previewRenderOnly=true;owner.recoveryRootOverride=root.appendingPathComponent("SessionCache")
    owner.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    defer {owner.window.orderOut(nil)}
    func settle(_ condition:@escaping ()->Bool) {
        let end=Date().addingTimeInterval(5)
        while !condition() && Date()<end {_=RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.02))}
    }
    func snapshot(_ guide:FirstRunGuide,_ name:String)throws {
        let target=guide.panel.contentView!;target.layoutSubtreeIfNeeded()
        let bitmap=target.bitmapImageRepForCachingDisplay(in:target.bounds)!
        target.effectiveAppearance.performAsCurrentDrawingAppearance{target.cacheDisplay(in:target.bounds,to:bitmap)}
        try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name+".png"))
    }
    func guide(_ name:String,status:FirstRunAssistantStatus)->FirstRunGuide {
        let data=root.appendingPathComponent(name)
        return FirstRunGuide(owner:owner,dataRoot:data,meetings:data.appendingPathComponent("SessionCache"),probe:{status})
    }
    try fm.createDirectory(at:directory,withIntermediateDirectories:true)

    // Everything already in place: never interrupt, and remember that silently.
    owner.vault.bytes=Data("fake_key".utf8)
    let quiet=guide("quiet",status:.ready);var quietDone=false
    quiet.presentIfNeeded {quietDone=true};settle{quietDone}
    try check(quietDone && owner.window.attachedSheet==nil && quiet.seen==["transcription","assistant"],"configured_install_sees_no_guide")

    // New install: one next action at a time, and always a way past it.
    owner.vault.bytes=nil
    let new=guide("new",status:.notInstalled);var newDone=false
    new.presentIfNeeded {newDone=true};settle{newDone}
    try check(owner.window.attachedSheet===new.panel && new.activeStep == .transcription,"new_install_starts_with_transcription")
    try check(new.panel.frame.height>200 && new.panel.frame.height<620,"guide_fits_a_small_screen_\(new.panel.frame.height)")
    try snapshot(new,"first-run-1-key")
    new.fillKeyForChecks("  ");new.saveKey()
    try check(owner.vault.bytes==nil && new.activeStep == .transcription,"blank_key_is_refused")
    new.fillKeyForChecks("fake_guide_key");new.saveKey()
    try check(owner.vault.load()=="fake_guide_key" && new.isDone(.transcription) && new.activeStep == .assistant,"saved_key_moves_to_assistant")
    try snapshot(new,"first-run-2-assistant")
    new.skip(.assistant)
    try check(new.activeStep==nil,"assistant_can_be_skipped")
    try snapshot(new,"first-run-3-ready")
    new.complete()
    try check(owner.window.attachedSheet==nil && Set(FirstRunStep.all.map{$0.kind.rawValue}).isSubset(of:new.seen),"finishing_marks_every_step_seen")

    // A skipped step does not come back on the next launch.
    let again=FirstRunGuide(owner:owner,dataRoot:root.appendingPathComponent("new"),meetings:root.appendingPathComponent("new/SessionCache"),probe:{.notInstalled});var againDone=false
    again.presentIfNeeded {againDone=true};settle{againDone}
    try check(owner.window.attachedSheet==nil,"skipped_step_does_not_nag")

    // A step added by a later release reaches people who finished the guide before it existed.
    let upgraded=root.appendingPathComponent("upgraded");try fm.createDirectory(at:upgraded,withIntermediateDirectories:true)
    try Data(#"{"schema":1,"seen":["recording","transcription"]}"#.utf8).write(to:upgraded.appendingPathComponent("first-run.json"))
    let later=FirstRunGuide(owner:owner,dataRoot:upgraded,meetings:upgraded.appendingPathComponent("SessionCache"),probe:{.needsLogin});var laterDone=false
    later.presentIfNeeded {laterDone=true};settle{laterDone}
    try check(owner.window.attachedSheet===later.panel && later.activeStep == .assistant,"new_step_reaches_existing_users")
    try check(later.detail(.assistant).contains("还没登录"),"login_state_is_named")
    later.complete()

    // Having recorded answers the recording step; it never opens the guide alone.
    owner.vault.bytes=Data("fake_key".utf8)
    let recorded=root.appendingPathComponent("recorded");try fm.createDirectory(at:recorded.appendingPathComponent("SessionCache/meeting"),withIntermediateDirectories:true)
    let done=FirstRunGuide(owner:owner,dataRoot:recorded,meetings:recorded.appendingPathComponent("SessionCache"),probe:{.ready});var doneDone=false
    done.presentIfNeeded {doneDone=true};settle{doneDone}
    try check(owner.window.attachedSheet==nil && done.isDone(.recording),"existing_meetings_count_as_recorded")
    owner.vault.bytes=nil
    return checks
}
