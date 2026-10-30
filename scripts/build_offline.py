"""Build an isolated development QA app from project-owned sources; never launch or use a network API."""
from pathlib import Path
import argparse,os,shutil,subprocess,plistlib,json,hashlib,atexit,sys
from build_guard import acquire_desktop_idle_lease
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root))
import app_version
native=root/'native'
work=root/'.runtime/build'
parser=argparse.ArgumentParser()
parser.add_argument('--edition',choices=['joe','standalone'],default='joe')
parser.add_argument('--ui-only',action='store_true')
parser.add_argument('--helper-only',action='store_true')
parser.add_argument('--desktop-idle-confirmed',action='store_true',help='After explicit user confirmation that recorders are stopped, hold the installed desktop startup lock throughout the build.')
args=parser.parse_args()
if args.edition=='standalone':work=work/'standalone'
work.mkdir(parents=True,exist_ok=True)
if args.ui_only and args.helper_only:
    parser.error('--ui-only and --helper-only cannot be combined')

# Development must yield to the installed recorder. Inspect executable names,
# never command arguments (which may contain provider configuration).
if args.desktop_idle_confirmed:
    desktop_idle_lease=acquire_desktop_idle_lease()
    atexit.register(os.close,desktop_idle_lease)
else:
    processes=subprocess.run(['ps','-axo','comm='],capture_output=True,text=True,check=True).stdout.splitlines()
    if any(Path(name.strip()).name in {'MeetingCapture','IntegratedCapture'} for name in processes):
        raise SystemExit('正在录音或处理已录音频，暂不编译。请等在场完成后再运行。')
priority_lowered=False
try:
    os.nice(10);priority_lowered=True
except PermissionError:
    if not args.desktop_idle_confirmed:
        raise
    print('CPU priority adjustment unavailable; desktop idle lease remains held throughout compilation.',flush=True)

app_name='在场独立版QA' if args.edition=='standalone' else '会议助理开发QA'
final_app=work/(app_name+'.app')
staging=work/('.'+app_name+'.staging.app')
if staging.exists(): shutil.rmtree(staging)
partial=args.ui_only or args.helper_only
helper_app=final_app/'Contents/Helpers/会议采集离线QA.app'
helper_contents=helper_app/'Contents'
if args.ui_only:
    partial_ready=all([
        (helper_contents/'MacOS/MeetingCapture').is_file(),
        (helper_contents/'Resources/FluidAudio_FluidAudio.bundle').is_dir(),
        (helper_contents/'Frameworks/libonnxruntime.dylib').is_file(),
        (helper_contents/'Frameworks/libsherpa-onnx-c-api.dylib').is_file(),
        (final_app/'Contents/Resources/MeetingAssistantIcon.icns').is_file(),
    ])
elif args.helper_only:
    partial_ready=all([
        (final_app/'Contents/MacOS/MeetingAssistant').is_file(),
        (final_app/'Contents/Resources/MeetingAssistantIcon.icns').is_file(),
    ])
else:
    partial_ready=False
if partial and final_app.is_dir() and partial_ready:
    shutil.copytree(final_app,staging,symlinks=True)
else:
    # Partial builds fall back to a complete source build when no complete QA app exists.
    args.ui_only=False
    args.helper_only=False
    contents=staging/'Contents'
    for directory in ['MacOS','Resources','Helpers/会议采集离线QA.app/Contents/MacOS',
                      'Helpers/会议采集离线QA.app/Contents/Resources',
                      'Helpers/会议采集离线QA.app/Contents/Frameworks']:
        (contents/directory).mkdir(parents=True,exist_ok=True)
app=staging

def source_file(name):
    candidates=[native/(name+'.swift'),native/'checks'/(name+'.swift')]
    found=[path for path in candidates if path.is_file()]
    if len(found)>1:
        raise RuntimeError(f'ambiguous Swift source {name}: {found}')
    if not found:
        raise FileNotFoundError(f'missing Swift source {name} in native/ or native/checks/')
    return found[0]
