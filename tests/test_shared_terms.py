import json, unittest, tempfile
from pathlib import Path
from unittest.mock import patch
import shared_terms as terms
import gui_worker

class TermContractTests(unittest.TestCase):
    def request(self):return dict(cloud_session_confirmed=True,cloud_budget_yuan=5,user_launch_confirmed=True,source_scope_confirmed=True,bundle='*system*',mic_enabled=True,key='fake-not-real')
    def test_only_detected_project_mishearings_are_correction_evidence(self):
        rows=[dict(term='晶视',aliases=['晶视屏'],misheard=['惊石'],layer='people'),
              dict(term='Agent',aliases=[],misheard=['智能体'],layer='general'),
              dict(term='惊石',aliases=[],misheard=['金石'],layer='project')]
        with patch('shared_terms.project_rows',return_value=rows):
            guide=terms.term_guide(project_dirs=[Path('/p/速卖通')])
            self.assertEqual(guide,['惊石；常被误识为金石','晶视（也称晶视屏）','Agent'])
            cleaned,_=terms.cleanup_terms(project_dirs=[Path('/p/速卖通')])
            self.assertEqual([r['misheard'] for r in cleaned],[['金石'],[],[]])
            self.assertFalse(any('常被误识为' in line for line in terms.term_guide()))

    def test_old_snapshot_is_ignored_without_writes(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            (root/'meeting-terms.json').write_text('{broken old snapshot')
            (root/'display-info.json').write_text(json.dumps(dict(title='速卖通')))
            before={p.name:p.read_bytes() for p in root.iterdir()}
            with patch('shared_terms.detect_projects',return_value=[Path('/p/速卖通')]) as detect:
                self.assertEqual(terms.meeting_projects(root,'金石'),[Path('/p/速卖通')])
                detect.assert_called_once_with('金石',title='速卖通')
            self.assertEqual(before,{p.name:p.read_bytes() for p in root.iterdir()})

    def owners(self):
        row=lambda term,aliases=(),misheard=():dict(term=term,aliases=list(aliases),misheard=list(misheard))
        return [dict(path='/p/闲鱼/实体与术语.md',layer='project',error=None,rows=[row('闲鱼',(),('咸鱼',)),row('九界',(),('九届',)),row('菜鸟驿站')]),
                dict(path='/p/vivo/实体与术语.md',layer='project',error=None,rows=[row('vivo'),row('菜鸟驿站')]),
                dict(path='/p/通用.md',layer='general',error=None,rows=[row('Agent')])]
    def test_project_detection_needs_clear_lead_and_uses_title(self):
        owners=self.owners()
        self.assertEqual(terms.detect_project('咸鱼这边九届说菜鸟驿站，闲鱼九界',owners),Path('/p/闲鱼'))
        self.assertIsNone(terms.detect_project('菜鸟驿站',owners))
        self.assertIsNone(terms.detect_project('闲鱼和vivo的菜鸟驿站',owners))
        self.assertEqual(terms.detect_project('今天聊排期',owners,title='闲鱼｜九界对接'),Path('/p/闲鱼'))

    def test_cleanup_selects_all_threshold_projects_without_changing_ownership(self):
        import coarse_audio
        owners=self.owners()
        text='闲鱼闲鱼闲鱼 vivo vivo vivo'
        self.assertIsNone(terms.detect_project(text,owners))
        self.assertEqual(set(terms.detect_projects(text,owners)),{Path('/p/闲鱼'),Path('/p/vivo')})
        self.assertEqual(terms.detect_projects('闲鱼',owners),[])
        self.assertEqual(terms.detect_projects('开会',owners,title='闲鱼'),[Path('/p/闲鱼')])
        with patch('shared_terms.compiled_owners',return_value=owners), \
             patch('shared_terms.term_guide',return_value=['合并词表']) as guide:
            self.assertEqual(coarse_audio._term_guide(Path('/nonexistent'),[dict(text=text)]),['合并词表'])
            self.assertEqual(set(guide.call_args.kwargs['project_dirs']),{Path('/p/闲鱼'),Path('/p/vivo')})

    def test_merged_guide_deduplicates_shared_terms_and_withholds_conflicts_before_limit(self):
        common=dict(term='Agent',aliases=[],misheard=[],layer='general')
        a=dict(term='Accio',aliases=['阿来'],misheard=['X5','误词','产品乙'],layer='project')
        b=dict(term='产品乙',aliases=[],misheard=['误词'],layer='project')
        with patch('shared_terms.project_rows',side_effect=[[a,common],[b,common]]):
            guide=terms.term_guide(project_dirs=[Path('/a'),Path('/b')])
        self.assertEqual(guide.count('Agent'),1)
        self.assertIn('Accio（也称阿来）；常被误识为X5',guide)
        self.assertIn('产品乙',guide)
        self.assertTrue(any('误词' in line and '不自动纠正' in line for line in guide))
        self.assertTrue(any('产品乙' in line and '不自动纠正' in line for line in guide))
        with patch('shared_terms.project_rows',side_effect=[[a,common],[b,common]]):
            limited=terms.term_guide(limit=1,project_dirs=[Path('/a'),Path('/b')])
        self.assertEqual(limited[0],'Accio（也称阿来）；常被误识为X5')
        self.assertTrue(any('误词' in line and '不自动纠正' in line for line in limited))

    def test_single_project_guide_unchanged(self):
        with patch('shared_terms.project_rows') as rows:
            rows.return_value=[dict(term='Accio',aliases=[],misheard=['X5'],layer='project')]
            self.assertEqual(terms.term_guide(Path('/a')),terms.term_guide(project_dirs=[Path('/a')]))
if __name__=='__main__':unittest.main()


class TitleContextTests(unittest.TestCase):
    def test_title_context_lists_heard_terms_projects_and_own_workspaces(self):
        row=lambda term,aliases=(),misheard=():dict(term=term,aliases=list(aliases),misheard=list(misheard))
        owners=[dict(path='/w/工作/通用.md',layer='general',error=None,rows=[row('我司',('工作',)),row('闲鱼'),row('Agent')]),
                dict(path='/w/工作/客户/闲鱼/实体与术语.md',layer='project',error=None,rows=[row('闲鱼',(),('咸鱼',)),row('九界',(),('九届',)),row('菜鸟驿站')])]
        with tempfile.TemporaryDirectory() as folder, \
             patch('shared_terms.meeting_text',return_value='咸鱼这边九届说咸鱼要投九界，咸鱼'), \
             patch('shared_terms.connectors',return_value={'project_roots':['/w/工作']}):
            value=terms.title_context(Path(folder),owners)
        self.assertEqual(value['projects'],['工作/客户/闲鱼'])
        self.assertEqual(value['domains'],['工作','我司'])
        self.assertEqual(value['terms'],['闲鱼；常被误识为咸鱼','九界；常被误识为九届'])
        self.assertEqual(value['unheard'],['菜鸟驿站','Agent'])
        # Only the leading project's own mishearings; shared tables are never swapped.
        self.assertEqual(value['spellings'],[['咸鱼','闲鱼'],['九届','九界']])

    def test_title_spellings_skip_ambiguous_misheard_words(self):
        row=lambda term,aliases=(),misheard=():dict(term=term,aliases=list(aliases),misheard=list(misheard))
        owners=[dict(path='/w/工作/通用.md',layer='general',error=None,rows=[row('晴川',(),('长城',))]),
                dict(path='/w/工作/客户/青禾/实体与术语.md',layer='project',error=None,
                     rows=[row('青禾露',(),('清禾露','禾露')),row('禾露花园',(),('禾露',)),row('金穗',(),('金岁',)),row('金岁')])]
        with tempfile.TemporaryDirectory() as folder, \
             patch('shared_terms.meeting_text',return_value='清禾露和禾露花园，金穗和金岁，长城'), \
             patch('shared_terms.connectors',return_value={'project_roots':['/w/工作']}):
            value=terms.title_context(Path(folder),owners)
        self.assertEqual(value['spellings'],[['清禾露','青禾露']])
