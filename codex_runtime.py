"""Local Codex app-server transport. Codex owns reasoning and native tools; the app owns durable chat history.

No credential files are read, no provider fallback is selected, and reconnecting
never replays turns. Callers route approval requests to the appropriate task.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
from collections import defaultdict, deque
from typing import Any, Awaitable, Callable


class RuntimeErrorCode(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


class CodexRuntime:
    def __init__(self, executable: str = "codex", *,
                 on_request: Callable[[str, dict], Awaitable[dict]] | None = None,
                 experimental_api: bool = True):
        self.executable = executable
        self.on_request = on_request
        self.experimental_api = experimental_api
        self.process = None
        self._next_id = 0
        self._pending: dict[int, asyncio.Future] = {}
        self._events: dict[str, deque] = defaultdict(deque)
        self._event_failures: dict[str, str] = {}
        self._changed = asyncio.Condition()
        self._write_lock = asyncio.Lock()
        self._workers: set[asyncio.Task] = set()
        self._reader = None
        self._stderr = None
        self.closed = True
        self.failure: str | None = None
        self.uncertain_starts: set[str] = set()

    async def start(self):
        if self.process is not None:
            raise RuntimeErrorCode("already_started")
        self.process = await asyncio.create_subprocess_exec(
            self.executable, "app-server", "--listen", "stdio://",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE, limit=8 * 1024 * 1024)
        self.closed = False
        self._reader = asyncio.create_task(self._read())
        self._stderr = asyncio.create_task(self._drain_stderr())
        try:
            params = {"clientInfo": {"name": "zaichang", "title": "在场", "version": "0.1.0"}}
            if self.experimental_api:
                params["capabilities"] = {"experimentalApi": True}
            result = await self.request("initialize", params)
            await self._send({"method": "initialized", "params": {}})
            return result
        except BaseException:
            await self.close()
            raise

    async def _drain_stderr(self):
        # Diagnostic output may contain paths/context; drain without persisting.
        while await self.process.stderr.read(8192):
            pass

    async def _send(self, message):
        if self.closed:
            raise RuntimeErrorCode(self.failure or "runtime_closed")
        async with self._write_lock:
            self.process.stdin.write(json.dumps(message, ensure_ascii=False).encode() + b"\n")
            try:
                await self.process.stdin.drain()
            except (BrokenPipeError, ConnectionResetError) as exc:
                raise RuntimeErrorCode("runtime_disconnected") from exc

    async def request(self, method: str, params: dict | None = None, *, timeout: float = 30):
        self._next_id += 1
        request_id = self._next_id
        future = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        try:
            await self._send({"id": request_id, "method": method, "params": params or {}})
            return await asyncio.wait_for(future, timeout)
        except (asyncio.TimeoutError, asyncio.CancelledError) as exc:
            # A lost response is not evidence that the server did nothing.
            # Keep the thread blocked against another start in this connection;
            # callers must report interruption, never replay the prompt.
            if method == "turn/start" and params and params.get("threadId"):
                self.uncertain_starts.add(params["threadId"])
            if isinstance(exc, asyncio.CancelledError):
                raise
            raise RuntimeErrorCode("rpc_outcome_unknown") from exc
        finally:
            self._pending.pop(request_id, None)

    async def _answer(self, message):
        try:
            if self.on_request is None:
                raise RuntimeErrorCode("approval_ui_unavailable")
            params = dict(message.get("params", {}))
            params["_serverRequestId"] = message["id"]
            result = await self.on_request(message["method"], params)
            await self._send({"id": message["id"], "result": result})
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            # Never silently grant permissions when no approval UI is attached.
            with contextlib.suppress(Exception):
                await self._send({"id": message["id"], "error": {
                    "code": -32000, "message": exc.code if isinstance(exc, RuntimeErrorCode) else "approval_ui_unavailable"}})

    async def _read(self):
        try:
            while line := await self.process.stdout.readline():
                message = json.loads(line)
                if not isinstance(message, dict):
                    raise ValueError("invalid_message")
                if "method" in message and "id" in message:
                    task = asyncio.create_task(self._answer(message))
                    self._workers.add(task)
                    task.add_done_callback(self._workers.discard)
                elif "id" in message:
                    future = self._pending.get(message["id"])
                    if future is not None and not future.done():
                        if "error" in message:
                            error = message["error"]
                            detail = str(error.get("message", "")).lower()
                            missing_thread = "thread" in detail and ("not found" in detail or "no such thread" in detail)
                            future.set_exception(RuntimeErrorCode("thread_not_found" if missing_thread else
                                "rpc_error_" + str(error.get("code", "unknown"))))
                        else:
                            future.set_result(message.get("result"))
                else:
                    params = message.get("params", {})
                    thread = params.get("threadId") or (params.get("thread") or {}).get("id") or ""
                    if not thread:
                        # Global notifications have no consumer; retaining them
                        # would eventually take down every task in this runtime.
                        continue
                    async with self._changed:
                        if thread in self._event_failures:
                            continue
                        queue = self._events[thread]
                        # A slow consumer must not cause unlimited memory growth.
                        # Drop deltas first; item/completed carries the full text.
                        if len(queue) >= 2048:
                            delta = next((i for i, v in enumerate(queue)
                                          if v.get("method", "").endswith("/delta")), None)
                            if delta is None:
                                self._event_failures[thread] = "event_consumer_overflow"
                                queue.clear()
                                self._changed.notify_all()
                                continue
                            del queue[delta]
                        queue.append(message)
                        self._changed.notify_all()
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            self.failure = exc.code if isinstance(exc, RuntimeErrorCode) else "protocol_error"
        finally:
            self.closed = True
            for future in list(self._pending.values()):
                if not future.done():
                    future.set_exception(RuntimeErrorCode(self.failure or "runtime_disconnected"))
            async with self._changed:
                self._changed.notify_all()

    async def event(self, thread_id: str, *, timeout: float = 120):
        async def take():
            async with self._changed:
                while not self._events[thread_id]:
                    if thread_id in self._event_failures:
                        raise RuntimeErrorCode(self._event_failures[thread_id])
                    if self.closed:
                        raise RuntimeErrorCode(self.failure or "runtime_disconnected")
                    await self._changed.wait()
                return self._events[thread_id].popleft()
        return await asyncio.wait_for(take(), timeout)

    async def start_thread(self, cwd: str, *, ephemeral: bool = True,
                           sandbox: str = "read-only", approval_policy: str = "on-request",
                           dynamic_tools: list[dict] | None = None,
                           developer_instructions: str | None = None,
                           model: str | None = None, effort: str | None = None):
        # Explicit per-purpose defaults apply only to new threads; existing turns retain their settings.
        params = {"cwd": cwd, "approvalPolicy": approval_policy,
                  "sandbox": sandbox, "ephemeral": True,
                  "config": {"features.multi_agent": False, "features.multi_agent_v2": False}}
        if model is not None:
            params['model'] = model
        if effort is not None:
            params['config']['model_reasoning_effort'] = effort
        if model is not None:
            params['config']['service_tier'] = 'default'
        if dynamic_tools:
            if not self.experimental_api:
                raise RuntimeErrorCode("dynamic_tools_require_experimental_api")
            params["dynamicTools"] = dynamic_tools
        if developer_instructions:
            params["developerInstructions"] = developer_instructions
        result = await self.request("thread/start", params)
        return result

    async def start_turn(self, thread_id: str, text: str, *, output_schema: dict | None = None,
                         execution_directory: str | None = None):
        if thread_id in self.uncertain_starts:
            raise RuntimeErrorCode("turn_start_requires_reconciliation")
        params = {"threadId": thread_id, "input": [{"type": "text", "text": text}],
                  "approvalPolicy": "never", "sandboxPolicy": {"type": "readOnly", "networkAccess": output_schema is None}}
        if execution_directory and output_schema is None:
            params.update(cwd=execution_directory, approvalPolicy="on-request",
                          approvalsReviewer="user",
                          sandboxPolicy={"type": "workspaceWrite", "writableRoots": [execution_directory],
                                         "networkAccess": True})
        if output_schema:
            params["outputSchema"] = output_schema
        return await self.request("turn/start", params)

    async def steer(self, thread_id: str, turn_id: str, text: str):
        return await self.request("turn/steer", {"threadId": thread_id, "expectedTurnId": turn_id,
            "input": [{"type": "text", "text": text}]})

    async def interrupt(self, thread_id: str, turn_id: str):
        return await self.request("turn/interrupt", {"threadId": thread_id, "turnId": turn_id})

    async def close(self):
        if self.process is None:
            return
        if self.process.returncode is None:
            self.process.stdin.close()
            try:
                await asyncio.wait_for(self.process.wait(), 5)
            except asyncio.TimeoutError:
                self.process.terminate()
                try:
                    await asyncio.wait_for(self.process.wait(), 3)
                except asyncio.TimeoutError:
                    self.process.kill()
                    await self.process.wait()
        for task in [self._reader, self._stderr, *self._workers]:
            if task is not None:
                task.cancel()
        await asyncio.gather(*(t for t in [self._reader, self._stderr, *self._workers]
                               if t is not None), return_exceptions=True)
        self.closed = True

    async def __aenter__(self):
        await self.start()
        return self

    async def __aexit__(self, *_):
        await self.close()
