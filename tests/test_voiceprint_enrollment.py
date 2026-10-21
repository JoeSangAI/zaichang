import json
import stat
import tempfile
import unittest
from pathlib import Path
from scripts.voiceprint_enrollment import build_archive, save_new

class VoiceprintEnrollmentTests(unittest.TestCase):
    def test_existing_reference_and_opt_out_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'voices.json';save_new({'revision':7,'enabled':False},p)
            with self.assertRaises(ValueError):save_new({'revision':1,'enabled':True},p)
            self.assertEqual(json.loads(p.read_text()),{'revision':7,'enabled':False})
            self.assertEqual(stat.S_IMODE(p.stat().st_mode),0o600)
    def test_enrollment_requires_explicit_local_use_before_audio_read(self):
        with self.assertRaisesRegex(ValueError,'Explicit local'):build_archive('/nonexistent',[],Path('.'))
    def test_ambiguous_manual_name_does_not_start_model_or_enroll(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);(p/'meeting.json').write_text(json.dumps({'session':'s'}))
            (p/'session-names.json').write_text(json.dumps({'session':'s','speakers':[{'name':'虚构姓名甲'},{'name':'虚构姓名甲'}]}))
            with self.assertRaisesRegex(ValueError,'Ambiguous'):build_archive(p,['虚构姓名甲','虚构姓名乙'],Path('.'),confirmed=True)
            self.assertFalse((p/'voices.json').exists())

if __name__=='__main__':unittest.main()
