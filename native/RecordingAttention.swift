import AppKit

enum RecordingAttentionAction:Equatable {case none,showReminder,dismissReminder,autoPause}

struct RecordingAttentionState {
    static let quietSeconds:TimeInterval=600
    static let reminderSeconds:TimeInterval=60
    static let maximumTickGap:TimeInterval=3
    private(set) var quietSince:TimeInterval?
    private(set) var reminderSince:TimeInterval?
    private(set) var lastTick:TimeInterval?
    private(set) var pauseRequested=false

    mutating func reset(now:TimeInterval) {
        quietSince=now;reminderSince=nil;lastTick=now;pauseRequested=false
    }
    mutating func speech(now:TimeInterval)->RecordingAttentionAction {
        let hadReminder=reminderSince != nil
        reset(now:now)
        return hadReminder ? .dismissReminder:.none
    }
    mutating func continueRecording(now:TimeInterval)->RecordingAttentionAction {
        speech(now:now)
    }
    mutating func cancel() {
        quietSince=nil;reminderSince=nil;lastTick=nil;pauseRequested=false
    }
    mutating func tick(recording:Bool,now:TimeInterval)->RecordingAttentionAction {
        guard recording else {
            let hadReminder=reminderSince != nil
            cancel()
            return hadReminder ? .dismissReminder:.none
        }
        guard now.isFinite else{return .none}
        guard let previous=lastTick,let quietStart=quietSince else {
            reset(now:now);return .none
        }
        // Long gaps mean the app was asleep or its main loop stalled. Restart
        // the quiet clock so a stale timer cannot pause a meeting on wake.
        if now<previous || now-previous>Self.maximumTickGap {
            let hadReminder=reminderSince != nil
            reset(now:now)
            return hadReminder ? .dismissReminder:.none
        }
        lastTick=now
        guard !pauseRequested else{return .none}
        if let reminded=reminderSince {
            guard now-reminded>=Self.reminderSeconds else{return .none}
            pauseRequested=true
            reminderSince=nil
            return .autoPause
        }
        guard now-quietStart>=Self.quietSeconds else{return .none}
        reminderSince=now
        return .showReminder
    }
    mutating func requestPause() {
        reminderSince=nil;pauseRequested=true
    }
}

final class RecordingAttention {
    private weak var ownerDelegate:Delegate?
    private var timer:Timer?
    private var alert:NSAlert?
    private var alertToken:UUID?
    private var state=RecordingAttentionState()
    private var observedSession:String?
    private var textBySegment:[String:String]=[:]
    private var segmentOrder:[String]=[]
    private var audioAboveThresholdSince:TimeInterval?
    private var lastAudioEventAt:TimeInterval?
    private var lastAudioReset=0.0

    init(owner:Delegate) {ownerDelegate=owner}

    func sync() {
        precondition(Thread.isMainThread)
        guard let owner=ownerDelegate,owner.phase.phase == .recording else {
            timer?.invalidate();timer=nil
            apply(state.tick(recording:false,now:ProcessInfo.processInfo.systemUptime))
            resetObservations()
            return
        }
        if timer==nil {
            let timer=Timer(timeInterval:1,repeats:true){[weak self] _ in
                Task{@MainActor in self?.tick()}
            }
            self.timer=timer;RunLoop.main.add(timer,forMode:.common)
        }
        tick()
    }

