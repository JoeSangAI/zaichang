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


if __name__ == '__main__':
    unittest.main()
