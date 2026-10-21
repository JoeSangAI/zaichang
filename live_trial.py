"""Interactive, bounded trial launcher. No recording or network on import/dry-run."""
import argparse
import getpass
import json
import os
import signal
import subprocess
import sys
import time
import uuid
import warnings
import threading
import queue
import fcntl
import stat
from datetime import datetime, timezone
from pathlib import Path
from dual_track import DualTrack
from fee_meter import FeeMeter

NATIVE = Path(__file__).parent / 'native/build/会议采集测试.app/Contents/MacOS/MeetingCapture'
RATE = 0.00033
PREVIOUS_AUDIO_SECONDS = 18.7855  # User supplied first-trial output; not a billing receipt.
REMAINING_SECONDS = 450  # Conservative remainder of the original 480s trial, no extension.
HEALTH = Path(__file__).parent / 'trial-health.json'


def prior_totals(path=HEALTH):
    path=Path(path)
    if not path.exists(): return PREVIOUS_AUDIO_SECONDS, 19.0
    prior=json.loads(path.read_text())
    audio=float(prior.get('previous_audio_seconds',0))+sum(max(float(x.get('sent_audio_seconds',0)),float(x.get('attempted_audio_seconds',0)),float(x.get('provider_audio_seconds',0))) for x in prior.get('tracks',{}).values())
    wall=float(prior.get('previous_wall_seconds',0))+float(prior.get('elapsed_seconds',0))
    if prior.get('phase') in {'active','launching'}:
        wall=max(wall,float(prior.get('previous_wall_seconds',0))+float(prior.get('max_seconds',450)))
    return audio,wall


def single_instance(path=None):
    path = Path(path) if path is not None else Path(__file__).parent / 'native/build/trial.lock'
    descriptor=os.open(path,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW|os.O_NONBLOCK,0o600)
    attributes=os.fstat(descriptor)
    if not stat.S_ISREG(attributes.st_mode) or attributes.st_uid!=os.getuid() or attributes.st_nlink!=1:
        os.close(descriptor);raise ValueError('工作进程锁文件无效')
    os.fchmod(descriptor,0o600);handle=os.fdopen(descriptor,'a')
    try: fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        raise ValueError('已有试验入口正在等待或运行，请勿重复启动')
    return handle


