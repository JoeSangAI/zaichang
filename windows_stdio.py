"""Bounded stdin transport for Windows Proactor loops and anonymous pipes."""
import asyncio
import threading


class StdinTransport(asyncio.ReadTransport):
    def __init__(self, loop, protocol, stream):
        super().__init__()
        self.loop, self.protocol, self.stream = loop, protocol, stream
        self.stopped = threading.Event()
        self.readable = threading.Event(); self.readable.set()
        self.pending = threading.Semaphore(4)
        protocol.connection_made(self)
        threading.Thread(target=self._read, daemon=True).start()

    def pause_reading(self): self.readable.clear()
    def resume_reading(self): self.readable.set()
    def is_closing(self): return self.stopped.is_set()
    def close(self): self.stopped.set(); self.readable.set()

    def _deliver(self, chunk):
        try:
            if not self.stopped.is_set():
                if chunk: self.protocol.data_received(chunk)
                else: self.protocol.eof_received()
        finally: self.pending.release()

    def _read(self):
        while not self.stopped.is_set():
            self.readable.wait()
            if self.stopped.is_set(): return
            chunk = self.stream.read1(65536)
            self.pending.acquire()
            if self.stopped.is_set(): return
            try: self.loop.call_soon_threadsafe(self._deliver, chunk)
            except RuntimeError: return
            if not chunk: return
