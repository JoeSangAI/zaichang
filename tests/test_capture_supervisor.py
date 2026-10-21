import json
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from capture_supervisor import CaptureControlAckChannel, CaptureSupervisor


class ControlSafety(unittest.TestCase):
    def child(self, folder):
        # CPU/model/device and stdout reader can be wedged indefinitely. This
        # child has no device/network; file increments simulate admitted frames.
        code = '''import signal,time,sys
from pathlib import Path
signal.signal(signal.SIGUSR1,lambda *_:None)
signal.signal(signal.SIGUSR2,lambda *_:None)
signal.signal(signal.SIGINT,lambda *_:None)
p=Path(sys.argv[1]);p.write_bytes(b'original-recording')
print('ready',flush=True)
while True:
 with p.open('ab') as f:f.write(b'frame')
 time.sleep(.005)
'''
        child = subprocess.Popen([sys.executable, '-u', '-c', code, str(folder/'audio.pcm')],
                                 stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: child.poll() is None and child.kill())
        self.addCleanup(child.stdout.close)
        self.assertEqual(child.stdout.readline().strip(), 'ready')
        return child

    def command(self, action='pause', session='meeting'):
        return dict(operation='recording_control', action=action, session=session)

    def test_real_blocked_child_is_killed_within_production_deadline_and_bytes_keep(self):
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp);child=self.child(folder)
            owner=CaptureSupervisor(child,'meeting');self.addCleanup(owner.close)
            started=time.monotonic();owner.request(self.command())
            child.wait(timeout=6.5)
            self.assertLess(time.monotonic()-started,6.4)
            self.assertEqual(child.returncode,-signal.SIGKILL)
            self.assertEqual(owner.forced_reason,'capture_control_timeout_pause')
            self.assertEqual(owner.recovery_stage,'capture_control_timeout_pause_saved_audio_recovery_pending')
            content=(folder/'audio.pcm').read_bytes();time.sleep(.05)
            self.assertEqual(content,(folder/'audio.pcm').read_bytes())
            self.assertTrue(content.startswith(b'original-recording'))

    def test_pause_ack_bypasses_blocked_general_stdout(self):
        with tempfile.TemporaryDirectory() as temp:
            ack_channel = CaptureControlAckChannel()
            ack_fd = ack_channel.child_fd
            code = '''import errno,json,os,signal,sys,threading,time
fd=int(sys.argv[1]);revision=0
def pause(_signum,_frame):
 global revision
 revision+=1
 # Close capture admission before acknowledging the control.
 event=dict(type='recording_paused',session='meeting',capture=False,capture_gate='closed',upload_gate='draining_saved_audio',control_revision=revision,draining_tracks=[])
 os.write(fd,json.dumps(event,separators=(',',':')).encode()+b'\\n')
signal.signal(signal.SIGUSR1,pause)
def flood():
 while True: os.write(1,b'x'*65536)
os.set_blocking(1,False)
while True:
 try: os.write(1,b'x'*65536)
 except BlockingIOError: break
os.set_blocking(1,True)
os.write(2,b'ready\\n')
threading.Thread(target=flood,daemon=True).start()
while True: time.sleep(.005)
'''
            child = subprocess.Popen([sys.executable, '-u', '-c', code, str(ack_fd)],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                     pass_fds=(ack_fd,))
            def stop_child():
                if child.poll() is None:
                    child.kill()
                try:
                    child.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    pass
            self.addCleanup(stop_child)
            self.addCleanup(child.stdout.close)
            self.addCleanup(child.stderr.close)
            owner = CaptureSupervisor(child, 'meeting', timeout=.5)
            self.addCleanup(owner.close)
            events = []
            received = threading.Event()
            def on_ack(event):
                owner.observe(event)
                events.append(event)
                received.set()
            ack_channel.start(on_ack)
            self.addCleanup(ack_channel.close)
            self.assertEqual(child.stderr.readline().strip(), 'ready')
            self.assertTrue(owner.request(self.command()))
            self.assertTrue(received.wait(.3), 'dedicated ACK was blocked behind ordinary stdout')
            self.assertEqual(events[0]['capture_gate'], 'closed')
            self.assertEqual(events[0]['upload_gate'], 'draining_saved_audio')
            time.sleep(.55)
            self.assertIsNone(child.poll())
            self.assertIsNone(owner.forced_reason)

    def test_tail_arriving_on_stdout_before_dedicated_ack_is_reconciled(self):
        with tempfile.TemporaryDirectory() as temp:
            ack_channel = CaptureControlAckChannel()
            ack_fd = ack_channel.child_fd
            code = '''import json,os,signal,sys,time
fd=int(sys.argv[1])
def pause(_signum,_frame):
 tail=dict(type='recording_pause_tail',session='meeting',track='mic',pause_revision=9,state='complete')
 os.write(1,json.dumps(tail,separators=(',',':')).encode()+b'\\n')
 time.sleep(.05)  # Force the ordinary stream to be consumed before the ACK socket.
 ack=dict(type='recording_paused',session='meeting',capture_gate='closed',upload_gate='draining_saved_audio',draining_tracks=['mic'],control_revision=9)
 os.write(fd,json.dumps(ack,separators=(',',':')).encode()+b'\\n')
signal.signal(signal.SIGUSR1,pause)
print('ready',flush=True)
while True: time.sleep(.005)
'''
            child = subprocess.Popen([sys.executable, '-u', '-c', code, str(ack_fd)],
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     pass_fds=(ack_fd,))
            def stop_child():
                if child.poll() is None:
                    child.kill()
                try:
                    child.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    pass
            self.addCleanup(stop_child)
            self.addCleanup(child.stdout.close)
            owner = CaptureSupervisor(child, 'meeting', timeout=.3, processing_timeout=.2)
            self.addCleanup(owner.close)
            self.assertEqual(child.stdout.readline().strip(), b'ready')
            received = threading.Event()
            def on_ack(event):
                owner.observe(event)
                received.set()
            ack_channel.start(on_ack)
            self.addCleanup(ack_channel.close)
            owner.request(self.command())
            tail = json.loads(child.stdout.readline())
            self.assertEqual(tail['type'], 'recording_pause_tail')
            owner.observe(tail)
            self.assertTrue(received.wait(.2))
            self.assertIsNone(owner._pending)
            time.sleep(.1)
            self.assertIsNone(child.poll())

    def test_pause_retries_never_extend_cutoff(self):
        with tempfile.TemporaryDirectory() as temp:
            child=self.child(Path(temp));owner=CaptureSupervisor(child,'meeting',timeout=.15);self.addCleanup(owner.close)
            owner.request(self.command());time.sleep(.1);owner.request(self.command())
            child.wait(timeout=.13);self.assertEqual(owner.forced_reason,'capture_control_timeout_pause')

    def test_wrong_session_ack_cannot_prevent_cutoff(self):
        with tempfile.TemporaryDirectory() as temp:
            child=self.child(Path(temp));owner=CaptureSupervisor(child,'meeting',timeout=.08);self.addCleanup(owner.close)
            self.assertFalse(owner.request(self.command(session='other')))
            owner.request(self.command());owner.observe(dict(type='recording_paused',session='other'))
            child.wait(timeout=.3);self.assertEqual(owner.forced_reason,'capture_control_timeout_pause')

    def test_valid_ack_keeps_same_process_and_resume_is_also_bounded(self):
        with tempfile.TemporaryDirectory() as temp:
            child=self.child(Path(temp));owner=CaptureSupervisor(child,'meeting',timeout=.08);self.addCleanup(owner.close)
            owner.request(self.command());owner.observe(dict(type='recording_paused',session='meeting',capture_gate='closed',upload_gate='draining_saved_audio',control_revision=1,draining_tracks=[]))
            time.sleep(.12);self.assertIsNone(child.poll())
            owner.request(self.command(action='resume'));child.wait(timeout=.3)
            self.assertEqual(owner.forced_reason,'capture_control_timeout_resume')

    def test_out_of_order_control_acks_cannot_restore_old_pause_state(self):
        child = FakeChild()
        owner = CaptureSupervisor(child, 'meeting', timeout=0.2)
        self.addCleanup(owner.close)
        owner.request(self.command('pause'))
        paused = dict(type='recording_paused', session='meeting', capture_gate='closed',
                      upload_gate='draining_saved_audio', draining_tracks=[], control_revision=5)
        owner.observe(paused)
        self.assertTrue(owner._paused)

        owner.request(self.command('resume'))
        # A higher-revision pause receipt cannot steal a newer resume request.
        owner.observe(dict(type='recording_paused', session='meeting', capture_gate='closed',
                           upload_gate='draining_saved_audio', draining_tracks=['mic'],
                           control_revision=6))
        self.assertEqual(owner._pending, 'resume')
        self.assertTrue(owner._paused)
        owner.observe(dict(type='recording_resumed', session='meeting', control_revision=6))
        self.assertFalse(owner._paused)

        # A delayed detached pause ACK must not undo the newer resume ACK.
        owner.observe(paused)
        self.assertFalse(owner._paused)
        owner.request(self.command('pause'))
        self.assertEqual(child.signals, [signal.SIGUSR1, signal.SIGUSR2, signal.SIGUSR1])
        owner.observe(dict(type='recording_paused', session='meeting', capture_gate='closed',
                           upload_gate='draining_saved_audio', draining_tracks=[], control_revision=7))
        # Nor may a delayed resume ACK undo a newer pause.
        owner.observe(dict(type='recording_resumed', session='meeting', control_revision=6))
        self.assertTrue(owner._paused)
        owner.request(self.command('pause'))
        self.assertEqual(child.signals, [signal.SIGUSR1, signal.SIGUSR2, signal.SIGUSR1])

    def test_device_change_pause_interrupts_pending_resume_and_can_resume_again(self):
        child = FakeChild()
        owner = CaptureSupervisor(child, 'meeting', timeout=0.04)
        self.addCleanup(owner.close)

        owner.request(self.command('resume'))
        self.assertEqual(owner._pending, 'resume')
        # The precise cause is insufficient without the closed capture/send
        # gates and a strictly newer revision.
        owner.observe(dict(type='recording_paused', session='meeting',
                           capture_gate='open', upload_gate='draining_saved_audio',
                           control_revision=1, reason='input_device_changed'))
        owner.observe(dict(type='recording_paused', session='meeting',
                           capture_gate='closed', upload_gate='closed',
                           control_revision=1, reason='input_device_changed'))
        self.assertEqual(owner._pending, 'resume')
        self.assertFalse(owner._paused)

        owner.observe(dict(type='recording_paused', session='meeting',
                           capture_gate='closed', upload_gate='draining_saved_audio',
                           control_revision=1, reason='input_device_changed',
                           draining_tracks=[]))
        self.assertIsNone(owner._pending)
        self.assertTrue(owner._paused)
        self.assertEqual(owner._last_control_revision, 1)
        time.sleep(0.08)  # Beyond the abandoned resume deadline.
        self.assertFalse(child.killed.is_set())
        self.assertIsNone(owner.forced_reason)

        owner.request(self.command('resume'))
        owner.observe(dict(type='recording_resumed', session='meeting',
                           control_revision=2))
        self.assertIsNone(owner._pending)
        self.assertFalse(owner._paused)
        owner.request(self.command('pause'))
        owner.observe(dict(type='recording_paused', session='meeting',
                           capture_gate='closed', upload_gate='draining_saved_audio',
                           control_revision=3, draining_tracks=[]))
        self.assertIsNone(owner._pending)
        self.assertTrue(owner._paused)
        self.assertEqual(child.signals, [signal.SIGUSR2, signal.SIGUSR2, signal.SIGUSR1])

    def test_device_change_pause_without_pending_command_updates_supervisor(self):
        child = FakeChild()
        owner = CaptureSupervisor(child, 'meeting', timeout=0.04)
        self.addCleanup(owner.close)

        owner.observe(dict(type='recording_paused', session='meeting',
                           capture_gate='closed', upload_gate='draining_saved_audio',
                           control_revision=4, reason='input_device_changed',
                           draining_tracks=[]))
        self.assertTrue(owner._paused)
        self.assertIsNone(owner._pending)
        self.assertEqual(owner._last_control_revision, 4)
        time.sleep(0.08)
        self.assertFalse(child.killed.is_set())

        # An untagged late pause cannot supersede a later in-flight resume.
        owner.request(self.command('resume'))
        owner.observe(dict(type='recording_paused', session='meeting',
                           capture_gate='closed', upload_gate='draining_saved_audio',
                           control_revision=5, draining_tracks=[]))
        self.assertEqual(owner._pending, 'resume')
        self.assertTrue(owner._paused)
        owner.observe(dict(type='recording_resumed', session='meeting', control_revision=6))
        self.assertIsNone(owner._pending)
        self.assertFalse(owner._paused)

    def test_device_pause_tail_before_dedicated_ack_is_reconciled(self):
        for pending_resume in (False, True):
            with self.subTest(pending_resume=pending_resume):
                child = FakeChild()
                owner = CaptureSupervisor(child, 'meeting', timeout=0.05,
                                          processing_timeout=0.2)
                self.addCleanup(owner.close)
                owner.request(self.command('pause'))
                owner.observe(dict(type='recording_paused', session='meeting',
                                   capture_gate='closed', upload_gate='draining_saved_audio',
                                   control_revision=5, draining_tracks=[]))
                self.assertTrue(owner._paused)
                self.assertIsNone(owner._pending)
                if pending_resume:
                    owner.request(self.command('resume'))
                    self.assertEqual(owner._pending, 'resume')
                deadline_before_tail = owner._deadline

                # A tail from an already-confirmed revision is stale. A future
                # tail is retained while the matching device-pause ACK is still
                # crossing its independent delivery channel.
                owner.observe(dict(type='recording_pause_tail', session='meeting',
                                   track='mic', pause_revision=5, state='complete'))
                self.assertNotIn(5, owner._early_pause_tails)
                early_tail = dict(type='recording_pause_tail', session='meeting',
                                  track='mic', pause_revision=6, state='complete')
                owner.observe(early_tail)
                self.assertEqual(owner._early_pause_tails.get(6), {'mic'})
                self.assertEqual(owner._deadline, deadline_before_tail)

                if pending_resume:
                    # An untagged late pause ACK must not consume the tail or
                    # steal the resume request; the exact route-change ACK can.
                    owner.observe(dict(type='recording_paused', session='meeting',
                                       capture_gate='closed', upload_gate='draining_saved_audio',
                                       control_revision=6, draining_tracks=['mic']))
                    self.assertEqual(owner._pending, 'resume')
                    self.assertEqual(owner._early_pause_tails.get(6), {'mic'})

                owner.observe(dict(type='recording_paused', session='meeting',
                                   capture_gate='closed', upload_gate='draining_saved_audio',
                                   control_revision=6, reason='input_device_changed',
                                   draining_tracks=['mic']))
                self.assertTrue(owner._paused)
                self.assertEqual(owner._last_control_revision, 6)
                self.assertIsNone(owner._pending)
                self.assertFalse(owner._pause_tracks)
                self.assertNotIn(6, owner._early_pause_tails)
                time.sleep(0.08)  # The tail cleared pause_drain; no false 180s cutoff.
                self.assertFalse(child.killed.is_set())

    def test_terminal_stop_and_finish_keep_short_deadline_after_late_pause_ack_and_tail(self):
        for terminal in ('stop', 'finish'):
            with self.subTest(terminal=terminal):
                child = FakeChild()
                owner = CaptureSupervisor(child, 'meeting', timeout=.08, processing_timeout=.35)
                self.addCleanup(owner.close)
                owner.request(self.command('pause'))
                if terminal == 'stop':
                    owner.stop()
                    expected = 'stop'
                else:
                    owner.request(self.command('finish'))
                    expected = 'finish'

                owner.observe(dict(type='recording_paused', session='meeting',
                                   capture_gate='closed', upload_gate='draining_saved_audio',
                                   draining_tracks=['mic'], control_revision=1))
                owner.observe(dict(type='recording_pause_tail', session='meeting', track='mic',
                                   pause_revision=1, state='complete'))
                self.assertEqual(owner._pending, expected)
                self.assertTrue(child.killed.wait(.2))
                self.assertEqual(owner.forced_reason, 'capture_control_timeout_' + expected)

    def test_orderly_finish_capture_stopped_keeps_processing_window_until_stopped(self):
        child = FakeChild()
        owner = CaptureSupervisor(child, 'meeting', timeout=.08, processing_timeout=.12)
        self.addCleanup(owner.close)
        owner.request(self.command('finish'))
        owner.observe(dict(type='capture_stopped', session='meeting', capture=False,
                           processing_pending=True))
        self.assertEqual(owner._pending, 'processing')
        self.assertFalse(child.killed.wait(.04))
        owner.observe(dict(type='stopped', session='meeting'))
        self.assertFalse(child.killed.wait(.14))
        self.assertIsNone(owner.forced_reason)

    def test_cosmetic_pause_ack_does_not_cancel_cutoff(self):
        with tempfile.TemporaryDirectory() as temp:
            child=self.child(Path(temp));owner=CaptureSupervisor(child,'meeting',timeout=.08);self.addCleanup(owner.close)
            owner.request(self.command());owner.observe(dict(type='recording_paused',session='meeting'))
            child.wait(timeout=.3);self.assertEqual(owner.forced_reason,'capture_control_timeout_pause')

    def test_stop_is_bounded_even_if_child_ignores_interrupt(self):
        with tempfile.TemporaryDirectory() as temp:
            child=self.child(Path(temp));owner=CaptureSupervisor(child,'meeting',timeout=.08);self.addCleanup(owner.close)
            owner.stop();child.wait(timeout=.3)
            self.assertEqual(owner.forced_reason,'capture_control_timeout_stop')


