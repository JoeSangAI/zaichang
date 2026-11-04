import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT), str(ROOT / 'scripts')]

import release_public

LOG = '# Changelog\n\n## 0.5.0 — 2026-12-01\n\n- 新的\n- 还有\n\n## 0.4.9 — 2026-11-03\n\n- 旧的\n'
MODELS = 'Contents/Resources/Runtime/native/local-speaker-install'


class NotesTests(unittest.TestCase):
    def changelog(self, base):
        path = Path(base) / 'CHANGELOG.md'
        path.write_text(LOG, encoding='utf-8')
        return path

    def test_notes_are_only_this_versions_section(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = self.changelog(temporary)
            self.assertEqual(release_public.notes('0.5.0', log), '- 新的\n- 还有')
            self.assertEqual(release_public.notes('0.4.9', log), '- 旧的')

    def test_a_version_without_a_changelog_section_cannot_be_released(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = self.changelog(temporary)
            self.assertEqual(release_public.changelog_problem('0.5.0', log), '')
            self.assertIn('0.5.1', release_public.changelog_problem('0.5.1', log))


class BundleGateTests(unittest.TestCase):
    def app(self, base, version='0.5.0'):
        app = Path(base).resolve() / '在场.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': version}))
        (app / 'Contents/MacOS/data.txt').write_text('plain')
        return app

    def test_clean_bundle_passes(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.assertEqual(release_public.problems_in(self.app(temporary), '0.5.0', home='/nobody'), [])

    def test_wrong_version_and_python_cache_are_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.app(temporary, '0.4.9')
            (app / 'Contents/__pycache__').mkdir()
            (app / 'Contents/__pycache__/x.pyc').write_bytes(b'x')
            problems = release_public.problems_in(app, '0.5.0', home='/nobody')
            self.assertEqual(len(problems), 2)

    def test_a_source_path_string_alone_is_not_a_dependency(self):
        # Compiled-in source paths for assertion messages don't stop the app running elsewhere.
        with tempfile.TemporaryDirectory() as temporary:
            app = self.app(temporary)
            (app / 'Contents/MacOS/tool').write_bytes(b'\xcf\xfa\xed\xfe' + b'/nobody/src/file.swift')
            self.assertEqual(release_public.problems_in(app, '0.5.0', home='/nobody'), [])


class PublicInstallerTests(unittest.TestCase):
    def test_installer_never_closes_a_running_copy(self):
        text = (ROOT / 'public/install.sh').read_text(encoding='utf-8') if (ROOT / 'public/install.sh').is_file() else (ROOT / 'install.sh').read_text(encoding='utf-8')
        self.assertNotIn('pkill', text)
        self.assertNotIn('kill ', text)
        self.assertIn(release_public.TEAM, text)
        subprocess.run(['bash', '-n'], input=text.encode(), check=True)

    def test_installer_assembles_app_and_models_and_still_reads_older_feeds(self):
        text = (ROOT / 'install.sh').read_text(encoding='utf-8')
        self.assertIn('field models.zip', text)
        self.assertIn('field patch.zip', text)
        self.assertIn('field zip', text)  # a feed from before the split
        self.assertIn('codesign --verify --deep --strict', text)

    def test_models_have_one_fixed_release_per_id(self):
        self.assertEqual(release_public.models_tag('a60e1ffbc6c11f1e66ae24a9c28ef6be'), 'models-a60e1ffbc6c1')


class UpdaterContractTests(unittest.TestCase):
    def swift(self):
        return (ROOT / 'native/AppUpdate.swift').read_text(encoding='utf-8')

    def test_app_and_release_agree_on_the_identity_and_the_small_package(self):
        text = self.swift()
        self.assertIn(release_public.TEAM, text)
        self.assertIn(f'releases/latest/download/latest.json', text)
        self.assertIn(release_public.REPO, text)
        for folder in release_public.MODEL_FOLDERS: self.assertIn(folder, text)

    def test_swap_runs_only_after_the_quit_gate_and_kills_nothing(self):
        text = self.swift()
        self.assertIn('willTerminateNotification', text)
        self.assertNotIn('kill -9', text)
        # The script is started in one place, from the notification the quit gate leads to.
        self.assertEqual(text.count('swap.sh'), 1)


if __name__ == '__main__':
    unittest.main()
