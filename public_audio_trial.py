"""Approved public file ASR only; secret from app pipe, never log/config-file it."""
from pathlib import Path
import json,subprocess,uuid,time,signal,threading,hashlib,plistlib,os
from fee_meter import FeeMeter
ROOT=Path(__file__).resolve().parent
NATIVE=ROOT/'native/nightly-build/会议采集候选.app/Contents/MacOS/MeetingCapture'

def verify_source(source):
    if hashlib.sha256(source.read_bytes()).hexdigest()!='e4d31ccf5923cff4678eb79e62136e229b22fe8ffdfef54a6a2b63a9453cf85e':
        raise ValueError('public_pcm_invalid')

def main():
    import sys
    incoming=json.loads(sys.stdin.readline());key=incoming.get('key')
    if set(incoming)!={'key'} or not isinstance(key,str) or not key or '\n' in key or '\r' in key:raise ValueError('credential_invalid')
    source=ROOT/'native/validation-workflow/public-mic-fixture/input.pcm'
    verify_source(source)
    session=str(uuid.uuid4());out=ROOT/'native/validation-workflow/public-cloud-trial'/session;out.mkdir(parents=True,mode=0o700)
    prior_seconds=0.0
    ledger_root=ROOT/'native/validation-workflow/public-cloud-trial'
    for old in ledger_root.glob('*/night-test-ledger.json'):
        value=json.loads(old.read_text());native=value.get('native_result')
        prior_seconds+=float(native['attempted_audio_seconds']) if native else float(value.get('reserved_max_attempted_audio_seconds',180))
    remaining=max(0,180-prior_seconds)
    if remaining<73.52:raise ValueError('initial_public_audio_seconds_exhausted')
    per_track=min(90,remaining/2)
    config=dict(session=session,bundle='*microphone*',key=key,confirmed=True,maxSeconds=per_track,model='qwen-audio-3.0-asr-flash-streaming',silenceMS=1300,micEnabled=True)
    ready_by=time.monotonic()+120
    while True:
        try:ready=plistlib.loads((NATIVE.parent.parent/'Info.plist').read_bytes()).get('PublicAudioASRTestAllowed') is True
        except (FileNotFoundError,ValueError):ready=False
        if ready:break
        if time.monotonic()>ready_by:raise ValueError('approved_public_runtime_not_ready')
        time.sleep(.1)
    # Reserve the entire permitted retry ceiling before any socket can be created.
    # A terminated launcher remains conservative; another run cannot silently reuse it.
    provisional=dict(approval='explicit_public_audio_probe',session=session,native_result=None,reserved_max_attempted_audio_seconds=per_track*2,prior_night_attempted_audio_seconds=prior_seconds,state='reserved_before_native_launch',key_written=False,live_capture=False,destination='dashscope.aliyuncs.com',region='Beijing',night_authorized_budget_yuan=5)
    ledger=out/'night-test-ledger.json';ledger.write_text(json.dumps(provisional,ensure_ascii=False,indent=2));os.chmod(ledger,0o600)
    child=subprocess.Popen([str(NATIVE),'--public-cloud-probe'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True);meter=FeeMeter();tasks=set();result=None
    watchdog=threading.Timer(180,lambda:child.send_signal(signal.SIGINT) if child.poll() is None else None);watchdog.daemon=True;watchdog.start()
    parent=os.getppid()
    def parent_watch():
        while child.poll() is None:
            if os.getppid()!=parent:child.send_signal(signal.SIGINT);return
            time.sleep(.2)
    threading.Thread(target=parent_watch,daemon=True).start()
    child.stdin.write(json.dumps(config)+'\n');child.stdin.flush();child.stdin.close();key=None;config=None;incoming=None
    with (out/'events.jsonl').open('w') as log:
        for line in child.stdout:
            event=json.loads(line)
            if event.get('type') in {'usage_local','usage_provider','health'}:meter.observe(event)
            if event.get('task_id'):tasks.add(event['task_id'])
            log.write(json.dumps(event,ensure_ascii=False)+'\n');log.flush()
            if event.get('type')=='public_cloud_trial_result':result=event
            if float(meter.snapshot()['estimated_yuan'])>5:child.send_signal(signal.SIGINT)
    child.wait(timeout=5);watchdog.cancel()
    receipt=dict(approval='explicit_public_audio_probe',session=session,task_ids=sorted(tasks),meter=meter.snapshot(),native_result=result,native_exit_code=child.returncode,key_written=False,live_capture=False,source='existing public LibriSpeech PCM; repeated across two tracks',requested_model='qwen-audio-3.0-asr-flash-streaming',response_model_reported=False,old_trial_ledger_modified=False,reserved_max_attempted_audio_seconds=per_track*2,prior_night_attempted_audio_seconds=prior_seconds,cumulative_attempted_audio_seconds=prior_seconds+float(result.get("attempted_audio_seconds",0)) if result else None)
    (out/'night-test-ledger.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2))
    print(json.dumps(dict(type='night_public_asr_summary',session=session,receipt=str(out/'night-test-ledger.json'),complete=bool(result and result['complete']),meter=meter.snapshot(),exit_code=child.returncode),ensure_ascii=False),flush=True)
    raise SystemExit(0 if child.returncode==0 and result and result['complete'] else 1)
if __name__=='__main__':
    try:main()
    except SystemExit:raise
    except Exception:print('public-asr-trial-failed; no credential output');raise SystemExit(1)
