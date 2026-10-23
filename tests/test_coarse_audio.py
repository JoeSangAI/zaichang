import base64
import io
import json
import tempfile
import unittest
import wave
from pathlib import Path
from unittest.mock import Mock, patch

import coarse_audio as coarse


class FakeResponse:
    def __init__(self, payload, url=coarse.API_URL):
        self.payload = payload
        self.url = url

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self, size=-1):
        return self.payload[:size]

    def geturl(self):
        return self.url


class FakeOpener:
    def __init__(self, payload):
        self.payload = payload
        self.calls = []

    def open(self, request, timeout):
        self.calls.append((request, timeout))
        return FakeResponse(self.payload)


class CoarseAudioTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.cache = Path(self.temp.name) / "cache"
        self.cache.mkdir()
        self.pcm = self.cache / "mic-000000.pcm"
        self.pcm.write_bytes(bytes(range(256)) * 125)  # 32,000 bytes = one second

    def request(self, *, units=None, written_bytes=None, budget=1.0):
        return {
            "key": "FAKE-DO-NOT-SEND",
            "request": {
                "schema": 1, "method": "audio_coarse_v1",
                "session": "00000000-0000-0000-0000-000000000001",
                "cache_id": "00000000-0000-0000-0000-000000000002",
                "cache_dir": str(self.cache),
                "source_sha256": "a" * 64, "snapshot_sha256": "b" * 64,
                "budget_yuan": budget,
                "roster": [{"speaker_key": "p1", "name": "甲"}, {"speaker_key": "p2", "name": "乙"}],
                "units": units if units is not None else [
                    {"id": "u1", "source_id": "mic", "text": "明天再确认。", "start": 0.0, "end": 0.5,
                     "speaker_key": "p1", "speaker_name": "甲", "manual": False},
                    {"id": "u2", "source_id": "mic", "text": "对。", "start": 0.5, "end": 1.0,
                     "speaker_key": "p1", "speaker_name": "甲", "manual": True},
                ],
                "audio_tracks": [{"source_id": "mic", "origin_seconds": 0,
                                  "chunks": [str(self.pcm)], "written_bytes": written_bytes or self.pcm.stat().st_size}],
            },
        }

    def result(self, speaker_key="p2"):
        label = coarse._speaker_label(speaker_key, "test")
        return {"units": [{"unit_id": "u1", "text": "明天再确认。", "speaker_key": label}]}, {
            "prompt_tokens": 100, "completion_tokens": 40, "total_tokens": 140,
        }

    def test_short_negative_track_origin_preserves_capture_alignment(self):
        payload = self.request()
        payload["request"]["audio_tracks"][0]["origin_seconds"] = -0.05
        parsed = coarse._parse_request(payload)
        track = parsed["tracks"][0]
        self.assertEqual(track.origin_seconds, -0.05)
        plan = coarse._segment_plan(track)
        self.assertEqual(plan[0][0], -0.05)
        self.assertAlmostEqual(plan[0][2], -0.05)
        payload["request"]["audio_tracks"][0]["origin_seconds"] = -0.251
        with self.assertRaisesRegex(coarse.CoarseAudioError, "invalid_track_origin"):
            coarse._parse_request(payload)

    def test_whitespace_only_units_are_rejected_but_short_speech_is_valid(self):
        for text in ("", "   ", "\t\n"):
            with self.subTest(text=repr(text)), self.assertRaisesRegex(coarse.CoarseAudioError, "invalid_unit_text"):
                coarse._parse_request(self.request(units=[{"unit_id": "blank", "source_id": "mic",
                    "text": text, "start": 0, "end": .2}]))
        parsed = coarse._parse_request(self.request(units=[{"unit_id": "short", "source_id": "mic",
            "text": "嗯", "start": 0, "end": .2}]))
        self.assertEqual([unit["id"] for unit in parsed["units"]], ["short"])

    def test_http_uses_fixed_tls_endpoint_json_mode_and_no_secret_in_body(self):
        payload = json.dumps({"choices": [{"message": {"content": json.dumps(self.result()[0])}}]}).encode()
        opener = FakeOpener(payload)
        pcm_wav = coarse._wav_bytes(self.pcm.read_bytes())
        result, _ = coarse._http_call("secret-key", pcm_wav, "prompt", 2048, opener=opener)
        request, timeout = opener.calls[0]
        body = json.loads(request.data)
        self.assertEqual(request.full_url, coarse.API_URL)
        self.assertEqual(request.get_header("Host"), coarse.API_HOST)
        self.assertEqual(request.get_header("Authorization"), "Bearer secret-key")
        self.assertEqual(body["model"], "qwen3.8-omni-flash")
        self.assertEqual(body["response_format"], {"type": "json_object"})
        self.assertFalse(body["stream"])
        self.assertEqual(body["messages"][0]["role"], "system")
        audio = body["messages"][1]["content"][1]["input_audio"]
        self.assertTrue(audio["data"].startswith("data:audio/wav;base64,"))
        self.assertTrue(wave.open(io.BytesIO(base64.b64decode(audio["data"].split(",", 1)[1]))).getnchannels() == 1)
        self.assertEqual(timeout, coarse.REQUEST_TIMEOUT_SECONDS)
        self.assertEqual(result["units"][0]["unit_id"], "u1")

    def test_http_text_only_request_omits_audio(self):
        payload = json.dumps({"choices": [{"message": {"content": json.dumps({"units": []})}}]}).encode()
        opener = FakeOpener(payload)
        coarse._http_call("synthetic-key", None, "text-only prompt", 8192, opener=opener)
        body = json.loads(opener.calls[0][0].data)
        self.assertEqual(body["model"], coarse.MODEL)
        self.assertEqual(body["messages"][1]["content"], [{"type": "text", "text": "text-only prompt"}])

    def test_transport_errors_preserve_safe_failure_category(self):
        import socket
        import ssl
        import urllib.error
        errors = [(TimeoutError("private details"), "provider_timeout"),
                  (socket.gaierror(-2, "private hostname"), "provider_dns_unavailable"),
                  (ssl.SSLError("private certificate"), "provider_tls_unavailable"),
                  (ConnectionResetError("private endpoint"), "provider_connection_unavailable")]
        for reason, expected in errors:
            opener = Mock()
            opener.open.side_effect = urllib.error.URLError(reason)
            with self.assertRaises(coarse.CoarseAudioError) as caught:
                coarse._http_call("synthetic-key", b"wave", "prompt", 8192, opener=opener)
            self.assertEqual(caught.exception.code, expected)
            self.assertNotIn("private", str(caught.exception))
            self.assertIsNone(caught.exception.diagnostic)

    def test_default_http_opener_retains_hostname_and_certificate_validation(self):
        payload = json.dumps({"choices": [{"message": {"content": json.dumps(self.result()[0])}}]}).encode()
        with patch.object(coarse.urllib.request, "build_opener", return_value=FakeOpener(payload)) as factory:
            coarse._http_call("synthetic-key", coarse._wav_bytes(self.pcm.read_bytes()), "prompt", 2048)
        handlers = factory.call_args.args
        tls = next(h for h in handlers if isinstance(h, coarse.urllib.request.HTTPSHandler))
        self.assertTrue(tls._context.check_hostname)
        self.assertEqual(tls._context.verify_mode, coarse.ssl.CERT_REQUIRED)
        self.assertGreater(len(tls._context.get_ca_certs()), 0)

    def test_truncated_provider_json_is_rejected_explicitly(self):
        payload = json.dumps({"choices": [{"finish_reason": "length", "message": {"content": '{"units":['}}]}).encode()
        with self.assertRaisesRegex(coarse.CoarseAudioError, "provider_response_truncated"):
            coarse._http_call("synthetic-key", b"wave", "prompt", 8192, opener=FakeOpener(payload))
        self.assertGreaterEqual(coarse._max_output_tokens(18), 8192)

    def test_structured_text_parts_and_complete_json_fence(self):
        content = '```json\n' + json.dumps(self.result()[0]) + '\n```'
        for value in [content, [{"type": "text", "text": content}]]:
            payload = json.dumps({"choices": [{"message": {"content": value}}]}).encode()
            result, _ = coarse._http_call("synthetic-key", b"wave", "prompt", 8192, opener=FakeOpener(payload))
            self.assertEqual(result, self.result()[0])
        payload = json.dumps({"choices": [{"message": {"content": 'Explanation: ' + content}}]}).encode()
        with self.assertRaisesRegex(coarse.CoarseAudioError, "provider_json_invalid"):
            coarse._http_call("synthetic-key", b"wave", "prompt", 8192, opener=FakeOpener(payload))

    def test_bare_array_response_keeps_strict_unit_validation(self):
        units = self.result()[0]["units"]
        payload = json.dumps({"choices": [{"message": {"content": json.dumps(units)}}]}).encode()
        result, _ = coarse._http_call("synthetic-key", b"wave", "prompt", 8192, opener=FakeOpener(payload))
        request = coarse._parse_request(self.request())
        targets = [u for u in request["units"] if not u["manual"]]
        self.assertEqual(len(coarse._validate_model_result(result, targets, request["key_by_model"])), 1)
        for invalid in [[], units + units, [dict(units[0], unit_id="foreign")], [dict(units[0], speaker_key="invented")]]:
            with self.assertRaises(coarse.CoarseAudioError):
                coarse._validate_model_result({"units": invalid}, targets, request["key_by_model"])

    def test_success_persists_results_and_identical_pause_reuses_without_call(self):
        payload = self.request()
        payload["request"]["run_id"] = "pause-001"
        calls = []

        def model_call(key, audio, prompt, max_tokens, **kwargs):
            calls.append((len(audio), max_tokens))
            return self.result()

        first = coarse._process(payload, call=model_call)
        second = coarse._process(payload, call=model_call)
        self.assertEqual(len(calls), 1)
        self.assertEqual(first["attempted_calls"], 1)
        self.assertEqual(second["attempted_calls"], 0)
        self.assertEqual(second["reused_segments"], 1)
        self.assertEqual(first["method"], "audio_coarse_v1")
        self.assertEqual(first["source_sha256"], "a" * 64)
        self.assertEqual(first["snapshot_sha256"], "b" * 64)
        self.assertEqual(first["run_id"], "pause-001")
        self.assertEqual(first["records"][0]["speaker_key"], "p2")
        self.assertEqual(first["records"][1]["text"], "对。")
        progress = json.loads((self.cache / coarse.PROGRESS_NAME).read_text())
        self.assertGreater(progress["reserved_yuan"], 0)
        self.assertEqual(progress["status"]["run_id"], "pause-001")
        self.assertEqual(progress["status"]["stage"], "complete")
        self.assertEqual(set(progress["status"]), {
            "run_id", "session", "cache_id", "stage", "completed", "total", "updated_at"})
        self.assertNotIn("FAKE-DO-NOT-SEND", json.dumps(progress))
        self.assertEqual((self.cache / coarse.PROGRESS_NAME).stat().st_mode & 0o777, 0o600)

    def test_incomplete_saved_audio_keeps_refinement_result_partial(self):
        payload = self.request()
        payload["request"]["incomplete_audio"] = True
        payload["request"]["audio_tracks"][0]["coverage_complete"] = False
        parsed = coarse._parse_request(payload)
        self.assertTrue(parsed["incomplete_audio"])

        result = coarse._process(payload, call=lambda *_args, **_kwargs: self.result())
        self.assertTrue(result["incomplete_audio"])
        ledger = json.loads((self.cache / coarse.PROGRESS_NAME).read_text())
        self.assertEqual(ledger["status"]["stage"], "partial")
        self.assertEqual(ledger["status"]["error"], "audio_incomplete")

    def test_malformed_audio_coverage_flag_is_rejected(self):
        payload = self.request()
        payload["request"]["audio_tracks"][0]["coverage_complete"] = "false"
        with self.assertRaisesRegex(coarse.CoarseAudioError, "invalid_audio_coverage"):
            coarse._parse_request(payload)

    def test_manual_units_are_never_sent_or_changed(self):
        request = self.request(units=[{"id": "manual-1", "source_id": "mic", "text": "人工原句",
                                       "start": 0, "end": 1, "speaker_key": "p1", "manual": True}])
        call = Mock(side_effect=AssertionError("manual-only segment must not call provider"))
        result = coarse._process(request, call=call)
        self.assertEqual(result["records"], [{"unit_id": "manual-1",
                                               "original_text_sha256": coarse._text_hash("人工原句"),
                                               "text": "人工原句", "speaker_key": "p1"}])
        call.assert_not_called()

    def test_failure_reserves_cost_and_exact_unknown_payload_needs_manual_retry(self):
        call = Mock(side_effect=coarse.CoarseAudioError("provider_unavailable"))
        with self.assertRaisesRegex(coarse.CoarseAudioError, "provider_unavailable"):
            coarse._process(self.request(), call=call)
        self.assertEqual(call.call_count, 1)
        ledger = json.loads((self.cache / coarse.PROGRESS_NAME).read_text())
        reserved_before = ledger["reserved_yuan"]
        self.assertEqual(next(iter(ledger["segments"].values()))["status"], "reserved_unknown")
        with self.assertRaisesRegex(coarse.CoarseAudioError, "previous_attempt_unknown"):
            coarse._process(self.request(), call=call)
        self.assertEqual(call.call_count, 1)
        ledger_after = json.loads((self.cache / coarse.PROGRESS_NAME).read_text())
        self.assertEqual(ledger_after["reserved_yuan"], reserved_before)


    def test_restart_retries_only_unknown_window_and_preserves_22_completed(self):
        # Match the reported durable state: 22 complete + 1 uncertain request.
        # Small independent tracks exercise the production window/ledger path.
        units = [{"id": f"u{i}", "source_id": f"app-{i:016x}-g1",
                  "text": "明天再确认。", "start": 0.0, "end": 1.0,
                  "speaker_key": "p1", "speaker_locked": True} for i in range(23)]
        request = self.request(units=units)
        request["request"]["audio_tracks"] = [
            {"source_id": u["source_id"], "origin_seconds": 0,
             "chunks": [str(self.pcm)], "written_bytes": self.pcm.stat().st_size}
            for u in units]
        calls = []

        def interrupted(_key, _audio, prompt, _max_tokens, **_kwargs):
            ids = json.loads(prompt.split("target_ids=", 1)[1].split("\n", 1)[0])
            calls.append(ids)
            if ids == ["u22"]:
                raise coarse.CoarseAudioError("provider_connection_unavailable")
            return {"units": [{"unit_id": uid, "text": "明天再确认。"} for uid in ids]}, {}

        with self.assertRaisesRegex(coarse.CoarseAudioError, "provider_connection_unavailable"):
            coarse._process(request, call=interrupted)
        path = self.cache / coarse.PROGRESS_NAME
        failed = json.loads(path.read_text())
        complete = {key: value for key, value in failed["segments"].items()
                    if value["status"] == "complete"}
        self.assertEqual(len(complete), 22)
        self.assertEqual(sum(s["status"] == "reserved_unknown" for s in failed["segments"].values()), 1)
        self.assertEqual(failed["status"]["stage"], "failed")
        self.assertEqual(failed["status"]["failed_stage"], "audio")
        initial_calls = len(calls)
        with self.assertRaisesRegex(coarse.CoarseAudioError, "previous_attempt_unknown"):
            coarse._process(request, call=interrupted)
        self.assertEqual(len(calls), initial_calls)
        reserved_before = json.loads(path.read_text())["reserved_yuan"]
        request["request"]["trigger"] = "manual_retry"

        def recovered(_key, _audio, prompt, _max_tokens, **_kwargs):
            ids = json.loads(prompt.split("target_ids=", 1)[1].split("\n", 1)[0])
            self.assertEqual(ids, ["u22"])
            calls.append(ids)
            return {"units": [{"unit_id": "u22", "text": "明天再确认。"}]}, {}

        result = coarse._process(request, call=recovered)
        saved = json.loads(path.read_text())
        self.assertEqual(result["attempted_calls"], 1)
        self.assertEqual(len(calls), initial_calls + 1)
        self.assertEqual(len(result["records"]), 23)
        self.assertEqual(saved["status"]["stage"], "complete")
        self.assertGreater(saved["reserved_yuan"], reserved_before)
        for key, value in complete.items():
            self.assertEqual(saved["segments"][key], value)
        self.assertEqual(coarse._process(request, call=recovered)["attempted_calls"], 0)
        self.assertEqual(len(calls), initial_calls + 1)

    def test_invalid_model_coverage_or_new_person_key_is_rejected(self):
        for model_result in [
            {"units": []},
            {"units": [{"unit_id": "u1", "text": "wrong", "speaker_key": "invented"}]},
        ]:
            with self.subTest(model_result=model_result):
                other_cache = Path(self.temp.name) / f"cache-{len(list(Path(self.temp.name).glob('cache-*')))}"
                other_cache.mkdir()
                pcm = other_cache / "mic-000000.pcm"
                pcm.write_bytes(self.pcm.read_bytes())
                request = self.request()
                request["request"]["cache_dir"] = str(other_cache)
                request["request"]["audio_tracks"][0]["chunks"] = [str(pcm)]
                call = lambda *_args, **_kwargs: (model_result, {})
                with self.assertRaises(coarse.CoarseAudioError):
                    coarse._process(request, call=call)

    def test_coverage_failure_repairs_only_window_and_resumes_completed_batches(self):
        texts = ["这是第一条足够完整的测试原句。", "这是第二条足够完整的测试原句。",
                 "这是第三条足够完整的测试原句。", "这是第四条足够完整的测试原句。"]
        units = [{"unit_id": f"u{i}", "source_id": "mic", "text": text,
                  "start": i / 10, "end": (i + 1) / 10, "speaker_key": "p1",
                  "speaker_locked": True}
                 for i, text in enumerate(texts)]
        request = self.request(units=units)
        request["request"]["trigger"] = "manual_retry"
        parsed = coarse._parse_request(request)
        track = parsed["tracks"][0]
        window_start, window_end, _, _ = coarse._segment_plan(track)[0]
        context_units = parsed["units"]
        audio = coarse._read_pcm(track.chunks, 0, track.total_bytes)
        audio_hash, input_hash = coarse._segment_identity(
            track, audio, context_units, parsed["roster"], window_start, window_end)
        segment_key = f"{track.source_id}:0:{audio_hash[:16]}"
        ledger = coarse._load_ledger(self.cache / coarse.PROGRESS_NAME,
                                     parsed["session"], parsed["cache_id"])
        ledger["segments"][segment_key] = {"status": "reserved_unknown", "input_hash": input_hash,
                                             "audio_sha256": audio_hash, "attempts": 1,
                                             "window_start": window_start, "window_end": window_end,
                                             "unit_ids": [unit["id"] for unit in parsed["units"]]}
        coarse._set_progress(self.cache / coarse.PROGRESS_NAME, ledger, parsed,
                             "failed", 0, 1, error="provider_unit_coverage_invalid")
        calls = []

        def model_call(_key, _audio, prompt, _max_tokens, **_kwargs):
            target_ids = json.loads(prompt.split("target_ids=", 1)[1].split("\n", 1)[0])
            calls.append(target_ids)
            if len(target_ids) == len(units):
                # Legacy whole-window receipt failed strict coverage. Do not
                # repeat this large request; use the two stable child batches.
                raise AssertionError("legacy parent request must not be repeated")
            if len(calls) == 2:
                raise coarse.CoarseAudioError("provider_unavailable")
            rows = [{"unit_id": unit_id, "text": texts[int(unit_id[1:])]} for unit_id in target_ids]
            return {"units": rows}, {}

        with self.assertRaisesRegex(coarse.CoarseAudioError, "provider_unavailable"):
            coarse._process(request, call=model_call)
        saved = json.loads((self.cache / coarse.PROGRESS_NAME).read_text())
        parent = saved["segments"][segment_key]
        self.assertEqual(parent["status"], "split")
        self.assertEqual(parent["repair_batches"]["0"]["status"], "complete")
        self.assertEqual(parent["repair_batches"]["1"]["status"], "failed")

        result = coarse._process(request, call=model_call)
        self.assertEqual(len(calls), 3, calls)
        self.assertEqual(calls[1], calls[2])  # only the failed sibling is retried
        self.assertNotEqual(calls[0], calls[1])
        self.assertEqual({row["unit_id"] for row in result["records"]}, {f"u{i}" for i in range(4)})
        self.assertEqual(result["attempted_calls"], 1)
        coarse._process(request, call=model_call)
        self.assertEqual(len(calls), 3)

    def test_coverage_repair_has_a_hard_per_window_call_limit(self):
        units = [{"unit_id": f"u{i}", "source_id": "mic", "text": f"这是第{i}条足够完整的测试原句。",
                  "start": i / 10, "end": (i + 1) / 10, "speaker_key": "p1",
                  "speaker_locked": True}
                 for i in range(4)]
        calls = []

        def always_incomplete(_key, _audio, prompt, _max_tokens, **_kwargs):
            ids = json.loads(prompt.split("target_ids=", 1)[1].split("\n", 1)[0])
            calls.append(ids)
            return {"units": [{"unit_id": item, "text": "漏了其他项"} for item in ids[:-1]]}, {}

        request = self.request(units=units)
        with self.assertRaisesRegex(coarse.CoarseAudioError, "provider_unit_coverage_invalid"):
            coarse._process(request, call=always_incomplete)
        self.assertLessEqual(len(calls), 1 + coarse.MAX_COVERAGE_REPAIR_CALLS)
        saved = json.loads((self.cache / coarse.PROGRESS_NAME).read_text())
        pending = [entry for entry in saved["segments"].values() if entry.get("repair_revision")]
        self.assertEqual(len(pending), 1)
        self.assertLessEqual(pending[0]["repair_calls"], coarse.MAX_COVERAGE_REPAIR_CALLS)
        first_call_count = len(calls)
        first_batch_states = {key: value.get("status") for key, value in pending[0]["repair_batches"].items()}

        retry = self.request(units=units)
        retry["request"]["run_id"] = "explicit-retry-after-repair-limit"
        retry["request"]["trigger"] = "manual_retry"
        retry_calls = []

        def recovered(_key, _audio, prompt, _max_tokens, **_kwargs):
            ids = json.loads(prompt.split("target_ids=", 1)[1].split("\n", 1)[0])
            retry_calls.append(ids)
            return {"units": [{"unit_id": item, "text": f"修复 {item}"} for item in ids]}, {}

        result = coarse._process(retry, call=recovered)
        saved_after_retry = json.loads((self.cache / coarse.PROGRESS_NAME).read_text())
        retry_parent = next(entry for entry in saved_after_retry["segments"].values()
                            if entry.get("repair_revision"))
        self.assertEqual(len(retry_calls), 4, (retry_calls, retry_parent.get("repair_calls"),
                                               {k: v.get("status") for k, v in retry_parent["repair_batches"].items()},
                                               first_call_count, first_batch_states))
        self.assertEqual(result["attempted_calls"], 4)
        self.assertEqual({row["unit_id"] for row in result["records"]}, {f"u{i}" for i in range(4)})

    def test_malformed_repair_children_fail_closed_without_provider_call(self):
        units = [{"unit_id": f"u{i}", "source_id": "mic", "text": f"这是第{i}条完整的测试原句。",
                  "start": i / 10, "end": (i + 1) / 10, "speaker_key": "p1", "speaker_locked": True}
                 for i in range(4)]
        req = coarse._parse_request(self.request(units=units))
        track = req["tracks"][0]
        start, end, _, _ = coarse._segment_plan(track)[0]
        pcm = coarse._read_pcm(track.chunks, 0, track.total_bytes)
        target_rows = req["units"][:2]
        batch_hash = coarse.hashlib.sha256(json.dumps(
            {"parent_input_hash": "parent-hash", "unit_ids": [unit["id"] for unit in target_rows],
             "revision": "coverage-bisection-1"}, sort_keys=True,
            separators=(",", ":")).encode("utf-8")).hexdigest()
        parent = {"repair_batches": {"0": {"status": "split", "input_hash": batch_hash,
                                             "children": ["0000000000000000000000000000000000000000000000000000000000000000", "01"]}}}
        ledger = coarse._load_ledger(self.cache / coarse.PROGRESS_NAME, req["session"], req["cache_id"])
        call = Mock(side_effect=AssertionError("corrupt cached tree must never trigger a provider request"))
        with self.assertRaisesRegex(coarse.CoarseAudioError, "coverage_repair_cache_invalid"):
            coarse._repair_coverage_batches(req, track, coarse._wav_bytes(pcm), req["units"], req["units"],
                                            start, end, parent, "parent-hash", ledger,
                                            self.cache / coarse.PROGRESS_NAME, call, 0, lambda: 1)
        call.assert_not_called()

    def test_repair_reservations_survive_later_normal_window(self):
        self.pcm.write_bytes(bytes(256) * 18_875)  # 4.8 MB, 151 seconds with a second window
        units = [{"unit_id": f"u{i}", "source_id": "mic", "text": f"这是窗口一第{i}条完整测试原句。",
                  "start": i / 10, "end": (i + 1) / 10, "speaker_key": "p1", "speaker_locked": True}
                 for i in range(4)]
        units.append({"unit_id": "u4", "source_id": "mic", "text": "这是窗口二中唯一的完整测试原句。",
                      "start": 150.3, "end": 150.8, "speaker_key": "p1", "speaker_locked": True})
        calls = []

        def model_call(_key, _audio, prompt, _max_tokens, **_kwargs):
            ids = json.loads(prompt.split("target_ids=", 1)[1].split("\n", 1)[0])
            calls.append(ids)
            if len(calls) == 1:
                return {"units": [{"unit_id": item, "text": f"校订 {item}"} for item in ids[:-1]]}, {}
            return {"units": [{"unit_id": item, "text": f"校订 {item}"} for item in ids]}, {}

        result = coarse._process(self.request(units=units), call=model_call)
        self.assertEqual(len(calls), 4)  # parent window + two repair children + normal second window
        self.assertEqual(result["attempted_calls"], 4)
        ledger = json.loads((self.cache / coarse.PROGRESS_NAME).read_text())
        reserved_in_receipts = 0.0
        for entry in ledger["segments"].values():
            reserved_in_receipts += entry.get("reserved_yuan", 0.0)
            reserved_in_receipts += sum(batch.get("reserved_yuan", 0.0)
                                        for batch in entry.get("repair_batches", {}).values())
        self.assertAlmostEqual(ledger["reserved_yuan"], reserved_in_receipts, places=10)

    def test_structured_speaker_keys_round_trip_and_locked_speaker_is_preserved(self):
        key_a = {"session": "session-a", "source": "mic", "epoch": 1, "identity": "voice-a"}
        key_b = {"session": "session-a", "source": "desktop", "epoch": 1, "identity": "voice-b"}
        request = self.request(units=[{"unit_id": "u1", "source_id": "mic", "text": "这是可以校订的完整原句。",
                                       "original_text_sha256": coarse._text_hash("这是可以校订的完整原句。"),
                                       "start": 0, "end": 1, "speaker_key": key_a,
                                       "speaker_locked": True, "manual": False}], budget=1.0)
        request["request"]["roster"] = [{"key": key_a, "name": "甲"}, {"key": key_b, "name": "乙"}]
        label_b = coarse._speaker_label(key_b, "test")
        result = coarse._process(request, call=lambda *_args, **_kwargs: (
            {"units": [{"unit_id": "u1", "text": "这是已经校正的完整原句。", "speaker_key": label_b}]}, {}))
        self.assertEqual(result["records"][0]["text"], "这是已经校正的完整原句。")
        self.assertEqual(result["records"][0]["speaker_key"], key_a)

    def test_user_retry_requires_new_explicit_action_and_keeps_cost_estimate(self):
        call = Mock(side_effect=coarse.CoarseAudioError("provider_unavailable"))
        with self.assertRaisesRegex(coarse.CoarseAudioError, "provider_unavailable"):
            coarse._process(self.request(), call=call)
        retry = self.request()
        retry["request"]["trigger"] = "manual_retry"
        with self.assertRaisesRegex(coarse.CoarseAudioError, "provider_unavailable"):
            coarse._process(retry, call=call)
        with self.assertRaisesRegex(coarse.CoarseAudioError, "provider_unavailable"):
            coarse._process(retry, call=call)
        self.assertEqual(call.call_count, 3)
        ledger = json.loads((self.cache / coarse.PROGRESS_NAME).read_text())
        self.assertEqual(next(iter(ledger["segments"].values()))["attempts"], 3)
        self.assertGreater(ledger["reserved_yuan"], 0)

    def test_pause_increment_reuses_unchanged_closed_segment_and_only_sends_new_tail(self):
        self.pcm.write_bytes(b"")
        with self.pcm.open("wb") as stream:
            stream.truncate(150 * coarse.BYTES_PER_SECOND)
        first = self.request(units=[{"unit_id": "early", "source_id": "mic", "text": "先说。",
                                    "start": 80, "end": 81, "manual": False}],
                             written_bytes=self.pcm.stat().st_size)
        calls = []

        def model_call(_key, _audio, prompt, _max_tokens, **_kwargs):
            targets = json.loads(prompt.split("target_ids=", 1)[1].split("\n", 1)[0])
            calls.append(targets)
            return {"units": [{"unit_id": unit_id, "text": "校订。", "speaker_key": coarse._speaker_label("p1", "test")}
                               for unit_id in targets]}, {}

        first_result = coarse._process(first, call=model_call)
        self.assertEqual(len(calls), 1)
        with self.pcm.open("wb") as stream:
            stream.truncate(160 * coarse.BYTES_PER_SECOND)
        second = self.request(units=[{"unit_id": "early", "source_id": "mic", "text": "先说。",
                                      "start": 80, "end": 81, "manual": False},
                                     {"unit_id": "late", "source_id": "mic", "text": "尾声。",
                                      "start": 150, "end": 151, "manual": False}],
                              written_bytes=self.pcm.stat().st_size)
        with patch.object(coarse, "_read_pcm", wraps=coarse._read_pcm) as read_pcm:
            second_result = coarse._process(second, call=model_call)
        self.assertEqual(len(calls), 2)
        self.assertEqual(read_pcm.call_count, 1)
        self.assertEqual(second_result["attempted_calls"], 1)
        self.assertEqual(second_result["reused_segments"], 1)
        self.assertEqual({record["unit_id"] for record in second_result["records"]}, {"early", "late"})

    def test_pause_increment_does_not_refine_old_units_when_the_short_tail_grows(self):
        with self.pcm.open("wb") as stream:
            stream.truncate(10 * coarse.BYTES_PER_SECOND)
        early = {"unit_id": "early", "source_id": "mic", "text": "这是一句完整的旧转写。",
                 "start": 2, "end": 3, "manual": False}
        calls = []

        def model_call(_key, _audio, prompt, _max_tokens, **_kwargs):
            targets = json.loads(prompt.split("target_ids=", 1)[1].split("\n", 1)[0])
            calls.append(targets)
            return {"units": [{"unit_id": unit_id, "text": "这是一句完整的旧转写。" if unit_id == "early" else "这是追加到录音尾部的新话。",
                                "speaker_key": coarse._speaker_label("p1", "test")}
                               for unit_id in targets]}, {}

        first = self.request(units=[early], written_bytes=self.pcm.stat().st_size)
        coarse._process(first, call=model_call)
        with self.pcm.open("wb") as stream:
            stream.truncate(12 * coarse.BYTES_PER_SECOND)
        late = {"unit_id": "late", "source_id": "mic", "text": "这是追加到录音尾部的一句新话。",
                "start": 10.5, "end": 11, "manual": False}
        second = self.request(units=[early, late], written_bytes=self.pcm.stat().st_size)
        result = coarse._process(second, call=model_call)
        self.assertEqual(calls, [["early"], ["late"]])
        self.assertEqual(result["attempted_calls"], 1)
        records = {row["unit_id"]: row for row in result["records"]}
        self.assertEqual(records["early"]["text"], "这是一句完整的旧转写。")
        self.assertEqual(records["late"]["text"], "这是追加到录音尾部的新话。")

    def test_speaker_name_changes_reuse_refined_text_and_keep_manual_assignment(self):
        unit = {"unit_id": "known", "source_id": "mic", "text": "这是这是一句完整的转写。",
                "start": 0, "end": .5, "speaker_key": "p1", "speaker_name": "发言人1",
                "speaker_locked": True, "manual": False}
        calls = []

        def model_call(_key, _audio, prompt, _max_tokens, **_kwargs):
            targets = json.loads(prompt.split("target_ids=", 1)[1].split("\n", 1)[0])
            calls.append(targets)
            return {"units": [{"unit_id": item, "text": "这是一句完整的转写。",
                                "speaker_key": coarse._speaker_label("p2", "test")} for item in targets]}, {}

        coarse._process(self.request(units=[unit]), call=model_call)
        renamed = dict(unit, speaker_name="张总")
        request = self.request(units=[renamed])
        request["request"]["roster"] = [{"speaker_key": "p1", "name": "张总"}]
        result = coarse._process(request, call=model_call)
        self.assertEqual(calls, [["known"]])
        self.assertEqual(result["attempted_calls"], 0)
        self.assertEqual(result["records"][0]["text"], "这是一句完整的转写。")
        self.assertEqual(result["records"][0]["speaker_key"], "p1")

    def test_changed_manual_text_is_preserved_when_old_cached_result_exists(self):
        unit = {"unit_id": "known", "source_id": "mic", "text": "原始转写完整句。",
                "start": 0, "end": .5, "manual": False}
        call = Mock(return_value=({"units": [{"unit_id": "known", "text": "AI校订句子。"}]}, {}))
        coarse._process(self.request(units=[unit]), call=call)
        calls_after_first_pause = call.call_count
        edited = dict(unit, text="用户手工修订句子。", manual=True)
        result = coarse._process(self.request(units=[edited]), call=call)
        self.assertEqual(call.call_count, calls_after_first_pause)
        self.assertEqual(result["records"][0]["text"], "用户手工修订句子。")

    def test_usage_estimate_is_not_a_cost_gate_but_pcm_bounds_are_checked(self):
        request = self.request(budget=0.0)
        call = Mock(return_value=self.result())
        result = coarse._process(request, call=call)
        self.assertEqual(result["attempted_calls"], 1)
        call.assert_called_once()
        request = self.request(written_bytes=self.pcm.stat().st_size + 2)
        with self.assertRaisesRegex(coarse.CoarseAudioError, "pcm_short_read"):
            coarse._process(request, call=call)
        self.assertEqual(call.call_count, 1)

    def test_frozen_pcm_prefix_is_readable_after_recording_appends(self):
        original = self.pcm.read_bytes()
        request = self.request(written_bytes=len(original))
        parsed = coarse._parse_request(request)
        with self.pcm.open("ab") as stream:
            stream.write(b"new-pause-audio")
        frozen = coarse._read_pcm(parsed["tracks"][0].chunks, 0, len(original))
        self.assertEqual(frozen, original)
        self.assertEqual(sum(chunk.byte_count for chunk in parsed["tracks"][0].chunks), len(original))

    def test_segment_windows_cover_timeline_with_bounded_overlap(self):
        track = coarse.Track("mic", 5.0, (coarse.PCMChunk(self.pcm, 32000 * 300),), 32000 * 300)
        plan = coarse._segment_plan(track)
        self.assertEqual(len(plan), 3)
        self.assertEqual(plan[0], (5.0, 155.0, 5.0, 155.0))
        self.assertEqual(plan[1], (143.0, 293.0, 155.0, 293.0))
        self.assertEqual(plan[2], (281.0, 305.0, 293.0, 305.0))

    def test_approximate_unit_uses_ten_second_audio_margin_without_changing_timing(self):
        with self.pcm.open("wb") as stream:
            stream.truncate(150 * coarse.BYTES_PER_SECOND)
        request = self.request(units=[{"unit_id": "rough", "source_id": "mic", "text": "片段。",
                                       "start": 149.2, "end": 149.8, "approximate_window": True,
                                       "manual": False}], written_bytes=150 * coarse.BYTES_PER_SECOND)
        calls = []

        def model_call(_key, audio, prompt, _max_tokens, **_kwargs):
            calls.append(len(audio))
            self.assertIn('"approximate_window":true', prompt)
            self.assertNotIn('"end":150.0', prompt)
            return {"units": [{"unit_id": "rough", "text": "校订片段。"}]}, {}

        result = coarse._process(request, call=model_call)
        self.assertEqual(len(calls), 1)
        self.assertEqual(result["records"][0]["unit_id"], "rough")
        self.assertEqual(result["records"][0]["text"], "片段。")

    def test_reads_exact_window_across_multiple_pcm_files(self):
        first, second = self.cache / "first.pcm", self.cache / "second.pcm"
        first.write_bytes(b"012345")
        second.write_bytes(b"6789abcd")
        chunks = (coarse.PCMChunk(first, 6), coarse.PCMChunk(second, 8))
        self.assertEqual(coarse._read_pcm(chunks, 4, 8), b"456789ab")

    def test_other_source_context_is_visible_but_never_a_target(self):
        req = self.request()
        remote = dict(id="remote-question", source_id="remote", text="明天确认可以吗？",
                      start=0, end=0.5, speaker_key="p2", manual=True)
        req["request"]["units"].append(remote)
        req["request"]["audio_tracks"].append(dict(source_id="remote", origin_seconds=0,
            chunks=[str(self.pcm)], written_bytes=self.pcm.stat().st_size))
        def answer(_key, _audio, prompt, _tokens, **_kwargs):
            targets = json.loads(prompt.split("target_ids=", 1)[1].split("\n", 1)[0])
            context = json.loads(prompt.split("\nunits=", 1)[1].split("\n", 1)[0])
            self.assertEqual(targets, ["u1"])
            self.assertEqual({u["source_id"] for u in context}, {"mic", "remote"})
            self.assertIn("remote-question", {u["unit_id"] for u in context})
            return self.result()
        result = coarse._process(req, call=answer)
        self.assertEqual(result["attempted_calls"], 1)
        self.assertEqual({r["unit_id"] for r in result["records"]}, {"u1", "u2", "remote-question"})

    def test_prompt_policy_change_invalidates_cached_result(self):
        call = Mock(return_value=self.result())
        coarse._process(self.request(), call=call)
        with patch.object(coarse, "PROMPT_REVISION", "future-policy"):
            result = coarse._process(self.request(), call=call)
        self.assertEqual(call.call_count, 2)
        self.assertEqual(result["reused_segments"], 0)

    def test_reused_legacy_window_ignores_extra_removed_blank_records(self):
        call = Mock(return_value=self.result())
        first = coarse._process(self.request(), call=call)
        self.assertEqual(first["reused_segments"], 0)
        ledger_path = self.cache / coarse.PROGRESS_NAME
        ledger = json.loads(ledger_path.read_text())
        segment = next(iter(ledger["segments"].values()))
        segment["unit_ids"].append("legacy-blank")
        segment["results"].append({"unit_id": "legacy-blank", "text": " ",
                                   "original_text_sha256": coarse._text_hash(" ")})
        ledger_path.write_text(json.dumps(ledger))
        second = coarse._process(self.request(), call=call)
        self.assertEqual(second["reused_segments"], 1)
        self.assertEqual([row["unit_id"] for row in second["records"]], ["u1", "u2"])
        self.assertEqual(call.call_count, 1)



    def test_exact_mapping_prompt_and_name_change_audit(self):
        rows=[dict(term='惊石',aliases=[],misheard=['金石'])]
        old=[dict(id='name',text='金石说嗯嗯先这样。'),dict(id='filler',text='嗯嗯先这样。')]
        new=[dict(unit_id='name',text='惊石说先这样。'),dict(unit_id='filler',text='先这样。')]
        self.assertEqual(coarse.name_changes(old,new,rows),[dict(unit_id='name',old='金石',new='惊石')])
        self.assertEqual(coarse.name_changes(old,old,rows),[])
        prompt=coarse._prompt('mic',[],[],[],0, ['惊石；常被误识为金石'])
        self.assertIn('精确出现',prompt)
        self.assertIn('即使读音相近也保留原文',prompt)
        self.assertNotIn('term_hints=',prompt)

    def test_receipt_audits_registered_names_and_rejects_unregistered_name_swap(self):
        rows=[dict(term='惊石',aliases=[],misheard=['金石'],layer='project'),
              dict(term='晶视',aliases=[],misheard=[],layer='people')]
        request=self.request(units=[dict(id='name',source_id='mic',text='金石说写到PPT里面。',start=0,end=1,speaker_locked=True)])
        call=Mock(return_value=({'units':[dict(unit_id='name',text='惊石说写到PPT里面。')]},{}))
        with patch.object(coarse,'_cleanup_terms',return_value=rows),patch.object(coarse,'_name_rows',return_value=rows):
            result=coarse._process(request,call=call)
            reused=coarse._process(request,call=call)
        self.assertEqual(result['name_changes'],[dict(unit_id='name',old='金石',new='惊石')])
        self.assertEqual(reused['name_changes'],result['name_changes'])
        self.assertEqual(call.call_count,1)
        unit=dict(text='写到PPT里面给惊石啊，水水啊，他们都在场。',manual=False,approximate_window=False)
        self.assertEqual(coarse._safe_text(unit,unit['text'].replace('惊石','晶视'),rows),unit['text'])
        alias=[dict(term='张三',aliases=['小张'],misheard=[])]
        unit['text']='小张说写到PPT里面。'
        self.assertEqual(coarse._safe_text(unit,unit['text'].replace('小张','张三'),alias),unit['text'])

    def test_previous_prompt_with_nonempty_old_hints_never_calls_model(self):
        request=self.request(units=[dict(id='name',source_id='mic',text='写到PPT里面给晶视啊，水水啊，他们都在场。',start=0,end=1,speaker_locked=True)])
        parsed=coarse._parse_request(request)
        unit=parsed['units'][0]
        # Real previous hash shape, including the now-removed per-meeting hints.
        for revision in ['term-guide-5','clear-transcript-1']:
            state=dict(unit_id=unit['id'],source_id=unit['source_id'],text_sha256=unit['original_text_sha256'],
                       start=round(unit['start'],3),end=round(unit['end'],3),approximate_window=unit['approximate_window'],
                       model=coarse.MODEL,prompt_revision=revision,term_hints=['晶视'])
            if revision=='clear-transcript-1':state['matched_terms']=[]
            old_hash=coarse.hashlib.sha256(json.dumps(state,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()).hexdigest()
            ledger=coarse._load_ledger(self.cache/coarse.PROGRESS_NAME,parsed['session'],parsed['cache_id'])
            ledger['unit_results']={unit['id']:dict(input_hash=old_hash,clean_policy=revision,
                result=dict(unit_id=unit['id'],original_text_sha256=unit['original_text_sha256'],text=unit['text']))}
            coarse._save_ledger(self.cache/coarse.PROGRESS_NAME,ledger)
            call=Mock(side_effect=AssertionError('must reuse old cleanup'))
            with patch.object(coarse,'_cleanup_terms',return_value=[]):
                first=coarse._process(request,call=call);second=coarse._process(request,call=call)
            call.assert_not_called()
            self.assertEqual(first['records'],second['records'])
            self.assertEqual(first['attempted_calls'],0)

    def test_semantic_stage_assigns_missing_speaker_without_changing_text(self):
        request = self.request(units=[
            {"unit_id": "residual", "source_id": "mic", "text": "原文短句。", "start": 0, "end": 0.5},
            {"unit_id": "known", "source_id": "mic", "text": "有归属。", "start": 0.5, "end": 1,
             "speaker_key": "p2"},
        ])
        calls = []

        def model_call(_key, audio, prompt, max_tokens, **_kwargs):
            calls.append((audio is None, max_tokens))
            targets = json.loads(prompt.split("target_ids=", 1)[1].split("\n", 1)[0])
            if audio is None:
                self.assertIn('"audio_speaker"', prompt)
                return {"units": [{"unit_id": item, "speaker_key": coarse._speaker_label("p2", "test")}
                                   for item in targets]}, {}
            return {"units": [{"unit_id": item, "text": "校订后。",
                                **({"speaker_key": coarse._speaker_label("p2", "test")} if item == "known" else {})}
                               for item in targets]}, {}

        result = coarse._process(request, call=model_call)
        records = {row["unit_id"]: row for row in result["records"]}
        self.assertEqual(calls, [(False, coarse._max_output_tokens(1)), (True, coarse._max_output_tokens(1))])
        self.assertEqual(records["residual"]["text"], "原文短句。")
        self.assertEqual(records["residual"]["speaker_key"], "p2")
        self.assertEqual(records["known"]["speaker_key"], "p2")
        self.assertTrue(result["semantic_attempted"])

    def test_semantic_protects_manual_and_locked_and_caches_null_reason(self):
        key = {"session": "s", "source": "mic", "epoch": 1, "identity": "speaker"}
        request = self.request(units=[
            {"unit_id": "manual", "source_id": "mic", "text": "人工。", "start": 0, "end": .2,
             "speaker_key": key, "manual": True},
            {"unit_id": "locked", "source_id": "mic", "text": "锁定原句。", "start": .2, "end": .4,
             "speaker_key": key, "speaker_locked": True},
            {"unit_id": "null", "source_id": "mic", "text": "短词。", "start": .4, "end": .6},
        ])
        request["request"]["roster"] = [{"key": key, "name": "甲"}]
        semantic_calls = []

        def model_call(_key, audio, prompt, _tokens, **_kwargs):
            targets = json.loads(prompt.split("target_ids=", 1)[1].split("\n", 1)[0])
            if audio is None:
                semantic_calls.append(targets)
                return {"units": [{"unit_id": "null", "speaker_key": None, "unassigned_reason": "声音太短"}]}, {}
            return {"units": [{"unit_id": item, "text": "锁定校字。" if item == "locked" else "短词。",
                                **({"speaker_key": coarse._speaker_label(key, "test")} if item == "locked" else {})}
                               for item in targets]}, {}

        first = coarse._process(request, call=model_call)
        ledger = json.loads((self.cache / coarse.PROGRESS_NAME).read_text())
        self.assertEqual(ledger["semantic_assignment"]["status"], "complete")
        self.assertNotIn("semantic_assignment_batches", ledger)
        second = coarse._process(request, call=model_call)
        by_id = {row["unit_id"]: row for row in first["records"]}
        self.assertEqual(semantic_calls, [["null"]])
        self.assertEqual(by_id["manual"]["text"], "人工。")
        self.assertEqual(by_id["manual"]["speaker_key"], key)
        self.assertEqual(by_id["locked"]["text"], "锁定原句。")
        self.assertEqual(by_id["locked"]["speaker_key"], key)
        self.assertIsNone(by_id["null"]["speaker_key"])
        self.assertEqual(by_id["null"]["notes"], "说话人未归属：声音太短")
        self.assertFalse(second["semantic_attempted"])
        self.assertEqual(semantic_calls, [["null"]])

    def test_semantic_malformed_response_preserves_audio_results_and_does_not_loop(self):
        request = self.request(units=[{"unit_id": "residual", "source_id": "mic", "text": "这是一句可以听清的完整原文。",
                                       "start": 0, "end": .5}])
        calls = []

        def model_call(_key, audio, prompt, _tokens, **_kwargs):
            calls.append(audio is None)
            if audio is None:
                return {"units": [{"unit_id": "residual", "speaker_key": "invented"}]}, {}
            return {"units": [{"unit_id": "residual", "text": "这是一句已经校正的完整原文。"}]}, {}

        first = coarse._process(request, call=model_call)
        second = coarse._process(request, call=model_call)
        self.assertEqual(calls, [False, True])
        self.assertEqual(first["warning"], "semantic_assignment_incomplete")
        self.assertEqual(second["warning"], "semantic_assignment_incomplete")
        self.assertEqual(first["records"][0]["text"], "这是一句已经校正的完整原文。")
        self.assertEqual(second["records"][0]["text"], "这是一句已经校正的完整原文。")
        self.assertNotIn("speaker_key", first["records"][0])

    def test_semantic_cache_keeps_prior_pause_assignments_when_snapshot_grows(self):
        assigned_key = {"session": "session-a", "source": "mic", "epoch": 1, "identity": "speaker-a"}
        request = self.request(units=[{"unit_id": "residual", "source_id": "mic", "text": "原句。",
                                       "start": 0, "end": .5}])
        request["request"]["roster"] = [{"key": assigned_key, "name": "甲"}]
        semantic_calls = []

        def model_call(_key, audio, prompt, _tokens, **_kwargs):
            targets = json.loads(prompt.split("target_ids=", 1)[1].split("\n", 1)[0])
            if audio is None:
                semantic_calls.append(targets)
                return {"units": [{"unit_id": "residual", "speaker_key": coarse._speaker_label(assigned_key, "test")} ]}, {}
            return {"units": [{"unit_id": "residual", "text": "校订。"}]}, {}

        first = coarse._process(request, call=model_call)
        second = coarse._process(request, call=model_call)
        self.assertEqual(first["records"][0]["speaker_key"], assigned_key)
        self.assertEqual(second["records"][0]["speaker_key"], assigned_key)
        changed = self.request(units=request["request"]["units"])
        changed["request"]["snapshot_sha256"] = "c" * 64
        changed["request"]["roster"] = [{"key": assigned_key, "name": "甲"}]
        changed["request"]["units"].append({"unit_id": "new-unit", "source_id": "mic",
            "text": "新增发言。", "start": 0.6, "end": 0.8})

        def answer_new(_key, audio, prompt, _tokens, **_kwargs):
            targets = json.loads(prompt.split("target_ids=", 1)[1].split("\n", 1)[0])
            if audio is None:
                semantic_calls.append(targets)
                return {"units": [{"unit_id": "new-unit", "speaker_key":
                                   coarse._speaker_label(assigned_key, "test")}]}, {}
            return {"units": [{"unit_id": item, "text": "新增发言。"} for item in targets]}, {}

        coarse._process(changed, call=answer_new)
        self.assertEqual(semantic_calls, [["residual"], ["new-unit"]])

    def test_semantic_null_cache_survives_new_pause_units(self):
        old = {"unit_id": "old", "source_id": "mic", "text": "短词。", "start": 0, "end": .3}
        request = self.request(units=[old])
        semantic_calls = []
        def answer(_key, audio, prompt, _tokens, **_kwargs):
            ids = json.loads(prompt.split("target_ids=", 1)[1].split("\n", 1)[0])
            if audio is None:
                semantic_calls.append(ids)
                return {"units": [{"unit_id": i, "speaker_key": None, "unassigned_reason": "声音过短"} for i in ids]}, {}
            return {"units": [{"unit_id": i, "text": "短词。"} for i in ids]}, {}
        coarse._process(request, call=answer)
        request["request"]["units"].append({"unit_id": "new", "source_id": "mic", "text": "短词。", "start": .5, "end": .8})
        result = coarse._process(request, call=answer)
        self.assertEqual(semantic_calls, [["old"], ["new"]])
        self.assertTrue(all("未归属" in row["notes"] for row in result["records"]))

    def test_semantic_budget_failure_keeps_completed_transcription(self):
        request = self.request(units=[{"unit_id": "u", "source_id": "mic", "text": "完整的原文。", "start": 0, "end": .5}])
        call = Mock(return_value=({"units": [{"unit_id": "u", "text": "完整的原文。"}]}, {}))
        with patch.object(coarse, "_reserve_cost", side_effect=[.01, coarse.MAX_RESERVED_YUAN_PER_MEETING]):
            result = coarse._process(request, call=call)
        self.assertEqual(call.call_count, 1)
        self.assertEqual(result["records"][0]["text"], "完整的原文。")
        self.assertEqual(result["warning"], "semantic_assignment_incomplete")

    def test_removed_roster_key_is_not_restored_from_text_cache(self):
        request = self.request(units=[{"unit_id": "u1", "source_id": "mic", "text": "明天再确认。", "start": 0, "end": .5}])
        coarse._process(request, call=Mock(return_value=self.result("p2")))
        request["request"]["roster"] = [{"speaker_key": "p1", "name": "甲"}]
        calls = []
        def answer(_key, audio, prompt, _tokens, **_kwargs):
            calls.append(audio)
            return {"units": [{"unit_id": "u1", "speaker_key": coarse._speaker_label("p1", "test")}]}, {}
        result = coarse._process(request, call=answer)
        self.assertEqual(calls, [None])
        self.assertEqual(result["records"][0]["speaker_key"], "p1")

    def test_semantic_missing_speaker_field_and_empty_null_reason_are_rejected(self):
        targets = [{"id": "one"}]
        mapping = {coarse._speaker_label("p1", "test"): "p1"}
        for value in [
            {"units": [{"unit_id": "one"}]},
            {"units": [{"unit_id": "one", "speaker_key": None, "unassigned_reason": " "}]},
        ]:
            with self.subTest(value=value), self.assertRaises(coarse.CoarseAudioError):
                coarse._validate_semantic_result(value, targets, mapping)
        self.assertEqual(coarse._validate_semantic_result(
            {"units": [{"unit_id": "one", "speaker_key": None, "unassigned_reason": "短"}]},
            targets, mapping)[0]["unassigned_reason"], "短")

    def test_conflicting_semantic_attribution_preserves_other_units(self):
        key = coarse._speaker_label("p1", "test")
        result = coarse._validate_semantic_result({"units": [
            {"unit_id": "one", "speaker_key": key, "unassigned_reason": "声音不清"},
            {"unit_id": "two", "speaker_key": key},
        ]}, [{"id": "one"}, {"id": "two"}], {key: "p1"})
        self.assertIsNone(result[0]["speaker_key"])
        self.assertEqual(result[0]["unassigned_reason"], "声音不清")
        self.assertEqual(result[1]["speaker_key"], "p1")

    def test_fragment_text_is_preserved_even_when_model_or_cache_rewrites_it(self):
        originals = ["只能", "块，就相当于", "我", "知道呀。", "一", "10万块钱", "完整但时间并未对齐的原始句子。", "这句较完整的原文允许明确纠错。"]
        proposals = ["只能最大。", "块，如或者", "我。", "知道呀！", "点。", "一百万块钱", "模型凭邻句补出的内容。", "这句较完整的原文允许清晰纠错。"]
        units = [{"id": f"u{i}", "source_id": "mic", "text": text, "start": i / 10,
                  "end": (i + 1) / 10, "approximate_window": i == 6} for i, text in enumerate(originals)]
        def answer(_key, _audio, prompt, _tokens, **_kwargs):
            context = json.loads(prompt.split("\nunits=", 1)[1].split("\n", 1)[0])
            self.assertEqual([u["text_locked"] for u in context], [False] * 6 + [True, False])
            return {"units": [{"unit_id": f"u{i}", "text": text,
                               "speaker_key": coarse._speaker_label("p2", "test")}
                              for i, text in enumerate(proposals)]}, {}
        call = Mock(side_effect=answer)
        first = coarse._process(self.request(units=units), call=call)
        second = coarse._process(self.request(units=units), call=call)
        for result in [first, second]:
            self.assertEqual([r["text"] for r in result["records"]], originals[:2] + proposals[2:4] + originals[4:7] + proposals[7:])
            self.assertTrue(all(r["speaker_key"] == "p2" for r in result["records"]))
        self.assertEqual(call.call_count, 1)
        self.assertEqual(second["reused_segments"], 1)

    def test_clear_text_names_stutters_and_fact_boundaries(self):
        terms = [{"term": "小张", "aliases": [], "misheard": ["小小章"]}]
        cases = [
            ("小小章", "小张", "小张"),
            ("小小章", "小李", "小小章"),
            ("我我觉得", "我觉得", "我觉得"),
            ("嗯，我觉得", "我觉得", "我觉得"),
            ("不不可以", "不可以", "不不可以"),
            ("不是不是", "不是", "不是不是"),
            ("不是不可以", "可以", "不是不可以"),
            ("这次可能需要小张来确认一下。", "这次需要小张来确认一下。", "这次可能需要小张来确认一下。"),
            ("如果明天确认我们就开始。", "明天确认我们就开始。", "如果明天确认我们就开始。"),
            ("这次需要小小章来确认一下。", "这次需要小张来确认一下。", "这次需要小张来确认一下。"),
            ("这次需要小张来确认一下。", "这次需要小李来确认一下。", "这次需要小张来确认一下。"),
        ]
        for original, proposed, expected in cases:
            with self.subTest(original=original):
                unit = {"text": original, "manual": False, "approximate_window": False}
                self.assertEqual(coarse._safe_text(unit, proposed, terms), expected)
        unit = {"text": "CODER", "manual": False, "approximate_window": False}
        self.assertEqual(coarse._safe_text(unit, "Qoder", [{"term": "Qoder", "misheard": ["coder"]}]), "CODER")
        # Synthetic shared person table uses 张三 as the canonical name and
        # 小张 as a confirmed spoken alias; preserve the confirmed-alias versus mishearing distinction.
        unit["text"] = "小小章"
        person_terms = [{"term": "张三", "aliases": ["小张", "张总"], "misheard": ["小章", "肖章"]}]
        self.assertEqual(coarse._safe_text(unit, "小张", person_terms), "小小章")
        self.assertEqual(coarse._safe_text(unit, "小李", person_terms), "小小章")

    def test_cleanup_rejects_neighbouring_turn_expansion_and_unrelated_replacement(self):
        original = "我们先确认方案再讨论时间。"
        unit = {"text": original, "manual": False, "approximate_window": False}
        for proposed in [original * 4, "苹果香蕉西瓜梨子葡萄草莓桃子。", "确认。"]:
            self.assertEqual(coarse._safe_text(unit, proposed, []), original)
        unit["text"] = "我们我们先确认方案，然后再讨论时间。"
        self.assertEqual(coarse._safe_text(unit, "我们先确认方案，然后再讨论时间。", []),
                         "我们先确认方案，然后再讨论时间。")

    def test_legacy_cleanup_reuses_history_and_only_revisits_known_wrong_name(self):
        terms = [{"term": "小张", "aliases": [], "misheard": ["小小章"]}]
        units = [{"id": "name", "source_id": "mic", "text": "小小章", "start": 0, "end": .5, "speaker_locked": True},
                 {"id": "other", "source_id": "mic", "text": "北京学校基本上都在海淀。", "start": .5, "end": 1, "speaker_locked": True}]
        request = self.request(units=units)
        with patch.object(coarse, "_cleanup_terms", return_value=terms):
            parsed = coarse._parse_request(request)
            ledger = coarse._load_ledger(self.cache / coarse.PROGRESS_NAME, parsed["session"], parsed["cache_id"])
            ledger["unit_results"] = {u["id"]: {
                "input_hash": coarse._unit_cache_identity(u, legacy=True),
                "result": {"unit_id": u["id"], "text": u["text"]}} for u in parsed["units"]}
            coarse._save_ledger(self.cache / coarse.PROGRESS_NAME, ledger)
            def answer(_key, _audio, prompt, _tokens, **_kwargs):
                self.assertEqual(json.loads(prompt.split("target_ids=", 1)[1].split("\n", 1)[0]), ["name"])
                return {"units": [{"unit_id": "name", "text": "小张"}]}, {}
            call = Mock(side_effect=answer)
            first = coarse._process(request, call=call)
            second = coarse._process(request, call=call)
            self.assertEqual([r["text"] for r in first["records"]], ["小张", units[1]["text"]])
            self.assertEqual(first["records"], second["records"])
            self.assertEqual(call.call_count, 1)

    def test_new_unrelated_term_does_not_invalidate_cleaned_units(self):
        request = self.request(units=[{"id": "name", "source_id": "mic", "text": "小小章", "start": 0, "end": 1, "speaker_locked": True}])
        call = Mock(return_value=({"units": [{"unit_id": "name", "text": "小张"}]}, {}))
        terms = [{"term": "小张", "aliases": [], "misheard": ["小小章"]}]
        with patch.object(coarse, "_cleanup_terms", return_value=terms):
            coarse._process(request, call=call)
        with patch.object(coarse, "_cleanup_terms", return_value=terms + [{"term": "在场", "misheard": ["再场"]}]):
            coarse._process(request, call=call)
        self.assertEqual(call.call_count, 1)

    def test_complete_sentence_correction_preserves_numeric_tokens(self):
        originals = ["你不是可以从17号开始吗？", "这次计划用10万元投放这个区城。", "这次计划用10万元投放这个区城。"]
        proposals = ["你不是可以从十七号开始吗？", "这次计划用100万元投放这个区域。", "这次计划用10万元投放这个区域。"]
        units = [{"id": f"u{i}", "source_id": "mic", "text": text, "start": i / 10,
                  "end": (i + 1) / 10} for i, text in enumerate(originals)]
        call = Mock(return_value=({"units": [{"unit_id": f"u{i}", "text": text,
            "speaker_key": coarse._speaker_label("p2", "test")} for i, text in enumerate(proposals)]}, {}))
        for _ in range(2):
            result = coarse._process(self.request(units=units), call=call)
            self.assertEqual([r["text"] for r in result["records"]], originals[:2] + proposals[2:])
        self.assertEqual(call.call_count, 1)

    def test_semantic_timeout_skip_can_recover_on_explicit_retry(self):
        request = coarse._parse_request(self.request(units=[
            {"unit_id": "residual", "source_id": "mic", "text": "原句。", "start": 0, "end": .5}]))
        records = {"residual": {"unit_id": "residual", "text": "校订。"}}
        ledger = {"reserved_yuan": 0.0}
        progress = self.cache / coarse.PROGRESS_NAME
        call = Mock(return_value=({"units": [{"unit_id": "residual",
                      "speaker_key": coarse._speaker_label("p2", "test")}]}, {}))
        self.assertEqual(coarse._semantic_speaker_pass(request, records, ledger, progress, call, 0,
                         lambda: coarse.WALL_TIMEOUT_SECONDS), (True, False))
        self.assertEqual(coarse._semantic_speaker_pass(request, records, ledger, progress, call, 0,
                         lambda: 0), (True, False))
        call.assert_not_called()
        request["allow_retry"] = True
        self.assertEqual(coarse._semantic_speaker_pass(request, records, ledger, progress, call, 0,
                         lambda: 0), (False, True))
        self.assertEqual(records["residual"]["speaker_key"], "p2")
        self.assertEqual(call.call_count, 1)

    def test_large_semantic_pass_batches_and_retries_only_failed_batch(self):
        units = [{"unit_id": f"short-{index}", "source_id": "mic", "text": "嗯",
                  "start": index / 1000, "end": (index + 1) / 1000}
                 for index in range(coarse.MAX_SEMANTIC_TARGETS + 1)]
        request = self.request(units=units)
        calls = []
        fail_second_once = True

        def model_call(_key, audio, prompt, _tokens, **_kwargs):
            nonlocal fail_second_once
            if audio is not None:
                return {"units": [{"unit_id": unit["unit_id"], "text": unit["text"]}
                                  for unit in units]}, {}
            targets = json.loads(prompt.split("target_ids=", 1)[1].split("\n", 1)[0])
            calls.append(targets)
            self.assertLessEqual(len(targets), coarse.MAX_SEMANTIC_TARGETS)
            if len(calls) == 2 and fail_second_once:
                fail_second_once = False
                raise coarse.CoarseAudioError("synthetic_second_batch_failure")
            return {"units": [{"unit_id": unit_id, "speaker_key": coarse._speaker_label("p2", "test")}
                               for unit_id in targets]}, {}

        first = coarse._process(request, call=model_call)
        self.assertEqual(first["warning"], "semantic_assignment_incomplete")
        self.assertEqual([len(batch) for batch in calls], [coarse.MAX_SEMANTIC_TARGETS, 1])
        ledger = json.loads((self.cache / coarse.PROGRESS_NAME).read_text())
        entries = ledger["semantic_assignment_batches"]
        self.assertEqual(entries["batch-0000"]["status"], "complete")
        self.assertEqual(entries["batch-0001"]["status"], "failed")
        self.assertEqual(sum(row.get("speaker_key") == "p2" for row in first["records"]),
                         coarse.MAX_SEMANTIC_TARGETS)

        retry = dict(request)
        retry["request"] = dict(request["request"], trigger="manual_retry")
        second = coarse._process(retry, call=model_call)
        self.assertNotIn("warning", second)
        self.assertEqual([len(batch) for batch in calls], [coarse.MAX_SEMANTIC_TARGETS, 1, 1])
        self.assertEqual(sum(row.get("speaker_key") == "p2" for row in second["records"]), len(units))
        self.assertEqual(entries["batch-0000"]["status"], "complete")


if __name__ == "__main__":
    unittest.main()


class CoarseBudgetCeilingTests(unittest.TestCase):
    def test_reservation_is_refused_past_the_meeting_ceiling(self):
        ledger = {"reserved_yuan": coarse.MAX_RESERVED_YUAN_PER_MEETING - 1.0}
        coarse._reserve_budget(ledger, 0.5)
        self.assertAlmostEqual(ledger["reserved_yuan"], coarse.MAX_RESERVED_YUAN_PER_MEETING - 0.5)
        with self.assertRaises(coarse.CoarseAudioError) as raised:
            coarse._reserve_budget(ledger, 1.0)
        self.assertEqual(str(raised.exception), "budget_exceeded")
        # A refused reservation leaves the ledger unchanged.
        self.assertAlmostEqual(ledger["reserved_yuan"], coarse.MAX_RESERVED_YUAN_PER_MEETING - 0.5)