icon_source=native/'assets/MeetingAssistantIcon.icns';icon_target=app/'Contents/Resources/MeetingAssistantIcon.icns'
icon_target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(icon_source,icon_target)
if not args.helper_only:
 ui=['RecordingAttention','RecordingAttentionChecks','MeetingCoarseRefinement','MeetingCoarseRefinementChecks','MeetingCoarseRefinementUI','MeetingCoarseRefinementUIChecks','MeetingArchiveUI','MeetingArchiveUIChecks','OfflineSpeakerBackend','WholeMeetingSpeakerRefinement','SpeakerRefinement','SpeakerRefinementChecks','SpeakerRefinementArtifact','SpeakerRefinementArtifactChecks','SpeakerRefinementJob','SpeakerRefinementJobChecks','MeetingSpeakerRefinementUI','MeetingSpeakerRefinementUIChecks','MeetingAudioAssets','MeetingAudioAssetsChecks','MeetingAudioAssetsUI','MeetingAudioAssetsUIChecks','VoiceprintAcousticContext','HistoricalVoiceLearning','HistoricalVoiceLearningChecks','MeetingSidebarSizing','MeetingFilesExport','MeetingFilesExportChecks','MeetingLibraryManagement','SpeakerConfirmationUI','SpeakerConfirmationChecks','SharedPersonIdentity','SharedPersonIdentityChecks','VoiceprintLearningChecks','LocalSemanticNames','MeetingDeletion','MeetingLibraryActions','MeetingLibraryChecks','MeetingAgentContext','MeetingAgentContextChecks','VoiceprintRecommendations','VoiceprintRecommendationUI','VoiceprintRecommendationChecks','MeetingAbsoluteTime','SessionSpeakerKey','RecordingStartChoice','RecordingDashboard','RecordingDashboardChecks','CoarseProgressChecks','StartupFlowChecks','MeetingVisualStyle','SpeakerAudioPreview','SpeakerAudioPreviewChecks','MinimalSpeakerUI','MeetingCardSummary','SpeakerReview','SpeakerReviewChecks','MeetingAutoTitle','MeetingAutoTitleFixture','MinimalUIFlowChecks','MeetingTitleUI','MeetingRecordDetails','IncrementalTranscript','SpeakerHistoryChecks','AudioSourceIdentity','RecordingControlChecks','WorkspaceChecks','MeetingWorkspace','MeetingWorkspaceTranscriptionStopChecks','MergedMeetingChecks','TranscriptTimeline','RealtimeTimelineChecks','ReviewRender','WallClockFixture','MeetingUIModel','IdentityArchive','BalanceClient','ProfileArchiveStore','LocalSpeakerBackend','SpeakerPipeline','SessionRecovery','RecordingJournal','SessionCacheRecoveryChecks','CapturePrimitives','PipelineFixture','ASRDecoder','SpeakerEmbeddingBackend','OfflineQASupport','MeetingTranslation','MeetingTranslationChecks','MeetingAssistantUI'];binary=work/'MeetingAssistant'
 ui_sources=work/'ui-sources';ui_sources.mkdir(parents=True,exist_ok=True)
 for stale in ui_sources.glob('*.swift'):stale.unlink()
 ui+=['MeetingAssistantLinks','MeetingMarkdown','MeetingMarkdownChecks','MeetingAgentPanel','MeetingAgentBridge','MeetingAgentChecks']
 ui+=['RuntimeConfiguration','RuntimeConfigurationChecks','MeetingMinutes','MeetingMinutesUI','MeetingMinutesChecks','EditionUIChecks']
 ui+=['MeetingNotes','MeetingNotesUI','MeetingNotesChecks']
 ui+=['MeetingSpeechIntervals','MeetingAcousticRefinement','SavedVoiceRecognition','SavedVoiceRecognitionUI','SavedVoiceRecognitionChecks','VoiceSuggestionPersistenceChecks','HistoricalVoiceEnrollment','VoiceprintAutomaticLearning','VoiceprintAutomaticLearningChecks']
 for name in ui:shutil.copy2(source_file(name),ui_sources/(name+'.swift'))
 subprocess.run(['xcrun','swiftc','-whole-module-optimization','-parse-as-library','-swift-version','5','-module-cache-path',str(work/'module-cache'),*[str(ui_sources/(f+'.swift')) for f in ui],'-o',str(binary)],check=True)
 shutil.copy2(binary,app/'Contents/MacOS/MeetingAssistant')
