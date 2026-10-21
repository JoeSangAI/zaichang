"""Offline integration of the compiled Swift helper and Python control supervisor."""
import json
import queue
import signal
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from capture_supervisor import CaptureControlAckChannel, CaptureSupervisor


def wait_event(events, wanted, timeout=4.0):
    deadline = time.monotonic() + timeout
    deferred = []
    while time.monotonic() < deadline:
        try:
            event = events.get(timeout=max(0.01, deadline - time.monotonic()))
        except queue.Empty:
            break
        if event.get('type') == wanted:
            for item in deferred:
                events.put(item)
            return event
        deferred.append(event)
    for item in deferred:
        events.put(item)
    raise AssertionError(f'timed out waiting for {wanted}; saw {[e.get("type") for e in deferred]}')


def manifest(directory):
    return json.loads((directory / 'mic-raw-manifest.json').read_text())


def run(binary, root):
    cache_id = str(uuid.uuid4())
    session = str(uuid.uuid4())
    directory = root / '.runtime' / 'capture-protocol-fixtures' / cache_id
    directory.mkdir(parents=True, mode=0o700)
    ack_channel = CaptureControlAckChannel()
    ack_fd = ack_channel.child_fd
    child = subprocess.Popen(
        [str(binary), '--capture-control-protocol-fixture', str(directory), session, cache_id, str(ack_fd)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, pass_fds=(ack_fd,))
    supervisor = CaptureSupervisor(child, session)
    events = queue.Queue()
    reader_errors = []

    def publish(event):
        supervisor.observe(event)
        events.put(event)

    def read_stdout():
        try:
            for line in child.stdout:
                event = json.loads(line)
                publish(event)
        except BaseException as error:  # surfaced on the test thread below
            reader_errors.append(error)

    reader = threading.Thread(target=read_stdout, daemon=True, name='fixture-helper-stdout')
    reader.start()
    ack_channel.start(publish)
    try:
        started = wait_event(events, 'started')
        assert started['session'] == session and started['cache_id'] == cache_id
        assert started['fixture'] is True and started['network'] is False
        assert started['fixture_written_bytes'] > 0
        initial = manifest(directory)
        assert initial['ended'] is False

        last_revision = 0
        for _ in range(3):
            before = manifest(directory)
            assert before['ended'] is False
            assert supervisor.request(dict(operation='recording_control', action='pause', session=session))
            paused = wait_event(events, 'recording_paused')
            assert paused['session'] == session
            assert paused['capture_gate'] == 'closed'
            assert paused['upload_gate'] == 'draining_saved_audio'
            assert paused['control_revision'] > last_revision
            last_revision = paused['control_revision']
            paused_bytes = paused['fixture_written_bytes']
            assert paused_bytes >= started['fixture_written_bytes']
            time.sleep(0.08)
            stable = manifest(directory)
            assert stable['ended'] is False
            pcm_path = directory / 'mic-raw-000000.pcm'
            size_during_pause = pcm_path.stat().st_size
            time.sleep(0.08)
            assert pcm_path.stat().st_size == size_during_pause
            assert child.poll() is None, 'pause must keep the original helper process alive'
            assert supervisor.forced_reason is None

            assert supervisor.request(dict(operation='recording_control', action='resume', session=session))
            resumed = wait_event(events, 'recording_resumed')
            assert resumed['session'] == session
            assert resumed['capture_gate'] == 'open'
            assert resumed['fresh_synthetic_pcm'] is True
            assert resumed['control_revision'] > last_revision
            last_revision = resumed['control_revision']
            assert resumed['fixture_written_bytes'] > paused_bytes
            assert manifest(directory)['ended'] is False

        assert supervisor.request(dict(operation='recording_control', action='finish', session=session))
        stopped = wait_event(events, 'stopped')
        assert stopped['session'] == session and stopped['cache_id'] == cache_id
        assert stopped['reason'] == 'user_finish'
        assert stopped['network'] is False and stopped['raw_audio_saved'] is True
        child.wait(timeout=4)
        reader.join(timeout=1)
        final = manifest(directory)
        assert child.returncode == 0
        assert final['ended'] is True and final['written_bytes'] == stopped['fixture_written_bytes']
        assert final['written_bytes'] > started['fixture_written_bytes']
        assert supervisor.forced_reason is None
        assert not reader_errors, reader_errors
        assert child.stderr.read() == ''
        return {
            'checks': ['real_swift_signal_installation', 'python_supervisor_unix_datagram_ack',
                       'same_helper_pause_resume_pause_resume_finish', 'unsealed_original_journal_during_pause',
                       'fresh_synthetic_pcm_before_resume_ack'],
            'session': session,
            'cache_id': cache_id,
            'pause_revisions': last_revision // 2,
            'final_written_bytes': final['written_bytes'],
            'ended_only_after_finish': final['ended'],
            'capture': False,
            'network': False,
        }
    finally:
        if child.poll() is None:
            try:
                supervisor.stop()
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=2)
        supervisor.close()
        ack_channel.close()
        reader.join(timeout=1)
        if child.stdout:
            child.stdout.close()
        if child.stderr:
            child.stderr.close()


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: capture_protocol_integration.py <offline-helper-binary> <project-root>')
    helper = Path(sys.argv[1]).resolve()
    project = Path(sys.argv[2]).resolve()
    result = run(helper, project)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
