import io,json,plistlib,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
import public_audio_trial as trial

class PublicCloudReservation(unittest.TestCase):
    def fixture(self,root,used):
        directory=root/'native/validation-workflow/public-cloud-trial/previous';directory.mkdir(parents=True);(directory/'night-test-ledger.json').write_text(json.dumps({'native_result':{'attempted_audio_seconds':used}}))
        binary=root/'native/nightly-build/会议采集候选.app/Contents/MacOS/MeetingCapture';binary.parent.mkdir(parents=True);(binary.parent.parent/'Info.plist').write_bytes(plistlib.dumps({'PublicAudioASRTestAllowed':True}));return binary
    def test_launch_failure_reserves_remaining_budget_before_any_socket(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);binary=self.fixture(root,51.2)
            with patch.object(trial,'verify_source'),patch.object(trial,'ROOT',root),patch.object(trial,'NATIVE',binary),patch('sys.stdin',io.StringIO('{"key":"FAKE-NEVER-SENT"}\n')),patch.object(trial.subprocess,'Popen',side_effect=RuntimeError('fixture launch failure')):
                with self.assertRaises(RuntimeError):trial.main()
            ledgers=list((root/'native/validation-workflow/public-cloud-trial').glob('*/night-test-ledger.json'));self.assertEqual(len(ledgers),2)
            reserved=next(json.loads(p.read_text()) for p in ledgers if p.parent.name!='previous')
            self.assertAlmostEqual(reserved['reserved_max_attempted_audio_seconds'],128.8);self.assertFalse(reserved['key_written']);self.assertEqual(reserved['state'],'reserved_before_native_launch')
            self.assertNotIn('FAKE-NEVER-SENT',json.dumps(reserved))
    def test_insufficient_remaining_budget_never_starts_native(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);binary=self.fixture(root,124.72)
            with patch.object(trial,'verify_source'),patch.object(trial,'ROOT',root),patch.object(trial,'NATIVE',binary),patch('sys.stdin',io.StringIO('{"key":"FAKE-NEVER-SENT"}\n')),patch.object(trial.subprocess,'Popen') as start:
                with self.assertRaisesRegex(ValueError,'initial_public_audio_seconds_exhausted'):trial.main()
                start.assert_not_called()

    def test_source_fingerprint_rejects_unapproved_audio(self):
        with tempfile.TemporaryDirectory() as folder:
            source=Path(folder)/'synthetic.pcm';source.write_bytes(bytes(3200))
            with self.assertRaisesRegex(ValueError,'public_pcm_invalid'):trial.verify_source(source)
