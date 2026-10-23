import ast
import inspect
import os
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

import assistant_runtime
import runtime_config
import shared_people
import shared_terms


class RuntimeConfigurationTests(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup)
        env=patch.dict(os.environ,{'ZAICHANG_DATA_ROOT':temp.name})
        env.start();self.addCleanup(env.stop)

    def test_edition_defaults_and_parsing(self):
        for value, expected in [(None, 'joe'), ('joe', 'joe'), ('standalone', 'standalone'), ('invalid', 'joe'), ('Standalone', 'joe')]:
            env = {} if value is None else {'ZAICHANG_EDITION': value}
            self.assertEqual(runtime_config.edition(env), expected)

    def test_edition_data_roots(self):
        base = Path.home() / 'Library/Application Support'
        self.assertEqual(runtime_config.data_root({}), base / 'MeetingAssistant')
        self.assertEqual(runtime_config.data_root({'ZAICHANG_EDITION': 'standalone'}), base / 'ZaichangStandalone')
        self.assertEqual(runtime_config.data_root({'ZAICHANG_DATA_ROOT': '/tmp/p6-isolated'}), Path('/tmp/p6-isolated'))
        self.assertEqual(runtime_config.data_root({'ZAICHANG_DATA_ROOT': 'SyntheticQA'}), base / 'SyntheticQA')
        for value in ('../private', '/tmp/../private', '.', '..', 'sub/folder'):
            self.assertEqual(runtime_config.data_root({'ZAICHANG_EDITION': 'standalone', 'ZAICHANG_DATA_ROOT': value}), base / 'ZaichangStandalone')

    def test_public_people_never_opens_private_paths(self):
        with patch.dict(os.environ, {'ZAICHANG_EDITION': 'standalone'}), patch.object(shared_people, 'canonical_path', side_effect=AssertionError('private path touched')), patch.object(shared_people.importlib.util, 'spec_from_file_location', side_effect=AssertionError('private import')):
            result = shared_people.search_people('同事')
            self.assertEqual(result['candidates'], [])
            self.assertEqual(result['status'], 'ok')
            self.assertEqual(shared_people.load_authoritative_people()[0], [])

    def test_public_terms_bypasses_private_loader_and_cached_owners(self):
        with patch.dict(os.environ, {'ZAICHANG_EDITION': 'standalone'}), patch.object(shared_terms, '_COMPILED', [10**20, [{'path': 'private'}]]):
            self.assertEqual(shared_terms.compiled_owners(), [])
            self.assertEqual(shared_terms.project_rows(Path('/private/project')), [])
            self.assertEqual(shared_terms.detect_projects('专名'), [])
            self.assertEqual(shared_terms.cleanup_terms(), ([], []))
            self.assertEqual(shared_terms.term_guide(), [])

    def test_assistant_instructions_are_portable(self):
        # All literal instruction text, including the follow-up prompt, is checked.
        source = inspect.getsource(assistant_runtime)
        strings = [n.value for n in ast.walk(ast.parse(source)) if isinstance(n, ast.Constant) and isinstance(n.value, str)]
        for value in strings:
            for forbidden in ('private_owner_marker',):
                self.assertNotIn(forbidden, value)
        self.assertIn('你是用户的助理', source)
        self.assertIn('context_guidance()', source)

    def test_runtime_packaging_includes_configuration(self):
        from scripts.install_standalone import PYTHON_MODULES
        self.assertTrue({'runtime_config.py','shared_people.py','shared_terms.py'} <= set(PYTHON_MODULES))
