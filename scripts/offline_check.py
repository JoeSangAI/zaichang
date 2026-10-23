"""Test the isolated development app; frozen candidate hash checking is optional."""
from pathlib import Path
import subprocess, json, hashlib, argparse, plistlib, uuid, os

parser = argparse.ArgumentParser()
parser.add_argument('--edition',choices=['joe','standalone'],default='joe')
parser.add_argument('--development', action='store_true', help='Compatibility flag; development is now the default.')
parser.add_argument('--frozen-hash-only', action='store_true', help='Only verify the unchanged frozen candidate.')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
frozen = root/'validation/owner/experience-work/candidate-final/会议助理.app/Contents/MacOS/MeetingAssistant'
for source in [*root.glob('*.py'), *root.glob('scripts/*.py'), *root.glob('tests/*.py')]:
    compile(source.read_text(), str(source), 'exec')
if args.frozen_hash_only:
    assert hashlib.sha256(frozen.read_bytes()).hexdigest() == '7f43dfe9b75af892b9a0dba7363fb27123ae96b09dba4e7e5327db25fb77f2b7'
    print(json.dumps(dict(frozen_candidate_hash=True, python_syntax=True, executed_historical_binary=False)))
    raise SystemExit(0)
app = root/('.runtime/build/standalone/在场独立版QA.app' if args.edition=='standalone' else '.runtime/build/会议助理开发QA.app')
metadata = plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert all(metadata.get(k) is True for k in ['OfflineOnly', 'OfflineQA', 'DevelopmentWorkspace'])
assert metadata.get('KeychainAuthorized') is False
assert metadata.get('AdapterRoot') == str(root)
assert metadata.get('ZaichangEdition', 'joe') == args.edition
helper_metadata=plistlib.loads((app/'Contents/Helpers/会议采集离线QA.app/Contents/Info.plist').read_bytes())
assert helper_metadata.get('ZaichangEdition', 'joe') == args.edition
if args.edition=='standalone':
    assert metadata['DataRootName']==helper_metadata['DataRootName']=='ZaichangStandalone'
    assert metadata['CFBundleIdentifier']=='com.joesang.zaichang.standalone.development-qa'
    assert helper_metadata['CFBundleIdentifier']=='com.joesang.zaichang.standalone.capture.development-qa'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
