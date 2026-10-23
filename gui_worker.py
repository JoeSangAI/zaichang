"""Private app pipe entry. No stored key, no interactive terminal, no retry."""
import json
import math
import sys
import subprocess
import os
import signal
import threading
import queue
from collections import deque
import time
from pathlib import Path
from runtime_config import data_root
from audio_sources import is_transcript_track, transcript_tracks, recording_control_signal
from shared_terms import meeting_project
from capture_supervisor import CaptureControlAckChannel, CaptureSupervisor
from identity_session import IdentitySession
from identity_bridge import PARTITION
from live_trial import prior_totals, single_instance, trial_config, run_trial, NATIVE
import plistlib
import tempfile
from datetime import datetime,timezone
import re
import uuid

CANDIDATE = Path(__file__).resolve().parent/'native/candidate-build/会议采集候选.app/Contents/MacOS/MeetingCapture'
ALLOWANCE_FILE = Path(__file__).resolve().parent/'native/candidate-build/trial-allowance.json'

def temporary_people(request):
    draft=request.get('candidate_people')
    if draft is None:return None
    if request.get('candidate_mode') is not True or request.get('human_identity_confirmed') is not True or not isinstance(draft,dict) or set(draft)-{'people','consents'}:
        raise ValueError('本场人物资料无效')
    consents=draft.get('consents',{})
    if not isinstance(consents,dict) or len(consents)>12 or any(not isinstance(c,dict) or set(c)-{'consent_id','active','purpose','persistent_allowed'} or c.get('active') is not True or not isinstance(c.get('consent_id'),str) or not 1<=len(c['consent_id'])<=160 or c.get('persistent_allowed') is not False or c.get('purpose')!='local_identity_until_app_exit' for c in consents.values()):
        raise ValueError('明天测试不恢复长期人物资料')
    state=dict(schema=1,partition=PARTITION,input_kind='consented_live_audio',people=draft.get('people',{}),consents=consents,samples=[])
    # Same production validator, with no restored features, calibration or history.
    return IdentitySession('candidate-draft-validation',human_use_authorized=True,snapshot=state).snapshot()

def candidate_binary(request):
    if request.get('candidate_mode',False) is not True:return NATIVE
    info=CANDIDATE.parent.parent/'Info.plist'
    if not info.is_file():raise ValueError('候选入口尚未准备好')
    settings=plistlib.loads(info.read_bytes())
    click_gate=settings.get('ClickStartsTrial') is True and request.get('user_launch_confirmed') is True
    if (settings.get('TrialArmed') is not True and not click_gate) or settings.get('OfflineOnly') is not False:
        raise ValueError('等待本人说开始后启用180秒测试')
    return CANDIDATE


def local_recording_config(request):
    import uuid
    if request.get('local_recording_confirmed') is not True or request.get('user_launch_confirmed') is not True or request.get('local_only') is not True:
        raise ValueError('local_recording_not_confirmed')
    bundle=request.get('bundle')
    if bundle not in {'com.tencent.meeting','*microphone*','*system*'} or request.get('mic_enabled') is not True or request.get('source_scope_confirmed') is not True:
        raise ValueError('local_recording_scope_invalid')
    seconds=request.get('local_max_seconds',3600)
    if type(seconds) not in (int,float) or not 0<seconds<=7200 or request.get('key') not in (None,'') or request.get('resume_cache_id') is not None or request.get('identity_snapshot') is not None or request.get('candidate_people') is not None:
        raise ValueError('local_recording_scope_invalid')
    config=dict(session=str(uuid.uuid4()),bundle=bundle,key='',confirmed=True,maxSeconds=seconds,unlimitedSession=True,model='qwen-audio-3.0-asr-flash-streaming',silenceMS=1300,micEnabled=True,userLaunchConfirmed=True,localOnly=True,localRecordingConfirmed=True,echoModelDirectory=str(Path(__file__).resolve().parent/'native/local-speaker-install/runtime-models'))
    return append_capture_config(request,config,local_only=True)

def append_capture_config(request,config,*,local_only):
    cache_id=request.get('append_capture_cache_id')
    if cache_id is None:return config
    if request.get('resume_cache_id') is not None or not isinstance(cache_id,str):raise ValueError('append_capture_scope_invalid')
    try: validated=str(uuid.UUID(cache_id)).lower()
    except ValueError:raise ValueError('append_capture_scope_invalid')
    if validated!=cache_id.lower():raise ValueError('append_capture_scope_invalid')
    directory=data_root()/'SessionCache'/cache_id
    if directory.is_symlink() or not directory.is_dir():raise ValueError('append_capture_scope_invalid')
    metadata=json.loads((directory/'meeting.json').read_text())
    previous_local=metadata.get('capture_mode')=='local_only'
    if previous_local!=local_only or metadata.get('bundle')!=config['bundle'] or metadata.get('asr_model')!=config['model'] or not isinstance(metadata.get('session'),str) or not metadata['session']:
        raise ValueError('append_capture_scope_invalid')
    config.update(session=metadata['session'],appendCaptureCacheID=cache_id)
    return config

