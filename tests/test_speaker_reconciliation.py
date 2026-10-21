import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from scripts.speaker_reconciliation import apply_plan, latest_events, select_prediction, sha

class SpeakerReconciliationTests(unittest.TestCase):
    def prediction(self,who='a',score=.7,margin=.25):
        return dict(winner=who,score=score,margin=margin,window=[0,2])
    def test_context_cannot_replace_conflicting_direct_voice(self):
        self.assertIsNone(select_prediction([self.prediction('b',.49,.12),self.prediction('a')],.6))
    def test_three_candidates_do_not_force_weak_voice(self):
        self.assertIsNone(select_prediction([self.prediction(score=.54)],1))
        self.assertIsNone(select_prediction([self.prediction(margin=.14)],1))
        self.assertIsNone(select_prediction([None],1))
    def test_disagreeing_independent_windows_remain_unresolved(self):
        self.assertIsNone(select_prediction([self.prediction('a'),self.prediction('b')],3))
    def test_existing_short_named_voice_is_preserved(self):
        self.assertIsNone(select_prediction([None,self.prediction('a')],.08,known=True))
    def test_match_requires_clear_confidence_and_margin(self):
        self.assertEqual(select_prediction([self.prediction()],2)['winner'],'a')
        self.assertIsNone(select_prediction([self.prediction(score=.6)],2,known=True))
    def test_latest_revision_and_replay_are_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);rows=[dict(type='segment',segment_id='a',revision=2,start=1,text='new'),dict(type='segment',segment_id='a',revision=1,start=1,text='old'),dict(type='segment',segment_id='b',revision=1,start=2,text='discard'),dict(type='asr_replay',discard_segment_ids=['b'])]
            (p/'mic-transcript.jsonl').write_text('\n'.join(json.dumps(r) for r in rows))
            events,hashes=latest_events(p)
            self.assertEqual([e['text'] for e in events],['new']);self.assertEqual(hashes['mic-transcript.jsonl'],sha(p/'mic-transcript.jsonl'))
    def plan(self,p):
        (p/'meeting.json').write_text(json.dumps(dict(session='s')))
        (p/'session-names.json').write_text('{}')
        (p/'mic-transcript.jsonl').write_text('original')
        return dict(cache_id=p.name,session='s',source_sha256={'mic-transcript.jsonl':sha(p/'mic-transcript.jsonl')},manifest_sha256={},provenance={'original_names_sha256':sha(p/'session-names.json')})
    def test_apply_keeps_originals_and_is_not_silent_overwrite(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);plan=self.plan(p);prior={f.name:f.read_bytes() for f in p.iterdir()}
            apply_plan(p,plan,p/'unused.json')
            self.assertEqual({n:(p/n).read_bytes() for n in prior},prior)
            self.assertEqual(json.loads((p/'speaker-reconciliation.json').read_text()),plan)
            with self.assertRaises(ValueError):apply_plan(p,plan,p/'unused.json')
    def test_changed_source_rejects_stale_plan(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);plan=self.plan(p);(p/'mic-transcript.jsonl').write_text('changed')
            with self.assertRaises(ValueError):apply_plan(p,plan,p/'unused.json')
            self.assertFalse((p/'speaker-reconciliation.json').exists())

if __name__=='__main__':unittest.main()