class HealthWriter:
    """Strict metadata allowlist. Never persist transcript, key, raw response or audio."""
    def __init__(self, session, bundle, seconds, pid, path=HEALTH):
        self.path = Path(path)
        prior_audio,prior_wall=prior_totals(path)
        self.values = {'session': session, 'bundle': bundle, 'native_pid': pid,
                       'phase': 'launching', 'max_seconds': seconds, 'budget_yuan': 1,
                       'previous_user_reported_audio_seconds': PREVIOUS_AUDIO_SECONDS,
                       'previous_audio_seconds': prior_audio, 'previous_wall_seconds': prior_wall,
                       'supplier_bill_verified': False, 'tracks': {},
                       'partial_counts': {'mic': 0, 'remote': 0}, 'final_counts': {'mic': 0, 'remote': 0}}
        self.values['quality_warning_counts']={'mic':0,'remote':0}
        self.delays = {t: {'partial': [], 'final': []} for t in ['mic', 'remote']}
        self.started_at = None

    def observe(self, e):
        kind = e.get('type')
        if kind == 'health':
            self.values['elapsed_seconds'] = e['elapsed_seconds']
            for track in ['mic', 'remote']:
                metrics = e.get(track, {})
                self.values['tracks'][track] = {k: v for k, v in metrics.items()
                    if k in {'speaker_frames_total','speaker_single_frames','speaker_overlap_frames','speaker_unvoiced_frames','speaker_annotation_known_count','speaker_annotation_unknown_count','speaker_annotation_multiple_count','speaker_unknown_coverage_gap','speaker_unknown_no_speaker_evidence','speaker_unknown_insufficient_voiced_evidence','speaker_unknown_asr_quality','speaker_unknown_no_reliable_span','speaker_unknown_source_or_epoch_mismatch','pcm_frames', 'pcm_bytes', 'nonzero_frames', 'queued_bytes', 'asr_ready', 'sent_audio_seconds',
                             'attempted_audio_seconds','task_attempted_audio_seconds','inflight_bytes','send_calls','send_wait_total_seconds','send_wait_max_seconds',
                             'max_queued_bytes','discarded_bytes','coverage_gap','provider_audio_seconds',
                             'queue_age_total_seconds','queue_age_max_seconds','model_ingest_wait_total_seconds','model_ingest_wait_max_seconds',
                             'socket_send_wait_total_seconds','socket_send_wait_max_seconds','annotation_wait_total_seconds','annotation_wait_max_seconds','automatic_asr_retries','boundary_trimmed_bytes','buffer_capacity_bytes','buffered_audio_seconds','buffer_near_full','speaker_ready','speaker_processed_audio_seconds','speaker_backlog_seconds','speaker_queue_peak_bytes','speaker_discarded_bytes','speaker_coverage_gap','speaker_buffer_near_full'}
                    and isinstance(v, (int, float, bool))}
        elif kind == 'segment' and not e.get('annotation_only'):
            track=e['track']; status='final' if e['final'] else 'partial'
            self.values[status+'_counts'][track] += 1
            if e.get('quality_flags'): self.values['quality_warning_counts'][track]+=1
            self.delays[track][status].append(max(0, e['received_at'] - e['start']))
        elif kind == 'started':
            self.values['phase']='active'; self.values['started_at_utc']=datetime.now(timezone.utc).isoformat()
        elif kind in {'capture_stopped','processing_started'}:
            self.values['phase']='processing';self.values['elapsed_seconds']=e['recording_elapsed_seconds'];self.values['capture_stopped_reason']=e.get('reason',self.values.get('capture_stopped_reason','unknown'))
        elif kind == 'stopped':
            self.values['phase']='stopped'; self.values['stop_reason']=e['reason']
            self.values['elapsed_seconds']=e.get('recording_elapsed_seconds',e['received_at'])
            for track in self.values['tracks'].values():
                track['asr_ready']=False
        elif kind == 'usage_local':
            self.values['tracks'].setdefault(e['track'], {})['sent_audio_seconds']=max(self.values['tracks'][e['track']].get('sent_audio_seconds',0),e.get('total_attempted_audio_seconds',e['sent_audio_seconds']))
        elif kind == 'error':
            self.values['phase']='error'; self.values['error_code']=e['code']
        elif kind == 'usage_provider':
            self.values['tracks'].setdefault(e['track'], {})['provider_audio_seconds']=max(e['duration'],self.values['tracks'][e['track']].get('provider_audio_seconds',0))
        elif kind == 'health_notice':
            self.values['notice']=e['code']
        else: return
        self.values['updated_at_utc']=datetime.now(timezone.utc).isoformat()
        sent=sum(max(x.get('sent_audio_seconds',0),x.get('attempted_audio_seconds',0)) for x in self.values['tracks'].values())
        self.values['estimated_total_asr_yuan']=(sent+self.values['previous_audio_seconds'])*RATE
        # This is provider sentence-start -> receipt, not measured human first-phoneme latency.
        self.values['sentence_timestamp_to_receipt']={}
        for track, groups in self.delays.items():
            self.values['sentence_timestamp_to_receipt'][track]={}
            for group, data in groups.items():
                ordered=sorted(data)
                if ordered:
                    self.values['sentence_timestamp_to_receipt'][track][group]={
                        'count':len(ordered),'p50':ordered[int((len(ordered)-1)*.5)],'p95':ordered[int((len(ordered)-1)*.95)]}
        temp=self.path.with_suffix('.json.tmp')
        fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
        with os.fdopen(fd,'w') as stream: json.dump(self.values,stream,ensure_ascii=False,indent=2)
        os.replace(temp,self.path)


def trial_config(bundle, key, seconds=REMAINING_SECONDS, silence=1300):
    if not isinstance(bundle, str) or not bundle or not 0 < seconds <= REMAINING_SECONDS:
        raise ValueError('必须选定应用；前轮已结束，本次最多剩余450秒')
    if not key or '\n' in key or '\r' in key or silence not in {400, 800, 1300}:
        raise ValueError('密钥或断句参数无效')
    estimate = seconds * 2 * RATE
    if estimate > 1:
        raise ValueError('ASR估算超过1元')
    return {'session': str(uuid.uuid4()), 'bundle': bundle, 'key': key,
            'confirmed': True, 'maxSeconds': seconds,
            'model': 'qwen-audio-3.0-asr-flash-streaming', 'silenceMS': silence}


