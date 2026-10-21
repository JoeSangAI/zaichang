import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from model_standby import ModelStandby


class StandbyLifecycle(unittest.TestCase):
    def fixture(self, body):
        folder=tempfile.TemporaryDirectory();self.addCleanup(folder.cleanup)
        binary=Path(folder.name)/'fake-native'
        binary.write_text('#!'+sys.executable+'\nimport sys,json,time\n'+body)
        binary.chmod(0o700);events=[]
        standby=ModelStandby(binary,'synthetic-local-model','synthetic-embedding',events.append,timeout=5)
        self.addCleanup(standby.close)
        return standby,events

    def test_ready_process_is_retained_until_explicit_release(self):
        s,e=self.fixture('print(json.dumps(dict(type="preparation",state="ready",capture=False,network=False)),flush=True)\nrequest=json.loads(sys.stdin.readline())\nassert request==dict(preparation_only=True)\nprint(json.dumps(dict(type="preparation",state="released",models_released=2)),flush=True)\n')
        pid=s.child.pid;s.prepare();self.assertTrue(s.ready);self.assertIsNone(s.child.poll())
        self.assertEqual(s.child.pid,pid);s.release_only();self.assertEqual(s.child.returncode,0)
        self.assertEqual(e[-1]['state'],'released')

    def test_timeout_is_explicit_and_close_reaps_owned_process(self):
        s,e=self.fixture('time.sleep(10)\n')
        s.timeout=.2
        with self.assertRaisesRegex(ValueError,'model_preparation_timeout'):s.prepare()
        s.close();self.assertIsNotNone(s.child.poll());self.assertFalse(s.ready)
        with self.assertRaises(ProcessLookupError):os.kill(s.child.pid,0)
        self.assertTrue(all(x.get('capture') is False and x.get('network') is False for x in e))

    def test_failure_does_not_report_ready_or_restart(self):
        s,e=self.fixture('print(json.dumps(dict(type="error",code="synthetic_model_failure")),flush=True)\n')
        pid=s.child.pid
        with self.assertRaisesRegex(ValueError,'model_preparation_failed'):s.prepare()
        s.close();self.assertFalse(s.ready);self.assertEqual(s.child.pid,pid)

    def test_cancel_loading_then_reopen(self):
        s,e=self.fixture('time.sleep(10)\n');s.close();self.assertIsNotNone(s.child.poll())
        next_s,next_e=self.fixture('print(json.dumps(dict(type="preparation",state="ready",capture=False,network=False)),flush=True)\nsys.stdin.readline()\n')
        next_s.prepare();self.assertTrue(next_s.ready);self.assertNotEqual(s.child.pid,next_s.child.pid)
        next_s.close();self.assertIsNotNone(next_s.child.poll())


if __name__=='__main__':unittest.main()