def cloud_session_config(request):
    import uuid
    if request.get('cloud_session_confirmed') is not True or request.get('user_launch_confirmed') is not True or request.get('source_scope_confirmed') is not True or request.get('mic_enabled') is not True:
        raise ValueError('cloud_session_not_confirmed')
    if request.get('bundle') not in {'com.tencent.meeting','*microphone*','*system*'}:raise ValueError('cloud_session_scope_invalid')
    key=request.get('key')
    if not isinstance(key,str) or not key or '\n' in key or '\r' in key:raise ValueError('cloud_session_scope_invalid')
    root=Path(__file__).resolve().parent
    config=dict(session=str(uuid.uuid4()),bundle=request['bundle'],key=key,confirmed=True,maxSeconds=7200,unlimitedSession=True,model='qwen-audio-3.0-asr-flash-streaming',silenceMS=1300,micEnabled=True,userLaunchConfirmed=True,cloudSessionConfirmed=True,localSpeakerDirectory=str(root/'native/local-speaker-install/runtime-models'),localEmbeddingModel=str(root/'native/local-embedding-install/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx'))
    if request.get('resume_cache_id') is not None:
        cache_id=request['resume_cache_id']
        if not isinstance(cache_id,str) or str(uuid.UUID(cache_id)).lower()!=cache_id.lower():raise ValueError('resume_scope_invalid')
        directory=data_root()/'SessionCache'/cache_id
        if directory.is_symlink() or not directory.is_dir():raise ValueError('resume_scope_invalid')
        metadata=json.loads((directory/'meeting.json').read_text())
        if metadata.get('bundle')!=request['bundle'] or metadata.get('asr_model')!=config['model'] or not isinstance(metadata.get('session'),str):raise ValueError('resume_scope_invalid')
        local_pending=metadata.get('capture_mode')=='local_only' and metadata.get('upload_authorized') is not True
        if local_pending and request.get('resume_upload_confirmed') is not True:raise ValueError('local_audio_upload_not_confirmed')
        if not local_pending and (metadata.get('cloud_session_authorized') is not True or metadata.get('asr_destination')!='dashscope.aliyuncs.com'):raise ValueError('resume_scope_invalid')
        tracks=len(transcript_tracks(directory))
        if not 1<=tracks<=1024:raise ValueError('resume_scope_invalid')
        # maxSeconds remains for older helpers; the current native helper uses
        # unlimitedSession and does not gate on cumulative duration.
        config.update(session=metadata['session'],resumeCacheID=cache_id,maxSeconds=7200,unlimitedSession=True)
        if local_pending:config['resumeUploadConfirmed']=True
    config=append_capture_config(request,config,local_only=False)
    return config

def validate_request(request, prior_audio, prior_wall):
    if request.get("cloud_session_confirmed") is True:return cloud_session_config(request)
    if request.get("local_only") is True:return local_recording_config(request)
    if request.get('user_launch_confirmed') is not True:
        raise ValueError('缺少本人启动意图')
    bundle=request.get('bundle')
    if not isinstance(bundle,str) or not bundle or bundle.startswith('com.joesang.'):
        raise ValueError('音源选择无效')
    if bundle != 'com.tencent.meeting' and request.get('source_scope_confirmed') is not True:
        raise ValueError('新音源范围需要本人确认')
    if bundle=='*microphone*' and request.get('mic_enabled') is not True:
        raise ValueError('麦克风会议必须收录麦克风')
    if type(request.get('mic_enabled',True)) is not bool:
        raise ValueError('麦克风选择无效')
    remaining=min(450,max(0,int(480-prior_wall)))
    if type(request.get('candidate_mode',False)) is not bool:raise ValueError('候选选择无效')
    if request.get('candidate_mode'):
        if bundle not in {'com.tencent.meeting','*microphone*'} or request.get('mic_enabled') is not True or request.get('speaker_enabled') is not True:
            raise ValueError('明天测试仅腾讯会议与麦克风双轨')
        remaining=min(180,remaining)
        if request.get('identity_snapshot') is not None:raise ValueError('明天测试不恢复长期人物资料')
        temporary_people(request)
        allowance=json.loads(ALLOWANCE_FILE.read_text())
        baseline=allowance.get('baseline_wall_seconds')
        if type(baseline) not in (int,float) or allowance.get('max_candidate_wall_seconds')!=180:
            raise ValueError('候选预算记录无效')
        candidate_remaining=max(0,int(180-max(0,prior_wall-baseline)))
        if candidate_remaining<=0:raise ValueError('本次180秒测试额度已用完；不会重置')
        remaining=min(remaining,candidate_remaining)
    if remaining<=0:
        raise ValueError('原8分钟测试时长已结束；不会重置')
    config=trial_config(bundle, request.get('key',''), remaining)
    config['userLaunchConfirmed']=True
    config['micEnabled']=request.get('mic_enabled',True)
    if type(request.get('speaker_enabled',False)) is not bool:raise ValueError('模型选择无效')
    if request.get('speaker_enabled'):
        directory=Path(__file__).resolve().parent/'native/local-speaker-install/runtime-models'
        if not (directory/'Nemotron3Diarizer_low.mlmodelc/model.mil').is_file():raise ValueError('本地模型未安装')
        config['localSpeakerDirectory']=str(directory)
        embedding=Path(__file__).resolve().parent/'native/local-embedding-install/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx'
        if embedding.is_file():config['localEmbeddingModel']=str(embedding)
    if 'resume_cache_id' in request:
        import uuid
        cache_id=request['resume_cache_id']
        if not isinstance(cache_id,str) or str(uuid.UUID(cache_id)).lower()!=cache_id.lower():raise ValueError('恢复会话无效')
        directory=data_root()/'SessionCache'/cache_id
        if directory.is_symlink() or not directory.is_dir():raise ValueError('恢复会话无效')
        metadata=json.loads((directory/'meeting.json').read_text())
        local_pending=metadata.get('capture_mode')=='local_only' and metadata.get('upload_authorized') is not True
        if metadata.get('bundle')!=bundle or metadata.get('asr_model')!=config['model'] or not isinstance(metadata.get('session'),str) or (metadata.get('asr_destination')!='dashscope.aliyuncs.com' and not (local_pending and request.get('resume_upload_confirmed') is True)):
            raise ValueError('恢复会话范围变化，需要确认')
        if local_pending:
            if request.get('resume_upload_confirmed') is not True:raise ValueError('local_audio_upload_not_confirmed')
            config['resumeUploadConfirmed']=True
        config['resumeCacheID']=cache_id;config['session']=metadata['session']
    return config