class TrialDeadline:
    """Bounded startup, then native capture budget; repeated started events cannot extend it."""
    def __init__(self,max_seconds,now):
        self.max_seconds=max_seconds;self.started_at=None;self.expires_at=now+45;self.processing_at=None
    def recording_started(self,now):
        if self.started_at is not None:return False
        self.started_at=now;self.expires_at=now+self.max_seconds+5;return True

    def processing_started(self,now):
        if self.started_at is None or self.processing_at is not None:return False
        self.processing_at=now
        self.expires_at=min(self.started_at+self.max_seconds+185,now+185)
        return True


class TrialView:
    def __init__(self, session, bundle):
        self.bridge = DualTrack(session, bundle, source_kind='capture-asr')
        self.bridge.start(user_confirmed=True, mode='text-only')
        self.usage = {}
        self.stopped = False
        self.last_at = 0

    def receive(self, e):
        kind = e.get('type')
        if kind == 'segment':
            if self.stopped:
                raise ValueError('停止后仍收到正文')
            self.bridge.ingest(e['track'], e)
            self.last_at = max(self.last_at, e['received_at'])
            # No permanent transcript write; partial explicitly marked.
            label = '本地麦克风' if e['track'] == 'mic' else '远端混音'
            status='句末待核对' if e.get('quality_flags') else '句末结果' if e['final'] else '暂定'
            return f"[{e['start']:.2f}] {label} {status}：{e['text']}"
        if kind == 'usage_local':
            self.usage[e['track']] = e['sent_audio_seconds']
        elif kind == 'stopped':
            self.last_at = max(self.last_at, e['received_at'])
            self.bridge.stop(self.last_at)
            self.stopped = True
            return '【测试已停止，现在说话不会收录】'+('原音分段暂存在本机。' if e.get('raw_audio_saved') else '原音频未保存。')+'原因：'+e['reason']
        elif kind == 'error':
            return '未开始或执行失败：' + e['code']
        elif kind == 'started':
            return '正在转写；停止：Ctrl-C；最多8分钟。不自动识别人名。'
        elif kind == 'capture_scope':
            return '应用声音范围：' + e['bundle'] + '；PID ' + str(e['pids'])
        elif kind == 'health':
            return f"健康：mic帧={e['mic']['pcm_frames']}，远端帧={e['remote']['pcm_frames']}，远端非零帧={e['remote']['nonzero_frames']}"
        elif kind == 'health_notice':
            return '状态：'+e['code']
        return None


class DisplayPump:
    """Bounded terminal writer. Partial updates replace one pending row; never block ingestion."""
    def __init__(self, writer=None, capacity=64):
        self.writer=writer or (lambda text: sys.stdout.write(text))
        self.messages=queue.Queue(maxsize=capacity)
        self.lock=threading.Lock(); self.pending={}; self.closed=False; self.failure=None
        self.thread=threading.Thread(target=self.guarded_run,daemon=True)
        self.thread.start()
    def push(self,event,message):
        if self.failure is not None: raise ValueError('terminal_display_failed')
        if event.get('type')=='health':
            with self.lock: self.pending['health']=('health',message)
            return
        if event.get('type')=='stopped':
            with self.lock: self.pending.clear()
        if event.get('type')=='segment' and not event.get('final'):
            with self.lock: self.pending[event['track']]=(event['segment_id'],message)
            return
        if event.get('type')=='segment':
            with self.lock:
                if self.pending.get(event['track'],(None,))[0]==event['segment_id']: self.pending.pop(event['track'],None)
        try: self.messages.put_nowait(message)
        except queue.Full: raise ValueError('terminal_display_backpressure')
    def guarded_run(self):
        try: self.run()
        except Exception:
            self.failure=True; self.closed=True

    def run(self):
        previous=None
        while not self.closed or not self.messages.empty():
            try:
                message=self.messages.get(timeout=.1)
                self.writer('\r\033[2K'+message+'\n'); self.messages.task_done()
            except queue.Empty: pass
            with self.lock: pending=' | '.join(value[1] for _,value in sorted(self.pending.items()))
            if pending!=previous:
                self.writer('\r\033[2K'+pending); previous=pending
            try: sys.stdout.flush()
            except OSError: return
        self.writer('\n')
    def finish(self):
        self.closed=True; self.thread.join(timeout=2)


