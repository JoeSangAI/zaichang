import AppKit
import AVFoundation
import Security
import Darwin

// Prepared only. No Keychain API is called unless the build is explicitly authorized.
enum Credential {
    static var offline:Bool {(Bundle.main.object(forInfoDictionaryKey:"OfflineOnly") as? Bool ?? false) || (CommandLine.arguments.contains("--speaker-ui-self-test") || CommandLine.arguments.contains("--recovery-ui-self-test") || CommandLine.arguments.contains("--cache-async-self-test") || CommandLine.arguments.contains("--speaker-refinement-self-test"))}
    static var service:String {RuntimeConfiguration.bailianService}
    static func existenceStatus() -> OSStatus {
        if offline {return errSecItemNotFound}
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
            kSecAttrAccount as String:"beijing-asr",kSecMatchLimit as String:kSecMatchLimitOne,
            kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
        return SecItemCopyMatching(q as CFDictionary,nil)
    }
    static func load(allowInteraction:Bool=true) throws -> String? {
        if offline {return nil}
        var q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
            kSecAttrAccount as String:"beijing-asr",kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        if !allowInteraction {q[kSecUseAuthenticationUI as String]=kSecUseAuthenticationUIFail;SecKeychainSetUserInteractionAllowed(false)}
        defer {if !allowInteraction {SecKeychainSetUserInteractionAllowed(true)}}
        var result:CFTypeRef?; let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data=result as? Data else { throw NSError(domain:"keychain",code:Int(status)) }
        return String(data:data,encoding:.utf8)
    }
    static func delete() throws {
        guard !offline else {throw NSError(domain:"offline",code:1)}
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"beijing-asr"]
        let code=SecItemDelete(q as CFDictionary)
        guard code==errSecSuccess || code==errSecItemNotFound else {throw NSError(domain:"keychain-delete",code:Int(code))}
    }
    static func save(_ key:String) throws {
        guard !offline else {throw NSError(domain:"offline",code:1)}
        var trusted:SecTrustedApplication?; var access:SecAccess?
        guard SecTrustedApplicationCreateFromPath(Bundle.main.executablePath,&trusted)==errSecSuccess,
              let trusted=trusted, SecAccessCreate("在场百炼凭据" as CFString,[trusted] as CFArray,&access)==errSecSuccess,
              let access=access else { throw NSError(domain:"keychain-access",code:1) }
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
            kSecAttrAccount as String:"beijing-asr",kSecAttrAccess as String:access,kSecValueData as String:Data(key.utf8)]
        var status=SecItemAdd(q as CFDictionary,nil)
        if status==errSecDuplicateItem {
            let match:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"beijing-asr"]
            status=SecItemUpdate(match as CFDictionary,[kSecValueData as String:Data(key.utf8),kSecAttrAccess as String:access] as CFDictionary)
        }
        guard status == errSecSuccess else {throw NSError(domain:"keychain-save",code:Int(status))}
    }
}

