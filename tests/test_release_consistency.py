import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT), str(ROOT / 'scripts')]

import app_version
import install_standalone


class ReleaseConsistencyTests(unittest.TestCase):
    def test_first_run_guide_was_reviewed_for_this_release(self):
        self.assertEqual(app_version.first_run_review_problem(), '')

    def test_every_installer_ships_the_one_version(self):
        self.assertEqual(install_standalone.VERSION, app_version.VERSION)
        self.assertEqual(install_standalone.BUILD, app_version.BUILD)

    def app(self, path, identifier):
        (path / 'Contents').mkdir(parents=True)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier}))

    def test_update_finds_the_copy_the_user_already_has(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            home, system = base / 'home/在场.app', base / 'system/在场.app'
            choose = lambda: install_standalone.default_destination(home, system)
            self.assertEqual(choose(), home)
            self.app(system, 'com.example.other')
            self.assertEqual(choose(), home)
            (system / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': install_standalone.BUNDLE_ID}))
            self.assertEqual(choose(), system)
            self.app(home, install_standalone.BUNDLE_ID)
            self.assertEqual(choose(), home)


@unittest.skipUnless((ROOT / 'scripts/export_public.py').is_file(), 'source checkout only')
class PublicExportTests(unittest.TestCase):
    def test_export_takes_only_committed_content(self):
        import export_public
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            subprocess.run(['git', 'init', '-q', str(base)], check=True)
            (base / 'public').mkdir()
            (base / 'public/README.md').write_text('committed\n')
            subprocess.run(['git', '-C', str(base), 'add', 'public/README.md'], check=True)
            subprocess.run(['git', '-C', str(base), '-c', 'user.name=t', '-c', 'user.email=t@example.com', 'commit', '-qm', 't'], check=True)
            (base / 'public/README.md').write_text('draft from another session\n')
            (base / 'public/new.png').write_bytes(b'unreviewed')
            with export_public.committed_tree('HEAD', base) as tree:
                self.assertEqual((tree / 'public/README.md').read_text(), 'committed\n')
                self.assertFalse((tree / 'public/new.png').exists())

    def test_hand_edit_on_github_blocks_until_taken_back(self):
        import sync_public
        recorded, wanted = {'README.md': 'old'}, {'README.md': 'old'}
        self.assertEqual(sync_public.edited_outside_export({'README.md': 'hand'}, recorded, wanted), ['README.md'])
        self.assertEqual(sync_public.edited_outside_export({'new.png': 'hand'}, {}, {}), ['new.png'])
        self.assertEqual(sync_public.edited_outside_export({'README.md': 'hand'}, recorded, {'README.md': 'hand'}), [])
        self.assertEqual(sync_public.edited_outside_export({'README.md': 'old'}, recorded, {'README.md': 'new'}), [])


if __name__ == '__main__':
    unittest.main()