def main():
    global CANDIDATE
    if sys.argv[1:]:
        if sys.argv[1:] not in (['--candidate-repair'],['--candidate-nightly']):raise ValueError('candidate_revision_invalid')
        CANDIDATE=Path(__file__).resolve().parent/('native/nightly-build/会议采集候选.app/Contents/MacOS/MeetingCapture' if sys.argv[1:]==['--candidate-nightly'] else 'native/candidate-repair-build/会议采集候选.app/Contents/MacOS/MeetingCapture')
    lock=single_instance(Path(tempfile.gettempdir())/("joesang-meeting-worker-"+str(os.getuid())+".lock"))
    request=json.loads(sys.stdin.readline())
    if request.get('mode')=='prepare':
        from model_standby import ModelStandby
        if request != {'mode':'prepare','candidate_mode':True}:raise ValueError('model_preparation_scope_invalid')
        info=plistlib.loads((CANDIDATE.parent.parent/'Info.plist').read_bytes())
        if info.get('TrialCandidate') is not True or info.get('OfflineOnly') is not False:raise ValueError('model_preparation_scope_invalid')
        root=Path(__file__).resolve().parent
        def publish(event):
            # Operational metadata only; separate from capture health and its budget.
            status={k:v for k,v in event.items() if k in {'type','state','track','elapsed_seconds','code','models_retained','models_released'}}
            status['updated_at_utc']=datetime.now(timezone.utc).isoformat()
            file=CANDIDATE.parents[3]/'preparation-state.json';temp=file.with_suffix('.tmp')
            fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
            with os.fdopen(fd,'w') as stream:json.dump(status,stream,ensure_ascii=False)
            os.replace(temp,file)
            print(json.dumps(event,ensure_ascii=False),flush=True)
        standby=ModelStandby(CANDIDATE,root/'native/local-speaker-install/runtime-models',root/'native/local-embedding-install/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx',publish)
        def cancel(signum=None,frame=None):
            standby.close();publish({'type':'preparation','state':'cancelled','capture':False,'network':False});raise SystemExit(0)
        signal.signal(signal.SIGINT,cancel);signal.signal(signal.SIGTERM,cancel)
        parent=os.getppid()
        def preparation_parent():
            while os.getppid()==parent:time.sleep(.2)
            os.kill(os.getpid(),signal.SIGTERM)
        threading.Thread(target=preparation_parent,daemon=True).start()
        try:
            standby.prepare()
            line=sys.stdin.readline()
            if not line:return
            request=json.loads(line)
            if request=={'preparation_only':True}:standby.release_only();return
            if request.get('candidate_mode') is not True:raise ValueError('model_preparation_scope_invalid')
            publish({'type':'preparation','state':'handed_to_trial'})
            execute(request,standby.child)
        except Exception as error:
            code=str(error) if str(error) in {'model_preparation_timeout','model_preparation_scope_invalid'} else 'model_preparation_failed'
            publish({'type':'preparation','state':'failed','code':code,'capture':False,'network':False})
        finally:
            standby.close()
        return
    execute(request)


def execute(request,prepared_child=None):
    if request.get("local_only") is True:return execute_local(request)
    if request.get("cloud_session_confirmed") is True:return execute_cloud_session(request)
    config=validate_request(request,*prior_totals())
    binary=candidate_binary(request)
    if not config.get('resumeCacheID'):
        desc=subprocess.run([str(binary),'--describe',config['bundle']],capture_output=True,text=True,check=True)
    if not config.get('resumeCacheID') and config['bundle'] not in {'*system*','*microphone*'} and not json.loads(desc.stdout).get('pids'): raise ValueError('腾讯会议未运行；未开始采集')
    human_scope=request.get('human_identity_confirmed') is True
    identity=IdentitySession(config['session'],human_use_authorized=human_scope,snapshot=temporary_people(request) if request.get('candidate_mode') else request.get('identity_snapshot'))
    parent=os.getppid()
    def watch_parent():
        while os.getppid()==parent: time.sleep(.2)
        os.kill(os.getpid(),signal.SIGINT)
    threading.Thread(target=watch_parent,daemon=True).start()
    print('状态：正在连接',flush=True)
    run_trial(config,identity_session=identity,command_stream=sys.stdin,native_binary=binary,prepared_child=prepared_child)

def execute_cloud_session(request):
    config=cloud_session_config(request);binary=candidate_binary(request)
    settings=plistlib.loads((binary.parent.parent/'Info.plist').read_bytes())
    if settings.get('LocalRecordingAllowed') is not True:raise ValueError('cloud_session_not_enabled')
    return run_independent_session(config,binary,cloud=True)

def execute_local(request):
    config=local_recording_config(request);binary=candidate_binary(request)
    info=plistlib.loads((binary.parent.parent/'Info.plist').read_bytes())
    if info.get('LocalRecordingAllowed') is not True:raise ValueError('local_recording_not_enabled')
    return run_independent_session(config,binary,cloud=False)

