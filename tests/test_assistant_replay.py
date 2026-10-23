import asyncio
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
from scripts import replay_meeting_assistant as replay


class ReplayTests(unittest.TestCase):
    def test_offline_real_meeting_drives_production_conversation(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            if not (replay.DATA_ROOT / "AgentContext/context.sqlite").is_file():
                self.skipTest("authorized local meeting unavailable")
            with patch.object(replay, 'native_projection', side_effect=unittest.SkipTest('meeting projection unavailable')):
                context = replay.load_context("394FBA81-C2E0-4258-B1B3-B2AE038E2017", out)
            result = asyncio.run(replay.replay(context, out, offline=True))
            self.assertEqual(result['errors'], [])
            self.assertEqual(result['final_revision'], len(context['segments']))
            self.assertGreater(len(result['says']), 0)
            self.assertEqual(len({r['thread_id'] for r in result['turns']}), 1)
            self.assertTrue(result['completed'])
            self.assertEqual(len(result['final_state']['messages']), len(result['says']))

    def test_projection_reader_uses_final_quality_flags_and_does_not_write(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);dbpath=root/'context.sqlite'
            with sqlite3.connect(dbpath) as db:
                db.executescript('CREATE TABLE meetings(session,metadata); CREATE TABLE segments(session,parent,revision,start,end,payload,deleted);')
                db.execute('INSERT INTO meetings VALUES(?,?)',('s',json.dumps({'cache_id':'cache','title':'合成测试','recording_elapsed_seconds':20})))
                turns=[{'id':'a','text':'本场预算需要确认','final':True,'speaker':'Bob','uncertain':False,'start':0,'end':10,
                        'parts':[{'id':'a1','final':True,'quality_flags':['review_required'],'text':'本场预算需要确认'}]},
                       {'id':'b','text':'未定稿','final':False,'start':10,'end':20}]
                db.execute('INSERT INTO segments VALUES(?,?,?,?,?,?,?)',('s','parent',2,0,20,json.dumps(turns),0))
            before=dbpath.read_bytes()
            with patch.object(replay,'native_projection',side_effect=AssertionError('unexpected fallback')):
                context=replay.projected_context('cache',root,database=dbpath,cache_root=root/'cache')
            self.assertEqual(len(context['segments']),1)
            self.assertEqual(context['segments'][0]['quality_flags'],['review_required'])
            self.assertEqual(context['segments'][0]['revision'],2)
            self.assertEqual(dbpath.read_bytes(),before)

    def test_empty_projection_falls_back_to_native_rules(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            with patch.object(replay,'native_projection',return_value={'source': 'projection-fixture', 'segments': [{'id': 'readme', 'text': Path('README.md').read_text(), 'final': True}]}) as fallback:
                result=replay.projected_context('cache',root,database=root/'missing.sqlite',cache_root=root/'cache')
            fallback.assert_called_once_with(root/'cache'/'cache',root)
            self.assertEqual(result['source'],'projection-fixture')
