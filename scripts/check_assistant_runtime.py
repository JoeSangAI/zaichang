"""Bounded live-subscription E2E for the local assistant scheduler.

Requests a scope limited to this checkout's README/AGENTS and public web research.
No meeting audio or credentials are passed. Actual tool behavior still requires
receipt review; the configured user harness is inherited. Fresh runs allow six turns
and explicit continuation runs allow four additional turns. Result data stays in
.runtime/ and contains short assistant replies plus protocol facts.
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import shutil
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from assistant_runtime import AssistantRuntime, AssistantStore
from codex_runtime import CodexRuntime, RuntimeErrorCode

PROBE_SCOPE = ("This is a bounded integration acceptance test, not a real project task. "
               "Read only this checkout README.md/AGENTS.md and public webpages needed for the supplied public question. "
               "Do not access workbench/desk APIs, private local files, private meeting archives, credentials, or messaging tools. "
               "Do not contact people, write files, call external model providers, or modify global settings. "
               "A local standard-library time.sleep command is allowed only for the cancellation probe. "
               "These restrictions apply to every delegated task.\n\n")
MAX_TURN_REQUESTS = 6
TERMINAL = {"completed", "interrupted", "cancelled", "failed"}


class ProbeRuntime(CodexRuntime):
    def __init__(self, probe, **kwargs):
        self.probe = probe
        super().__init__(**kwargs)

    async def start_thread(self, cwd, **options):
        options["developer_instructions"] = options.get("developer_instructions", "") + "\n\n" + PROBE_SCOPE
        self.probe["thread_starts"].append({
            "sandbox": options.get("sandbox"),
            "approval_policy": options.get("approval_policy"),
            "dynamic_tools": [tool.get("name") for tool in options.get("dynamic_tools", [])],
        })
        return await super().start_thread(cwd, **options)

    async def start_turn(self, thread_id, text, *, output_schema=None):
        if self.probe["turn_requests"] >= self.probe.get("turn_limit", MAX_TURN_REQUESTS):
            raise RuntimeErrorCode("probe_turn_limit")
        self.probe["turn_requests"] += 1
        self.probe["turn_log"].append({"thread_id": thread_id,
                                        "prompt_sha256": hashlib.sha256(text.encode()).hexdigest(),
                                        "output_schema": bool(output_schema)})
        return await super().start_turn(thread_id, PROBE_SCOPE + text, output_schema=output_schema)

    async def event(self, thread_id, *, timeout=120):
        event = await super().event(thread_id, timeout=timeout)
        params = event.get("params") or {}
        item = params.get("item") or {}
        if item.get("type") in ("commandExecution", "execCommand", "mcpToolCall", "dynamicToolCall"):
            self.probe["tool_events"].append({"thread_id": thread_id,
                "method": event.get("method"), "item_type": item.get("type"),
                "item_id": item.get("id")})
        return event


def short(text, limit=700):
    return str(text or "")[:limit]


def task_summary(service, workspace_id):
    return [{"id": row["id"], "title": row["title"], "origin": row["origin"],
             "status": row["status"], "lane": row["lane"], "thread_id": row["thread_id"],
             "turn_id": row["turn_id"], "parent_task_id": row["parent_task_id"],
             "depth": row["depth"], "error": row["error"]}
            for row in service.store.tasks(workspace_id)]


def assistant_text(service, task_id):
    return [short(row["text"]) for row in service.store.db.execute(
        "SELECT text FROM message WHERE task_id=? AND role='assistant' AND origin!='scout' ORDER BY created", (task_id,))]


async def wait_for(service, workspace_id, predicate, *, timeout=180):
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        # Do not silently authorize an action in a headless probe.
        for approval_id, approval in list(service.approvals.items()):
            policy = getattr(service, "probe_approval_policy", None)
            decision = await policy(approval) if policy else "decline"
            service.probe_artifact["approval_decisions"].append({"kind": approval["kind"],
                "title": approval["title"], "task_id": approval["task_id"], "decision": decision})
            await service.cmd_approval(workspace_id, {"approval_id": approval_id, "decision": decision})
        tasks = service.store.tasks(workspace_id)
        found = predicate(tasks)
        if found:
            return found
        await asyncio.sleep(.15)
    raise TimeoutError("task_wait_timeout")


async def wait_tasks_terminal(service, workspace_id, task_ids, timeout=180):
    await wait_for(service, workspace_id, lambda rows: all(
        service.store.task(task_id) and service.store.task(task_id)["status"] in TERMINAL
        for task_id in task_ids), timeout=timeout)


async def run_probe(output_dir: Path):
    output_dir.mkdir(parents=True, exist_ok=True)
    run_id = uuid.uuid4().hex[:10]
    store = AssistantStore(output_dir / run_id / "store")
    observed = {"turn_requests": 0, "turn_log": [], "thread_starts": [], "tool_calls": [],
                "tool_events": [], "approval_decisions": [], "turn_limit": MAX_TURN_REQUESTS}
    report = {"schema": 1, "kind": "assistant_runtime_live_e2e",
              "run_id": run_id, "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "source": {"root": str(ROOT),
                         "readme_sha256": hashlib.sha256((ROOT / "README.md").read_bytes()).hexdigest(),
                         "agents_sha256": hashlib.sha256((ROOT / "AGENTS.md").read_bytes()).hexdigest()},
              "limits": {"max_turn_requests": MAX_TURN_REQUESTS, "meeting_audio_sent": False,
                         "private_context_access_verified": False, "external_provider_calls_verified": False,
                         "requested_scope": "checkout docs/public webpages; no private workbench or meeting access"},
              "checks": {}, "phases": {}, "probe": observed}

    def save():
        path = output_dir / run_id / "result.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

    service = AssistantRuntime(store, ROOT,
        runtime_factory=lambda **kwargs: ProbeRuntime(observed, **kwargs))
    service.probe_artifact = report["probe"]

    async def capture_request(method, params):
        if method == "item/tool/call":
            observed["tool_calls"].append({"method": method, "thread_id": params.get("threadId"),
                "tool": params.get("tool"), "arguments": params.get("arguments")})
        return await service._on_server_request(method, params)

    # Install the observer callback before the one-time App Server handshake.
    service.runtime_factory = lambda **kwargs: ProbeRuntime(observed, on_request=capture_request)
    workspace_id = f"assistant-e2e-{run_id}"
    try:
        bound = await service.bind(workspace_id, {"session_id": f"e2e-session-{run_id}",
            "cache_id": f"e2e-cache-{run_id}", "title": "本地公开文档验收"})
        workspace_id = bound["workspace_id"]
        if service.runtime is None or service.runtime_status != "ready":
            raise RuntimeErrorCode("app_server_not_ready:" + service.runtime_message)
        account = await service.runtime.request("account/read", {"refreshToken": False})
        account_type = (account.get("account") or {}).get("type")
        report["subscription_account_type"] = account_type
        if account_type != "chatgpt":
            raise RuntimeErrorCode("chatgpt_subscription_required")
        report["checks"]["chatgpt_subscription"] = True
        report["checks"]["app_server_initialize"] = True
        save()

        parent_prompt = (
            "仅使用当前项目内的公开README.md与AGENTS.md，直接读取它们，不写文件、不联网、不调用任何外部服务。"
            "请先用一句话核对正式App入口和QA验收入口。然后必须调用 assistant_job_spawn 建一个独立只读任务，"
            "标题为‘README测试入口核对’，目标是读取README.md提取Python测试命令和QA构建产物路径，最多两句话回答；"
            "随后调用 assistant_job_list 确认任务已创建，并在主回复中说明子任务ID。不要继续派生任务。"
        )
        parent = await service.cmd_send(workspace_id, {"text": parent_prompt})
        parent_id = parent["task_id"]
        def parent_and_child(rows):
            children = [r for r in rows if r["parent_task_id"] == parent_id]
            row = service.store.task(parent_id)
            if row and row["status"] in TERMINAL and children and all(c["status"] in TERMINAL for c in children):
                return children
            return None
        children = await wait_for(service, workspace_id, parent_and_child, timeout=240)
        report["phases"]["native_dynamic_spawn"] = {"parent_id": parent_id,
            "parent_status": service.store.task(parent_id)["status"],
            "children": [{"id": c["id"], "origin": c["origin"], "status": c["status"],
                          "thread_id": c["thread_id"], "answer": assistant_text(service, c["id"])} for c in children],
            "parent_answer": assistant_text(service, parent_id)}
        report["checks"]["native_dynamic_tool_called"] = any(c["tool"] == "assistant_job_spawn" for c in observed["tool_calls"])
        report["checks"]["native_job_list_called"] = any(c["tool"] == "assistant_job_list" for c in observed["tool_calls"])
        report["checks"]["child_thread_isolated"] = bool(children and all(
            c["thread_id"] and c["thread_id"] != service.store.task(parent_id)["thread_id"] for c in children))
        report["checks"]["child_read_task_completed"] = bool(children and all(c["status"] == "completed" for c in children))
        report["checks"]["background_did_not_change_reply_focus"] = service.store.workspace(workspace_id)["active_task_id"] == parent_id
        save()

        long_prompt = ("请只读完整检查README.md和AGENTS.md，整理这两个公开项目文件的目录责任、QA步骤和本地使用边界，"
                       "逐项核对文件原文，给一份约六点的清单；不要写入、联网或运行命令。")
        short_prompt = "只读README.md，告诉我Python单元测试的命令，简短回答，不运行命令。"
        first = await service.cmd_send(workspace_id, {"text": long_prompt, "new_task": True})
        second = await service.cmd_send(workspace_id, {"text": short_prompt, "new_task": True})
        first_id, second_id = first["task_id"], second["task_id"]
        await wait_for(service, workspace_id, lambda rows: (
            service.store.task(first_id)["status"] == "running" and service.store.task(first_id)["turn_id"] and
            service.store.task(second_id)["status"] == "running" and service.store.task(second_id)["turn_id"]), timeout=60)
        pre_cancel = {"first_status": service.store.task(first_id)["status"],
                      "first_turn_id": service.store.task(first_id)["turn_id"],
                      "second_status": service.store.task(second_id)["status"],
                      "second_turn_id": service.store.task(second_id)["turn_id"]}
        await service.cmd_cancel(workspace_id, {"task_id": first_id})
        await wait_tasks_terminal(service, workspace_id, [first_id, second_id], timeout=180)
        report["phases"]["independent_cancel"] = {"cancelled_task": first_id,
            "other_task": second_id, "pre_cancel": pre_cancel,
            "cancelled_final": service.store.task(first_id)["status"],
            "other_final": service.store.task(second_id)["status"],
            "other_answer": assistant_text(service, second_id)}
        report["checks"]["cancelled_active_turn"] = pre_cancel["first_turn_id"] is not None and service.store.task(first_id)["status"] == "interrupted"
        report["checks"]["cancel_did_not_interrupt_other_task"] = service.store.task(second_id)["status"] == "completed"
        save()

        # Feed one exact, short excerpt from README.md as a final meeting-context
        # segment. This exercises the scout/worker path without reading any meeting.
        excerpt = "仅改UI时可用 scripts/build_offline.py --ui-only。产物位于 .runtime/build/会议助理开发QA.app；QA使用独立标识与合成数据。"
        if excerpt not in (ROOT / "README.md").read_text():
            excerpt = next(line.strip() for line in (ROOT / "README.md").read_text().splitlines()
                           if "QA使用独立标识与合成数据" in line)
        default_off = not bool(store.workspace(workspace_id)["proactive"])
        report["checks"]["proactive_default_off"] = default_off
        await service.cmd_proactive(workspace_id, {"enabled": True})
        await service.cmd_context(workspace_id, {"title": "公开文档中的QA使用方式",
            "session_id": f"e2e-session-{run_id}", "cache_id": f"e2e-cache-{run_id}",
            "segments": [{"id": "readme-excerpt-1", "revision": 1,
                          "speaker": "文档摘录", "text": excerpt, "final": True}],
            "notes": "本次仅使用项目README公开内容验证主动链。"})
        scout_rows = await wait_for(service, workspace_id,
            lambda rows: next((r for r in rows if r["origin"] == "scout" and r["status"] in TERMINAL), None), timeout=120)
        scout_id = scout_rows["id"]
        await wait_for(service, workspace_id, lambda rows: all(r["status"] in TERMINAL for r in rows
            if r["origin"] == "proactive" and r["parent_task_id"] == scout_id), timeout=180)
        proactive_children = [r for r in service.store.tasks(workspace_id)
                              if r["origin"] == "proactive" and r["parent_task_id"] == scout_id]
        scout_snapshot = await service._snapshot(workspace_id, announce=False)
        report["phases"]["proactive_chain"] = {"scout_id": scout_id,
            "scout_status": service.store.task(scout_id)["status"],
            "scout_internal_messages_hidden": not any(m["origin"] == "scout" for m in scout_snapshot["messages"]),
            "workers": [{"id": r["id"], "status": r["status"], "thread_id": r["thread_id"],
                         "answer": assistant_text(service, r["id"])} for r in proactive_children],
            "context_excerpt": excerpt}
        report["checks"]["proactive_context_scout_ran"] = service.store.task(scout_id)["status"] == "completed"
        report["checks"]["proactive_worker_chain"] = bool(proactive_children and all(r["status"] == "completed" for r in proactive_children))
        report["checks"]["scout_internal_content_hidden"] = report["phases"]["proactive_chain"]["scout_internal_messages_hidden"]
        await service.cmd_proactive(workspace_id, {"enabled": False})
        report["checks"]["proactive_default_off_then_explicit_on_off"] = not service.store.workspace(workspace_id)["proactive"]
        save()

        dynamic_names = [name for row in observed["thread_starts"] for name in row["dynamic_tools"]]
        report["checks"]["dynamic_tools_registered_on_codex_threads"] = "assistant_job_spawn" in dynamic_names
        report["checks"]["turn_request_limit_respected"] = observed["turn_requests"] <= MAX_TURN_REQUESTS
        report["tasks"] = task_summary(service, workspace_id)
        report["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        report["ok"] = all(report["checks"].values())
        save()
        print(json.dumps({"ok": report["ok"], "checks": report["checks"],
                          "turn_requests": observed["turn_requests"],
                          "result": str(output_dir / run_id / "result.json")}, ensure_ascii=False), flush=True)
        return report
    except Exception as exc:
        report["ok"] = False
        report["error"] = exc.code if isinstance(exc, RuntimeErrorCode) else (str(exc) or type(exc).__name__)
        report["tasks"] = task_summary(service, workspace_id)
        save()
        print(json.dumps({"ok": False, "error": report["error"],
                          "turn_requests": observed["turn_requests"],
                          "result": str(output_dir / run_id / "result.json")}, ensure_ascii=False), flush=True)
        raise
    finally:
        try:
            await service.cmd_proactive(workspace_id, {"enabled": False})
        except Exception:
            pass
        await service.shutdown()
        store.close()


async def run_continuation(previous_result: Path):
    previous_result = previous_result.expanduser().resolve()
    previous = json.loads(previous_result.read_text())
    store_path = previous_result.parent / "store"
    if not (store_path / "assistant.sqlite3").is_file():
        raise FileNotFoundError("previous assistant store is missing")
    if Path(previous["source"]["root"]).resolve() != ROOT:
        raise ValueError("previous probe belongs to another checkout")
    continuation_id = "continue-" + uuid.uuid4().hex[:8]
    output_dir = previous_result.parent / continuation_id
    output_dir.mkdir(parents=True, exist_ok=True)
    store = AssistantStore(store_path)
    observed = {"turn_requests": 0, "turn_limit": 4, "turn_log": [], "thread_starts": [],
                "tool_calls": [], "tool_events": [], "approval_decisions": []}
    report = {"schema": 1, "kind": "assistant_runtime_live_e2e_continuation",
        "run_id": continuation_id, "continuation_of": str(previous_result),
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "limits": {"max_additional_turn_requests": 4, "meeting_audio_sent": False,
                   "private_context_access_verified": False, "external_provider_calls_verified": False,
                         "requested_scope": "checkout docs/public webpages; no private workbench or meeting access"},
        "checks": {}, "phases": {}, "probe": observed}

    def save():
        (output_dir / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

    service = AssistantRuntime(store, ROOT)
    service.probe_artifact = report["probe"]

    async def capture_request(method, params):
        if method == "item/tool/call":
            observed["tool_calls"].append({"method": method, "thread_id": params.get("threadId"),
                "tool": params.get("tool"), "arguments": params.get("arguments")})
        return await service._on_server_request(method, params)

    service.runtime_factory = lambda **kwargs: ProbeRuntime(observed, on_request=capture_request)

    async def approval_policy(approval):
        # Explicitly allow only the single harmless local sleep command for this test.
        command = str(approval["params"].get("command") or "")
        if "python3" in command and "time.sleep(15)" in command:
            return "accept"
        return "decline"

    service.probe_approval_policy = approval_policy
    workspace_row = store.db.execute("SELECT * FROM workspace ORDER BY updated DESC LIMIT 1").fetchone()
    if not workspace_row:
        store.close()
        raise ValueError("previous workspace binding missing")
    workspace_id = workspace_row["id"]
    try:
        rebound = await service.bind(workspace_id, {"session_id": workspace_row["session_id"],
            "cache_id": workspace_row["cache_id"], "title": workspace_row["title"]})
        report["workspace_id"] = rebound["workspace_id"]
        if service.runtime is None or service.runtime_status != "ready":
            raise RuntimeErrorCode("app_server_not_ready:" + service.runtime_message)
        account = await service.runtime.request("account/read", {"refreshToken": False})
        account_type = (account.get("account") or {}).get("type")
        report["subscription_account_type"] = account_type
        report["checks"]["chatgpt_subscription"] = account_type == "chatgpt"
        report["checks"]["warm_bind_same_workspace"] = rebound["workspace_id"] == workspace_id
        if account_type != "chatgpt":
            raise RuntimeErrorCode("chatgpt_subscription_required")

        sleep_prompt = (
            "请使用本地命令执行工具运行这条无害命令并等待它结束："
            "python3 -c 'import time; time.sleep(15)'。它只暂停15秒，不联网、不读写文件。"
            "命令运行期间不要提前回答。"
        )
        control_prompt = "只读当前目录README.md，告诉我Python单元测试命令，不要运行任何命令。"
        sleep_task = await service.cmd_send(workspace_id, {"text": sleep_prompt, "new_task": True})
        control_task = await service.cmd_send(workspace_id, {"text": control_prompt, "new_task": True})
        sleep_id, control_id = sleep_task["task_id"], control_task["task_id"]

        def command_started(rows):
            row = service.store.task(sleep_id)
            if not row or not row["thread_id"]:
                return None
            return next((e for e in observed["tool_events"] if e["thread_id"] == row["thread_id"]
                         and e["item_type"] == "commandExecution"
                         and str(e["method"]).endswith("/started")), None)

        started_event = await wait_for(service, workspace_id, command_started, timeout=90)
        before_cancel = {"task_status": service.store.task(sleep_id)["status"],
                         "turn_id": service.store.task(sleep_id)["turn_id"],
                         "tool_event": started_event,
                         "other_status": service.store.task(control_id)["status"]}
        if not before_cancel["turn_id"]:
            raise RuntimeErrorCode("sleep_command_started_without_active_turn")
        await service.cmd_cancel(workspace_id, {"task_id": sleep_id})
        await wait_tasks_terminal(service, workspace_id, [sleep_id, control_id], timeout=120)
        sleep_final = service.store.task(sleep_id)
        control_final = service.store.task(control_id)
        report["phases"]["interrupt_running_command"] = {"sleep_task": sleep_id,
            "control_task": control_id, "before_cancel": before_cancel,
            "sleep_final_status": sleep_final["status"], "sleep_error": sleep_final["error"],
            "control_final_status": control_final["status"],
            "control_answer": assistant_text(service, control_id)}
        report["checks"]["exec_tool_started_before_cancel"] = started_event is not None
        report["checks"]["active_command_interrupted"] = sleep_final["status"] == "interrupted"
        report["checks"]["interrupt_did_not_affect_other_task"] = control_final["status"] == "completed"
        save()

        # Synthetic product-research context used to verify proactive follow-up.
        default_off = not bool(store.workspace(workspace_id)["proactive"])
        report["checks"]["proactive_default_off"] = default_off
        await service.cmd_proactive(workspace_id, {"enabled": True})
        context_text = "我们在讨论ExampleCo，不确定它过去是否做过面向大学生的产品试用活动。"
        await service.cmd_context(workspace_id, {"title": "ExampleCo产品试用调研",
            "session_id": workspace_row["session_id"], "cache_id": workspace_row["cache_id"],
            "segments": [{"id": "synthetic-example-product-question", "revision": 1,
                          "speaker": "Synthetic research prompt", "text": context_text, "final": True}],
            "notes": "Synthetic context; identify the information gap, then let an independent worker verify it."})
        scout = await wait_for(service, workspace_id,
            lambda rows: next((r for r in rows if r["origin"] == "scout" and r["created"] > workspace_row["updated"]
                               and r["status"] in TERMINAL), None), timeout=120)
        await wait_for(service, workspace_id,
            lambda rows: all(r["status"] in TERMINAL for r in rows
                if r["origin"] == "proactive" and r["parent_task_id"] == scout["id"]), timeout=180)
        workers = [r for r in store.tasks(workspace_id)
                   if r["origin"] == "proactive" and r["parent_task_id"] == scout["id"]]
        scout_message = store.db.execute("SELECT text FROM message WHERE task_id=? AND role='assistant' ORDER BY created DESC LIMIT 1",
                                         (scout["id"],)).fetchone()
        report["phases"]["qoder_scout_to_worker"] = {"scout_id": scout["id"],
            "scout_status": scout["status"],
            "scout_proposal_json": short(scout_message["text"] if scout_message else "", 1200),
            "workers": [{"id": row["id"], "title": row["title"], "status": row["status"],
                         "thread_id": row["thread_id"], "answer": assistant_text(service, row["id"])}
                        for row in workers],
            "context": context_text}
        report["checks"]["scout_completed"] = scout["status"] == "completed"
        report["checks"]["scout_created_worker"] = bool(workers)
        report["checks"]["worker_completed"] = bool(workers and all(r["status"] == "completed" for r in workers))
        report["checks"]["turn_request_limit_respected"] = observed["turn_requests"] <= 4
        await service.cmd_proactive(workspace_id, {"enabled": False})
        report["checks"]["proactive_closed"] = not bool(store.workspace(workspace_id)["proactive"])

        old_cancel = next((row for row in previous.get("tasks", [])
                           if row.get("error") == "completed" and "完整检查README" in row.get("title", "")), None)
        report["baseline"] = {"previous_result": str(previous_result),
            "previous_failed_report_kept_unchanged": True,
            "native_dynamic_spawn_check": previous.get("checks", {}).get("native_dynamic_tool_called", False),
            "native_job_list_check": previous.get("checks", {}).get("native_job_list_called", False),
            "previous_cancel_interrupted": False if old_cancel else None,
            "previous_scout_had_no_proposal": not any(row.get("origin") == "proactive" for row in previous.get("tasks", []))}
        report["checks"]["previous_dynamic_spawn_verified"] = report["baseline"]["native_dynamic_spawn_check"]
        report["checks"]["previous_job_list_verified"] = report["baseline"]["native_job_list_check"]
        report["tasks"] = task_summary(service, workspace_id)
        report["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        report["overall_ok"] = all(report["checks"].values())
        save()
        print(json.dumps({"ok": report["overall_ok"], "checks": report["checks"],
            "additional_turn_requests": observed["turn_requests"],
            "result": str(output_dir / "result.json")}, ensure_ascii=False), flush=True)
        return report
    except Exception as exc:
        report["error"] = exc.code if isinstance(exc, RuntimeErrorCode) else (str(exc) or type(exc).__name__)
        report["tasks"] = task_summary(service, workspace_id)
        report["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        save()
        print(json.dumps({"ok": False, "error": report["error"],
            "additional_turn_requests": observed["turn_requests"],
            "result": str(output_dir / "result.json")}, ensure_ascii=False), flush=True)
        raise
    finally:
        try:
            await service.cmd_proactive(workspace_id, {"enabled": False})
        except Exception:
            pass
        await service.shutdown()
        store.close()


def main():
    parser = argparse.ArgumentParser(description="Run a bounded real-subscription assistant runtime E2E.")
    parser.add_argument("--live", action="store_true", help="starts up to six real Codex subscription turns")
    parser.add_argument("--output", type=Path, default=ROOT / ".runtime/assistant-runtime-e2e-1021")
    parser.add_argument("--continue-from", type=Path, help="continue a prior live run with at most four additional turns")
    args = parser.parse_args()
    if not args.live:
        parser.error("--live is required; this E2E starts real Codex turns")
    if args.continue_from:
        return asyncio.run(run_continuation(args.continue_from))
    return asyncio.run(run_probe(args.output.resolve()))


if __name__ == "__main__":
    main()
