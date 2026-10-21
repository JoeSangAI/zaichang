import AppKit

@MainActor func coarseProgressChecks(directory:URL) throws->[String] {
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    var checks:[String]=[]
    func check(_ value:Bool,_ label:String)throws{guard value else{throw Failure(code:label)};checks.append(label)}
    func snapshot(_ view:CoarseProcessingStatusView,_ name:String)throws {
        let host=NSView(frame:NSRect(x:0,y:0,width:620,height:76))
        view.frame=NSRect(x:16,y:26,width:588,height:30);host.addSubview(view);host.layoutSubtreeIfNeeded()
        guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else{throw Failure(code:"coarse_progress_bitmap_unavailable")}
        host.cacheDisplay(in:host.bounds,to:bitmap)
        guard let data=bitmap.representation(using:.png,properties:[:]) else{throw Failure(code:"coarse_progress_png_unavailable")}
        try data.write(to:directory.appendingPathComponent(name+".png"))
    }

    let view=CoarseProcessingStatusView()
    view.show(CoarseProcessingProgress(runID:"fixture",stage:"preparing",completed:0,total:0),summary:nil,isRecording:true,fallbackRunning:false)
    try check(!view.isHidden && view.statusLabel.stringValue.contains("录音可继续") && view.progressIndicator.isIndeterminate,
              "preparing_uses_spinner_and_explains_recording_can_continue")
    try snapshot(view,"coarse-preparing-while-recording")

    view.show(CoarseProcessingProgress(runID:"fixture",stage:"audio",completed:4,total:10),summary:nil,isRecording:true,fallbackRunning:false)
    try check(!view.progressIndicator.isHidden && !view.progressIndicator.isIndeterminate && view.progressIndicator.doubleValue==4 && view.progressIndicator.maxValue==10,
              "reliable_stage_counts_use_a_determinate_system_progress_bar")
    try snapshot(view,"coarse-audio-progress-while-recording")

    view.show(CoarseProcessingProgress(runID:"fixture",stage:"speakers",completed:2,total:0),summary:nil,isRecording:false,fallbackRunning:false)
    try check(view.progressIndicator.isIndeterminate && view.statusLabel.stringValue.contains("发言人"),
              "unknown_speaker_progress_uses_spinner_without_fake_percentage")

    view.show(CoarseProcessingProgress(runID:"fixture",stage:"complete",completed:10,total:10),summary:nil,isRecording:false,fallbackRunning:false)
    try check(!view.isHidden && view.progressIndicator.isHidden && view.statusLabel.stringValue.contains("可标记发言人") && !view.statusLabel.stringValue.contains("待确认"),
              "completed_summary_leads_to_simple_speaker_naming")
    try snapshot(view,"coarse-complete-ready-to-name")

    view.show(CoarseProcessingProgress(runID:"fixture",stage:"failed",completed:0,total:0),summary:"这一段整理未完成，可重试",isRecording:false,fallbackRunning:false)
    try check(view.statusLabel.stringValue=="这一段整理未完成，可重试" && !view.isHidden,
              "failure_is_visible_without_turning_every_unassigned_turn_into_a_task")
    try snapshot(view,"coarse-failed-retry")

    view.show(nil,summary:nil,isRecording:false,fallbackRunning:false)
    try check(view.isHidden,"no_work_hides_the_coarse_status_row")
    return checks
}
