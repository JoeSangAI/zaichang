"""The optional ontology connector, against a fake local service with invented entries."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import socket
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

import ontology_source
import runtime_config
import shared_people
import shared_terms


def entries(base):
    evidence = [dict(path=str(base / 'notes/人物.md'), source='example', at=1, sha256='0' * 64, line=3)]
    return [
        dict(id='青梧公司', kind='subject', type='organization', name='青梧公司', aliases=['青梧'], provenance=evidence),
        dict(id='林小禾', kind='subject', type='person', name='林小禾', aliases=['小禾'], misrecognitions=['林小河'],
             organization_id='青梧公司', provenance=evidence),
        dict(id='林小禾 (2)', kind='subject', type='person', name='林小禾', aliases=[], organization='远山工作室',
             provenance=evidence),
        dict(id='周北辰', kind='subject', type='person', name='周北辰', aliases=['North'], misrecognitions=['周北尘'],
             role='示例角色', provenance=evidence),
        dict(id='纸灯工程', kind='project', name='纸灯工程', aliases=['纸灯'], misrecognitions=['纸登工程'],
             client='青梧公司', provenance=evidence),
        dict(id='准备样稿', kind='action', name='准备样稿', provenance=evidence),
    ]


class FakeService:
    """GET ?kind= / ?id=, POST owner records with request_id idempotency, like the real service."""

    def __init__(self, items):
        self.items = {item['id']: item for item in items}
        self.posts, self.receipts, self.down = [], {}, False
        service = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, status, value):
                data = json.dumps(value, ensure_ascii=False).encode()
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                if service.down:
                    return self.reply(503, {})
                query = parse_qs(urlsplit(self.path).query)
                rows = list(service.items.values())
                if 'kind' in query:
                    rows = [r for r in rows if r['kind'] == query['kind'][0]]
                if 'id' in query:
                    rows = [r for r in rows if r['id'] == query['id'][0]]
                    if not rows:
                        return self.reply(404, {})
                self.reply(200, dict(schema_version=1, items=rows, redirects={}))

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                if service.down:
                    return self.reply(503, {})
                if 'Origin' in self.headers or self.headers['Content-Type'] != 'application/json':
                    return self.reply(403, {})
                service.posts.append(body)
                key = body.get('request_id')
                if key in service.receipts:
                    return self.reply(200 if service.receipts[key] == body else 409, {})
                service.receipts[key] = body
                item = service.items[body['id']]
                item.update(body['fields'])
                self.reply(201, dict(batch='b', item=item))

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.url = f'http://127.0.0.1:{self.server.server_address[1]}/api/ontology'
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def unused_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


class OntologySourceTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        env = patch.dict(os.environ, {'ZAICHANG_DATA_ROOT': str(self.root)})
        env.start()
        self.addCleanup(env.stop)
        self.service = FakeService(entries(self.root))
        self.addCleanup(self.service.close)
        self.focus = self.root / 'ExampleProjects'
        master = self.focus / '公司资料/内部人员与长期协作方.md'
        master.parent.mkdir(parents=True)
        master.write_text('## 示例组织内部人员\n- **合成甲（Alpha）：** 示例组织测试角色。\n', encoding='utf-8')
        self.loader = str((Path(__file__).parent / 'fixtures/people_loader.py').resolve())
        self.snapshot = self.root / 'snapshot.json'
        self.snapshot.write_text(json.dumps(dict(schema_version=1, items=entries(self.root), redirects={}),
                                            ensure_ascii=False), encoding='utf-8')

    def write(self, **extra):
        value = dict(schema=1, people_loader=self.loader, project_roots=[str(self.focus)], **extra)
        (self.root / 'connectors.json').write_text(json.dumps(value, ensure_ascii=False))
        shared_terms.compiled_owners(max_age=-1)

    def names(self, result):
        return [c['reference']['name'] for c in result['candidates']]

    def test_only_loopback_http_is_accepted(self):
        for value in ('http://192.0.2.1/api/ontology', 'https://127.0.0.1/api/ontology', 'file:///tmp/x',
                      'http://127.0.0.1:8766/api/ontology?kind=subject', 'http://user:pw@127.0.0.1/api', ['x'],
                      {'snapshot': '/tmp/s.json'}):
            self.write(ontology=value)
            self.assertNotIn('ontology', runtime_config.connectors(), value)
        self.write(ontology='http://localhost:8766/api/ontology/')
        self.assertEqual(runtime_config.connectors()['ontology'], {'url': 'http://localhost:8766/api/ontology'})
        self.write(ontology={'url': self.service.url, 'snapshot': str(self.snapshot)})
        self.assertEqual(runtime_config.connectors()['ontology'], {'url': self.service.url, 'snapshot': str(self.snapshot)})

    def test_disabled_keeps_existing_sources(self):
        self.write()
        self.assertIsNone(ontology_source.read())
        self.assertEqual(self.names(shared_people.search_people('合成甲')), ['合成甲'])
        self.assertEqual(shared_people.search_people('林小禾')['candidates'], [])
        self.assertFalse(any(o.get('ontology') for o in shared_terms.compiled_owners()))
        self.assertEqual(ontology_source.report_misrecognition('林小禾', '林小和', session='s', operation_id='1',
                                                               quote='示例'), 'disabled')
        self.assertFalse((self.root / ontology_source.OUTBOX).exists())
        self.assertEqual(self.service.posts, [])

    def test_people_come_from_the_ontology_with_organization_and_misrecognitions(self):
        self.write(ontology=self.service.url)
        result = shared_people.search_people('林小禾')
        self.assertEqual(result['source'], 'ontology')
        self.assertTrue(result['requires_confirmation'])
        self.assertEqual(self.names(result), ['林小禾', '林小禾'])
        self.assertEqual({c['organization'] for c in result['candidates']}, {'青梧公司', '远山工作室'})
        for candidate in result['candidates']:
            self.assertRegex(candidate['reference']['id'], r'^person:[0-9a-f]{20}$')
            self.assertEqual(candidate['reference']['evidence'], [str(self.root / 'notes/人物.md')])
        self.assertEqual(len({c['reference']['id'] for c in result['candidates']}), 2)
        self.assertEqual(self.names(shared_people.search_people('林小河')), ['林小禾'])  # misheard spelling
        self.assertEqual(self.names(shared_people.search_people('north')), ['周北辰'])
        self.assertEqual(shared_people.search_people('青梧公司')['candidates'], [])  # organizations are not people
        self.assertEqual(shared_people.search_people('合成甲')['candidates'], [])  # loader replaced
        # Equal names stay ambiguous; a known misrecognition of one person resolves as a whole name.
        resolved = shared_people.resolve_names(['林小禾', '周北尘', '小禾', '纸登工程'])['resolved']
        self.assertEqual(resolved, {'林小禾': '林小禾', '周北尘': '周北辰', '小禾': '林小禾'})

    def test_unreachable_service_uses_snapshot_then_existing_sources(self):
        dead = f'http://127.0.0.1:{unused_port()}/api/ontology'
        self.write(ontology={'url': dead, 'snapshot': str(self.snapshot)})
        self.assertEqual(ontology_source.read()['origin'], 'snapshot')
        self.assertEqual(self.names(shared_people.search_people('周北辰')), ['周北辰'])
        self.write(ontology=dead)
        self.assertIsNone(ontology_source.read())
        self.assertEqual(self.names(shared_people.search_people('合成甲')), ['合成甲'])
        owners = shared_terms.compiled_owners()
        self.assertEqual([o['error'] for o in owners if o.get('ontology')], ['OntologyUnavailable'])
        self.assertEqual(shared_terms.term_guide(text='林小河来了'), shared_terms.term_guide())

    def test_terms_include_heard_ontology_names_and_misrecognitions(self):
        self.write(ontology=self.service.url)
        self.assertEqual(shared_terms.term_guide(), [])  # without meeting text no ontology rows join
        text = '林小河说纸登工程下周交样，周北辰确认'
        guide = shared_terms.term_guide(text=text)
        self.assertIn('林小禾（也称小禾）；常被误识为林小河', guide)
        self.assertIn('纸灯工程（也称纸灯）；常被误识为纸登工程', guide)
        self.assertIn('周北辰（也称North）；常被误识为周北尘', guide)
        self.assertFalse(any(line.startswith('青梧公司') for line in guide))  # not said in this meeting
        rows, conflicts = shared_terms.cleanup_terms(text=text)
        self.assertEqual(conflicts, [])
        self.assertIn('林小河', next(r for r in rows if r['term'] == '林小禾')['misheard'])
        import coarse_audio
        with patch('shared_terms.meeting_projects', return_value=[]):
            cleaned = coarse_audio._cleanup_terms(self.root, [dict(text=text)])
        self.assertIn('纸灯工程', [r['term'] for r in cleaned])
        unit = dict(id='u', text='林小河说纸登工程下周交样', manual=False, approximate_window=False)
        self.assertEqual(coarse_audio._safe_text(unit, '林小禾说纸灯工程下周交样', cleaned), '林小禾说纸灯工程下周交样')
        self.assertEqual(coarse_audio._safe_text(unit, '周北辰说纸灯工程下周交样', cleaned), unit['text'])

    def test_title_context_names_ontology_projects_and_spellings(self):
        self.write(ontology=self.service.url)
        folder = self.root / 'meeting'
        folder.mkdir()
        with patch('shared_terms.meeting_text', return_value='纸登工程排期，林小河负责'):
            value = shared_terms.title_context(folder)
        self.assertIn('纸灯工程', value['projects'])
        self.assertIn(['纸登工程', '纸灯工程'], value['spellings'])
        self.assertIn(['林小河', '林小禾'], value['spellings'])
        self.assertIn('青梧公司', value['unheard'])

    def test_owner_correction_is_sent_once_and_retried_unchanged(self):
        self.write(ontology=self.service.url)
        args = dict(session='meeting-1', operation_id='op-7', quote='主人把「林晓禾」改为「林小禾」')
        self.assertEqual(ontology_source.report_misrecognition('林小禾', '林晓禾', **args, now=100), 'saved')
        body = self.service.posts[-1]
        self.assertEqual(body['fields'], {'misrecognitions': ['林小河', '林晓禾']})
        self.assertEqual((body['op'], body['actor'], body['kind'], body['at']), ('update', 'owner', 'subject', 100))
        self.assertEqual(body['evidence'], [{'ref': 'zaichang:meeting-1#op-7', 'quote': args['quote']}])
        # The same operation again: already in the list, nothing new is written.
        self.assertEqual(ontology_source.report_misrecognition('林小禾', '林晓禾', **args), 'already_known')
        self.assertEqual(len(self.service.posts), 1)
        # Service down: the correction waits locally with a fixed record and is resent as is.
        self.service.down = True
        other = dict(session='meeting-1', operation_id='op-8', quote='主人把「纸登」改为「纸灯工程」')
        self.assertEqual(ontology_source.report_misrecognition('纸灯工程', '纸登', **other, now=200), 'pending')
        self.assertEqual([e['ref'] for e in ontology_source.pending()], ['zaichang:meeting-1#op-8'])
        self.service.down = False
        self.assertEqual(ontology_source.deliver(), {'zaichang:meeting-1#op-8': 'saved'})
        self.assertEqual(ontology_source.pending(), [])
        # A lost reply: the same stored record arrives twice and the service answers duplicate.
        third = dict(session='meeting-2', operation_id='op-1', quote='主人把「周北晨」改为「周北辰」')
        ontology_source.queue_misrecognition('周北辰', '周北晨', **third, now=300)
        with patch.object(ontology_source, 'http_post', side_effect=OSError('reset')):
            self.assertEqual(ontology_source.deliver(), {'zaichang:meeting-2#op-1': 'pending'})
        stored = ontology_source.pending()[0]['body']
        self.service.receipts[stored['request_id']] = stored  # it had in fact arrived
        self.assertEqual(ontology_source.deliver(), {'zaichang:meeting-2#op-1': 'duplicate'})
        self.assertEqual(ontology_source.report_misrecognition('无此条目', '误', session='s', operation_id='x',
                                                               quote='示例'), 'not_found')
        self.assertEqual(ontology_source.pending(), [])

    def test_no_speaker_or_voice_binding_in_connector(self):
        source = Path(ontology_source.__file__).read_text(encoding='utf-8')
        self.assertIsNone(re.search(r'voiceprint|speaker_key|SessionSpeakerKey', source))


if __name__ == '__main__':
    unittest.main()
