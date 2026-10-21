import unittest
from scripts.speaker_joiner import Clock,Span,SpeakerJoiner
class JoinerTests(unittest.TestCase):
    def setUp(self):self.j=SpeakerJoiner();self.c=Clock('remote','epoch1',10)
    def segment(self,start=10,end=12,epoch='epoch1'):return dict(segment_id='s',source_id='remote',epoch=epoch,start=start,end=end,end_time_known=True)
    def test_clock_and_same_speaker(self):
        self.j.revise(self.c,1,[Span(0,32000,('slot1',))])
        self.assertEqual(self.j.join(self.segment())['cluster_id'],'slot1')
    def test_change_is_multiple_without_majority(self):
        self.j.revise(self.c,1,[Span(0,31900,('a',)),Span(31900,32000,('b',))])
        self.assertEqual(self.j.join(self.segment())['basis'],'multiple')
    def test_overlap_gap_and_missing_word_span(self):
        for spans in [[Span(0,32000,('a','b'))],[Span(0,30000,('a',))]]:
            j=SpeakerJoiner();j.revise(self.c,1,spans);self.assertNotEqual(j.join(self.segment())['basis'],'anonymous_cluster')
        s=self.segment();s['end_time_known']=False;self.assertEqual(self.j.join(s)['basis'],'unknown')
    def test_revision_epoch_and_manual_override(self):
        self.assertTrue(self.j.revise(self.c,2,[Span(0,32000,('a',))]));self.assertFalse(self.j.revise(self.c,1,[Span(0,32000,('b',))]))
        self.assertEqual(self.j.join(self.segment(epoch='new'))['basis'],'unknown')
        self.j.confirm_segment('s','person');self.j.revise(self.c,3,[Span(0,32000,('c',))]);self.assertEqual(self.j.join(self.segment())['person_id'],'person')
        self.j.confirm_segment('s',None);self.assertEqual(self.j.join(self.segment())['cluster_id'],'c')
