"""Explicit live subscription probe; never reads keys or sends meeting audio."""
from __future__ import annotations
import argparse
import asyncio
import hashlib
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from codex_runtime import CodexRuntime, RuntimeErrorCode


async def completed(runtime, thread, turn, events):
    while True:
        message = await runtime.event(thread, timeout=180)
        params = message.get("params", {})
        events.append({"method": message.get("method"),
                       "turn_id": params.get("turnId") or (params.get("turn") or {}).get("id"),
                       "at": time.monotonic()})
        if message.get("method") == "turn/completed" and params["turn"]["id"] == turn:
            return params["turn"]


async def probe(out):
    report = {"schema": 1, "kind": "live_codex_subscription_probe", "checks": {},
              "meeting_audio_sent": False, "external_generation_called": False}
    out.mkdir(parents=True, exist_ok=True)
    def save():
        (out / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    report["source_sha256"] = hashlib.sha256((ROOT / "README.md").read_bytes()).hexdigest()
    try:
        async with CodexRuntime() as runtime:
            report["checks"]["initialize"] = True
            account = await runtime.request("account/read", {"refreshToken": False})
            report["account_type"] = (account.get("account") or {}).get("type")
            if report["account_type"] != "chatgpt":
                raise RuntimeErrorCode("subscription_account_required")
            a, b = await asyncio.gather(runtime.start_thread(str(ROOT)),
                                       runtime.start_thread(str(ROOT), ephemeral=True))
            aid, bid = a["thread"]["id"], b["thread"]["id"]
            report["threads"] = {"foreground": aid, "background": bid}
            report["model"] = a.get("model")
            report["reasoning_effort"] = a.get("reasoningEffort")
            skills = await runtime.request("skills/list", {"cwds": [str(ROOT)]})
            report["skills_response_received"] = isinstance(skills, dict)
            report["skill_count"] = sum(len(row.get("skills", [])) for row in skills.get("data", []))
            mcp = await runtime.request("mcpServerStatus/list", {"limit": 100}, timeout=60)
            report["mcp_servers"] = [{"name": s.get("name"), "auth_status": s.get("authStatus"),
                                       "tool_count": len(s.get("tools", {}))} for s in mcp.get("data", [])]
            common = "这是在场接入的只读验收。不要写文件、联网、读凭据、启动其他Agent或调用收费服务。"
            # Both are real source inspections. Cancellation tests a real active turn.
            ta, tb = await asyncio.gather(
                runtime.start_turn(aid, common + "请实际读取当前目录README.md，用一句中文说明正式App路径与QA构建入口。"),
                runtime.start_turn(bid, common + "请实际检查native/MeetingCoarseRefinement.swift里prepareRequest和project两个函数，比较人物保护与正文保护的关系。"))
            at, bt = ta["turn"]["id"], tb["turn"]["id"]
            report["checks"]["independent_active_turns"] = aid != bid and at != bt
            save()
            print("two_turns_started", flush=True)
            ea, eb = [], []
            wa = asyncio.create_task(completed(runtime, aid, at, ea))
            wb = asyncio.create_task(completed(runtime, bid, bt, eb))
            await runtime.interrupt(bid, bt)
            done_a, done_b = await asyncio.gather(wa, wb)
            report["foreground_status"] = done_a["status"]
            report["background_status"] = done_b["status"]
            report["checks"]["interrupt_isolated"] = done_a["status"] == "completed" and done_b["status"] == "interrupted"
            report["events"] = {"foreground": ea, "background": eb}
            history = await runtime.request("thread/turns/list", {"threadId": aid, "itemsView": "full"})
            items = [item for turn in history.get("data", []) for item in turn.get("items", [])]
            report["item_types"] = sorted({i.get("type", "") for i in items})
            report["checks"]["actual_tool_used"] = any(i.get("type") in {"commandExecution", "mcpToolCall", "dynamicToolCall"} for i in items)
            report["foreground_answer"] = "\n".join(i.get("text", "") for i in items if i.get("type") == "agentMessage")
            save()
        # A new process resumes a persisted thread; it does not replay the first turn.
        async with CodexRuntime() as second:
            resumed = await second.request("thread/resume", {"threadId": aid,
                "cwd": str(ROOT), "approvalPolicy": "on-request", "sandbox": "read-only"})
            report["checks"]["resume_same_thread"] = resumed["thread"]["id"] == aid
            follow = await second.start_turn(aid, "接着刚才的结果，只回答QA构建入口。无需再用工具。")
            ef = []
            final = await completed(second, aid, follow["turn"]["id"], ef)
            report["checks"]["followup_completed"] = final["status"] == "completed"
            report["resume_events"] = ef
        report["ok"] = all(report["checks"].values())
        save()
        print(json.dumps({"ok": report["ok"], "checks": report["checks"], "model": report.get("model")}, ensure_ascii=False), flush=True)
    except Exception as exc:
        report["ok"] = False
        report["error"] = exc.code if isinstance(exc, RuntimeErrorCode) else type(exc).__name__
        save()
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", action="store_true", help="explicitly authorize this subscription-only probe")
    parser.add_argument("--output", type=Path, default=ROOT / ".runtime/codex-integration-1021")
    args = parser.parse_args()
    if not args.live:
        parser.error("--live is required; this probe starts real Codex turns")
    asyncio.run(probe(args.output))
