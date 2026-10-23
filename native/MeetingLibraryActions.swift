import AppKit

extension Delegate:NSMenuDelegate {
    // A confirmed paused-session delete closes the retained capture connection
    // internally before touching its files; no separate End action is needed.
    var canDeleteCurrentMeeting:Bool {
        guard !preparingModels,!processingAudio,!resumeBusy,!credentialReadJob.waiting,
              !newMeetingRequested,recordingControlInFlight==nil else{return false}
        return phase.phase == .paused || !recordingBusy
    }
    var currentMeetingDeleteBlockReason:String {
        phase.phase == .recording ? "请先暂停录音，再删除会议":"正在连接或保存会议，请稍后再删除"
    }
    var currentMeetingWriterStopped:Bool {
        child==nil && !processingAudio && !resumeBusy && !preparingModels && !credentialReadJob.waiting
        && ![.connecting,.recording,.paused,.stopping].contains(phase.phase)
    }
    var hasBufferedMeetingEvents:Bool {readLock.lock();defer{readLock.unlock()};return !pending.isEmpty || buffer.contains(10)}
    func reconcileDeletedMeetingProjections() {
        guard let publisher=contextPublisher else{return}
        let store=meetingDeletionStore
        cacheWriteQueue.async {
            do {
                let receipts=try store.receipts(includeRestored:true)
                var seen=Set<String>()
                for receipt in receipts where seen.insert(receipt.session).inserted {
                    let payload=try store.folder(receipt).appendingPathComponent("cache")
                    if receipt.state=="restored" {try publisher.restoreSession(receipt.session)}
                    else if receipt.state=="trashed" || FileManager.default.fileExists(atPath:payload.path) {try publisher.deleteSession(receipt.session)}
                }
            } catch {DispatchQueue.main.async{self.diagnostic.stringValue="会议回收站状态检查未完成，请重试恢复"}}
        }
    }
    var meetingDeletionStore:MeetingDeletionStore {deletionStoreOverride ?? MeetingDeletionStore(cacheRoot:recoveryBase())}
    func installLibraryContextMenu(){let menu=NSMenu();menu.delegate=self;menu.autoenablesItems=false;libraryTable.menu=menu}
    func libraryActionsButton()->NSButton {
        let button=NSButton(image:NSImage(systemSymbolName:"ellipsis.circle",accessibilityDescription:"会议操作")!,target:self,action:#selector(showLibraryActions(_:)))
        button.isBordered=false;button.toolTip="管理所选会议";button.setAccessibilityLabel("会议操作")
        button.widthAnchor.constraint(equalToConstant:26).isActive=true;return button
    }
    @objc func showLibraryActions(_ sender:NSButton) {
        let row=libraryTable.selectedRow
        libraryMenuTarget=libraryVisible.indices.contains(row) ? libraryVisible[row]:recoveries.first{$0.id==displayedDocument.currentCacheID}
        let menu=NSMenu();menu.autoenablesItems=false;populateLibraryActions(menu)
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.maxY+4),in:sender)
    }
    func populateLibraryActions(_ menu:NSMenu) {
        menu.removeAllItems()
        if let item=libraryMenuTarget {
            let controller=libraryManagementController
            for operation in MeetingLibraryOperation.visibleOperations {
                if operation == .transcribe || operation == .meetingFiles || operation == .delete {menu.addItem(.separator())}
                let entry=menu.addItem(withTitle:controller.title(operation)+(operation == .rename || operation == .renameAudio || operation == .delete ? "…":""),action:#selector(performLibraryManagementMenu(_:)),keyEquivalent:"");entry.target=self
                entry.representedObject=["id":item.id,"operation":operation.rawValue]
                entry.isEnabled=controller.enabled(operation,for:item)
                entry.toolTip = !entry.isEnabled ? controller.disabledReason(operation,for:item):operation == .meetingFiles ? "一处打开本场可播放录音、转写原文和会议说明":operation == .transcribe ? "保留已有原文，只转写剩余录音；不会开始录音":nil
            }
            if controller.loadedID != item.id {let loading=menu.addItem(withTitle:"正在读取记录…",action:nil,keyEquivalent:"");loading.isEnabled=false}
        }
    }
    func menuNeedsUpdate(_ menu:NSMenu) {
        guard menu===libraryTable?.menu else{return}
        let row=libraryTable.clickedRow
        if libraryManagement?.contextMenuOpen != true {libraryMenuTarget=libraryVisible.indices.contains(row) ? libraryVisible[row]:nil}
        if let target=libraryMenuTarget,let selected=libraryVisible.firstIndex(where:{$0.id==target.id}) {
            // Right-click targets are visually selected, while the document and
            // active recording are not implicitly replaced by a context menu.
            librarySelectionChanging=true;libraryTable.selectRowIndexes(IndexSet(integer:selected),byExtendingSelection:false);librarySelectionChanging=false
            libraryManagementController.refresh()
        }
        populateLibraryActions(menu)
    }
    func menuWillOpen(_ menu:NSMenu){
        guard menu===libraryTable?.menu else{return}
        let controller=libraryManagementController;controller.contextMenuOpen=true
        // Preserve a successful snapshot between menu construction and click.
        // Failed/missing snapshots get exactly one explicit retry per opening.
        controller.refresh(force:controller.files==nil || controller.loadedID != libraryMenuTarget?.id)
        populateLibraryActions(menu)
    }
    func menuDidClose(_ menu:NSMenu){if menu===libraryTable?.menu {libraryManagement?.contextMenuOpen=false;updateLibraryManagement()}}
    @objc func deleteLibraryMeeting(){guard let item=libraryMenuTarget else{return};requestDeleteMeeting(item)}
    func requestDeleteMeeting(_ item:CachedMeeting) {
        guard !meetingDeletionBusy,libraryManagement?.busy != true else{return}
        guard item.id != currentCacheID || canDeleteCurrentMeeting else {showTransientFeedback(currentMeetingDeleteBlockReason);return}
        let confirmed:Bool
        if let override=deletionConfirmationOverride {confirmed=override(item)}
        else {
            let alert=NSAlert();alert.messageText="删除「"+item.displayTitle+"」？";alert.informativeText="已录内容会先保存，再将本场录音、转写文字和会议资料一起移入回收站，之后可从回收站找回。另存到其他位置的文件、共享人物声纹档案保留。";alert.addButton(withTitle:"删除会议");alert.addButton(withTitle:"取消");confirmed=alert.runModal() == .alertFirstButtonReturn
        }
        guard confirmed,!meetingDeletionBusy,libraryManagement?.busy != true,item.id != currentCacheID || canDeleteCurrentMeeting else{return}
        cancelSpeakerRefinement(cacheID:item.id);historyReader?.cancelSpeakerRefinement(cacheID:item.id)
        meetingDeletionBusy=true;deletingCacheID=item.id;libraryJob.cancel();pendingLibraryOpen=nil;libraryOpenJob.cancel();librarySearchJob.cancel();libraryFilterWork?.cancel()
        let document=historyReader?.currentCacheID==item.id ? historyReader!:(currentCacheID==item.id ? self:nil)
        document?.meetingDocumentGeneration &+= 1;document?.inlinePopover?.close();document?.speakerReviewWindow?.close();document?.meetingTitleField.isEditable=false
        updateWorkspacePresentation();diagnostic.stringValue="正在保存并删除会议"
        let titleTasks=[currentCacheID==item.id ? titleTask:nil,finalTitleTasks.removeValue(forKey:item.id)].compactMap{$0};for task in titleTasks{task.cancel()}
        if currentCacheID==item.id {
            invalidateAutoTitle();titleProvider=nil;titleTextAllowed=false
            if phase.phase == .paused {
                suppressAutomaticRefinementAfterStop=true
                finishRecording()
                diagnostic.stringValue="正在保存已录内容，随后移入回收站"
            }
        }
        Task { @MainActor [weak self] in
            guard let self else{return}
            for task in titleTasks {await task.value}
            let deadline=Date().addingTimeInterval(30)
            while Date()<deadline {
                let isCurrent=self.currentCacheID==item.id
                let writer=document ?? self
                let stopped = !isCurrent || self.currentMeetingWriterStopped
                let buffered=self.hasBufferedMeetingEvents
                if stopped,!writer.cacheExportJob.busy,!writer.qaWriteJob.busy,(!isCurrent || !buffered) {break}
                try? await Task.sleep(nanoseconds:20_000_000)
            }
            let isCurrent=self.currentCacheID==item.id
            let writer=document ?? self
            guard !isCurrent || !self.hasBufferedMeetingEvents else{self.finishMeetingDeletion("会议仍在保存；文件保留，请稍后重试");return}
            guard (!isCurrent || self.currentMeetingWriterStopped),!writer.cacheExportJob.busy,!writer.qaWriteJob.busy else{self.finishMeetingDeletion("会议仍在保存；文件保留，请稍后重试");return}
            if let document {
                document.persistSessionNames { [weak self] result in
                    guard let self else{return}
                    guard case .success=result else{self.finishMeetingDeletion("人物修改保存失败；会议保留，请重试");return}
                    if isCurrent {self.persistRecordingLifecycle { [weak self] result in guard let self else{return};guard case .success=result else{self.finishMeetingDeletion("会议保存失败；文件保留，请重试");return};self.moveMeetingToBin(item,document:document)}}
                    else {self.moveMeetingToBin(item,document:document)}
                }
            } else {self.moveMeetingToBin(item,document:nil)}
        }
    }
    private func moveMeetingToBin(_ item:CachedMeeting,document:Delegate?) {
        let store=meetingDeletionStore,publisher=contextPublisher
        // Serialize behind both possible annotation/title writers. Capture and
        // export jobs were explicitly awaited; cancelled read results cannot reopen.
        cacheWriteQueue.async { [weak self] in
            if let document,document !== self {document.cacheWriteQueue.sync{}}
            let result=Result {try MeetingAudioAssetsStore(cacheRoot:store.cacheRoot,exportsRoot:store.exportsRoot).recoverPending(item);return try store.trash(item,afterMove:{try publisher?.deleteSession($0)})}
            DispatchQueue.main.async {
                guard let self else{return}
                switch result {
                case .success:
                    if self.historyReader?.currentCacheID==item.id {self.returnToCurrent()}
                    if self.currentCacheID==item.id {self.meetingDeletionBusy=false;self.newMeeting();self.contextSession=nil;self.contextPublisher?.clearCurrent()}
                    self.recoveries.removeAll{$0.id==item.id};self.libraryVisible.removeAll{$0.id==item.id};self.renderLibraryList();self.reloadLibrary();self.finishMeetingDeletion("会议已移入回收站，可随时恢复")
                case .failure(let error):self.finishMeetingDeletion((error as? Failure)?.code.contains("recovery_required")==true ? "部分文件已移入回收站，请使用恢复会议":"删除失败；会议文件已保留，可重试")
                }
            }
        }
    }
    func finishMeetingDeletion(_ message:String){meetingDeletionBusy=false;deletingCacheID=nil;diagnostic.stringValue=message;updateWorkspacePresentation();displayedDocument.diagnostic.stringValue=message;displayedDocument.diagnostic.isHidden=false;completeApplicationTerminationIfReady()}
    @objc func showDeletedMeetings(){
        guard !meetingDeletionBusy,libraryManagement?.busy != true else{return};meetingDeletionBusy=true;updateWorkspacePresentation();let store=meetingDeletionStore
        DispatchQueue.global(qos:.userInitiated).async {let result=Result{try store.receipts().map{MeetingRecycleBinRow.read($0,store:store)}};DispatchQueue.main.async{
            self.meetingDeletionBusy=false;self.updateWorkspacePresentation()
            guard case .success(let rows)=result else{self.finishMeetingDeletion("无法读取回收站，请重试");return}
            if let selection=self.restoreSelectionOverride {if let receipt=selection(rows.map(\.receipt)) {self.restoreDeletedMeeting(receipt)};return}
            MeetingRecycleBinController.forOwner(self).present(rows)
        }}
    }
    func restoreDeletedMeeting(_ receipt:MeetingDeletionReceipt) {
        restoreDeletedMeetings([receipt]){_ in}
    }
    func restoreDeletedMeetings(_ receipts:[MeetingDeletionReceipt],completion:@escaping(MeetingRestoreResult)->Void) {
        guard !meetingDeletionBusy,libraryManagement?.busy != true,!receipts.isEmpty else{return}
        var seen=Set<String>();let selected=receipts.filter{seen.insert($0.id).inserted}
        let blocked=Set(selected.filter{$0.cacheID==currentCacheID && recordingBusy}.map(\.id))
        meetingDeletionBusy=true;updateWorkspacePresentation();let store=meetingDeletionStore,publisher=contextPublisher
        cacheWriteQueue.async {
            var result=MeetingRestoreResult()
            for receipt in selected {
                if blocked.contains(receipt.id) {result.failures[receipt.id]="本场仍在使用，不能恢复覆盖";continue}
                do {try store.restore(receipt,afterMove:{try publisher?.restoreSession($0)});result.restored.insert(receipt.id)}
                catch {result.failures[receipt.id]=(error as? Failure)?.code=="meeting_restore_collision" ? "原位置已有同一会议，未覆盖任何文件":"恢复失败；回收站原文件保留，可重试"}
            }
            DispatchQueue.main.async {
                if !result.restored.isEmpty {self.reloadLibrary()}
                let message=result.failures.isEmpty ? "已恢复\(result.restored.count)场会议及录音、原文":result.restored.isEmpty && result.failures.count==1 ? result.failures.values.first!:"已恢复\(result.restored.count)场，\(result.failures.count)场未恢复；原文件保留，可重试"
                self.finishMeetingDeletion(message);completion(result)
            }
        }
    }
}

