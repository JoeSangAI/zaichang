import AppKit

extension Delegate {
    var audioAssetOperationBusy:Bool {(workspaceOwner ?? self).libraryManagement?.audioAssetOperationInFlight==true}
}

extension MeetingLibraryManagement {
    func finishAudioAssetOperation() {
        busy=false;audioAssetOperationInFlight=false;refresh(force:true);owner?.updateUI()
        owner?.completeApplicationTerminationIfReady()
    }
    func requestAudioRename(_ target:CachedMeeting) {
        guard let owner,enabled(.renameAudio,for:target),let info=files?.audioAssets else{message(disabledReason(.renameAudio,for:target));return}
        let value:String?
        if let audioRenameOverride {value=audioRenameOverride(target,info.name)}else{
            let alert=NSAlert();alert.messageText="重命名录音";alert.informativeText="单独修改录音导出的文件名。会议标题和已另存的文件保持不变。"
            let field=NSTextField(string:info.name);field.frame=NSRect(x:0,y:0,width:320,height:26);alert.accessoryView=field;alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消");alert.window.initialFirstResponder=field
            value=alert.runModal() == .alertFirstButtonReturn ? field.stringValue:nil
        }
        guard let value,!owner.meetingDeletionBusy else{return}
        renameAudio(target,to:value)
    }
    func renameAudio(_ target:CachedMeeting,to name:String,completion:((Result<MeetingAudioAssetInfo,Error>)->Void)?=nil) {
        guard let owner,!busy,!owner.meetingDeletionBusy,!(owner.currentCacheID==target.id && owner.recordingBusy) else{message("录音尚未封存或文件正在处理，请稍后重试");completion?(.failure(Failure(code:"audio_asset_busy")));return}
        let store=audioStoreOverride ?? MeetingAudioAssetsStore(cacheRoot:owner.recoveryBase())
        busy=true;audioAssetOperationInFlight=true;refresh();owner.updateUI();message("正在保存录音名称")
        owner.cacheWriteQueue.async { [weak self] in
            let result=Result {try store.rename(target,to:name,active:false)}
            DispatchQueue.main.async {
                guard let self else{return};self.finishAudioAssetOperation()
                switch result {case .success(let info):self.message("录音名称已保存：「"+info.name+"」")
                case .failure(let error):self.message(self.audioAssetFailure(error))}
                completion?(result)
            }
        }
    }
    func exportAudio(_ target:CachedMeeting,completion:((Result<URL,Error>)->Void)?=nil) {
        guard let owner,enabled(.exportAudio,for:target),!owner.recordingBusy else{message(disabledReason(.exportAudio,for:target));completion?(.failure(Failure(code:"audio_asset_busy")));return}
        let store=audioStoreOverride ?? MeetingAudioAssetsStore(cacheRoot:owner.recoveryBase())
        busy=true;audioAssetOperationInFlight=true;refresh();owner.updateUI();message("正在导出录音，原音保留")
        owner.cacheWriteQueue.async { [weak self] in
            let result=Result {try store.export(target,active:false)}
            DispatchQueue.main.async {
                guard let self else{return};self.finishAudioAssetOperation()
                switch result {
                case .success(let folder):
                    let opened=self.revealOverride?(folder) ?? (Credential.offline ? false:NSWorkspace.shared.open(folder))
                    self.message(opened ? "录音已导出，已打开文件夹":"录音已导出；可再次点“导出录音”打开文件夹")
                case .failure(let error):self.message(self.audioAssetFailure(error))
                };completion?(result)
            }
        }
    }
    func audioAssetFailure(_ error:Error)->String {
        let code=(error as? Failure)?.code ?? ""
        if code.contains("collision") {return "已有同名文件，未覆盖；请换一个录音名称"}
        if code.contains("name") || code.contains("title") {return "录音名称无效；请使用1–80个字，去掉路径符号和换行"}
        if code.contains("active") || code.contains("unsealed") {return "录音仍在保存，请稍后重试"}
        if code.contains("retired") {return "原始录音已移至回收区，请先恢复原音再导出"}
        if code.contains("changed") {return "录音文件已变化，未覆盖原文件；请重新选择后重试"}
        if code.contains("recovery_required") {return "录音文件操作未完成；原音保留，请重新选择后重试恢复"}
        return "录音文件操作失败；原音和原名称保留，请重试"
    }
}