if not args.ui_only:
 h=work/'harness';s=h/'Sources/IntegratedCapture';s.mkdir(parents=True,exist_ok=True)
 for stale in s.glob('*.swift'):stale.unlink()
 files=['MeetingCoarseRefinement','OfflineSpeakerBackend','WholeMeetingSpeakerRefinement','SpeakerRefinement','SpeakerRefinementArtifact','VoiceprintAcousticContext','HistoricalVoiceLearning','MeetingAbsoluteTime','SessionSpeakerKey','CaptureSafetyChecks','SpeakerHistoryChecks','SourcePipelineFixture','AudioSourceIdentity','ProcessAudioSources','SourceCaptureSession','EchoPreprocessor','TranscriptTimeline','LocalSpeakerBackend','SpeakerPipeline','SessionRecovery','RecordingJournal','SessionCacheRecoveryChecks','CapturePrimitives','PipelineFixture','ASRDecoder','SpeakerEmbeddingBackend','IndependentClockFixture','OfflineSpeechProbe','BufferedCaptureFixture','PublicAudioTrial','LocalRecording','MeetingCapture','NetworkRecoveryFixture']
 files+=['RuntimeConfiguration','RuntimeConfigurationChecks']
 files+=['SavedVoiceRecognition','MeetingAcousticRefinement','MeetingSpeechIntervals']
 for f in files:shutil.copy2(source_file(f),s/(f+'.swift'))
 c=h/'Sources/SherpaC';c.mkdir(parents=True,exist_ok=True);shutil.copy2(native/'local-embedding-install/c-api.h',c/'c-api.h');(c/'module.modulemap').write_text('module SherpaC { header "c-api.h" link "sherpa-onnx-c-api" export * }\n')
 sdk=native/'local-speaker-install/sdk';lib=native/'local-embedding-install/runtime/lib'
 # SDK and its binary dependency NemoTextProcessing are both in the project; no remote Swift package.
 (h/'Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package=Package(name:"MeetingDevelopment",platforms:[.macOS(.v15)],dependencies:[.package(path:'+json.dumps(str(sdk),ensure_ascii=False)+')],targets:[.systemLibrary(name:"SherpaC"),.executableTarget(name:"IntegratedCapture",dependencies:[.product(name:"FluidAudio",package:"sdk"),"SherpaC"],linkerSettings:[.unsafeFlags(["-L",'+json.dumps(str(lib),ensure_ascii=False)+',"-Xlinker","-rpath","-Xlinker",'+json.dumps(str(lib),ensure_ascii=False)+'])])],swiftLanguageModes:[.v5])\n')
 build_env=dict(os.environ,CLANG_MODULE_CACHE_PATH=str(work/'module-cache'),SWIFT_MODULECACHE_PATH=str(work/'module-cache'))
 subprocess.run(['xcrun','swift','build','--disable-sandbox','--package-path',str(h),'--scratch-path',str(work/'sdk-build'),'--cache-path',str(work/'cache'),'--config-path',str(work/'config'),'--security-path',str(work/'security'),'--jobs','2'],check=True,env=build_env)
 helper=app/'Contents/Helpers/会议采集离线QA.app';cap=helper/'Contents/MacOS/MeetingCapture';shutil.copy2(work/'sdk-build/arm64-apple-macosx/debug/IntegratedCapture',cap);cap.chmod(0o755);subprocess.run(['install_name_tool','-rpath',str(lib),'@executable_path/../Frameworks',str(cap)],check=True)
 resources=work/'sdk-build/arm64-apple-macosx/debug/FluidAudio_FluidAudio.bundle'
 helper_resources=helper/'Contents/Resources'
 if not resources.is_dir(): raise FileNotFoundError(f'FluidAudio resources missing from current build: {resources}')
 generated_resources=helper_resources/resources.name
 if generated_resources.exists(): shutil.rmtree(generated_resources)
 shutil.copytree(resources,generated_resources)
 frameworks=helper/'Contents/Frameworks'
 for stale in frameworks.iterdir():
  if stale.is_file() or stale.is_symlink(): stale.unlink()
  elif stale.is_dir(): shutil.rmtree(stale)
 for library in ['libonnxruntime.dylib','libsherpa-onnx-c-api.dylib']:
  shutil.copy2(lib/library,frameworks/library)
 helper_icon=helper_resources/'MeetingAssistant.icns'
 shutil.copy2(native/'assets/MeetingAssistant.icns',helper_icon)