def capture_status_event(event):
    """Forward only capture counters; receiving PCM does not establish speech."""
    if event.get('type') != 'health':
        return None
    tracks = {}
    signal = {}
    for track,lane in event.items():
        if not is_transcript_track(track):continue
        count = lane.get('pcm_bytes') if isinstance(lane, dict) else None
        if type(count) is int and count >= 0:
            tracks[track] = count
            values = {key: lane[key] for key in (
                'hardware_pcm_frames','signal_samples','nonzero_samples','signal_peak','signal_rms',
                'last_packet_age_seconds','last_nonzero_age_seconds','raw_signal','clean_signal','input_diagnostics',
                'alignment_padding_bytes','admitted_pcm_bytes','padding_counters_known'
            ) if key in lane}
            if values:signal[track] = values
    if not tracks:return None
    result=dict(type='capture_status',session=event.get('session'),tracks=tracks)
    if signal:result.update(signal=signal,paused=event.get('paused') is True,elapsed_seconds=event.get('elapsed_seconds',0))
    return result


def recording_control_snapshot(event, previous, session):
    """Small local receipt for control state; never contains transcript or audio."""
    kind = event.get('type')
    if event.get('session') != session or kind not in {
            'started', 'recording_paused', 'recording_resumed', 'recording_pause_tail',
            'recording_control_failed', 'capture_control_failed', 'capture_stopped', 'stopped', 'error'}:
        return None
    result = dict(previous or {}, schema=1, session=session, last_event=kind)
    event_at = datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    result['updated_at'] = event_at
    if kind == 'started':
        recording = event.get('capture') is True or event.get('audio_frames_received') is True
        result['capture_gate'] = 'open' if recording else 'closed'
        result['upload_gate'] = 'open' if recording else 'closed'
        result['capture_session_active'] = recording
    if kind == 'error':
        result['last_error'] = safe_control_reason(event.get('code')) or 'recording_worker_failed'
    if kind in {'recording_paused', 'recording_resumed'}:
        revision = event.get('control_revision')
        if type(revision) is not int or revision <= result.get('control_revision', -1):
            return None
        result['control_revision'] = revision
        # A reason belongs to this ACK, not to a prior device-change pause.
        result.pop('reason', None)
        result['pause_tracks'] = ({track: 'processing' for track in event.get('draining_tracks', [])
                                   if isinstance(track, str) and is_transcript_track(track)}
                                  if kind == 'recording_paused' else {})
    elif kind == 'recording_pause_tail':
        track = event.get('track')
        if (event.get('pause_revision') != result.get('control_revision') or
                track not in result.get('pause_tracks', {}) or
                event.get('state') not in {'complete', 'pending'}):
            return None
        result['pause_tracks'] = dict(result['pause_tracks'], **{track: event['state']})
    for field in ('reason', 'capture_gate', 'upload_gate'):
        value = event.get(field)
        if isinstance(value, str):
            result[field] = value[:256]
    # Gate ownership follows the terminal/control event type; a stale gate
    # value carried by a later event cannot reopen a stopped recorder.
    if kind == 'recording_paused':
        result['capture_gate'],result['upload_gate']='closed','draining_saved_audio'
        result['capture_session_active']=True
    elif kind == 'recording_resumed':
        result['capture_gate'],result['upload_gate']='open','open'
        result['capture_session_active']=True
    elif kind == 'capture_stopped':
        result['capture_gate']='closed'
        result['upload_gate']=event.get('upload_gate','closed')
        result['capture_session_active']=False
    elif kind in {'stopped','error'}:
        result['capture_gate'],result['upload_gate']='closed','closed'
        result['capture_session_active']=False
    if kind in {'recording_control_failed', 'capture_control_failed'} and isinstance(event.get('reason'), str):
        result['native_failure'] = event['reason'][:256]
    if event.get('ack_transport') == 'dedicated_socket':
        result['ack_transport'] = 'dedicated_socket'
    if type(event.get('transcription_complete')) is bool:
        result['transcription_complete'] = event['transcription_complete']
    gap = safe_capture_gap(event)
    if kind == 'recording_paused' and gap:
        result.update(gap)
    existing_failure_reason=safe_control_reason(result.get('capture_failure_reason'))
    if result.get('capture_failure_reason') and existing_failure_reason is None:
        result.pop('capture_failure_reason',None)
        result.pop('capture_failure',None)
    failure_reason = safe_control_reason(event.get('capture_failure_reason'))
    if failure_reason is None and kind in {'recording_control_failed', 'capture_control_failed'}:
        failure_reason = safe_control_reason(event.get('reason'))
    if failure_reason is None and kind in {'capture_stopped', 'stopped'}:
        reason = safe_control_reason(event.get('reason'))
        if (reason and not reason.startswith(('processing_', 'asr_', 'transcription_')) and
                reason not in {'user_stop', 'user_finish', 'local_duration_limit',
                               'cloud_duration_limit', 'trial_time_limit', 'audio_budget_limit'}):
            failure_reason = reason
    if failure_reason and not existing_failure_reason:
        result['capture_failure_reason'] = failure_reason
        result['capture_failure'] = {
            'reason': failure_reason,
            'event': kind,
            'control_revision': event.get('control_revision') if type(event.get('control_revision')) is int else None,
            'recorded_at': event_at,
        }
    return result