    func observe(_ event:[String:Any]) {
        precondition(Thread.isMainThread)
        guard let owner=ownerDelegate else{return}
        let type=event["type"] as? String ?? ""
        if let session=event["session"] as? String {
            if let old=observedSession,old != session {resetObservations();apply(state.tick(recording:false,now:ProcessInfo.processInfo.systemUptime))}
            observedSession=session
            guard owner.activeSession==nil || owner.activeSession==session || type=="started" else{return}
        }
        let now=ProcessInfo.processInfo.systemUptime
        if type=="started" || type=="recording_resumed" {
            state.reset(now:now);resetAudioCandidate();cancelAlert();sync();return
        }
        if type=="recording_paused" || type=="stopped" || type=="error" {
            state.cancel();resetObservations();cancelAlert();sync();return
        }
        guard owner.phase.phase == .recording else{return}
        if type=="segment",let id=event["segment_id"] as? String,
           let text=event["text"] as? String,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            let prior=textBySegment[id]
            textBySegment[id]=text
            if prior==nil || prior != text {
                if prior==nil {segmentOrder.append(id)}
                if segmentOrder.count>512,let removed=segmentOrder.first {
                    segmentOrder.removeFirst();textBySegment.removeValue(forKey:removed)
                }
                apply(state.speech(now:now));cancelAlert()
            }
        } else if type=="audio_levels",owner.sessionLocalOnly || owner.asrNetworkStates.values.contains(where:{["pending","waiting","catching"].contains($0)}) {
            observeAudioActivity(event,now:now)
        }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        timer?.invalidate();timer=nil;state.cancel();cancelAlert();resetObservations()
    }

    private func tick() {
        guard let owner=ownerDelegate else{cancel();return}
        apply(state.tick(recording:owner.phase.phase == .recording,now:ProcessInfo.processInfo.systemUptime))
    }

    private func apply(_ action:RecordingAttentionAction) {
        switch action {
        case .none:break
        case .showReminder:showReminder()
        case .dismissReminder:cancelAlert()
        case .autoPause:
            cancelAlert()
            guard let owner=ownerDelegate,owner.phase.phase == .recording else{return}
            owner.sendRecordingControl("pause")
        }
    }

    private func showReminder() {
        guard alert==nil,let owner=ownerDelegate,owner.phase.phase == .recording,
              owner.window != nil else{return}
        let alert=NSAlert();alert.alertStyle = .informational
        if !NSApp.isActive {_=NSApp.requestUserAttention(.informationalRequest)}
        alert.messageText="长时间没有检测到讲话"
        alert.informativeText="连续10分钟没有检测到讲话，将在1分钟后自动暂停。已录内容保留。"
        alert.addButton(withTitle:"继续录音")
        alert.addButton(withTitle:"现在暂停")
        let token=UUID();alertToken=token;self.alert=alert
        alert.beginSheetModal(for:owner.window){[weak self] response in
            guard let self=self,self.alertToken==token else{return}
            self.alert=nil;self.alertToken=nil
            if response == .alertFirstButtonReturn {
                _=self.state.continueRecording(now:ProcessInfo.processInfo.systemUptime)
            } else if response == .alertSecondButtonReturn {
                self.state.requestPause();self.ownerDelegate?.sendRecordingControl("pause")
            }
        }
    }

    private func cancelAlert() {
        guard let alert=alert else{return}
        alertToken=nil;self.alert=nil
        if let parent=alert.window.sheetParent {parent.endSheet(alert.window,returnCode:.cancel)}
    }

    private func observeAudioActivity(_ event:[String:Any],now:TimeInterval) {
        guard let levels=event["levels"] as? [String:[String:Any]] else{return}
        if let previous=lastAudioEventAt,now-previous>1.0 {audioAboveThresholdSince=nil}
        lastAudioEventAt=now
        let active=levels.values.contains { lane in
            let rms=(lane["signal_rms"] as? NSNumber)?.doubleValue ?? 0
            let peak=(lane["signal_peak"] as? NSNumber)?.doubleValue ?? 0
            let age=(lane["last_packet_age_seconds"] as? NSNumber)?.doubleValue ?? 0
            return age<0.7 && rms.isFinite && peak.isFinite && (rms>=0.012 || peak>=0.08)
        }
        guard active else{audioAboveThresholdSince=nil;return}
        if audioAboveThresholdSince==nil {audioAboveThresholdSince=now;return}
        guard let since=audioAboveThresholdSince,now-since>=1.5,now-lastAudioReset>=4 else{return}
        lastAudioReset=now;apply(state.speech(now:now));cancelAlert()
    }

    private func resetAudioCandidate() {audioAboveThresholdSince=nil;lastAudioEventAt=nil;lastAudioReset=0}
    private func resetObservations() {
        observedSession=nil;textBySegment.removeAll(keepingCapacity:true);segmentOrder.removeAll(keepingCapacity:true);resetAudioCandidate()
    }
}