final class FocusPanel:NSPanel {
    override func sendEvent(_ event:NSEvent) {
        if event.type == .keyDown,event.keyCode==48,let current=firstResponder as? NSControl {
            var next:NSView?=event.modifierFlags.contains(.shift) ? current.previousKeyView:current.nextKeyView
            for _ in 0..<8 {guard let target=next else{break};if !target.isHidden && ((target as? NSControl)?.isEnabled ?? true) && target.acceptsFirstResponder {makeFirstResponder(target);return};next=event.modifierFlags.contains(.shift) ? target.previousKeyView:target.nextKeyView}
        }
        super.sendEvent(event)
    }
}
final class FocusPopup:NSPopUpButton {override var acceptsFirstResponder:Bool {true}}
final class ImmediateButton:NSButton {
    override var acceptsFirstResponder:Bool {true}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
}
final class Delegate:NSObject,NSApplicationDelegate,NSWindowDelegate,NSTextFieldDelegate,NSToolbarDelegate,NSTextViewDelegate,NSTableViewDelegate,NSTableViewDataSource,NSSearchFieldDelegate {
    var sidebar:NSView!;var sidebarWidth:NSLayoutConstraint!;var sidebarManualVisible:Bool?
    var sidebarDivider:MeetingSidebarDivider?;var preferredSidebarWidth:CGFloat=200;var sidebarPreferencesOverride:UserDefaults?
    var meetingDeletionBusy=false;var deletingCacheID:String?;var deletionConfirmationOverride:((CachedMeeting)->Bool)?
    var libraryManagement:MeetingLibraryManagement?
    var feedbackExpiresAt=Date.distantPast;var feedbackUndoButton:NSButton?;var feedbackAllowsNameUndo=false
    var deletionStoreOverride:MeetingDeletionStore?;var libraryMenuTarget:CachedMeeting?;var restoreSelectionOverride:(([MeetingDeletionReceipt])->MeetingDeletionReceipt?)?
    var agentController:MeetingAgentController?;var agentSidebarButton:NSButton?;var agentFeatureOverride=false;var agentLiveProbe=false;var agentStoreOverride:URL?
    var notesController:MeetingNotesController?;var notesExpanded=false;var notesPausedRelative:Double?
    var documentHost:NSView!;var currentDocument:NSView!;var meetingTitleField:NSTextField!;var meetingTitle="新会议"
    var librarySearch:NSSearchField!;var libraryTable:NSTableView!;var libraryStatus:NSTextField!;var libraryRetryButton:NSButton!;var libraryVisible:[CachedMeeting]=[];var librarySelectionChanging=false
    let libraryJob=CacheReadJob();let libraryOpenJob=CacheReadJob();let librarySearchJob=CacheReadJob();let librarySummaryJob=CacheReadJob();var librarySummaryPending:CachedMeeting?;var librarySummaryGeneration=0;var librarySummaryLoaded:Set<String>=[];var libraryFilterWork:DispatchWorkItem?;var pendingLibraryOpen:CachedMeeting?;var libraryReloadPending=false;var librarySelectRecentPending=false
    var liveReturn:NSButton!;var timelineToggle:NSButton!;var historyLiveButton:NSButton!;var showsSpeakerRanges=false
    var speakerReviewButton:NSButton?;var voiceCandidateButton:NSButton?;var speakerReviewWindow:NSWindow?;var libraryParticipants:[String:[String]]=[:]
    let autoTitle=MeetingAutoTitle();var titleProvider:MeetingTitleProvider?;var titleTextAllowed=false;var titleTask:Task<Void,Never>?;var titleRevision=0
    var finalTitleTasks:[String:Task<Void,Never>]=[:]
    var isHistoryReader=false;weak var workspaceOwner:Delegate?;var historyReader:Delegate?;var historyReaderShell:NSWindow?
    var recordingLiveDot:RecordingLiveDot?;var recordingCapsuleWidth:NSLayoutConstraint?;var recordingModeChip:RecordingModeChip?;var readingAlignedRows:[NSStackView]=[];var settingsLayoutFrames:[(NSView,NSRect)]=[];var notesTransportStack:NSStackView?;var meetingEyebrow:NSTextField?;var emptyFilesButton:NSButton?;var emptyTranscribeButton:NSButton?;var window:NSWindow!;var sheet:NSPanel!;var key:NSSecureTextField!;var keyLabel:NSTextField!;var setupMessage:NSTextField!;var savedLabel:NSTextField!;var save:NSButton!;var change:NSButton!
    var historyButton:NSButton?;var newButton:NSButton?;var archiveButton:NSButton?;var heading:NSTextField!;var source:NSTextField!;var meter:NSTextField!;var action:NSButton!;var output:NSTextView!;var scroll:NSScrollView!;var empty:NSTextField!;var latest:NSButton!;var footerDetails:NSButton!;var settingsCancel:NSButton!;var diagnostic:NSTextField!
    var phase=UIState();var child:Process?;var quitting=false;var mock=false;var timer:Timer?;var mockTick=0;let vault=MockVault()
    var terminationJobsPending=0;var terminationReplyPending=false;var terminationWriteBarrierStarted=false
    var terminationReplyOverride:(()->Void)?
    var workerGeneration=UUID();var workerExitReceived=false;var workerEOFReceived=false
    var pending=Data();var buffer=Data();let readLock=NSLock();var drainScheduled=false;var transcriptRenderScheduled=false;var transcriptRenderPending=false;var lastTranscriptRender=Date.distantPast;var transcriptProjectionComputations=0;var spokenRowsCache:[String:(revision:Int,correctionRevision:Int,rows:[(String,[String:Any])])]=[:]
    var incrementalTranscript=IncrementalTranscript();var dirtyTranscriptParents:Set<String>=[];var dirtyTranscriptQueue:[String]=[];var dirtyTranscriptQueueIndex=0;var fullRefreshBlocksByParent:[String:[TranscriptRenderedBlock]]=[:];var fullRefreshGeneration=0;var indexedCorrectionRevision=0;var fullRefreshAtomsReady=false;var fullRefreshBuildInFlight=false;var nonFinalTranscriptParents=Set<String>();var fullTranscriptRefreshPending=false
    var transcriptReadingRestoreRevision=0;var pendingTranscriptReadingPosition:TranscriptReadingPosition?;var pendingTranscriptSelection:NSRange?
    var timeline=TranscriptTimeline();var segments:[String:[String:Any]] {get {timeline.records} set {timeline.records=newValue;if newValue.isEmpty {fullRefreshGeneration &+= 1;indexedCorrectionRevision=naming.correctionRevision;fullRefreshAtomsReady=false;fullRefreshBuildInFlight=false;timeline.discardedIDs=[];spokenRowsCache=[:];dirtyTranscriptParents=[];dirtyTranscriptQueue=[];dirtyTranscriptQueueIndex=0;fullRefreshBlocksByParent=[:];nonFinalTranscriptParents=[];observedTranscriptTracks=[];observedTranscriptApplications=[];fullTranscriptRefreshPending=false;if let storage=output?.textStorage {incrementalTranscript.reset(storage:storage)}}}};var sequence:[String] {get {timeline.orderedIDs} set {timeline.arrivalOrder=newValue}};var expandedParents:[String:Set<String>]=[:];var transcriptCapacity=TranscriptCapacity();var showWholeTranscript=true;var transcriptLimitHit=false;var processingAudio=false;var asrNetworkStates:[String:String]=[:];var currentCacheID:String? {didSet {if oldValue != currentCacheID {notesPausedRelative=nil;cancelMeetingMinutes();translationCredentialJob.cancel();translationService.bind(cacheID:currentCacheID,root:recoveryBase());translationSwitch?.state=translationService.enabled ? .on:.off};notesController?.bind(currentCacheID)}};var cachedTranscriptionComplete=false;var observedTranscriptTracks=Set<String>();var observedTranscriptApplications=Set<String>()
    lazy var translationService=MeetingTranslationService();var translationSwitch:MeetingTintedSwitch?;let translationCredentialJob=CacheReadJob();var translationStatusLabel:NSTextField?
    var meetingMinutesBusy=false;var meetingMinutesTask:Task<Void,Never>?;let meetingMinutesCredentialJob=CacheReadJob();let meetingMinutesReferenceJob=CacheReadJob()
    var availableCloudSeconds=0;let budgetReadJob=CacheReadJob();let credentialReadJob=CacheReadJob()
    let cacheReadJob=CacheReadJob();let cacheExportJob=CacheReadJob();let recordDetailsJob=CacheReadJob();let cacheWriteQueue=DispatchQueue(label:"meeting.cache.writes");
    var localOnlyMode=false;var modeUserSelected=false;var recordingModePicker:NSPopUpButton?;var exportButton:NSButton?;var startupWorkerFixture:(([String:Any])->Void)?;var startupCredentialFixture:(()throws->String?)?
    var recordingTimeLabel:NSTextField?;var recordingActionCaption:NSTextField?;var recordingTransportView:NSView?
    lazy var recordingAttention=RecordingAttention(owner:self)
    var coarseStopButton:NSButton?
    var recordingModeSwitch:NSSegmentedControl?;var recordingModeHint:NSTextField?
    var microphoneLevel:RecordingLevelView?;var computerLevel:RecordingLevelView?;var audioLevelTimer:Timer?
    var latestAudioLevels:[String:[String:Any]]=[:];var latestAudioLevelAt=0.0
    var sessionLocalOnly=false
    var newRecordingPending=false
    let qaWriteJob=CacheReadJob();var qaStore:RecordingJournal?;var qaSession="";var qaRecoveryMode="slow"
    var recoveryRetireOverride:((URL)throws->URL)?;var recoveryRootOverride:URL?;var recoveryBudgetOverride:Int?;var recoveryRunnerOverride:((CachedMeeting)->Void)?
    var recoveryPanel:NSPanel?;var recoveryPicker:NSPopUpButton?;var recoveryDetail:NSTextField?;var recoveryContinue:NSButton?;var recoveryOriginal:NSButton?;var recoveryRestore:NSButton?;var recoveries:[CachedMeeting]=[];var resumeBusy=false;var recoveredArchiveText:String?
    var pendingAppendCaptureID:String?
    // Times of automatic resumes after a microphone change; bounds a flapping device.
    var deviceAutoResumeTimes:[Double]=[]
    var replacing=false;var editing=false;var fixture:NSPopUpButton!
    let fixtureBoard=NSPasteboard(name:NSPasteboard.Name("com.joesang.meeting-assistant.validation-only"))
    let fixtures=["fake",String(repeating:"x",count:16),String(repeating:"x",count:32),String(repeating:"x",count:64),String(repeating:"x",count:128),"  fake_key  \n","fake-_/+.=:()", "fake\ninside"]
    var sourceBundle="*system*";var sourceName="电脑声音";var sessionSource="电脑声音与麦克风";var useMic=true;var confirmedScope=false
    var people:[String:String]=[:];var identityArchive=IdentityArchive();var balanceDraft=BalanceConnectionDraft()
    var absoluteTime:MeetingAbsoluteTime?
    var contextPublisher:MeetingContextPublisher?;var contextSession:String?
    var confirmationController:SpeakerConfirmationController?;var confirmationDrafts:[String:String]=[:]
    var quickVoiceUndoScope:(session:String,cache:String,generation:Int,revision:Int)?;var quickVoiceUndoPending=false
    var voiceprintService:VoiceprintRecommendationService?;var voiceprintCandidates:[SessionSpeakerKey:VoiceprintRecommendation]=[:];var voiceprintSuggestionArchive:VoiceprintArchive?;var voiceprintGeneration=0;var voiceprintStatus=""
    let savedVoiceRecognitionJob=SpeakerRefinementJob(timeout:120)
    var savedVoiceRecognitionExecutorOverride:((SavedVoiceRecognitionRequest,UUID,@escaping(UUID,Result<Data,Error>)->Void)->Void)?
    var workerInput:FileHandle?;var activeSession:String?;var identitySnapshot:[String:Any]?;var humanIdentityAuthorized=false;var identityBusy=false;var profileStore:ProfileArchiveStore?;var balanceState=BalanceSnapshotState();var balanceCredentials:BalanceCredentials?;var balancePermission=false;var lastWorkerManual:[String:String]=[:]
    var pausedTailStates:[String:String]=[:];var pausedTailRevision:Int?;var lastRecordingControlRevision = -1
    var recordingControlTimeout:DispatchWorkItem?;var recordingControlTimeoutSeconds=3.0
    var meetingDocumentGeneration=0 {didSet {if oldValue != meetingDocumentGeneration {cancelMeetingMinutes()}}};var newMeetingRequested=false;var newMeetingSaveInFlight=false
    var recordingControlInFlight:String?
    var pendingAutomaticTailRecovery:(reason:String,cacheID:String,session:String)?;var automaticTailRecoveryAttempted=Set<String>()
    var mockRecordingControlHandler:(([String:Any])->Void)?;var mockStopHandler:(()->Void)?;var savePanelURLProvider:(()->URL?)?
    var echoStatusLabel="";var observedAppSources:[String:String]=[:]
    var sourceCaptureGapLabels=Set<String>();var unavailableAppSourceIDs=Set<String>()
    var replayingHistory=false;var deferPresentation=false
    var speakerRefinementJob=SpeakerRefinementJob()
    var savedCoarseJobs:[String:SpeakerRefinementJob]=[:]
    var pendingCoarseCutoffs:[String:Double]=[:]
    var lastCoarseInputSignatures:[String:String]=[:]
    var coarseProcessingProgress:CoarseProcessingProgress?
    var coarseProcessingSummary:String?
    var coarseProgressTimer:Timer?
    var coarseRefinementExecutorOverride:(([String:Any],UUID,@escaping(UUID,Result<Data,Error>)->Void)->Void)?
    var speakerRefinementLifecycle=MeetingSpeakerRefinementLifecycle()
    var speakerRefinementToken:UUID?
    var speakerRefinementScope:(cacheID:String,session:String,generation:Int,correctionRevision:Int)?
    var speakerRefinementNeedsRetry=false
    var speakerRefinementMessage:String?
    var speakerRefinementFailureCode:String?
    var speakerRefinementFailureRevision:Int?
    var coarseResultToken:(cacheID:String,session:String,generation:Int,revision:Int,sourceSHA256:String,snapshotSHA256:String)?
    var suppressAutomaticRefinementAfterStop=false
    var speakerRefinementExecutorOverride:(([String:Any],URL,URL,UUID,@escaping(UUID,Result<Data,Error>)->Void)->Void)?
    var speakerRefinementRequestOverride:(([String:Any])->Void)?
    var speakerRefinementCheckMode=false
    var sourceActivity=SourceActivity()
    var microphoneSignalAlertVisible=false
    var speakerLoading=false
    var preparingModels=false;var modelsPrepared=false;var preparationElapsed=0.0;var preparationTrack="mic"
    var identityCandidatesEnabled=false;var candidateBySegment:[String:(String,String,Int)]=[:];var feedback:[[String:String]]=[]
    var previewRenderOnly=false
    var inlinePopover:NSPopover?;var inlineField:NSTextField?;var inlineSegment:String?
    var inlineScope:NSPopUpButton?;var inlineTargets:[Int:SessionSpeakerKey]=[:]
    var naming=SessionNames()
    // Transcript range lookup is backed by the treap index.
    var textRanges:[String:NSRange] {incrementalTranscript.allTurnRanges()}
    var root:String {if Bundle.main.object(forInfoDictionaryKey:"SelfContainedRuntime") as? Bool==true,let resources=Bundle.main.resourceURL {return resources.appendingPathComponent("Runtime").path};return Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String ?? ""}
    var captureExecutableURL:URL {if offlineQA {return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/会议采集离线QA.app/Contents/MacOS/MeetingCapture")};let revision=Bundle.main.object(forInfoDictionaryKey:"CandidateRevision") as? String;let build=revision=="nightly" ? "nightly-build":revision=="repair" ? "candidate-repair-build":"ui-next-build";return URL(fileURLWithPath:root+"/native/"+build+"/"+(build=="ui-next-build" ? "会议采集验证":"会议采集候选")+".app/Contents/MacOS/MeetingCapture")}
    var trialCandidate:Bool {Bundle.main.object(forInfoDictionaryKey:"TrialCandidate") as? Bool ?? false}
    var trialArmed:Bool {Bundle.main.object(forInfoDictionaryKey:"TrialArmed") as? Bool ?? false}
    var authorized:Bool {Bundle.main.object(forInfoDictionaryKey:"KeychainAuthorized") as? Bool ?? false}
    var stored:Bool {mock ? vault.bytes != nil : authorized && Credential.existenceStatus()==errSecSuccess}
    func label(_ text:String,size:CGFloat=13,weight:NSFont.Weight = .regular)->NSTextField {let v=NSTextField(wrappingLabelWithString:text);v.font = .systemFont(ofSize:size,weight:weight);v.alignment = .left;return v}
    func stack(_ orientation:NSUserInterfaceLayoutOrientation,spacing:CGFloat=12)->NSStackView {let v=NSStackView();v.orientation=orientation;v.spacing=spacing;v.alignment = orientation == .horizontal ? .centerY:.leading;return v}
    func applicationDidFinishLaunching(_ note:Notification) {
        mock=Credential.offline || CommandLine.arguments.contains("--mock");humanIdentityAuthorized=Bundle.main.object(forInfoDictionaryKey:"HumanIdentityUseAuthorized") as? Bool ?? false
        if let path=Bundle.main.resourcePath,let icon=NSImage(contentsOfFile:path+"/"+(Bundle.main.object(forInfoDictionaryKey:"CFBundleIconFile") as? String ?? "MeetingAssistant.icns")) {NSApp.applicationIconImage=icon}
        restoreSidebarWidth();buildWorkspace()
        buildSettings();configureRecordingStartPreference();cacheReadJob.onStateChange={ [weak self] in self?.updateUI() };cacheExportJob.onStateChange={ [weak self] in self?.updateUI() };qaWriteJob.onStateChange={ [weak self] in self?.updateUI();DispatchQueue.main.async {self?.completeApplicationTerminationIfReady()} };installMenus();if !previewRenderOnly {window.center();if offlineQA {window.orderFront(nil)}else{window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}}
        if mock {fixtureBoard.clearContents();fixtureBoard.setString(fixtures[0],forType:.string)}
        if offlineQA {do {try configureOfflineQA()}catch{phase.phase = .failed;phase.error="离线QA隔离配置错误";updateUI();return}}
        // No recording or secret retrieval on launch.
        layoutWorkspace();updateUI();configureVoiceprintRecommendations();configureMeetingContext();reconcileDeletedMeetingProjections()
        showMissingCredentialHintIfNeeded()
        if previewRenderOnly {return}
        reloadLibrary(selectRecent:true)
        if !mock && Bundle.main.object(forInfoDictionaryKey:"LocalRecordingAllowed") as? Bool != true {refreshCloudBudget()}
        if !mock && Bundle.main.object(forInfoDictionaryKey:"LocalRecordingAllowed") as? Bool==true {return}
        if trialCandidate {if !mock && Bundle.main.object(forInfoDictionaryKey:"LocalRecordingAllowed") as? Bool != true && remainingSeconds()<=0 {newRecordingPending=true;diagnostic.stringValue="正在连接转写服务";updateUI()};return}
        if !mock && remainingSeconds()<=0 {phase.phase = .ended;updateUI()} else if !stored {showSettings()}
    }
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] {[NSToolbarItem.Identifier("history"),.flexibleSpace,NSToolbarItem.Identifier("search"),NSToolbarItem.Identifier("export"),NSToolbarItem.Identifier("details"),NSToolbarItem.Identifier("assistant"),NSToolbarItem.Identifier("more")]}
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] {
        assistantEnabled ? [NSToolbarItem.Identifier("history"),.flexibleSpace,NSToolbarItem.Identifier("assistant"),NSToolbarItem.Identifier("export"),NSToolbarItem.Identifier("more")] : [NSToolbarItem.Identifier("history"),.flexibleSpace,NSToolbarItem.Identifier("search"),NSToolbarItem.Identifier("export"),NSToolbarItem.Identifier("details")]
    }
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier id:NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag:Bool)->NSToolbarItem? {
        let spec:(String,String,Selector)
        switch id.rawValue {
        case "history":spec=("会议列表","sidebar.left",#selector(toggleSidebar))
        case "search":spec=("搜索原文","magnifyingglass",#selector(showDocumentSearch))
        case "assistant":spec=("显示或隐藏右侧栏","sidebar.right",#selector(toggleVisibleAssistant))
        case "more":spec=("更多","ellipsis",#selector(showAssistantMore(_:)))
        case "details":spec=("会议详情","info.circle",#selector(showWorkspaceDetails))
        case "export":spec=("导出","square.and.arrow.up",#selector(showMeetingExportMenu))
        default:spec=("设置","gearshape",#selector(showSettings))
        }
        let item=NSToolbarItem(itemIdentifier:id);item.label=spec.0;item.toolTip=spec.0;item.autovalidates=false
        let button=ImmediateButton(title:spec.0,target:self,action:spec.2);button.bezelStyle = .inline;button.isBordered=false;button.contentTintColor=MeetingVisualStyle.muted;button.image=NSImage(systemSymbolName:spec.1,accessibilityDescription:spec.0);button.imagePosition = .imageOnly;button.title="";button.setAccessibilityLabel(spec.0)
        item.view=button
        switch id.rawValue {case "history":historyButton=button;case "export":exportButton=button;case "assistant":agentSidebarButton=button;default:break}
        return item
    }
    func windowDidResize(_ notification:Notification) {layoutWorkspace()}
    func resizeTranscript() {
        guard let scroll=scroll,let output=output else{return}
        let width=max(1,scroll.contentSize.width)
        empty?.preferredMaxLayoutWidth=max(1,width-24)
        // One centred reading column: wider windows add margin, never line length.
        let margin=floor(max(0,(width-MeetingVisualStyle.readingWidth)/2))
        if abs(output.textContainerInset.width-margin)>0.5 {output.textContainerInset=NSSize(width:margin,height:output.textContainerInset.height)}
        for row in readingAlignedRows where abs(row.edgeInsets.left-margin)>0.5 {row.edgeInsets=NSEdgeInsets(top:row.edgeInsets.top,left:margin,bottom:row.edgeInsets.bottom,right:margin)}
        if abs(output.frame.width-width)>0.5 {output.setFrameSize(NSSize(width:width,height:output.frame.height))}
        let textWidth=max(1,width-2*margin)
        if let container=output.textContainer,abs(container.containerSize.width-textWidth)>0.5 {container.containerSize=NSSize(width:textWidth,height:CGFloat.greatestFiniteMagnitude)}
    }
    func buildSettings() {
        sheet=FocusPanel(contentRect:NSRect(x:0,y:0,width:520,height:360),styleMask:[.titled,.closable],backing:.buffered,defer:false);sheet.title="设置";sheet.delegate=self;sheet.autorecalculatesKeyViewLoop=false
        let content=sheet.contentView!
        func place(_ v:NSView,_ x:CGFloat,_ y:CGFloat,_ width:CGFloat,_ height:CGFloat){v.frame=NSRect(x:x,y:y,width:width,height:height);content.addSubview(v)}
        place(label("记录方式",size:13,weight:.medium),24,308,100,24)
        let mode=FocusPopup();mode.addItems(withTitles:["录音并转写", "仅录音"]);mode.selectItem(at:localOnlyMode ? 1:0);mode.target=self;mode.action=#selector(changeRecordingMode);recordingModePicker=mode;place(mode,130,306,220,28)
        place(label("麦克风和电脑声音同时收录，无需切换应用。",size:13),24,271,472,32)
        let captureHint=label("包括会议软件、浏览器、播放器，以及会议中共享的声音。",size:12);captureHint.textColor = .secondaryLabelColor;place(captureHint,24,242,472,28)
        let separator=NSBox();separator.boxType = .separator;place(separator,24,233,472,1)
        savedLabel=label("密钥已保存在这台Mac",size:13);place(savedLabel,24,195,472,24)
        keyLabel=label("百炼密钥",size:13,weight:.medium);place(keyLabel,24,195,472,24)
        key=NSSecureTextField();key.delegate=self;key.placeholderString=mock ? "仅输入假密钥" : "粘贴API密钥";key.bezelStyle = .roundedBezel;place(key,24,157,472,30)
        let privacy=label(mock ? "离线预览：请勿输入真实密钥。" : "云端识别由阿里云百炼提供，录音保存在本机。",size:12);privacy.identifier=NSUserInterfaceItemIdentifier("settings-privacy");privacy.textColor = .secondaryLabelColor;place(privacy,24,126,472,22)
        // One 12pt line fits in 17pt. Keep its upper edge at 123 and leave
        // 2pt below it before the more-settings buttons end at y=104.
        setupMessage=label("",size:12);setupMessage.identifier=NSUserInterfaceItemIdentifier("settings-message");setupMessage.textColor = .secondaryLabelColor;place(setupMessage,24,106,472,17)
        if mock || humanIdentityAuthorized || !trialCandidate {place(label("更多设置",size:12,weight:.medium),24,78,76,24)}
        let peopleButton=ImmediateButton(title:"人物资料…",target:self,action:#selector(manageConsent));peopleButton.identifier=NSUserInterfaceItemIdentifier("settings-people");peopleButton.bezelStyle = .rounded;peopleButton.isHidden = !mock && !humanIdentityAuthorized;place(peopleButton,112,76,88,28)
        let balanceButton=ImmediateButton(title:"余额…",target:self,action:#selector(configureBalance));balanceButton.identifier=NSUserInterfaceItemIdentifier("settings-balance");balanceButton.bezelStyle = .rounded;place(balanceButton,208,76,88,28);balanceButton.isHidden=trialCandidate
        change=ImmediateButton(title:"更换密钥",target:self,action:#selector(changeKey));change.bezelStyle = .rounded;place(change,24,20,108,28)
        let cancel=ImmediateButton(title:"取消",target:self,action:#selector(dismissSettings));settingsCancel=cancel;cancel.bezelStyle = .rounded;cancel.keyEquivalent="\u{1b}";place(cancel,296,20,84,28)
        save=ImmediateButton(title:"保存密钥",target:self,action:#selector(saveKey));save.bezelStyle = .rounded;save.keyEquivalent="\r";place(save,388,20,108,28)
        fixture=FocusPopup();fixture.addItems(withTitles:["4字符","16字符","32字符","64字符","128字符","首尾空白","特殊字符","内部换行"])
        key.nextKeyView=cancel;cancel.nextKeyView=save;save.nextKeyView=key
        settingsLayoutFrames=content.subviews.map{($0,$0.frame)}
    }
    // New recordings always use both capture lanes. Historical sessions keep their
    // original scope while being reviewed or resumed; reset only when starting anew.
    func prepareAutomaticCapture() {
        guard (child==nil || modelsPrepared),![.connecting,.recording,.stopping].contains(phase.phase) else{return}
        sourceBundle="*system*";sourceName="电脑声音";useMic=true;confirmedScope=false
    }
    var showsMissingCredentialHint:Bool {diagnostic?.stringValue=="去设置里填写百炼密钥"}
    func showMissingCredentialHintIfNeeded() {
        if !stored {
            diagnostic.stringValue="去设置里填写百炼密钥";diagnostic.isHidden=false
            if currentCacheID==nil {empty.stringValue=diagnostic.stringValue}
        }
    }
    @objc func showSettings() {
        guard (child==nil || modelsPrepared),[.idle,.stopped,.failed,.ended].contains(phase.phase),window.attachedSheet==nil else {return}
        editing = !stored;replacing=false;key.stringValue="";refreshSettings();window.beginSheet(sheet);sheet.makeFirstResponder(editing ? key : save)
    }
    func refreshSettings() {
        let enteringKey=editing || !stored
        savedLabel.isHidden=enteringKey;keyLabel.isHidden = !enteringKey;key.isHidden = !enteringKey;change.isHidden = !stored || enteringKey
        // Collapse the absent input row and shorten the sheet. Always derive
        // frames from the editing layout, so repeated replacements never drift.
        let reduction:CGFloat=enteringKey ? 0:60
        sheet.setContentSize(NSSize(width:520,height:360-reduction))
        for (view,baseline) in settingsLayoutFrames {
            var frame=baseline
            if baseline.minY>=157 {frame.origin.y-=reduction}
            else if baseline.minY>=76 {frame.origin.y-=enteringKey ? 0:22}
            view.frame=frame
        }
        savedLabel.needsDisplay=true;keyLabel.needsDisplay=true;sheet.contentView?.needsDisplay=true
        save.title=editing ? "保存密钥" : "完成";save.isEnabled = !editing || CredentialInput(raw:key.stringValue).issue==nil
        setupMessage.stringValue=editing ? "" : "已保存";sheet.layoutIfNeeded()
    }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
        if control===key && selector==#selector(NSResponder.insertTab(_:)) {sheet.makeFirstResponder(settingsCancel);return true}
        if control===key && selector==#selector(NSResponder.insertBacktab(_:)) {sheet.makeFirstResponder(save);return true}
        return false
    }
    func controlTextDidChange(_ note:Notification) {
        if handleWorkspaceTextChange(note) {return}
        let value=CredentialInput(raw:key.stringValue)
        save.isEnabled=value.issue==nil
        setupMessage.stringValue=value.raw.isEmpty ? "" : value.issue ?? (value.trimmed ? "将移除首尾空白，\(value.count)个字符" : "已输入\(value.count)个字符")
    }
    @objc func changeKey() {editing=true;replacing=true;key.stringValue="";refreshSettings();sheet.makeFirstResponder(key)}
    @objc func saveKey() {
        if !editing {dismissSettings();return}
        let value=CredentialInput(raw:key.stringValue);guard value.issue==nil else {setupMessage.stringValue=value.issue!;return}
        do {
            if mock {try vault.save(value.normalized);precondition(vault.bytes==Data(value.normalized.utf8))}
            else {guard authorized else {return};try Credential.save(value.normalized)}
            key.stringValue="";editing=false;replacing=false;refreshSettings();if diagnostic.stringValue=="去设置里填写百炼密钥" {diagnostic.stringValue="密钥已保存";if currentCacheID==nil {empty?.stringValue="开始后，会议文字会出现在这里"}};setupMessage.stringValue="已保存";sheet.makeFirstResponder(save)
        } catch {setupMessage.stringValue=stored ? "没能更换密钥，原密钥仍可用。请重试。" : "没能保存密钥，请重试。"}
    }
    @objc func dismissSettings() {key.stringValue="";window.endSheet(sheet);sheet.orderOut(nil)}
    @objc func selectFixture() {fixtureBoard.clearContents();fixtureBoard.setString(fixtures[fixture.indexOfSelectedItem],forType:.string);sheet.makeFirstResponder(key)}
    @objc func failSave() {vault.failNext=true;setupMessage.stringValue="虚构测试：下次保存将失败，旧值保留。"}
    @objc func toggle() {
        guard !(workspaceOwner ?? self).meetingDeletionBusy else{return}
        guard !audioAssetOperationBusy || (workspaceOwner ?? self).recordingBusy else{showTransientFeedback("录音文件正在保存，请稍后开始");return}
        if credentialReadJob.waiting {credentialReadJob.cancel();resumeBusy=false;processingAudio=false;phase.phase = .idle;phase.error="已取消连接";updateUI();return}
        if cacheReadJob.waiting || cacheExportJob.waiting || qaWriteJob.waiting {cacheReadJob.cancel();cacheExportJob.cancel();qaWriteJob.cancel();phase.error="已取消";diagnostic.stringValue="会议内容已保留";updateUI();return}
        if offlineQA && preparingModels {timer?.invalidate();preparingModels=false;modelsPrepared=false;phase.phase = .idle;diagnostic.stringValue="假准备已取消，未采音／未连接云";updateUI();return}
        if processingAudio,let child=child {child.interrupt();diagnostic.stringValue="正在取消整理，已转写文字保留";return}
        if phase.phase == .recording {return}
        if phase.phase == .paused {sendRecordingControl("resume");return}
        if currentCacheID != nil {diagnostic.stringValue="本场已保存；请点“新会议”开始另一场";return}
        guard [.idle,.stopped,.failed].contains(phase.phase) else {return}
        prepareAutomaticCapture()
        if Bundle.main.object(forInfoDictionaryKey:"LocalRecordingAllowed") as? Bool==true && (!mock || (Credential.offline && previewRenderOnly && startupWorkerFixture != nil)) {beginRecordingModeFlow();return}
        if !mock && localOnlyMode {beginLocalOnlyFlow();return}
        if !trialCandidate && !stored {showSettings();return}
        if !mock && remainingSeconds()<=0 {beginLocalOnlyFlow();return}
        if !mock && !["com.tencent.meeting","*microphone*"].contains(sourceBundle) {
            let alert=NSAlert();alert.messageText="开始实时转写？";alert.informativeText=(sourceBundle=="*system*" ? "全部电脑声音包括浏览器、音乐、通知。" : sourceName+"。")+(useMic ? "另收录麦克风。" : "不收录麦克风。")+"音频将上传至云端生成文字，费用按实际用量计算。";alert.addButton(withTitle:"确认并开始");alert.addButton(withTitle:"取消");guard alert.runModal() == .alertFirstButtonReturn else{return};confirmedScope=true
        }
        sessionSource=sourceName.replacingOccurrences(of:"声音",with:"");source.stringValue=sourceName.replacingOccurrences(of:"声音",with:"")+(useMic ? " · 麦克风" : "");naming.reset();recoveredArchiveText=nil;currentCacheID=nil;recordingControlInFlight=nil
        guard phase.start() else {return};activeSession=nil;absoluteTime=nil;resetVoiceprintRecommendations(session:nil);sourceActivity=SourceActivity();segments=[:];sequence=[];expandedParents=[:];transcriptCapacity.reset();transcriptLimitHit=false;showWholeTranscript=true;output.string="";empty.isHidden=false;buffer=Data();updateUI()
        if mock {
            mockTick=0
            let begin={ [weak self] in guard let self=self else{return};self.timer=Timer.scheduledTimer(withTimeInterval:0.4,repeats:true){[weak self] _ in self?.mockStep()}}
            if offlineQA {beginQAMeetingAsync(done:begin)}else{begin()};return
        }
        let secret:String
        do {guard let found=try Credential.load(),!found.isEmpty else {phase.phase = .failed;phase.error="去设置里填写百炼密钥";updateUI();return};secret=found}
        catch {phase.phase = .failed;phase.error="无法连接转写服务，请允许访问系统保存的凭据";updateUI();return}
        startWorker(secret)
    }
    func recordingControlCommand(action:String)->[String:Any]? {
        guard ["pause","resume"].contains(action),let session=activeSession,!session.isEmpty else{return nil}
        return ["operation":"recording_control","action":action,"session":session]
    }
    func sendRecordingControl(_ action:String) {
        guard recordingControlInFlight==nil,
              (action=="pause" ? phase.phase == .recording:phase.phase == .paused),
              let command=recordingControlCommand(action:action) else{return}
        if action=="resume" {cancelSpeakerRefinementForResume();invalidateMeetingArchivePreparationOnResume()}
        recordingControlInFlight=action;recordingControlTimeout?.cancel()
        // The worker owns the hardware safety cutoff and observes ACKs before
        // UI delivery. A delayed UI queue must not terminate an already-paused
        // healthy recorder or overwrite its control failure with user_stop.
        let session=activeSession
        let timeout=DispatchWorkItem{[weak self] in
            guard let self,self.activeSession==session,self.recordingControlInFlight==action else{return}
            self.diagnostic.stringValue=action=="pause" ? "正在确认暂停，请稍候":"正在恢复收音，请稍候"
            self.updateUI()
        }
        recordingControlTimeout=timeout
        DispatchQueue.main.asyncAfter(deadline:.now()+recordingControlTimeoutSeconds,execute:timeout)
        updateUI()
        if mock {
            guard let mockRecordingControlHandler=mockRecordingControlHandler else{recordingControlInFlight=nil;updateUI();return}
            mockRecordingControlHandler(command);return
        }
        guard child?.isRunning==true,let handle=workerInput,
              let data=try? JSONSerialization.data(withJSONObject:command) else{recordingControlInFlight=nil;end();diagnostic.stringValue="控制连接中断，正在停止采集和上传；已有记录保留";updateUI();return}
        do {try handle.write(contentsOf:data+Data([10]))}
        catch {recordingControlInFlight=nil;end();diagnostic.stringValue="控制连接中断，正在停止采集和上传；已有记录保留";updateUI()}
    }
    @objc func changeRecordingMode(){guard canSelectRecordingMode else{recordingModePicker?.selectItem(at:displayedLocalMode ? 1:0);return};modeUserSelected=true;localOnlyMode=recordingModePicker?.indexOfSelectedItem==1;persistRecordingStartPreference();newRecordingPending=localOnlyMode;diagnostic.stringValue=localOnlyMode ? "只保存录音，不上传":"边录音，边生成文字";updateUI()}
    func beginLocalOnlyFlow(){
        guard !audioAssetOperationBusy else{showTransientFeedback("录音文件正在保存，请稍后开始");return}
        prepareAutomaticCapture()
        guard Bundle.main.object(forInfoDictionaryKey:"LocalRecordingAllowed") as? Bool==true else{newRecordingPending=true;phase.phase = .idle;diagnostic.stringValue="当前版本不支持录音，请更新应用";updateUI();return}
        titleProvider=nil;titleTextAllowed=false
        sessionLocalOnly=true;localOnlyMode=true;newRecordingPending=false;confirmedScope=true;useMic=true;phase=UIState();guard phase.start() else{return};activeSession=nil;absoluteTime=nil;resetVoiceprintRecommendations(session:nil);naming.reset();sourceActivity=SourceActivity();segments=[:];sequence=[];expandedParents=[:];transcriptCapacity.reset();transcriptLimitHit=false;recoveredArchiveText=nil;currentCacheID=nil;sessionSource=sourceName;source.stringValue=sourceName+" · 本地录音（不上传）";output.string="";empty.isHidden=false;updateUI()
        let request:[String:Any]=["local_only":true,"local_recording_confirmed":true,"local_max_seconds":7200,"key":"","bundle":sourceBundle,"mic_enabled":true,"source_scope_confirmed":true,"user_launch_confirmed":true,"candidate_mode":trialCandidate]
        startWorker(nil,overrideRequest:request)
    }
    func beginCloudSessionFlow(){
        guard !audioAssetOperationBusy else{showTransientFeedback("录音文件正在保存，请稍后开始");return}
        prepareAutomaticCapture()
        let fixture=Credential.offline && previewRenderOnly && startupWorkerFixture != nil ? startupCredentialFixture:nil
        guard (!Credential.offline || fixture != nil),Bundle.main.object(forInfoDictionaryKey:"LocalRecordingAllowed") as? Bool==true,["com.tencent.meeting","*microphone*","*system*"].contains(sourceBundle) else{phase.error="暂时无法开始转写，请重试";updateUI();return}
        // Cancellation releases the waiting token, not the system credential
        // dialog itself. Keep local recording available while that read ends.
        guard !credentialReadJob.busy else{phase.phase = .failed;phase.error="请先处理系统服务访问提示，或选择仅录音";updateUI();return}
        sessionLocalOnly=false;localOnlyMode=false
        newRecordingPending=false;phase=UIState();phase.phase = .connecting;phase.error=nil;diagnostic.stringValue="正在连接转写服务";credentialReadJob.onStateChange={ [weak self] in self?.updateUI() };updateUI()
        credentialReadJob.run(timeout:15,work:{if let fixture=fixture {return try fixture()};return try Credential.load()}){[weak self] result in guard let self=self else{return};switch result {case .success(let secret):guard let secret=secret,!secret.isEmpty else{self.phase.phase = .failed;self.phase.error="去设置里填写百炼密钥";self.updateUI();return};self.namelessCloudStart(secret);case .failure:self.phase.phase = .failed;self.phase.error="连接未完成，请处理系统访问提示后重试";self.updateUI()}}
    }
    func namelessCloudStart(_ key:String){
        titleProvider=DashScopeMeetingTitleProvider(apiKey:key);titleTextAllowed=true
        naming.reset();sourceActivity=SourceActivity();segments=[:];sequence=[];expandedParents=[:];transcriptCapacity.reset();transcriptLimitHit=false;currentCacheID=nil;activeSession=nil;absoluteTime=nil;resetVoiceprintRecommendations(session:nil);recoveredArchiveText=nil;showWholeTranscript=true;output.string="";empty.isHidden=false;sessionSource=sourceName;source.stringValue=sourceName+" · 实时转写";confirmedScope=true;useMic=true;phase.phase = .connecting;updateUI()
        let request:[String:Any]=["key":key,"bundle":sourceBundle,"mic_enabled":true,"source_scope_confirmed":true,"user_launch_confirmed":true,"candidate_mode":trialCandidate,"cloud_session_confirmed":true]
        startWorker(key,overrideRequest:request)
    }
    @objc func newMeeting(){
        guard !meetingDeletionBusy,!audioAssetOperationBusy else{return}
        cancelTranscriptReadingRestore()
        guard child==nil,!credentialReadJob.waiting,!processingAudio,!preparingModels,!([.connecting,.recording,.paused,.stopping].contains(phase.phase)) else{diagnostic.stringValue="正在保存上一场录音，请稍候";return}
        meetingDocumentGeneration &+= 1
        detachSavedCoarseRefinement();speakerRefinementLifecycle.begin(session:nil);speakerRefinementNeedsRetry=false
        invalidateAutoTitle();titleProvider=nil;titleTextAllowed=false;speakerReviewWindow?.close();speakerReviewWindow=nil
        // Clear the old live context before changing the visible title. Any UI
        // refresh during new-meeting setup must not publish that title to the
        // previously active session.
        activeSession=nil;updateMeetingContext()
        meetingTitle=MeetingLibraryInfo.defaultTitle(Date());showsSpeakerRanges=false
        // Existing app-owned journal remains on disk. Never retroactively save an old window.
        prepareAutomaticCapture()
        asrNetworkStates=[:];observedAppSources=[:];echoStatusLabel="";recordingControlInFlight=nil;cacheReadJob.cancel();cacheExportJob.cancel();qaWriteJob.cancel();timer?.invalidate();qaStore=nil;naming.reset();activeSession=nil;absoluteTime=nil;resetVoiceprintRecommendations(session:nil);currentCacheID=nil;sessionLocalOnly=false;recoveredArchiveText=nil;empty.stringValue="会议文字会出现在这里";segments=[:];sequence=[];expandedParents=[:];transcriptCapacity.reset();transcriptLimitHit=false;showWholeTranscript=true;phase=UIState();output.string="";empty.isHidden=false;sessionSource="新录音";source.stringValue="新录音 · 待开始";newRecordingPending = !mock && (localOnlyMode || (Bundle.main.object(forInfoDictionaryKey:"LocalRecordingAllowed") as? Bool != true && remainingSeconds()<=0));diagnostic.stringValue=newRecordingPending ? "准备录音":"点击开始记录新会议";agentController?.newWorkspace();updateUI()
    }
    func recoveryBase()->URL {if Credential.offline,let value=recoveryRootOverride{return value};return meetingCacheRoot()}
    func cancelSpeakerRefinement(cacheID:String?=nil) {
        let owner=workspaceOwner ?? self
        if let id=cacheID ?? currentCacheID {owner.pendingCoarseCutoffs.removeValue(forKey:id)}
        if cacheID==nil || cacheID==currentCacheID {coarseProgressTimer?.invalidate();coarseProcessingProgress=nil;coarseProcessingSummary=nil}
        if let cacheID,let saved=owner.savedCoarseJobs.removeValue(forKey:cacheID) {saved.cancel()}
        guard cacheID == nil || speakerRefinementScope?.cacheID==cacheID else{return}
        if let id=speakerRefinementScope?.cacheID,owner.savedCoarseJobs[id] === speakerRefinementJob {owner.savedCoarseJobs.removeValue(forKey:id)}
        speakerRefinementJob.cancel();speakerRefinementToken=nil;speakerRefinementScope=nil;speakerRefinementMessage=nil;coarseResultToken=nil
    }
    func detachSavedCoarseRefinement() {
        coarseProgressTimer?.invalidate();coarseProcessingProgress=nil;coarseProcessingSummary=nil
        let owner=workspaceOwner ?? self
        guard let id=speakerRefinementScope?.cacheID,owner.savedCoarseJobs[id] === speakerRefinementJob else{cancelSpeakerRefinement();return}
        // A new recording gets its own worker; the stopped meeting keeps its
        // already-authorized snapshot and can still commit to its own cache.
        speakerRefinementJob=SpeakerRefinementJob()
        speakerRefinementToken=nil;speakerRefinementScope=nil;speakerRefinementMessage=nil;coarseResultToken=nil
    }
    func cancelSpeakerRefinementForResume() {
        savedVoiceRecognitionJob.cancel()
        historyReader?.savedVoiceRecognitionJob.cancel()
        confirmationController?.cancelQuickInteraction();historyReader?.confirmationController?.cancelQuickInteraction()
        _=speakerRefinementLifecycle.resumed(session:activeSession)
        let owner=workspaceOwner ?? self
        if let id=speakerRefinementScope?.cacheID,owner.savedCoarseJobs[id] === speakerRefinementJob {
            // The paused batch keeps its worker and frozen boundary. Capture is
            // independent; its subsequent audio belongs to the next pause.
        } else if let id=currentCacheID,owner.savedCoarseJobs[id] != nil {
            // A batch started from another view still owns this same meeting.
        } else {cancelSpeakerRefinement()}
        coarseResultToken=nil;speakerRefinementFailureCode=nil;speakerRefinementFailureRevision=nil;if !speakerRefinementCheckMode {diagnostic.stringValue="录音继续中"}
    }
    func scheduleSpeakerRefinement(trigger:String,allowUnsealed:Bool=false) {
        if !Credential.offline || coarseRefinementExecutorOverride != nil {scheduleCoarseRefinement(trigger:trigger,allowUnsealed:allowUnsealed);return}
        guard (!sessionLocalOnly || trigger=="manual_recovery"),!quitting,!meetingDeletionBusy,
              let cacheID=currentCacheID,UUID(uuidString:cacheID) != nil,
              let session=activeSession,!session.isEmpty,
              phase.phase == .paused || phase.phase == .stopped,
              trigger != "pause" || phase.phase == .paused else{return}
        let folder=recoveryBase().appendingPathComponent(cacheID,isDirectory:true)
        let base=recoveryBase()
        let models=URL(fileURLWithPath:root).appendingPathComponent("native/local-speaker-install/runtime-models",isDirectory:true)
        let model=models.appendingPathComponent("community-1/Segmentation.mlmodelc",isDirectory:true)
        let qaHelper=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/会议采集离线QA.app/Contents/MacOS/MeetingCapture")
        let executable=Credential.offline && FileManager.default.isExecutableFile(atPath:qaHelper.path) ? qaHelper:URL(fileURLWithPath:root).appendingPathComponent("native/nightly-build/会议采集候选.app/Contents/MacOS/MeetingCapture")
        let executor=speakerRefinementExecutorOverride,requestObserver=speakerRefinementRequestOverride
        guard executor != nil ||
                (FileManager.default.isExecutableFile(atPath:executable.path) && FileManager.default.fileExists(atPath:model.path)) else{return}
        let token=speakerRefinementJob.reserve(),generation=meetingDocumentGeneration,revision=naming.correctionRevision
        speakerRefinementToken=token;speakerRefinementScope=(cacheID,session,generation,revision);speakerRefinementMessage=nil;speakerRefinementFailureCode=nil;speakerRefinementFailureRevision=nil;coarseResultToken=nil
        if !speakerRefinementCheckMode {diagnostic.stringValue="正在校正发言人…";updateUI()}
        persistSessionNames { [weak self] result in
            guard let self=self,self.speakerRefinementJob.isCurrent(token),self.currentCacheID==cacheID,
                  self.activeSession==session,self.meetingDocumentGeneration==generation,
                  self.naming.correctionRevision==revision else{return}
            guard case .success=result else {self.failSpeakerRefinement(token:token,cacheID:cacheID,session:session,generation:generation,revision:revision);return}
            // persistSessionNames has completed on the serial cache writer. Queue
            // the input snapshot behind it so helper reads a committed roster.
            self.cacheWriteQueue.async { [weak self] in
                guard let self=self,self.speakerRefinementJob.isCurrent(token) else{return}
                do {
                    let item=try cachedMeetings(in:base).first{$0.id==cacheID}
                    guard let meeting=item,meeting.directory.standardizedFileURL==folder.standardizedFileURL else{throw SpeakerRefinementArtifactError.invalidScope}
                    let metadata=try meeting.metadata()
                    guard metadata["session"] as? String==session else{throw SpeakerRefinementArtifactError.invalidScope}
                    let events=try meeting.events(includeAutomaticRefinement:false),hashes=try meeting.transcriptHashes()
                    guard !events.isEmpty,events.allSatisfy({$0["session"] as? String==session}) else{throw SpeakerRefinementArtifactError.invalidSnapshot}
                    let request:[String:Any]=["folder":folder.path,"session":session,"allow_unsealed":allowUnsealed]
                    requestObserver?(request)
                    let done:(UUID,Result<Data,Error>)->Void={ [weak self] returned,result in
                        guard let self=self else{return}
                        switch result {
                        case .failure(let error):DispatchQueue.main.async{self.failSpeakerRefinement(token:returned,cacheID:cacheID,session:session,generation:generation,revision:revision,error:error)}
                        case .success(let data):
                            self.cacheWriteQueue.async { [weak self] in
                                guard let self=self,self.speakerRefinementJob.isCurrent(returned) else{return}
                                do {
                                    let raw=try meeting.events(includeAutomaticRefinement:false)
                                    guard try meeting.transcriptHashes()==hashes else{throw SpeakerRefinementArtifactError.eventChanged}
                                    let prepared=try SpeakerRefinementArtifact.prepareValidated(data:data,events:raw,sourceHashes:hashes,directory:folder,cacheID:cacheID)
                                    try self.speakerRefinementJob.commitIfCurrent(returned) {
                                        try SpeakerRefinementArtifact.writePrepared(prepared)
                                    }
                                    DispatchQueue.main.async {
                                        self.finishSpeakerRefinement(token:returned,cacheID:cacheID,session:session,generation:generation,revision:revision,events:prepared.projectedEvents)
                                    }
                                } catch {
                                    DispatchQueue.main.async{self.failSpeakerRefinement(token:returned,cacheID:cacheID,session:session,generation:generation,revision:revision,error:error)}
                                }
                            }
                        }
                    }
                    if let injected=executor {injected(request,executable,models,token,done)}
                    else {_=self.speakerRefinementJob.start(request:request,executable:executable,models:models,reservedToken:token,done:done)}
                } catch {
                    DispatchQueue.main.async{self.failSpeakerRefinement(token:token,cacheID:cacheID,session:session,generation:generation,revision:revision,error:error)}
                }
            }
        }
    }
    func failSpeakerRefinement(token:UUID,cacheID:String,session:String,generation:Int,revision:Int,error:Error?=nil,job:SpeakerRefinementJob?=nil) {
        let job=job ?? speakerRefinementJob,owner=workspaceOwner ?? self
        guard job.isCurrent(token) else{return}
        if owner.savedCoarseJobs[cacheID] === job {owner.savedCoarseJobs.removeValue(forKey:cacheID)}
        if currentCacheID==cacheID {
            coarseProcessingProgress=nil;coarseProgressTimer?.invalidate()
            coarseProcessingSummary="这一段整理未完成，可重试；原音与原文保留"
        }
        if job !== speakerRefinementJob || currentCacheID != cacheID {
            saveCoarseStatus(cacheID:cacheID,session:session,state:"failed",error:error);owner.reloadLibrary();return
        }
        guard speakerRefinementToken==token,
              currentCacheID==cacheID,activeSession==session,meetingDocumentGeneration==generation else{return}
        speakerRefinementToken=nil;speakerRefinementScope=nil
        if error is SpeakerRefinementJobError && (error as? SpeakerRefinementJobError) == .cancelled {return}
        speakerRefinementFailureCode=coarseErrorCode(error)
        speakerRefinementFailureRevision=revision
        coarseResultToken=nil
        saveCoarseStatus(cacheID:cacheID,session:session,state:"failed",error:error)
        speakerRefinementMessage=Credential.offline ? "发言人校正未完成":coarseFailureMessage(error)
        if !speakerRefinementCheckMode {
            if naming.correctionRevision != revision {showTransientFeedback("姓名已更新；请再次暂停后校正")}
            else {showTransientFeedback(Credential.offline ? "发言人校正失败；已有结果保留，可在发言人窗口重新校正":"AI整理未完成；可在发言人窗口重试整理")}
            updateUI();refreshOpenSpeakerReview()
        }
    }
    func finishSpeakerRefinement(token:UUID,cacheID:String,session:String,generation:Int,revision:Int,events:[[String:Any]],coarseSourceSHA256:String?=nil,coarseSnapshotSHA256:String?=nil,job:SpeakerRefinementJob?=nil) {
        let job=job ?? speakerRefinementJob,owner=workspaceOwner ?? self
        guard job.isCurrent(token) else{return}
        if owner.savedCoarseJobs[cacheID] === job {owner.savedCoarseJobs.removeValue(forKey:cacheID)}
        let coarseWarning=events.first?["coarse_refinement_warning"] as? String
        let readingNotice=events.first?["reading_projection_notice"] as? String
        if currentCacheID==cacheID,coarseSourceSHA256 != nil {
            coarseProcessingProgress=nil;coarseProgressTimer?.invalidate()
            coarseProcessingSummary=coarseWarning == nil ? (readingNotice ?? "上一段已整理，可标记发言人"):"部分内容已整理，其余可重试；原文保留"
        }
        if coarseSourceSHA256 != nil {saveCoarseStatus(cacheID:cacheID,session:session,state:coarseWarning == nil ? "complete":"partial")}
        if job !== speakerRefinementJob || currentCacheID != cacheID {
            if let reader=owner.historyReader,reader.currentCacheID==cacheID,reader.activeSession==session {
                let completionSummary:String? = coarseSourceSHA256 == nil ? nil :
                    (coarseWarning == nil ? (readingNotice ?? "上一段已整理，可标记发言人"):"部分内容已整理，其余可重试；原文保留")
                reader.refreshSpeakerRefinementProjection(cacheID:cacheID,session:session,completionSummary:completionSummary)
            }
            owner.reloadLibrary();return
        }
        guard speakerRefinementToken==token,
              meetingDocumentGeneration==generation else{return}
        let sameDocument=(coarseSourceSHA256 != nil && activeSession==session && currentCacheID==cacheID) || speakerRefinementLifecycle.acceptsResult(session:activeSession,cacheID:currentCacheID,
            expectedSession:session,expectedCacheID:cacheID,phase:phase.phase,
            currentRevision:naming.correctionRevision,expectedRevision:revision)
        if sameDocument {
            if let source=coarseSourceSHA256,let snapshot=coarseSnapshotSHA256 {
                coarseResultToken=(cacheID,session,generation,revision,source,snapshot)
            }
            var changed=0
            for event in events {
                guard let id=event["segment_id"] as? String,let old=segments[id],
                      old["session"] as? String==session,old["revision"] as? Int==event["revision"] as? Int else{continue}
                // Keep explicitly named utterances exactly as the user left them.
                if naming.sentenceName(segment:id) != nil {continue}
                if speakerStateChanged(old,event) {changed+=1}
                timeline.put(event)
                naming.register(segment:id,item:event)
                for run in TranscriptTimeline.speakerRuns(event) {
                    let runID=TranscriptTimeline.runID(parent:id,run:run)
                    naming.register(segment:runID,item:run)
                }
                spokenRowsCache.removeValue(forKey:id);markTranscriptParentDirty(id)
            }
            let coarseWarning=events.first?["coarse_refinement_warning"] as? String
            saveCoarseStatus(cacheID:cacheID,session:session,state:coarseWarning == nil ? "complete":"partial")
            speakerRefinementMessage=coarseWarning ?? (Credential.offline ? (changed>0 ? "发言人已校正":"发言人校正完成，暂无新分组"):"文字与发言人已整理")
            if !speakerRefinementCheckMode {showTransientFeedback(speakerRefinementMessage ?? "整理完成")}
        }
        if let reader=historyReader,reader.currentCacheID==cacheID,reader.activeSession==session {
            let completionSummary:String? = coarseSourceSHA256 == nil ? nil :
                (coarseWarning == nil ? "上一段已整理，可标记发言人":"部分内容已整理，其余可重试；原文保留")
            reader.refreshSpeakerRefinementProjection(cacheID:cacheID,session:session,completionSummary:completionSummary)
        }
        speakerRefinementToken=nil;speakerRefinementScope=nil
        if !speakerRefinementCheckMode {updateUI();refreshOpenSpeakerReview()}
        scheduleSavedVoiceRecognition()
    }
    func speakerStateChanged(_ old:[String:Any],_ new:[String:Any])->Bool {
        func jsonEqual(_ lhs:Any?,_ rhs:Any?)->Bool {
            guard let lhs=lhs,let rhs=rhs,let left=try? JSONSerialization.data(withJSONObject:lhs,options:[.sortedKeys]),
                  let right=try? JSONSerialization.data(withJSONObject:rhs,options:[.sortedKeys]) else{return lhs == nil && rhs == nil}
            return left==right
        }
        return old["text"] as? String != new["text"] as? String || !jsonEqual(old["speaker"],new["speaker"]) || !jsonEqual(old["speaker_runs"],new["speaker_runs"])
    }
    func refreshSpeakerRefinementProjection(cacheID:String,session:String,completionSummary:String?=nil) {
        guard currentCacheID==cacheID,activeSession==session else{return}
        let base=recoveryBase()
        cacheReadJob.run(work:{
            guard let item=try cachedMeetings(in:base).first(where:{$0.id==cacheID}) else{throw SpeakerRefinementArtifactError.invalidScope}
            return try item.events()
        }){[weak self] result in
            guard let self=self,self.currentCacheID==cacheID,self.activeSession==session,
                  case .success(let events)=result else{return}
            for event in events {guard let id=event["segment_id"] as? String,let old=self.segments[id],old["revision"] as? Int==event["revision"] as? Int else{continue};self.timeline.put(event);self.naming.register(segment:id,item:event);for run in TranscriptTimeline.speakerRuns(event){self.naming.register(segment:TranscriptTimeline.runID(parent:id,run:run),item:run)};self.spokenRowsCache.removeValue(forKey:id);self.markTranscriptParentDirty(id)}
            self.renderText()
            if let completionSummary,!self.hasRunningCoarseRefinement {
                self.coarseProgressTimer?.invalidate();self.coarseProgressTimer=nil
                self.coarseProcessingProgress=nil;self.coarseProcessingSummary=completionSummary
            }
            self.updateUI();self.refreshOpenSpeakerReview()
            self.scheduleSavedVoiceRecognition()
        }
    }
    var canRetrySpeakerRefinement:Bool {
        guard [.paused,.stopped,.failed].contains(phase.phase),!sessionLocalOnly,!resumeBusy,
              speakerRefinementToken==nil,currentCacheID != nil,
              workspaceOwner?.recordingBusy != true else{return false}
        if let id=currentCacheID,(workspaceOwner ?? self).savedCoarseJobs[id] != nil {return false}
        return !sequence.isEmpty
    }
    @objc func retrySpeakerRefinement() {
        guard canRetrySpeakerRefinement else{return}
        scheduleSpeakerRefinement(trigger:"manual_retry",allowUnsealed:phase.phase == .paused)
        refreshOpenSpeakerReview()
    }
    @objc func showRecoveries(){
        if !previewRenderOnly {sidebarManualVisible=true;layoutWorkspace();reloadLibrary();return}
        guard child==nil,!resumeBusy else{diagnostic.stringValue="正在处理本场；请停止后再恢复其他会话";return}
        laterRecovery();diagnostic.stringValue="正在读取历史会议"
        let base=recoveryBase();cacheReadJob.run(work:{try cachedMeetings(in:base)}){[weak self] result in guard let self=self else{return};switch result {case .success(let items):self.recoveries=items;self.presentRecoveries();case .failure(let error):self.phase.error=cacheFailureMessage(error);self.diagnostic.stringValue="无法读取历史会议，请检查文件访问权限";self.updateUI()}}
    }
    func presentRecoveries(){
        guard !recoveries.isEmpty else{diagnostic.stringValue=offlineQA ? "新假会话缓存没有记录；旧Documents夹具未读取，访问需本人确认":"还没有会议记录";return}
        recoveryPanel=NSPanel(contentRect:NSRect(x:0,y:0,width:480,height:240),styleMask:[.titled],backing:.buffered,defer:false);recoveryPanel!.title=offlineQA ? "新假会话 · 旧Documents夹具未读取":"历史会议"
        let picker=FocusPopup(frame:NSRect(x:24,y:170,width:432,height:28));picker.target=self;picker.action=#selector(changeRecoverySelection);for item in recoveries {let entry=NSMenuItem(title:item.label,action:nil,keyEquivalent:"");entry.representedObject=item.id;picker.menu!.addItem(entry)};recoveryPicker=picker;recoveryPanel!.contentView!.addSubview(picker)
        let detail=label("",size:13);detail.frame=NSRect(x:24,y:83,width:432,height:72);recoveryDetail=detail;recoveryPanel!.contentView!.addSubview(detail)
        let original=ImmediateButton(title:"查看已有原文",target:self,action:#selector(viewRecoveryOriginal));original.frame=NSRect(x:24,y:24,width:130,height:32);recoveryPanel!.contentView!.addSubview(original);recoveryOriginal=original
        let restore=ImmediateButton(title:"恢复原音",target:self,action:#selector(restoreRecoveryAudio));restore.frame=NSRect(x:164,y:24,width:108,height:32);recoveryPanel!.contentView!.addSubview(restore);recoveryRestore=restore
        let later=ImmediateButton(title:"稍后",target:self,action:#selector(laterRecovery));later.frame=NSRect(x:278,y:24,width:70,height:32);recoveryPanel!.contentView!.addSubview(later)
        let next=ImmediateButton(title:"补转剩余录音",target:self,action:#selector(continueRecovery));next.frame=NSRect(x:350,y:24,width:106,height:32);recoveryPanel!.contentView!.addSubview(next);recoveryContinue=next
        changeRecoverySelection();if !previewRenderOnly {window.beginSheet(recoveryPanel!)}
    }
    func selectedRecovery()->CachedMeeting? {guard let id=recoveryPicker?.selectedItem?.representedObject as? String else{return nil};return recoveries.first{$0.id==id}}
    @objc func changeRecoverySelection(){cacheReadJob.cancel();guard let item=selectedRecovery() else{return};recoveryDetail?.stringValue="会话 "+String(item.id.prefix(8))+"\n"+item.details;recoveryPicker?.selectedItem?.title=item.label;recoveryContinue?.title=item.pendingBytes>0 ? "补转剩余录音":"打开原文";recoveryRestore?.isEnabled=item.audioCleaned && item.retiredBytes>0;recoveryContinue?.toolTip="保留已有原文，只把尚未转成文字的录音上传转写；不会开始录音。"}
    @objc func restoreRecoveryAudio(){
        guard child==nil,!resumeBusy,!processingAudio,let item=selectedRecovery(),item.audioCleaned,item.retiredBytes>0 else{return}
        let alert=NSAlert();alert.messageText="恢复录音？";alert.informativeText="恢复后可继续转写。\n\n录音位置：\n"+(item.retiredLocation ?? "位置不可用");alert.addButton(withTitle:"恢复原音");alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        restoreRecoveryAudioConfirmed(item)
    }
    func restoreRecoveryAudioConfirmed(_ item:CachedMeeting){
        let allowed=recoveryBase().appendingPathComponent(".retired")
        recoveryRestore?.isEnabled=false;diagnostic.stringValue="正在恢复录音"
        cacheExportJob.run(work:{try restoreRetiredAudioAt(item.directory,sessionBase:self.recoveryBase(),allowedRetiredBase:allowed);return try cachedMeetings(in:self.recoveryBase()).first{$0.id==item.id}}){[weak self] result in
            guard let self=self else{return};switch result {
            case .success(let restored):if let restored=restored,let index=self.recoveries.firstIndex(where:{$0.id==item.id}) {self.recoveries[index]=restored;self.changeRecoverySelection()};self.diagnostic.stringValue="录音已恢复"
            case .failure(let error):self.diagnostic.stringValue=(error as? Failure)?.code=="cache_restore_conflict" ? "录音已存在，无需恢复":"录音恢复失败，请检查文件是否可访问";self.recoveryDetail?.stringValue=self.diagnostic.stringValue
                if !self.previewRenderOnly {let alert=NSAlert();alert.messageText="原音恢复未完成";alert.informativeText=self.diagnostic.stringValue+"\n录音位置：\n"+(item.retiredLocation ?? "位置不可用")+"\n会议位置：\n"+item.directory.path+"";alert.addButton(withTitle:"关闭");alert.runModal()}
            };self.updateUI()
        }
    }
    @objc func laterRecovery(){cacheReadJob.cancel();if let panel=recoveryPanel {if panel.sheetParent != nil {window.endSheet(panel)};panel.orderOut(nil)};recoveryPanel=nil}
    func importRecovery(_ item:CachedMeeting)throws {try applyRecovery(item,payload:RecoveryPayload(item))}
    func applyRecovery(_ item:CachedMeeting,payload:RecoveryPayload)throws {
        if currentCacheID != item.id {detachSavedCoarseRefinement()}
        let wasDeferred=deferPresentation,wasReplayingHistory=replayingHistory;deferPresentation=true;replayingHistory=true
        defer {replayingHistory=wasReplayingHistory;deferPresentation=wasDeferred;if !wasDeferred && recoveredArchiveText==nil {renderText();updateUI()};scheduleSavedVoiceRecognition()}
        let events=payload.events;let preserveNames=currentCacheID==item.id;sourceActivity=SourceActivity();segments=[:];sequence=[];expandedParents=[:];if !preserveNames {naming.reset()};transcriptCapacity.reset();transcriptLimitHit=false;recoveredArchiveText=nil
        meetingTitle=item.displayTitle
        currentCacheID=item.id;cachedTranscriptionComplete=item.transcriptionComplete
        phase=UIState();phase.phase = .stopped;phase.elapsed=item.durationSeconds;let metadata=payload.metadata;sessionLocalOnly=metadata["capture_mode"] as? String=="local_only" && metadata["upload_authorized"] as? Bool != true;activeSession=metadata["session"] as? String ?? events.first?["session"] as? String ?? item.id
        resetVoiceprintRecommendations(session:activeSession)
        absoluteTime=MeetingAbsoluteTime(metadata["absolute_clock"])
        let bundle=metadata["bundle"] as? String ?? events.first?["application"] as? String
        switch bundle {case "*microphone*":sessionSource="仅麦克风";case "*system*":sessionSource="电脑声音（含浏览器）";case "com.tencent.meeting":sessionSource="腾讯会议声音";default:sessionSource="来源未记录"}
        if bundle != "*microphone*",item.tracks.contains("mic") {sessionSource += " + 麦克风"}
        source.stringValue="本地会话 · "+item.label
        for event in events {receive(event)}
        speakerRefinementMessage=events.first?["coarse_refinement_warning"] as? String
        coarseProcessingProgress=nil;coarseProcessingSummary=nil
        if let status=payload.coarseStatus,status["session"] as? String==activeSession,!hasRunningCoarseRefinement {
            switch status["state"] as? String {
            case "failed","partial":coarseProcessingSummary="部分内容尚未整理，可重试"
            case "running":coarseProcessingSummary="上次整理中断，可重试"
            case "cancelled":coarseProcessingSummary="整理已停止"
            case "complete" where showsCoarseProjection:coarseProcessingSummary=events.first?["reading_projection_notice"] as? String ?? "上一段已整理，可标记发言人"
            default:break
            }
        }
        if let warning=events.first?["speaker_reconciliation_warning"] as? String {phase.error=warning;diagnostic.stringValue=warning}
        if !preserveNames,let names=payload.names,let session=activeSession {try naming.restore(names,session:session,events:events,directory:item.directory);if naming.restoredAutoNameInvalidated {persistSessionNames();reloadLibraryAfterVoiceprintNameWrite()};spokenRowsCache.removeAll();markAllTranscriptParentsDirty()}
        if let archive=payload.archive,events.isEmpty {recoveredArchiveText=archive;output.string=archive;empty.isHidden=true}
        else {renderText()}
    }
    func readRecovery(_ item:CachedMeeting,done:@escaping(RecoveryPayload)->Void){diagnostic.stringValue="正在读取原文";cacheReadJob.run(work:{try RecoveryPayload(item)}){[weak self] result in guard let self=self else{return};switch result {case .success(let payload):done(payload);case .failure(let error):self.phase.error=cacheFailureMessage(error);self.recoveryDetail?.stringValue=self.phase.error ?? "本地文件读取失败";self.diagnostic.stringValue=self.phase.error!;self.updateUI()}}}
    @objc func viewRecoveryOriginal(){guard let item=selectedRecovery(),!resumeBusy else{return};readRecovery(item){[weak self] payload in guard let self=self else{return};do {try self.applyRecovery(item,payload:payload);self.laterRecovery();self.diagnostic.stringValue=item.pendingBytes>0 ? "已打开原文，部分录音待转写":"已打开原文"}catch{self.recoveryDetail?.stringValue="无法读取原文，请重试"}}}
    @objc func continueRecovery(){
        guard !meetingDeletionBusy,!audioAssetOperationBusy,!resumeBusy,child==nil,let item=selectedRecovery() else{return}
        if item.pendingBytes==0 {viewRecoveryOriginal();return}
        let remaining=Credential.offline ? (recoveryBudgetOverride ?? 0):remainingSeconds()
        guard remaining>0 || (!Credential.offline && Bundle.main.object(forInfoDictionaryKey:"LocalRecordingAllowed") as? Bool==true) else{recoveryDetail?.stringValue=item.details+"\n本次转写额度已用完；原音保留，可稍后继续。";diagnostic.stringValue="转写用量已达上限，录音已保留";return}
        readRecovery(item){[weak self] payload in self?.continueLoadedRecovery(item,payload:payload)}
    }
    func continueLoadedRecovery(_ item:CachedMeeting,payload:RecoveryPayload){
        guard !audioAssetOperationBusy,!resumeBusy,child==nil else{return}
        do {
            let metadata=payload.metadata;let localPending=metadata["capture_mode"] as? String=="local_only" && metadata["upload_authorized"] as? Bool != true;let independent=metadata["cloud_session_authorized"] as? Bool==true || localPending
            guard let bundle=metadata["bundle"] as? String,["com.tencent.meeting","*microphone*","*system*"].contains(bundle),metadata["asr_model"] as? String=="qwen-audio-3.0-asr-flash-streaming",metadata["asr_destination"] as? String=="dashscope.aliyuncs.com" || localPending else{recoveryDetail?.stringValue="录音信息不完整，暂时无法转写";return}
            if localPending && !Credential.offline {let alert=NSAlert();alert.messageText="转写这场录音？";alert.informativeText="录音将上传至云端生成文字。\n\n转写后自动整理文字与发言人，费用按实际用量统计，可随时停止。";alert.addButton(withTitle:"上传并转写");alert.addButton(withTitle:"取消");guard alert.runModal() == .alertFirstButtonReturn else{return}}
            if !Credential.offline && !independent && remainingSeconds()<=0 {recoveryDetail?.stringValue="转写用量已达上限，录音已保留";return}
            // Original cloud sessions retain their confirmed scope; local-only audio needs explicit upload confirmation.
            try applyRecovery(item,payload:payload);resumeBusy=true;recoveryContinue?.isEnabled=false;laterRecovery();phase.phase = .stopping;processingAudio=true;updateUI()
            if Credential.offline {guard let runner=recoveryRunnerOverride else{resumeBusy=false;processingAudio=false;throw Failure(code:"offline_recovery_no_runner")};runner(item);return}
            sourceBundle=bundle;confirmedScope=true;useMic=true
            credentialReadJob.onStateChange={ [weak self] in self?.updateUI() }
            credentialReadJob.run(timeout:15,work:{try Credential.load()}){[weak self] result in
                guard let self=self,self.resumeBusy else{return}
                switch result {
                case .success(let value):
                    guard let secret=value,!secret.isEmpty else{self.resumeBusy=false;self.processingAudio=false;self.phase.phase = .failed;self.phase.error="已存密钥不可用；原音保留";self.updateUI();return}
                    self.titleProvider=DashScopeMeetingTitleProvider(apiKey:secret);self.titleTextAllowed=true
                    var request=self.startRequest(secret);request["resume_cache_id"]=item.id
                    if independent {request["cloud_session_confirmed"]=true};if localPending {request["resume_upload_confirmed"]=true}
                    self.startWorker(secret,overrideRequest:request)
                case .failure:
                    self.resumeBusy=false;self.processingAudio=false;self.phase.phase = .failed;self.phase.error="钥匙串读取未完成；原音保留，未上传";self.updateUI()
                }
            }
        }catch{resumeBusy=false;processingAudio=false;phase.phase = .failed;phase.error="本地恢复未启动；音频保留";updateUI()}
    }
    func beginPreparation() {
        guard !mock,child==nil,remainingSeconds()>0 else {return}
        preparingModels=true;modelsPrepared=false;preparationElapsed=0;preparationTrack="mic";phase.error=nil;phase.phase = .connecting;speakerLoading=false;updateUI();startWorker(nil)
    }
    func startRequest(_ secret:String)->[String:Any] {
        var request:[String:Any]=["key":secret,"bundle":sourceBundle,"mic_enabled":useMic,"speaker_enabled":true,"human_identity_confirmed":humanIdentityAuthorized,"source_scope_confirmed":confirmedScope,"user_launch_confirmed":true,"candidate_mode":trialCandidate]
        if let snapshot=identitySnapshot {if trialCandidate {request["candidate_people"]=["people":snapshot["people"] ?? [:],"consents":snapshot["consents"] ?? [:]]}else{request["identity_snapshot"]=snapshot}}
        return request
    }
    func sendStartRequest(_ secret:String) {
        guard !quitting,modelsPrepared,let input=workerInput,child?.isRunning==true else {phase.phase = .failed;phase.error="准备已中断，请重试";updateUI();return}
        do {try input.write(contentsOf:JSONSerialization.data(withJSONObject:startRequest(secret))+Data([10]));modelsPrepared=false}
        catch {phase.phase = .failed;phase.error="未能开始记录，请重试";updateUI()}
    }
    func startWorker(_ secret:String?,overrideRequest:[String:Any]?=nil) {
        guard !quitting else{return}
        // Reset at the new job boundary. A delayed `started` event from a job
        // already cancelled by the user must not clear that cancellation.
        suppressAutomaticRefinementAfterStop=false
        (workspaceOwner ?? self).stopSpeakerAudioPreview()
        if Credential.offline && previewRenderOnly,let fixture=startupWorkerFixture,let request=overrideRequest {fixture(request);return}
        guard !Credential.offline else{phase.phase = .failed;phase.error="离线入口禁止启动生产工作进程";updateUI();return}
        let proc=Process();let stdin=Pipe();let stdout=Pipe();proc.executableURL=URL(fileURLWithPath:"/usr/local/bin/python3");proc.arguments=["-u",root+"/gui_worker.py"]
        if Bundle.main.object(forInfoDictionaryKey:"CandidateRevision") as? String=="repair" {proc.arguments!.append("--candidate-repair")}
        if Bundle.main.object(forInfoDictionaryKey:"CandidateRevision") as? String=="nightly" {proc.arguments!.append("--candidate-nightly")}
        var env=RuntimeConfiguration.childEnvironment();for name in ["DASHSCOPE_API_KEY","ALIYUN_API_KEY","BAILIAN_API_KEY"] {env.removeValue(forKey:name)};env["PYTHONDONTWRITEBYTECODE"]="1";env["MEETING_GUI"]="1";proc.environment=env
        proc.standardInput=stdin;proc.standardOutput=stdout;proc.standardError=FileHandle.nullDevice
        readLock.lock();workerGeneration=UUID();let generation=workerGeneration;pending=Data();readLock.unlock()
        buffer=Data();workerExitReceived=false;workerEOFReceived=false
        proc.terminationHandler={ [weak self] _ in DispatchQueue.main.async {
            guard let self,self.workerGeneration==generation else{return}
            self.workerExitReceived=true;self.completeWorkerIfDrained()
        }}
        do {try proc.run();child=proc;let request:[String:Any]=overrideRequest ?? secret.map{startRequest($0)} ?? ["mode":"prepare","candidate_mode":true];let data=try JSONSerialization.data(withJSONObject:request);try stdin.fileHandleForWriting.write(contentsOf:data+Data([10]));workerInput=stdin.fileHandleForWriting
            DispatchQueue.global(qos:.userInitiated).async {[weak self] in
                // One reader owns the pipe through EOF; termination cannot drop
                // the last batch of events or release a new meeting prematurely.
                while true {
                    let data=stdout.fileHandleForReading.availableData
                    guard !data.isEmpty else{break}
                    guard let self else{return}
                    self.readLock.lock()
                    guard self.workerGeneration==generation else{self.readLock.unlock();return}
                    let overflow=self.pending.count+data.count>4_000_000
                    if !overflow {self.pending.append(data)}
                    let schedule = !overflow && !self.drainScheduled
                    if schedule {self.drainScheduled=true};self.readLock.unlock()
                    if overflow {DispatchQueue.main.async {[weak self] in guard let self,self.workerGeneration==generation else{return};self.phase.error="文字显示跟不上，已停止。请重新开始";self.end()}}
                    else if schedule {DispatchQueue.main.async {[weak self] in guard let self,self.workerGeneration==generation else{return};self.drain()}}
                }
                DispatchQueue.main.async {[weak self] in guard let self,self.workerGeneration==generation else{return};self.workerEOFReceived=true;self.drain()}
            }
        }
        catch {phase.phase = .failed;phase.error="无法启动，请重新开始";child=nil;updateUI()}
    }
    func completeWorkerIfDrained() {
        guard workerExitReceived,workerEOFReceived else{return}
        readLock.lock();let hasPending = !pending.isEmpty;readLock.unlock()
        guard !hasPending,!buffer.contains(10) else{scheduleBufferedDrainIfNeeded();return}
        workerExitReceived=false;workerEOFReceived=false;buffer=Data()
        // A healthy paused recorder remains alive. EOF without a terminal
        // receipt is an interruption, even if its saved audio can be recovered.
        if [.connecting,.recording,.paused].contains(phase.phase) {
            phase.phase = .failed;phase.error="录音进程意外退出；原音和已有文字保留"
        }
        child=nil;resumeBusy=false;processingAudio=false;workerInput=nil;recordingControlTimeout?.cancel();recordingControlInFlight=nil
        if preparingModels {phase.phase = .failed;phase.error="准备已中断，请重试"}
        preparingModels=false;modelsPrepared=false;speakerLoading=false
        if phase.phase != .failed && phase.phase != .ended {phase.phase = .stopped}
        updateUI();finalizeSessionTitle();finishPendingNewMeetingIfReady()
        if let pending=pendingAutomaticTailRecovery {
            pendingAutomaticTailRecovery=nil
            startAutomaticTailRecovery(reason:pending.reason,cacheID:pending.cacheID,session:pending.session)
        }
        completeApplicationTerminationIfReady()
    }
    func startAutomaticTailRecovery(reason:String,cacheID:String,session:String) {
        guard ["capture_control_timeout_pause","capture_control_timeout_pause_drain",
               "capture_control_timeout_finish"].contains(reason),
              !quitting,!meetingDeletionBusy,!sessionLocalOnly,!resumeBusy,child==nil,
              currentCacheID==cacheID,activeSession==session,
              automaticTailRecoveryAttempted.insert(cacheID).inserted else{return}
        let base=recoveryBase()
        diagnostic.stringValue="采集已停止，正在补齐已保存录音"
        cacheReadJob.run(work:{
            guard let item=try cachedMeetings(in:base).first(where:{$0.id==cacheID}) else{throw Failure(code:"automatic_tail_cache_missing")}
            guard item.pendingBytes>0 else{return nil as (CachedMeeting,RecoveryPayload)?}
            return (item,try RecoveryPayload(item))
        }){[weak self] result in
            guard let self=self,self.currentCacheID==cacheID,self.activeSession==session,
                  !self.quitting,!self.meetingDeletionBusy,self.child==nil,!self.resumeBusy else{return}
            switch result {
            case .success(let recovery):
                guard let (item,payload)=recovery,item.pendingBytes>0 else{return}
                self.continueLoadedRecovery(item,payload:payload)
            case .failure:
                self.diagnostic.stringValue="录音已停止；尾部暂未补齐，原音保留，可手动补转"
            }
        }
    }
    func drain() {
        var presentationChanged=false
        let wasDeferred=deferPresentation;deferPresentation=true
        defer {deferPresentation=wasDeferred;if !wasDeferred {if presentationChanged {if !dirtyTranscriptParents.isEmpty || fullTranscriptRefreshPending {scheduleTranscriptRender()};updateUI()};scheduleBufferedDrainIfNeeded();completeWorkerIfDrained()}}
        readLock.lock();buffer.append(pending);pending=Data();drainScheduled=false;readLock.unlock()
        guard buffer.count<=4_000_000 else {buffer=Data();phase.error="文字显示跟不上，已停止。请重新开始";end();return}
        let deadline=ProcessInfo.processInfo.systemUptime+0.012;var processed=0
        while processed < (mock ? Int.max:64),ProcessInfo.processInfo.systemUptime<deadline,let edge=buffer.firstIndex(of:10) {
            let row=Data(buffer[..<edge]);buffer.removeSubrange(...edge)
            if let event=(try? JSONSerialization.jsonObject(with:row)) as? [String:Any] {if event["type"] as? String != "audio_levels" {presentationChanged=true};receive(event)}
            else if let text=String(data:row,encoding:.utf8),text.contains("状态：") {
                presentationChanged=true
                if text.contains("腾讯会议未运行") {phase.phase = .failed;phase.error="先打开腾讯会议，再点开始"}
                else if text.contains("预算已耗尽") || text.contains("本场转写用量已达上限") {phase.phase = .ended}
                else if text.contains("失败"),phase.phase != .failed {phase.phase = .failed;phase.error=workerFailureMessage("worker_preflight_failed")}
            };processed+=1
        }
    }
    func scheduleBufferedDrainIfNeeded(){
        guard buffer.contains(10) else{return}
        readLock.lock();let schedule = !drainScheduled;if schedule {drainScheduled=true};readLock.unlock()
        let generation=workerGeneration
        if schedule {DispatchQueue.main.async{[weak self] in guard let self,self.workerGeneration==generation else{return};self.drain()}}
    }
    func scheduleTranscriptRender(){
        guard !dirtyTranscriptParents.isEmpty || fullTranscriptRefreshPending else{return}
        transcriptRenderPending=true
        guard !transcriptRenderScheduled else{return}
        transcriptRenderScheduled=true
        // Coalesce ordinary live updates; drain bounded backlog slices without
        // adding 120 ms of idle time to every 24-parent rebuild batch.
        let backlog=fullTranscriptRefreshPending || dirtyTranscriptQueue.count-dirtyTranscriptQueueIndex>24
        let delay=backlog ? 0.001:max(0,0.12-Date().timeIntervalSince(lastTranscriptRender))
        DispatchQueue.main.asyncAfter(deadline:.now()+delay){[weak self] in
            guard let self=self else{return};self.transcriptRenderScheduled=false
            guard self.transcriptRenderPending else{return};self.transcriptRenderPending=false
            self.renderText();self.lastTranscriptRender=Date()
        }
    }
    func receive(_ event:[String:Any],workerID:UUID?=nil) {
        if let workerID,workerID != workerGeneration {return}
        // A saved worker cannot turn a newly created blank workspace into a
        // stopped meeting. Starting capture is owned by the explicit Start action.
        if activeSession==nil,currentCacheID==nil,child==nil,phase.phase == .idle,
           sequence.isEmpty,recoveredArchiveText==nil,
           ["stopped","capture_stopped","processing_started"].contains(event["type"] as? String ?? "") {return}
        if event["type"] as? String != "started",let incoming=event["session"] as? String,let current=activeSession,incoming != current {return}

        if !Credential.offline {recordingAttention.observe(event)}
        if event["type"] as? String == "identity_candidate" {
            guard identityCandidatesEnabled,let id=event["segment_id"] as? String,let segment=segments[id],let person=event["person_id"] as? String,people[person] != nil,
                  let revision=event["calibration_version"] as? String,!revision.isEmpty,event["quality_ok"] as? Bool == true,event["overlap"] as? Bool == false,
                  event["session"] as? String == segment["session"] as? String else{return}
            guard event["segment_revision"] as? Int == segment["revision"] as? Int,event["epoch"] as? String == segment["epoch"] as? String,event["source_id"] as? String == segment["source_id"] as? String else{return}
            candidateBySegment[id]=(person,revision,event["segment_revision"] as? Int ?? 0);return
        }

        let type=event["type"] as? String ?? ""
        let wasRecoveryRun=type=="stopped" && resumeBusy
        if type=="stopped" || type=="error" {recordingControlTimeout?.cancel();recordingControlInFlight=nil}
        if type=="error" {cancelSpeakerRefinement()}
        if type=="audio_levels" {receiveAudioLevels(event);return}
        if type=="started" {pausedTailStates=[:];pausedTailRevision=nil;lastRecordingControlRevision = -1}
        if type=="capture_status" {if let incoming=event["session"] as? String,let current=activeSession,incoming != current {return};sourceActivity.receive(event);updateUI();return}
        if type=="recording_paused" || type=="recording_resumed" {
            guard event["session"] as? String == activeSession else{return}
            let action=type=="recording_paused" ? "pause":"resume"
            let userRequestedPause=recordingControlInFlight=="pause"
            let devicePause=action=="pause" && ["input_device_changed","mic_conversion_backpressure"].contains(event["reason"] as? String ?? "")
            guard [.recording,.paused].contains(phase.phase),recordingControlInFlight==nil || recordingControlInFlight==action || devicePause else{return}
            if let revision=event["control_revision"] as? Int {
                guard revision>lastRecordingControlRevision else{return}
                lastRecordingControlRevision=revision
            } else {guard mock || Credential.offline else{return}}
            if action=="resume",let clock=MeetingAbsoluteTime(event["absolute_clock"]) {absoluteTime=clock}
            if action=="resume" {cancelSpeakerRefinementForResume();invalidateMeetingArchivePreparationOnResume()}
            recordingControlTimeout?.cancel();recordingControlInFlight=nil
            notesPausedRelative=action=="pause" ? event["recording_elapsed_seconds"] as? Double:nil
            phase.phase=action=="pause" ? .paused:.recording
            pausedTailStates=[:];pausedTailRevision=action=="pause" ? event["control_revision"] as? Int:nil
            if action=="pause",let tracks=event["draining_tracks"] as? [String] {for track in tracks where isTranscriptAudioTrack(track) {pausedTailStates[track]="processing"}}
            if let elapsed=event["recording_elapsed_seconds"] as? Double,elapsed.isFinite,elapsed>=0 {phase.elapsed=max(phase.elapsed,elapsed)}
            diagnostic.stringValue=action=="pause" ? (sessionLocalOnly ? "录音已暂停并保存；再次点录音继续同一场":"录音已暂停，正在补齐已录内容的转写；再次点录音继续同一场"):"已继续录音"
            if action=="pause",event["reason"] as? String=="input_device_changed",!userRequestedPause {
                // Switching to headphones changes the default microphone. Resume on the
                // new device automatically; keep paused only if the device keeps flapping.
                let now=ProcessInfo.processInfo.systemUptime
                deviceAutoResumeTimes=deviceAutoResumeTimes.filter{now-$0<60}
                if deviceAutoResumeTimes.count<3 {
                    deviceAutoResumeTimes.append(now)
                    diagnostic.stringValue="输入设备已切换，正在用新麦克风接着录"
                    let revision=lastRecordingControlRevision,session=activeSession
                    // A run-loop timer (not a main-queue block) so it also fires while a
                    // nested run loop is spinning, e.g. inside a modal flow or a check.
                    Timer.scheduledTimer(withTimeInterval:1.5,repeats:false) { [weak self] _ in
                        guard let self,self.phase.phase == .paused,self.activeSession==session,
                              self.lastRecordingControlRevision==revision,self.recordingControlInFlight==nil,
                              !self.newMeetingRequested,!self.quitting else{return}
                        self.sendRecordingControl("resume")
                    }
                } else {
                    diagnostic.stringValue="麦克风反复切换，录音已暂停；请确认麦克风后点继续，接上本场录音"
                }
            }
            if action=="pause",event["reason"] as? String=="mic_conversion_backpressure" {diagnostic.stringValue="声音处理暂时跟不上，已暂停；有短暂缺口，已录内容保留。点继续接上本场录音"}
            if action=="pause" && (event["reason"] as? String != "input_device_changed" || userRequestedPause) {
                // Reuse the existing tail completion event; no separate timer
                // or pre-tail title request while the transcript is draining.
                if !pausedTailStates.values.contains("processing") {scheduleAutoTitle()}
                reloadLibrary()
                if Credential.offline && coarseRefinementExecutorOverride==nil {scheduleSavedVoiceRecognition()}
                if !pausedTailStates.values.contains("processing") && (!Credential.offline || coarseRefinementExecutorOverride != nil) {
                    scheduleCoarseRefinement(trigger:"pause",allowUnsealed:true,cutoff:phase.elapsed)
                }
            }
            updateUI();return
        }
        if type=="recording_pause_tail" {
            guard event["session"] as? String==activeSession,phase.phase == .paused,
                  let revision=pausedTailRevision,event["pause_revision"] as? Int==revision,
                  let track=event["track"] as? String,pausedTailStates[track] != nil,
                  let state=event["state"] as? String,["complete","pending"].contains(state) else{return}
            pausedTailStates[track]=state
            if !pausedTailStates.values.contains("processing") {
                // Title freshness must not depend on which refinement backend
                // runs, or whether refinement succeeds.
                scheduleAutoTitle()
                if Credential.offline && coarseRefinementExecutorOverride==nil {scheduleSavedVoiceRecognition()}
                if !speakerRefinementCheckMode {diagnostic.stringValue=pausedTailStates.values.contains("pending") ? "录音已暂停；部分转写未完成，原音保留，可重试转写":"录音已暂停；已录内容已自动转写完成"}
                if (!Credential.offline || coarseRefinementExecutorOverride != nil) {
                    scheduleCoarseRefinement(trigger:"pause_tail",allowUnsealed:true,cutoff:phase.elapsed)
                } else if !pausedTailStates.values.contains("pending"),let revision=pausedTailRevision,
                   speakerRefinementLifecycle.pauseTailCompleted(session:activeSession,revision:revision,states:pausedTailStates,localOnly:sessionLocalOnly) {
                    scheduleSpeakerRefinement(trigger:"pause",allowUnsealed:true)
                }
                if !speakerRefinementCheckMode {reloadLibrary()}
            }
            if !speakerRefinementCheckMode {updateUI()};return
        }
        if type=="echo_status" {
            guard event["track"] as? String=="mic" else{return}
            if let incoming=event["session"] as? String, incoming != activeSession {return}
            let state=event["state"] as? String ?? ""
            switch state {
            case "processed":echoStatusLabel="麦克风回声处理正常"
            case "processed_with_raw_edges","processedWithRawEdges":echoStatusLabel="部分声音未消除回声，外放可能重复"
            case "reference_recovered","referenceRecovered":echoStatusLabel="回声参考已恢复，正在处理"
            case "reference_unavailable","referenceUnavailable":echoStatusLabel="回声参考暂不可用，外放可能重复；可使用耳机"
            case "reference_misaligned","referenceMisaligned":echoStatusLabel="回声参考未对齐，外放可能重复；可使用耳机"
            case "model_unavailable","modelUnavailable":echoStatusLabel="回声处理不可用，外放可能重复；可使用耳机"
            case "processing_failed","processingFailed","timeline_discontinuity","timelineDiscontinuity","bufferedForModelLatency","invalidInput":echoStatusLabel="麦克风回声处理异常；保留原声"
            default:echoStatusLabel=""
            }
            updateSourceActivity();return
        }
        if type=="audio_source" {
            let id=event["source_id"] as? String ?? ""
            let state=event["state"] as? String ?? ""
            let coreID=event["core_source_id"] as? String ?? applicationAudioCoreID(id) ?? id
            if state=="capture_unavailable" {
                unavailableAppSourceIDs.insert(coreID)
                let label=audioSourceLabel(event)
                sourceCaptureGapLabels.insert(label)
            } else if state=="capture_recovered" {
                unavailableAppSourceIDs.remove(coreID)
                if event["had_capture_gap"] as? Bool==true {
                    let label=audioSourceLabel(event)
                    sourceCaptureGapLabels.insert(label)
                }
            }
            if isTranscriptAudioTrack(id),id != "mic" {
                let label=audioSourceLabel(event)
                if state=="inactive" {observedAppSources.removeValue(forKey:id)} else {observedAppSources[id]=label}
            }
            updateSourceActivity();return
        }
        if type=="preparation" {
            let state=event["state"] as? String ?? "failed"
            preparationElapsed=event["elapsed_seconds"] as? Double ?? preparationElapsed;preparationTrack=event["track"] as? String ?? preparationTrack
            if state=="ready" {preparingModels=false;modelsPrepared=true;phase.error=nil;phase.phase = .idle;diagnostic.stringValue="准备就绪"}
            else if state=="failed" {preparingModels=false;modelsPrepared=false;phase.phase = .failed;phase.error=friendly(event["code"] as? String ?? "model_preparation_failed")}
            updateUI();return
        }
        if trialCandidate && type=="identity_state" && [.stopped,.failed,.ended].contains(phase.phase) {return}
        if type=="identity_state",let state=event["state"] as? [String:Any] {
            let priorPeople=people;identitySnapshot=state;people=state["people"] as? [String:String] ?? people;identityCandidatesEnabled=state["calibration"] is [String:Any];identityBusy=false
            let manual=state["manual"] as? [String:String] ?? [:]
            for (sid,person) in lastWorkerManual where manual[sid]==nil {if naming.values[sid]==priorPeople[person] {naming.set(segment:sid,name:"")}}
            for (sid,person) in manual where person != lastWorkerManual[sid] {if let name=people[person] {naming.set(segment:sid,name:name)}}
            lastWorkerManual=manual
            if let store=profileStore {do {try store.save(store.persistableState(state),rewriteBackup:true)} catch {diagnostic.stringValue="人物资料保存失败，请重试"}}
            if output != nil {spokenRowsCache.removeAll();markAllTranscriptParentsDirty()};return
        }
        if type=="identity_ack" {
            if event["ok"] as? Bool==false {identityBusy=false}
            diagnostic.stringValue=event["ok"] as? Bool==false ? "人物操作未完成："+identityMessage(event["code"] as? String ?? "") : "人物资料已更新";return
        }
        if type=="speaker_model" {
            let state=event["state"] as? String ?? "failed"
            if state=="loading" {speakerLoading=true;diagnostic.stringValue="正在录音，准备识别发言人"}
            else if state=="ready" {speakerLoading=false;diagnostic.stringValue="发言人识别已就绪"}
            else if state=="failed" {speakerLoading=false;diagnostic.stringValue="发言人暂不可用，文字记录继续"}
            updateUI();return
        }
        if type=="processing_failed" {
            guard event["session"] as? String==activeSession else{return}
            let track=event["track"] as? String ?? "mic"
            asrNetworkStates[track]="pending"
            diagnostic.stringValue=(phase.phase == .recording ? "录音继续进行；":"")+"已保存声音，部分文字未完成，可稍后补转"
            updateUI();return
        }
        if type=="asr_replay",let ids=event["discard_segment_ids"] as? [String] {
            voiceprintService?.discard(ids)
            for id in ids {if let item=segments[id],let key=SessionSpeakerKey.from(item) {voiceprintCandidates.removeValue(forKey:key);refreshVoiceprintHeading(key)}}
            let namesRevision=naming.correctionRevision
            var changedParents=Set<String>()
            for id in ids {
                changedParents.insert(id)
                if let old=segments[id] {for run in TranscriptTimeline.speakerRuns(old) {naming.discard(segment:TranscriptTimeline.runID(parent:id,run:run))}}
                transcriptCapacity.remove(id);naming.discard(segment:id)
            }
            timeline.discard(Set(ids));for parent in changedParents {publishMeetingContext(parent:parent,turns:[]);markTranscriptParentDirty(parent)}
            if naming.correctionRevision != namesRevision {persistSessionNames();markAllTranscriptParentsDirty();reloadLibraryAfterVoiceprintNameWrite()}
            return
        }
        if ["asr_reconnecting","asr_pending","asr_catching_up","asr_resumed"].contains(type) {
            let track=event["track"] as? String ?? "mic"
            asrNetworkStates[track]=type=="asr_reconnecting" ? "waiting":type=="asr_pending" ? "pending":type=="asr_catching_up" ? "catching":"live"
            diagnostic.stringValue=type=="asr_reconnecting" ? (phase.phase == .paused ? "录音保持暂停，正在恢复已录内容的转写":"等待网络恢复，录音继续"):type=="asr_pending" ? "部分转写未完成，原音已保留，可重试转写":type=="asr_catching_up" ? "正在补全未完成的文字":(phase.phase == .paused ? "录音保持暂停，正在补齐已录内容":"实时转写已恢复")
            updateUI();return
        }
        if type=="segment",let id=event["segment_id"] as? String {
            coarseResultToken=nil;speakerRefinementFailureCode=nil;speakerRefinementFailureRevision=nil
            if let session=activeSession,let incoming=event["session"] as? String,session != incoming {return}
            guard timeline.accepts(event) else{return}
            guard !transcriptLimitHit,let bytes=try? JSONSerialization.data(withJSONObject:event),transcriptCapacity.reserve(id,textBytes:(event["text"] as? String ?? "").utf8.count,eventBytes:bytes.count) else {
                transcriptLimitHit=true;if child != nil {end()};phase.phase = .failed;phase.error="本场内容已达上限，记录已停止";diagnostic.stringValue="请导出当前内容，然后新建会议";updateUI();return
            }
            if let old=segments[id],old["revision"] as? Int != event["revision"] as? Int {candidateBySegment.removeValue(forKey:id)}
            spokenRowsCache.removeValue(forKey:id);timeline.put(event);sourceActivity.receive(event)
            if event["final"] as? Bool==true {nonFinalTranscriptParents.remove(id)} else {nonFinalTranscriptParents.insert(id)}
            if let track=event["track"] as? String {observedTranscriptTracks.insert(track)}
            if let track=event["source_id"] as? String,isTranscriptAudioTrack(track),track != "mic" {
                let label=audioSourceLabel(event);if label != "电脑声音" {observedAppSources[track]=label;observedTranscriptApplications.insert(label)}
            }
            let previousSpeakerCount=naming.registeredSpeakerCount
            naming.register(segment:id,item:event)
            for run in TranscriptTimeline.speakerRuns(event) {naming.register(segment:TranscriptTimeline.runID(parent:id,run:run),item:run)}
            let visibleRows=spokenRows(id,event)
            for (key,row) in visibleRows where key != id {naming.register(segment:key,item:row)}
            if !deferPresentation,naming.registeredSpeakerCount != previousSpeakerCount {persistSessionNames()}
            observeVoiceprint(event);observeSemanticName(event)
            if MeetingTranslationPolicy.eligible(event) {for (partID, part) in visibleRows {translationService.accept(segmentID:partID,item:part)}}
            markTranscriptParentDirty(id,preparedRows:visibleRows)
            if event["final"] as? Bool == true,phase.phase == .recording {scheduleAutoTitle()}
            if previewRenderOnly && dirtyTranscriptQueue.count<=24 {renderText()}
        } else if type=="meter" {
            phase.elapsed=max(phase.elapsed,event["elapsed_seconds"] as? Double ?? 0)
            if let text=(event["combined_estimated_yuan"] ?? event["estimated_yuan"]) as? String,let amount=Double(text),amount.isFinite,amount>=0 {phase.estimated=amount}
        } else if type=="started" {let resuming=event["resume"] as? Bool==true,appending=event["append_capture"] as? Bool==true;pendingAutomaticTailRecovery=nil;if resuming {cancelSpeakerRefinementForResume()} else if !appending {detachSavedCoarseRefinement()};if resuming || appending {invalidateMeetingArchivePreparationOnResume()};speakerRefinementNeedsRetry=false;resetVoiceprintRecommendations(session:event["session"] as? String);if !resuming && !appending {absoluteTime=nil};if let clock=MeetingAbsoluteTime(event["absolute_clock"]) {absoluteTime=clock};sourceActivity=SourceActivity();latestAudioLevels=[:];latestAudioLevelAt=0;observedAppSources=[:];sourceCaptureGapLabels=[];unavailableAppSourceIDs=[];echoStatusLabel="";asrNetworkStates=[:];sessionLocalOnly=event["mode"] as? String=="local_only";activeSession=event["session"] as? String;currentCacheID=event["cache_id"] as? String;speakerRefinementLifecycle.begin(session:activeSession);cachedTranscriptionComplete=false;if phase.phase != .stopping {phase.phase = event["capture"] as? Bool==false && !(Credential.offline && event["mock"] as? Bool==true) ? .stopping:(event["audio_frames_received"] as? Bool==false ? .connecting:.recording)};if meetingTitle=="新会议" {meetingTitle=MeetingLibraryInfo.defaultTitle(Date())};beginMeetingContext();if !previewRenderOnly {reloadLibrary()}}
        else if type=="capture_stopped" {
            phase.phase = .stopping;phase.elapsed=max(phase.elapsed,event["recording_elapsed_seconds"] as? Double ?? 0)
            let reason=event["reason"] as? String ?? "unknown"
            let expected=["user_stop","user_finish","local_duration_limit","cloud_duration_limit","trial_time_limit","audio_budget_limit"].contains(reason)
            diagnostic.stringValue=expected ? "录音已停止，正在完成转写":friendly(reason)+"；正在处理已录内容"
        }
        else if type=="processing_started" {processingAudio=true;phase.phase = .stopping;diagnostic.stringValue="正在完成转写"}
        else if type=="stopped" {let recoverySucceeded=resumeBusy && !suppressAutomaticRefinementAfterStop;resumeBusy=false;processingAudio=false;cachedTranscriptionComplete=event["transcription_complete"] as? Bool ?? false;phase.elapsed=max(phase.elapsed,event["recording_elapsed_seconds"] as? Double ?? 0);var changedTranscriptParents=Set<String>()
            if trialCandidate {identityBusy=false;identitySnapshot=nil;people=[:];candidateBySegment=[:];feedback=[];lastWorkerManual=[:];identityCandidatesEnabled=false;for id in sequence {segments[id]?.removeValue(forKey:"identity_features")}}
            for id in nonFinalTranscriptParents {segments[id]?["stream_closed"]=true;changedTranscriptParents.insert(id)}
            nonFinalTranscriptParents=[]
            let reason=event["reason"] as? String ?? "unknown"
            let captureFailure=event["capture_failure_reason"] as? String
            if transcriptLimitHit {phase.phase = .failed;phase.error="本场内容已达上限，记录已停止"}
            else if wasRecoveryRun && cachedTranscriptionComplete && ["user_stop","user_finish","processing_cancelled"].contains(reason) {phase.phase = .stopped;phase.error=nil;diagnostic?.stringValue="已保存录音已全部转写"}
            else if ["trial_time_limit","audio_budget_limit"].contains(reason) {phase.phase = .ended}
            else if reason=="input_device_changed" && cachedTranscriptionComplete {phase.phase = .stopped;phase.error=friendly(reason)}
            else if let captureFailure,!captureFailure.isEmpty {phase.phase = .failed;phase.error=friendly(captureFailure)}
            else if reason=="user_stop" || reason=="user_finish" || reason=="local_duration_limit" || reason=="cloud_duration_limit" {phase.phase = .stopped}
            else {phase.phase = .failed;phase.error=friendly(reason);cancelSpeakerRefinement()}
            if event["audio_sources_complete"] as? Bool==false {
                let sources=(event["source_capture_gaps"] as? [[String:Any]] ?? []).compactMap{$0["application_name"] as? String}.filter{!$0.isEmpty}
                let names=sources.isEmpty ? "电脑声音":sources.joined(separator:"、")
                diagnostic?.stringValue="\(names)有一段声音未录到，其他录音已保存。"
            }
            for parent in changedTranscriptParents {markTranscriptParentDirty(parent)}
            if !previewRenderOnly {reloadLibrary()}
            if shouldRefineAfterStopped(session:activeSession,reason:reason,transcriptionComplete:cachedTranscriptionComplete,localOnly:sessionLocalOnly && !recoverySucceeded,recoverySucceeded:recoverySucceeded) {
                scheduleSpeakerRefinement(trigger:recoverySucceeded ? "manual_recovery":"stopped")
            }
        } else if type=="error" {
            phase.error=event["message"] as? String=="腾讯会议未运行；未开始采集" ? "先打开腾讯会议，再点开始":workerFailureMessage(event["code"] as? String ?? "unknown")
            phase.phase = .failed
        }
        updateUI()
        if type=="stopped" {
            finalizeSessionTitle();finishPendingNewMeetingIfReady()
            let reason=event["reason"] as? String ?? ""
            if !wasRecoveryRun,let cacheID=currentCacheID,let session=activeSession,
               ["capture_control_timeout_pause","capture_control_timeout_pause_drain",
                "capture_control_timeout_finish"].contains(reason),
               event["transcription_complete"] as? Bool != true,!sessionLocalOnly {
                pendingAutomaticTailRecovery=(reason,cacheID,session)
            }
        }
    }
    func workerFailureMessage(_ reason:String)->String {
        if reason=="cache_writer_active" {return "会议文件仍在保存，本次补转未开始；请稍后补转，原音和已有文字保留"}
        if resumeBusy {return "尾部补转未完成；原音和已有文字保留，可稍后补转"}
        if ["worker_preflight_failed","recording_worker_failed"].contains(reason) {
            return phase.elapsed>0 || !sequence.isEmpty ? "录音处理已中断；原音和已有文字保留，可补转剩余录音":"录音未启动，请重试"
        }
        return friendly(reason)
    }
    func friendly(_ reason:String)->String {
        if reason=="capture_control_timeout_pause_drain" {return "录音已中断；尾部转写超时，原音保留，可补转"}
        if reason.hasPrefix("capture_control_") || reason.hasPrefix("capture_pause_") || reason.hasPrefix("capture_resume_") || reason=="capture_owner_exited" {return "录音控制异常，本场录音已中断；原音和已有文字保留"}
        if reason=="model_preparation_timeout" {return "准备超时，请重试"}
        if reason.hasPrefix("model_preparation") {return "准备失败，请重试"}
        if reason=="startup_timeout" {return "连接超时，请重试"}
        if reason=="startup_interrupted" {return "已取消"}
        if reason.contains("permission") {return "无法录音，请在系统设置中允许访问麦克风和电脑声音"}
        if reason.contains("InvalidApiKey") || reason.contains("401") {return trialCandidate ? "去设置里填写百炼密钥" : "密钥无效，请在设置中更换"}
        if reason.contains("Quota") {return "转写服务余额不足，请检查账户"}
        if reason.hasPrefix("speaker_model") {return "发言人识别出错，记录已停止；已有文字已保留"}
        if reason=="processing_cancelled" || reason=="processing_timeout" {return "转写未完成，可导出当前文字"}
        if reason=="mic_conversion_backpressure" {return "声音处理积压，录音已中断；已有录音保留"}
        if reason.hasPrefix("microphone_") || reason=="input_device_changed" {return "麦克风采集异常，已停止；请检查输入设备后重新开始，已有记录保留"}
        if reason=="no_sound" {return "没有收到声音，请检查麦克风和电脑音量"}
        if reason=="audio_backpressure" || reason=="cache_writer_backpressure" {return "录音已中断；已保存原音保留，可继续恢复本场"}
        if reason.hasPrefix("cache_") {return "录音保存遇到问题，已保存原音保留；可继续恢复本场"}
        if reason.contains("selected_application") {return "暂时无法获取电脑声音，请检查系统录音权限"}
        return "连接中断，已停止。请检查网络后重新开始"
    }
    func updateUI() {
        guard !deferPresentation else{return}
        updateMeetingContext()
        heading.stringValue=phase.error ?? [.idle:"准备就绪",.connecting:"正在连接",.recording:"正在记录",.paused:"录音已暂停",.stopping:"正在整理",.stopped:"已停止",.failed:"已停止",.ended:"已结束"][phase.phase]!
        if phase.error==nil,phase.phase == .paused,!pausedTailStates.isEmpty {heading.stringValue=pausedTailStates.values.contains("processing") ? "录音已暂停 · 正在补齐文字":pausedTailStates.values.contains("pending") ? "录音已暂停 · 转写未完成":"录音已暂停 · 已录内容已转写"}
        if phase.phase == .recording {
            if asrNetworkStates.values.contains("pending") {heading.stringValue="正在录音 · 转写暂停"}
            else if asrNetworkStates.values.contains("waiting") {heading.stringValue="正在录音 · 等待网络"}
            else if asrNetworkStates.values.contains("catching") {heading.stringValue="正在录音 · 补全转写"}
        }
        if phase.phase == .stopped,currentCacheID != nil,!cachedTranscriptionComplete {heading.stringValue="已停止 · 部分录音待转写"}
        if sessionLocalOnly && phase.phase == .recording {heading.stringValue="正在录音"}
        if sessionLocalOnly && phase.phase == .stopped && sequence.isEmpty {heading.stringValue="录音已保存";empty.stringValue="录音已保存，可稍后生成文字"}
        if speakerLoading && phase.phase == .connecting {heading.stringValue="正在准备"}
        heading.font = .systemFont(ofSize:phase.error == nil ? 17 : 15,weight:.semibold)
        action.title=[.connecting:"正在录音",.recording:"正在录音",.paused:"继续录音",.stopping:"正在整理",.failed:"重新开始",.stopped:"开始录音",.idle:"开始录音",.ended:"开始录音"][phase.phase]!
        action.isEnabled = ![.connecting,.recording,.stopping].contains(phase.phase) && (phase.phase != .paused || recordingControlInFlight==nil)
        if processingAudio {action.title="正在整理";action.isEnabled=false;heading.stringValue="正在完成转写"}
        if preparingModels {
            heading.stringValue="正在准备 · \(Int(preparationElapsed))秒";action.title="正在准备"
            diagnostic.stringValue="首次启动可能需要一点时间";action.isEnabled = false
        } else if trialCandidate && !mock && [.idle,.stopped,.failed].contains(phase.phase) {action.title="开始"}
        if newRecordingPending && !mock && [.idle,.stopped,.failed,.ended].contains(phase.phase) {action.title=(Bundle.main.object(forInfoDictionaryKey:"LocalRecordingAllowed") as? Bool==true) ? "开始本地录音":"开始录音";action.isEnabled=true}
        if credentialReadJob.waiting {action.title="正在连接";action.isEnabled=false;heading.stringValue="正在连接转写服务"}
        if cacheReadJob.waiting || cacheExportJob.waiting || qaWriteJob.waiting {action.title="正在处理";action.isEnabled=false;heading.stringValue="正在处理会议记录"}
        let sessionBusy=child != nil || preparingModels || processingAudio || credentialReadJob.waiting || cacheReadJob.waiting || cacheExportJob.waiting || qaWriteJob.waiting || [.connecting,.recording,.paused,.stopping].contains(phase.phase)
        historyButton?.isEnabled = true;newButton?.isEnabled = !sessionBusy
        meter.stringValue="\(phase.time)  ·  预计费用 \(phase.price)"+(balanceState.checked == nil ? "":"  ·  "+balanceState.display)
        meter.toolTip=meter.stringValue
        recordingModePicker?.isEnabled = ![.connecting,.recording,.paused,.stopping].contains(phase.phase) && !cacheReadJob.waiting && !cacheExportJob.waiting && !qaWriteJob.waiting && !credentialReadJob.waiting
        exportButton?.isEnabled = !sequence.isEmpty || recoveredArchiveText != nil || currentCacheID != nil
        footerDetails?.isHidden = false
        updateWorkspacePresentation()
        updateSourceActivity()
        updateRecordingDashboard()
        if !Credential.offline {recordingAttention.sync()}
        resizeTranscript()
    }
    func namingItem(_ id:String)->[String:Any]? {
        if let item=segments[id] {return item}
        if let turn=incrementalTranscript.block(id)?.turn {return turn.item}
        for (parent,item) in segments {if let row=spokenRows(parent,item).first(where:{$0.0==id}) {return row.1}}
        return readingTurns().first(where:{$0.id==id})?.item
    }
    func speakerLabel(_ id:String,_ item:[String:Any])->String {
        if let name=naming.displayName(segment:id) {return name.visibleValue}
        if let key=naming.key(segment:id) ?? SessionSpeakerKey.from(item) {
            if let name=naming.displayName(speaker:key) {return name.visibleValue}
            return naming.displayLabel(speaker:key)
        }
        if let title=SpeakerReviewIndex.simultaneousTitle(item:item,session:activeSession ?? "",names:naming) {return title}
        let speaker=item["speaker"] as? [String:Any] ?? [:]
        return speaker["basis"] as? String=="multiple" && speaker["reason"] as? String=="overlap" ? "多人重叠":"待确认"
    }
    // Presentation uses word-aligned turns; the original provider sentence and its ID stay intact.
    // A user's explicit whole-sentence label still takes precedence.
    func spokenRows(_ id:String,_ item:[String:Any])->[(String,[String:Any])] {
        let revision=item["revision"] as? Int ?? -1
        if let cached=spokenRowsCache[id],cached.revision==revision,cached.correctionRevision==naming.correctionRevision {return cached.rows}
        transcriptProjectionComputations+=1
        let rows=computeSpokenRows(id,item);spokenRowsCache[id]=(revision,naming.correctionRevision,rows);return rows
    }
    func computeSpokenRows(_ id:String,_ item:[String:Any])->[(String,[String:Any])] {
        if naming.sentenceName(segment:id) != nil {return [(id,item)]}
        let runs=TranscriptTimeline.speakerRuns(item)
        let overrides=naming.manualRunOverrides(parent:id,item:item)
        var rows:[(String,[String:Any])]=[]
        func row(_ run:[String:Any])->[String:Any] {
            var result=item;result.removeValue(forKey:"speaker_runs");result.removeValue(forKey:"word_spans")
            for key in ["text","start","end","speaker"] {result[key]=run[key]}
            result["parent_segment_id"]=id
            return result
        }
        if overrides.isEmpty {
            rows=runs.isEmpty ? [(id,item)]:runs.map{(TranscriptTimeline.runID(parent:id,run:$0),row($0))}
        } else {
            // Recreate only real provider-word boundaries, and keep manual spans
            // narrower than any surrounding text merged by a later model revision.
            var previousOwner:String?
            for word in item["word_spans"] as? [[String:Any]] ?? [] {
                guard let lo=word["start"] as? Double,let hi=word["end"] as? Double else{continue}
                let override=overrides.filter{$0.start<=lo+1e-6 && $0.end>=hi-1e-6}.min{($0.end-$0.start)<($1.end-$1.start)}
                let run=runs.first{($0["start"] as? Double ?? .infinity)<=lo+1e-6 && ($0["end"] as? Double ?? -.infinity)>=hi-1e-6}
                var fragment=word;fragment["speaker"]=run?["speaker"] ?? item["speaker"]
                let owner=override?.id ?? "model:"+(run.map{TranscriptTimeline.runID(parent:id,run:$0)} ?? id)
                let key=override?.id ?? id+":word:"+String(Int((lo*1000).rounded()))
                if var last=rows.last,previousOwner==owner {
                    // A malformed fragment falls back to the whole sentence via the check below.
                    last.1["text"]=(last.1["text"] as? String ?? "")+(word["text"] as? String ?? "");last.1["end"]=hi;rows[rows.count-1]=last
                } else {rows.append((key,row(fragment)))}
                previousOwner=owner
            }
            if rows.map{$0.1["text"] as? String ?? ""}.joined() != item["text"] as? String {return [(id,item)]}
        }
        // Punctuation carries no audible identity. Keep it with adjacent text
        // instead of creating an empty-looking speaker turn for a quote or comma.
        var readable:[(String,[String:Any])]=[]
        for entry in rows {
            let body=entry.1["text"] as? String ?? ""
            if !readable.isEmpty,body.range(of:"[\\p{L}\\p{N}]",options:.regularExpression)==nil,
               naming.sentenceName(segment:entry.0)==nil,!overrides.contains(where:{$0.id==entry.0}) {
                var prior=readable.removeLast();prior.1["text"]=(prior.1["text"] as? String ?? "")+body;prior.1["end"]=entry.1["end"];readable.append(prior)
            } else {readable.append(entry)}
        }
        return readable
    }
    func readingIdentity(_ id:String,_ item:[String:Any])->String? {
        if naming.sentenceName(segment:id) != nil {return "manual:"+id}
        guard let key=naming.key(segment:id) ?? SessionSpeakerKey.from(item) else{return nil}
        if let name=naming.displayName(segment:id),name.origin == .voiceprint,naming.displayName(speaker:key)==nil {
            return [key.session,key.source,key.epoch,key.identity,"voiceprint",name.value].joined(separator:"\u{001F}")
        }
        if let name=naming.displayName(segment:id),name.origin == .manual {
            // Reconciliation may reference the same person on another track.
            // Reading boundaries follow the recorded sound, not that person's key.
            let session=item["session"] as? String ?? key.session
            let source=item["source_id"] as? String ?? key.source
            let epoch=(item["epoch"] as? String).flatMap{$0.isEmpty ? nil:$0} ?? key.epoch
            return [session,source,epoch,"manual-name",name.value].joined(separator:"\u{001F}")
        }
        return [key.session,key.source,key.epoch,key.identity].joined(separator:"\u{001F}")
    }
    func readingTurnLabel(_ turn:ReadingTurn)->String {
        let manualNames=Set(turn.parts.compactMap{part in
            naming.displayName(segment:part.0).flatMap{$0.origin == .manual ? $0.value:nil}
        })
        // An overlap blip that already carries an identity (manual or bridged)
        // belongs to that person's turn; only an unowned overlap labels it.
        if let overlap=turn.parts.first(where:{part in let speaker=part.1["speaker"] as? [String:Any] ?? [:];return speaker["basis"] as? String=="multiple" && speaker["reason"] as? String=="overlap" && readingIdentity(part.0,part.1)==nil}) {
            if manualNames.count==1 && turn.parts.allSatisfy({naming.displayName(segment:$0.0)?.origin == .manual}) {
                return manualNames.first!
            }
            return SpeakerReviewIndex.simultaneousTitle(item:overlap.1,session:activeSession ?? "",names:naming) ?? "多人重叠"
        }
        if let known=turn.parts.first(where:{readingIdentity($0.0,$0.1) != nil}) {return speakerLabel(known.0,known.1)}
        return speakerLabel(turn.id,turn.item)
    }
    func readingTurns(_ parents:[String]?=nil)->[ReadingTurn] {
        if parents==nil && dirtyTranscriptParents.isEmpty && !fullTranscriptRefreshPending && incrementalTranscript.trackedParentCount==segments.count {return incrementalTranscript.allTurns()}
        if let parents=parents,parents.isEmpty {return []}
        var rows:[(id:String,parent:String,item:[String:Any])]=[]
        for parent in parents ?? sequence {guard let item=segments[parent] else{continue};rows.append(contentsOf:spokenRows(parent,item).map{(id:$0.0,parent:parent,item:$0.1)})}
        rows.sort {let a=TranscriptTimeline.start($0.item),b=TranscriptTimeline.start($1.item);if a != b {return a<b};if $0.parent != $1.parent {return $0.parent<$1.parent};return $0.id<$1.id}
        return TranscriptTimeline.readingTurns(rows,identity:readingIdentity)
    }
    func transcriptParent(for id:String)->String {
        if segments[id] != nil {return id}
        if let item=namingItem(id),let parent=item["parent_segment_id"] as? String,!parent.isEmpty {return parent}
        return incrementalTranscript.block(id)?.turn.parent ?? id
    }
    func transcriptIdentity(for id:String)->String? {
        guard let item=namingItem(id) else{return nil};return readingIdentity(id,item)
    }
    func markNamingChange(segment id:String,oldIdentity:String?=nil,oldParent:String?=nil) {
        var affected=Set<String>()
        if let oldIdentity=oldIdentity {affected.formUnion(incrementalTranscript.parents(for:oldIdentity))}
        let parent=oldParent ?? transcriptParent(for:id);affected.insert(parent);spokenRowsCache.removeValue(forKey:parent)
        if let newIdentity=transcriptIdentity(for:id) {affected.formUnion(incrementalTranscript.parents(for:newIdentity))}
        for candidate in affected {spokenRowsCache.removeValue(forKey:candidate)}
        indexedCorrectionRevision=naming.correctionRevision
        if affected.count>128 {markAllTranscriptParentsDirty()} else {for candidate in affected {markTranscriptParentDirty(candidate)};if affected.count<=24 {renderText()}}
    }
    func speakerDetails(_ id:String,_ item:[String:Any])->[(String,String)] {
        let runs=TranscriptTimeline.speakerRuns(item)
        guard runs.count>1 else{return []}
        return runs.map {run in
            let key=TranscriptTimeline.runID(parent:id,run:run)
            let label=speakerLabel(key,run)
            return (key,TranscriptTimeline.timestamp(run["start"],precise:true)+"–"+TranscriptTimeline.timestamp(run["end"],precise:true)+"  "+label)
        }
    }
    func updateSourceActivity() {
        guard let source=source else{return}
        guard [.recording,.paused,.stopping,.stopped,.ended].contains(phase.phase) else{return}
        let tracks=Set(sourceActivity.bytes.keys).union(sourceActivity.transcribed).filter{isTranscriptAudioTrack($0) && $0 != "mic"}
        let measuredTracks=tracks.filter{sourceActivity.signal[$0] != nil}
        let remoteState=measuredTracks.isEmpty ? (tracks.contains(where:{sourceActivity.transcribed.contains($0)}) ? "已有转写" : sourceActivity.label("remote")) : measuredTracks.sorted().map{(observedAppSources[$0] ?? "电脑声音")+" "+sourceActivity.label($0)}.joined(separator:"；")
        let appLabels=Set(tracks.compactMap{observedAppSources[$0]}).sorted()
        let remoteName=appLabels.isEmpty ? "电脑声音" : appLabels.joined(separator:"、")
        let mic="麦克风："+sourceActivity.label("mic")
        let echo=echoStatusLabel.isEmpty || sourceActivity.microphoneWarning != nil ? "" : "  ·  "+echoStatusLabel
        let sourceWarning = !unavailableAppSourceIDs.isEmpty ? "  ·  电脑声音采集中断，正在恢复" :
            (!sourceCaptureGapLabels.isEmpty ? "  ·  电脑声音曾中断，缺失时段无法补录" : "")
        source.stringValue=mic+"  ·  "+remoteName+"："+remoteState+echo+sourceWarning
        source.toolTip=source.stringValue+"。声音信号按原音轨独立检测，能量不等于有效发言。"
        if [.connecting,.recording].contains(phase.phase),let warning=sourceActivity.microphoneWarning {
            heading.stringValue="麦克风收音异常 · 电脑声音继续记录"
            diagnostic.stringValue=warning;diagnostic.isHidden=false
            microphoneSignalAlertVisible=true;source.textColor = .systemRed
        } else {
            source.textColor = .secondaryLabelColor
            if microphoneSignalAlertVisible {microphoneSignalAlertVisible=false;diagnostic.stringValue="";diagnostic.isHidden=true}
        }
    }
    func markTranscriptParentDirty(_ parent:String,preparedRows:[(String,[String:Any])]?=nil) {
        guard !parent.isEmpty else{return}
        let rows:[(String,[String:Any])]
        if let preparedRows=preparedRows {rows=preparedRows}
        else {spokenRowsCache.removeValue(forKey:parent);rows=segments[parent].map{spokenRows(parent,$0)} ?? []}
        let related=incrementalTranscript.replaceAtoms(parent:parent,rows:rows.map{TranscriptAtomicRow(id:$0.0,parent:parent,item:$0.1)})
        for candidate in related {if dirtyTranscriptParents.insert(candidate).inserted {dirtyTranscriptQueue.append(candidate)}}
        if !deferPresentation {scheduleTranscriptRender()}
    }
    func markAllTranscriptParentsDirty() {
        indexedCorrectionRevision=naming.correctionRevision;fullRefreshGeneration &+= 1;fullRefreshAtomsReady=false;fullRefreshBuildInFlight=false;fullTranscriptRefreshPending=true;fullRefreshBlocksByParent=[:];dirtyTranscriptParents=[];dirtyTranscriptQueue=timeline.orderedIDs;dirtyTranscriptQueueIndex=0
        spokenRowsCache.removeAll();updateMeetingContext()
        if !deferPresentation {scheduleTranscriptRender()}
    }
    func transcriptTimeHeading(_ offset:Double)->String {
        let relative=TranscriptTimeline.timestamp(offset)
        return absoluteTime?.display(offset).map{relative+" · "+$0} ?? relative
    }
    func renderedBlock(_ turn:ReadingTurn)->TranscriptRenderedBlock {
        let item=turn.item,key=turn.id
        let originalLabel=readingTurnLabel(turn)
        // Keep the reading surface quiet. Evidence and per-fragment correction
        // remain available on the header/underlined text and in original export.
        let unresolved=["待确认","多人重叠","多人同时发言","句内说话人变化"].contains(originalLabel)
        let speaker=unresolved ? (originalLabel=="待确认" ? "未识别 · 是谁？":originalLabel):originalLabel
        let hint=unresolved ? "":voiceprintHint(turn)
        let text=NSMutableAttributedString(string:"");var partRanges:[String:NSRange]=[:]
        let final=item["final"] as? Bool ?? false
        let review=(item["quality_flags"] as? [String])?.isEmpty==false
        let state=final ? "" : item["stream_closed"] as? Bool==true || ![.connecting,.recording,.stopping].contains(phase.phase) ? " · 未完成" : " · 正在转写"
        // The newest unfinished turn while recording: marked as speaking, its last words still settling.
        let speaking=state==" · 正在转写" && phase.phase == .recording
        // Header: avatar, name and one time. The source and the relative time
        // stay in the tooltip; consecutive turns of one speaker collapse it.
        let start=TranscriptTimeline.start(item)
        let relative=TranscriptTimeline.timestamp(start)
        let absolute=absoluteTime?.display(start)
        let colorKey=unresolved ? nil:originalLabel
        let tint=MeetingVisualStyle.speakerColor(colorKey)
        let header=NSMutableParagraphStyle();header.paragraphSpacingBefore=20;header.paragraphSpacing=4;header.lineBreakMode = .byCharWrapping
        header.minimumLineHeight=26
        let tooltip=readingTurnLabel(turn)+(turn.uncertain ? " · 部分发言归属未定":"")+" · "+audioSourceLabel(item)+" · "+relative+(absolute.map{" · "+$0} ?? "")
        let headerStart=text.length
        let avatar=NSTextAttachment();avatar.image=MeetingVisualStyle.speakerAvatar(unresolved ? "?":MeetingVisualStyle.speakerInitial(speaker),color:tint)
        avatar.bounds=NSRect(x:0,y:-6,width:24,height:24)
        text.append(NSAttributedString(attachment:avatar))
        let base:[NSAttributedString.Key:Any]=[.paragraphStyle:header,.toolTip:tooltip]
        text.append(NSAttributedString(string:"  "+speaker,attributes:base.merging([.font:MeetingVisualStyle.nameFont,.foregroundColor:unresolved ? MeetingVisualStyle.muted:MeetingVisualStyle.ink]){$1}))
        if originalLabel=="待确认",let id=turn.parts.first?.0 {
            let who=(text.string as NSString).range(of:"是谁？",options:.backwards)
            if who.location != NSNotFound {text.addAttributes([.link:id,.toolTip:"确认这句话的发言人"],range:who)}
        }
        if !hint.isEmpty {text.append(NSAttributedString(string:hint,attributes:base.merging([.font:NSFont.systemFont(ofSize:12),.foregroundColor:MeetingVisualStyle.muted]){$1}))}
        text.append(NSAttributedString(string:"   "+(absolute ?? relative)+(speaking ? "":state),attributes:base.merging([.font:NSFont.monospacedDigitSystemFont(ofSize:12,weight:.regular),.foregroundColor:MeetingVisualStyle.muted]){$1}))
        if speaking {text.append(NSAttributedString(string:"   ● 正在说",attributes:base.merging([.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:MeetingVisualStyle.accent]){$1}))}
        text.append(NSAttributedString(string:"\n",attributes:base))
        text.addAttribute(.paragraphStyle,value:header,range:NSRange(location:headerStart,length:text.length-headerStart))
        let continuation=unresolved || turn.uncertain || review ? nil:speaker+"\u{1F}"+audioSourceLabel(item)
        text.addAttribute(.zaichangTurnHeader,value:TranscriptTurnHeader(continuationKey:continuation,start:start,end:(item["end"] as? Double).flatMap{$0.isFinite ? $0:nil} ?? start),range:NSRange(location:headerStart,length:text.length-headerStart))
        let para=NSMutableParagraphStyle();para.lineSpacing=7;para.paragraphSpacing=6;para.lineBreakMode = .byWordWrapping
        para.firstLineHeadIndent=34;para.headIndent=34
        var identities=Set<String>()
        for (partID,part) in turn.parts {
            let offset=text.length,body=part["text"] as? String ?? ""
            let identity=readingIdentity(partID,part);if let identity=identity {identities.insert(identity)}
            var attributes:[NSAttributedString.Key:Any]=[.font:MeetingVisualStyle.bodyFont,.foregroundColor:MeetingVisualStyle.ink,.paragraphStyle:para]
            if identity==nil && turn.uncertain {
                attributes[.link]=partID;attributes[.underlineStyle]=NSUnderlineStyle.single.rawValue|NSUnderlineStyle.patternDot.rawValue
                attributes[.toolTip]=(part["speaker"] as? [String:Any])?["reason"] as? String=="overlap" ? "这部分有重叠发言；点击修改发言人":"这部分的发言人待确认；点击修改"
            }
            text.append(NSAttributedString(string:body,attributes:attributes));partRanges[partID]=NSRange(location:offset,length:text.length-offset)
        }
        if speaking,let last=turn.parts.last.flatMap({partRanges[$0.0]}),last.length>0 {
            // Fade the newest words only; the text itself is unchanged.
            let faint=min(2,last.length),settling=min(4,last.length-faint)
            if settling>0 {text.addAttribute(.foregroundColor,value:MeetingVisualStyle.ink.withAlphaComponent(0.7),range:NSRange(location:last.location+last.length-faint-settling,length:settling))}
            text.addAttribute(.foregroundColor,value:MeetingVisualStyle.ink.withAlphaComponent(0.4),range:NSRange(location:last.location+last.length-faint,length:faint))
        }
        let translated=turn.parts.compactMap { partID, part -> String? in
            guard MeetingTranslationPolicy.eligible(turn.item),MeetingTranslationPolicy.eligible(part) else {return nil}
            return translationService.translated(segmentID:partID,source:part["text"] as? String ?? "")
        }.joined(separator:"\n")
        if !translated.isEmpty {
            let style=para.mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacingBefore=4;style.lineSpacing=4
            text.append(NSAttributedString(string:"\n"+translated,attributes:[.font:NSFont.systemFont(ofSize:13.5),.foregroundColor:MeetingVisualStyle.muted,.paragraphStyle:style]))
        }
        text.append(NSAttributedString(string:"\n",attributes:[.font:NSFont.systemFont(ofSize:14.5),.paragraphStyle:para]))
        if showsSpeakerRanges {
            for (partID,part) in turn.parts {
                let detail=TranscriptTimeline.timestamp(part["start"],precise:true)+"–"+TranscriptTimeline.timestamp(part["end"],precise:true)+"  "+speakerLabel(partID,part)
                text.append(NSAttributedString(string:detail+"\n",attributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.tertiaryLabelColor,.link:partID]))
            }
        }
        return TranscriptRenderedBlock(turn:turn,attributed:text,partRanges:partRanges,identities:identities)
    }
    struct TranscriptReadingPosition {
        var nearBottom=false
        var selectedID:String?,selectedOffset:Int?,selectedEndID:String?,selectedEndOffset:Int?
        var anchorID:String?,anchorOffset=0,anchorDelta:CGFloat=0
        var viewportY:CGFloat=0
    }
    func captureTranscriptReadingPosition()->TranscriptReadingPosition {
        var result=TranscriptReadingPosition()
        guard let output=output,let scroll=scroll else{return result}
        let viewport=scroll.contentView.bounds,selection=output.selectedRange()
        result.nearBottom=viewport.maxY>=output.bounds.maxY-80 && selection.length==0;result.viewportY=viewport.minY
        if selection.length>0 {
            result.selectedID=incrementalTranscript.turnID(atCharacter:selection.location);result.selectedOffset=incrementalTranscript.localOffset(atCharacter:selection.location)
            let end=max(selection.location,selection.location+selection.length-1)
            result.selectedEndID=incrementalTranscript.turnID(atCharacter:end);result.selectedEndOffset=incrementalTranscript.localOffset(atCharacter:end)
        }
        if !result.nearBottom,let layout=output.layoutManager,let container=output.textContainer {
            var glyph=layout.glyphIndex(for:NSPoint(x:1,y:viewport.minY-output.textContainerInset.height),in:container)
            if glyph<layout.numberOfGlyphs {
                var lineRange=NSRange()
                let line=layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:&lineRange)
                // Paragraph spacing can hit the previous line. Anchor the first visible line.
                let next=NSMaxRange(lineRange)
                if line.maxY+output.textContainerInset.height<=viewport.minY && next<layout.numberOfGlyphs {glyph=next}
            }
            if glyph<layout.numberOfGlyphs {
                let character=layout.characterIndexForGlyph(at:glyph)
                result.anchorID=incrementalTranscript.turnID(atCharacter:character);result.anchorOffset=incrementalTranscript.localOffset(atCharacter:character) ?? 0
                let rect=layout.boundingRect(forGlyphRange:NSRange(location:glyph,length:1),in:container)
                result.anchorDelta=viewport.minY-(rect.minY+output.textContainerInset.height)
            }
        }
        return result
    }
    func cancelTranscriptReadingRestore() {transcriptReadingRestoreRevision &+= 1;pendingTranscriptReadingPosition=nil;pendingTranscriptSelection=nil}
    func currentTranscriptReadingPosition()->TranscriptReadingPosition {
        if let pending=pendingTranscriptReadingPosition,pendingTranscriptSelection==output.selectedRange() {return pending}
        cancelTranscriptReadingRestore()
        return captureTranscriptReadingPosition()
    }
    func restoreAfterTranscriptEdit(_ position:TranscriptReadingPosition) {
        restoreTranscriptReadingPosition(position)
        transcriptReadingRestoreRevision &+= 1
        let revision=transcriptReadingRestoreRevision,selection=output.selectedRange()
        pendingTranscriptReadingPosition=position;pendingTranscriptSelection=selection
        // AppKit can adjust the clip origin after the text view completes layout.
        // Repeat the same local anchor once; a new edit or manual scroll cancels it.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.01) { [weak self] in
            guard let self=self,self.transcriptReadingRestoreRevision==revision else{return}
            self.pendingTranscriptReadingPosition=nil;self.pendingTranscriptSelection=nil
            guard self.output.selectedRange()==selection else{return}
            let current=self.captureTranscriptReadingPosition()
            if current.anchorID != position.anchorID || current.anchorOffset != position.anchorOffset || abs(current.anchorDelta-position.anchorDelta)>0.5 {self.restoreTranscriptReadingPosition(position)}
        }
    }
    func restoreTranscriptReadingPosition(_ position:TranscriptReadingPosition) {
        guard let output=output,let scroll=scroll else{return}
        if let id=position.selectedID,let range=incrementalTranscript.range(forTurn:id) {
            let location=min(range.location+(position.selectedOffset ?? 0),max(range.location,range.location+range.length-1));var end=location
            if let endID=position.selectedEndID,let endRange=incrementalTranscript.range(forTurn:endID) {end=min(endRange.location+(position.selectedEndOffset ?? 0),max(endRange.location,endRange.location+endRange.length-1))}
            let selection=NSRange(location:location,length:max(1,end-location+1))
            if output.selectedRange() != selection {output.setSelectedRange(selection)}
        }
        if position.nearBottom {output.scrollToEndOfDocument(nil);latest?.isHidden=true;return}
        var y=position.viewportY
        if let id=position.anchorID,let range=incrementalTranscript.range(forTurn:id),let layout=output.layoutManager,let container=output.textContainer {
            let location=min(range.location+position.anchorOffset,max(range.location,range.location+range.length-1))
            let anchorRange=NSRange(location:location,length:1)
            layout.ensureLayout(forCharacterRange:anchorRange)
            let glyph=layout.glyphRange(forCharacterRange:anchorRange,actualCharacterRange:nil)
            y=layout.boundingRect(forGlyphRange:glyph,in:container).minY+output.textContainerInset.height+position.anchorDelta
        }
        scroll.contentView.scroll(to:NSPoint(x:scroll.contentView.bounds.minX,y:max(0,y)));scroll.reflectScrolledClipView(scroll.contentView);latest?.isHidden=false
    }
    func renderText() {
        guard !deferPresentation,let output=output,let scroll=scroll else{return}
        if indexedCorrectionRevision != naming.correctionRevision {markAllTranscriptParentsDirty()}
        if fullRefreshBuildInFlight {return}
        resizeTranscript()
        if let archive=recoveredArchiveText,sequence.isEmpty {if output.string != archive {output.string=archive};empty.isHidden=archive.isEmpty;return}
        guard let storage=output.textStorage else{return}
        let readingPosition=currentTranscriptReadingPosition()
        let deadline=ProcessInfo.processInfo.systemUptime+0.010;var processed=0
        var refreshedParents:[String]=[]
        let mutatesVisibleText = !fullTranscriptRefreshPending && dirtyTranscriptQueueIndex<dirtyTranscriptQueue.count
        if mutatesVisibleText {storage.beginEditing()}
        while dirtyTranscriptQueueIndex<dirtyTranscriptQueue.count,processed<24,ProcessInfo.processInfo.systemUptime<deadline {
            let parent=dirtyTranscriptQueue[dirtyTranscriptQueueIndex];dirtyTranscriptQueueIndex+=1;dirtyTranscriptParents.remove(parent)
            refreshedParents.append(parent)
            if fullTranscriptRefreshPending && !fullRefreshAtomsReady {
                let rows=segments[parent].map{spokenRows(parent,$0)} ?? []
                _=incrementalTranscript.replaceAtoms(parent:parent,rows:rows.map{TranscriptAtomicRow(id:$0.0,parent:parent,item:$0.1)})
                processed+=1;continue
            }
            let turns: [ReadingTurn]
            turns=incrementalTranscript.turns(forParent:parent,identity:readingIdentity)
            let blocks=turns.map{renderedBlock($0)}
            publishMeetingContext(parent:parent,turns:turns)
            if fullTranscriptRefreshPending {fullRefreshBlocksByParent[parent]=blocks}
            else {incrementalTranscript.replace(parent:parent,with:blocks,storage:storage)}
            processed+=1
        }
        if mutatesVisibleText {storage.endEditing();if processed>0 {TranscriptTurnHeader.refresh(storage,near:refreshedParents.compactMap{incrementalTranscript.range(forParent:$0)})}}
        if fullTranscriptRefreshPending && !fullRefreshAtomsReady && dirtyTranscriptQueueIndex>=dirtyTranscriptQueue.count {
            fullRefreshAtomsReady=true;dirtyTranscriptQueue=timeline.orderedIDs;dirtyTranscriptQueueIndex=0
            if dirtyTranscriptQueue.count<=24 {renderText()} else {scheduleTranscriptRender()}
            return
        }
        if fullTranscriptRefreshPending && dirtyTranscriptQueueIndex>=dirtyTranscriptQueue.count {
            if fullRefreshBlocksByParent.count<=24 {
                let blocks=fullRefreshBlocksByParent.values.flatMap{$0}.sorted {let a=TranscriptTimeline.start($0.turn.item),b=TranscriptTimeline.start($1.turn.item);if a != b {return a<b};if $0.turn.parent != $1.turn.parent {return $0.turn.parent<$1.turn.parent};return $0.turn.id<$1.turn.id}
                let (fresh,text)=IncrementalTranscript.rebuilt(blocks,atoms:incrementalTranscript.allAtoms())
                let oldLength=storage.length;storage.setAttributedString(text);fresh.noteFullReplacement(oldLength:oldLength);TranscriptTurnHeader.refresh(storage)
                incrementalTranscript=fresh;fullRefreshBlocksByParent=[:];fullRefreshAtomsReady=false;fullTranscriptRefreshPending=false;empty.isHidden=storage.length>0
                updateMeetingContext()
                restoreAfterTranscriptEdit(readingPosition)
                footerDetails?.isHidden=false
                meetingTranscriptProjectionDidSettle()
                return
            }
            fullRefreshBuildInFlight=true
            let generation=fullRefreshGeneration,blocks=fullRefreshBlocksByParent.values.flatMap{$0},atoms=incrementalTranscript.allAtoms()
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                guard let self=self else{return}
                let sorted=blocks.sorted {let a=TranscriptTimeline.start($0.turn.item),b=TranscriptTimeline.start($1.turn.item);if a != b {return a<b};if $0.turn.parent != $1.turn.parent {return $0.turn.parent<$1.turn.parent};return $0.turn.id<$1.turn.id}
                let (fresh,text)=IncrementalTranscript.rebuilt(sorted,atoms:atoms)
                DispatchQueue.main.async {
                    guard self.fullTranscriptRefreshPending,self.fullRefreshGeneration==generation else{return}
                    self.fullRefreshBuildInFlight=false
                    guard self.dirtyTranscriptQueueIndex>=self.dirtyTranscriptQueue.count else {self.scheduleTranscriptRender();return}
                    guard let storage=self.output?.textStorage else{return}
                    let readingPosition=self.currentTranscriptReadingPosition()
                    let oldLength=storage.length;storage.setAttributedString(text)
                    fresh.noteFullReplacement(oldLength:oldLength);TranscriptTurnHeader.refresh(storage)
                    self.incrementalTranscript=fresh;self.fullRefreshBlocksByParent=[:];self.fullRefreshAtomsReady=false;self.fullTranscriptRefreshPending=false
                    self.updateMeetingContext()
                    self.empty?.isHidden=storage.length>0
                    self.restoreAfterTranscriptEdit(readingPosition)
                    self.footerDetails?.isHidden=false
                    self.meetingTranscriptProjectionDidSettle()
                }
            }
            return
        }
        empty.isHidden=storage.length>0
        if mutatesVisibleText && processed>0 {restoreAfterTranscriptEdit(readingPosition)}
        footerDetails?.isHidden=false
        if dirtyTranscriptQueueIndex<dirtyTranscriptQueue.count {scheduleTranscriptRender()}
        else {dirtyTranscriptQueue=[];dirtyTranscriptQueueIndex=0;meetingTranscriptProjectionDidSettle()}
    }
    func settleTranscriptForOfflineReview() throws {
        guard previewRenderOnly else{throw Failure(code:"offline_transcript_settle_scope")}
        let deadline=Date().addingTimeInterval(30)
        while (fullTranscriptRefreshPending || fullRefreshBuildInFlight || dirtyTranscriptQueueIndex<dirtyTranscriptQueue.count) && Date()<deadline {
            if !fullRefreshBuildInFlight {renderText()}
            _=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))
        }
        guard !fullTranscriptRefreshPending,!fullRefreshBuildInFlight,dirtyTranscriptQueueIndex>=dirtyTranscriptQueue.count else{throw Failure(code:"offline_transcript_settle_timeout")}
    }
    func textView(_ textView:NSTextView,clickedOnLink link:Any,at charIndex:Int)->Bool {
        guard let id=link as? String,let item=namingItem(id) else{return false};naming.register(segment:id,item:item);showSpeakerConfirmation(id);return true
    }
    func beginInlineName(_ id:String) {
        guard !(workspaceOwner ?? self).meetingDeletionBusy else{return}
        guard let item=namingItem(id) else{return}
        naming.register(segment:id,item:item)
        inlinePopover?.close();inlineSegment=id
        let controller=NSViewController();controller.view=NSView(frame:NSRect(x:0,y:0,width:280,height:164))
        let known=naming.key(segment:id) != nil
        let title=label(known ? "修改发言人" : "这句话是谁说的？",size:13,weight:.medium);title.frame=NSRect(x:16,y:136,width:248,height:20);controller.view.addSubview(title)
        let field=NSTextField(frame:NSRect(x:16,y:96,width:248,height:28));field.placeholderString="输入姓名";field.stringValue=naming.displayName(segment:id)?.value ?? "";controller.view.addSubview(field);inlineField=field
        let scope=FocusPopup(frame:NSRect(x:12,y:56,width:256,height:26));scope.addItems(withTitles:["修改本场姓名","只修改这句话"]);scope.item(at:0)?.isEnabled=known;scope.selectItem(at:known ? 0:1);inlineTargets=[:]
        for target in naming.choices(session:namingItem(id)?["session"] as? String ?? "") where target != naming.key(segment:id) {
            inlineTargets[scope.numberOfItems]=target
            scope.addItem(withTitle:"这句话是："+(naming.displayName(speaker:target)?.value ?? naming.displayLabel(speaker:target)))
        }
        scope.target=self;scope.action=#selector(changeInlineScope);controller.view.addSubview(scope);inlineScope=scope
        let undo=ImmediateButton(title:"撤销上次",target:self,action:#selector(undoName));undo.bezelStyle = .rounded;undo.frame=NSRect(x:12,y:8,width:96,height:28);controller.view.addSubview(undo)
        let done=ImmediateButton(title:"完成",target:self,action:#selector(commitInlineName));done.bezelStyle = .rounded;done.keyEquivalent="\r";done.frame=NSRect(x:184,y:8,width:84,height:28);controller.view.addSubview(done)
        let pop=NSPopover();pop.behavior = .transient;pop.contentViewController=controller;inlinePopover=pop
        if let range=incrementalTranscript.range(forTurn:id) ?? incrementalTranscript.range(forPart:id) {let rect=output.firstRect(forCharacterRange:NSRange(location:range.location,length:1),actualRange:nil);let inWindow=window.convertFromScreen(rect);let local=output.convert(inWindow,from:nil);if !documentIsPreview {pop.show(relativeTo:local,of:output,preferredEdge:.maxY)};pop.contentViewController?.view.window?.makeFirstResponder(field)}
    }
    @objc func changeInlineScope(){guard let scope=inlineScope,let target=inlineTargets[scope.indexOfSelectedItem] else{return};inlineField?.stringValue=naming.displayName(speaker:target)?.value ?? ""}
    func persistSessionNames(done:((Result<Void,Error>)->Void)?=nil) {
        guard let id=currentCacheID,UUID(uuidString:id) != nil,let session=activeSession else{done?(.failure(Failure(code:"meeting_names_scope_missing")));return}
        if Credential.offline && recoveryRootOverride==nil {done?(.failure(Failure(code:"meeting_names_fixture_scope_missing")));return}
        do {
            let file=recoveryBase().appendingPathComponent(id).appendingPathComponent("session-names.json"),data=try naming.snapshot(session:session)
            let confirmations=naming.voiceConfirmations,revision=naming.correctionRevision,generation=meetingDocumentGeneration
            if let scope=speakerRefinementScope,scope.correctionRevision != revision,
               (workspaceOwner ?? self).savedCoarseJobs[id] == nil {
                speakerRefinementNeedsRetry=true;cancelSpeakerRefinement()
            }
            cacheWriteQueue.async {
                do {
                    let previous=try? Data(contentsOf:file)
                    let priorObject=previous.flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
                    let priorIDs=Set((priorObject?["voiceConfirmations"] as? [[String:Any]] ?? []).compactMap{$0["id"] as? String})
                    let addedLearningIntent=confirmations.contains{!priorIDs.contains($0.id)}
                    let same=previous.flatMap{try? JSONSerialization.jsonObject(with:$0)}.flatMap{$0 as? NSDictionary}.map{old in (try? JSONSerialization.jsonObject(with:data)).flatMap{$0 as? NSDictionary}.map{old.isEqual(to:$0 as! [AnyHashable:Any])} ?? false} ?? false
                    if !same {try data.write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)}
                    DispatchQueue.main.async {
                        if self.activeSession==session,self.currentCacheID==id,self.meetingDocumentGeneration==generation,self.naming.correctionRevision==revision {
                            self.synchronizeCommittedVoiceMemory(session:session,confirmations:confirmations,revision:revision)
                            if addedLearningIntent,VoiceprintLearningPolicy().isEnabled {self.scheduleSavedVoiceRecognition()}
                        }
                        done?(.success(()))
                        if self.speakerRefinementNeedsRetry,self.activeSession==session,self.currentCacheID==id,
                           self.naming.correctionRevision==revision,[.paused,.stopped].contains(self.phase.phase),!self.sessionLocalOnly {
                            self.speakerRefinementNeedsRetry=false
                            self.scheduleSpeakerRefinement(trigger:"correction_retry",allowUnsealed:self.phase.phase == .paused)
                        }
                    }
                } catch {DispatchQueue.main.async {if self.currentCacheID==id,self.activeSession==session{self.diagnostic.stringValue="人物修改尚未保存，请重试"};done?(.failure(error))}}
            }
        } catch {diagnostic.stringValue="人物修改尚未保存，请重试";done?(.failure(error))}
    }
    @objc func commitInlineName(){guard let id=inlineSegment,namingItem(id) != nil,let field=inlineField else{return}
        let oldIdentity=transcriptIdentity(for:id),parent=transcriptParent(for:id)
        cancelPendingVoiceprintMemory()
        let selected=inlineScope?.indexOfSelectedItem ?? 1
        if let target=inlineTargets[selected] {guard naming.assign(segment:id,to:target,humanConfirmed:true,name:field.stringValue) else{return}}
        else if selected==0 {naming.setSpeaker(segment:id,name:field.stringValue)} else {naming.set(segment:id,name:field.stringValue)}
        if selected==0,let key=naming.key(segment:id),let name=naming.name(speaker:key) {rememberManualVoiceprint(key:key,name:name)}
        else if let name=naming.name(segment:id) {naming.attachConfirmation(segmentIDs:[id],name:name,learn:VoiceprintLearningPolicy().isEnabled)}
        diagnostic.stringValue=selected==0 ? "发言人姓名已更新":"这句话的发言人已更新"
        inlinePopover?.close();persistSessionNames();markNamingChange(segment:id,oldIdentity:oldIdentity,oldParent:parent)
    }
    @objc func clearInlineName(){cancelPendingVoiceprintMemory();guard let id=inlineSegment else{return};let oldIdentity=transcriptIdentity(for:id),parent=transcriptParent(for:id);if inlineScope?.indexOfSelectedItem==0 {naming.setSpeaker(segment:id,name:"")}else {naming.set(segment:id,name:"")};if lastWorkerManual[id] != nil {identityCommand("clear_feedback",fields:["segment_id":id])};inlinePopover?.close();persistSessionNames();markNamingChange(segment:id,oldIdentity:oldIdentity,oldParent:parent)}
    func transcriptExport()->String {transcriptExportSnapshot().text()}
    func assistExportTranslations(turns:[ReadingTurn])->[String:String] {
        guard translationService.enabled else{return [:]}
        var values:[String:String]=[:]
        for turn in turns {
            let translated=turn.parts.compactMap { id, part -> String? in
                guard MeetingTranslationPolicy.eligible(turn.item),MeetingTranslationPolicy.eligible(part) else{return nil}
                return translationService.translated(segmentID:id,source:part["text"] as? String ?? "")
            }.joined(separator:"\n")
            if !translated.isEmpty {values[turn.id]=translated}
        }
        return values
    }
    func transcriptExportSnapshot()->TranscriptExportSnapshot {
        let settled = dirtyTranscriptParents.isEmpty && !fullTranscriptRefreshPending && !fullRefreshBuildInFlight
        let turns=incrementalTranscript.trackedParentCount==segments.count && settled ? incrementalTranscript.allTurns():readingTurns()
        return TranscriptExportSnapshot(turns:turns,names:naming,meetingTitle:meetingTitle,sessionSource:sessionSource,phase:phase.phase,incomplete:currentCacheID != nil && !cachedTranscriptionComplete,observedTracks:observedTranscriptTracks,applicationNames:observedTranscriptApplications.sorted(),recoveredArchiveText:recoveredArchiveText,absoluteTime:absoluteTime,translations:assistExportTranslations(turns:turns))
    }
    var transcriptSuggestedFilename:String {
        let forbidden=CharacterSet.controlCharacters.union(CharacterSet(charactersIn:"/:\\"))
        let parts=meetingTitle.components(separatedBy:forbidden).filter{!$0.isEmpty}
        let title=String(parts.joined(separator:"_").trimmingCharacters(in:.whitespacesAndNewlines).prefix(80))
        let safe=title.isEmpty || title.allSatisfy({$0=="."}) ? "会议":title.hasPrefix(".") ? "会议"+title:title
        return safe+"－转写原文.txt"
    }
    @objc func exportTranscript(){guard !(workspaceOwner ?? self).meetingDeletionBusy else{return};guard !sequence.isEmpty || recoveredArchiveText != nil || currentCacheID != nil else{return}
        let url:URL?
        if let provider=savePanelURLProvider {url=provider()}
        else {let panel=NSSavePanel();panel.title="导出本场转写原文";panel.nameFieldStringValue=transcriptSuggestedFilename;panel.canCreateDirectories=true;panel.message="保存当前已有的文字；录音状态保持不变。";url=panel.runModal() == .OK ? panel.url:nil}
        guard let url=url else{return}
        saveTranscriptAsync(to:url)
    }
    func saveTranscriptAsync(to url:URL){
        guard !cacheExportJob.busy else{return}
        if !dirtyTranscriptParents.isEmpty || fullTranscriptRefreshPending || fullRefreshBuildInFlight {scheduleTranscriptRender();if !fullRefreshBuildInFlight {renderText()};let deferredGeneration=meetingDocumentGeneration;DispatchQueue.main.asyncAfter(deadline:.now()+0.02){[weak self] in guard let self,self.meetingDocumentGeneration==deferredGeneration else{return};self.saveTranscriptAsync(to:url)};return}
        let snapshot=transcriptExportSnapshot(),count=snapshot.turns.count,generation=meetingDocumentGeneration,cache=currentCacheID,session=activeSession
        diagnostic.stringValue="正在导出原文"
        let assistantDirectory = agentStoreOverride ?? recoveryBase().deletingLastPathComponent().appendingPathComponent(Credential.offline ? "DevelopmentQA/Assistant" : "Assistant")
        cacheExportJob.run(work:{
            let reminders = try cache.map { try meetingAssistantReminderExport(cacheID: $0, assistantDirectory: assistantDirectory) } ?? ""
            try (snapshot.text() + reminders).write(to:url,atomically:true,encoding:.utf8)
        }){[weak self] result in
            guard let self=self,self.meetingDocumentGeneration==generation,self.currentCacheID==cache,self.activeSession==session else{return}
            switch result {case .success:self.diagnostic.stringValue="本场全部\(count)段原文已导出"
            case .failure:self.diagnostic.stringValue="导出失败，请重试"}
        }
    }
    func persistRecordingLifecycle(done:@escaping(Result<Void,Error>)->Void){
        guard let id=currentCacheID,UUID(uuidString:id) != nil else {done(.success(()));return}
        let base=recoveryBase();let folder=base.appendingPathComponent(id,isDirectory:true)
        let session=activeSession ?? id;let elapsed=max(0,phase.elapsed)
        cacheWriteQueue.async {
            do {
                let values=try folder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                guard values.isDirectory==true,values.isSymbolicLink != true else{throw Failure(code:"meeting_cache_path_invalid")}
                let metadata:[String:Any]=["schema":1,"lifecycle":"ended","session":session,"recording_elapsed_seconds":elapsed,"ended_at":ISO8601DateFormatter().string(from:Date())]
                let data=try JSONSerialization.data(withJSONObject:metadata,options:[.sortedKeys])
                try data.write(to:folder.appendingPathComponent("meeting-lifecycle.json"),options:.atomic)
                DispatchQueue.main.async{done(.success(()))}
            } catch {DispatchQueue.main.async{done(.failure(error))}}
        }
    }
    func saveTranscript(to url:URL)throws {
        try transcriptExport().write(to:url,atomically:true,encoding:.utf8)
        diagnostic.stringValue="本场全部\(sequence.count)段原文已导出"
    }

    @objc func showFullTranscript(){showWholeTranscript=true;renderText();diagnostic.stringValue="已显示全部 \(sequence.count) 段原文"}
    @objc func showRecentTranscript(){showWholeTranscript=false;renderText();output?.scrollToEndOfDocument(nil);latest?.isHidden=true;diagnostic.stringValue="已定位到最近记录；完整原文仍保留"}
    @objc func nameSegment(){guard recoveredArchiveText==nil,let id=selectedSegment() else{return};beginInlineName(id)}
    func selectedSegment()->String? {incrementalTranscript.turnID(atCharacter:output.selectedRange().location)}
    @objc func confirmCandidate() {
        guard identityCandidatesEnabled,let id=selectedSegment(),let candidate=candidateBySegment[id],let name=people[candidate.0] else {
            let notice=NSAlert();notice.messageText=identityCandidatesEnabled ? "暂时无法确认这段发言人" : "人物识别尚未设置";notice.addButton(withTitle:"完成");notice.runModal();return
        }
        let notice=NSAlert();notice.messageText="这段可能是"+name;notice.informativeText="确认只标记本场文字，长期样本需要另外同意。";notice.addButton(withTitle:"确认");notice.addButton(withTitle:"不是此人");notice.addButton(withTitle:"稍后");notice.addButton(withTitle:"纠正为其他人物")
        let choice=notice.runModal();guard choice != .alertThirdButtonReturn,segments[id]?["revision"] as? Int==candidate.2 else{return}
        if choice.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue+3 {
            let correction=NSAlert();correction.messageText="纠正这段人物";correction.informativeText="仅改本场归属，不自动加样本。";let chooser=FocusPopup(frame:NSRect(x:0,y:0,width:330,height:28));let ids=people.keys.sorted();chooser.addItem(withTitle:"请选择正确人物");for person in ids {chooser.addItem(withTitle:people[person]!+" · "+String(person.prefix(6)))};correction.accessoryView=chooser;correction.addButton(withTitle:"确认纠正");correction.addButton(withTitle:"取消")
            if correction.runModal() == .alertFirstButtonReturn,chooser.indexOfSelectedItem>0 {let person=ids[chooser.indexOfSelectedItem-1];guard segments[id]?["revision"] as? Int==candidate.2 else{return};feedback.append(["feedback_id":UUID().uuidString,"segment_id":id,"person_id":person,"revision":candidate.1,"decision":"corrected"]);identityCommand("feedback",fields:["segment_id":id,"segment_revision":segments[id]?["revision"] ?? 0,"person_id":person,"decision":"corrected"]);let old=transcriptIdentity(for:id),parent=transcriptParent(for:id);naming.set(segment:id,name:people[person]!);markNamingChange(segment:id,oldIdentity:old,oldParent:parent);candidateBySegment.removeValue(forKey:id)};return
        }
        feedback.append(["feedback_id":UUID().uuidString,"segment_id":id,"person_id":candidate.0,"revision":candidate.1,"decision":choice == .alertFirstButtonReturn ? "confirmed" : "rejected"])
        identityCommand("feedback",fields:["segment_id":id,"segment_revision":segments[id]?["revision"] ?? 0,"person_id":candidate.0,"decision":choice == .alertFirstButtonReturn ? "confirmed" : "rejected"])
        if choice == .alertFirstButtonReturn {let old=transcriptIdentity(for:id),parent=transcriptParent(for:id);naming.set(segment:id,name:name);markNamingChange(segment:id,oldIdentity:old,oldParent:parent)};candidateBySegment.removeValue(forKey:id)
    }
    func identityMessage(_ code:String)->String {
        switch code {
        case "person_consent_required":return "先记录此人知情同意"
        case "human_identity_scope_not_authorized":return "请先完成人物识别设置"
        case "need_two_people_three_independent_samples_each":return "至少两人各三段独立样本"
        case "samples_not_separable_keep_unknown","held_out_sample_failed_keep_unknown":return "样本暂不能可靠区分，保持未知"
        case "segment_changed_or_unavailable":return "段落已变化，请重新选择"
        case "duplicate_audio_sample":return "这段已经登记，需另一段声音"
        default:return "条件未满足，资料没有改变"
        }
    }
    func identityCommand(_ operation:String,fields:[String:Any]=[:]) {
        if child != nil && activeSession == nil && !modelsPrepared {diagnostic.stringValue="正在准备，请稍候";return}
        guard !identityBusy else{diagnostic.stringValue="人物操作正在完成，请稍候";return};identityBusy=true
        let session=activeSession ?? "local-idle";var command=fields
        command.merge(["session":session,"operation":operation,"command_id":UUID().uuidString,"human_confirmed":true]){_,new in new}
        if let handle=workerInput,activeSession != nil {
            guard let data=try? JSONSerialization.data(withJSONObject:command) else{identityBusy=false;return}
            do {try handle.write(contentsOf:data+Data([10]))} catch {identityBusy=false;diagnostic.stringValue="人物连接已关闭，未保存"};return
        }
        let proc=Process();let input=Pipe();let outputPipe=Pipe();proc.executableURL=URL(fileURLWithPath:"/usr/local/bin/python3");proc.arguments=["-u",root+"/identity_control.py"];proc.standardInput=input;proc.standardOutput=outputPipe;proc.standardError=FileHandle.nullDevice
        var request:[String:Any]=["session":session,"synthetic_only":mock,"human_use_authorized":humanIdentityAuthorized,"command":command];if let state=identitySnapshot {request["state"]=state}
        var env=RuntimeConfiguration.childEnvironment();for key in ["DASHSCOPE_API_KEY","ALIYUN_API_KEY","BAILIAN_API_KEY"] {env.removeValue(forKey:key)};env["PYTHONDONTWRITEBYTECODE"]="1";proc.environment=env
        DispatchQueue.global().async {
            do {
                try proc.run();try input.fileHandleForWriting.write(contentsOf:try JSONSerialization.data(withJSONObject:request)+Data([10]));try input.fileHandleForWriting.close()
                let data=outputPipe.fileHandleForReading.readDataToEndOfFile();proc.waitUntilExit()
                guard data.count<=4_000_000 else{return}
                for row in data.split(separator:10) {if let event=(try? JSONSerialization.jsonObject(with:Data(row))) as? [String:Any] {DispatchQueue.main.async {self.receive(event)}}}
            } catch {DispatchQueue.main.async {self.identityBusy=false;self.diagnostic.stringValue="人物操作未完成，资料没有保存"}}
        }
    }
    @objc func manageConsent() {
        if !mock && !humanIdentityAuthorized {diagnostic.stringValue="人物识别暂未启用";return}
        let dialog=NSAlert();dialog.messageText="本机人物资料";dialog.informativeText="登记称呼不等于学习声音。勾选同意只允许本应用打开期间的本机身份匹配；退出即清除。长期保存另需明确批准。同名人物请分别登记。"
        let panel=NSView(frame:NSRect(x:0,y:0,width:360,height:145));let choice=FocusPopup(frame:NSRect(x:0,y:108,width:350,height:26));choice.addItem(withTitle:"选择已登记人物")
        let ids=people.keys.sorted();for id in ids {choice.addItem(withTitle:people[id]!+" · "+String(id.prefix(6)))}
        let name=NSTextField(frame:NSRect(x:0,y:69,width:350,height:26));name.placeholderString="人物姓名"
        let informed=ImmediateButton(checkboxWithTitle:"此人已知情并同意本应用暂存特征用于识别",target:nil,action:nil);informed.frame=NSRect(x:0,y:26,width:350,height:32)
        panel.addSubview(choice);panel.addSubview(name);panel.addSubview(informed);dialog.accessoryView=panel
        var consentTitles=["登记人物","记录同意","撤销同意","删除人物","取消"];if !trialCandidate {consentTitles.append("同意长期用途")};for title in consentTitles {dialog.addButton(withTitle:title)}
        let result=dialog.runModal().rawValue-NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if result==0 {let trimmed=name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines);guard !trimmed.isEmpty else{return};identityCommand("person",fields:["person_id":UUID().uuidString,"name":String(trimmed.prefix(80))]);return}
        guard choice.indexOfSelectedItem>0 else{return};let person=ids[choice.indexOfSelectedItem-1]
        if result==1 && informed.state == .on {identityCommand("consent",fields:["person_id":person,"person_informed":true,"ephemeral_use_allowed":true])}
        if result==5 && informed.state == .on {let note=NSAlert();note.messageText="此人的长期用途";note.informativeText="确认此人已知情并同意特征在本机跨会识别；可撤销和删除。该操作只记录用途，真正保存还需档案与Keychain密钥批准。";note.addButton(withTitle:"记录长期同意");note.addButton(withTitle:"取消");if note.runModal() == .alertFirstButtonReturn {identityCommand("persistent_consent",fields:["person_id":person,"person_informed":true,"persistent_use_allowed":true])}}
        if result==2 || result==3 {identityCommand(result==2 ? "revoke" : "delete",fields:["person_id":person]);candidateBySegment=candidateBySegment.filter{$0.value.0 != person};feedback=feedback.filter{$0["person_id"] != person}}
    }
    @objc func enrollSegment() {
        guard let sid=selectedSegment(),let segment=segments[sid],segment["identity_features"] is [String:Any] else {diagnostic.stringValue="需2–4秒单人清晰句末段，未知或叠说不能学习";return}
        let dialog=NSAlert();dialog.messageText="暂存这段声音特征";dialog.informativeText="选择真实人物并确认归属；仅使用已同意的本机暂存用途。文字改名不会代替这次确认，不保存原音。"
        let chooser=FocusPopup(frame:NSRect(x:0,y:0,width:330,height:28));let ids=people.keys.sorted();chooser.addItem(withTitle:"请选择人物");for id in ids {chooser.addItem(withTitle:people[id]!+" · "+String(id.prefix(6)))};dialog.accessoryView=chooser;dialog.addButton(withTitle:"确认暂存");dialog.addButton(withTitle:"取消")
        guard dialog.runModal() == .alertFirstButtonReturn,chooser.indexOfSelectedItem>0 else{return}
        identityCommand("sample",fields:["person_id":ids[chooser.indexOfSelectedItem-1],"segment_id":sid,"segment_revision":segment["revision"] ?? 0])
    }
    @objc func calibrateIdentity() {
        let dialog=NSAlert();dialog.messageText="用已确认样本校准";dialog.informativeText="至少两人各三段独立样本，留一段验证。不能分开的样本保持未知；相似度不是概率。新增或删除样本后需重新校准。";dialog.addButton(withTitle:"校准");dialog.addButton(withTitle:"取消")
        if dialog.runModal() == .alertFirstButtonReturn {identityCommand("calibrate")}
    }
    @objc func undoIdentity() {identityCommand("undo")}
    @objc func configureBalance() {
        if trialCandidate {return}
        let dialog=NSAlert();dialog.messageText="账户余额配置";dialog.informativeText="仅一次只读余额请求。由本人核验RAM动作bss:DescribeAcccount，Resource *；不授支付、充值或FullAccess。凭据与百炼密钥分开，默认只在内存。"
        let panel=NSView(frame:NSRect(x:0,y:0,width:390,height:220));let account=NSTextField(frame:NSRect(x:0,y:185,width:380,height:25));account.placeholderString="账户备注";let access=NSSecureTextField(frame:NSRect(x:0,y:148,width:380,height:25));access.placeholderString="专用RAM AccessKey ID（本人输入）";let secret=NSSecureTextField(frame:NSRect(x:0,y:111,width:380,height:25));secret.placeholderString="AccessKey Secret";let token=NSSecureTextField(frame:NSRect(x:0,y:74,width:380,height:25));token.placeholderString="短时STS SecurityToken（可选）"
        let permission=ImmediateButton(checkboxWithTitle:"已核验上述只读权限，同意本次查询",target:nil,action:nil);permission.frame=NSRect(x:0,y:25,width:380,height:35)
        for v in [account,access,secret,token,permission] as [NSView] {panel.addSubview(v)};dialog.accessoryView=panel
        for title in ["查询一次","本次连接","清除配置","取消"] {dialog.addButton(withTitle:title)}
        let result=dialog.runModal().rawValue-NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if result==2 {balanceCredentials=nil;balancePermission=false;balanceState=BalanceSnapshotState();updateUI();return}
        guard result==0 || result==1 else{return}
        applyBalanceInput(BalanceCredentials(accountLabel:String(account.stringValue.prefix(80)),accessID:access.stringValue,secret:secret.stringValue,securityToken:token.stringValue),permission:permission.state == .on,query:result==0)
    }
    func applyBalanceInput(_ credentials:BalanceCredentials,permission:Bool,query:Bool) {
        do {try credentials.validate()} catch {diagnostic.stringValue="凭据格式无效，没有保存或查询";return}
        balanceCredentials=credentials;balancePermission=permission;if query {queryBalance()};updateUI()
    }
    func queryBalance() {
        guard let credentials=balanceCredentials,balancePermission else {diagnostic.stringValue="需本人输入专用凭据并核验只读权限";return}
        if mock {do {try balanceState.accept(Data("{\"Success\":true,\"Data\":{\"AvailableCashAmount\":\"12.34\",\"AvailableAmount\":\"20.00\",\"Currency\":\"CNY\"}}".utf8),at:Date());updateUI()} catch {balanceState.fail();updateUI()};return}
        guard Bundle.main.object(forInfoDictionaryKey:"BalanceQueryAuthorized") as? Bool==true else {diagnostic.stringValue="余额查询暂未启用";return}
        Task { @MainActor in
            do {let request=try balanceRequest(credentials,at:Date(),nonce:UUID().uuidString,permissionConfirmed:balancePermission);let data=try await BalanceTransport().fetch(request);try balanceState.accept(data,at:Date())}
            catch {balanceState.fail()}
            updateUI()
        }
    }
    @objc func saveProfileArchive() {
        if trialCandidate {return}
        guard let state=identitySnapshot else{diagnostic.stringValue="还没有人物资料";return}
        guard mock || Bundle.main.object(forInfoDictionaryKey:"ProfileStorageAuthorized") as? Bool==true else{diagnostic.stringValue="人物资料保存尚未启用";return}
        let dialog=NSAlert();dialog.messageText="保存本机身份档案";dialog.informativeText="特征和事件历史AES-GCM加密。密钥存本机Keychain，当前应用可读；同一系统账户／管理员的权限仍需信任。档案与一份本机加密备份不上传。删除／撤销会重写两份，应用不能清理系统已有备份或保证磁盘取证擦除。"
        let panel=NSView(frame:NSRect(x:0,y:0,width:420,height:160));let labels=["同意本机跨会识别用途","同意生成专用Keychain加密密钥","同意保存到本机应用支持目录","理解备份和删除范围"]
        var boxes:[NSButton]=[];for (i,title) in labels.enumerated(){let box=ImmediateButton(checkboxWithTitle:title,target:nil,action:nil);box.frame=NSRect(x:0,y:CGFloat(125-i*35),width:415,height:28);panel.addSubview(box);boxes.append(box)};dialog.accessoryView=panel;dialog.addButton(withTitle:"保存");dialog.addButton(withTitle:"取消")
        guard dialog.runModal() == .alertFirstButtonReturn,boxes.allSatisfy({$0.state == .on}) else{return}
        let folder=mock ? URL(fileURLWithPath:root+"/native/validation-workflow/fake-profile") : RuntimeConfiguration.dataRoot(legacyJoeIdentity:true).appendingPathComponent("Identity",isDirectory:true)
        let grant=ProfileStorageGrant(purposeAccepted:true,keychainKeyAccepted:true,localFolderAccepted:true,backupDeletionAccepted:true)
        let keys:ProfileKeyProvider=mock ? FakeProfileKeyProvider() : KeychainProfileProvider(permitted:true)
        let store=ProfileArchiveStore(folder:folder,domain:mock ? "synthetic_model_output" : "consented_live_audio",keys:keys,grant:grant)
        do {try store.save(state);profileStore=store;diagnostic.stringValue="加密档案已保存；未保存原音"}catch{diagnostic.stringValue="档案未保存，检查人物长期同意与权限"}
    }
    @objc func restoreProfileArchive() {
        if trialCandidate {return}
        guard mock || Bundle.main.object(forInfoDictionaryKey:"ProfileStorageAuthorized") as? Bool==true else{diagnostic.stringValue="请先启用人物资料保存";return}
        let folder=mock ? URL(fileURLWithPath:root+"/native/validation-workflow/fake-profile") : RuntimeConfiguration.dataRoot(legacyJoeIdentity:true).appendingPathComponent("Identity",isDirectory:true)
        let grant=ProfileStorageGrant(purposeAccepted:true,keychainKeyAccepted:true,localFolderAccepted:true,backupDeletionAccepted:true)
        let provider:ProfileKeyProvider=mock ? FakeProfileKeyProvider() : KeychainProfileProvider(permitted:true)
        let store=profileStore ?? ProfileArchiveStore(folder:folder,domain:mock ? "synthetic_model_output" : "consented_live_audio",keys:provider,grant:grant);profileStore=store
        do {let state=try store.load();identitySnapshot=state;people=state["people"] as? [String:String] ?? [:];identityCandidatesEnabled=state["calibration"] is [String:Any];diagnostic.stringValue="人物资料已恢复"}catch{diagnostic.stringValue="人物资料恢复失败，请重试"}
    }
    @objc func eraseProfileArchive() {
        if trialCandidate {return}
        guard let store=profileStore else{return};let dialog=NSAlert();dialog.messageText="删除本机全部身份档案？";dialog.informativeText="删除当前档案、应用加密备份和专用密钥；退出后不能恢复。系统外部备份需本人另外管理。";dialog.addButton(withTitle:"删除");dialog.addButton(withTitle:"取消")
        if dialog.runModal() == .alertFirstButtonReturn {do {try store.removeAll();profileStore=nil;identityCommand("forget_all",fields:[:]);identitySnapshot=nil;people=[:];candidateBySegment=[:];feedback=[];lastWorkerManual=[:];naming.reset();identityCandidatesEnabled=false;markAllTranscriptParentsDirty();diagnostic.stringValue="本机档案与专用密钥已删除"}catch{diagnostic.stringValue="删除未完成，请检查本机权限"}}
    }
    @objc func showWorkspaceDetails(){displayedDocument.showDetails()}
    @objc func undoName() {
        if undoQuickVoiceConfirmationIfAvailable() {return}
        cancelPendingVoiceprintMemory()
        inlinePopover?.close();guard naming.undo() != nil else{return}
        for id in naming.lastUndoSegmentIDs {if feedback.contains(where:{$0["segment_id"]==id}) {identityCommand("clear_feedback",fields:["segment_id":id])};feedback=feedback.filter{$0["segment_id"] != id};candidateBySegment.removeValue(forKey:id)}
        persistSessionNames();markAllTranscriptParentsDirty();cacheWriteQueue.async{[weak self] in DispatchQueue.main.async{[weak self] in guard let self=self else{return};(self.workspaceOwner ?? self).reloadLibrary()}}
    }

    @objc func goLatest() {cancelTranscriptReadingRestore();output.scrollToEndOfDocument(nil);latest.isHidden=true;footerDetails?.isHidden=false}
    func mockStep() {
        guard phase.phase == .connecting || phase.phase == .recording else {return};mockTick+=1
        if mockTick==1 {receive(offlineQA ? ["type":"started","session":qaSession,"cache_id":currentCacheID ?? "","capture":false,"mock":true,"audio_frames_received":true]:["type":"started"])}
        if offlineQA {receive(["type":"meter","elapsed_seconds":Double(mockTick)*0.4,"estimated_yuan":"0"]);qaUtterance(mockTick);return}
        let secs=Double(mockTick)*0.4;receive(["type":"meter","elapsed_seconds":secs,"estimated_yuan":String((secs+secs*0.8)*0.00033)])
        let count=min(17,mockTick)
        let body=count>=17 ? "今天先确认三个创意方向，再安排下一步。" : String("今天先确认三个创意方向，再安排下一步。".prefix(count))
        receive(["type":"segment","segment_id":"one","track":"remote","text":body,"final":count>=17])
        if useMic && mockTick>=5 {receive(["type":"segment","segment_id":"two","track":"mic","text":"预算先按1500元。","final":true])}
    }
    func finishRecording() {
        guard !mock,!offlineQA,!sessionLocalOnly,!quitting,!preparingModels,
              [.recording,.paused].contains(phase.phase),child?.isRunning==true,
              let session=activeSession,let input=workerInput else{end();return}
        let command:[String:Any]=["operation":"recording_control","action":"finish","session":session]
        do {
            try input.write(contentsOf:try JSONSerialization.data(withJSONObject:command)+Data([10]))
            _=phase.stop();recordingControlTimeout?.cancel();recordingControlInFlight=nil;timer?.invalidate()
            diagnostic.stringValue="正在保存录音并补齐已录内容的转写";updateUI()
        } catch {end();diagnostic.stringValue="保存连接中断，原音已保留；未完成部分可重试转写";updateUI()}
    }
    @objc func end() {
        pendingAutomaticTailRecovery=nil
        if credentialReadJob.waiting {
            credentialReadJob.cancel();phase.phase = .stopped;phase.error=nil
            diagnostic.stringValue="连接已取消，未开始录音";updateUI();return
        }
        if offlineQA && qaStore != nil {finishQAMeeting();return}
        if processingAudio,let proc=child {proc.interrupt();diagnostic.stringValue="整理已取消，未转完原音留在本机";return}

        if preparingModels || modelsPrepared {preparingModels=false;modelsPrepared=false;phase.phase = .stopping}
        else {guard phase.stop() else {return}}
        timer?.invalidate();updateUI()
        if mock {
            if let mockStopHandler=mockStopHandler {mockStopHandler();return}
            DispatchQueue.main.asyncAfter(deadline:.now()+0.35) {
                self.receive(["type":"segment","segment_id":"one","track":"remote","text":"今天先确认三个创意方向，再安排下一步。","final":true])
                self.receive(["type":"stopped","reason":"user_stop"])
            }
            return
        }
        guard let proc=child else {phase.phase = .stopped;updateUI();return}
        kill(proc.processIdentifier,SIGINT)
        // The independent worker supervisor bounds stop completion. Pending
        // original audio stays recoverable; a wedged helper cannot keep uploading.
        if quitting {DispatchQueue.main.asyncAfter(deadline:.now()+0.25){if proc.isRunning {proc.interrupt()}}}
    }
    func remainingSeconds()->Int {availableCloudSeconds}
    func refreshCloudBudget(){budgetReadJob.run(work:{self.readRemainingSeconds()}){[weak self] result in guard let self=self else{return};switch result {case .success(let seconds):self.availableCloudSeconds=seconds;self.newRecordingPending=seconds<=0;if seconds<=0 && !self.modeUserSelected {self.localOnlyMode=true;self.recordingModePicker?.selectItem(at:1)};self.diagnostic.stringValue=seconds<=0 ? "转写用量已达上限，仍可录音":"转写服务可用";case .failure:self.availableCloudSeconds=0;self.newRecordingPending=true;self.diagnostic.stringValue="无法获取转写用量，请稍后重试"};self.updateUI()}}
    func readRemainingSeconds()->Int {
        guard let data=try? Data(contentsOf:URL(fileURLWithPath:root+"/trial-health.json")),let h=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else {return 450}
        let prior=h["previous_wall_seconds"] as? Double ?? 0
        var used=prior+(h["elapsed_seconds"] as? Double ?? 0)
        if ["active","launching"].contains(h["phase"] as? String ?? "") {used=max(used,prior+(h["max_seconds"] as? Double ?? 450))}
        guard used.isFinite else{return 0}
        let original=min(450,max(0,Int(480-used)))
        if trialCandidate {
            guard let data=try? Data(contentsOf:URL(fileURLWithPath:root+"/native/candidate-build/trial-allowance.json")),let allowance=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let baseline=allowance["baseline_wall_seconds"] as? Double,baseline.isFinite,allowance["max_candidate_wall_seconds"] as? Int==180 else{return 0}
            return min(original,max(0,Int(180-max(0,used-baseline))))
        };return original
    }
    @objc func showDetails() {loadRecordDetails()}
    @objc func paste(_ sender:Any?) {
        if let editor=window.firstResponder as? MeetingNoteEditor {editor.paste(sender);return}
        if mock,Bundle.main.object(forInfoDictionaryKey:"FakeClipboardInputEnabled") as? Bool != true {guard let editor=sheet.fieldEditor(false,for:key) as? NSTextView else {return};editor.insertText(fixtureBoard.string(forType:.string) ?? "fake",replacementRange:editor.selectedRange())}
        else {NSApp.sendAction(#selector(NSText.paste(_:)),to:nil,from:sender)}
    }
    @objc func validationScenario(_ item:NSMenuItem) {
        guard offlineQA else {return};timer?.invalidate()
        if item.tag==9 || item.tag==10 {
            phase=UIState();phase.phase = .recording;phase.elapsed=123;phase.estimated=0.12;segments=[:];sequence=[];sessionSource="腾讯会议";naming.reset()
            for i in 0..<20 {receive(["type":"segment","segment_id":"review-\(i)","session":"synthetic-ui","track":i%3==1 ? "mic":"remote","text":"先把品牌主张讲清楚，再比较用户反馈与预算。这段仅为界面验证的虚构文字。","final":i != 19,"revision":1,"speaker":["basis":"unknown"]])}
            naming.set(segment:"review-0",name:"张宇 · 品牌策略与增长运营负责人");markTranscriptParentDirty("review-0")
            if item.tag==10 {balanceState.cash="1234567890.12";balanceState.currency="CNY";phase.estimated=99999.99}
            renderText();updateUI();return
        }
        switch item.tag {
        case 1,11,12,13:phase.phase = .recording;phase.error=nil;let types=[1:"asr_reconnecting",11:"asr_catching_up",12:"asr_resumed",13:"asr_pending"];receive(["type":types[item.tag]!,"track":"mic"])
        case 2:phase.phase = .failed;phase.error="没有录音权限，请在系统设置中允许"
        case 3:phase.phase = .recording;phase.error=nil;segments=[:];sequence=[];expandedParents=[:];transcriptCapacity.reset();transcriptLimitHit=false;showWholeTranscript=true;output.string="";empty.stringValue="还没听到声音";empty.isHidden=false
        case 4:phase.phase = .ended;phase.error=nil;empty.isHidden=true
        case 5:window.setContentSize(NSSize(width:640,height:480))
        case 6:window.setContentSize(NSSize(width:800,height:620))
        case 7:NSApp.appearance=NSAppearance(named:.darkAqua)
        case 8:NSApp.appearance=NSAppearance(named:.aqua)
        default:phase.phase = .idle;phase.error=nil
        }
        updateUI()
    }
    @objc func validateIcon() {
        guard mock else {return}
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:360,height:160),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        panel.title="图标32点原生验证";panel.isReleasedWhenClosed=false
        let icon=NSWorkspace.shared.icon(forFile:Bundle.main.bundlePath)
        for (x,color) in [(CGFloat(0),NSColor.white),(CGFloat(180),NSColor(calibratedWhite:0.12,alpha:1))] {
            let background=NSView(frame:NSRect(x:x,y:0,width:180,height:160));background.wantsLayer=true;background.layer?.backgroundColor=color.cgColor
            let image=NSImageView(frame:NSRect(x:74,y:64,width:32,height:32));image.image=icon;image.imageScaling = .scaleProportionallyUpOrDown;background.addSubview(image);panel.contentView?.addSubview(background)
        }
        panel.center();panel.makeKeyAndOrderFront(nil)
    }
    @objc func exportReviewShot() {
        guard mock,window.isVisible else{return};let directory=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("joesang-meeting-ui-review");try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let stamp=String(Int(Date().timeIntervalSince1970));let targets:[(String,NSView?)]=[("main-"+phase.phase.rawValue,window.contentView),("settings",window.attachedSheet?.contentView),("person",inlinePopover?.isShown==true ? inlinePopover?.contentViewController?.view : nil)]
        for (name,target) in targets {guard let target=target,let bitmap=target.bitmapImageRepForCachingDisplay(in:target.bounds) else{continue};target.effectiveAppearance.performAsCurrentDrawingAppearance { target.cacheDisplay(in:target.bounds,to:bitmap) };let image=NSImage(size:target.bounds.size);image.lockFocus();target.effectiveAppearance.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill();NSBezierPath(rect:NSRect(origin:.zero,size:target.bounds.size)).fill();bitmap.draw(in:NSRect(origin:.zero,size:target.bounds.size)) };image.unlockFocus();guard let tiff=image.tiffRepresentation,let opaque=NSBitmapImageRep(data:tiff) else{continue};if let png=opaque.representation(using:.png,properties:[:]) {try? png.write(to:directory.appendingPathComponent(stamp+"-"+name+".png"))}}
    }
    func installMenus() {
        let menu=NSMenu();let item=NSMenuItem();menu.addItem(item);let appMenu=NSMenu();let config=appMenu.addItem(withTitle:"设置…",action:#selector(showSettings),keyEquivalent:",");config.target=self;appMenu.addItem(.separator());let quit=appMenu.addItem(withTitle:"退出在场",action:#selector(quitApplication),keyEquivalent:"q");quit.target=self;item.submenu=appMenu
        let editItem=NSMenuItem();menu.addItem(editItem);let edit=NSMenu(title:"编辑");edit.addItem(withTitle:"剪切",action:#selector(NSText.cut(_:)),keyEquivalent:"x");edit.addItem(withTitle:"复制",action:#selector(NSText.copy(_:)),keyEquivalent:"c");let paste=edit.addItem(withTitle:"粘贴",action:#selector(paste(_:)),keyEquivalent:"v");paste.target=self;edit.addItem(withTitle:"全选",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a");editItem.submenu=edit
        let find=edit.addItem(withTitle:"搜索原文…",action:#selector(showDocumentSearch),keyEquivalent:"f");find.target=self
        let recovery=edit.addItem(withTitle:"历史会议…",action:#selector(showRecoveries),keyEquivalent:"");recovery.target=self
        let libraryFind=edit.addItem(withTitle:"搜索会议…",action:#selector(showLibrarySearch),keyEquivalent:"f");libraryFind.keyEquivalentModifierMask=[.command,.shift];libraryFind.target=self
        let rename=edit.addItem(withTitle:"重命名所选记录…",action:#selector(renameSelectedLibraryMeeting),keyEquivalent:"r");rename.keyEquivalentModifierMask=[.command,.shift];rename.target=self
        let delete=edit.addItem(withTitle:"删除所选记录…",action:#selector(deleteSelectedLibraryMeeting),keyEquivalent:"");delete.target=self
        let transcribe=edit.addItem(withTitle:"转写所选录音…",action:#selector(transcribeSelectedLibraryMeeting),keyEquivalent:"");transcribe.target=self
        let exportMinutes=edit.addItem(withTitle:"导出纪要…",action:#selector(exportVisibleMinutes),keyEquivalent:"");exportMinutes.target=self
        let exportText=edit.addItem(withTitle:"导出原文…",action:#selector(exportVisibleDocument),keyEquivalent:"");exportText.target=self
        let peopleReview=edit.addItem(withTitle:"按发言人查看…",action:#selector(showSpeakerReview),keyEquivalent:"p");peopleReview.target=self
        let details=edit.addItem(withTitle:"会议详情…",action:#selector(showWorkspaceDetails),keyEquivalent:"");details.target=self
        let resume=edit.addItem(withTitle:"继续这场录音…",action:#selector(resumeViewedMeeting),keyEquivalent:"");resume.target=self
        let assign=edit.addItem(withTitle:"修改发言人…",action:#selector(nameVisibleSegment),keyEquivalent:"");assign.target=self;let undoAssign=edit.addItem(withTitle:"撤销发言人修改",action:#selector(undoVisibleName),keyEquivalent:"");undoAssign.target=self
        let candidate=edit.addItem(withTitle:"确认当前段身份候选…",action:#selector(confirmCandidate),keyEquivalent:"");candidate.target=self;let sample=edit.addItem(withTitle:"暂存本场身份样本…",action:#selector(enrollSegment),keyEquivalent:"");sample.target=self;let calibration=edit.addItem(withTitle:"校准人物匹配…",action:#selector(calibrateIdentity),keyEquivalent:"");calibration.target=self;let undoPerson=edit.addItem(withTitle:"撤销人物操作",action:#selector(undoIdentity),keyEquivalent:"");undoPerson.target=self;let saveArchive=edit.addItem(withTitle:"保存加密身份档案…",action:#selector(saveProfileArchive),keyEquivalent:"");saveArchive.target=self;let restoreArchive=edit.addItem(withTitle:"恢复加密身份档案",action:#selector(restoreProfileArchive),keyEquivalent:"");restoreArchive.target=self;let eraseArchive=edit.addItem(withTitle:"删除本机身份档案…",action:#selector(eraseProfileArchive),keyEquivalent:"");eraseArchive.target=self;let consent=edit.addItem(withTitle:"当前人物声纹同意／撤销…",action:#selector(manageConsent),keyEquivalent:"");consent.target=self
        if !mock && !humanIdentityAuthorized {
            for entry in [candidate,sample,calibration,undoPerson,saveArchive,restoreArchive,eraseArchive,consent] {edit.removeItem(entry)}
        } else if trialCandidate {edit.removeItem(saveArchive);edit.removeItem(restoreArchive);edit.removeItem(eraseArchive)}
        let winItem=NSMenuItem();menu.addItem(winItem);let winMenu=NSMenu(title:"窗口");let close=winMenu.addItem(withTitle:"关闭",action:#selector(closeWindow),keyEquivalent:"w");close.target=self;winItem.submenu=winMenu
        if offlineQA {
            let node=NSMenuItem();menu.addItem(node);let testing=NSMenu(title:"验证")
            for (tag,title) in [(1,"等待网络"),(11,"追赶转写"),(12,"转写恢复"),(13,"转写暂停"),(2,"拒绝录音权限"),(3,"无声音"),(4,"体验结束"),(5,"小窗口"),(6,"标准窗口"),(7,"深色"),(8,"浅色"),(9,"长正文与长姓名"),(10,"长金额"),(0,"准备就绪")] {
                let choice=testing.addItem(withTitle:title,action:#selector(validationScenario(_:)),keyEquivalent:"");choice.target=self;choice.tag=tag
            }
            let iconCheck=testing.addItem(withTitle:"图标32点",action:#selector(validateIcon),keyEquivalent:"");iconCheck.target=self
            let capture=testing.addItem(withTitle:"保存当前界面截图",action:#selector(exportReviewShot),keyEquivalent:"s");capture.keyEquivalentModifierMask=[.command,.shift];capture.target=self
            node.submenu=testing
        }
        installQAMenu(menu)
        NSApp.mainMenu=menu
    }
    @objc func quitApplication(){_ = closeAttachedSheet();NSApp.terminate(nil)}
    private func closeAttachedSheet()->Bool {
        guard let attached=window.attachedSheet else{return false}
        if attached === sheet {dismissSettings()}
        else {window.endSheet(attached,returnCode:.cancel);attached.orderOut(nil)}
        return true
    }
    @objc func closeWindow() {closeWindowTarget(NSApp.keyWindow)}
    func closeWindowTarget(_ foreground:NSWindow?) {
        if closeAttachedSheet() {}
        else if MeetingRecordDetailsWindow.closeIfVisible(foreground) {}
        else if MeetingRecycleBinController.closeIfVisible(foreground) {}
        else if !closeSpeakerReviewWindow(foreground) {(foreground ?? window)?.performClose(nil)}
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        if sender==sheet {dismissSettings();return false}
        let notesSaved = notesController?.flushForClosing() ?? true
        let historyNotesSaved = historyReader?.notesController?.flushForClosing() ?? true
        guard notesSaved && historyNotesSaved else { return false }
        // The recording owner outlives its window; Dock reopen restores this same workspace.
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if quitting {return terminationReplyPending ? .terminateLater:.terminateNow}
        let notesSaved = notesController?.flushForClosing() ?? true
        let historyNotesSaved = historyReader?.notesController?.flushForClosing() ?? true
        guard notesSaved && historyNotesSaved else { return .terminateCancel }
        quitting=true;recordingAttention.cancel()
        if let agentController {terminationJobsPending+=1;agentController.shutdown { [weak self] in guard let self else{return};self.terminationJobsPending-=1;self.completeApplicationTerminationIfReady()}}
        newRecordingPending=false;newMeetingRequested=false
        pendingAutomaticTailRecovery=nil;credentialReadJob.cancel();budgetReadJob.cancel()
        timer?.invalidate();audioLevelTimer?.invalidate()
        invalidateAutoTitle();for task in finalTitleTasks.values {task.cancel()};finalTitleTasks.removeAll()
        titleProvider=nil;titleTextAllowed=false
        var jobs=Array(savedCoarseJobs.values)+[speakerRefinementJob,savedVoiceRecognitionJob]
        if let historyReader {jobs.append(historyReader.speakerRefinementJob);jobs.append(historyReader.savedVoiceRecognitionJob)}
        var seen=Set<ObjectIdentifier>()
        for job in jobs where seen.insert(ObjectIdentifier(job)).inserted {
            if job.hasPendingWork {
                terminationJobsPending+=1
                job.cancelAndWait { [weak self] in
                    guard let self else{return};self.terminationJobsPending-=1
                    self.completeApplicationTerminationIfReady()
                }
            } else {job.cancel()}
        }
        savedCoarseJobs.removeAll();cancelSpeakerRefinement();speakerRefinementNeedsRetry=false
        historyReader?.quitting=true;historyReader?.cancelSpeakerRefinement()
        // Stop even when already draining a paused/finished recording. UIState.stop()
        // deliberately rejects .stopping, so normal End cannot be the quit gate.
        if let child,child.isRunning {
            child.interrupt()
            // The first stop closes capture; the second cancels any saved-audio tail.
            DispatchQueue.main.asyncAfter(deadline:.now()+0.25) {if child.isRunning {child.interrupt()}}
        } else if offlineQA && qaStore != nil {finishQAMeeting()}
        terminationReplyPending=true
        completeApplicationTerminationIfReady()
        return .terminateLater
    }
    func completeApplicationTerminationIfReady() {
        guard quitting,terminationReplyPending,child==nil,terminationJobsPending==0,
              !meetingDeletionBusy,!audioAssetOperationBusy,!qaWriteJob.busy else{return}
        if !terminationWriteBarrierStarted {
            terminationWriteBarrierStarted=true;terminationJobsPending+=1
            let writes=DispatchGroup()
            var queues=[cacheWriteQueue,MeetingNotesStore.queue]
            if let historyReader {queues.append(historyReader.cacheWriteQueue)}
            for queue in queues {writes.enter();queue.async {writes.leave()}}
            writes.notify(queue:.main) { [weak self] in
                guard let self else{return};self.terminationJobsPending-=1
                self.completeApplicationTerminationIfReady()
            }
            return
        }
        terminationReplyPending=false
        if let terminationReplyOverride {terminationReplyOverride()}else{NSApp.reply(toApplicationShouldTerminate:true)}
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {window.makeKeyAndOrderFront(nil);return true}
}
@main struct UIEntry {
    @MainActor static func runMeetingNotesChecks() -> Bool {
        guard CommandLine.arguments.count==3,["--meeting-notes-self-test","--meeting-notes-storage-self-test"].contains(CommandLine.arguments[1]),Credential.offline else{return false}
        do {let result=try meetingNotesChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]),storageOnly:CommandLine.arguments[1]=="--meeting-notes-storage-self-test");print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("meeting-notes-failed: \(error)");exit(1)}
        return true
    }
    @MainActor static func recoveryUIChecks(directory:URL)throws->[String:Any] {
        _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let base=directory.appendingPathComponent("recovery-ui-fixtures");try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        let raw=try Data(contentsOf:directory.appendingPathComponent("public-mic-fixture/input.pcm"));let pcm=Data(raw.prefix(160000));var checks=0;var nativeRuns=0
        func make()->CachedMeeting {
            let id=UUID().uuidString;let folder=base.appendingPathComponent(id);let store=try! RecordingJournal(directory:folder,track:"mic",freeSpace:{1_000_000_000})
            for offset in stride(from:0,to:pcm.count,by:3200){try! store.enqueue(Data(pcm[offset..<offset+3200]),at:1_000_000_000+Double(offset)/32000)};store.finish();store.wait()
            let session="fixture-"+id
            for (sid,start,end,final) in [("old-final",0.0,1.0,true),("old-partial",1.0,1.5,false)] {store.record(["type":"segment","session":session,"application":"*microphone*","segment_id":sid,"revision":1,"track":"mic","start":start,"end":end,"end_time_known":true,"text":"离线恢复占位文本","final":final,"speaker":["basis":"unknown"]])}
            store.wait();try! store.commit("asr",cursor:32000);store.wait()
            let meta:[String:Any]=["session":session,"bundle":"*microphone*","asr_destination":"dashscope.aliyuncs.com","asr_model":"qwen-audio-3.0-asr-flash-streaming"]
            try! JSONSerialization.data(withJSONObject:meta).write(to:folder.appendingPathComponent("meeting.json"))
            return try! cachedMeetings(in:base).first{$0.id==id}!
        }
        func delegate()->Delegate {let value=Delegate();value.previewRenderOnly=true;value.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));value.recoveryRootOverride=base;return value}
        func waitIO(_ view:Delegate){let until=Date().addingTimeInterval(5);while (view.cacheReadJob.busy || view.cacheExportJob.busy) && Date()<until {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))};precondition(!view.cacheReadJob.busy && !view.cacheExportJob.busy)}
        func select(_ view:Delegate,_ item:CachedMeeting){view.showRecoveries();waitIO(view);view.recoveryPicker!.selectItem(at:view.recoveries.firstIndex{$0.id==item.id}!);view.changeRecoverySelection()}
        func native(_ view:Delegate,_ item:CachedMeeting,_ mode:String)throws {
            let root=URL(fileURLWithPath:view.root);let candidate=Bundle.main.object(forInfoDictionaryKey:"CandidateRevision") as? String=="repair"
            let binary=view.captureExecutableURL
            let process=Process();let output=Pipe();process.executableURL=binary;process.arguments=["--recovery-fixture",item.id,mode];process.standardOutput=output;process.standardError=FileHandle.nullDevice;try process.run();let data=output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit();guard process.terminationStatus==0 else{throw Failure(code:"fixture_native_failed")};nativeRuns+=1
            for line in data.split(separator:10) {if let event=try? JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] {view.receive(event)}}
        }
        let item=make()
        let torn=try FileHandle(forWritingTo:item.directory.appendingPathComponent("mic-transcript.jsonl"));try torn.seekToEnd();try torn.write(contentsOf:Data("{\"type\":\"segment\"".utf8));try torn.close()
        let view=delegate();select(view,item)
        precondition(view.exportButton != nil);checks+=1
        let second=make();select(view,second);view.recoveries.reverse();view.changeRecoverySelection()
        precondition(view.selectedRecovery()?.id==second.id && view.recoveryDetail!.stringValue.contains(String(second.id.prefix(8))) && view.recoveryPicker!.selectedItem!.title==second.label);checks+=1
        let oldPanel=view.recoveryPanel;select(view,item)
        precondition(view.recoveryPanel !== oldPanel && view.selectedRecovery()?.id==item.id);checks+=1
        precondition(view.recoveryDetail!.stringValue.contains("待转 4.0") && view.recoveryDetail!.stringValue.contains("本地"));checks+=1
        view.recoveryBudgetOverride=0;var starts=0;view.recoveryRunnerOverride={_ in starts+=1};view.recoveryContinue!.performClick(nil)
        precondition(starts==0 && !view.resumeBusy && view.recoveryDetail!.stringValue.contains("额度已用完"));checks+=1
        view.recoveryOriginal!.performClick(nil);waitIO(view);precondition(view.sequence.count==2 && view.transcriptExport().contains("离线恢复占位文本"));checks+=1
        view.beginInlineName("old-final");view.inlineField!.stringValue="本场测试人物";view.commitInlineName();precondition(view.naming.name(segment:"old-final")=="本场测试人物");checks+=1
        let partial=base.appendingPathComponent("partial-export.txt");try view.saveTranscript(to:partial);precondition(try! String(contentsOf:partial).contains("离线恢复占位文本"));precondition(FileManager.default.fileExists(atPath:item.directory.appendingPathComponent("mic-000000.pcm").path));checks+=1
        select(view,item);view.laterRecovery();precondition(starts==0 && view.recoveryPanel==nil);checks+=1
        view.cacheWriteQueue.sync{};let reopened=delegate();select(reopened,item);precondition(reopened.recoveries.contains{$0.id==item.id});checks+=1
        reopened.cacheWriteQueue.sync{};reopened.viewRecoveryOriginal();waitIO(reopened);precondition(reopened.naming.name(segment:"old-final")=="本场测试人物");checks+=1
        select(reopened,item)
        reopened.recoveryBudgetOverride=10;var selected:CachedMeeting?;reopened.recoveryRunnerOverride={selected=$0;starts+=1};reopened.recoveryContinue!.performClick(nil);waitIO(reopened);reopened.continueRecovery();precondition(starts==1 && reopened.resumeBusy);checks+=1
        try native(reopened,selected!,"offline");precondition(!reopened.resumeBusy && !reopened.cachedTranscriptionComplete && (try! cachedMeetings(in:base).first{$0.id==item.id}!).pendingBytes==128000);checks+=1
        select(reopened,try! cachedMeetings(in:base).first{$0.id==item.id}!);reopened.recoveryContinue!.performClick(nil);waitIO(reopened);try native(reopened,selected!,"disconnect")
        precondition(reopened.cachedTranscriptionComplete && !reopened.resumeBusy && reopened.segments["old-partial"]==nil);checks+=1
        precondition(FileManager.default.fileExists(atPath:item.directory.appendingPathComponent("mic-transcript-incomplete-tail.bin").path));checks+=1
        let finals=reopened.segments.values.filter{$0["final"] as? Bool==true};precondition(finals.count==5 && Set(finals.compactMap{$0["start"] as? Double}).count==5);checks+=1
        precondition(finals.allSatisfy{($0["received_at"] as? Double ?? 0)>=0});checks+=1
        precondition(!reopened.transcriptExport().contains("未完成稿") && reopened.transcriptExport().contains("old-final")==false);checks+=1
        do {try reopened.saveTranscript(to:base.appendingPathComponent("missing-directory/result.txt"));preconditionFailure()}catch{}
        precondition(FileManager.default.fileExists(atPath:item.directory.appendingPathComponent("mic-000000.pcm").path));checks+=1
        reopened.recoveryRetireOverride={_ in throw Failure(code:"fixture_retirement_failed")};try reopened.saveTranscript(to:base.appendingPathComponent("retirement-failed-export.txt"));precondition(FileManager.default.fileExists(atPath:item.directory.appendingPathComponent("mic-000000.pcm").path));checks+=1
        reopened.recoveryRetireOverride=nil
        reopened.saveTranscriptAsync(to:base.appendingPathComponent("full-export.txt"));waitIO(reopened);precondition(FileManager.default.fileExists(atPath:item.directory.appendingPathComponent("mic-000000.pcm").path));checks+=1
        try archiveAndCleanSessionAt(item.directory,text:reopened.transcriptExport(),retire:{try retireFixtureAudio($0,base:base,id:item.id)})
        let archived=try cachedMeetings(in:base).first{$0.id==item.id}!
        precondition(archived.audioCleaned && !FileManager.default.fileExists(atPath:item.directory.appendingPathComponent("mic-000000.pcm").path));checks+=1
        let retired=base.appendingPathComponent(".retired").appendingPathComponent(item.id).appendingPathComponent("mic-000000.pcm");precondition(try! Data(contentsOf:retired)==pcm);checks+=1
        let manifest=item.directory.appendingPathComponent("mic-manifest.json");var marker=try JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as! [String:Any];marker["audio_cleaned"]=false;try JSONSerialization.data(withJSONObject:marker).write(to:manifest,options:.atomic)
        let interruptedCleanup=try RecordingJournal(directory:item.directory,track:"mic");precondition(interruptedCleanup.audioIsCleaned());checks+=1
        let afterClean=delegate();select(afterClean,archived);afterClean.recoveryBudgetOverride=0;afterClean.recoveryContinue!.performClick(nil);waitIO(afterClean)
        precondition(afterClean.transcriptExport().contains("离线") && !afterClean.resumeBusy);checks+=1
        let limited=make();let other=delegate();select(other,limited);other.recoveryBudgetOverride=10;var limitedItem:CachedMeeting?;other.recoveryRunnerOverride={limitedItem=$0};other.recoveryContinue!.performClick(nil);waitIO(other);try native(other,limitedItem!,"limited")
        precondition(!other.cachedTranscriptionComplete && other.transcriptExport().contains("离线恢复占位文本") && FileManager.default.fileExists(atPath:limited.directory.appendingPathComponent("mic-000000.pcm").path));checks+=1
        try other.saveTranscript(to:base.appendingPathComponent("limited-export.txt"));precondition(FileManager.default.fileExists(atPath:limited.directory.appendingPathComponent("mic-000000.pcm").path));checks+=1
        let closing=make();let closeView=delegate();select(closeView,closing);closeView.recoveryBudgetOverride=10;var closeItem:CachedMeeting?;closeView.recoveryRunnerOverride={closeItem=$0};closeView.recoveryContinue!.performClick(nil);waitIO(closeView)
        let root=URL(fileURLWithPath:closeView.root);let candidate=Bundle.main.object(forInfoDictionaryKey:"CandidateRevision") as? String=="repair"
        let proc=Process();let pipe=Pipe();proc.executableURL=closeView.captureExecutableURL;proc.arguments=["--recovery-fixture",closeItem!.id,"slow"];proc.standardOutput=pipe;proc.standardError=FileHandle.nullDevice;try proc.run();closeView.child=proc
        let initial=pipe.fileHandleForReading.availableData
        precondition(closeView.applicationShouldTerminate(NSApp) == .terminateLater);checks+=1
        let remaining=pipe.fileHandleForReading.readDataToEndOfFile();proc.waitUntilExit();precondition(proc.terminationStatus==0);nativeRuns+=1;closeView.child=nil
        for line in (initial+remaining).split(separator:10) {if let event=try? JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] {closeView.receive(event)}}
        precondition(!closeView.cachedTranscriptionComplete && (try! cachedMeetings(in:base).first{$0.id==closing.id}!).pendingBytes>0);checks+=1
        let retry=delegate();select(retry,try! cachedMeetings(in:base).first{$0.id==closing.id}!);retry.recoveryBudgetOverride=10;var retryItem:CachedMeeting?;retry.recoveryRunnerOverride={retryItem=$0};retry.recoveryContinue!.performClick(nil);waitIO(retry);try native(retry,retryItem!,"normal")
        precondition(retry.cachedTranscriptionComplete && retry.segments.values.filter{$0["final"] as? Bool==true}.count==5);checks+=1
        try retry.saveTranscript(to:base.appendingPathComponent("reopened-full.txt"));precondition(!(try! cachedMeetings(in:base).first{$0.id==closing.id}!).audioCleaned);checks+=1
        let automaticItem=make();let automaticMetadata=try! automaticItem.metadata();let automaticSession=automaticMetadata["session"] as! String
        var authorizedMetadata=automaticMetadata;authorizedMetadata["capture_mode"]="cloud";authorizedMetadata["upload_authorized"]=true;authorizedMetadata["cloud_session_authorized"]=true
        try! JSONSerialization.data(withJSONObject:authorizedMetadata).write(to:automaticItem.directory.appendingPathComponent("meeting.json"),options:.atomic)
        let automatic=delegate();automatic.currentCacheID=automaticItem.id;automatic.activeSession=automaticSession
        automatic.phase.phase = .failed;automatic.recoveryBudgetOverride=10
        var automaticStarted:[String]=[];automatic.recoveryRunnerOverride={automaticStarted.append($0.id)}
        automatic.workerExitReceived=true;automatic.workerEOFReceived=true
        automatic.receive(["type":"stopped","session":automaticSession,"reason":"capture_control_timeout_pause","transcription_complete":false,"audio_retained":true])
        precondition(automatic.pendingAutomaticTailRecovery?.cacheID==automaticItem.id)
        automatic.completeWorkerIfDrained();waitIO(automatic)
        precondition(automaticStarted==[automaticItem.id] && automatic.resumeBusy && automatic.child==nil)
        automatic.receive(["type":"stopped","session":automaticSession,"reason":"capture_control_timeout_finish","transcription_complete":false,"audio_retained":true])
        precondition(automatic.pendingAutomaticTailRecovery==nil,"a failed recovery is not recursively restarted")
        automatic.startAutomaticTailRecovery(reason:"capture_control_timeout_pause",cacheID:automaticItem.id,session:automaticSession)
        precondition(automaticStarted==[automaticItem.id],"automatic saved-tail recovery is once per meeting")
        let localOnly=delegate();localOnly.currentCacheID=automaticItem.id;localOnly.activeSession=automaticSession;localOnly.sessionLocalOnly=true
        localOnly.startAutomaticTailRecovery(reason:"capture_control_timeout_pause",cacheID:automaticItem.id,session:automaticSession)
        precondition(localOnly.automaticTailRecoveryAttempted.isEmpty,"local-only saved audio is never uploaded automatically")
        checks+=2
        let errors=delegate();errors.phase.elapsed=4152
        errors.receive(["type":"error","code":"recording_worker_failed"])
        precondition(errors.heading.stringValue.contains("录音处理已中断") && !errors.heading.stringValue.contains("未启动"))
        errors.phase.phase = .stopping;errors.resumeBusy=true
        errors.receive(["type":"error","code":"cache_writer_active"])
        let specificError=errors.phase.error
        errors.pending=Data("状态：未开始或已停止 · 范围／预算／入口校验失败\n".utf8);errors.drain()
        precondition(errors.phase.error==specificError && errors.heading.stringValue.contains("文件仍在保存"))
        errors.receive(["type":"error","code":"recording_worker_failed"])
        precondition(errors.heading.stringValue.contains("尾部补转未完成"))
        errors.receive(["type":"stopped","reason":"processing_cancelled","transcription_complete":true,"capture_failure_reason":"capture_control_timeout_pause"])
        precondition(errors.cachedTranscriptionComplete && errors.phase.phase == .stopped && errors.phase.error==nil)
        errors.resumeBusy=false;errors.phase.elapsed=0;errors.sequence=[]
        errors.receive(["type":"error","code":"worker_preflight_failed"])
        precondition(errors.heading.stringValue=="录音未启动，请重试")
        checks+=5;errors.window.close()
        closeView.window.close();retry.window.close()
        view.window.close();reopened.window.close();afterClean.window.close();other.window.close()
        return ["type":"recovery_native_ui_checks","assertions":checks,"native_resume_runs":nativeRuns,"own_native_process_cancel_and_reopen":true,"actual_AppKit_button_handlers":true,"same_native_resume_and_retry_loop":true,"public_pcm":true,"protocol_mock":true,"capture":false,"network":false,"keychain":false,"permissions_changed":false,"old_window_touched":false,"external_mouse_keyboard":false]
    }
    @MainActor static func speakerUIChecks(directory:URL)throws->[String:Any] {
        _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let view=Delegate();view.previewRenderOnly=true;view.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));view.window.contentView!.layoutSubtreeIfNeeded();var checks=0
        view.prepareAutomaticCapture()
        precondition(view.useMic && view.sourceBundle=="*system*" && !view.confirmedScope && view.startRequest("synthetic") ["bundle"] as? String=="*system*");checks+=1
        func item(_ id:String,_ slot:Int?,_ revision:Int=1)->[String:Any] {
            var speaker:[String:Any]=["basis":"unknown"]
            if let slot=slot {speaker=["basis":"anonymous_cluster","cluster_id":slot,"source_id":"mic","epoch":"ui-speakers"]}
            return ["type":"segment","session":"ui-speakers","source_id":"mic","track":"mic","epoch":"ui-speakers","segment_id":id,"revision":revision,"speaker":speaker,"text":"离线虚构发言 "+id,"final":true]
        }
        func commit(_ id:String,_ name:String,_ scope:Int=0) {
            view.beginInlineName(id);view.inlineScope!.selectItem(at:scope);view.inlineField!.stringValue=name
            let done=view.inlinePopover!.contentViewController!.view.subviews.compactMap{$0 as? NSButton}.first{$0.title=="完成"}!
            done.performClick(nil)
        }
        view.receive(item("a",0));view.receive(item("b",0));view.receive(item("other",1));view.receive(item("unknown",nil))
        commit("a","Alice");precondition(view.naming.name(segment:"a")=="Alice" && view.naming.name(segment:"b")=="Alice" && view.naming.name(segment:"other")==nil);checks+=1
        view.receive(item("future",0));precondition(view.naming.name(segment:"future")=="Alice" && view.output.string.components(separatedBy:"Alice").count==4);checks+=1
        commit("other","Alice");commit("a","First person");precondition(view.naming.name(segment:"other")=="Alice" && view.naming.name(segment:"future")=="First person");checks+=1
        view.undoName();precondition(view.naming.name(segment:"future")=="Alice");checks+=1
        commit("b","This sentence",1);precondition(view.naming.name(segment:"b")=="This sentence" && view.naming.name(segment:"a")=="Alice");view.undoName();checks+=1
        view.beginInlineName("b");let target=view.inlineTargets.first{$0.value.identity=="slot:1"}!.key
        view.inlineScope!.selectItem(at:target);view.changeInlineScope();precondition(view.inlineField!.stringValue=="Alice");view.inlineField!.stringValue="Second person";view.commitInlineName()
        view.receive(item("b",0,2));precondition(view.naming.key(segment:"b")?.identity=="slot:1" && view.naming.name(segment:"b")=="Second person" && view.naming.name(segment:"other")=="Second person");checks+=1
        view.undoName();precondition(view.naming.key(segment:"b")?.identity=="slot:0" && view.naming.name(segment:"other")=="Alice");checks+=1
        view.beginInlineName("unknown");precondition(view.inlineScope!.indexOfSelectedItem==1 && view.inlineScope!.item(at:0)!.isEnabled==false);view.inlineField!.stringValue="Only this sentence";view.commitInlineName();view.receive(item("unknown-future",nil));precondition(view.naming.name(segment:"unknown-future")==nil);checks+=1
        var split=item("split",nil);split["text"]="甲乙";split["start"]=1.0;split["end"]=3.0;split["speaker_runs"]=[["start":1.0,"end":2.0,"text":"甲","speaker":item("unused",0)["speaker"]!],["start":2.0,"end":3.0,"text":"乙","speaker":item("unused",1)["speaker"]!]]
        view.receive(split);precondition(view.segments["split"] != nil && view.sequence.contains("split") && !view.sequence.contains("split:word:2000"));checks+=1
        let before=view.sequence.count;split["revision"]=2;view.receive(split);precondition(view.sequence.count==before);checks+=1
        view.receive(["type":"stopped","reason":"trial_time_limit"]);precondition(view.naming.name(segment:"future")=="Alice" && view.phase.phase == .ended);checks+=1
        view.deferPresentation=true
        for index in 0..<210 {view.receive(item("retained-\(index)",0))}
        view.deferPresentation=false
        view.showRecentTranscript()
        try view.settleTranscriptForOfflineReview()
        precondition(view.segments["a"] != nil && view.sequence.count>200 && view.textRanges.count==view.readingTurns().count && view.output.string.contains("离线虚构发言 a") && view.output.string.contains("离线虚构发言 retained-209") && view.naming.name(segment:"retained-209")=="Alice");checks+=1
        view.showFullTranscript();precondition(view.output.string.contains("离线虚构发言 a") && view.textRanges.count==view.readingTurns().count);checks+=1
        view.showRecentTranscript();precondition(view.textRanges.count==view.readingTurns().count && view.output.string.contains("离线虚构发言 a"));checks+=1
        let exported=view.transcriptExport();precondition(exported.contains("离线虚构发言 a") && exported.contains("离线虚构发言 retained-209") && exported.contains("Alice") && exported.contains("待确认"));checks+=1
        let saved=view.segments["a"]!;var tooLarge=item("overflow",0);tooLarge["text"]=String(repeating:"x",count:2*1024*1024+1);view.receive(tooLarge)
        precondition(view.transcriptLimitHit && view.segments["overflow"]==nil && view.segments["a"] != nil && view.phase.phase == .failed);view.receive(["type":"stopped","reason":"user_stop"]);precondition(view.phase.phase == .failed && view.phase.error!.contains("内容已达上限"));checks+=1
        precondition(view.segments["a"]!["text"] as? String==saved["text"] as? String);view.showFullTranscript();checks+=1
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        view.beginInlineName("a")
        for (name,target) in [("speaker-transcript",view.window.contentView!),("speaker-popover",view.inlinePopover!.contentViewController!.view),("mic-settings",view.sheet.contentView!)] {
            target.layoutSubtreeIfNeeded();let bitmap=target.bitmapImageRepForCachingDisplay(in:target.bounds)!;target.cacheDisplay(in:target.bounds,to:bitmap)
            let opaque=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:bitmap.pixelsWide,pixelsHigh:bitmap.pixelsHigh,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:opaque);let rectangle=NSRect(x:0,y:0,width:bitmap.pixelsWide,height:bitmap.pixelsHigh);NSColor.white.setFill();NSBezierPath(rect:rectangle).fill();bitmap.draw(in:rectangle);NSGraphicsContext.restoreGraphicsState();try opaque.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name+".png"))
        }
        return ["type":"speaker_native_ui_checks","assertions":checks,"actual_AppKit_widgets_and_button_handlers":true,"offscreen":true,"external_mouse_keyboard_test":false,"capture":false,"network":false,"keychain":false,"public_human_speaker_probe_is_separate":true]
    }
    @MainActor static func workflowChecks(_ fixture:PipelineFixtureResult,file:URL)throws->[String:Any] {
        let document=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        _ = NSApplication.shared
        let view=Delegate();view.mock=true;view.heading=NSTextField(labelWithString:"");view.source=NSTextField(labelWithString:"");view.action=ImmediateButton();view.meter=NSTextField(labelWithString:"");view.empty=NSTextField(labelWithString:"");view.diagnostic=NSTextField(labelWithString:"");view.latest=NSButton();view.scroll=NSScrollView(frame:NSRect(x:0,y:0,width:600,height:400));view.output=NSTextView(frame:NSRect(x:0,y:0,width:600,height:1000));view.scroll.documentView=view.output
        view.sheet=NSPanel(contentRect:.zero,styleMask:[],backing:.buffered,defer:false);view.key=NSSecureTextField();view.keyLabel=NSTextField(labelWithString:"");view.setupMessage=NSTextField(labelWithString:"");view.savedLabel=NSTextField(labelWithString:"");view.save=NSButton();view.change=NSButton();view.editing=true
        var checks=0
        view.key.stringValue="  fake_new_key  ";view.saveKey();precondition(view.vault.load()=="fake_new_key" && view.key.stringValue.isEmpty);checks+=1
        view.sourceBundle="com.tencent.meeting";view.useMic=false;view.prepareAutomaticCapture();precondition(view.sourceBundle=="*system*" && view.useMic);checks+=1
        view.toggle();view.timer?.invalidate();precondition(view.phase.phase == .connecting);checks+=1
        view.prepareAutomaticCapture();precondition(view.sourceBundle=="*system*" && view.useMic);checks+=1
        for event in fixture.events {view.receive(event)}
        precondition(view.phase.phase == .stopped && view.sequence.count==7);checks+=1
        var corrected=false;var undo=false;var candidate=false
        for event in document["events"] as! [[String:Any]] {
            view.receive(event)
            if event["type"] as? String=="identity_candidate" {candidate = !view.candidateBySegment.isEmpty}
            if event["type"] as? String=="identity_state",let state=event["state"] as? [String:Any],let manual=state["manual"] as? [String:String] {
                if manual["a-9"]=="b" {corrected=view.output.string.contains("假人物b")}
                if corrected && manual["a-9"]=="a" {undo=view.output.string.contains("假人物a")}
            }
        }
        precondition(candidate && corrected && undo);checks+=3
        precondition(view.profileStore==nil);checks+=1
        let secureID=NSSecureTextField();let secureSecret=NSSecureTextField();secureID.stringValue="fakeRAMID";secureSecret.stringValue="fakeRAMSecret"
        view.applyBalanceInput(BalanceCredentials(accountLabel:"模拟账户",accessID:secureID.stringValue,secret:secureSecret.stringValue,securityToken:""),permission:false,query:true);precondition(view.balanceState.cash==nil);checks+=1
        view.applyBalanceInput(BalanceCredentials(accountLabel:"模拟账户",accessID:secureID.stringValue,secret:secureSecret.stringValue,securityToken:""),permission:true,query:true);precondition(view.balanceState.cash=="12.34");checks+=1
        do {try view.balanceState.accept(Data("{\"Success\":false}".utf8),at:Date());preconditionFailure()}catch{precondition(view.balanceState.cash=="12.34" && view.balanceState.stale);checks+=1}
        secureID.stringValue="";secureSecret.stringValue="";view.balanceCredentials=nil
        view.receive(["type":"meter","elapsed_seconds":10.0,"estimated_yuan":"0.00297"]);view.receive(["type":"stopped","reason":"user_stop"]);let elapsed=view.phase.elapsed;view.updateUI();precondition(view.phase.elapsed==elapsed && view.phase.estimated==0.00297);checks+=1
        let grant=ProfileStorageGrant(purposeAccepted:true,keychainKeyAccepted:true,localFolderAccepted:true,backupDeletionAccepted:true);let keys=FakeProfileKeyProvider();let folder=file.deletingPathExtension().appendingPathExtension("archive");let store=ProfileArchiveStore(folder:folder,domain:"synthetic_model_output",keys:keys,grant:grant)
        try store.save(document["archive_state"] as! [String:Any]);try store.save(document["archive_state"] as! [String:Any]);let fresh=ProfileArchiveStore(folder:folder,domain:"synthetic_model_output",keys:FakeProfileKeyProvider(),grant:grant);let restored=try fresh.load();precondition((restored["samples"] as! [[String:Any]]).count==6);checks+=1
        view.receive(["type":"identity_state","state":restored]);precondition(view.people.count==2 && view.identityCandidatesEnabled);checks+=1
        try store.save(document["purged_state"] as! [String:Any],rewriteBackup:true);let backup=try fresh.load(useBackup:true);precondition(!(backup["people"] as! [String:String]).keys.contains("b") && !(backup["samples"] as! [[String:Any]]).contains{$0["person_id"] as? String=="a"});checks+=1
        try store.removeAll();try FileManager.default.removeItem(at:folder);checks+=1
        for i in 0..<1000 {view.receive(["type":"segment","session":"fixture","segment_id":"native-pressure-\(i)","revision":1,"track":"remote","text":"合成压力文本","final":true,"speaker":["basis":"unknown"],"epoch":"pressure"])}
        precondition(view.sequence.count==1007 && view.segments.count==1007 && view.segments["manual"] != nil && view.textRanges.count==1007);checks+=1
        for reason in ["network_disconnected","no_sound","speaker_model_missing","trial_time_limit","audio_budget_limit"] {view.receive(["type":"stopped","reason":reason]);precondition(reason.hasSuffix("limit") ? view.phase.phase == .ended : view.phase.phase == .failed);checks+=1}
        view.terminationReplyOverride={};precondition(view.applicationShouldTerminate(NSApp) == .terminateLater);checks+=1
        return ["type":"offline_native_workflow","native_handler_checks":checks,"python_workflow_checks":document["checks"]!,"real_model_pipeline":fixture.evidence,"round":document["round"]!,"window_opened":false,"screen_mouse_keyboard":false,"real_keychain":false,"financial_network":false,"capture":false,"real_voiceprint_quality_verified":false,"fake_archive_removed":true]
    }
    @MainActor static func main() async {
        if runMeetingNotesChecks() {return}
        if CommandLine.arguments.count>=2,Credential.offline {
            let flag=CommandLine.arguments[1]
            if ["--runtime-configuration-self-test","--meeting-minutes-self-test","--edition-ui-self-test","--meeting-files-self-test"].contains(flag) {
                do {
                    var checks:[String]=[]
                    switch flag {
                    case "--runtime-configuration-self-test": checks=try runtimeConfigurationChecks()
                    case "--meeting-minutes-self-test": checks=try meetingMinutesChecks()
                    default:
                        guard CommandLine.arguments.count==3 else{throw Failure(code:"check_directory_required")}
                        let directory=URL(fileURLWithPath:CommandLine.arguments[2])
                        checks = try flag=="--edition-ui-self-test" ? editionUIChecks(directory:directory):meetingFilesExportChecks(directory:directory)
                    }
                    print(String(data:try JSONSerialization.data(withJSONObject:["type":flag,"edition":RuntimeConfiguration.edition(),"checks":checks,"passed":checks.count,"capture":false,"cloud":false,"keychain":false],options:.sortedKeys),encoding:.utf8)!)
                } catch {print("edition-check-failed: \(error)");exit(1)}
                return
            }
        }

        // A worker that exits early must surface as a write error on its pipe,
        // handled by the existing catch paths, not as SIGPIPE killing the app.
        signal(SIGPIPE,SIG_IGN)
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--quick-voice-preview",Credential.offline {
            let app=NSApplication.shared;app.setActivationPolicy(.regular)
            Task { @MainActor in
                do {let checks=try await quickVoiceConfirmationChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]),interactive:true);print(String(data:try JSONSerialization.data(withJSONObject:["checks":checks,"passed":checks.count,"capture":false,"cloud":false,"keychain":false],options:.sortedKeys),encoding:.utf8)!);exit(0)}catch{print("quick-voice-preview-failed: \(error)");exit(1)}
            }
            app.run();return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--merged-meeting-self-test",Credential.offline {
            do {let checks=try mergedMeetingChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:["checks":checks,"passed":checks.count,"capture":false,"cloud":false,"keychain":false],options:.sortedKeys),encoding:.utf8)!)}catch{print("merged-meeting-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--meeting-library-self-test",Credential.offline {
            do {let dir=URL(fileURLWithPath:CommandLine.arguments[2]);let files=try meetingFilesExportChecks(directory:dir.appendingPathComponent("meeting-files"));var result=try await meetingLibraryChecks(directory:dir);result["meeting_files_checks"]=files;print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("meeting-library-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==4,CommandLine.arguments[1]=="--voiceprint-saved-feature-review",Credential.offline {
            do {let result=try voiceprintSavedFeatureReview(archiveURL:URL(fileURLWithPath:CommandLine.arguments[2]),featuresURL:URL(fileURLWithPath:CommandLine.arguments[3]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("voiceprint-saved-feature-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--saved-voice-self-test",Credential.offline {
            do {let result=try await savedVoiceRecognitionChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("saved-voice-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==5,CommandLine.arguments[1]=="--authorized-local-voice-enrollment",Credential.offline {
            do {
                let folder=URL(fileURLWithPath:CommandLine.arguments[2]),feature=URL(fileURLWithPath:CommandLine.arguments[3]),store=VoiceprintArchiveStore(folder:URL(fileURLWithPath:CommandLine.arguments[4]),domain:"consented_live_audio")
                let result=try JSONDecoder().decode(SavedVoiceRecognitionResult.self,from:SavedVoiceRecognition.read(feature,limit:2*1024*1024))
                let report=try enrollSavedVoiceReferences(result:result,folder:folder,store:store,authorized:true)
                print(String(data:try JSONSerialization.data(withJSONObject:report,options:.sortedKeys),encoding:.utf8)!)
            }catch {print("voice-enrollment-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==5,CommandLine.arguments[1]=="--automatic-voice-replay",Credential.offline {
            do {let checks=try voiceprintAutomaticFrozenFeatureReplay(archiveURL:URL(fileURLWithPath:CommandLine.arguments[2]),featureDirectory:URL(fileURLWithPath:CommandLine.arguments[3]),candidateResultsURL:URL(fileURLWithPath:CommandLine.arguments[4]));print(String(data:try JSONSerialization.data(withJSONObject:["checks":checks,"passed":checks.count,"capture":false,"cloud":false,"original_files_modified":false],options:.sortedKeys),encoding:.utf8)!)}catch{print("automatic-voice-replay-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==4,CommandLine.arguments[1]=="--group-voice-replay",Credential.offline {
            do {let result=try voiceprintGroupFrozenReplay(archiveURL:URL(fileURLWithPath:CommandLine.arguments[2]),featureDirectory:URL(fileURLWithPath:CommandLine.arguments[3]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("group-voice-replay-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==6,CommandLine.arguments[1]=="--saved-voice-naming-replay",Credential.offline {
            do {let result=try savedVoiceNamingReplay(cacheID:CommandLine.arguments[2],cacheRoot:URL(fileURLWithPath:CommandLine.arguments[3]),featuresURL:URL(fileURLWithPath:CommandLine.arguments[4]),archiveURL:URL(fileURLWithPath:CommandLine.arguments[5]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("saved-voice-naming-replay-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==4,CommandLine.arguments[1]=="--saved-voice-review",Credential.offline {
            do {let result=try savedVoiceRecognitionReview(resultURL:URL(fileURLWithPath:CommandLine.arguments[2]),archiveURL:URL(fileURLWithPath:CommandLine.arguments[3]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("saved-voice-review-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,["--assistant-ui-self-test","--assistant-live-probe","--assistant-overview-live-probe"].contains(CommandLine.arguments[1]),Credential.offline {
            do {let result=try meetingAgentChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]),live:CommandLine.arguments[1] != "--assistant-ui-self-test",overviewOnly:CommandLine.arguments[1]=="--assistant-overview-live-probe");print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("assistant-ui-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--meeting-translation-ui-self-test",Credential.offline {
            do {let result=try meetingTranslationUIChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("meeting-translation-ui-failed: \(error)");exit(1)}
            return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--meeting-translation-self-test",Credential.offline {
            do {let result=try meetingTranslationChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("meeting-translation-failed: \(error)");exit(1)}
            return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--meeting-context-self-test",Credential.offline {
            do {let result=try await meetingContextChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("meeting-context-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--voiceprint-self-test",Credential.offline {
            do {let result=try await voiceprintRecommendationChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("voiceprint-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--startup-flow-self-test",Credential.offline {
            do {let result=try await startupFlowChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("startup-flow-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--new-meeting-lifecycle-self-test",Credential.offline {
            do {let result=try await newMeetingLifecycleChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("new-meeting-lifecycle-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--speaker-consistency-self-test",Credential.offline {
            do {let result=try await speakerConsistencyChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("speaker-consistency-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--title-sequence-self-test",Credential.offline {
            do {let result=try await meetingTitleSequenceChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("title-sequence-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--minimal-ui-self-test",Credential.offline {
            do {let result=try await minimalUIFlowChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("minimal-ui-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--workspace-self-test",Credential.offline {
            do {var result=try workspaceChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));let pauseChecks=try meetingWorkspaceTranscriptionPauseChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));let archiveChecks=try meetingArchiveUIChecks();let lifecycleChecks=try meetingWindowLifecycleChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]).appendingPathComponent(UUID().uuidString));let checks=(result["checks"] as? [String] ?? [])+pauseChecks+archiveChecks+lifecycleChecks;result["checks"]=checks;result["passed"]=checks.count;print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("workspace-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--acoustic-real-self-test",Credential.offline {
            do {let result=try await automaticAcousticMeetingCheck(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)}catch{print("acoustic-real-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--coarse-real-prepare-readonly",Credential.offline {
            do {let result=try meetingCoarseRefinementReadOnlyPrepare(cacheID:CommandLine.arguments[2],root:meetingCacheRoot());print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)}catch{print("coarse-prepare-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--coarse-progress-self-test",Credential.offline {
            do {let checks=try coarseProgressChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:["type":"coarse_progress_checks","passed":checks.count,"checks":checks,"capture":false,"cloud":false],options:[.sortedKeys]),encoding:.utf8)!)}catch{print("coarse-progress-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--recording-control-self-test",Credential.offline {
            do {let result=try await recordingControlChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)}catch{print("recording-control-failed: \(error)");exit(1)};return
        }
        if [4,5].contains(CommandLine.arguments.count),CommandLine.arguments[1]=="--saved-speaker-review",Credential.offline {
            do {let evidence=try renderSavedSpeakerReview(cacheID:CommandLine.arguments[2],directory:URL(fileURLWithPath:CommandLine.arguments[3]),cacheRoot:CommandLine.arguments.count==5 ? URL(fileURLWithPath:CommandLine.arguments[4]):meetingCacheRoot());print(String(data:try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys]),encoding:.utf8)!)}catch{print("saved-speaker-review-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--realtime-timeline-self-test",Credential.offline {
            do {let result=try realtimeTimelineChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)}catch{print("realtime-timeline-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--render-review",Credential.offline,Bundle.main.object(forInfoDictionaryKey:"UIOnlyReview") as? Bool==true {
            do {let evidence=try renderReview(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys]),encoding:.utf8)!)}catch{print("{\"type\":\"review_render_failed\"}");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--wall-clock-short-self-test",Credential.offline {
            do {let evidence=try await wallClockFixture(directory:URL(fileURLWithPath:CommandLine.arguments[2]),targetSeconds:60);print(String(data:try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys]),encoding:.utf8)!)}catch{print("{\"type\":\"wall_clock_error\",\"capture\":false}");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--wall-clock-self-test",Credential.offline {
            do {let evidence=try await wallClockFixture(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys]),encoding:.utf8)!)}catch{print("{\"type\":\"wall_clock_error\",\"capture\":false}");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--stress-self-test",Credential.offline {
            do {let evidence=try await pipelineStress(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys]),encoding:.utf8)!)}catch{print("{\"type\":\"stress_error\",\"capture\":false}");exit(1)};return
        }
        if CommandLine.arguments.count==4,CommandLine.arguments[1]=="--workflow-self-test",Credential.offline {
            do {let fixture=try await pipelineFixture(directory:URL(fileURLWithPath:CommandLine.arguments[2]));let evidence=try await MainActor.run {try workflowChecks(fixture,file:URL(fileURLWithPath:CommandLine.arguments[3]))};print(String(data:try JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys]),encoding:.utf8)!)}catch{print("{\"type\":\"workflow_error\",\"capture\":false}");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--pipeline-self-test",Credential.offline {
            do {
                let fixture=try await pipelineFixture(directory:URL(fileURLWithPath:CommandLine.arguments[2]))
                await MainActor.run {
                    _ = NSApplication.shared
                    let view=Delegate();view.mock=true;view.heading=NSTextField(labelWithString:"");view.action=ImmediateButton();view.meter=NSTextField(labelWithString:"");view.empty=NSTextField(labelWithString:"");view.diagnostic=NSTextField(labelWithString:"");view.latest=NSButton();view.scroll=NSScrollView(frame:NSRect(x:0,y:0,width:600,height:400));view.output=NSTextView(frame:NSRect(x:0,y:0,width:600,height:1000));view.scroll.documentView=view.output
                    var humanSeen=false;var checks=0
                    for event in fixture.events {
                        view.receive(event)
                        if event["type"] as? String=="speaker_model",event["state"] as? String=="loading" {precondition(view.speakerLoading);checks+=1}
                        if event["segment_id"] as? String=="manual" {
                            if !humanSeen {view.naming.set(segment:"manual",name:"测试人物");view.markTranscriptParentDirty("manual");view.renderText();humanSeen=true}
                            precondition(view.output.string.contains("测试人物"));checks+=1
                        }
                    }
                    precondition(view.phase.phase == .stopped && view.sequence.count==7);checks+=1
                    precondition(!view.output.string.contains("待确认") && view.output.string.contains("多人同时发言") && view.output.string.contains("句内说话人变化"));checks+=1
                    view.undoName();precondition(!view.output.string.contains("测试人物") && view.output.string.contains("发言人"));checks+=1
                    let lockPath=(Bundle.main.object(forInfoDictionaryKey:"AppLockPath") as? String ?? "/tmp/meeting-validation")+".pipeline"
                    let one=open(lockPath,O_CREAT|O_RDWR,0o600);let two=open(lockPath,O_CREAT|O_RDWR,0o600)
                    precondition(one>=0 && two>=0 && flock(one,LOCK_EX|LOCK_NB)==0 && flock(two,LOCK_EX|LOCK_NB) != 0);close(two);close(one);checks+=1
                    var evidence=fixture.evidence;evidence["native_ui_render_checks"]=checks;evidence["window_opened"]=false;evidence["keychain"]=false;evidence["model_revision_preserved_human_name"]=true;evidence["single_instance_lock"]=true
                    print(String(data:try! JSONSerialization.data(withJSONObject:evidence,options:[.sortedKeys]),encoding:.utf8)!)
                }
            } catch {print("{\"type\":\"pipeline_error\",\"capture\":false}");exit(1)}
            return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--recovery-ui-self-test",Credential.offline {
            do {guard let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String,URL(fileURLWithPath:CommandLine.arguments[2]).standardizedFileURL.path==URL(fileURLWithPath:root+"/native/validation-workflow").standardizedFileURL.path else{throw Failure(code:"offline_fixture_scope_invalid")};let result=try recoveryUIChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)}catch{print("recovery-ui-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.contains("--preparation-ui-self-test") {
            _ = NSApplication.shared
            let view=Delegate();view.mock=true;view.heading=NSTextField(labelWithString:"");view.action=ImmediateButton();view.meter=NSTextField(labelWithString:"");view.diagnostic=NSTextField(labelWithString:"")
            view.phase.phase = .connecting;view.preparingModels=true
            view.receive(["type":"preparation","state":"progress","track":"mic","elapsed_seconds":47.0])
            precondition(view.heading.stringValue.contains("47秒") && view.action.title=="取消准备" && !view.modelsPrepared && view.phase.elapsed==0)
            view.receive(["type":"preparation","state":"track_ready","track":"remote","elapsed_seconds":49.0])
            precondition(view.diagnostic.stringValue.contains("2/2") && !view.modelsPrepared)
            view.receive(["type":"preparation","state":"ready","elapsed_seconds":51.0])
            precondition(view.modelsPrepared && !view.preparingModels && view.phase.phase == .idle && view.action.title=="开始" && view.phase.elapsed==0 && view.phase.estimated==0)
            view.receive(["type":"preparation","state":"failed","code":"model_preparation_timeout"])
            precondition(!view.modelsPrepared && view.phase.phase == .failed && view.heading.stringValue.contains("准备"))
            precondition(view.friendly("startup_timeout").contains("未开始采音"))
            print("{\"type\":\"preparation_ui_checks\",\"assertions\":5,\"window_opened\":false,\"keychain\":false,\"capture\":false,\"network\":false}");exit(0)
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--audio-assets-self-test",Credential.offline {
            do {let directory=URL(fileURLWithPath:CommandLine.arguments[2]);let core=try meetingAudioAssetsChecks(directory:directory);let ui=try await meetingAudioAssetsUIChecks(directory:directory);let checks=core+ui;print(String(data:try JSONSerialization.data(withJSONObject:["type":"audio_assets_checks","passed":checks.count,"checks":checks,"capture":false,"cloud":false],options:.sortedKeys),encoding:.utf8)!)}catch{print("audio-assets-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--historical-voice-self-test",Credential.offline {
            do {let checks=try historicalVoiceLearningChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:["type":"historical_voice_checks","passed":checks.count,"checks":checks,"capture":false,"cloud":false],options:.sortedKeys),encoding:.utf8)!)}catch{print("historical-voice-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--speaker-confirmation-self-test",Credential.offline {
            do {let value=try speakerConfirmationChecks(directory:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),encoding:.utf8)!)}catch{print("speaker-confirmation-check-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--speaker-refinement-self-test",Credential.offline {
            do {
                let directory=URL(fileURLWithPath:CommandLine.arguments[2])
                let job=try speakerRefinementJobChecks(directory:directory)
                let artifact=try speakerRefinementArtifactChecks(directory:directory)
                let core=speakerRefinementChecks()
                let ui=try meetingSpeakerRefinementUIChecks(directory:directory)
                let coarse=try meetingCoarseRefinementChecks(directory:directory)
                let coarseUI=try meetingCoarseRefinementUIChecks(directory:directory)
                let attention=try recordingAttentionChecks()
                let checks=job+artifact+core+ui+coarse+coarseUI+attention
                print(String(data:try JSONSerialization.data(withJSONObject:["type":"speaker_refinement_checks","passed":checks.count,"checks":checks,"capture":false,"cloud":false],options:[.sortedKeys]),encoding:.utf8)!)
            } catch {print("speaker-refinement-check-failed: \(error)");exit(1)};return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--speaker-ui-self-test",Credential.offline {do {let dir=URL(fileURLWithPath:CommandLine.arguments[2]);let preview=try speakerAudioPreviewChecks(directory:dir.appendingPathComponent("audio-preview"));var result=try speakerUIChecks(directory:dir);result["audio_preview_checks"]=preview;print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)}catch{print("{\"type\":\"speaker_ui_failed\"}");exit(1)};return}
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--qa-experience-self-test",Credential.offline {
            _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
            let view=Delegate();view.previewRenderOnly=true;view.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification));var checks=0
            precondition(view.diagnostic.superview != nil);checks+=1
            precondition(NSApp.mainMenu?.items.contains{$0.submenu?.title=="验证"}==true);checks+=1
            for tag in [1,11,12,13] {let item=NSMenuItem();item.tag=tag;view.validationScenario(item);precondition(view.phase.phase == .recording && view.action.title=="暂停录音" && view.action.isEnabled==true && !view.action.isHiddenOrHasHiddenAncestor && view.newButton?.isEnabled==false && view.historyButton?.isEnabled==true);checks+=1}
            view.phase.phase = .stopped;view.updateUI();precondition(view.newButton?.isEnabled==true && view.historyButton?.isEnabled==true);checks+=1
            view.receive(["type":"segment","session":view.activeSession ?? "experience-fixture","segment_id":"a","track":"mic","text":"虚构内容，仅检查界面","final":true,"speaker":["basis":"unknown"]]);precondition(view.output.string.contains("未识别 · 是谁？") && view.speakerLabel("a",view.segments["a"]!)=="待确认");checks+=1
            let dir=URL(fileURLWithPath:CommandLine.arguments[2]);try! FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            for (name,width,height,appearance) in [("standard",800,620,NSAppearance.Name.aqua),("compact",640,480,NSAppearance.Name.aqua),("dark",800,620,NSAppearance.Name.darkAqua)] {
                view.window.setContentSize(NSSize(width:width,height:height));view.window.appearance=NSAppearance(named:appearance);view.window.contentView!.layoutSubtreeIfNeeded();let target=view.window.contentView!;let bitmap=target.bitmapImageRepForCachingDisplay(in:target.bounds)!;target.effectiveAppearance.performAsCurrentDrawingAppearance {target.cacheDisplay(in:target.bounds,to:bitmap)};let image=NSImage(size:target.bounds.size);image.lockFocus();target.effectiveAppearance.performAsCurrentDrawingAppearance {NSColor.windowBackgroundColor.setFill();NSBezierPath(rect:NSRect(origin:.zero,size:target.bounds.size)).fill();bitmap.draw(in:NSRect(origin:.zero,size:target.bounds.size))};image.unlockFocus();let opaque=NSBitmapImageRep(data:image.tiffRepresentation!)!;try! opaque.representation(using:.png,properties:[:])!.write(to:dir.appendingPathComponent(name+".png"))
            }
            print("{\"assertions\":\(checks),\"offscreen_render\":true,\"capture\":false,\"keychain\":false,\"cloud\":false}");exit(0)
        }
        if CommandLine.arguments.contains("--qa-network-state-self-test"),Credential.offline {do {try networkStateUIChecks();exit(0)}catch{print("network-state-ui-failed: \(error)");exit(1)}}
        if CommandLine.arguments.contains("--qa-audio-restore-self-test"),Bundle.main.object(forInfoDictionaryKey:"OfflineQA") as? Bool==true {do {try offlineQAAudioRestoreChecks();exit(0)}catch{print("offline-qa-audio-restore-failed: \(error)");exit(1)}}
        if CommandLine.arguments.contains("--qa-blocked-read-self-test"),Bundle.main.object(forInfoDictionaryKey:"OfflineQA") as? Bool==true {do {try offlineQABlockedReadChecks();exit(0)}catch{print("offline-qa-blocked-read-failed: \(error)");exit(1)}}
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--qa-clock-self-test",Bundle.main.object(forInfoDictionaryKey:"OfflineQA") as? Bool==true {do {try offlineQAClockChecks(input:URL(fileURLWithPath:CommandLine.arguments[2]));exit(0)}catch{print("offline-qa-clock-failed: \(error)");exit(1)}}
        if CommandLine.arguments.contains("--cache-async-self-test"),Credential.offline {do {try cacheAsyncChecks();exit(0)}catch{print("cache-async-failed: \(error)");exit(1)}}
        if CommandLine.arguments.count==2,["--authorized-public-asr-test","--authorized-public-asr-test-no-prompt"].contains(CommandLine.arguments[1]) {
            guard Bundle.main.object(forInfoDictionaryKey:"CandidateRevision") as? String=="nightly",Bundle.main.object(forInfoDictionaryKey:"KeychainAuthorized") as? Bool==true,!Credential.offline,let root=Bundle.main.object(forInfoDictionaryKey:"AdapterRoot") as? String else{print("public-asr-scope-denied");exit(1)}
            do {guard let key=try Credential.load(allowInteraction:CommandLine.arguments[1] != "--authorized-public-asr-test-no-prompt"),!key.isEmpty else{print("public-asr-key-unavailable");exit(1)}
                let child=Process();let input=Pipe();child.executableURL=URL(fileURLWithPath:"/usr/local/bin/python3");child.arguments=[root+"/public_audio_trial.py"];child.standardInput=input;try child.run();try input.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:["key":key])+Data([10]));try input.fileHandleForWriting.close();child.waitUntilExit();exit(child.terminationStatus)
            }catch{print("public-asr-keychain-or-launch-failed");exit(1)}
        }
        if CommandLine.arguments.contains("--ui-self-test") {modelSelfTest();exit(0)}
        if CommandLine.arguments.contains("--key-status") {let code=Credential.existenceStatus();print(code==errSecItemNotFound ? "key_absent" : code==errSecSuccess ? "key_present" : "key_status_unavailable");exit(0)}
        let ownID=Bundle.main.bundleIdentifier ?? "com.joesang.meeting-assistant"
        if NSRunningApplication.runningApplications(withBundleIdentifier:ownID).contains(where:{$0.processIdentifier != getpid()}) {exit(0)}
        let lockPath=Bundle.main.object(forInfoDictionaryKey:"AppLockPath") as? String ?? NSTemporaryDirectory()+"joesang-meeting-ui-\(getuid())-\(ownID).lock"
        let uiLock=open(lockPath,O_CREAT|O_RDWR|O_NOFOLLOW|O_NONBLOCK,0o600)
        var lockStat=stat();guard uiLock>=0,fstat(uiLock,&lockStat)==0,(lockStat.st_mode & S_IFMT)==S_IFREG,lockStat.st_uid==getuid(),flock(uiLock,LOCK_EX|LOCK_NB)==0 else {exit(0)}
        let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=Delegate();app.delegate=delegate;withExtendedLifetime(delegate){app.run()}
    }
}
