import AppKit
import Darwin

struct ASRTermCandidate:Decodable {let word:String;let sources:[String]}
struct ASRTermProjection:Decodable {
    let schema:Int;let status:String;let requires_selection:Bool
    let candidates:[ASRTermCandidate];let source_digest:String?
    static func decode(_ data:Data)throws->Self {
        guard data.count<=256*1024 else{throw Failure(code:"asr_term_projection_limit")}
        let value=try JSONDecoder().decode(Self.self,from:data)
        guard value.schema==1,value.status=="ok",value.requires_selection,value.candidates.count<=2048,
              Set(value.candidates.map{$0.word}).count==value.candidates.count,
              value.candidates.allSatisfy({ASRTermVocabulary.valid($0.word) && $0.sources.count<=8 && !$0.sources.isEmpty && $0.sources.allSatisfy{$0.count<=1024 && !$0.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)}}) else{throw Failure(code:"asr_term_projection_invalid")}
        return value
    }
}

final class ASRTermsLoader {
    private let lock=NSLock();private var active:Process?;private var token=UUID()
    private static func stop(_ process:Process) {
        guard process.isRunning else{return}
        let pid=process.processIdentifier;process.terminate()
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+0.25) {if process.isRunning,process.processIdentifier==pid {_=Darwin.kill(pid,SIGKILL)}}
    }
    func cancel(){lock.lock();token=UUID();let old=active;active=nil;lock.unlock();if let old {Self.stop(old)}}
    func load(root:String,done:@escaping(Result<ASRTermProjection,Error>)->Void) {
        cancel();lock.lock();let generation=token;lock.unlock()
        DispatchQueue.global(qos:.utility).async { [weak self] in
            guard let self else{return}
            let result:Result<ASRTermProjection,Error>=Result {
                let script=URL(fileURLWithPath:root).appendingPathComponent("shared_terms.py")
                guard script.path==script.resolvingSymlinksInPath().path,let attributes=try? FileManager.default.attributesOfItem(atPath:script.path),attributes[.type] as? FileAttributeType == .typeRegular,(attributes[.size] as? NSNumber)?.intValue ?? Int.max < 1024*1024 else{throw Failure(code:"asr_terms_unavailable")}
                guard let python=PythonRuntime.executable() else{throw Failure(code:"python_runtime_missing")}
                let process=Process(),pipe=Pipe();process.executableURL=python;process.arguments=["-B",script.path]
                var env=RuntimeConfiguration.childEnvironment();for key in ["PYTHONPATH","PYTHONHOME","PYTHONSTARTUP"] {env.removeValue(forKey:key)};env["PYTHONDONTWRITEBYTECODE"]="1";process.environment=env;process.standardInput=FileHandle.nullDevice;process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
                self.lock.lock();guard self.token==generation else{self.lock.unlock();throw Failure(code:"asr_terms_cancelled")}
                do {try process.run();self.active=process;self.lock.unlock()}catch{self.lock.unlock();throw error}
                let timeout=DispatchWorkItem {Self.stop(process)}
                DispatchQueue.global().asyncAfter(deadline:.now()+3.5,execute:timeout)
                defer{timeout.cancel();Self.stop(process);try? pipe.fileHandleForReading.close()}
                var data=Data()
                while true {let part=pipe.fileHandleForReading.availableData;if part.isEmpty{break};guard data.count+part.count<=256*1024 else{if process.isRunning{process.terminate()};throw Failure(code:"asr_terms_output_limit")};data.append(part)}
                process.waitUntilExit();guard process.terminationStatus==0 else{throw Failure(code:"asr_terms_unavailable")}
                return try ASRTermProjection.decode(data)
            }
            RunLoop.main.perform(inModes:[.common]) {self.lock.lock();let current=self.token==generation;if current{self.active=nil};self.lock.unlock();if current{done(result)}}
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}

final class ASRTermsPicker:NSObject,NSTableViewDataSource,NSTableViewDelegate,NSSearchFieldDelegate {
    let owner:Delegate,alert=NSAlert(),table=NSTableView(),search=NSSearchField(),source=NSPopUpButton(),status=NSTextField(wrappingLabelWithString:"正在读取已有术语…"),loader=ASRTermsLoader()
    var candidates:[ASRTermCandidate]=[],visible:[ASRTermCandidate]=[],selected:Set<String>,sourceDigest:String?
    init(owner:Delegate){self.owner=owner;selected=Set(owner.pendingASRTerms.keys);super.init()}
    func present() {
        alert.messageText="本场术语";alert.informativeText="仅发送你选中的词，帮助识别专名；不会据此确认发言人。开始转写时，所选词随音频发送至阿里云北京。本场结束后失效。"
        alert.addButton(withTitle:"本场使用");alert.addButton(withTitle:"取消");alert.addButton(withTitle:"不使用")
        alert.buttons[0].isEnabled=false
        let panel=NSView(frame:NSRect(x:0,y:0,width:460,height:330));search.frame=NSRect(x:0,y:298,width:220,height:26);search.placeholderString="筛选词语";search.delegate=self;search.setAccessibilityLabel("筛选已有术语");panel.addSubview(search)
        source.frame=NSRect(x:230,y:298,width:230,height:26);source.addItem(withTitle:"全部来源");source.target=self;source.action=#selector(filter);panel.addSubview(source)
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("term"));column.width=440;table.addTableColumn(column);table.headerView=nil;table.rowHeight=30;table.delegate=self;table.dataSource=self;table.setAccessibilityLabel("选择本场使用的术语")
        let scroll=NSScrollView(frame:NSRect(x:0,y:45,width:460,height:242));scroll.documentView=table;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;panel.addSubview(scroll)
        status.frame=NSRect(x:0,y:0,width:460,height:38);status.font = .systemFont(ofSize:11);status.textColor = .secondaryLabelColor;panel.addSubview(status);alert.accessoryView=panel
        if let fixture=owner.asrTermProjectionFixture {loaded(.success(fixture))}else{loader.load(root:owner.root){[weak self] in self?.loaded($0)}}
        let response=alert.runModal();loader.cancel()
        if response == .alertFirstButtonReturn,selected.count<=ASRTermVocabulary.maximumWords {owner.pendingASRTerms=Dictionary(uniqueKeysWithValues:selected.map{($0,2)});owner.pendingASRTermsDecision=true;owner.pendingASRTermDigest=sourceDigest}
        else if response == .alertThirdButtonReturn {owner.pendingASRTerms=[:];owner.pendingASRTermsDecision=true;owner.pendingASRTermDigest=nil}
        owner.updateASRTermStatus()
    }
    func loaded(_ result:Result<ASRTermProjection,Error>) {
        switch result {
        case .success(let value):candidates=value.candidates;sourceDigest=value.source_digest;selected.formIntersection(Set(candidates.map{$0.word}));source.addItems(withTitles:Array(Set(candidates.flatMap{$0.sources})).sorted());filter()
        case .failure:status.stringValue="术语来源暂不可用。取消后仍可正常转写；未发送任何术语。";alert.buttons[0].isEnabled=false
        }
    }
    @objc func filter(){let query=search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines);let scope=source.indexOfSelectedItem==0 ? nil:source.titleOfSelectedItem;visible=candidates.filter{(scope==nil || $0.sources.contains(scope!)) && (query.isEmpty || $0.word.localizedCaseInsensitiveContains(query))};table.reloadData();updateCount()}
    func controlTextDidChange(_ obj:Notification){filter()}
    func numberOfRows(in tableView:NSTableView)->Int {visible.count}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let item=visible[row],button=NSButton(checkboxWithTitle:item.word,target:self,action:#selector(toggle(_:)));button.identifier=NSUserInterfaceItemIdentifier(item.word);button.state=selected.contains(item.word) ? .on:.off;button.toolTip=item.sources.joined(separator:"\n");button.setAccessibilityLabel(item.word+"；来源："+item.sources.joined(separator:"、"));return button
    }
    @objc func toggle(_ button:NSButton){guard let word=button.identifier?.rawValue else{return};if button.state == .on {if selected.count>=ASRTermVocabulary.maximumWords {button.state = .off;status.stringValue="最多选择64个与本场相关的词。";return};selected.insert(word)}else{selected.remove(word)};updateCount()}
    func updateCount(){status.stringValue="已选 \(selected.count) · 在自动术语之外加给本场；不上传来源、人物身份或整份资料。";alert.buttons[0].isEnabled = !selected.isEmpty}
}