binary = app/'Contents/MacOS/MeetingAssistant'
evidence = root/('.runtime/standalone-review' if args.edition=='standalone' else '.runtime/realtime-review')
evidence.mkdir(parents=True, exist_ok=True)
# Every subprocess, including connector UI checks, must use isolated QA data.
os.environ["ZAICHANG_EDITION"] = args.edition
os.environ["ZAICHANG_DATA_ROOT"] = str(evidence / "data")
for name, arguments in [('runtime-configuration',['--runtime-configuration-self-test']), ('meeting-minutes',['--meeting-minutes-self-test']), ('edition-ui',['--edition-ui-self-test',str(evidence/'edition-ui')]), ('meeting-files',['--meeting-files-self-test',str(evidence/'meeting-files')]), ('meeting-assistant', ['--assistant-ui-self-test', str(evidence/'assistant-ui')]), ('meeting-notes', ['--meeting-notes-self-test', str(root/'.runtime/meeting-notes-1018')]), ('coarse-progress', ['--coarse-progress-self-test', str(evidence/'coarse-progress')]), ('title-sequence', ['--title-sequence-self-test', str(evidence/'title-sequence'/str(uuid.uuid4()))]), ('new-meeting-lifecycle', ['--new-meeting-lifecycle-self-test', str(evidence/'new-meeting-lifecycle')]), ('speaker-refinement',['--speaker-refinement-self-test',str(evidence/'speaker-refinement')]), ('audio-assets',['--audio-assets-self-test',str(evidence/'audio-assets')]), ('historical-voice',['--historical-voice-self-test',str(evidence/'historical-voice')]), ('meeting-translation',['--meeting-translation-self-test',str(evidence/'meeting-translation')]), ('meeting-translation-ui',['--meeting-translation-ui-self-test',str(evidence/'meeting-translation-ui')]), ('speaker-confirmation', ['--speaker-confirmation-self-test', str(evidence/'speaker-confirmation')]), ('meeting-library', ['--meeting-library-self-test', str(evidence/'meeting-library')]), ('meeting-context', ['--meeting-context-self-test', str(evidence/'meeting-context')]), ('voiceprint', ['--voiceprint-self-test', str(evidence/'voiceprint')]), ('saved-voice', ['--saved-voice-self-test', str(evidence/'saved-voice')]), ('startup', ['--startup-flow-self-test', str(evidence/'startup')]), ('model', ['--ui-self-test']), ('minimal', ['--minimal-ui-self-test', str(evidence/'minimal-ui')]), ('timeline', ['--realtime-timeline-self-test', str(evidence)]), ('workspace', ['--workspace-self-test', str(evidence/'workspace')]), ('speaker', ['--speaker-ui-self-test', str(evidence/'speaker')]), ('speaker-consistency', ['--speaker-consistency-self-test', str(evidence/'speaker-consistency')]), ('network', ['--qa-network-state-self-test']), ('recording', ['--recording-control-self-test', str(evidence/'recording-controls')])]:
    result = subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=120)
    (evidence/(name+'.log')).write_text(result.stdout+result.stderr)
    print(result.stdout, end='', flush=True)
    assert result.returncode == 0, f'{name}: exit {result.returncode}; see {evidence/(name+".log")}'
    if name == 'timeline':
        (evidence/'checks.json').write_text(result.stdout)
reader_check=subprocess.run(['python3','-m','unittest','-v','tests.test_meeting_context','tests.test_runtime_config'],cwd=root,capture_output=True,text=True,timeout=30)
(evidence/'meeting-context-python.log').write_text(reader_check.stdout+reader_check.stderr)
assert reader_check.returncode==0,'meeting context reader checks failed'
helper=app/'Contents/Helpers/会议采集离线QA.app/Contents/MacOS/MeetingCapture'
for name, arguments in [('runtime-helper',['--runtime-configuration-self-test']), ('capture-safety', ['--capture-safety-self-test', str(root/'.runtime/capture-safety-checks')]), ('session-cache-recovery',['--session-cache-recovery-self-test',str(root/'.runtime/session-cache-recovery-checks')]), ('speaker-history', ['--speaker-history-self-test']), ('source', ['--source-pipeline-self-test', str(root/'.runtime/source-pipeline-checks')]), ('local-recording', ['--local-recording-self-test', str(root/'.runtime/local-recording-fixtures')]), ('capture', ['--self-test'])]:
    result=subprocess.run([str(helper),*arguments],capture_output=True,text=True,timeout=120)
    (evidence/(name+'.log')).write_text(result.stdout+result.stderr)
    print(result.stdout,end='',flush=True)
    assert result.returncode==0,f'{name}: exit {result.returncode}'
protocol=subprocess.run(['python3',str(root/'tests/capture_protocol_integration.py'),str(helper),str(root)],cwd=root,capture_output=True,text=True,timeout=30)
(evidence/'capture-control-protocol.log').write_text(protocol.stdout+protocol.stderr)
print(protocol.stdout,end='',flush=True)
assert protocol.returncode==0,'cross-process capture control protocol failed; see '+str(evidence/'capture-control-protocol.log')
print(json.dumps(dict(edition=args.edition, development=True, tested_binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), tested_helper_sha256=hashlib.sha256(helper.read_bytes()).hexdigest(), python_syntax=True, context_reader_tests=True, context_reader_sha256=hashlib.sha256((root/"meeting_context.py").read_bytes()).hexdigest(), capture=False, cloud=False, keychain=False)))
