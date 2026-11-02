import Foundation
import AppKit

// Offline measure of how smooth the window stays: replays a copied meeting's saved
// transcript events through the real receive/render path while a heartbeat records
// how long the main thread went without running. Reads a copy under .runtime only.
@MainActor func transcriptReplayProfile(root:URL,cacheID:String,speed:Double) async throws->[String:Any] {
    guard Credential.offline,root.path.contains("/.runtime/") else{throw Failure(code:"replay_profile_scope")}
    _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
    let folder=root.appendingPathComponent(cacheID)
    let metadata=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("meeting.json"))) as! [String:Any]
    guard let session=metadata["session"] as? String else{throw Failure(code:"replay_profile_session")}
    var events:[[String:Any]]=[]
    for file in try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) where file.lastPathComponent.hasSuffix("-transcript.jsonl") {
        for line in try Data(contentsOf:file).split(separator:10) {
            if let event=(try? JSONSerialization.jsonObject(with:Data(line))) as? [String:Any],event["type"] as? String=="segment" {events.append(event)}
        }
    }
    events.sort{($0["received_at"] as? Double ?? 0)<($1["received_at"] as? Double ?? 0)}
    guard !events.isEmpty else{throw Failure(code:"replay_profile_empty")}

    var beats:[Double]=[],last=ProcessInfo.processInfo.systemUptime
    let lastBeat=UnsafeMutablePointer<Double>.allocate(capacity:1);lastBeat.pointee=last
    let heartbeat=Timer(timeInterval:0.004,repeats:true){_ in
        let now=ProcessInfo.processInfo.systemUptime;beats.append(now-last);last=now;lastBeat.pointee=now
    }
    RunLoop.main.add(heartbeat,forMode:.common)
    // Name what a long stall was doing: sample ourselves from outside the main thread.
    let watchdog=DispatchSource.makeTimerSource(queue:DispatchQueue(label:"replay.watchdog"))
    var sampled=0
    watchdog.schedule(deadline:.now(),repeating:.milliseconds(50))
    watchdog.setEventHandler {
        guard ProcessInfo.processInfo.systemUptime-lastBeat.pointee>0.25,sampled<3 else{return}
        sampled+=1;lastBeat.pointee=ProcessInfo.processInfo.systemUptime
        let proc=Process();proc.executableURL=URL(fileURLWithPath:"/usr/bin/sample")
        proc.arguments=[String(getpid()),"1","10","-file",root.deletingLastPathComponent().appendingPathComponent("stall-\(sampled).sample").path]
        proc.standardOutput=FileHandle.nullDevice;proc.standardError=FileHandle.nullDevice;try? proc.run()
    }
    watchdog.resume()
    func summary()->[String:Any] {
        let sorted=beats.sorted();let total=sorted.reduce(0,+)
        func at(_ p:Double)->Double {sorted.isEmpty ? 0:(sorted[min(sorted.count-1,Int(Double(sorted.count)*p))]*1000).rounded()}
        return ["p50_ms":at(0.5),"p99_ms":at(0.99),"max_ms":(sorted.last ?? 0)*1000,"over_50ms":sorted.filter{$0>0.05}.count,
                "over_200ms":sorted.filter{$0>0.2}.count,"stalled_seconds":sorted.filter{$0>0.05}.reduce(0,+),"seconds":total]
    }
    let view=Delegate();view.previewRenderOnly=true;view.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));view.recoveryRootOverride=root
    view.window.setContentSize(NSSize(width:1280,height:820));view.window.orderFront(nil)
    view.activeSession=session;view.currentCacheID=cacheID;view.phase.phase = .recording;view.previewRenderOnly=false
    var stages:[[String:Any]]=[]
    let chunk=max(1,events.count/6);let origin=events[0]["received_at"] as? Double ?? 0,wall=ProcessInfo.processInfo.systemUptime
    var receiveMax=0.0
    for (index,event) in events.enumerated() {
        let due=wall+((event["received_at"] as? Double ?? origin)-origin)/speed
        let wait=due-ProcessInfo.processInfo.systemUptime
        if wait>0 {try await Task.sleep(nanoseconds:UInt64(wait*1e9))}
        let before=ProcessInfo.processInfo.systemUptime
        view.receive(event)
        receiveMax=max(receiveMax,ProcessInfo.processInfo.systemUptime-before)
        if (index+1)%chunk==0 {
            var stage=summary();stage["events"]=index+1;stage["receive_max_ms"]=(receiveMax*1000).rounded();stages.append(stage);beats=[];receiveMax=0
        }
    }
    let settle=Date().addingTimeInterval(20)
    while (view.fullTranscriptRefreshPending || view.dirtyTranscriptQueueIndex<view.dirtyTranscriptQueue.count),Date()<settle {try await Task.sleep(nanoseconds:20_000_000)}
    view.previewRenderOnly=true;view.phase.phase = .stopped;view.window.orderOut(nil)
    // Opening the same meeting from the library, the other path people feel.
    beats=[];last=ProcessInfo.processInfo.systemUptime
    let owner=Delegate();owner.previewRenderOnly=true;owner.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));owner.recoveryRootOverride=root
    owner.window.setContentSize(NSSize(width:1280,height:820));owner.window.orderFront(nil)
    guard let item=try cachedMeetings(in:root,recoverInterrupted:false).first(where:{$0.id==cacheID}) else{throw Failure(code:"replay_profile_item")}
    beats=[];last=ProcessInfo.processInfo.systemUptime
    sampled=0;let opening=ProcessInfo.processInfo.systemUptime
    owner.openLibraryMeeting(item)
    let until=Date().addingTimeInterval(30)
    while owner.historyReader==nil || owner.historyReader?.fullTranscriptRefreshPending==true || (owner.historyReader?.dirtyTranscriptQueueIndex ?? 0)<(owner.historyReader?.dirtyTranscriptQueue.count ?? 0),Date()<until {try await Task.sleep(nanoseconds:10_000_000)}
    var open=summary();open["open_seconds"]=ProcessInfo.processInfo.systemUptime-opening;open["text_characters"]=owner.historyReader?.output.string.count ?? 0
    heartbeat.invalidate();watchdog.cancel()
    // A reader per opened meeting must not outlive being replaced.
    func footprint()->Double {
        var info=task_vm_info_data_t(),count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let status=withUnsafeMutablePointer(to:&info){$0.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}}
        return status==KERN_SUCCESS ? Double(info.phys_footprint)/1048576:0
    }
    var memory:[Double]=[footprint()]
    weak var firstReader=owner.historyReader
    for _ in 0..<6 {
        let previous=owner.historyReader
        owner.returnToCurrent();try await Task.sleep(nanoseconds:100_000_000)
        owner.openLibraryMeeting(item)
        let deadline=Date().addingTimeInterval(10)
        while owner.historyReader==nil || owner.historyReader===previous || owner.historyReader?.fullTranscriptRefreshPending==true,Date()<deadline {try await Task.sleep(nanoseconds:20_000_000)}
        memory.append(footprint())
    }
    owner.window.orderOut(nil)
    return ["type":"transcript_replay_profile","events":events.count,"speed":speed,"live":stages,"open_saved":open,"open_memory_mb":memory,"first_reader_released":firstReader==nil,"capture":false,"cloud":false,"keychain":false]
}
