"""Compile the production signal/route/barrier code; no devices or network."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def declaration(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]


class CapturePauseBoundaryTests(unittest.TestCase):
    def test_ui_pause_and_device_pause_share_one_tail_revision(self):
        capture = (ROOT / 'native/MeetingCapture.swift').read_text()
        source = (ROOT / 'native/SourceCaptureSession.swift').read_text()
        swift = 'import Foundation\nimport Darwin\n'
        swift += declaration(capture, 'var interrupted: sig_atomic_t', '@inline(__always) func captureAdmissionOpen')
        swift += declaration(capture, 'func recordingPauseHandler(', 'func recordingFinishHandler(')
        swift += declaration(source, 'final class CaptureInputDeviceChangePause {', '/// Detects a microphone')
        swift += declaration(source, 'final class CapturePauseTailBarrier {', 'private final class CaptureASRConsumerInventory')
        swift += '''
var results:[String:Bool]=[:]
for deviceFirst in [true,false] {
    capturePaused=0;captureHardwareReady=1;captureControlRevision=0
    let route=CaptureInputDeviceChangePause(),tail=CapturePauseTailBarrier()
    if deviceFirst {route.request(reason:"input_device_changed");_=route.applyPendingPause()}
    else {recordingPauseHandler(SIGUSR1)}
    let revision=captureControlRevision
    tail.begin(revision:revision,throughByte:121732)
    if deviceFirst {recordingPauseHandler(SIGUSR1)}
    else {route.request(reason:"input_device_changed");_=route.applyPendingPause()}
    // The capture loop finalizes only the transition's matching revision.
    if revision==captureControlRevision {tail.finalize(revision:revision,throughByte:121732)}
    if let (ready,_) = tail.pending() {tail.complete(ready)}
    results[deviceFirst ? "device_then_ui" : "ui_then_device"] =
        captureControlRevision==revision && tail.isComplete(captureControlRevision)
    recordingPauseHandler(SIGUSR2)
    results[deviceFirst ? "device_resume" : "ui_resume"] =
        capturePaused==0 && captureControlRevision==revision+1
}
print(String(data:try! JSONSerialization.data(withJSONObject:results,options:.sortedKeys),encoding:.utf8)!)
'''
        with tempfile.TemporaryDirectory(prefix='pause-boundary-') as temp:
            folder = Path(temp)
            path = folder / 'main.swift'
            path.write_text(swift)
            subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'cache'),
                            str(path), '-o', str(folder / 'check')],
                           # A fresh Swift module cache can exceed one minute on a busy Mac.
                           check=True, capture_output=True, timeout=180)
            result = subprocess.run([str(folder / 'check')], check=True,
                                    capture_output=True, text=True, timeout=10)
        observed = json.loads(result.stdout)
        self.assertEqual(observed, {name: True for name in observed}, result.stdout)


if __name__ == '__main__':
    unittest.main()
