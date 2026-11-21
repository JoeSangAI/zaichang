import json, unittest, tempfile
from pathlib import Path
from unittest.mock import patch
import shared_terms as terms
import gui_worker

class TermContractTests(unittest.TestCase):
    def request(self):return dict(cloud_session_confirmed=True,cloud_budget_yuan=5,user_launch_confirmed=True,source_scope_confirmed=True,bundle='*system*',mic_enabled=True,key='fake-not-real')
    def test_only_detected_project_mishearings_are_correction_evidence(self):
        rows=[dict(term='云格',aliases=['云格屏'],misheard=['示例林舟'],layer='people'),
              dict(term='Agent',aliases=[],misheard=['智能体'],layer='general'),
              dict(term='示例林舟',aliases=[],misheard=['示例林洲'],layer='project')]
        with patch('shared_terms.project_rows',return_value=rows):
            guide=terms.term_guide(project_dirs=[Path('/p/纸灯工程')])
            self.assertEqual(guide,['示例林舟；常被误识为示例林洲','云格（也称云格屏）','Agent'])
            cleaned,_=terms.cleanup_terms(project_dirs=[Path('/p/纸灯工程')])
            self.assertEqual([r['misheard'] for r in cleaned],[['示例林洲'],[],[]])
            self.assertFalse(any('常被误识为' in line for line in terms.term_guide()))

    def test_old_snapshot_is_ignored_without_writes(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            (root/'meeting-terms.json').write_text('{broken old snapshot')
            (root/'display-info.json').write_text(json.dumps(dict(title='纸灯工程')))
            before={p.name:p.read_bytes() for p in root.iterdir()}
            with patch('shared_terms.detect_projects',return_value=[Path('/p/纸灯工程')]) as detect:
                self.assertEqual(terms.meeting_projects(root,'示例林洲'),[Path('/p/纸灯工程')])
                detect.assert_called_once_with('示例林洲',title='纸灯工程')
            self.assertEqual(before,{p.name:p.read_bytes() for p in root.iterdir()})

    def owners(self):
        row=lambda term,aliases=(),misheard=():dict(term=term,aliases=list(aliases),misheard=list(misheard))
        return [dict(path='/p/纸京/实体与术语.md',layer='project',error=None,rows=[row('纸京',(),('纸鲸',)),row('月篮墙',(),('月蓝墙',)),row('风筝柜')]),
                dict(path='/p/FableDeck/实体与术语.md',layer='project',error=None,rows=[row('FableDeck'),row('风筝柜')]),
                dict(path='/p/通用.md',layer='general',error=None,rows=[row('Agent')])]
    def test_project_detection_needs_clear_lead_and_uses_title(self):
        owners=self.owners()
        self.assertEqual(terms.detect_project('纸鲸试展讲月蓝墙和风筝柜，纸京负责月篮墙',owners),Path('/p/纸京'))
        self.assertIsNone(terms.detect_project('风筝柜',owners))
        self.assertIsNone(terms.detect_project('纸京和FableDeck的风筝柜',owners))
        self.assertEqual(terms.detect_project('今天聊排期',owners,title='纸京｜月篮墙对接'),Path('/p/纸京'))

    def test_cleanup_selects_all_threshold_projects_without_changing_ownership(self):
        import coarse_audio
        owners=self.owners()
        text='纸京纸京纸京 FableDeck FableDeck FableDeck'
        self.assertIsNone(terms.detect_project(text,owners))
        self.assertEqual(set(terms.detect_projects(text,owners)),{Path('/p/纸京'),Path('/p/FableDeck')})
        self.assertEqual(terms.detect_projects('纸京',owners),[])
        self.assertEqual(terms.detect_projects('开会',owners,title='纸京'),[Path('/p/纸京')])
        with patch('shared_terms.compiled_owners',return_value=owners), \
             patch('shared_terms.term_guide',return_value=['合并词表']) as guide:
            self.assertEqual(coarse_audio._term_guide(Path('/nonexistent'),[dict(text=text)]),['合并词表'])
            self.assertEqual(set(guide.call_args.kwargs['project_dirs']),{Path('/p/纸京'),Path('/p/FableDeck')})

    def test_merged_guide_deduplicates_shared_terms_and_withholds_conflicts_before_limit(self):
        common=dict(term='Agent',aliases=[],misheard=[],layer='general')
        a=dict(term='FableBox',aliases=['纸方匣'],misheard=['FBox','误词','产品乙'],layer='project')
        b=dict(term='产品乙',aliases=[],misheard=['误词'],layer='project')
        with patch('shared_terms.project_rows',side_effect=[[a,common],[b,common]]):
            guide=terms.term_guide(project_dirs=[Path('/a'),Path('/b')])
        self.assertEqual(guide.count('Agent'),1)
        self.assertIn('FableBox（也称纸方匣）；常被误识为FBox',guide)
        self.assertIn('产品乙',guide)
        self.assertTrue(any('误词' in line and '不自动纠正' in line for line in guide))
        self.assertTrue(any('产品乙' in line and '不自动纠正' in line for line in guide))
        with patch('shared_terms.project_rows',side_effect=[[a,common],[b,common]]):
            limited=terms.term_guide(limit=1,project_dirs=[Path('/a'),Path('/b')])
        self.assertEqual(limited[0],'FableBox（也称纸方匣）；常被误识为FBox')
        self.assertTrue(any('误词' in line and '不自动纠正' in line for line in limited))

    def test_single_project_guide_unchanged(self):
        with patch('shared_terms.project_rows') as rows:
            rows.return_value=[dict(term='FableBox',aliases=[],misheard=['FBox'],layer='project')]
            self.assertEqual(terms.term_guide(Path('/a')),terms.term_guide(project_dirs=[Path('/a')]))
if __name__=='__main__':unittest.main()


class TitleContextTests(unittest.TestCase):
    def test_title_context_lists_heard_terms_projects_and_own_workspaces(self):
        row=lambda term,aliases=(),misheard=():dict(term=term,aliases=list(aliases),misheard=list(misheard))
        owners=[dict(path='/w/项目册/通用.md',layer='general',error=None,rows=[row('示例工作室',('项目册',)),row('纸京'),row('Agent')]),
                dict(path='/w/项目册/纸京/实体与术语.md',layer='project',error=None,rows=[row('纸京',(),('纸鲸',)),row('月篮墙',(),('月蓝墙',)),row('风筝柜')])]
        with tempfile.TemporaryDirectory() as folder, \
             patch('shared_terms.meeting_text',return_value='纸鲸展台试装月蓝墙，纸鲸要给月篮墙打光，纸鲸'), \
             patch('shared_terms.connectors',return_value={'project_roots':['/w/项目册']}):
            value=terms.title_context(Path(folder),owners)
        self.assertEqual(value['projects'],['项目册/纸京'])
        self.assertEqual(value['domains'],['项目册','示例工作室'])
        self.assertEqual(value['terms'],['纸京；常被误识为纸鲸','月篮墙；常被误识为月蓝墙'])
        self.assertEqual(value['unheard'],['风筝柜','Agent'])
        # Only the leading project's own mishearings; shared tables are never swapped.
        self.assertEqual(value['spellings'],[['纸鲸','纸京'],['月蓝墙','月篮墙']])

    def test_title_spellings_skip_ambiguous_misheard_words(self):
        row=lambda term,aliases=(),misheard=():dict(term=term,aliases=list(aliases),misheard=list(misheard))
        owners=[dict(path='/w/项目册/通用.md',layer='general',error=None,rows=[row('纸湾',(),('纸弯',))]),
                dict(path='/w/项目册/云芽/实体与术语.md',layer='project',error=None,
                     rows=[row('云芽盒',(),('云牙盒','芽盒')),row('芽盒展厅',(),('芽盒',)),row('风籽',(),('风子',)),row('风子')])]
        with tempfile.TemporaryDirectory() as folder, \
             patch('shared_terms.meeting_text',return_value='云牙盒和芽盒展厅，风籽和风子，纸弯'), \
             patch('shared_terms.connectors',return_value={'project_roots':['/w/项目册']}):
            value=terms.title_context(Path(folder),owners)
        self.assertEqual(value['spellings'],[['云牙盒','云芽盒']])
