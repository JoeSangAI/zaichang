"""Repeatable, strictly local readiness/cancel tests of the final candidate binary.

Never send a capture config, key or PCM from a device. Cache state is not erased;
first/second run labels describe processes, not a guaranteed cold system cache.
"""
from pathlib import Path
import hashlib
import json
import time
from model_standby import ModelStandby


def main():
    root=Path(__file__).resolve().parents[1]
    binary=root/'native/candidate-build/会议采集候选.app/Contents/MacOS/MeetingCapture'
    directory=root/'native/local-speaker-install/runtime-models'
    embedding=root/'native/local-embedding-install/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx'
    health=root/'trial-health.json';allowance=root/'native/candidate-build/trial-allowance.json'
    before={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [health,allowance]}
    results=[]
    def run(label):
        events=[];began=time.monotonic()
        def emit(event):
            events.append(event)
            if event.get('state')!='progress':print(json.dumps(dict(case=label,event=event),ensure_ascii=False),flush=True)
        s=ModelStandby(binary,directory,embedding,emit)
        try:
            s.prepare();ready=time.monotonic()-began
            assert s.ready and s.child.poll() is None
            time.sleep(2) # Same process retains both models, without any start/config.
            assert s.child.poll() is None
            s.release_only();assert s.child.returncode==0
            assert any(e.get('state')=='released' and e.get('models_released')==2 for e in events)
            results.append(dict(case=label,ready_seconds=ready,pid=s.child.pid,events=events,models_released=2,exit_code=0))
        finally:s.close()
    run('first_repaired_candidate_process')
    run('second_same_identity_process')
    s=ModelStandby(binary,directory,embedding,lambda e:None)
    try:
        first=json.loads(s.child.stdout.readline());assert first.get('state')=='loading'
        began=time.monotonic();s.close();assert s.child.poll() is not None
        results.append(dict(case='cancel_during_load',cancel_seconds=time.monotonic()-began,pid=s.child.pid,exit_code=s.child.returncode))
    finally:s.close()
    run('reopen_after_cancel')
    after={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [health,allowance]}
    assert before==after
    evidence=dict(cases=results,health_and_budget_unchanged=True,forced_cold_cache=False,
        native_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),capture=False,network=False,keychain=False,
        scope='local model initialization and generated-silence warmup only',automatic_retries=0)
    out=root/'native/validation-workflow/startup-readiness.json';out.write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(dict(type='startup_validation_complete',cases=len(results),capture=False,network=False),ensure_ascii=False),flush=True)


if __name__=='__main__':main()