def safe_capture_gap(value):
    """Keep a bounded gap diagnostic through resume/recovery, without source text."""
    duration = value.get('gap_seconds')
    reason = safe_control_reason(value.get('gap_reason'))
    if (value.get('coverage_gap') is True and reason and
            type(duration) in {int, float} and math.isfinite(duration) and duration >= 0):
        return {'coverage_gap': True, 'gap_reason': reason, 'gap_seconds': duration}
    return None


def safe_control_reason(value):
    """Accept only compact diagnostic codes; never persist event text or secrets."""
    if not isinstance(value, str) or not 1 <= len(value) <= 256:
        return None
    return value if re.fullmatch(r'[A-Za-z0-9_.:-]+', value) else None


def append_control_request(previous, session, action, *, accepted=True, requested_at=None, source='ui'):
    if action not in {'pause', 'resume', 'finish', 'stop', 'cancel'} or not isinstance(session, str):
        return previous
    result = dict(previous or {}, schema=1, session=session)
    result['last_request'] = {
        'action': action,
        'requested_at': requested_at or datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z'),
        'accepted': bool(accepted),
        'source': source if source in {'ui', 'signal', 'control_channel_closed', 'parent_exit'} else 'ui',
    }
    result['updated_at'] = result['last_request']['requested_at']
    return result


def read_same_session_control_receipt(cache, session):
    """Read only the prior session's structured control diagnostic, if present."""
    try:
        value = json.loads((Path(cache) / 'recording-control.json').read_text())
    except (OSError, UnicodeError, json.JSONDecodeError, TypeError):
        return None
    if not isinstance(value, dict) or value.get('session') != session:
        return None
    reason = safe_control_reason(value.get('capture_failure_reason'))
    failure = value.get('capture_failure')
    if reason and isinstance(failure, dict):
        failure = {'reason': reason, 'event': safe_control_reason(failure.get('event'))}
    else:
        failure = None
    # Carry only fields owned by this receipt. Never copy arbitrary cache data
    # into the new write, even if a local file was manually edited.
    receipt = {'schema': 1, 'session': session}
    for key in ('last_event', 'updated_at', 'reason', 'capture_gate', 'upload_gate', 'capture_session_active',
                'control_revision', 'pause_tracks', 'native_failure', 'transcription_complete',
                'ack_transport', 'last_request', 'helper_exit'):
        if key in value:
            receipt[key] = value[key]
    if reason and failure:
        receipt['capture_failure_reason'] = reason
        receipt['capture_failure'] = failure
    gap = safe_capture_gap(value)
    if gap:
        receipt.update(gap)
    return {'capture_failure_reason': reason, 'capture_failure': failure, 'receipt': receipt}


def initial_control_receipt(cache, session, *, recovery=False):
    receipt = {'schema': 1, 'session': session}
    if recovery:
        prior = read_same_session_control_receipt(cache, session)
        if prior:
            receipt = prior['receipt']
        receipt['last_recovery'] = {'run_kind': 'recovery'}
    return receipt


def write_control_receipt(cache, receipt):
    if cache is None or not isinstance(receipt, dict):
        return
    target = Path(cache) / 'recording-control.json'
    try:
        temporary = target.with_suffix('.json.tmp')
        temporary.write_text(json.dumps(receipt, ensure_ascii=False, separators=(',', ':')))
        os.chmod(temporary, 0o600)
        os.replace(temporary, target)
    except OSError:
        pass  # Diagnostics must never block capture or transcription.


def helper_exit_snapshot(return_code, forced_reason=None, *, recorded_at=None):
    if forced_reason:
        reason=safe_control_reason(forced_reason) or 'helper_forced_exit'
    elif isinstance(return_code,int) and return_code<0:
        reason='signal_'+str(-return_code)
    elif isinstance(return_code,int):
        reason='exit_'+str(return_code)
    else:
        reason='exit_unknown'
    return {
        'reason':reason,
        'return_code':return_code if isinstance(return_code,int) else None,
        'signal':-return_code if isinstance(return_code,int) and return_code<0 else None,
        'recorded_at':recorded_at or datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z'),
    }


def finalize_control_receipt_on_exit(receipt, exit_snapshot):
    """Close stale open gates and make an unplanned recorder exit recoverable."""
    result = dict(receipt or {})
    result['helper_exit'] = exit_snapshot
    active = result.get('capture_session_active') is True
    if active:
        result['capture_session_active'] = False
        result['capture_gate'] = 'closed'
        result['upload_gate'] = 'closed'
        result['last_event'] = 'helper_exit'
        reason = 'capture_helper_'+str(exit_snapshot.get('reason') or 'exit_unknown')
        result['capture_failure_reason'] = reason[:256]
        result['capture_failure'] = {
            'reason': result['capture_failure_reason'],
            'event': 'helper_exit',
            'control_revision': result.get('control_revision'),
            'recorded_at': exit_snapshot.get('recorded_at'),
        }
    elif result.get('last_event') != 'stopped' and result.get('capture_gate') == 'open':
        # Migrate older receipts that predate capture_session_active.
        result['capture_gate'] = 'closed'
        result['upload_gate'] = 'closed'
        result['last_event'] = 'helper_exit'
        result.setdefault('last_error', 'capture_helper_'+str(exit_snapshot.get('reason') or 'exit_unknown'))
    return result


