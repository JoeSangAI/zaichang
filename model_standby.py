"""Keyless local preparation; retain our native process until an explicit UI start.

No download, microphone, Keychain or ASR. Preparation never writes a recording
budget or retries. Cancel/timeout terminate only the process we created.
"""
import json
import subprocess
import threading
import queue
import time

PREPARATION_TIMEOUT = 180


class ModelStandby:
    def __init__(self, binary, directory, embedding, publish, timeout=PREPARATION_TIMEOUT):
        self.publish = publish
        self.timeout = timeout
        self.child = subprocess.Popen([str(binary), '--prepare-standby', str(directory), str(embedding)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, start_new_session=True)
        self.ready = False

    def prepare(self):
        messages = queue.Queue(maxsize=32)
        def read():
            try:
                for line in self.child.stdout:
                    event = json.loads(line)
                    messages.put(event, timeout=2)
                    if event.get('type') == 'preparation' and event.get('state') == 'ready':
                        return
            except (ValueError, OSError, queue.Full):
                pass
            messages.put({'type': 'preparation', 'state': 'failed', 'code': 'model_preparation_failed'})
        reader = threading.Thread(target=read, daemon=True)
        reader.start()
        began = time.monotonic()
        track = 'mic'
        while time.monotonic() - began < self.timeout:
            try:
                event = messages.get(timeout=1)
            except queue.Empty:
                self.publish({'type': 'preparation', 'state': 'progress', 'track': track,
                    'elapsed_seconds': time.monotonic()-began, 'capture': False, 'network': False})
                continue
            if event.get('type') != 'preparation' or event.get('state') == 'failed':
                raise ValueError('model_preparation_failed')
            track = event.get('track', track)
            self.publish(event)
            if event.get('state') == 'ready':
                reader.join(timeout=2)
                self.ready = True
                return
        raise ValueError('model_preparation_timeout')

    def release_only(self):
        if not self.ready:
            raise ValueError('model_preparation_not_ready')
        self.child.stdin.write(json.dumps({'preparation_only': True})+'\n')
        self.child.stdin.flush()
        self.child.stdin.close()
        for line in self.child.stdout:
            self.publish(json.loads(line))
        self.child.wait(timeout=5)

    def close(self):
        if self.child.poll() is None:
            self.child.terminate()
            try:
                self.child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait(timeout=3)
        for stream in (self.child.stdin, self.child.stdout):
            if stream and not stream.closed:
                stream.close()
