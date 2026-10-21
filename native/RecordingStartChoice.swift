import AppKit

enum RecordingStartChoice:String {
    case localOnly="local_only",transcribe="cloud"
    static let preferenceKey="RecordingDefaultMode"
    static let dashboardDefaultKey="RecordingDashboardDefaultApplied"
    static func dashboardDefault(saved:String?,migrated:Bool)->RecordingStartChoice {migrated ? (saved.flatMap(RecordingStartChoice.init(rawValue:)) ?? .transcribe):.transcribe}
}

extension Delegate {
    func configureRecordingStartPreference() {
        guard !Credential.offline,!mock else{return}
        let defaults=UserDefaults.standard
        let mode=RecordingStartChoice.dashboardDefault(saved:defaults.string(forKey:RecordingStartChoice.preferenceKey),migrated:defaults.bool(forKey:RecordingStartChoice.dashboardDefaultKey))
        localOnlyMode=mode == .localOnly;modeUserSelected=true
        defaults.set(mode.rawValue,forKey:RecordingStartChoice.preferenceKey)
        defaults.set(true,forKey:RecordingStartChoice.dashboardDefaultKey)
        recordingModePicker?.selectItem(at:localOnlyMode ? 1:0)
    }
    func persistRecordingStartPreference() {
        guard !Credential.offline,!mock else{return}
        UserDefaults.standard.set((localOnlyMode ? RecordingStartChoice.localOnly:RecordingStartChoice.transcribe).rawValue,
                                  forKey:RecordingStartChoice.preferenceKey)
    }
    func beginRecordingModeFlow() {
        guard child==nil,!preparingModels,!processingAudio,!credentialReadJob.waiting,
              [.idle,.stopped,.failed,.ended].contains(phase.phase) else{return}
        recordingModePicker?.selectItem(at:localOnlyMode ? 1:0)
        // The explicit Start click launches the previously configured mode and
        // scope. OS permissions, credential failures and hard limits still apply.
        if localOnlyMode {beginLocalOnlyFlow()}else{beginCloudSessionFlow()}
    }
}