# Build explicit development metadata; no plist or payload is inherited from a historical QA app.
helper=app/'Contents/Helpers/会议采集离线QA.app'
helper_info={
 'CFBundleExecutable':'MeetingCapture',
 'CFBundleIdentifier':'com.joesang.meeting-capture.development-qa',
 'CFBundleName':'会议采集离线QA',
 'CFBundleDisplayName':'会议采集离线QA',
 'CFBundlePackageType':'APPL',
 'CFBundleDevelopmentRegion':'zh_CN',
 'CFBundleLocalizations':['zh-Hans'],
 'CFBundleShortVersionString':app_version.VERSION,
 'CFBundleVersion':'1',
 'CFBundleIconFile':'MeetingAssistant.icns',
 'LSMinimumSystemVersion':'15.0',
 'NSHighResolutionCapable':True,
 'AdapterRoot':str(root),
 'OfflineOnly':True,
 'OfflineQA':True,
 'DevelopmentWorkspace':True,
 'KeychainAuthorized':False,
 'LocalRecordingAllowed':False,
 'PublicAudioASRTestAllowed':False,
 'TrialCandidate':True,
 'TrialArmed':False,
 'HumanIdentityUseAuthorized':False,
 'NSMicrophoneUsageDescription':'收录会议中的麦克风声音，并保存在本机；选择转写时生成会议文字。',
 'NSAudioCaptureUsageDescription':'收录电脑播放的会议声音，并区分应用来源。',
}
helper_info['ZaichangEdition']=args.edition
if args.edition=='standalone':
 helper_info.update(DataRootName='ZaichangStandalone',CFBundleIdentifier='com.joesang.zaichang.standalone.capture.development-qa')
helper_plist=helper/'Contents/Info.plist'
helper_plist.write_bytes(plistlib.dumps(helper_info,sort_keys=True))
subprocess.run(['codesign','--force','--sign','-',str(helper)],check=True)

info={
 'CFBundleExecutable':'MeetingAssistant',
 'CFBundleIdentifier':'com.joesang.meeting-assistant.development-qa',
 'CFBundleName':'在场开发QA',
 'CFBundleDisplayName':'在场开发QA',
 'CFBundlePackageType':'APPL',
 'CFBundleDevelopmentRegion':'zh_CN',
 'CFBundleLocalizations':['zh-Hans'],
 'CFBundleShortVersionString':app_version.VERSION,
 'CFBundleVersion':'1',
 'CFBundleIconFile':'MeetingAssistantIcon.icns',
 'LSMinimumSystemVersion':'15.0',
 'NSHighResolutionCapable':True,
 'AdapterRoot':str(root),
 'AppLockPath':str(work/'qa.lock'),
 'OfflineOnly':True,
 'OfflineQA':True,
 'DevelopmentWorkspace':True,
 'KeychainAuthorized':False,
 'LocalRecordingAllowed':True,
 'TrialCandidate':True,
 'TrialArmed':False,
 'HumanIdentityUseAuthorized':False,
 'NSMicrophoneUsageDescription':helper_info['NSMicrophoneUsageDescription'],
 'NSAudioCaptureUsageDescription':helper_info['NSAudioCaptureUsageDescription'],
}
info['ZaichangEdition']=args.edition
if args.edition=='standalone':
 info.update(DataRootName='ZaichangStandalone',CFBundleIdentifier='com.joesang.zaichang.standalone.development-qa')
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info,sort_keys=True))
runtime=app/'Contents/Resources/Runtime'
if runtime.is_symlink(): runtime.unlink()
elif runtime.is_dir(): shutil.rmtree(runtime)
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)

# Verify both halves even for a partial build. Do not promote a UI/helper made
# from an older source snapshot when files changed while compilation ran.
built_sources={}
for snapshot in [work/'ui-sources',work/'harness/Sources/IntegratedCapture']:
 for copied in snapshot.glob('*.swift'):
  current=source_file(copied.stem)
  digest=hashlib.sha256(copied.read_bytes()).hexdigest()
  if digest != hashlib.sha256(current.read_bytes()).hexdigest():
   raise RuntimeError('源码在编译期间或局部构建前变化，请完整重建：'+str(current.relative_to(root)))
  built_sources[str(current.relative_to(root))]=digest

if final_app.exists():
 replaced=work/('.'+app_name+'.previous.app')
 if replaced.exists(): shutil.rmtree(replaced)
 final_app.rename(replaced)
 try:
  staging.rename(final_app)
 except Exception:
  replaced.rename(final_app)
  raise
 shutil.rmtree(replaced)
else:
 staging.rename(final_app)
(work/'source-receipt.json').write_text(json.dumps({
 'schema':1,'edition':args.edition,'sources':built_sources,
 'ui_sha256':hashlib.sha256((final_app/'Contents/MacOS/MeetingAssistant').read_bytes()).hexdigest(),
 'helper_sha256':hashlib.sha256((final_app/'Contents/Helpers/会议采集离线QA.app/Contents/MacOS/MeetingCapture').read_bytes()).hexdigest(),
},ensure_ascii=False,indent=2)+'\n')
print(final_app)
