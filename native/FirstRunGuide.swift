import AppKit

/// What a new install needs, in one list. A release that adds a permission or a
/// service adds a step here; people who already finished the guide see just that step.
struct FirstRunStep {
    enum Kind:String {case transcription,recording}
    let kind:Kind
    /// True when an unfinished step is worth interrupting the launch for.
    let opensGuide:Bool
    /// System permission prompts this step prepares people for. Checked against Info.plist.
    let usageKeys:[String]
    static let all=[
        FirstRunStep(kind:.transcription,opensGuide:true,usageKeys:[]),
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

/// One card, one decision: a transcription key, or recording only for now. The assistant's Codex is optional
/// and lives in Settings; system permissions are asked by macOS the first time a recording starts.
final class FirstRunGuide:NSObject {
    static let keyURL=URL(string:"https://bailian.console.aliyun.com/?tab=model#/api-key")!
    static let installCommand="curl -fsSL https://chatgpt.com/codex/install.sh | sh && codex"
    private weak var owner:Delegate?
    private let seenFile:URL,meetings:URL
    private(set) var skipped=Set<FirstRunStep.Kind>()
    let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:480,height:260),styleMask:[.titled],backing:.buffered,defer:false)
    private let keyField=NSSecureTextField(),keyMessage=NSTextField(labelWithString:"")
    init(owner:Delegate,dataRoot:URL=RuntimeConfiguration.dataRoot(),meetings:URL?=nil) {
        self.owner=owner;seenFile=dataRoot.appendingPathComponent("first-run.json")
        self.meetings=meetings ?? dataRoot.appendingPathComponent("SessionCache")
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
        case .recording:return hasRecorded
        }
    }
    var activeStep:FirstRunStep.Kind? {
        FirstRunStep.all.first{$0.opensGuide && !isDone($0.kind) && !skipped.contains($0.kind)}?.kind
    }
    /// Launch path: stay quiet unless a step this person has not seen actually needs them.
    func presentIfNeeded(completion:(()->Void)?=nil) {
        guard let owner else{completion?();return}
        var seen=self.seen
        for step in FirstRunStep.all where isDone(step.kind) {seen.insert(step.kind.rawValue)}
        self.seen=seen
        let needed=FirstRunStep.all.filter{$0.opensGuide && !seen.contains($0.kind.rawValue) && !isDone($0.kind)}
        // Someone who has already started a meeting is not interrupted.
        if !needed.isEmpty,owner.window.attachedSheet==nil,owner.phase.phase == .idle,owner.currentCacheID==nil || owner.mock {present()}
        completion?()
    }
    func present() {
        guard let owner,owner.window.attachedSheet==nil else{return}
        skipped=[];keyMessage.stringValue="";keyMessage.isHidden=true;owner.window.beginSheet(panel);panel.makeFirstResponder(keyField)
    }
    private func build() {
        panel.isReleasedWhenClosed=false;panel.backgroundColor=MeetingVisualStyle.surface
        let title=NSTextField(labelWithString:"开始用在场");title.font=MeetingVisualStyle.titleFont(22);title.textColor=MeetingVisualStyle.ink
        let intro=wrapping("录音只存在这台 Mac。转文字和出概览用你自己的阿里云百炼密钥，一小时会议约 1 元。",size:13,color:MeetingVisualStyle.muted)
        keyField.placeholderString="粘贴百炼 API 密钥";keyField.font = .systemFont(ofSize:13);keyField.bezelStyle = .roundedBezel;keyField.target=self;keyField.action=#selector(start)
        keyField.translatesAutoresizingMaskIntoConstraints=false;keyField.widthAnchor.constraint(equalToConstant:424).isActive=true
        keyMessage.font = .systemFont(ofSize:12);keyMessage.textColor=MeetingVisualStyle.accentText;keyMessage.isHidden=true
        let permissions=wrapping(detail(.recording),size:12,color:MeetingVisualStyle.muted)
        let create=SpeakerPillButton(title:"去百炼创建密钥 ↗",primary:false,small:true) {NSWorkspace.shared.open(Self.keyURL)}
        let later=SpeakerPillButton(title:"先只录音",primary:false) {[weak self] in self?.skip(.transcription)}
        let begin=SpeakerPillButton(title:"开始",primary:true) {[weak self] in self?.start()}
        let footer=NSStackView(views:[create,NSView(),later,begin]);footer.orientation = .horizontal;footer.spacing=8;footer.alignment = .centerY
        let page=NSStackView(views:[title,intro,keyField,keyMessage,permissions,footer]);page.orientation = .vertical;page.alignment = .leading;page.spacing=12
        page.setCustomSpacing(18,after:intro);page.setCustomSpacing(20,after:permissions)
        page.translatesAutoresizingMaskIntoConstraints=false
        let content=panel.contentView!;content.addSubview(page)
        NSLayoutConstraint.activate([page.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:28),page.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-28),
                                     page.topAnchor.constraint(equalTo:content.topAnchor,constant:26),page.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-22),
                                     content.widthAnchor.constraint(equalToConstant:480),footer.widthAnchor.constraint(equalTo:page.widthAnchor)])
        fit()
    }
    private func fit() {
        panel.contentView?.layoutSubtreeIfNeeded()
        if let size=panel.contentView?.fittingSize,size.height>0 {panel.setContentSize(NSSize(width:480,height:size.height))}
    }
    private func wrapping(_ text:String,size:CGFloat,color:NSColor)->NSTextField {
        let field=NSTextField(wrappingLabelWithString:text);field.font = .systemFont(ofSize:size);field.textColor=color;field.isSelectable=false
        field.preferredMaxLayoutWidth=424;field.translatesAutoresizingMaskIntoConstraints=false;field.widthAnchor.constraint(equalToConstant:424).isActive=true
        return field
    }
    func detail(_ kind:FirstRunStep.Kind)->String {
        switch kind {
        case .transcription:return isDone(kind) ? "密钥已保存在这台 Mac。":"录音只存在这台 Mac。转文字和出概览用你自己的阿里云百炼密钥，一小时会议约 1 元。"
        case .recording:return "第一次录音时，系统会问麦克风和电脑声音，两个都点「允许」，只问这一次。"
        }
    }
    /// "开始": an empty field means the key was saved earlier or is wanted later; anything typed must save.
    @objc func start() {
        if keyField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,isDone(.transcription) {complete();return}
        saveKey()
        if isDone(.transcription),keyMessage.isHidden {complete()}
    }
    @objc func saveKey() {
        guard let owner else{return}
        if let problem=owner.storeBailianKey(keyField.stringValue) {keyMessage.stringValue=problem;keyMessage.isHidden=false;fit();return}
        keyField.stringValue="";keyMessage.stringValue="";keyMessage.isHidden=true;fit()
    }
    func fillKeyForChecks(_ value:String) {keyField.stringValue=value}
    /// "先只录音" makes recording-only the start choice, so the record button works without a key.
    func skip(_ kind:FirstRunStep.Kind) {
        if kind == .transcription {owner?.selectRecordingModeFromChip(1)}
        skipped.insert(kind);if activeStep==nil {complete()}
    }
    func complete() {
        var seen=self.seen;seen.formUnion(FirstRunStep.all.map{$0.kind.rawValue});self.seen=seen
        owner?.window.endSheet(panel);panel.orderOut(nil)
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
    /// Codex is optional: with it the assistant can look things up, use tools and listen; without it, it still answers.
    @objc func showCodexConnection() {
        let window=sheet.isVisible ? sheet:window
        DispatchQueue.global(qos:.userInitiated).async {
            let status=FirstRunCodexProbe.status()
            DispatchQueue.main.async {[weak self] in
                guard let self,let window else{return}
                let alert=NSAlert()
                if status == .ready {
                    alert.messageText="Codex 已连接";alert.informativeText="\(AssistantProfile.name)可以查资料、用工具，也可以旁听会上交办的事。";alert.addButton(withTitle:"好")
                    alert.beginSheetModal(for:window)
                    return
                }
                alert.messageText="连接 Codex（可选）"
                alert.informativeText="用你的 ChatGPT 账号，让\(AssistantProfile.name)能查资料、用工具和旁听。不连也不影响别的。\n\n点下面的按钮会复制一条命令并打开终端：粘贴、回车，按提示登录。"
                alert.addButton(withTitle:"复制命令并打开终端");alert.addButton(withTitle:"取消")
                alert.beginSheetModal(for:window) {response in
                    guard response == .alertFirstButtonReturn else{return}
                    let command=status == .needsLogin ? "codex":FirstRunGuide.installCommand
                    NSPasteboard.general.clearContents();NSPasteboard.general.setString(command,forType:.string)
                    NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/Utilities/Terminal.app"))
                }
            }
        }
    }
    @objc func checkForUpdatesFromSettings() {
        dismissSettings();AppUpdater.shared.showOrCheck()
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
    func snapshot(_ guide:FirstRunGuide,_ name:String)throws {
        let target=guide.panel.contentView!;target.layoutSubtreeIfNeeded()
        let bitmap=target.bitmapImageRepForCachingDisplay(in:target.bounds)!
        target.effectiveAppearance.performAsCurrentDrawingAppearance{target.cacheDisplay(in:target.bounds,to:bitmap)}
        try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name+".png"))
    }
    func guide(_ name:String)->FirstRunGuide {
        let data=root.appendingPathComponent(name)
        return FirstRunGuide(owner:owner,dataRoot:data,meetings:data.appendingPathComponent("SessionCache"))
    }
    try fm.createDirectory(at:directory,withIntermediateDirectories:true)

    // A key already saved: never interrupt, and remember that silently.
    owner.vault.bytes=Data("fake_key".utf8)
    let quiet=guide("quiet");quiet.presentIfNeeded()
    try check(owner.window.attachedSheet==nil && quiet.seen==["transcription"],"configured_install_sees_no_guide")

    // New install: one card, and the key is the only question. Codex is not part of it.
    owner.vault.bytes=nil
    let new=guide("new");new.presentIfNeeded()
    try check(owner.window.attachedSheet===new.panel && new.activeStep == .transcription,"new_install_asks_for_the_key")
    try check(new.panel.frame.height>150 && new.panel.frame.height<420,"guide_is_one_small_card_\(new.panel.frame.height)")
    try snapshot(new,"first-run-1-key")
    new.fillKeyForChecks("  ");new.start()
    try check(owner.vault.bytes==nil && owner.window.attachedSheet===new.panel,"blank_key_is_refused")
    new.fillKeyForChecks("fake_guide_key");new.start()
    try check(owner.vault.load()=="fake_guide_key" && owner.window.attachedSheet==nil,"saved_key_closes_the_card")
    try check(Set(FirstRunStep.all.map{$0.kind.rawValue}).isSubset(of:new.seen),"finishing_marks_every_step_seen")

    // Recording only for now: the card closes, and the next launch doesn't ask again.
    owner.vault.bytes=nil
    let later=guide("later");later.presentIfNeeded();later.skip(.transcription)
    try check(owner.window.attachedSheet==nil,"record_only_closes_the_card")
    let again=guide("later");again.presentIfNeeded()
    try check(owner.window.attachedSheet==nil,"skipped_key_does_not_nag")

    // Having recorded answers the recording step; it never opens the guide alone.
    owner.vault.bytes=Data("fake_key".utf8)
    let recorded=root.appendingPathComponent("recorded");try fm.createDirectory(at:recorded.appendingPathComponent("SessionCache/meeting"),withIntermediateDirectories:true)
    let done=FirstRunGuide(owner:owner,dataRoot:recorded,meetings:recorded.appendingPathComponent("SessionCache"));done.presentIfNeeded()
    try check(owner.window.attachedSheet==nil && done.isDone(.recording),"existing_meetings_count_as_recorded")
    owner.vault.bytes=nil
    return checks
}