struct MeetingRestoreResult {
    var restored=Set<String>()
    var failures:[String:String]=[:]
}

struct MeetingRecycleBinRow {
    let receipt:MeetingDeletionReceipt
    var recordingDate:Date?
    var duration:Double?
    var details:String
    static func read(_ receipt:MeetingDeletionReceipt,store:MeetingDeletionStore)->MeetingRecycleBinRow {
        var row=MeetingRecycleBinRow(receipt:receipt,details:"录音、转写和会议资料")
        do {
            let payload=try store.folder(receipt).appendingPathComponent("cache")
            let folder=FileManager.default.fileExists(atPath:payload.path) ? payload:store.cacheRoot.appendingPathComponent(receipt.cacheID)
            guard folder.standardizedFileURL==folder.resolvingSymlinksInPath().standardizedFileURL else{throw Failure(code:"recycle_row_scope")}
            func object(_ file:URL)throws->[String:Any] {
                let values=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                guard values.isRegularFile==true,values.isSymbolicLink != true,(values.fileSize ?? Int.max)<=1024*1024 else{throw Failure(code:"recycle_row_unreadable")}
                guard let value=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any] else{throw Failure(code:"recycle_row_unreadable")};return value
            }
            let metadata=try object(folder.appendingPathComponent("meeting.json"))
            guard metadata["session"] as? String==receipt.session else{throw Failure(code:"recycle_row_session")}
            row.recordingDate=MeetingAbsoluteTime(metadata["absolute_clock"])?.date(0)
            var duration:Double?
            for track in try meetingAudioTracks(in:folder) {
                let value=try object(folder.appendingPathComponent(track+"-manifest.json"))
                guard value["track"] as? String==track,let bytes=value["written_bytes"] as? Int,bytes>=0,bytes<=512*1024*1024 else{throw Failure(code:"recycle_row_unreadable")}
                let origin=metadata["capture_origin_uptime"] as? Double,trackOrigin=value["origin_uptime"] as? Double
                let offset=(origin != nil && trackOrigin != nil && origin!.isFinite && trackOrigin!.isFinite && trackOrigin!>=origin! && trackOrigin!-origin!<=7200) ? trackOrigin!-origin!:0
                duration=max(duration ?? 0,Double(bytes)/32000+offset)
            }
            row.duration=duration
            if receipt.state != "trashed" {row.details="上次操作未完成；可尝试恢复"}
        } catch {row.details="详细资料暂时无法读取；原文件保留"}
        return row
    }
    func dateText(_ date:Date?)->String {
        guard let date else{return "未记录"};let formatter=DateFormatter();formatter.dateFormat="MM-dd HH:mm";return formatter.string(from:date)
    }
    var durationText:String {guard let duration,duration.isFinite else{return "未记录"};let seconds=max(0,Int(duration));return seconds>=3600 ? String(format:"%02d:%02d:%02d",seconds/3600,(seconds/60)%60,seconds%60):String(format:"%02d:%02d",seconds/60,seconds%60)}
}