extension Delegate {
    @objc func chooseASRTerms(){let owner=workspaceOwner ?? self;guard !owner.recordingBusy else{return};let picker=ASRTermsPicker(owner:owner);withExtendedLifetime(picker){picker.present()}}
    func updateASRTermStatus(){asrTermsButton?.title=pendingASRTerms.isEmpty ? (pendingASRTermsDecision ? "本场不使用术语":"本场术语…"):"本场术语 · \(pendingASRTerms.count)";asrTermsButton?.toolTip=pendingASRTerms.isEmpty ? "已自动带上本项目、人物与通用术语；可再加选本场词语。仅录音不会上传":"手选词语与自动术语一起用于下一次转写；仅录音不会上传"}
    func requestWithASRTerms(_ original:[String:Any])->[String:Any] {
        guard original["cloud_session_confirmed"] as? Bool==true,original["local_only"] as? Bool != true else{return original}
        var request=original
        if pendingASRTermsDecision,let terms=try? ASRTermVocabulary.validated(pendingASRTerms) {request["asr_vocabulary"]=terms;request["asr_terms_confirmed"]=true}
        return request
    }
    func commitASRTermsOnStarted() {
        guard let terms=startingASRTerms else{return}
        activeASRTerms=terms;startingASRTerms=nil
        if pendingASRTermsDecision,pendingASRTerms==terms {pendingASRTerms=[:];pendingASRTermsDecision=false;pendingASRTermDigest=nil}
        updateASRTermStatus()
    }
}
