import AppKit

enum MeetingLibraryOperation:Int,CaseIterable {case rename,renameAudio,transcribe,exportAudio,audioFolder,transcriptFolder,meetingFiles,delete
    static var visibleOperations:[MeetingLibraryOperation] {allCases.filter{![.audioFolder,.transcriptFolder].contains($0)}}
}
struct MeetingLibraryFiles {
    let session:String;let localOnly:Bool;let audioFolder:URL?;let transcriptFolder:URL?
    var audioAssets:MeetingAudioAssetInfo?=nil
    static func directory(_ url:URL)throws {
        guard url.standardizedFileURL.path==url.resolvingSymlinksInPath().standardizedFileURL.path else{throw Failure(code:"library_path_invalid")}
        let values=try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);guard values.isDirectory==true,values.isSymbolicLink != true else{throw Failure(code:"library_directory_missing")}
    }
    static func read(_ item:CachedMeeting,root:URL)throws->MeetingLibraryFiles {
        guard UUID(uuidString:item.id) != nil,item.directory.standardizedFileURL==root.appendingPathComponent(item.id).standardizedFileURL else{throw Failure(code:"library_scope_invalid")}
        try directory(item.directory)
        func object(_ file:URL)throws->[String:Any] {
            guard file.standardizedFileURL.path==file.resolvingSymlinksInPath().standardizedFileURL.path else{throw Failure(code:"library_path_invalid")}
            let v=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]);guard v.isRegularFile==true,v.isSymbolicLink != true,(v.fileSize ?? 0)<=512*1024 else{throw Failure(code:"library_metadata_invalid")}
            guard let result=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any] else{throw Failure(code:"library_metadata_invalid")};return result
        }
        let metadata=try object(item.directory.appendingPathComponent("meeting.json"));guard let session=metadata["session"] as? String,!session.isEmpty,(metadata["cache_id"] as? String ?? item.id)==item.id else{throw Failure(code:"library_session_invalid")}
        func contents(_ folder:URL)throws->(Bool,Bool) {
            try directory(folder);let files=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]);guard files.count<=12000 else{throw Failure(code:"library_file_capacity")}
            var audio=false,text=false
            for file in files {
                let name=file.lastPathComponent
                let audioName=name.range(of:"^(mic(?:-raw)?|reference|remote(?:-g[1-9][0-9]{0,2})?|app-[a-f0-9]{16}(?:-g[1-9][0-9]{0,2})?)-[0-9]{6}\\.pcm$",options:.regularExpression) != nil
                let textName=name=="archived-transcript.txt" || (name.hasSuffix("-transcript.jsonl") && isTranscriptAudioTrack(String(name.dropLast("-transcript.jsonl".count))))
                guard audioName || textName else{continue}
                let v=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]);guard v.isRegularFile==true,v.isSymbolicLink != true,file.standardizedFileURL.path==file.resolvingSymlinksInPath().standardizedFileURL.path else{throw Failure(code:"library_file_invalid")}
                if (v.fileSize ?? 0)>0 {audio=audio || audioName;text=text || textName}
            }
            return (audio,text)
        }
        let current=try contents(item.directory);var audioFolder=current.0 ? item.directory:nil
        if audioFolder==nil,FileManager.default.fileExists(atPath:item.directory.appendingPathComponent("audio-retirement.json").path) {
            let receipt=try object(item.directory.appendingPathComponent("audio-retirement.json")),retired=root.appendingPathComponent(".retired").appendingPathComponent(item.id)
            if receipt["state"] as? String=="trashed" {
                guard receipt["schema"] as? Int==1,receipt["cache_id"] as? String==item.id,receipt["recoverable"] as? Bool==true,receipt["destination"] as? String==retired.path else{throw Failure(code:"library_retired_scope")}
                if try contents(retired).0 {audioFolder=retired}
            }
        }
        var result=MeetingLibraryFiles(session:session,localOnly:metadata["capture_mode"] as? String=="local_only" && metadata["upload_authorized"] as? Bool != true,audioFolder:audioFolder,transcriptFolder:current.1 ? item.directory:nil)
        result.audioAssets=try? MeetingAudioAssetsStore(cacheRoot:root).info(item)
        return result
    }
}

