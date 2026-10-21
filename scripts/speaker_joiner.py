"""Source/epoch-aware conservative timestamp join. No acoustic model or names invented."""
from dataclasses import dataclass
import math
@dataclass(frozen=True)
class Clock:
    source_id:str
    epoch:str
    origin:float
    sample_rate:int=16000
    def time(self,sample):
        if sample<0 or self.sample_rate<=0:raise ValueError('invalid sample clock')
        return self.origin+sample/self.sample_rate
@dataclass(frozen=True)
class Span:
    start:float
    end:float
    clusters:tuple
    quality_ok:bool=True
class SpeakerJoiner:
    def __init__(self):self.timeline={};self.manual={}
    def revise(self,clock,revision,spans):
        key=(clock.source_id,clock.epoch)
        if revision<=self.timeline.get(key,(-1,[]))[0]:return False
        normalized=[]
        for span in spans:
            if not all(math.isfinite(x) for x in (span.start,span.end)) or span.start<0 or span.end<=span.start:
                raise ValueError('invalid span')
            normalized.append(Span(clock.time(span.start),clock.time(span.end),tuple(span.clusters),span.quality_ok))
        self.timeline[key]=(revision,normalized);return True
    def confirm_segment(self,segment_id,person_id):
        if person_id:self.manual[segment_id]=person_id
        else:self.manual.pop(segment_id,None)
    def join(self,segment):
        if segment['segment_id'] in self.manual:
            return {'basis':'human_segment','person_id':self.manual[segment['segment_id']]}
        if not segment.get('end_time_known') or segment['end']<=segment['start']:
            return {'basis':'unknown','reason':'no_reliable_span'}
        entry=self.timeline.get((segment['source_id'],segment['epoch']))
        if not entry:return {'basis':'unknown','reason':'model_or_epoch_unavailable'}
        lo,hi=segment['start'],segment['end'];cuts={lo,hi};relevant=[]
        for span in entry[1]:
            if span.end>lo and span.start<hi:
                relevant.append(span);cuts.update((max(lo,span.start),min(hi,span.end)))
        points=sorted(cuts);clusters=set()
        for a,b in zip(points,points[1:]):
            active=[s for s in relevant if s.start<=a and s.end>=b]
            if not active or any(not s.quality_ok for s in active):return {'basis':'unknown','reason':'coverage_or_quality'}
            slots={c for s in active for c in s.clusters}
            if not slots:return {'basis':'unknown','reason':'no_speaker_evidence'}
            if len(slots)>1:return {'basis':'multiple','reason':'overlap','cluster_ids':sorted(slots)}
            clusters.update(slots)
        if len(clusters)!=1:return {'basis':'multiple','reason':'speaker_change','cluster_ids':sorted(clusters)}
        return {'basis':'anonymous_cluster','cluster_id':next(iter(clusters)),'epoch':segment['epoch'],'revision':entry[0]}