class GUIEventPump(DisplayPump):
    """Same bounded ingestion contract; JSONL for native UI, no terminal escapes."""
    def run(self):
        previous={}
        while not self.closed or not self.messages.empty():
            try:
                message=self.messages.get(timeout=.1)
                self.writer(message+'\n'); self.messages.task_done()
            except queue.Empty: pass
            with self.lock: pending=dict(self.pending)
            for track,value in sorted(pending.items()):
                if previous.get(track)!=value: self.writer(value[1]+'\n')
            previous=pending
            sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True, help='本次明确选择的会议应用Bundle ID')
    parser.add_argument('--seconds', type=int)
    parser.add_argument('--silence-ms', type=int, choices=[400, 800, 1300], default=1300)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    previous_audio,previous_wall=prior_totals()
    if args.seconds is None: args.seconds=min(REMAINING_SECONDS,max(0,int(480-previous_wall)))
    if args.seconds > 480-previous_wall or (previous_audio+args.seconds*2)*RATE > 1:
        parser.error('超出本次累计8分钟／1元范围；不会重试或延长。')
    preview = trial_config(args.bundle, 'placeholder-not-a-key', args.seconds, args.silence_ms)
    print(f"仅采集：{args.bundle}应用输出＋麦克风；请佩戴耳机。")
    print(f"发送：阿里云百炼北京dashscope.aliyuncs.com；Qwen3.0流式ASR；最多{args.seconds}秒。")
    print(f"两轨ASR估算≤{args.seconds*2*RATE:.4f}元；预算1元，不自动充值或重试。")
    print(f"累计已用{previous_wall:.1f}秒、ASR估算{previous_audio*RATE:.4f}元；本次上限{args.seconds}秒，累计原8分钟范围内。")
    print('音频只在有界内存；转写只在当前进程／终端，不默认保存；Ctrl-C停止。')
    if args.dry_run:
        print('只读预览：没有启动采集、权限请求或网络。')
        return
    if not NATIVE.exists():
        parser.error('缺少旧试验采集程序；日常使用请打开桌面在场App。')
    if not sys.stdin.isatty():
        parser.error('真实试验必须在本人交互终端确认，不能后台启动。')
    try: instance_lock = single_instance()
    except ValueError as e: parser.error(str(e))
    description = subprocess.run([str(NATIVE), '--describe', args.bundle], capture_output=True, text=True, check=True)
    info = json.loads(description.stdout)
    if not info.get('pids'):
        parser.error('选定会议应用未运行；未请求权限或连接网络。')
    print('已核对本次进程：', info['pids'])
    with warnings.catch_warnings():
        warnings.simplefilter('error', getpass.GetPassWarning)
        try:
            key = getpass.getpass('本人安全输入百炼北京API key（隐藏，不写文件）：')
        except getpass.GetPassWarning:
            parser.error('当前终端不能隐藏输入，已停止；不要在聊天或普通输入框发送key。')
    if input('密钥已在本机内存。准备好后输入 开始8分钟测试（否则退出）：').strip() != '开始8分钟测试':
        key = ''
        print('未开始；未连接百炼或申请音频权限。'); return
    config = trial_config(args.bundle, key, args.seconds, args.silence_ms)
    run_trial(config)


