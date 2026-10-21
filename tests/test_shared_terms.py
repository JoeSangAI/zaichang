import json, unittest, tempfile
from pathlib import Path
from unittest.mock import patch
import shared_terms as terms
import gui_worker

class TermContractTests(unittest.TestCase):
    def test_word_lengths_and_controls(self):
        for word in ['人工智能','one two three four five six seven','a'*128,'词'*15]:self.assertTrue(terms.valid_term(word))
        for word in ['', ' 词', '词'*16,'a'*129,'one two three four five six seven eight','坏\n词','隐\u200b词']:
            self.assertFalse(terms.valid_term(word),repr(word))
    def test_explicit_selection_and_small_local_limit(self):
        self.assertEqual(terms.request_vocabulary({}),{})
        for request in [dict(asr_vocabulary={'专名':2}),dict(asr_terms_confirmed=True,asr_vocabulary={'词':True}),dict(asr_terms_confirmed=True,asr_vocabulary={'词':50}),dict(asr_terms_confirmed=True,asr_vocabulary={str(i):2 for i in range(301)})]:
            with self.assertRaises(ValueError):terms.request_vocabulary(request)
    def request(self):return dict(cloud_session_confirmed=True,cloud_budget_yuan=5,user_launch_confirmed=True,source_scope_confirmed=True,bundle='*system*',mic_enabled=True,key='fake-not-real')
    def test_cloud_passes_only_words_not_evidence(self):
        r=self.request();r.update(asr_terms_confirmed=True,asr_vocabulary={'示例品牌':2},term_sources=['never-upload-source'],person_id='never-upload-id')
        with patch('shared_terms.auto_vocabulary',return_value={'自动词':3,'示例品牌':4}):c=gui_worker.cloud_session_config(r)
        self.assertEqual(c['asrVocabulary'],{'示例品牌':2,'自动词':3});self.assertTrue(c['asrVocabularyConfirmed']);self.assertNotIn('term_sources',c);self.assertNotIn('person_id',c)
    def test_cloud_defaults_to_standing_terms_and_explicit_empty_opts_out(self):
        r=self.request()
        with patch('shared_terms.auto_vocabulary',return_value={'自动词':2}):
            c=gui_worker.cloud_session_config(r);self.assertEqual(c['asrVocabulary'],{'自动词':2});self.assertTrue(c['asrVocabularyConfirmed'])
            r.update(asr_terms_confirmed=True,asr_vocabulary={})
            self.assertEqual(gui_worker.cloud_session_config(r)['asrVocabulary'],{})
        with patch('shared_terms.auto_vocabulary',side_effect=OSError('owner missing')):
            self.assertNotIn('asrVocabulary',gui_worker.cloud_session_config(self.request()))
        r=self.request();r['asr_vocabulary']={'专名':2}
        with self.assertRaises(ValueError):gui_worker.cloud_session_config(r)
    def test_local_recording_never_has_cloud_terms(self):
        r=dict(local_only=True,local_recording_confirmed=True,user_launch_confirmed=True,source_scope_confirmed=True,bundle='*system*',mic_enabled=True,key='',asr_terms_confirmed=True,asr_vocabulary={'私有词':2})
        self.assertNotIn('asrVocabulary',gui_worker.local_recording_config(r))
    def test_rejection_event_reaches_ui_without_provider_payload(self):
        event=dict(type='asr_terms',state='rejected',ordinary_asr_retry=True,session='synthetic',track='mic',error_message='private provider details',asr_vocabulary={'private':2})
        out=gui_worker.asr_terms_status_event(event)
        self.assertEqual(out,dict(type='asr_terms',state='rejected',ordinary_asr_retry=True,session='synthetic',track='mic',audio_retained=True))
        for bad in [dict(event,track='../bad'),dict(event,session='bad\n'),dict(event,ordinary_asr_retry=False)]:self.assertIsNone(gui_worker.asr_terms_status_event(bad))
    def test_explicit_empty_overrides_saved_resume_words(self):
        import uuid
        with tempfile.TemporaryDirectory() as folder:
            home=Path(folder);cid=str(uuid.uuid4());directory=home/'Library/Application Support/ZaichangStandalone/SessionCache'/cid;directory.mkdir(parents=True)
            (directory/'meeting.json').write_text(json.dumps(dict(bundle='*system*',asr_model='qwen-audio-3.0-asr-flash-streaming',session='synthetic',cloud_session_authorized=True,asr_destination='dashscope.aliyuncs.com',asr_vocabulary={'old':2},asr_vocabulary_confirmed=True)))
            r=self.request();r['resume_cache_id']=cid
            with patch('gui_worker.Path.home',return_value=home),patch('gui_worker.transcript_tracks',return_value=['mic']),patch('shared_terms.auto_vocabulary',return_value={}):
                self.assertEqual(gui_worker.cloud_session_config(r)['asrVocabulary'],{'old':2})
                r.update(asr_terms_confirmed=True,asr_vocabulary={});c=gui_worker.cloud_session_config(r)
                self.assertEqual(c['asrVocabulary'],{});self.assertTrue(c['asrVocabularyConfirmed'])
                r['asr_vocabulary']={'new':2};self.assertEqual(gui_worker.cloud_session_config(r)['asrVocabulary'],{'new':2})
    def test_projection_reads_term_sections_only_without_write(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder).resolve();owner=root/'实体与术语.md'
            owner.write_text('# 实体与术语\n\n- **客观信息：** 不是词\n\n## 转写词表\n\n- 示例品牌｜示例｜示粒品牌\n- '+'过长'*9+'\n')
            module=root/'table.py'
            module.write_text('def compile_all():\n    return [dict(path=%r,layer="project",rows=[dict(term="示例品牌",aliases=["示例"],misheard=["示粒品牌"]),dict(term="过长过长过长过长过长过长过长过长过长",aliases=[],misheard=[])],error=None)]\n'%(str(owner)))
            before={str(p):p.read_bytes() for p in root.rglob('*') if p.is_file()}
            with patch('shared_terms.Path.home',return_value=root):result=terms.candidates(module)
            self.assertEqual({r['word'] for r in result['candidates']},{'示例品牌','示例'});self.assertTrue(result['requires_selection']);self.assertEqual(result['source_count'],1)
            self.assertNotIn('示粒品牌',json.dumps(result,ensure_ascii=False));self.assertNotIn('客观信息',json.dumps(result,ensure_ascii=False))
            self.assertEqual(before,{str(p):p.read_bytes() for p in root.rglob('*') if p.is_file()})
    def owners(self):
        row=lambda term,aliases=(),misheard=():dict(term=term,aliases=list(aliases),misheard=list(misheard))
        return [dict(path='/p/示例项目/实体与术语.md',layer='project',error=None,rows=[row('示例项目',(),('示例项木',)),row('功能甲',(),('功能加',)),row('共享站点')]),
                dict(path='/p/样例平台/实体与术语.md',layer='project',error=None,rows=[row('样例平台'),row('共享站点')]),
                dict(path='/p/通用.md',layer='general',error=None,rows=[row('Agent')])]
    def test_project_detection_needs_clear_lead_and_uses_title(self):
        owners=self.owners()
        self.assertEqual(terms.detect_project('示例项木这边功能加说共享站点，示例项目功能甲',owners),Path('/p/示例项目'))
        self.assertIsNone(terms.detect_project('共享站点',owners))
        self.assertIsNone(terms.detect_project('示例项目和样例平台的共享站点',owners))
        self.assertEqual(terms.detect_project('今天聊排期',owners,title='示例项目｜功能甲对接'),Path('/p/示例项目'))
    def test_vocabulary_orders_layers_and_never_sends_misheard(self):
        rows=[dict(term='Agent',aliases=[],misheard=[],layer='general'),dict(term='示例姓名',aliases=['姓名简称'],misheard=['同音错词'],layer='people'),
              dict(term='示例项目',aliases=[],misheard=['示例项木'],layer='project')]
        with patch('shared_terms.term_table') as table:
            table.return_value.for_project.return_value=rows
            self.assertEqual(terms.auto_vocabulary(Path('/p/示例项目')),{'示例项目':4,'示例姓名':3,'姓名简称':3,'Agent':2})
            with patch('shared_terms.VOCABULARY_LIMIT',2):self.assertEqual(terms.auto_vocabulary(None,limit=2),{'示例项目':4,'示例姓名':3})
            self.assertEqual(terms.term_guide(None),['示例项目；常被误识为示例项木','示例姓名（也称姓名简称）；常被误识为同音错词','Agent'])
            self.assertEqual(terms.merged_vocabulary({'手选':1},None,{'旧词':2,'示例项目':5}),{'手选':1,'示例项目':4,'示例姓名':3,'姓名简称':3,'Agent':2,'旧词':2})
    def test_cleanup_prompt_carries_guide_once_and_cache_ignores_it(self):
        import coarse_audio
        unit=dict(id='u1',source_id='mic',text='示例项木',start=0.0,end=1.0,manual=False,approximate_window=False,original_text_sha256='0'*64)
        prompt=coarse_audio._prompt('mic',[],[unit],[],0.0,['示例项目','只在热词里'],['示例项目；常被误识为示例项木'])
        self.assertIn('term_guide=["示例项目；常被误识为示例项木"]',prompt);self.assertIn('term_hints=["只在热词里"]',prompt)
        self.assertEqual(coarse_audio._unit_cache_identity(unit,['示例项目']),coarse_audio._unit_cache_identity(dict(unit),['示例项目']))
        with patch('shared_terms.detect_projects',side_effect=OSError('missing')):
            self.assertEqual(coarse_audio._term_guide(Path('/nonexistent'),[unit]),[])

    def test_cleanup_selects_all_threshold_projects_without_changing_ownership(self):
        import coarse_audio
        owners=self.owners()
        text='示例项目示例项目示例项目 样例平台 样例平台 样例平台'
        self.assertIsNone(terms.detect_project(text,owners))
        self.assertEqual(set(terms.detect_projects(text,owners)),{Path('/p/示例项目'),Path('/p/样例平台')})
        self.assertEqual(terms.detect_projects('示例项目',owners),[])
        self.assertEqual(terms.detect_projects('开会',owners,title='示例项目'),[Path('/p/示例项目')])
        with patch('shared_terms.compiled_owners',return_value=owners), \
             patch('shared_terms.term_guide',return_value=['合并词表']) as guide:
            self.assertEqual(coarse_audio._term_guide(Path('/nonexistent'),[dict(text=text)]),['合并词表'])
            self.assertEqual(set(guide.call_args.kwargs['project_dirs']),{Path('/p/示例项目'),Path('/p/样例平台')})

    def test_merged_guide_deduplicates_shared_terms_and_withholds_conflicts_before_limit(self):
        common=dict(term='Agent',aliases=[],misheard=[],layer='general')
        a=dict(term='产品甲',aliases=['甲产品'],misheard=['甲品','误词','产品乙'],layer='project')
        b=dict(term='产品乙',aliases=[],misheard=['误词'],layer='project')
        with patch('shared_terms.project_rows',side_effect=[[a,common],[b,common]]):
            guide=terms.term_guide(project_dirs=[Path('/a'),Path('/b')])
        self.assertEqual(guide.count('Agent'),1)
        self.assertIn('产品甲（也称甲产品）；常被误识为甲品',guide)
        self.assertIn('产品乙',guide)
        self.assertTrue(any('误词' in line and '不自动纠正' in line for line in guide))
        self.assertTrue(any('产品乙' in line and '不自动纠正' in line for line in guide))
        with patch('shared_terms.project_rows',side_effect=[[a,common],[b,common]]):
            limited=terms.term_guide(limit=1,project_dirs=[Path('/a'),Path('/b')])
        self.assertEqual(limited[0],'产品甲（也称甲产品）；常被误识为甲品')
        self.assertTrue(any('误词' in line and '不自动纠正' in line for line in limited))

    def test_single_project_guide_unchanged(self):
        with patch('shared_terms.term_table') as table:
            table.return_value.for_project.return_value=[dict(term='产品甲',aliases=[],misheard=['甲品'],layer='project')]
            self.assertEqual(terms.term_guide(Path('/a')),terms.term_guide(project_dirs=[Path('/a')]))
if __name__=='__main__':unittest.main()
