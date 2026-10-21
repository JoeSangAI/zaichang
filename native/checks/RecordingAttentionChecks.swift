import Foundation

func recordingAttentionChecks()throws->[String] {
    var state=RecordingAttentionState()
    _=state.tick(recording:true,now:0)
    var reminders=0
    for second in 1...600 {
        let action=state.tick(recording:true,now:Double(second))
        if action == .showReminder {reminders+=1}
    }
    guard reminders==1 else{throw Failure(code:"attention_one_reminder_at_10m")}
    for second in 601...659 {_=state.tick(recording:true,now:Double(second))}
    guard state.tick(recording:true,now:660) == .autoPause else{throw Failure(code:"attention_auto_pause_at_11m")}
    guard state.tick(recording:true,now:661) == .none else{throw Failure(code:"attention_pause_requested_once")}

    state.reset(now:0)
    for second in 1...600 {_=state.tick(recording:true,now:Double(second))}
    for second in 601...630 {_=state.tick(recording:true,now:Double(second))}
    guard state.tick(recording:true,now:631) == .none else{throw Failure(code:"attention_resume_no_early_pause")}
    state.reset(now:631)
    for second in 632...1_230 {_=state.tick(recording:true,now:Double(second))}
    guard state.tick(recording:true,now:1_231) == .showReminder else{throw Failure(code:"attention_resume_starts_fresh_window")}

    guard state.speech(now:1_240) == .dismissReminder else{throw Failure(code:"attention_speech_dismisses_reminder")}
    for second in 1_241...1_839 {_=state.tick(recording:true,now:Double(second))}
    guard state.tick(recording:true,now:1_840) == .showReminder else{throw Failure(code:"attention_speech_restarts_quiet_window")}

    guard state.continueRecording(now:1_850) == .dismissReminder else{throw Failure(code:"attention_keep_going_dismisses")}
    for second in 1_851...2_449 {_=state.tick(recording:true,now:Double(second))}
    guard state.tick(recording:true,now:2_450) == .showReminder else{throw Failure(code:"attention_keep_going_resets_window")}
    state.cancel()
    guard state.tick(recording:true,now:3_000) == .none else{throw Failure(code:"attention_cancel_disarms_timer")}

    state.reset(now:0)
    for second in 1...600 {_=state.tick(recording:true,now:Double(second))}
    guard state.tick(recording:true,now:604) == .dismissReminder else{throw Failure(code:"attention_stall_restarts_quiet_window")}
    for second in 605...1_203 {_=state.tick(recording:true,now:Double(second))}
    guard state.tick(recording:true,now:1_204) == .showReminder else{throw Failure(code:"attention_stall_restarts_quiet_window")}
    guard state.tick(recording:false,now:1_205) == .dismissReminder,
          state.tick(recording:true,now:1_206) == .none else{throw Failure(code:"attention_pause_clears_reminder")}
    return ["ten_minute_quiet_reminder","one_minute_pause_deadline","pause_requested_once","resume_resets_quiet_window","speech_cancels_reminder","continue_resets_quiet_window","cancel_disarms_timer","stall_restarts_quiet_window","pause_clears_reminder"]
}
