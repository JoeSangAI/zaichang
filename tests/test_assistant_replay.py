import asyncio
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
from scripts import replay_meeting_assistant as replay


def replay_fixture(root: Path) -> dict:
    database = root / "context.sqlite"
    sentences = [
        "纸鸮展台的入口先留空，方便观众排队。",
        "把折纸模型放在蓝色桌子上。",
        "导览牌移到投影墙旁边，留出通道。",
        "走完展线后再确定灯光角度。",
    ]
    metadata = {"cache_id": "fixture-cache", "title": "纸鸮展台｜布展演练",
                "absolute_clock": {"anchors": [{"unix_time": 1927938600}]}}
    with sqlite3.connect(database) as db:
        db.executescript("CREATE TABLE meetings(session,metadata); "
                         "CREATE TABLE segments(session,parent,revision,start,end,payload,deleted);")
        db.execute("INSERT INTO meetings VALUES(?,?)", ("fixture-session", json.dumps(metadata)))
        for index, text in enumerate(sentences):
            start, end = index * 3, index * 3 + 2
            turn = {"id": f"turn-{index}", "text": text, "start": start, "end": end, "final": True}
            db.execute("INSERT INTO segments VALUES(?,?,?,?,?,?,?)",
                       ("fixture-session", turn["id"], 1, start, end, json.dumps([turn]), 0))
    with patch.object(replay, "native_projection", side_effect=AssertionError("unexpected fallback")):
        return replay.load_context("fixture-cache", root, database=database, cache_root=root / "cache")


class ReplayTests(unittest.TestCase):
    def test_offline_fixture_drives_production_conversation(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            context = replay_fixture(out)
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
