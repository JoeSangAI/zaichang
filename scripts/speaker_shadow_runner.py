#!/usr/bin/env python3
"""Compare frozen online slots with local Community-1 on a public fixture.

The raw whole-meeting result is the direct diarization evaluation. A separate
helper probe blanks two turns only in a disposable copy to inspect refinement;
it is reported independently and is not treated as raw-model accuracy.
No production meeting, speaker name, profile write, or network path is used.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PUBLIC = ROOT / "native/validation-workflow/public-speech-fixture"
DEFAULT_BASELINE = ROOT / "native/validation-workflow/speaker-repair-public-remote.json"
DEFAULT_HELPER = ROOT / ".runtime/build/会议助理开发QA.app/Contents/Helpers/会议采集离线QA.app/Contents/MacOS/MeetingCapture"
DEFAULT_MODELS = ROOT / "native/local-speaker-install/runtime-models"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)


def score_raw_segments(turns, segments):
    """Score anonymous clusters by turn overlap, maximizing the label mapping."""
    clusters = sorted({str(row["cluster"]) for row in segments})
    rows = []
    for turn in turns:
        overlap = {}
        for segment in segments:
            seconds = max(0.0, min(turn["end"], segment["end"]) - max(turn["start"], segment["start"]))
            if seconds > 0:
                key = str(segment["cluster"])
                overlap[key] = overlap.get(key, 0.0) + seconds
        rows.append({"cluster": max(overlap, key=overlap.get) if overlap else None,
                     "overlap_seconds": round(sum(overlap.values()), 3),
                     "source_speaker_id": turn["source_speaker_id"]})
    people = sorted({turn["source_speaker_id"] for turn in turns})
    counts = {cluster: {person: 0 for person in people} for cluster in clusters}
    for row in rows:
        if row["cluster"] is not None:
            counts[row["cluster"]][row["source_speaker_id"]] += 1

    from functools import lru_cache

    @lru_cache(maxsize=None)
    def assign(index, used_mask):
        if index == len(clusters):
            return 0, ()
        cluster = clusters[index]
        options = [(None, 0, used_mask)]
        options.extend((person, counts[cluster][person], used_mask | (1 << person_index))
                       for person_index, person in enumerate(people)
                       if not used_mask & (1 << person_index))
        best_score, best_tail, best_label = -1, (), None
        for label, gained, next_mask in options:
            tail_score, tail = assign(index + 1, next_mask)
            score = gained + tail_score
            if score > best_score:
                best_score, best_tail, best_label = score, tail, label
        return best_score, (best_label,) + best_tail

    best_correct, labels = assign(0, 0)
    mapping = dict(zip(clusters, labels))
    covered = sum(row["cluster"] is not None for row in rows)
    return {"segments": len(segments), "clusters": len(clusters), "turns": len(turns),
            "covered_turns": covered, "unknown_turns": len(turns) - covered,
            "correct_after_anonymous_label_permutation": best_correct,
            "wrong_turns_after_anonymous_label_permutation": covered - best_correct,
            "accuracy_when_assigned": best_correct / covered if covered else None,
            "coverage": covered / len(turns), "anonymous_cluster_to_public_speaker_mapping": mapping,
            "turn_predictions": rows}


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, default=DEFAULT_HELPER)
    parser.add_argument("--models", type=Path, default=DEFAULT_MODELS)
    parser.add_argument("--raw-cli", type=Path, default=None)
    parser.add_argument("--fixture-dir", type=Path, default=DEFAULT_PUBLIC)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    parser.add_argument("--voiceprint-checks", type=Path, default=None,
                        help="Optional old frozen receipt; never treated as a fresh evaluation")
    parser.add_argument("--out-root", type=Path, default=ROOT / ".runtime/speaker_shadow")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.raw_cli is None:
        candidates = list((ROOT / ".runtime/speaker_shadow").glob("*/swift-build/arm64-apple-macosx/debug/Shadow"))
        args.raw_cli = max(candidates, key=lambda path: path.stat().st_mtime) if candidates else Path("/missing/raw-community-shadow")
    public = args.fixture_dir.expanduser().resolve()
    fixture_meta = read_json(public / "sources.json")
    reference = read_json(public / "reference.json")
    baseline = read_json(args.baseline.expanduser().resolve())
    voiceprint = read_json(args.voiceprint_checks.expanduser().resolve()) if args.voiceprint_checks else None
    if fixture_meta.get("license") != "CC BY 4.0" or fixture_meta.get("dataset") != "openslr/librispeech_asr":
        raise SystemExit("public_fixture_provenance_invalid")
    if baseline.get("type") != "public_recording_speaker_probe" or baseline.get("network") is not False:
        raise SystemExit("online_baseline_invalid")
    if voiceprint is not None and (voiceprint.get("type") != "independent_saved_voice_feature_review" or voiceprint.get("capture") is not False or voiceprint.get("cloud") is not False):
        raise SystemExit("voiceprint_historical_receipt_invalid")
    if not args.helper.is_file() or not os.access(args.helper, os.X_OK):
        raise SystemExit("offline_helper_unavailable")
    if not args.raw_cli.is_file() or not os.access(args.raw_cli, os.X_OK):
        raise SystemExit("raw_community_shadow_cli_unavailable")
    if not (args.models / "community-1/Segmentation.mlmodelc").is_dir():
        raise SystemExit("community_model_unavailable")

    turns = reference["turns"]
    online = [row["speaker"]["cluster_id"] for row in baseline["annotation_results"]]
    if len(turns) != len(online) or len(turns) != 6:
        raise SystemExit("fixture_turn_count_mismatch")
    # Slot IDs and public source-speaker IDs are both anonymized here.
    truth = [0 if turn["source_speaker_id"] == "2035" else 1 for turn in turns]
    online_correct = sum(pred == expected for pred, expected in zip(online, truth))

    out = args.out_root / str(uuid.uuid4()).upper()
    cache = out / "cache" / str(uuid.uuid4()).upper()
    cache.mkdir(parents=True, mode=0o700)
    out.mkdir(parents=True, exist_ok=True, mode=0o700)
    session = str(uuid.uuid4())
    origin = 1000.0
    pcm = (public / "input.pcm").read_bytes()
    if len(pcm) % 2 or len(pcm) > 2_000_000:
        raise SystemExit("fixture_pcm_invalid")
    raw_started = time.monotonic()
    raw_process = subprocess.run(
        [str(args.raw_cli), str(public / "input.pcm"), str(args.models / "community-1")],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=300, check=False,
    )
    raw_elapsed = time.monotonic() - raw_started
    (out / "community-1-raw.log").write_text(raw_process.stdout + "\n[stderr]\n" + raw_process.stderr, encoding="utf-8")
    if raw_process.returncode != 0:
        raise SystemExit(f"raw_community_shadow_failed:{raw_process.returncode}; see {out / 'community-1-raw.log'}")
    raw_payload = json.loads(next(line for line in reversed(raw_process.stdout.splitlines()) if line.startswith("{")))
    raw_score = score_raw_segments(turns, raw_payload.get("segments", []))
    # Make a private, disposable cache copy. Chunk format mirrors the app's
    # 16 kHz mono PCM journal; the source fixture itself remains untouched.
    manifest_chunks = []
    for index, start in enumerate(range(0, len(pcm), 320_000)):
        chunk = pcm[start : start + 320_000]
        name = f"remote-{index:06d}.pcm"
        (cache / name).write_bytes(chunk)
        os.chmod(cache / name, 0o600)
        manifest_chunks.append({"index": index, "start_sample": start // 2, "bytes": len(chunk), "sha256": sha(chunk)})
    save_json(cache / "meeting.json", {"session": session, "capture_origin_uptime": origin})
    save_json(cache / "remote-manifest.json", {
        "schema": 1, "track": "remote", "format": "pcm_s16le", "sample_rate": 16000,
        "channels": 1, "origin_uptime": origin, "ended": True, "audio_cleaned": False,
        "written_bytes": len(pcm), "chunks": manifest_chunks,
    })

    online_events = []
    for index, turn in enumerate(turns):
        assigned = online[index] if index < 4 else None
        speaker = ({"basis": "anonymous_cluster", "cluster_id": assigned, "source_id": "remote", "epoch": "public-frozen"}
                   if assigned is not None else {"basis": "unknown"})
        online_events.append({
            "type": "segment", "session": session, "track": "remote", "source_id": "remote",
            "epoch": "public-frozen", "segment_id": f"turn-{index}", "revision": 1,
            "start": turn["start"], "end": turn["end"], "text": f"public-turn-{index}",
            "final": True, "end_time_known": True, "quality_flags": [], "speaker": speaker,
        })
    # These overlapping probe rows are unlabeled copies of the first two
    # anchored intervals. If Community-1 anchors and timestamps are flowing,
    # the conservative refinement path should be able to label them without
    # using the target turn's own label as an anchor.
    for index, turn_index in enumerate((0, 1)):
        turn = turns[turn_index]
        lo, hi = turn["start"] + 1.0, turn["end"] - 1.0
        online_events.append({
            "type": "segment", "session": session, "track": "remote", "source_id": "remote",
            "epoch": "public-frozen", "segment_id": f"anchor-probe-{index}", "revision": 1,
            "start": lo, "end": hi, "text": f"unlabeled-anchor-probe-{index}",
            "final": True, "end_time_known": True, "quality_flags": [], "speaker": {"basis": "unknown"},
        })
    transcript = cache / "remote-transcript.jsonl"
    transcript.write_text("".join(json.dumps(event, ensure_ascii=False) + "\n" for event in online_events), encoding="utf-8")
    os.chmod(transcript, 0o600)

    request = {"folder": str(cache), "session": session, "allow_unsealed": False}
    started = time.monotonic()
    process = subprocess.run(
        [str(args.helper), "--refine-meeting-speakers", str(args.models)],
        input=json.dumps(request, ensure_ascii=False) + "\n", text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180, check=False,
    )
    elapsed = time.monotonic() - started
    if process.returncode != 0:
        (out / "helper.stderr.txt").write_text(process.stderr[-8000:], encoding="utf-8")
        raise SystemExit(f"community_helper_failed:{process.returncode}")
    result = json.loads(process.stdout)
    records = result.get("records", [])
    corrected = {}
    for record in records:
        event_id = record.get("segment_id")
        speaker = record.get("speaker") or {}
        if event_id and speaker.get("basis") == "anonymous_cluster":
            corrected[event_id] = speaker.get("cluster_id")
    recovered_predictions = [corrected.get(f"turn-{index}") for index in (4, 5)]
    recovered_correct = sum(pred is not None and pred == truth[index] for pred, index in zip(recovered_predictions, (4, 5)))
    recovered_coverage = sum(pred is not None for pred in recovered_predictions)
    anchor_probe_predictions = [corrected.get(f"anchor-probe-{index}") for index in (0, 1)]
    anchor_probe_expected = [online[0], online[1]]
    anchor_probe_assigned = sum(pred is not None for pred in anchor_probe_predictions)
    anchor_probe_correct = sum(pred == expected for pred, expected in zip(anchor_probe_predictions, anchor_probe_expected) if pred is not None)

    report = {
        "schema": 1,
        "type": "public_speaker_shadow_evaluation",
        "fixture": {"dataset": fixture_meta["dataset"], "revision": fixture_meta["revision"], "license": fixture_meta["license"], "seconds": reference["input_seconds"], "turns": len(turns), "people": 2, "pcm_sha256": sha(pcm)},
        "method": {
            "online_baseline": "existing frozen public_recording_speaker_probe anonymous slots",
            "community1": "standalone local FluidAudio Community-1 whole-meeting raw diarization; anonymous cluster IDs aligned to public clip-speaker labels by best permutation",
            "community1_anchor_refinement_probe": "existing offline QA helper on a private disposable journal; zero candidate assignments observed, so it does not establish accuracy or explain why the conservative path returned no change",
            "voiceprint": "historical frozen receipt only; not re-run in this task and not pooled into a cross-method accuracy figure",
        },
        "online_baseline": {"turns": len(turns), "correct": online_correct, "accuracy": online_correct / len(turns), "coverage": len(turns) / len(turns), "wrong_speaker_assignments": len(turns) - online_correct, "unknown": 0, "wall_seconds_prior_probe": baseline.get("wall_seconds"), "model_seconds_prior_probe": baseline.get("load_seconds")},
        "community1_raw_full_meeting": {**raw_score, "input_seconds": raw_payload.get("input_seconds"), "model_load_seconds": raw_payload.get("model_load_seconds"), "inference_wall_seconds": raw_payload.get("wall_seconds"), "process_wall_seconds": raw_elapsed, "cluster_segments": raw_payload.get("segments")},
        "community1_shadow_recovery": {"eligible_unknown_turns": 2, "assigned": recovered_coverage, "correct": recovered_correct, "accuracy_when_assigned": recovered_correct / recovered_coverage if recovered_coverage else None, "coverage": recovered_coverage / 2, "wrong_speaker_assignments": recovered_coverage - recovered_correct, "unknown": 2 - recovered_coverage, "wall_seconds_including_model_startup": elapsed, "candidate_records": len(records), "predictions": recovered_predictions},
        "community1_anchor_mapping_control": {"unlabeled_probe_segments": 2, "assigned": anchor_probe_assigned, "correct_vs_existing_online_slot": anchor_probe_correct, "accuracy_when_assigned": anchor_probe_correct / anchor_probe_assigned if anchor_probe_assigned else None, "predictions": anchor_probe_predictions},
        "voiceprint_historical_frozen_receipt_not_rerun": ({"present": False} if voiceprint is None else {"present": True, "rerun_this_task": False, "profiles": voiceprint.get("profiles"), "heldout_examples": voiceprint.get("independent_examples"), "accepted": voiceprint.get("accepted"), "unknown": voiceprint.get("unknown"), "wrong_names": voiceprint.get("wrong_names"), "coverage_in_old_receipt": voiceprint.get("accepted", 0) / voiceprint.get("independent_examples", 1)}),
        "resource": {"input_seconds": reference["input_seconds"], "helper_wall_seconds": elapsed, "cloud": False, "capture": False, "production_thresholds_changed": False, "production_identity_write": False, "evaluation_audio_used_for_learning": False},
        "limitations": [
            "Online public baseline and Community-1 labels are anonymous clusters, not real-person names.",
            "Community-1 raw-cluster score uses whole-meeting output and public clip-level speaker IDs; best permutation accounts for arbitrary cluster labels. The source labels are not word/frame-level diarization truth.",
            "Any voiceprint counts shown are copied from an old frozen receipt, not re-run or validated in this task; they cannot be compared as if they came from this LibriSpeech fixture.",
            "The public fixture contains separated read-speech turns; it does not measure overlap, noisy meeting speech, Mandarin, cross-track identity, one-word replies, or long-session resource behavior.",
        ],
    }
    save_json(out / "result.json", result)
    save_json(out / "report.json", report)
    summary = [
        "# Speaker shadow run (public fixture)", "",
        f"- Fixture: LibriSpeech validation, CC BY 4.0; 2 speakers, {reference['input_seconds']:.2f} seconds, 6 turns.",
        f"- Existing online anonymous slots: {online_correct}/6 correct; no names or unknowns in this fixture; prior recorded wall time {baseline.get('wall_seconds'):.2f}s (model load {baseline.get('load_seconds'):.2f}s).",
        f"- Community-1 raw whole-meeting: {raw_score['correct_after_anonymous_label_permutation']}/{raw_score['turns']} turns correct after anonymous label permutation; coverage {raw_score['covered_turns']}/{raw_score['turns']}; {raw_score['segments']} output segments across {raw_score['clusters']} clusters; model load {raw_payload.get('model_load_seconds'):.2f}s, inference {raw_payload.get('wall_seconds'):.2f}s.",
        f"- Community-1 recovery: {recovered_coverage}/2 deliberately unknown turns assigned; {recovered_correct}/{recovered_coverage} assigned turns matched public reference; helper wall time {elapsed:.2f}s including startup.",
        f"- Existing anchor-refinement helper probe: {anchor_probe_assigned}/2 unlabeled controls and {recovered_coverage}/2 unknown turns received assignments ({len(records)} candidate records total). Its all-empty result is inconclusive about conservative rejection versus input incompatibility; it is not an accuracy result. Raw Community-1 clusters above are the direct full-meeting result.",
        ("- Voiceprint: no historical receipt supplied; no current held-out voiceprint evaluation was run." if voiceprint is None else f"- Historical frozen voiceprint receipt (not re-run in this task): {voiceprint.get('accepted')}/{voiceprint.get('independent_examples')} accepted, {voiceprint.get('unknown')} unknown, {voiceprint.get('wrong_names')} wrong names. This is a different cohort, not a current validation or three-way same-set comparison."),
        "- Local-only; no capture, cloud, name write, threshold change, or evaluation-audio learning. Outputs are private to this worktree runtime folder.",
        "- This fixture does not validate overlap, Mandarin, noisy meetings, short replies, cross-track identity, or four-hour resource use.",
    ]
    (out / "report.md").write_text("\n".join(summary) + "\n", encoding="utf-8")
    os.chmod(out / "report.md", 0o600)
    print(json.dumps({"out": str(out), "online_correct": f"{online_correct}/6", "community_raw": f"{raw_score['correct_after_anonymous_label_permutation']}/{raw_score['turns']} turns, {raw_score['segments']} segments, inference {raw_payload.get('wall_seconds'):.3f}s", "community_recovery": f"{recovered_correct}/{recovered_coverage} assigned, coverage {recovered_coverage}/2", "helper_seconds": round(elapsed, 3), "voiceprint_historical_receipt_only": voiceprint is not None}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