class FakeChild:
    def __init__(self):
        import threading
        self.killed = threading.Event()
        self.signals = []

    def poll(self):
        return -signal.SIGKILL if self.killed.is_set() else None

    def send_signal(self, value):
        self.signals.append(value)

    def kill(self):
        self.killed.set()


class ProcessingDeadlineSafety(unittest.TestCase):
    def owner(self, processing_timeout=.3):
        child = FakeChild()
        owner = CaptureSupervisor(child, 'meeting', timeout=.04,
                                  processing_timeout=processing_timeout)
        self.addCleanup(owner.close)
        return child, owner

    def closed(self, owner, **fields):
        event = dict(type='capture_stopped', session='meeting', capture=False,
                     processing_pending=True)
        event.update(fields)
        owner.observe(event)

    def test_closed_capture_can_finish_after_capture_deadline(self):
        child, owner = self.owner()
        owner.stop(); self.closed(owner)
        self.assertFalse(child.killed.wait(.09))
        owner.observe(dict(type='stopped', session='meeting'))
        self.assertFalse(child.killed.wait(.32))
        self.assertIsNone(owner.forced_reason)

    def test_missing_cosmetic_and_wrong_session_receipts_keep_cutoff(self):
        for fields in [dict(capture=None), dict(capture=True), dict(session='other')]:
            with self.subTest(fields=fields):
                child, owner = self.owner()
                owner.stop(); self.closed(owner, **fields)
                self.assertTrue(child.killed.wait(.3))
                self.assertEqual(owner.forced_reason, 'capture_control_timeout_stop')

    def test_processing_has_final_deadline_and_duplicate_receipt_cannot_extend_it(self):
        child, owner = self.owner(processing_timeout=.10)
        owner.stop(); self.closed(owner)
        time.sleep(.07); self.closed(owner)
        self.assertTrue(child.killed.wait(.075))
        self.assertEqual(owner.forced_reason, 'processing_timeout')

    def test_second_stop_cancels_processing_and_ack_cannot_reopen_it(self):
        child, owner = self.owner()
        owner.stop(); self.closed(owner); owner.stop()
        self.closed(owner)
        self.assertTrue(child.killed.wait(.2))
        self.assertEqual(owner.forced_reason, 'capture_control_timeout_cancel')
        self.assertEqual(child.signals, [signal.SIGINT, signal.SIGINT])

    def test_cancel_can_finish_and_final_event_cannot_reopen_deadline(self):
        child, owner = self.owner(processing_timeout=.08)
        owner.stop(); self.closed(owner); owner.stop()
        owner.observe(dict(type='stopped', session='meeting'))
        self.closed(owner); owner.stop()
        self.assertFalse(child.killed.wait(.12))
        self.assertEqual(len(child.signals), 2)

    def test_automatic_capture_end_is_bounded_and_cannot_resume(self):
        child, owner = self.owner(processing_timeout=.08)
        self.closed(owner)
        self.assertFalse(owner.request(dict(operation='recording_control',
                                            action='resume', session='meeting')))
        self.assertTrue(child.killed.wait(.2))
        self.assertEqual(owner.forced_reason, 'processing_timeout')

    def test_pause_ack_requires_capture_closed_and_saved_audio_drain_gate(self):
        child, owner = self.owner(processing_timeout=.12)
        owner.timeout = .18
        owner.request(dict(operation='recording_control', action='pause', session='meeting'))
        time.sleep(.015)
        owner.observe(dict(type='recording_paused', session='meeting', capture_gate='open',
                           upload_gate='draining_saved_audio', draining_tracks=['mic'],control_revision=1))
        time.sleep(.015)
        self.assertFalse(child.killed.is_set())
        owner.observe(dict(type='recording_paused', session='meeting', capture_gate='closed',
                           upload_gate='closed', draining_tracks=['mic'],control_revision=1))
        self.assertFalse(child.killed.wait(.03))
        self.assertTrue(child.killed.wait(.2))
        self.assertEqual(owner.forced_reason, 'capture_control_timeout_pause')

    def test_pause_drain_deadline_ends_only_after_each_track_reports_complete_or_pending(self):
        child, owner = self.owner(processing_timeout=.12)
        owner.request(dict(operation='recording_control', action='pause', session='meeting'))
        owner.observe(dict(type='recording_paused', session='meeting', capture_gate='closed',
                           upload_gate='draining_saved_audio', draining_tracks=['mic', 'remote'],control_revision=2))
        owner.observe(dict(type='recording_pause_tail', session='meeting', track='mic',pause_revision=1,state='complete'))
        owner.observe(dict(type='recording_pause_tail', session='meeting', track='mic',pause_revision=2,state='complete'))
        self.assertFalse(child.killed.wait(.04))
        owner.request(dict(operation='recording_control',action='pause',session='meeting'))
        self.assertEqual(child.signals,[signal.SIGUSR1])
        owner.observe(dict(type='recording_pause_tail', session='meeting', track='remote',pause_revision=2,state='pending'))
        self.assertFalse(child.killed.wait(.14))
        self.assertIsNone(owner.forced_reason)

    def test_pause_drain_timeout_reports_pending_and_keeps_same_recorder_resumable(self):
        child, owner = self.owner(processing_timeout=.06)
        pending_events=[]
        callback_finished=threading.Event()

        def on_event(event):
            # Re-entering the supervisor proves callbacks do not run under its lock.
            self.assertEqual(owner.snapshot()['paused'], True)
            pending_events.append(event)
            callback_finished.set()

        owner.event_callback=on_event
        owner.request(dict(operation='recording_control', action='pause', session='meeting'))
        owner.observe(dict(type='recording_paused', session='meeting', capture_gate='closed',
                           upload_gate='draining_saved_audio', draining_tracks=['mic'], control_revision=2))
        self.assertTrue(callback_finished.wait(.2))
        self.assertFalse(child.killed.is_set())
        self.assertIsNone(owner.forced_reason)
        self.assertEqual(pending_events, [dict(type='recording_pause_tail', session='meeting',
            track='mic', pause_revision=2, state='pending', reason='pause_drain_timeout')])
        self.assertTrue(owner.snapshot()['paused'])
        self.assertIsNone(owner.snapshot()['pending'])

        self.assertTrue(owner.request(dict(operation='recording_control', action='resume', session='meeting')))
        owner.observe(dict(type='recording_resumed', session='meeting', control_revision=3))
        self.assertFalse(child.killed.is_set())
        self.assertFalse(owner.snapshot()['paused'])

        # The independent short deadline still protects a later unacknowledged finish.
        self.assertTrue(owner.request(dict(operation='recording_control', action='finish', session='meeting')))
        self.assertTrue(child.killed.wait(.2))
        self.assertEqual(owner.forced_reason, 'capture_control_timeout_finish')

    def test_retired_sources_replayed_after_pause_ack_do_not_force_stop(self):
        child, owner = self.owner(processing_timeout=.08)
        owner.request(dict(operation='recording_control', action='pause', session='meeting'))
        retired = ['remote-g1', 'remote-g2', 'remote-g3', 'remote-g4']
        owner.observe(dict(type='recording_paused', session='meeting', capture_gate='closed',
                           upload_gate='draining_saved_audio', draining_tracks=['mic']+retired, control_revision=3))
        for track in retired:
            owner.observe(dict(type='recording_pause_tail', session='meeting', track=track,
                               pause_revision=3, state='complete'))
        self.assertEqual(owner._pause_tracks, {'mic'})
        owner.observe(dict(type='recording_pause_tail', session='meeting', track='mic',
                           pause_revision=3, state='complete'))
        self.assertFalse(child.killed.wait(.12))
        self.assertTrue(owner._paused)
        self.assertIsNone(owner._pending)
        self.assertIsNone(owner.forced_reason)

    def test_finish_is_session_bound_idempotent_and_pause_can_finish_without_restarting(self):
        child, owner = self.owner(processing_timeout=.12)
        owner.request(dict(operation='recording_control', action='pause', session='meeting'))
        owner.observe(dict(type='recording_paused', session='meeting', capture_gate='closed',
                           upload_gate='draining_saved_audio', draining_tracks=['mic'],control_revision=3))
        self.assertFalse(owner.request(dict(operation='recording_control', action='finish', session='other')))
        self.assertTrue(owner.request(dict(operation='recording_control', action='finish', session='meeting')))
        self.assertTrue(owner.request(dict(operation='recording_control', action='finish', session='meeting')))
        self.assertEqual(child.signals, [signal.SIGUSR1, signal.SIGWINCH])
        owner.observe(dict(type='capture_stopped', session='meeting', capture=False, processing_pending=True))
        owner.observe(dict(type='stopped', session='meeting'))
        self.assertFalse(child.killed.wait(.14))
        self.assertIsNone(owner.forced_reason)


if __name__=='__main__':unittest.main()