final class MeetingRecycleBinController:NSWindowController,NSTableViewDataSource,NSTableViewDelegate,NSWindowDelegate {
    private static let controllers=NSMapTable<Delegate,MeetingRecycleBinController>.weakToStrongObjects()
    static func forOwner(_ owner:Delegate)->MeetingRecycleBinController {
        if let controller=controllers.object(forKey:owner){return controller}
        let controller=MeetingRecycleBinController(owner:owner);controllers.setObject(controller,forKey:owner);return controller
    }
    static func closeIfVisible(_ foreground:NSWindow?)->Bool {
        guard let foreground else{return false}
        for case let controller as MeetingRecycleBinController in controllers.objectEnumerator()?.allObjects ?? [] where controller.window===foreground {
            if controller.restoring {controller.status.stringValue="正在恢复，完成后可关闭"}else{controller.close()};return true
        }
        return false
    }
    private weak var meetingOwner:Delegate?
    let table=NSTableView(),restoreButton=NSButton(),selectAllButton=NSButton(),status=NSTextField(wrappingLabelWithString:""),summary=NSTextField(labelWithString:"")
    private(set) var rows:[MeetingRecycleBinRow]=[]
    private(set) var selectedIDs=Set<String>()
    private(set) var restoring=false
    private var failures:[String:String]=[:]
    private var synchronizingSelection=false
    var confirmationOverride:(([MeetingRecycleBinRow])->Bool)?
    init(owner:Delegate) {
        self.meetingOwner=owner
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:840,height:480),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="回收站";window.minSize=NSSize(width:760,height:380);window.isReleasedWhenClosed=false
        super.init(window:window);window.delegate=self
        let root=NSStackView();root.orientation = .vertical;root.alignment = .leading;root.spacing=12;root.edgeInsets=NSEdgeInsets(top:18,left:18,bottom:18,right:18);root.translatesAutoresizingMaskIntoConstraints=false
        window.contentView!.addSubview(root)
        let note=NSTextField(wrappingLabelWithString:"勾选需要恢复的会议。录音、转写和会议资料会一起找回。")
        note.textColor = .secondaryLabelColor;note.font = .systemFont(ofSize:12)
        selectAllButton.title="全选";selectAllButton.target=self;selectAllButton.action=#selector(toggleAll);selectAllButton.bezelStyle = .rounded
        let spacer=NSView();spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let header=NSStackView(views:[summary,spacer,selectAllButton]);header.orientation = .horizontal
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder;scroll.documentView=table
        table.delegate=self;table.dataSource=self;table.rowHeight=56;table.allowsMultipleSelection=true;table.allowsEmptySelection=true;table.usesAlternatingRowBackgroundColors=true
        for (id,title,width) in [("check","",34.0),("title","会议",310.0),("recorded","录音时间",140.0),("duration","时长",70.0),("deleted","删除时间",140.0)] {
            let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id));column.title=title;column.width=width;column.minWidth=id=="title" ? 220:width;table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        restoreButton.title="恢复所选（0项）";restoreButton.target=self;restoreButton.action=#selector(restoreSelected);restoreButton.bezelStyle = .rounded;restoreButton.keyEquivalent="\r"
        let close=NSButton(title:"关闭",target:self,action:#selector(closeWindow));close.bezelStyle = .rounded;close.keyEquivalent="\u{1b}"
        let footer=NSStackView(views:[status,close,restoreButton]);footer.orientation = .horizontal;footer.alignment = .centerY;footer.spacing=12
        status.font = .systemFont(ofSize:12);status.textColor = .secondaryLabelColor;status.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        for view in [note,header,scroll,footer]{view.translatesAutoresizingMaskIntoConstraints=false;root.addArrangedSubview(view);view.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-36).isActive=true}
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:180)])
        updateControls()
    }
    required init?(coder:NSCoder){fatalError("init(coder:) unavailable")}
    func present(_ rows:[MeetingRecycleBinRow]) {
        guard !restoring else{window?.makeKeyAndOrderFront(nil);return}
        load(rows);window?.center();showWindow(nil);window?.makeKeyAndOrderFront(nil)
    }
    func load(_ rows:[MeetingRecycleBinRow]) {
        self.rows=rows;selectedIDs.formIntersection(Set(rows.map{$0.receipt.id}));failures=[:];refreshSelection()
        status.stringValue=rows.isEmpty ? "回收站为空":"勾选后可一次恢复多场会议";updateControls()
    }
    func setSelected(_ id:String,selected:Bool) {
        guard !restoring,rows.contains(where:{$0.receipt.id==id}) else{return}
        if selected {selectedIDs.insert(id)}else{selectedIDs.remove(id)};refreshSelection();updateControls()
    }
    private func refreshSelection() {
        synchronizingSelection=true;table.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter{selectedIDs.contains(rows[$0].receipt.id)}),byExtendingSelection:false)
        synchronizingSelection=false
    }
    func tableViewSelectionDidChange(_ notification:Notification) {
        guard !synchronizingSelection,!restoring else{return}
        selectedIDs=Set(table.selectedRowIndexes.compactMap{rows.indices.contains($0) ? rows[$0].receipt.id:nil})
        refreshSelection();updateControls()
    }
    private func updateControls() {
        summary.stringValue="共\(rows.count)场会议 · 已选\(selectedIDs.count)场"
        restoreButton.title="恢复所选（\(selectedIDs.count)项）";restoreButton.isEnabled = !restoring && !selectedIDs.isEmpty
        selectAllButton.title=selectedIDs.count==rows.count && !rows.isEmpty ? "取消全选":"全选";selectAllButton.isEnabled = !restoring && !rows.isEmpty
        table.isEnabled = !restoring
    }
    func numberOfRows(in tableView:NSTableView)->Int{rows.count}
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView? {
        guard rows.indices.contains(row),let column else{return nil};let item=rows[row],id=item.receipt.id
        if column.identifier.rawValue=="check" {
            let button=NSButton(checkboxWithTitle:"",target:self,action:#selector(toggleRow(_:)));button.identifier=NSUserInterfaceItemIdentifier(id);button.state=selectedIDs.contains(id) ? .on:.off;button.isEnabled = !restoring;button.setAccessibilityLabel("选择「"+item.receipt.title+"」");return button
        }
        let text:String
        switch column.identifier.rawValue {
        case "title":text=item.receipt.title+"\n"+(failures[id] ?? item.details)
        case "recorded":text=item.dateText(item.recordingDate)
        case "duration":text=item.durationText
        default:text=item.dateText(Date(timeIntervalSince1970:item.receipt.createdAt))
        }
        let label=NSTextField(wrappingLabelWithString:text);label.maximumNumberOfLines=2;label.font = .systemFont(ofSize:12);label.toolTip=text;label.setAccessibilityLabel(text)
        if failures[id] != nil && column.identifier.rawValue=="title" {label.textColor = .systemRed}
        return label
    }
    @objc private func toggleRow(_ sender:NSButton){guard let id=sender.identifier?.rawValue else{return};setSelected(id,selected:sender.state == .on)}
    @objc func toggleAll(){guard !restoring else{return};selectedIDs=selectedIDs.count==rows.count ? []:Set(rows.map{$0.receipt.id});refreshSelection();updateControls()}
    @objc func restoreSelected() {
        guard !restoring,let owner=meetingOwner,!owner.meetingDeletionBusy,owner.libraryManagement?.busy != true else{return}
        let selected=rows.filter{selectedIDs.contains($0.receipt.id)};guard !selected.isEmpty else{return}
        let confirmed:Bool
        if let confirmationOverride {confirmed=confirmationOverride(selected)}else {
            let alert=NSAlert();alert.messageText="恢复所选的\(selected.count)场会议？";alert.informativeText="以下会议的录音、转写和资料会一起恢复。"
            let list=NSTextField(wrappingLabelWithString:selected.map{"· "+$0.receipt.title+"　"+$0.dateText($0.recordingDate)}.joined(separator:"\n"));list.frame=NSRect(x:0,y:0,width:480,height:max(44,Double(selected.count)*36));list.font = .systemFont(ofSize:13)
            let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:500,height:min(220,list.frame.height)));scroll.hasVerticalScroller=true;scroll.documentView=list;alert.accessoryView=scroll
            alert.addButton(withTitle:"恢复\(selected.count)场会议");alert.addButton(withTitle:"取消");confirmed=alert.runModal() == .alertFirstButtonReturn
        }
        guard confirmed else{return}
        guard !owner.meetingDeletionBusy,owner.libraryManagement?.busy != true else{status.stringValue="会议资料正在处理，请稍后重试";return}
        restoring=true;status.stringValue="正在恢复\(selected.count)场会议…";updateControls()
        owner.restoreDeletedMeetings(selected.map(\.receipt)){[weak self] result in
            guard let self else{return};self.restoring=false;self.rows.removeAll{result.restored.contains($0.receipt.id)};self.selectedIDs.subtract(result.restored);self.failures=result.failures;self.refreshSelection()
            self.status.stringValue=result.failures.isEmpty ? "已恢复\(result.restored.count)场会议": "已恢复\(result.restored.count)场，\(result.failures.count)场未恢复；请查看列表中的原因后重试";self.updateControls()
        }
    }
    @objc private func closeWindow(){guard !restoring else{return};close()}
    func windowShouldClose(_ sender:NSWindow)->Bool {if restoring {status.stringValue="正在恢复，完成后可关闭"};return !restoring}
}