def persist_active_meeting_lifecycle(cache, session, elapsed, *, at=None):
    """Replace a stale ended marker when this saved meeting records again."""
    if cache is None or not isinstance(session, str) or not session:
        return
    if type(elapsed) not in (int, float) or not math.isfinite(elapsed) or elapsed < 0:
        elapsed = 0
    try:
        cache = Path(cache)
        if cache.is_symlink() or not cache.is_dir():
            return
        target = cache / 'meeting-lifecycle.json'
        try:
            prior = json.loads(target.read_text())
        except (OSError, UnicodeError, json.JSONDecodeError):
            return
        if not isinstance(prior, dict) or prior.get('session') != session or prior.get('lifecycle') != 'ended':
            return
        temporary = target.with_suffix('.json.tmp')
        value = {'schema': 1, 'lifecycle': 'active', 'session': session,
                 'recording_elapsed_seconds': elapsed,
                 'resumed_at': at or datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')}
        temporary.write_text(json.dumps(value, ensure_ascii=False, separators=(',', ':')))
        os.chmod(temporary, 0o600)
        os.replace(temporary, target)
    except OSError:
        pass  # Lifecycle is diagnostic and must never interrupt audio capture.


def control_event_for_ui(event, *, recovery, source_capture_failure_reason):
    """Carry the original capture cause through a successful same-session recovery."""
    source_capture_failure_reason=safe_control_reason(source_capture_failure_reason)
    if (recovery and event.get('type') == 'stopped' and source_capture_failure_reason and
            event.get('reason') in {'user_stop', 'user_finish'}):
        return dict(event, capture_failure_reason=source_capture_failure_reason)
    return event


class PauseControlEventDelivery:
    """Serialize pause ACKs before tails across the independent output channels."""
    def __init__(self):
        self._events = queue.SimpleQueue()
        self._lock = threading.Lock()
        self._acknowledged = set()
        self._early_tails = {}

    def acknowledge(self, event):
        revision = event.get('control_revision')
        if type(revision) is not int:
            return
        with self._lock:
            self._acknowledged.add(revision)
            self._events.put(event)
            for tail in self._early_tails.pop(revision, []):
                self._events.put(tail)
            for stale in list(self._early_tails):
                if stale < revision:
                    self._early_tails.pop(stale, None)
            if len(self._acknowledged) > 8:
                self._acknowledged = set(sorted(self._acknowledged)[-8:])
            if len(self._early_tails) > 4:
                for stale in sorted(self._early_tails)[:-4]:
                    self._early_tails.pop(stale, None)

    def tail(self, event):
        revision = event.get('pause_revision')
        if type(revision) is not int:
            return
        with self._lock:
            if revision in self._acknowledged:
                self._events.put(event)
            else:
                tails = self._early_tails.setdefault(revision, [])
                if len(tails) < 512:
                    tails.append(event)

    def receive(self):
        return self._events.get()

    def close(self):
        self._events.put(None)


def run_independent_session(config,binary,cloud=False):
    from fee_meter import FeeMeter, cumulative_asr_fee, session_usage_snapshot, combined_session_fee, coarse_reserved_yuan
    from decimal import Decimal
    meter=FeeMeter();previous_input=0.0;previous_fee=Decimal(0)
    recovering=bool(config.get('resumeCacheID'))
    cache=(data_root()/'SessionCache'/config['resumeCacheID']) if recovering else None
    prior_receipt=read_same_session_control_receipt(cache,config['session']) if recovering else None
    source_capture_failure_reason=prior_receipt['capture_failure_reason'] if prior_receipt else None
    control_receipt=initial_control_receipt(cache,config['session'],recovery=recovering)
    control_receipt_lock=threading.Lock()
    output_lock = threading.Lock()
    def emit_ui(value):
        # ACK delivery and general events share one framed UI stream. Keep the
        # JSON body and newline together when the two threads publish at once.
        with output_lock:
            print(json.dumps(value, ensure_ascii=False), flush=True)
    if recovering:
        usage=cache/'session-usage.json'
        previous_fee=None;previous_input=None
        if usage.exists():
            try:
                old=json.loads(usage.read_text())
                if isinstance(old,dict):
                    old_meter=old.get('meter') if isinstance(old.get('meter'),dict) else {}
                    raw_input=old.get('cumulative_input_audio_seconds',old_meter.get('input_audio_seconds'))
                    if type(raw_input) in (int,float) and raw_input>=0:previous_input=float(raw_input)
                    previous_fee=cumulative_asr_fee(old)
            except (OSError,UnicodeError,json.JSONDecodeError,ValueError,TypeError):
                pass  # Usage history is diagnostic; an unreadable ledger is reported as unknown.
    ack_channel = CaptureControlAckChannel()
    ack_child_fd = ack_channel.child_fd
    try:
        child=subprocess.Popen([str(binary),'--run-confirmed'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                               text=True,pass_fds=(ack_child_fd,))
    except BaseException:
        ack_channel.close()
        raise
    parent=os.getppid()
    supervisor=CaptureSupervisor(child,config['session'],parent_pid=parent)
    pause_event_delivery = PauseControlEventDelivery()
    pending_signal_stops = deque()
    helper_error_received = False

    def persist_control_receipt():
        write_control_receipt(cache,control_receipt)

    def remember_control(event):
        nonlocal control_receipt
        with control_receipt_lock:
            if recovering:
                recovery_receipt = control_receipt.get('last_recovery', {'run_kind':'recovery'})
                snapshot = recording_control_snapshot(event, recovery_receipt, config['session'])
            else:
                snapshot = recording_control_snapshot(event, control_receipt, config['session'])
            if snapshot is None:
                return
            supervisor_state=supervisor.snapshot()
            if supervisor_state['recovery_stage'] is not None:
                snapshot['control_recovery_stage'] = supervisor_state['recovery_stage']
            if event.get('ack_transport') == 'dedicated_socket':
                snapshot['ack_transport'] = 'dedicated_socket'
            if recovering:
                snapshot.pop('capture_failure_reason', None)
                snapshot.pop('capture_failure', None)
                snapshot.pop('schema', None)
                snapshot.pop('session', None)
                control_receipt = dict(control_receipt, last_recovery=snapshot)
            else:
                control_receipt = snapshot
            persist_control_receipt()

    def remember_request(action, accepted, source):
        nonlocal control_receipt
        with control_receipt_lock:
            if recovering:
                recovery_receipt = control_receipt.get('last_recovery', {'run_kind':'recovery'})
                recovery_request = append_control_request(
                    recovery_receipt,config['session'],action,accepted=accepted,source=source)
                recovery_request.pop('schema', None)
                recovery_request.pop('session', None)
                control_receipt = dict(control_receipt, last_recovery=recovery_request)
            else:
                control_receipt=append_control_request(control_receipt,config['session'],action,
                                                       accepted=accepted,source=source)
            persist_control_receipt()

    def remember_helper_exit():
        nonlocal control_receipt
        return_code=child.returncode
        forced=supervisor.snapshot()['forced_reason']
        exit_snapshot=helper_exit_snapshot(return_code,forced)
        terminal_event=None
        with control_receipt_lock:
            if recovering:
                recovery_receipt = control_receipt.get('last_recovery', {'run_kind':'recovery'})
                prior_last=recovery_receipt.get('last_event')
                recovery_receipt = finalize_control_receipt_on_exit(recovery_receipt,exit_snapshot)
                control_receipt=dict(control_receipt,last_recovery=recovery_receipt)
                if not helper_error_received and prior_last not in {'stopped','error'}:
                    terminal_event={'type':'error','session':config['session'],
                                    'code':'processing_helper_exit','audio_retained':True}
            else:
                prior_last=control_receipt.get('last_event') if isinstance(control_receipt,dict) else None
                had_capture=bool(isinstance(control_receipt,dict) and
                                 (control_receipt.get('capture_session_active') is True or
                                  prior_last in {'started','recording_paused','recording_resumed','capture_stopped'}))
                control_receipt=finalize_control_receipt_on_exit(
                    control_receipt or {'schema':1,'session':config['session']},exit_snapshot)
                if not helper_error_received and prior_last not in {'stopped','error'}:
                    reason=(control_receipt.get('capture_failure_reason') or 'processing_helper_exit')
                    if had_capture:
                        terminal_event={'type':'stopped','session':config['session'],'reason':reason,
                                        'capture':False,'capture_gate':'closed','upload_gate':'closed',
                                        'transcription_complete':False,'raw_audio_saved':True,
                                        'audio_retained':True,'capture_failure_reason':control_receipt.get('capture_failure_reason')}
                    else:
                        terminal_event={'type':'error','session':config['session'],
                                        'code':'recording_worker_failed','audio_retained':False}
            persist_control_receipt()
        return terminal_event

    def remember_supervisor_event(event):
        # Keep the watchdog free to enforce later control deadlines even when
        # UI stdout or receipt persistence is temporarily blocked.
        pause_event_delivery.tail(event)

    supervisor.event_callback=remember_supervisor_event

    def remember_started_cache(event):
        nonlocal cache
        cache_id=event.get('cache_id')
        if not isinstance(cache_id,str):
            return
        try:
            import uuid
            uuid.UUID(cache_id)
        except (ValueError,TypeError,AttributeError):
            return
        expected=data_root()/'SessionCache'
        candidate=expected/cache_id
        if recovering and candidate != cache:
            return
        cache=candidate
        if event.get('capture') is True or event.get('audio_frames_received') is True:
            persist_active_meeting_lifecycle(
                cache,config['session'],event.get('recording_elapsed_seconds',0))
    def receive_control_ack(event):
        # Process the gate ACK before any potentially blocked general event output.
        if event.get('type') not in {'recording_paused', 'recording_resumed'}:
            return
        event['ack_transport'] = 'dedicated_socket'
        supervisor.observe(event)
        pause_event_delivery.acknowledge(event)

    def deliver_control_acks():
        while True:
            event = pause_event_delivery.receive()
            if event is None:
                return
            # Keep the visible confirmation off the child's ordinary stdout
            # reader, which may be occupied with an earlier event.
            remember_control(event)
            visible_event = dict(event)
            visible_event.pop('ack_transport', None)
            emit_ui(visible_event)
    ack_delivery_thread = threading.Thread(target=deliver_control_acks, daemon=True,
                                           name='capture-control-ack-delivery')
    ack_delivery_thread.start()
    ack_channel.start(receive_control_ack)
    def request_stop(source):
        state=supervisor.snapshot()
        action='cancel' if state['capture_closed'] else 'stop'
        accepted=supervisor.stop(source)
        remember_request(action,accepted,source)
    def stop(signum=None,frame=None):
        # Python signal handlers run on the main thread and may interrupt a
        # receipt write while its non-reentrant lock is held. Queue only; the
        # existing watcher performs control and persistence work.
        pending_signal_stops.append(signum)
    previous=signal.signal(signal.SIGINT,stop);previous_term=signal.signal(signal.SIGTERM,stop)
    def watch():
        while child.poll() is None:
            while pending_signal_stops:
                pending_signal_stops.popleft()
                request_stop('signal')
            if os.getppid()!=parent:request_stop('parent_exit');return
            time.sleep(.2)
    threading.Thread(target=watch,daemon=True).start()
    try:
        # The write descriptor is inherited by the child; the parent copy is
        # already closed by start(). Send the numeric child descriptor in config.
        config['controlAckFD'] = ack_child_fd
        child.stdin.write(json.dumps(config)+'\n');child.stdin.flush()
        # The same process remains alive while paused. Control commands never
        # replace the session or its capture/usage authority.
        def controls():
            for command_line in sys.stdin:
                try:command=json.loads(command_line)
                except (ValueError,TypeError):continue
                accepted=supervisor.request(command)
                if isinstance(command,dict) and command.get('session')==config['session']:
                    remember_request(command.get('action'),accepted,'ui')
            request_stop('control_channel_closed')
        threading.Thread(target=controls,daemon=True).start()
        for line in child.stdout:
            event=json.loads(line)
            if event.get('type') == 'error':
                helper_error_received = True
                event = dict(event, session=config['session'],
                             code=safe_control_reason(event.get('code')) or 'recording_worker_failed')
            event=control_event_for_ui(event,recovery=recovering,
                                       source_capture_failure_reason=source_capture_failure_reason)
            if event.get('type')=='started':
                remember_started_cache(event)
            elif event.get('type')=='recording_resumed' and cache is not None:
                persist_active_meeting_lifecycle(
                    cache,config['session'],event.get('recording_elapsed_seconds',0))
            supervisor.observe(event)
            kind=event.get('type')
            if kind in {'recording_paused', 'recording_resumed'}:
                pause_event_delivery.acknowledge(event)
            elif kind == 'recording_pause_tail':
                pause_event_delivery.tail(event)
            else:
                remember_control(event)
            activity=capture_status_event(event)
            if activity is not None:emit_ui(activity)
            if cloud:
                meter.observe(event)
                if kind in {'health','usage_local','usage_provider','stopped'}:
                    snapshot=meter.snapshot();usage_snapshot=session_usage_snapshot(snapshot,previous_input,previous_fee,config['session'])
                    combined_fee=combined_session_fee(usage_snapshot,cache,config['session']) if cache is not None else cumulative_asr_fee(usage_snapshot)
                    asr_fee=usage_snapshot['cumulative_estimated_yuan']
                    coarse_value=coarse_reserved_yuan(cache,config['session']) if cache is not None else Decimal(0)
                    coarse_fee=str(coarse_value) if coarse_value is not None else 'unknown'
                    emit_ui(dict(snapshot,estimated_yuan=asr_fee,combined_estimated_yuan=str(combined_fee) if combined_fee is not None else 'unknown',coarse_reserved_yuan=coarse_fee if coarse_fee is not None else 'unknown',cumulative_usage_status='known' if asr_fee is not None else 'unknown'))
                    if cache is not None:
                        try:
                            file=cache/'session-usage.json';temp=file.with_suffix('.tmp');temp.write_text(json.dumps(usage_snapshot,ensure_ascii=False));os.chmod(temp,0o600);os.replace(temp,file)
                        except OSError:
                            pass  # Usage persistence must never interrupt capture or transcription.
                if kind in {'audio_levels','started','segment','speaker_model','capture_stopped','processing_started','processing_failed','stopped','error','asr_replay','asr_reconnecting','asr_pending','asr_catching_up','asr_resumed','audio_source','echo_status'}:emit_ui(event)
            elif kind in {'audio_levels','started','meter','capture_stopped','stopped','error','processing_failed','audio_source','echo_status'}:emit_ui(event)
        child.wait(timeout=5)
        if supervisor.forced_reason:
            stopped = dict(type='stopped',session=config['session'],reason=supervisor.forced_reason,capture=False,network=False,transcription_complete=False,audio_retained=True)
            remember_control(stopped)
            emit_ui(stopped)
        # Any unreported helper exit is translated by remember_helper_exit()
        # into a terminal UI event after the local receipt has been closed.
    finally:
        signal.signal(signal.SIGINT,previous);signal.signal(signal.SIGTERM,previous_term)
        if child.poll() is None:
            supervisor.stop()
            try:child.wait(timeout=3)
            except subprocess.TimeoutExpired:child.kill();child.wait(timeout=3)
        terminal_event=remember_helper_exit()
        if terminal_event is not None:
            remember_control(terminal_event)
            emit_ui(terminal_event)
        supervisor.close()
        ack_channel.close()
        pause_event_delivery.close()
        if child.stdin is not None:
            child.stdin.close()
        if child.stdout is not None:
            child.stdout.close()
    # Intentionally no HealthWriter, trial allowance mutation, key or cloud ASR.

if __name__=='__main__':
    try: main()
    except Exception as error:
        safe={'腾讯会议未运行；未开始采集','原8分钟测试时长已结束；不会重置','当前试验仅允许腾讯会议范围','缺少本人启动意图','已有试验入口正在等待或运行，请勿重复启动','等待本人说开始后启用180秒测试','候选入口尚未准备好','明天测试仅腾讯会议与麦克风双轨','明天测试不恢复长期人物资料','本次180秒测试额度已用完；不会重置'}
        # Do not replace an actionable native error with an unrelated legacy
        # startup/budget message. Never put arbitrary exception text in output.
        reason=str(error) if str(error) in safe else None
        code = 'worker_preflight_failed'
        if str(error) in {'recording_worker_failed', 'local_recording_failed'}:code='recording_worker_failed'
        print(json.dumps(dict(type='error', code=code, **({'message':reason} if reason else {})),ensure_ascii=False),flush=True)
        sys.exit(1)