def run_trial(config,identity_session=None,command_stream=None,native_binary=NATIVE,prepared_child=None):
    from identity_session import IdentitySession
    identity_session=identity_session or IdentitySession(config['session'])
    view = TrialView(config['session'], config['bundle'])
    # Key goes only through an anonymous stdin pipe; no argument, environment or log.
    child = prepared_child or subprocess.Popen([str(native_binary), '--run-confirmed'], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                             start_new_session=True)
    child.stdin.write(json.dumps(config) + '\n'); child.stdin.flush(); child.stdin.close()
    health = HealthWriter(config['session'],config['bundle'],config['maxSeconds'],child.pid)
    gui=os.environ.get("MEETING_GUI")=="1"
    meter=FeeMeter()
    display = GUIEventPump() if gui else DisplayPump()
    config['key'] = ''  # Best effort only; no claim of guaranteed Python memory erasure.
    command_stop=threading.Event()
    def commands():
        for line in command_stream:
            if command_stop.is_set():return
            try:
                if len(line)>4_000_000:raise ValueError('identity_command_capacity')
                command=json.loads(line);answers=identity_session.command(command)
            except Exception as error:
                code=str(error);known={'person_consent_required','human_identity_scope_not_authorized','segment_changed_or_unavailable','single_speaker_sample_required','duplicate_audio_sample','need_two_people_three_independent_samples_each','samples_not_separable_keep_unknown','held_out_sample_failed_keep_unknown','unreliable_or_wrong_domain_sample'}
                answers=[{'type':'identity_ack','session':config['session'],'ok':False,'code':code if code in known else 'identity_command_invalid'}]
            for answer in answers:
                try:display.push(answer,json.dumps(answer,ensure_ascii=False))
                except ValueError:stop();return
    started = time.monotonic()
    def stop(signum=None, frame=None):
        if child.poll() is None:
            try: child.send_signal(signal.SIGINT)
            except ProcessLookupError: pass
    def deadline():
        stop()
        try: child.wait(timeout=3)
        except subprocess.TimeoutExpired: child.kill()
    trial_deadline=TrialDeadline(config['maxSeconds'],started)
    startup_timed_out=threading.Event()
    def startup_deadline():
        startup_timed_out.set();deadline()
    watchdog = threading.Timer(45, startup_deadline)
    watchdog.daemon = True
    watchdog.start()
    prior = signal.signal(signal.SIGINT, stop)
    if gui and command_stream is not None:threading.Thread(target=commands,daemon=True).start()
    try:
        for line in child.stdout:
            event = json.loads(line)
            health.observe(event)
            if event.get('type')=='started' and trial_deadline.recording_started(time.monotonic()):
                watchdog.cancel();watchdog=threading.Timer(max(0,trial_deadline.expires_at-time.monotonic()),deadline);watchdog.daemon=True;watchdog.start()
            if event.get('type')=='processing_started' and trial_deadline.processing_started(time.monotonic()):
                watchdog.cancel();watchdog=threading.Timer(max(0,trial_deadline.expires_at-time.monotonic()),deadline);watchdog.daemon=True;watchdog.start()
            identity_events=identity_session.observe(event) if event.get('type')=='segment' else []
            message = view.receive(event)
            if gui:
                meter.observe(event)
                if event.get('type') in {'health','usage_local','usage_provider','stopped'}:
                    display.push({'type':'meter'} if event.get('type') in {'stopped','usage_local'} or (event.get('type')=='usage_provider' and event.get('final')) else {'type':'health'},json.dumps(meter.snapshot(),ensure_ascii=False))
                if event.get('type') in {'segment','started','capture_stopped','processing_started','stopped','error','speaker_model','asr_replay','asr_reconnecting','asr_pending'}:
                    display.push(event,json.dumps(event,ensure_ascii=False))
                for answer in identity_events:display.push(answer,json.dumps(answer,ensure_ascii=False))
            elif message: display.push(event,message)
            if time.monotonic()>trial_deadline.expires_at:stop()
        child.wait(timeout=5)
        if trial_deadline.started_at is None and health.values['phase'] not in {'error','stopped'}:
            code='startup_timeout' if startup_timed_out.is_set() else 'startup_interrupted'
            health.observe({'type':'error','code':code})
            display.push({'type':'error'},json.dumps({'type':'error','code':code}) if gui else '未开始采音：'+code)
    except (ValueError, KeyError, OSError, subprocess.TimeoutExpired) as error:
        stop()
        try: child.wait(timeout=3)
        except subprocess.TimeoutExpired: child.kill(); child.wait()
        code='terminal_display_backpressure' if str(error)=='terminal_display_backpressure' else 'launcher_io_or_contract_failure'
        try: health.observe({'type':'error','code':code})
        except OSError: pass
        try: display.push({'type':'stopped'},json.dumps({'type':'error','code':code}) if gui else '【测试已停止】'+code+'；未自动重试。')
        except ValueError: pass
    finally:
        command_stop.set()
        if gui:
            try:display.push({'type':'identity_state'},json.dumps({'type':'identity_state','session':config['session'],'state':identity_session.snapshot()},ensure_ascii=False))
            except ValueError:pass
        watchdog.cancel()
        signal.signal(signal.SIGINT, prior)
        if child.poll() is None: stop(); child.wait(timeout=5)
        child.stdout.close()
        display.finish()
    if not view.stopped:
        view.bridge.stop(view.last_at)
        print('状态：连接已结束；当前上下文失效。' if gui else '连接已结束；可能有未稳定段，不宣称完整覆盖。',flush=True)
    if not gui:
        print('本机发送音频秒数：', view.usage, '；费用以供应商账单为准。')
        print('当前会话句末段数：', len(view.bridge.snapshot(view.last_at)['whole_meeting']))
    # No disk transcript; keep terminal visible for test review, never claim original archive exists.


if __name__ == '__main__':
    main()
