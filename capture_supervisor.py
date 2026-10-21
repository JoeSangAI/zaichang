"""A recording's independent control deadline. No audio, model, or UI work.

The native pause signal closes admission immediately. If capture cannot confirm
its device state, kill only our Popen child at the original short cutoff, then
let the UI recover saved audio without reopening capture.
The watchdog does not publish output, so a full UI stream cannot block the cutoff.
"""
import os
import signal
import threading
import time
import json
import socket
from audio_sources import recording_control_signal


class CaptureControlAckChannel:
    """Bounded local datagram channel for control ACKs, independent of stdout."""
    def __init__(self):
        reader, writer = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        writer.setblocking(False)
        writer.set_inheritable(True)
        self._reader = reader
        self._writer = writer
        self._thread = None
        self._closed = threading.Event()

    @property
    def child_fd(self):
        return self._writer.fileno()

    def start(self, callback):
        # The Popen child inherited the writer; close the parent's duplicate.
        self._writer.close()
        self._reader.settimeout(0.2)

        def read_events():
            with self._reader:
                while True:
                    try:
                        packet, _, flags, _ = self._reader.recvmsg(4097)
                    except socket.timeout:
                        if self._closed.is_set():
                            break
                        continue
                    except OSError:
                        break
                    if not packet:
                        break
                    if flags & getattr(socket, 'MSG_TRUNC', 0) or len(packet) > 4096:
                        continue
                    try:
                        event = json.loads(packet)
                    except (UnicodeError, json.JSONDecodeError):
                        continue
                    if isinstance(event, dict):
                        callback(event)

        self._thread = threading.Thread(target=read_events, daemon=True,
                                        name='capture-control-ack-reader')
        self._thread.start()

    def close(self):
        self._closed.set()
        if self._writer.fileno() >= 0:
            self._writer.close()
        if self._thread is not None:
            self._thread.join(timeout=1)
        else:
            self._reader.close()


