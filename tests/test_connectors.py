"""Exercise optional integrations with user-owned temporary source files."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import runtime_config
import shared_terms
import shared_people
from assistant_runtime import AssistantRuntime


class ConnectorTests(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup)
        self.root=Path(tmp.name).resolve()
        env=patch.dict(os.environ, {'ZAICHANG_DATA_ROOT':str(self.root)})
        env.start();self.addCleanup(env.stop)
        self.path=self.root/'connectors.json'

    def write(self, value):
        self.path.write_text(json.dumps(value,ensure_ascii=False))

    def fixture(self):
        project=self.root/'projects'/'demo';project.mkdir(parents=True)
        (project/'实体与术语.md').write_text('正文里不能读取人名。\n## 转写词表\n- 项目甲｜甲产品｜误写甲\n## 其他\n- 不读取\n')
        general=self.root/'general.md';general.write_text('## 转写词表\n- 通用词｜通用别名｜通用误写\n')
        people=self.root/'people.md';people.write_text('## 转写词表\n- 张三｜小张｜误写姓名\n')
        master=self.root/'projects/公司资料/内部人员与长期协作方.md';master.parent.mkdir()
        master.write_text('## 人员\n- **合成甲（Alpha / 共用别名）：** 示例角色。\n')
        return {'schema':1,'project_roots':[str(project.parent)],'general_terms':str(general),
                'people_terms':str(people),'people_loader':str(Path('tests/fixtures/people_loader.py').resolve()),
                'archive':{'url':'http://127.0.0.1:18766','app_id':'example-archive'},'context_hint':'资料以项目上下文为准。'},project

    def test_missing_malformed_and_unsupported_config_are_inert(self):
        for raw in (None,'{bad','[]','{"schema":2}','{"schema":true}'):
            if raw is not None:self.path.write_text(raw)
            self.assertEqual(runtime_config.connectors(),{})
            self.assertEqual(shared_terms.compiled_owners(),[])
            self.assertEqual(shared_people.search_people('张三')['candidates'],[])
            self.assertEqual(runtime_config.context_guidance(),'')

    def test_all_connectors_work_in_both_editions(self):
        config,project=self.fixture();self.write(config)
        for edition in ('joe','standalone'):
            with self.subTest(edition=edition),patch.dict(os.environ,{'ZAICHANG_EDITION':edition}):
                rows,_=shared_terms.cleanup_terms(project)
                self.assertEqual([r['layer'] for r in rows],['project','people','general'])
                self.assertEqual([r['misheard'] for r in rows],[['误写甲'],[],[]])
                self.assertEqual(shared_terms.detect_project('项目甲项目甲项目甲'),project)
                self.assertEqual(len(shared_people.search_people('Alpha')['candidates']),1)
                self.assertEqual(runtime_config.connectors()['archive'],config['archive'])
                for kind in ('chat',):
                    prompt=AssistantRuntime._listener_prompt()
                    self.assertIn(config['context_hint'],prompt)
                    self.assertIn(str(project.parent),prompt)
                self.assertNotIn(config['context_hint'],AssistantRuntime._overview_prompt(None, {}))

    def test_removing_configuration_invalidates_cached_terms(self):
        config,project=self.fixture();self.write(config)
        self.assertTrue(shared_terms.compiled_owners())
        self.path.unlink()
        self.assertEqual(shared_terms.compiled_owners(),[])
        self.assertEqual(shared_terms.project_rows(project),[])

    def test_nearest_project_only_and_no_outside_owner(self):
        config,project=self.fixture();self.write(config)
        child=project/'nested';child.mkdir()
        (child/'实体与术语.md').write_text('## 转写词表\n- 子项目｜｜子误写\n')
        rows=shared_terms.project_rows(child)
        self.assertEqual([r['term'] for r in rows if r['layer']=='project'],['子项目'])
        self.assertFalse(any(r['layer']=='project' for r in shared_terms.project_rows(self.root)))

    def test_terms_duplicate_merge_and_malformed_owner(self):
        config,project=self.fixture();self.write(config)
        owner=project/'实体与术语.md'
        owner.write_text('## 转写词表\n- 项目甲｜甲一\n- 项目甲｜甲二\n')
        self.assertEqual(shared_terms.project_rows(project)[0]['aliases'],['甲一','甲二'])
        owner.write_text('## 转写词表\n- 一｜二｜三｜四\n')
        shared_terms.compiled_owners(max_age=-1)
        self.assertFalse(any(r['layer']=='project' for r in shared_terms.project_rows(project)))

    def test_invalid_optional_values_do_not_enable_integrations(self):
        self.write({'schema':1,'project_roots':['relative','/tmp/../wrong',9], 'people_loader':False,
                    'context_hint':[], 'archive':{'url':'file:///tmp/service','app_id':'sample'}})
        config=runtime_config.connectors()
        self.assertEqual(config,{'schema':1,'project_roots':[]})

    def test_optional_bridge_parameters_are_paths_only(self):
        self.write({'schema':1,'agent_bridge':{'tunnel_id':'example-tunnel','key_file':str(self.root/'not-read.env'),'mcp_server':str(self.root/'server.py')}})
        self.assertEqual(runtime_config.connectors()['agent_bridge']['tunnel_id'],'example-tunnel')
        self.assertFalse((self.root/'not-read.env').exists())

    def test_private_template_contract_with_paths_replaced(self):
        config,project=self.fixture()
        template=Path('docs/history/20261022-术语止损与旁听同事/tasks/joe-connectors.json')
        if template.exists():
            original=json.loads(template.read_text())
            self.assertEqual(set(original)-{'agent_bridge'},set(config))
            original.pop('agent_bridge',None)
            original.update(config)
            config=original
        self.write(config)
        self.assertEqual(shared_terms.term_guide(project),['项目甲（也称甲产品）；常被误识为误写甲','张三（也称小张）','通用词（也称通用别名）'])
        self.assertEqual(shared_people.search_people('Alpha')['candidates'][0]['reference']['name'],'合成甲')


if __name__=='__main__':unittest.main()
