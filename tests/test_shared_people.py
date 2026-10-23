import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import shared_people as subject


class SharedPeopleChecks(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name).resolve();self.focus=self.base/'ExampleProjects'
        self.master=self.focus/'公司资料/内部人员与长期协作方.md'
        self.master.parent.mkdir(parents=True)
        self.master.write_text('## 示例组织内部人员\n- **合成甲（Alpha / 共用别名）：** 示例组织测试角色。\n- **合成乙（共用别名）：** 示例组织另一个角色。\n',encoding='utf-8')

        self.loader=Path(__file__).parent/'fixtures/people_loader.py'
        self.loader=self.loader.resolve()
        self.config=self.base/'connectors.json'
        self.config.write_text(json.dumps({'schema':1,'people_loader':str(self.loader),'project_roots':[str(self.focus)]}))
        env=patch.dict(os.environ,{'ZAICHANG_DATA_ROOT':str(self.base)})
        env.start();self.addCleanup(env.stop)

    def search(self, query):
        return subject.search_people(query, focus_root=self.focus)

    def test_matches_authoritative_ids_and_retains_ambiguity(self):
        source,_=subject.load_authoritative_people(focus_root=self.focus)
        expected={p['id'] for p in source if '共用别名' in p['aliases']}
        result=self.search('共用别名')
        self.assertEqual({c['reference']['id'] for c in result['candidates']},expected)
        self.assertEqual(len(expected),2)
        self.assertTrue(result['requires_confirmation'])
        self.assertEqual(result['candidates'][0]['organization'],'示例组织')
        self.assertEqual(result['candidates'][0]['reference']['evidence'],[str(self.master)])

    def test_alias_casefold_substring_and_no_fuzzy_identity(self):
        self.assertEqual(len(self.search('aLPHa')['candidates']),1)
        self.assertEqual(len(self.search('合成')['candidates']),2)
        self.assertEqual(self.search('Alphz')['candidates'],[])
        self.assertEqual(self.search('示例组织')['candidates'],[])

    def test_invalid_queries(self):
        for query in ['', '  ', '\nAlpha', 'Alpha\x00', '\u202eAlpha', 'a'*81, None]:
            with self.subTest(query=query),self.assertRaises(ValueError):self.search(query)

    def test_missing_or_redirected_code_and_master_fail_closed(self):
        with self.assertRaises((ValueError,OSError)):
            subject.search_people('Alpha',module_path=self.base/'missing.py',focus_root=self.focus)
        alias=self.base/'redirect.py';alias.symlink_to(self.loader)
        with self.assertRaises(ValueError):subject.search_people('Alpha',module_path=alias,focus_root=self.focus)
        self.master.unlink()
        with self.assertRaises((ValueError,OSError)):self.search('Alpha')

    def test_source_size_count_and_noncanonical_paths(self):
        with patch.object(subject,'MAX_FILE_BYTES',10),self.assertRaises(ValueError):self.search('Alpha')
        with patch.object(subject,'MAX_SOURCES',0),self.assertRaises(ValueError):
            customer=self.focus/'客户/合成';customer.mkdir(parents=True)
            (customer/'实体与术语.md').write_text('## 人员\n- **测试：** 联系人。')
            self.search('Alpha')
        with self.assertRaises(ValueError):subject.canonical_path(str(self.focus)+'/../ExampleProjects',directory=True)

    def test_invalid_returned_id_evidence_and_count_are_not_bound(self):
        source,focus=subject.load_authoritative_people(focus_root=self.focus)
        for field,value in [('id','person:guessed'),('evidence',['/etc/passwd']),('name','Alpha\x00')]:
            person=dict(source[0]);person[field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):subject.validated_person(person,focus)
        with patch.object(subject,'MAX_PEOPLE',0),self.assertRaises(ValueError):self.search('Alpha')
        with patch.object(subject,'load_authoritative_people',return_value=([source[0],source[0]],focus)),self.assertRaises(ValueError):self.search('Alpha')

    def test_results_are_bounded_without_merging_names(self):
        self.master.write_text('## 示例组织内部人员\n'+''.join(f'- **合成{i}：** 示例组织测试角色。\n' for i in range(25)))
        result=self.search('合成')
        self.assertEqual(len(result['candidates']),20);self.assertTrue(result['truncated'])

    def test_evidence_above_context_limit_keeps_person_with_eight_verified_paths(self):
        people,focus=subject.load_authoritative_people(focus_root=self.focus)
        evidence=[]
        for number in range(12):
            file=self.focus/f'synthetic-evidence-{number}.md';file.write_text('synthetic')
            evidence.append(str(file))
        person=dict(people[0],evidence=evidence)
        with patch.object(subject,'load_authoritative_people',return_value=([person],focus)):
            result=self.search(person['name'])
        self.assertEqual(len(result['candidates']),1)
        self.assertEqual(result['candidates'][0]['reference']['evidence'],evidence[:8])
        with self.assertRaises(ValueError):subject.validated_person(dict(person,evidence=['/'+('a'*2048)]),focus)

    def test_no_source_write_or_bytecode_on_import(self):
        before=self.master.read_bytes();before_files=set(self.base.rglob('*'))
        self.search('Alpha')
        self.assertEqual(before,self.master.read_bytes());self.assertEqual(before_files,set(self.base.rglob('*')))
        self.assertTrue(sys.dont_write_bytecode)

    def test_cli_invalid_query_is_structured_and_bounded(self):
        result=subprocess.run([sys.executable,'-B',subject.__file__,'--query','bad\nquery'],capture_output=True,text=True,timeout=4)
        self.assertEqual(result.returncode,1)
        response=json.loads(result.stdout)
        self.assertEqual(response['status'],'unavailable');self.assertEqual(response['candidates'],[])
        self.assertNotIn('Traceback',result.stderr)


if __name__=='__main__':unittest.main()
