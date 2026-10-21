"""Test the isolated development app and its offline-only checks."""
from pathlib import Path
import subprocess, json, hashlib, argparse, plistlib, uuid

parser = argparse.ArgumentParser()
parser.add_argument('--development', action='store_true', help='Compatibility flag; development is now the default.')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
for source in [*root.glob('*.py'), *root.glob('scripts/*.py'), *root.glob('tests/*.py')]:
    compile(source.read_text(), str(source), 'exec')
app = root/'.runtime/build/会议助理开发QA.app'
metadata = plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert all(metadata.get(k) is True for k in ['OfflineOnly', 'OfflineQA', 'DevelopmentWorkspace'])
assert metadata.get('KeychainAuthorized') is False
assert metadata.get('AdapterRoot') == str(root)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
binary = app/'Contents/MacOS/MeetingAssistant'
evidence = root/'.runtime/realtime-review'
evidence.mkdir(parents=True, exist_ok=True)
for name, arguments in [('meeting-assistant', ['--assistant-ui-self-test', str(evidence/'assistant-ui')]), ('meeting-notes', ['--meeting-notes-self-test', str(root/'.runtime/meeting-notes-1018')]), ('meeting-minutes', ['--meeting-minutes-self-test']), ('coarse-progress', ['--coarse-progress-self-test', str(evidence/'coarse-progress')]), ('title-sequence', ['--title-sequence-self-test', str(evidence/'title-sequence'/str(uuid.uuid4()))]), ('new-meeting-lifecycle', ['--new-meeting-lifecycle-self-test', str(evidence/'new-meeting-lifecycle')]), ('speaker-refinement',['--speaker-refinement-self-test',str(evidence/'speaker-refinement')]), ('audio-assets',['--audio-assets-self-test',str(evidence/'audio-assets')]), ('historical-voice',['--historical-voice-self-test',str(evidence/'historical-voice')]), ('asr-terms',['--asr-terms-self-test']), ('meeting-translation',['--meeting-translation-self-test',str(evidence/'meeting-translation')]), ('speaker-confirmation', ['--speaker-confirmation-self-test', str(evidence/'speaker-confirmation')]), ('meeting-library', ['--meeting-library-self-test', str(evidence/'meeting-library')]), ('meeting-context', ['--meeting-context-self-test', str(evidence/'meeting-context')]), ('voiceprint', ['--voiceprint-self-test', str(evidence/'voiceprint')]), ('saved-voice', ['--saved-voice-self-test', str(evidence/'saved-voice')]), ('startup', ['--startup-flow-self-test', str(evidence/'startup')]), ('model', ['--ui-self-test']), ('minimal', ['--minimal-ui-self-test', str(evidence/'minimal-ui')]), ('timeline', ['--realtime-timeline-self-test', str(evidence)]), ('workspace', ['--workspace-self-test', str(evidence/'workspace')]), ('speaker', ['--speaker-ui-self-test', str(evidence/'speaker')]), ('speaker-consistency', ['--speaker-consistency-self-test', str(evidence/'speaker-consistency')]), ('network', ['--qa-network-state-self-test']), ('recording', ['--recording-control-self-test', str(evidence/'recording-controls')])]:
    result = subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=120)
    (evidence/(name+'.log')).write_text(result.stdout+result.stderr)
    print(result.stdout, end='', flush=True)
    assert result.returncode == 0, f'{name}: exit {result.returncode}; see {evidence/(name+".log")}'
    if name == 'timeline':
        (evidence/'checks.json').write_text(result.stdout)
reader_check=subprocess.run(['python3','-m','unittest','-v','tests.test_meeting_context'],cwd=root,capture_output=True,text=True,timeout=30)
(evidence/'meeting-context-python.log').write_text(reader_check.stdout+reader_check.stderr)
assert reader_check.returncode==0,'meeting context reader checks failed'
helper=app/'Contents/Helpers/会议采集离线QA.app/Contents/MacOS/MeetingCapture'
for name, arguments in [('asr-term-protocol',['--asr-terms-self-test']), ('capture-safety', ['--capture-safety-self-test', str(root/'.runtime/capture-safety-checks')]), ('session-cache-recovery',['--session-cache-recovery-self-test',str(root/'.runtime/session-cache-recovery-checks')]), ('speaker-history', ['--speaker-history-self-test']), ('source', ['--source-pipeline-self-test', str(root/'.runtime/source-pipeline-checks')]), ('pipeline-model-load', ['--pipeline-self-test', str(root/'native/local-speaker-install/runtime-models')]), ('local-recording', ['--local-recording-self-test', str(root/'.runtime/local-recording-fixtures')]), ('capture', ['--self-test'])]:
    result=subprocess.run([str(helper),*arguments],capture_output=True,text=True,timeout=120)
    (evidence/(name+'.log')).write_text(result.stdout+result.stderr)
    print(result.stdout,end='',flush=True)
    assert result.returncode==0,f'{name}: exit {result.returncode}'
    if name == 'pipeline-model-load':
        evidence_rows=[json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        summary=next((row for row in evidence_rows if row.get('type')=='native_pipeline_validation'),None)
        assert (summary and summary.get('real_model') is True and summary.get('model_warmup') is True
                and summary.get('network_audio') is False and summary.get('capture') is False), 'real offline speaker-model load/warmup did not report safe success'
protocol=subprocess.run(['python3',str(root/'tests/capture_protocol_integration.py'),str(helper),str(root)],cwd=root,capture_output=True,text=True,timeout=30)
(evidence/'capture-control-protocol.log').write_text(protocol.stdout+protocol.stderr)
print(protocol.stdout,end='',flush=True)
assert protocol.returncode==0,'cross-process capture control protocol failed; see '+str(evidence/'capture-control-protocol.log')
print(json.dumps(dict(development=True, tested_binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), tested_helper_sha256=hashlib.sha256(helper.read_bytes()).hexdigest(), python_syntax=True, context_reader_tests=True, context_reader_sha256=hashlib.sha256((root/"meeting_context.py").read_bytes()).hexdigest(), capture=False, cloud=False, keychain=False)))