class CaptureSupervisor:
    # Real devices (Bluetooth headsets) can take seconds to release on pause.
    # The capture gate is already closed, so waiting longer records nothing;
    # it only avoids killing a recorder that is still releasing hardware.
    def __init__(self, child, session, *, timeout=6.0, parent_pid=None,
                 processing_timeout=185.0, event_callback=None):
        self.child = child
        self.session = session
        self.timeout = timeout
        self.processing_timeout = processing_timeout
        self._capture_closed = False
        self._finished = False
        self._paused = False
        self._pause_tracks = set()
        self._pause_revision = None
        self._early_pause_tails = {}
        self._last_control_revision = -1
        self.parent_pid = parent_pid
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._closed = False
        self._pending = None
        self._deadline = None
        self.forced_reason = None
        self.recovery_stage = None
        self.event_callback = event_callback
        self._thread = threading.Thread(target=self._watch, daemon=True,
                                        name='capture-control-deadline')
        self._thread.start()

    def request(self, command):
        action_signal = recording_control_signal(command, self.session)
        if action_signal is None:
            return False
        with self._lock:
            if self._closed or self._finished or self._capture_closed or self.child.poll() is not None:
                return False
            action = command['action']
            if action == 'pause' and self._paused:
                return True
            if action in {'pause', 'finish'} and self._pending == action:
                return True
            # Repeated controls do not extend a safety deadline or repeat a
            # finish side effect. A new control replaces the prior deadline.
            if self._pending != action:
                self._pending = action
                self._deadline = time.monotonic() + self.timeout
            try:
                self.child.send_signal(action_signal)
            except ProcessLookupError:
                return False
        self._wake.set()
        return True

    def stop(self, reason='user_stop'):
        with self._lock:
            if self._closed or self._finished or self.child.poll() is not None:
                return False
            # A second user stop after capture closed cancels tail processing.
            # Repeated cancellation never extends the short safety deadline.
            action = 'cancel' if self._capture_closed else 'stop'
            if self._pending != action:
                self._pending = action
                self._deadline = time.monotonic() + self.timeout
            try:
                self.child.send_signal(signal.SIGINT)
            except ProcessLookupError:
                return False
        self._wake.set()
        return True

    def snapshot(self):
        """Return control state without exposing child output or user content."""
        with self._lock:
            return {
                'pending': self._pending,
                'paused': self._paused,
                'capture_closed': self._capture_closed,
                'finished': self._finished,
                'forced_reason': self.forced_reason,
                'recovery_stage': self.recovery_stage,
                'pause_revision': self._pause_revision,
                'pause_tracks': sorted(self._pause_tracks),
            }

    def observe(self, event):
        if event.get('session') != self.session:
            return
        kind = event.get('type')
        device_change_pause = (kind == 'recording_paused' and
                               event.get('reason') == 'input_device_changed')
        if kind in {'recording_control_failed', 'capture_control_failed'}:
            self.stop('native_control_failed')
            return
        # An ACK certifies closed audio/write and send admission, not merely
        # receipt of a UI command. Never cancel the cutoff on a cosmetic ACK.
        if kind in {'recording_paused', 'recording_resumed'}:
            revision = event.get('control_revision')
            if type(revision) is not int:
                return
            if kind == 'recording_paused' and (event.get('capture_gate') != 'closed' or
                                               event.get('upload_gate') != 'draining_saved_audio'):
                return
        if kind == 'recording_pause_tail':
            track = event.get('track')
            revision = event.get('pause_revision')
            if (not isinstance(track, str) or type(revision) is not int or
                    event.get('state') not in {'complete', 'pending'}):
                return
            with self._lock:
                if (self._capture_closed or self._finished or
                        self._pending in {'stop', 'cancel', 'finish'}):
                    return
                if self._pending == 'pause_drain' and revision == self._pause_revision:
                    self._pause_tracks.discard(track)
                    if not self._pause_tracks:
                        self._pending = self._deadline = None
                elif (revision > self._last_control_revision and
                      self._pending in {'pause', 'resume', None}):
                    # The dedicated ACK socket and ordinary event stream are
                    # independent. A device-change pause can also arrive while
                    # resume is pending (or without a UI command); retain only
                    # future-revision tails until its validated ACK identifies
                    # the matching inventory. This never changes the deadline.
                    early = self._early_pause_tails.setdefault(revision, set())
                    if len(early) < 512:
                        early.add(track)
                    if len(self._early_pause_tails) > 4:
                        for stale in sorted(self._early_pause_tails)[:-4]:
                            self._early_pause_tails.pop(stale, None)
            self._wake.set()
            return
        with self._lock:
            if kind in {'recording_paused', 'recording_resumed'} and (self._capture_closed or self._finished):
                return
            if kind in {'recording_paused', 'recording_resumed'} and self._pending in {'stop', 'cancel', 'finish'}:
                # A terminal command owns its short cutoff until native confirms
                # capture closure. A delayed pre-terminal control ACK must not
                # convert that cutoff back into a pause/resume deadline.
                return
            if kind == 'recording_paused' and self._pending != 'pause':
                # A microphone route change can pause capture while the UI's
                # resume handshake is still in flight, or without a UI command
                # at all. Only that exact, gate-validated native cause may
                # replace the resume deadline; generic/out-of-order pause ACKs
                # must not steal a newer control request.
                if not (device_change_pause and self._pending in {None, 'resume'}):
                    return
            if kind == 'recording_resumed' and self._pending != 'resume':
                return
            if kind == 'stopped':
                self._finished = True
                self._paused = False
                self._pending = self._deadline = None
                self._pause_tracks.clear()
            elif kind == 'recording_paused':
                revision = event.get('control_revision')
                if revision <= self._last_control_revision:
                    return
                self._last_control_revision = revision
                self._paused = True
                self._pause_tracks = {track for track in event.get('draining_tracks', [])
                                      if isinstance(track, str)}
                self._pause_revision = revision
                self._pause_tracks.difference_update(self._early_pause_tails.pop(revision, set()))
                if self._pause_tracks:
                    self._pending = 'pause_drain'
                    self._deadline = time.monotonic() + self.processing_timeout
                else:
                    self._pending = self._deadline = None
                    self._pause_revision = None
                for stale in list(self._early_pause_tails):
                    if stale <= revision:
                        self._early_pause_tails.pop(stale, None)
            elif (kind == 'capture_stopped' and event.get('capture') is False
                  and not self._capture_closed and not self._finished):
                # Native has closed capture admission and stopped the devices.
                # Its journal/ASR tail has a 180 s deadline of its own; allow
                # that bounded drain instead of killing it after 2 seconds.
                self._capture_closed = True
                self._pause_tracks.clear()
                self._pause_revision = None
                self._pending = 'processing'
                self._deadline = time.monotonic() + self.processing_timeout
            else:
                expected = {'pause': 'recording_paused',
                            'resume': 'recording_resumed'}.get(self._pending)
                if kind == 'recording_resumed':
                    revision = event.get('control_revision')
                    if revision <= self._last_control_revision:
                        return
                    self._last_control_revision = revision
                if kind == expected:
                    self._pending = self._deadline = None
                    self._pause_tracks.clear()
                    self._pause_revision = None
                    if kind == 'recording_resumed':
                        self._paused = False
        self._wake.set()

    def _watch(self):
        while True:
            pending_events = []
            terminate = False
            with self._lock:
                if self._closed or self.child.poll() is not None:
                    return
                parent_lost = self.parent_pid is not None and os.getppid() != self.parent_pid
                expired = self._deadline is not None and time.monotonic() >= self._deadline
                if expired and self._pending == 'pause_drain' and not parent_lost:
                    # Capture is already closed and the helper is safely paused.
                    # ASR tail latency must not kill a recorder that can still
                    # resume; report unresolved tracks as pending, then retain
                    # the paused process for an explicit resume or finish.
                    revision = self._pause_revision
                    for track in sorted(self._pause_tracks):
                        pending_events.append({
                            'type': 'recording_pause_tail',
                            'session': self.session,
                            'track': track,
                            'pause_revision': revision,
                            'state': 'pending',
                            'reason': 'pause_drain_timeout',
                        })
                    self._pause_tracks.clear()
                    self._pending = self._deadline = None
                    self._pause_revision = None
                elif parent_lost or expired:
                    self.forced_reason = ('capture_owner_exited' if parent_lost else
                                          ('processing_timeout' if self._pending == 'processing' else
                                           'capture_control_timeout_' + self._pending))
                    if not parent_lost and self._pending in {'pause', 'pause_drain', 'finish'}:
                        self.recovery_stage = self.forced_reason + '_saved_audio_recovery_pending'
                    # Popen owns this child and poll() verifies it has not exited.
                    # No broad process-name lookup or PID from user data.
                    try:
                        self.child.kill()
                    except ProcessLookupError:
                        pass
                    terminate = True
            # UI/persistence callbacks may call snapshot() or other supervisor
            # methods; never invoke them while holding _lock.
            if pending_events and self.event_callback is not None:
                for event in pending_events:
                    try:
                        self.event_callback(event)
                    except Exception:
                        pass
            if terminate:
                return
            self._wake.wait(.01)
            self._wake.clear()

    def close(self):
        with self._lock:
            self._closed = True
        self._wake.set()
        self._thread.join(timeout=.2)