@MainActor func meetingRecycleBinChecks(directory:URL) async throws->[String] {
    guard Credential.offline,directory.path.contains("/.runtime/"),directory.standardizedFileURL==directory.resolvingSymlinksInPath().standardizedFileURL else{throw Failure(code:"recycle_checks_scope")}
    let fm=FileManager.default,base=directory.appendingPathComponent(UUID().uuidString),cache=base.appendingPathComponent("SessionCache")
    try fm.createDirectory(at:cache,withIntermediateDirectories:true)
    let store=MeetingDeletionStore(cacheRoot:cache,binRoot:base.appendingPathComponent("RecycleBin"),exportsRoot:base.appendingPathComponent("MeetingExports"))
    var checks:[String]=[]
    func check(_ value:Bool,_ name:String)throws {guard value else{throw Failure(code:name)};checks.append(name)}
    func wait(_ condition:()->Bool)async throws {let until=Date().addingTimeInterval(8);while !condition(),Date()<until {try await Task.sleep(nanoseconds:10_000_000)};guard condition() else{throw Failure(code:"recycle_checks_timeout")}}
    func hashes(_ folder:URL)throws->[String:Data] {var values:[String:Data]=[:];for file in try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) {values[file.lastPathComponent]=try Data(contentsOf:file)};return values}
    func fixture(_ title:String,_ unix:Double)throws->CachedMeeting {
        let id=UUID().uuidString,session=UUID().uuidString,folder=cache.appendingPathComponent(id)
        let journal=try RecordingJournal(directory:folder,track:"mic",freeSpace:{1_000_000_000})
        for index in 0..<5 {try journal.enqueue(Data(repeating:0x31,count:32000),at:100+Double(index))};journal.finish();journal.wait()
        let clock:[String:Any]=["schema":1,"basis":"capture_clock","time_zone":"Asia/Shanghai","anchors":[["relative_start":0.0,"unix_time":unix]]]
        try JSONSerialization.data(withJSONObject:["session":session,"cache_id":id,"bundle":"*microphone*","capture_origin_uptime":100.0,"absolute_clock":clock]).write(to:folder.appendingPathComponent("meeting.json"))
        try MeetingLibraryInfo.saveTitle(title,in:folder);return try cachedMeetings(in:cache).first{$0.id==id}!
    }
    let first=try fixture("客户投放｜青浦奥莱选点与广佛效果验证",1791492000),second=try fixture("闲鱼用增｜采购边界与四周试投",1791495600),third=try fixture("项目沟通｜下一周安排",1791499200)
    let firstBytes=try hashes(first.directory),secondBytes=try hashes(second.directory),thirdBytes=try hashes(third.directory)
    let a=try store.trash(first),b=try store.trash(second),c=try store.trash(third)
    let rows=try store.receipts().map{MeetingRecycleBinRow.read($0,store:store)}
    try check(rows.count==3 && rows.allSatisfy{$0.recordingDate != nil && $0.duration != nil && $0.durationText=="00:05"},"recycle_list_reads_real_capture_time_and_duration_without_audio_playback")
    let owner=Delegate();owner.previewRenderOnly=true;owner.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));owner.recoveryRootOverride=cache;owner.deletionStoreOverride=store
    let controller=MeetingRecycleBinController.forOwner(owner);controller.load(rows)
    try check(controller.numberOfRows(in:controller.table)==3 && controller.table.tableColumns.map{$0.title}==["","会议","录音时间","时长","删除时间"] && !controller.restoreButton.isEnabled,"recycle_list_shows_all_meetings_and_dates_with_no_implicit_selection")
    controller.toggleAll();try check(controller.selectedIDs.count==3 && controller.restoreButton.title=="恢复所选（3项）","recycle_select_all_counts_multiple_meetings")
    controller.toggleAll();controller.setSelected(a.id,selected:true);controller.setSelected(b.id,selected:true)
    try check(controller.selectedIDs==Set([a.id,b.id]) && controller.restoreButton.title=="恢复所选（2项）","recycle_checkboxes_select_independent_meetings")
    controller.table.selectRowIndexes(IndexSet(integer:rows.firstIndex{$0.receipt.id==a.id}!),byExtendingSelection:false)
    controller.table.selectRowIndexes(IndexSet(integer:rows.firstIndex{$0.receipt.id==b.id}!),byExtendingSelection:true)
    try check(controller.selectedIDs==Set([a.id,b.id]) && controller.restoreButton.title=="恢复所选（2项）","recycle_row_selection_and_checkboxes_share_one_restore_scope")
    controller.window?.appearance=NSAppearance(named:.aqua)
    if let view=controller.window?.contentView {view.wantsLayer=true;view.layer?.backgroundColor=NSColor.windowBackgroundColor.cgColor;view.layoutSubtreeIfNeeded();if let image=view.bitmapImageRepForCachingDisplay(in:view.bounds) {view.cacheDisplay(in:view.bounds,to:image);try fm.createDirectory(at:directory,withIntermediateDirectories:true);try image.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("recycle-list-multiselect.png"))}}
    controller.confirmationOverride={_ in false};controller.restoreSelected()
    try check(!controller.restoring && !owner.meetingDeletionBusy && controller.selectedIDs.count==2 && (try hashes(store.folder(a).appendingPathComponent("cache")))==firstBytes,"recycle_cancel_preserves_selection_and_all_deleted_files")
    try fm.createDirectory(at:first.directory,withIntermediateDirectories:true);try Data("unrelated destination".utf8).write(to:first.directory.appendingPathComponent("collision.txt"))
    controller.confirmationOverride={_ in true};controller.restoreSelected()
    try check(controller.restoring && owner.meetingDeletionBusy && !controller.restoreButton.isEnabled,"recycle_restore_blocks_duplicate_actions_until_batch_finishes")
    try await wait{!controller.restoring && !owner.meetingDeletionBusy}
    try check((try hashes(second.directory))==secondBytes && (try hashes(store.folder(a).appendingPathComponent("cache")))==firstBytes && (try hashes(store.folder(c).appendingPathComponent("cache")))==thirdBytes,"recycle_batch_restores_valid_meeting_and_preserves_failed_and_unselected_files")
    try check(controller.rows.count==2 && controller.selectedIDs==Set([a.id]) && controller.restoreButton.isEnabled && controller.status.stringValue.contains("1场未恢复"),"recycle_partial_failure_keeps_failed_selection_visible_and_retryable")
    try fm.removeItem(at:first.directory);controller.restoreSelected();try await wait{!controller.restoring}
    try check((try hashes(first.directory))==firstBytes && controller.rows.count==1 && controller.rows[0].receipt.id==c.id && controller.selectedIDs.isEmpty,"recycle_retry_restores_only_failed_meeting_without_repeating_success")
    var result:MeetingRestoreResult?
    owner.restoreDeletedMeetings([c,c]){result=$0};try await wait{result != nil}
    try check(result!.restored==Set([c.id]) && result!.failures.isEmpty && (try hashes(third.directory))==thirdBytes,"recycle_batch_deduplicates_receipts_and_preserves_original_bytes")
    controller.load([]);try check(controller.status.stringValue=="回收站为空" && !controller.restoreButton.isEnabled && !controller.selectAllButton.isEnabled,"empty_recycle_bin_has_clear_state_without_restore_action")
    owner.phase.phase = .recording;owner.closeWindowTarget(controller.window)
    try check(owner.phase.phase == .recording && !owner.quitting,"closing_recycle_bin_does_not_quit_or_stop_recording_owner")
    owner.window.orderOut(nil);controller.close();return checks
}