// NSMenu uses a nested event-tracking run loop. Deliver capability reads in
// common modes so a first-open menu can become usable without closing it.
final class MeetingLibraryReadJob {
    var busy=false
    var onStateChange:(()->Void)?
    private var token:UUID?
    private var deadline:Timer?
    func cancel(){token=nil;deadline?.invalidate();deadline=nil;onStateChange?()}
    func run<T>(timeout:Double=5,work:@escaping()throws->T,done:@escaping(Result<T,Error>)->Void) {
        precondition(Thread.isMainThread)
        guard !busy else{done(.failure(Failure(code:"cache_io_still_waiting")));return}
        busy=true;let id=UUID();token=id;onStateChange?()
        let timer=Timer(timeInterval:timeout,repeats:false) { [weak self] _ in
            guard let self,self.token==id else{return}
            self.token=nil;self.deadline=nil;self.onStateChange?();done(.failure(Failure(code:"cache_io_timeout")))
        }
        deadline=timer;RunLoop.main.add(timer,forMode:.common)
        DispatchQueue.global(qos:.userInitiated).async {
            let result=Result{try work()}
            RunLoop.main.perform(inModes:[.common]) {
                self.busy=false
                guard self.token==id else{self.onStateChange?();return}
                self.token=nil;timer.invalidate();self.deadline=nil;self.onStateChange?();done(result)
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}

final class MeetingLibraryManagement:NSObject {
    weak var owner:Delegate?
    let view=NSStackView();let status=NSTextField(wrappingLabelWithString:"")
    var buttons:[MeetingLibraryOperation:NSButton]=[:]
    var item:CachedMeeting?;var files:MeetingLibraryFiles?;var loadedID:String?;var busy=false;var contextMenuOpen=false;var readingID:String?
    let readJob=MeetingLibraryReadJob()
    var renameOverride:((CachedMeeting)->String?)?;var audioRenameOverride:((CachedMeeting,String)->String?)?;var revealOverride:((URL)->Bool)?;var audioAssetOperationInFlight=false
    var audioStoreOverride:MeetingAudioAssetsStore?
    var beforeWrite:((URL)throws->Void)?
    var readOverride:((CachedMeeting,URL)throws->MeetingLibraryFiles)?
    init(owner:Delegate) {
        self.owner=owner;super.init();view.orientation = .vertical;view.alignment = .leading;view.spacing=3
        for operation in MeetingLibraryOperation.visibleOperations {
            let button=NSButton(title:title(operation),target:self,action:#selector(click(_:)));button.tag=operation.rawValue;button.bezelStyle = .inline;button.isBordered=false;button.font = .systemFont(ofSize:11);button.alignment = .left
            let symbol:[MeetingLibraryOperation:String]=[.rename:"pencil",.renameAudio:"waveform",.transcribe:"text.bubble",.exportAudio:"square.and.arrow.up",.meetingFiles:"folder",.delete:"trash"]
            button.image=NSImage(systemSymbolName:symbol[operation]!,accessibilityDescription:nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:11,weight:.regular));button.imagePosition = .imageLeading
            view.addArrangedSubview(button);button.widthAnchor.constraint(equalTo:view.widthAnchor).isActive=true;buttons[operation]=button
        }
        status.font = .systemFont(ofSize:10);status.textColor = .secondaryLabelColor;status.maximumNumberOfLines=3;status.setAccessibilityLabel("所选会议操作状态");view.addArrangedSubview(status);status.widthAnchor.constraint(equalTo:view.widthAnchor).isActive=true
        readJob.onStateChange={ [weak self] in guard let self,!self.readJob.busy,self.readingID != self.item?.id else{return};self.refresh() };refresh()
    }
    func title(_ operation:MeetingLibraryOperation)->String {
        switch operation {case .rename:return "重命名会议";case .renameAudio:return "重命名录音";case .exportAudio:return "导出录音";case .transcribe:return files?.localOnly==true ? "转写录音":"补转剩余录音";case .audioFolder:return "录音文件夹";case .transcriptFolder:return "转写文件夹";case .meetingFiles:return "打开会议文件…";case .delete:return "删除会议"}
    }
    func enabled(_ operation:MeetingLibraryOperation,for target:CachedMeeting?=nil)->Bool {
        guard let owner,let target=target ?? item,!busy,!owner.meetingDeletionBusy else{return false}
        let known=loadedID==target.id ? files:nil
        switch operation {
        case .rename:return known != nil
        case .renameAudio:return known?.audioAssets != nil && !(target.id==owner.currentCacheID && owner.recordingBusy)
        case .exportAudio:return known?.audioAssets != nil && !owner.recordingBusy && (known?.audioAssets?.exported==true || known?.audioAssets?.needsRecovery==true || (known?.audioFolder==target.directory && !target.warning))
        case .delete:return target.id != owner.currentCacheID || owner.canDeleteCurrentMeeting
        case .transcribe:return known?.audioFolder != nil && target.pendingBytes>0 && !owner.recordingBusy && !owner.cacheReadJob.busy
        case .audioFolder:return known?.audioFolder != nil
        case .transcriptFolder:return known?.transcriptFolder != nil
        case .meetingFiles:return known != nil && !owner.recordingBusy
        }
    }
    func disabledReason(_ operation:MeetingLibraryOperation,for target:CachedMeeting?=nil)->String {
        guard let owner,let target=target ?? item else{return "请先选择一场会议"}
        if busy || owner.meetingDeletionBusy {return "正在处理记录，请稍候再试"}
        if operation == .delete,target.id==owner.currentCacheID,!owner.canDeleteCurrentMeeting {return owner.currentMeetingDeleteBlockReason}
        if operation == .renameAudio,target.id==owner.currentCacheID,owner.recordingBusy {return "录音尚未封存，暂不能修改文件名"}
        if (operation == .exportAudio || operation == .meetingFiles),owner.recordingBusy {return "录音尚未封存，暂不能导出或整理文件"}
        if operation == .exportAudio,files?.audioAssets?.exported != true,files?.audioAssets?.needsRecovery != true,target.warning {return "录音尚未完整保存，暂不能导出"}
        if operation == .transcribe,owner.recordingBusy {return "当前会议仍在处理，暂不能补转其他录音"}
        if operation == .transcribe,owner.cacheReadJob.busy {return "正在读取会议，请稍候再试"}
        guard loadedID==target.id,let files else{return readJob.busy ? "记录仍在读取，请稍后再试":"记录无法读取，请重新右键重试"}
        if operation == .renameAudio || operation == .exportAudio,files.audioAssets==nil {return "录音名称资料无法读取，请重新右键重试"}
        if operation == .exportAudio,files.audioAssets?.exported != true,files.audioAssets?.needsRecovery != true,let folder=files.audioFolder,folder != target.directory {return "原始录音已移至回收区，请先恢复原音再导出"}
        if operation == .transcribe || (operation == .exportAudio && files.audioAssets?.exported != true && files.audioAssets?.needsRecovery != true),files.audioFolder==nil {return "本场没有可用的录音文件"}
        if operation == .transcribe,target.pendingBytes<=0 {return "本场没有待处理的转写"}
        return "记录状态已变化，请重新右键选择"
    }
    func refresh(force:Bool=false) {
        guard let owner else{return}
        let selected=contextMenuOpen ? owner.libraryMenuTarget:owner.selectedLibraryManagementItem
        if force {files=nil;loadedID=nil}
        if item?.id != selected?.id {item=selected;files=nil;loadedID=nil;status.stringValue="";readingID=nil;readJob.cancel()}else{item=selected}
        for (operation,button) in buttons {
            button.title=title(operation);button.isEnabled=enabled(operation);button.setAccessibilityLabel(button.title)
            button.toolTip=operation == .meetingFiles ? "一次打开本场录音、转写原文和文件说明":operation == .transcribe ? "已有原文会保留，只处理尚未转成文字的录音":nil
        }
        guard let item else{status.stringValue="选择一场会议后可管理";return}
        if loadedID != item.id,!readJob.busy {
            let root=owner.recoveryBase(),id=item.id,reader=readOverride;readingID=id;status.stringValue="正在读取记录"
            readJob.run(work:{if let reader{return try reader(item,root)};return try MeetingLibraryFiles.read(item,root:root)}){[weak self] result in
                guard let self,self.item?.id==id else{return};self.loadedID=id
                switch result {case .success(let files):self.files=files;self.status.stringValue=files.localOnly ? "仅保存录音；转写需确认上传":"本场文件状态已读取"
                case .failure:self.files=nil;self.status.stringValue="记录无法读取，请重新右键重试"}
                self.refresh();if self.contextMenuOpen,let menu=owner.libraryTable.menu {owner.populateLibraryActions(menu);menu.update()}
            }
        } else if !busy,loadedID==item.id,owner.recordingBusy {
            status.stringValue=item.id==owner.currentCacheID && owner.canDeleteCurrentMeeting ? "本场已暂停，可删除；录音文件尚未封存":"可查看记录；录音尚未封存，暂不能导出或整理文件"
        }
    }
    @objc private func click(_ sender:NSButton){guard let operation=MeetingLibraryOperation(rawValue:sender.tag),let item else{return};perform(operation,item:item)}
    func perform(_ operation:MeetingLibraryOperation,item:CachedMeeting) {
        guard let owner,enabled(operation,for:item) else{message(disabledReason(operation,for:item));return}
        switch operation {
        case .delete:owner.requestDeleteMeeting(item)
        case .rename:requestRename(item)
        case .renameAudio:requestAudioRename(item)
        case .exportAudio:exportAudio(item)
        case .transcribe:
            // Set the original target once. continueRecovery captures this item
            // before its asynchronous read and retains upload/budget confirmation.
            guard !owner.recordingBusy else{return};owner.returnToCurrent()
            owner.recoveryDetail=owner.diagnostic;let picker=FocusPopup();picker.addItem(withTitle:item.displayTitle);picker.selectedItem?.representedObject=item.id;owner.recoveryPicker=picker
            if !owner.recoveries.contains(where:{$0.id==item.id}) {owner.recoveries.append(item)}
            owner.continueRecovery()
        case .audioFolder,.transcriptFolder:reveal(operation,item:item)
        case .meetingFiles:openMeetingFiles(item)
        }
    }
    func requestRename(_ item:CachedMeeting) {
        guard let owner,!busy,!owner.meetingDeletionBusy else{message(disabledReason(.rename,for:item));return}
        let name:String?
        if let renameOverride {name=renameOverride(item)}else{
            let alert=NSAlert();alert.messageText="重命名会议";alert.informativeText="修改会议标题和之后导出原文的默认文件名。录音文件名、已另存的文件保持不变。"
            let field=NSTextField(string:item.displayTitle);field.frame=NSRect(x:0,y:0,width:320,height:26);alert.accessoryView=field;alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消");alert.window.initialFirstResponder=field
            name=alert.runModal() == .alertFirstButtonReturn ? field.stringValue:nil
        }
        guard let name else{return};let trimmed=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty,trimmed.count<=80,!trimmed.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{message("名称需为1–80个字，不能包含换行");return}
        rename(item,to:trimmed)
    }
    func rename(_ item:CachedMeeting,to name:String,completion:((Result<Void,Error>)->Void)?=nil) {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,name.count<=80,!name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{completion?(.failure(Failure(code:"library_title_invalid")));message("名称需为1–80个字，不能包含换行");return}
        guard let owner,!busy,!owner.meetingDeletionBusy else{completion?(.failure(Failure(code:"library_operation_busy")));return};busy=true;refresh();message("正在保存名称")
        if owner.currentCacheID==item.id {owner.invalidateAutoTitle()}
        owner.finalTitleTasks.removeValue(forKey:item.id)?.cancel()
        let root=owner.recoveryBase(),beforeWrite=beforeWrite,publisher=owner.contextPublisher
        owner.cacheWriteQueue.async { [weak self,weak owner] in
            let result:Result<Void,Error>=Result {let info=try MeetingLibraryFiles.read(item,root:root);try beforeWrite?(item.directory);try MeetingDisplayInfoStore.saveManual(name,in:item.directory);if let publisher {publisher.updateTitle(session:info.session,title:name)}}
            DispatchQueue.main.async {
                guard let self else{return};self.busy=false
                switch result {
                case .success:
                    if let owner {
                        let selectedID=owner.selectedLibraryManagementItem?.id
                        for document in [owner,owner.historyReader].compactMap({$0}) where document.currentCacheID==item.id {document.meetingTitle=name;document.meetingTitleField.stringValue=name;document.updateWorkspacePresentation()}
                        for index in owner.recoveries.indices where owner.recoveries[index].id==item.id {owner.recoveries[index].customTitle=name}
                        for index in owner.libraryVisible.indices where owner.libraryVisible[index].id==item.id {owner.libraryVisible[index].customTitle=name}
                        // Finishing a rename must not select the active document
                        // after the user has selected another record meanwhile.
                        let previousSelectionGate=owner.librarySelectionChanging
                        owner.librarySelectionChanging=true
                        let changed=IndexSet(owner.libraryVisible.indices.filter{owner.libraryVisible[$0].id==item.id})
                        owner.libraryTable.reloadData(forRowIndexes:changed,columnIndexes:IndexSet(integersIn:0..<owner.libraryTable.numberOfColumns))
                        if let selectedID,let row=owner.libraryVisible.firstIndex(where:{$0.id==selectedID}) {owner.libraryTable.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)}
                        else {owner.libraryTable.deselectAll(nil)}
                        owner.librarySelectionChanging=previousSelectionGate
                        owner.updateLibraryManagement()
                    };self.message("「"+name+"」已保存")
                case .failure:self.message("名称保存失败，原名称保留，请重试")
                };self.refresh();completion?(result)
            }
        }
    }
    func reveal(_ operation:MeetingLibraryOperation,item:CachedMeeting) {
        guard let owner,!busy else{return};busy=true;refresh();let root=owner.recoveryBase()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result=Result {let files=try MeetingLibraryFiles.read(item,root:root);guard let folder=operation == .audioFolder ? files.audioFolder:files.transcriptFolder else{throw Failure(code:"library_folder_missing")};return folder}
            DispatchQueue.main.async {
                guard let self else{return};self.busy=false
                switch result {
                case .success(let folder):
                    let opened=self.revealOverride?(folder) ?? (Credential.offline ? false:NSWorkspace.shared.open(folder))
                    self.message(opened ? (operation == .audioFolder ? "已打开原始录音文件夹":"已打开原始转写记录文件夹（不是另存的TXT）"):"文件夹未能打开，请检查文件访问权限")
                case .failure:self.message("本场文件不存在或无法访问，未打开其他位置")
                };self.refresh()
            }
        }
    }
    func openMeetingFiles(_ target:CachedMeeting) {
        guard let owner,enabled(.meetingFiles,for:target),let library=loadedID==target.id ? files:nil else{message(disabledReason(.meetingFiles,for:target));return}
        let root=owner.recoveryBase(),audioStore=audioStoreOverride ?? MeetingAudioAssetsStore(cacheRoot:root),builder=MeetingFilesExportStore(cacheRoot:root,exportsRoot:audioStore.exportsRoot)
        busy=true;audioAssetOperationInFlight=true;refresh();owner.updateUI();message("正在整理会议文件；首次生成可能需要一些时间")
        owner.cacheWriteQueue.async { [weak self] in
            let result=Result {let files=try builder.build(target,library:library,audioStore:audioStore);try MeetingNotesStore.exportMeetingFiles(target,to:files.folder);return files}
            DispatchQueue.main.async {
                guard let self else{return};self.busy=false;self.audioAssetOperationInFlight=false;self.refresh(force:true);owner.updateUI()
                switch result {
                case .success(let files):
                    let opened=self.revealOverride?(files.folder) ?? (Credential.offline ? false:NSWorkspace.shared.open(files.folder))
                    let state=files.transcriptState+"，"+(files.audioCount==0 ? "无可用WAV":"包含\(files.audioCount)路录音")
                    self.message(opened ? "会议文件已整理并打开（\(state)）":"会议文件已整理（\(state)），请检查文件访问权限后重试打开")
                case .failure(let error):
                    let code=(error as? Failure)?.code ?? ""
                    self.message(code=="meeting_files_user_file_collision" ? "已保留你手动修改的文件；请先另存或移走同名文件，再重试整理会议文件":code.hasPrefix("meeting_files_") ? "会议文件整理失败；原始录音和已有文件均保留，请检查文件访问权限后重试":self.audioAssetFailure(error))
                }
                owner.completeApplicationTerminationIfReady()
            }
        }
    }
    func message(_ text:String){status.stringValue=text;owner?.displayedDocument.showTransientFeedback(text)}
}

extension Delegate {
    var selectedLibraryManagementItem:CachedMeeting? {guard let table=libraryTable,libraryVisible.indices.contains(table.selectedRow) else{return nil};return libraryVisible[table.selectedRow]}
    var libraryManagementController:MeetingLibraryManagement {if let libraryManagement{return libraryManagement};let controller=MeetingLibraryManagement(owner:self);libraryManagement=controller;return controller}
    func makeLibraryManagementView()->NSView {libraryManagementController.view}
    func makeLibraryRecycleButton()->NSButton {let button=NSButton(title:"回收站",target:self,action:#selector(showDeletedMeetings));button.toolTip="查看并恢复已删除会议";button.setAccessibilityLabel("查看并恢复已删除会议");button.bezelStyle = .inline;button.image=NSImage(systemSymbolName:"tray",accessibilityDescription:nil);button.imagePosition = .imageLeading;button.font = .systemFont(ofSize:11);return button}
    func updateLibraryManagement(){libraryManagement?.refresh()}
    func saveLibraryMeetingTitle(_ item:CachedMeeting,title:String,completion:((Result<Void,Error>)->Void)?=nil) {libraryManagementController.rename(item,to:title,completion:completion)}
    @objc func renameSelectedLibraryMeeting(){guard let item=selectedLibraryManagementItem else{return};libraryManagementController.requestRename(item)}
    @objc func deleteSelectedLibraryMeeting(){guard let item=selectedLibraryManagementItem else{return};requestDeleteMeeting(item)}
    @objc func transcribeSelectedLibraryMeeting(){guard let item=selectedLibraryManagementItem else{return};libraryManagementController.perform(.transcribe,item:item)}
    @objc func performLibraryManagementMenu(_ sender:NSMenuItem) {
        guard let target=sender.representedObject as? [String:Any],let id=target["id"] as? String,let raw=target["operation"] as? Int,let operation=MeetingLibraryOperation(rawValue:raw) else{return}
        let frozen=libraryMenuTarget?.id==id ? libraryMenuTarget:nil
        guard let item=frozen ?? libraryVisible.first(where:{$0.id==id}) ?? recoveries.first(where:{$0.id==id}) else{libraryManagementController.message("记录已不在列表中，请重新选择");return}
        libraryManagementController.perform(operation,item:item)
    }
}
