"""Qwen 3.0 CNY estimates, per-session estimates. No account access or billing claim."""
from decimal import Decimal
import math
import json
from pathlib import Path
from audio_sources import is_transcript_track
RATE=Decimal('0.00033')

class FeeMeter:
    def __init__(self):
        self.tasks={};self.current={};self.elapsed=0.0
    @staticmethod
    def seconds(value):
        if isinstance(value,bool) or not isinstance(value,(int,float)) or not math.isfinite(value) or value<0:
            raise ValueError('invalid audio seconds')
        return Decimal(str(value))
    def bind(self,track,task):
        if not is_transcript_track(track) or not isinstance(task,str) or not task:
            raise ValueError('invalid audio task')
        old=self.current.get(track)
        fallback=track+':local'
        if task in self.tasks and self.tasks[task]['track']!=track: raise ValueError('task track mismatch')
        if task not in self.tasks:
            self.tasks[task]={'track':track,'local':Decimal(0),'provider':None,'final':False}
            if old==fallback and old in self.tasks:
                self.tasks[task]['local']=self.tasks.pop(old)['local']
        self.current[track]=task
        return self.tasks[task]
    def observe(self,event):
        kind=event.get('type')
        if kind=='health':
            self.elapsed=max(self.elapsed,float(self.seconds(event['elapsed_seconds'])))
            for track, info in event.items():
                if not is_transcript_track(track) or not isinstance(info,dict):continue
                state=self.bind(track,info.get('task_id') or self.current.get(track) or track+':local')
                state['local']=max(state['local'],self.seconds(info.get('task_attempted_audio_seconds',info.get('sent_audio_seconds',0))))
        elif kind=='usage_local':
            track=event['track'];state=self.bind(track,event.get('task_id') or self.current.get(track) or track+':local')
            state['local']=max(state['local'],self.seconds(event['sent_audio_seconds']))
        elif kind=='usage_provider':
            state=self.bind(event['track'],event['task_id'])
            duration=self.seconds(event['duration'])
            state['provider']=max(state['provider'] or Decimal(0),duration)
            state['final']=state['final'] or event.get('final') is True
        elif kind=='stopped':
            self.elapsed=max(self.elapsed,float(self.seconds(event.get('recording_elapsed_seconds',event['received_at']))))
    def snapshot(self):
        measured=Decimal(0);provider_complete=bool(self.tasks)
        for state in self.tasks.values():
            # Final service usage calibrates that task; otherwise estimate conservatively from sent audio.
            final=state['final'] and state['provider'] is not None
            measured+=state['provider'] if final else max(state['local'],state['provider'] or Decimal(0))
            provider_complete=provider_complete and final
        return {'type':'meter','elapsed_seconds':self.elapsed,'estimated_yuan':str(measured*RATE),
                'input_audio_seconds':str(measured),'rate_yuan_per_audio_second':str(RATE),
                'basis':'service_usage' if provider_complete else 'sent_audio_estimate',
                'supplier_bill_verified':False,'balance_status':'not_connected'}


def recorded_session_fee(usage):
    """Only reuse an amount whose persisted scope covers the entire session."""
    if not isinstance(usage, dict):
        return None
    def amount(value):
        if isinstance(value, bool) or not isinstance(value, (str, int, float)):
            return None
        try:
            result = Decimal(str(value))
        except Exception:
            return None
        return result if result.is_finite() and result >= 0 else None
    if usage.get('schema') == 2:
        return amount(usage.get('cumulative_estimated_yuan'))
    meter = usage.get('meter')
    if not isinstance(meter, dict):
        return None
    if 'cumulative_input_audio_seconds' in usage:
        total = amount(usage.get('cumulative_input_audio_seconds'))
        recent = amount(meter.get('input_audio_seconds'))
        if total is None or recent is None or abs(total - recent) > Decimal('0.000001'):
            return None
    return amount(meter.get('estimated_yuan'))


def session_usage_snapshot(snapshot, previous_input, previous_fee, session):
    fee = None if previous_fee is None else str(previous_fee + Decimal(snapshot['estimated_yuan']))
    cumulative_input = (None if previous_input is None else
                        previous_input+float(snapshot['input_audio_seconds']))
    return dict(schema=2, session=session,
                cumulative_input_audio_seconds=cumulative_input,
                cumulative_estimated_yuan=fee, meter=snapshot)


def coarse_reserved_yuan(cache_directory, session):
    """Read the coarse-AI spend estimate; return None when its ledger is unknown.

    A missing ledger means this session has not reserved any coarse-AI spend.
    Reservations are cumulative and deliberately remain charged after failure or
    cancellation, since the provider may already have received the request.
    """
    path = Path(cache_directory) / 'coarse-audio-progress.json'
    if not path.exists():
        return Decimal(0)
    if path.is_symlink() or not path.is_file():
        return None
    try:
        ledger = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(ledger, dict) or ledger.get('schema') != 1 or ledger.get('session') != session:
        return None
    value = ledger.get('reserved_yuan')
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        return None
    try:
        amount = Decimal(str(value))
    except Exception:
        return None
    if not amount.is_finite() or amount < 0:
        return None
    return amount


def cumulative_asr_fee(usage):
    """Return a cumulative ASR estimate, or None when persisted history is unknown."""
    if usage is None:
        return None
    if not isinstance(usage, dict):
        return None
    fee = recorded_session_fee(usage)
    if fee is not None:
        return fee
    # Older usage records may not persist a complete fee. Rebuild the estimate
    # from their cumulative input duration instead of treating it as free.
    seconds = usage.get('cumulative_input_audio_seconds')
    if seconds is None:
        meter = usage.get('meter')
        if isinstance(meter, dict):
            seconds = meter.get('input_audio_seconds')
    if isinstance(seconds, bool) or not isinstance(seconds, (str, int, float)):
        return None
    try:
        total = Decimal(str(seconds))
    except Exception:
        return None
    if not total.is_finite() or total < 0:
        return None
    return total * RATE


def combined_session_fee(usage, cache_directory, session):
    """ASR plus coarse-AI estimate; None means at least one ledger is unknown."""
    asr = cumulative_asr_fee(usage)
    coarse = coarse_reserved_yuan(cache_directory, session)
    return None if asr is None or coarse is None else asr + coarse

