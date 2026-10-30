#!/usr/bin/env python3
"""Build, verify, and install 在场 into a per-user Applications folder."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import plistlib
import platform
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import app_version

WORK = ROOT / ".runtime/build/standalone"
QA_APP = WORK / "在场独立版QA.app"
STAGE = WORK / ".在场.app.installing"
APP = WORK / "在场.app"
HELPER_SOURCE = QA_APP / "Contents/Helpers/会议采集离线QA.app"
HELPER_RELATIVE = Path("Contents/Resources/Runtime/native/nightly-build/会议采集候选.app")
PYTHON_MODULES = (
    "adapter.py", "assistant_runtime.py", "codex_runtime.py", "audio_sources.py",
    "capture_supervisor.py", "coarse_audio.py", "dual_track.py", "fee_meter.py",
    "gui_worker.py", "identity_bridge.py", "identity_control.py", "identity_session.py",
    "live_trial.py", "meeting_context.py", "model_standby.py", "public_audio_trial.py",
    "runtime_config.py", "shared_terms.py", "shared_people.py", "speaker_identity.py",
)
VERSION = app_version.VERSION
BUILD = app_version.BUILD
BUNDLE_ID = "com.joesang.zaichang.standalone"


def run(*args: str, capture_output: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run([str(arg) for arg in args], check=True, capture_output=capture_output)


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def process_guard() -> None:
    output = run("ps", "-axo", "comm=", capture_output=True).stdout.decode(errors="replace")
    if any(Path(name.strip()).name in {"MeetingCapture", "IntegratedCapture"} for name in output.splitlines()):
        raise SystemExit("在场正在录音或处理音频，请结束后再构建或安装。")


def app_is_running() -> bool:
    output = run("ps", "-axo", "comm=", capture_output=True).stdout.decode(errors="replace")
    return any(Path(name.strip()).name == "MeetingAssistant" for name in output.splitlines())


def copy_runtime(runtime: Path) -> dict[str, str]:
    runtime.mkdir(parents=True, exist_ok=True)
    result = {}
    for name in PYTHON_MODULES:
        source = ROOT / name
        if not source.is_file():
            raise FileNotFoundError(f"Missing app runtime source: {name}")
        destination = runtime / name
        shutil.copy2(source, destination)
        result[name] = sha(destination)
    for name in ["agent-plugin"]:
        source = ROOT / name
        if source.is_dir():
            shutil.copytree(source, runtime / name, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store"))
    assets = runtime / "native/assets"
    assets.mkdir(parents=True, exist_ok=True)
    for name in ("MeetingAssistantIcon.icns", "MeetingAssistant.icns"):
        shutil.copy2(ROOT / "native/assets" / name, assets / name)

    # Only portable runtime resources are copied. Build logs, caches, SDK source,
    # local profiles, and meeting data stay outside the app bundle.
    speaker = ROOT / "native/local-speaker-install"
    speaker_target = runtime / "native/local-speaker-install"
    models = speaker / "runtime-models"
    shutil.copytree(models, speaker_target / "runtime-models")
    license_dir = runtime / "ThirdPartyLicenses"
    license_dir.mkdir(parents=True, exist_ok=True)
    for name in ["Apache-2.0.txt", "OpenMDW-1.1.txt", "ThirdPartyNotices.md"]:
        shutil.copy2(ROOT / "scripts/licenses" / name, license_dir / name)

    embedding = ROOT / "native/local-embedding-install"
    embedding_target = runtime / "native/local-embedding-install"
    shutil.copytree(embedding / "runtime", embedding_target / "runtime")
    shutil.copy2(embedding / "3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx",
                 embedding_target / "3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")
    shutil.copy2(embedding / "c-api.h", embedding_target / "c-api.h")
    for source in [ROOT / name for name in PYTHON_MODULES]:
        compile(source.read_text(encoding="utf-8"), str(source), "exec")
    return result


def rewrite_bundle(stage: Path, runtime_hashes: dict[str, str]) -> dict:
    runtime = stage / "Contents/Resources/Runtime"
    runtime_python_hashes = copy_runtime(runtime)
    if runtime_hashes != runtime_python_hashes:
        raise RuntimeError("Runtime sources changed while the app was being staged")

    helper_source = HELPER_SOURCE
    helper_target = stage / HELPER_RELATIVE
    helper_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(helper_source, helper_target)
    # The production helper is shipped at Runtime/native/nightly-build; remove
    # the offline-only helper retained inside the source QA app.
    shutil.rmtree(stage / "Contents/Helpers/会议采集离线QA.app")
    helper_info_path = helper_target / "Contents/Info.plist"
    helper_info = plistlib.loads(helper_info_path.read_bytes())
    helper_info.update({
        "CFBundleIdentifier": "com.joesang.zaichang.standalone.capture",
        "CFBundleName": "在场声音采集",
        "CFBundleDisplayName": "在场声音采集",
        "CFBundleVersion": BUILD,
        "CFBundleShortVersionString": VERSION,
        "ZaichangEdition": "standalone",
        "DataRootName": "ZaichangStandalone",
        "SelfContainedRuntime": True,
        "OfflineOnly": False,
        "OfflineQA": False,
        "DevelopmentWorkspace": False,
        "KeychainAuthorized": True,
        "LocalRecordingAllowed": True,
        "PublicAudioASRTestAllowed": False,
        "HumanIdentityUseAuthorized": False,
        "TrialArmed": False,
        "TrialCandidate": True,
        "CandidateRevision": "nightly",
        "ClickStartsTrial": True,
    })
    for key in ["AdapterRoot", "AppLockPath"]:
        helper_info.pop(key, None)
    helper_info_path.write_bytes(plistlib.dumps(helper_info, sort_keys=True))

    info_path = stage / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.update({
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleName": "在场",
        "CFBundleDisplayName": "在场",
        "CFBundleVersion": BUILD,
        "CFBundleShortVersionString": VERSION,
        "ZaichangEdition": "standalone",
        "DataRootName": "ZaichangStandalone",
        "SelfContainedRuntime": True,
        "OfflineOnly": False,
        "OfflineQA": False,
        "DevelopmentWorkspace": False,
        "KeychainAuthorized": True,
        "LocalRecordingAllowed": True,
        "PublicAudioASRTestAllowed": False,
        "HumanIdentityUseAuthorized": False,
        "TrialArmed": False,
        "TrialCandidate": True,
        "CandidateRevision": "nightly",
        "ClickStartsTrial": True,
        "NSMicrophoneUsageDescription": "在场在你开始录音后收录会议声音，并将原始音频保存在本机。",
        "NSAudioCaptureUsageDescription": "在场在你开始录音后收录电脑会议声音，并将原始音频保存在本机。",
    })
    for key in ["AdapterRoot", "DesktopDelivery", "AppLockPath"]:
        info.pop(key, None)
    info_path.write_bytes(plistlib.dumps(info, sort_keys=True))

    app_binary = stage / "Contents/MacOS/MeetingAssistant"
    helper_binary = helper_target / "Contents/MacOS/MeetingCapture"
    if not app_binary.is_file() or not helper_binary.is_file():
        raise RuntimeError("Built app is missing its UI or capture helper")
    return {"runtime_python_sha256": runtime_python_hashes,
            "ui_sha256": sha(app_binary), "capture_helper_sha256": sha(helper_binary)}


def verify(stage: Path) -> dict:
    run("codesign", "--verify", "--deep", "--strict", str(stage))
    info = plistlib.loads((stage / "Contents/Info.plist").read_bytes())
    helper_path = stage / HELPER_RELATIVE
    helper_info = plistlib.loads((helper_path / "Contents/Info.plist").read_bytes())
    expected = {"ZaichangEdition": "standalone", "DataRootName": "ZaichangStandalone",
                "SelfContainedRuntime": True, "OfflineQA": False, "LocalRecordingAllowed": True,
                "TrialCandidate": True, "ClickStartsTrial": True}
    if any(info.get(key) != value for key, value in expected.items()):
        raise RuntimeError("App bundle metadata does not match the standalone release policy")
    if any(helper_info.get(key) != value for key, value in expected.items()):
        raise RuntimeError("Capture helper metadata does not match the standalone release policy")
    if "AdapterRoot" in info or "AdapterRoot" in helper_info:
        raise RuntimeError("App bundle contains a build-machine source path")
    runtime = stage / "Contents/Resources/Runtime"
    if not all((runtime / name).is_file() for name in PYTHON_MODULES):
        raise RuntimeError("App bundle does not contain the complete Python runtime")
    if not (runtime / "native/local-speaker-install/runtime-models/Nemotron3Diarizer_low.mlmodelc/weights/weight.bin").is_file():
        raise RuntimeError("App bundle is missing the live speaker model")
    if not (runtime / "native/local-speaker-install/runtime-models/learnable_sil_emb.bin").is_file():
        raise RuntimeError("App bundle is missing the Nemotron silence embedding required by FluidAudio")
    if not all((runtime / "ThirdPartyLicenses" / name).is_file() for name in
               ["Apache-2.0.txt", "OpenMDW-1.1.txt", "ThirdPartyNotices.md"]):
        raise RuntimeError("App bundle is missing third-party license notices")
    for path in stage.rglob("*.py"):
        compile(path.read_text(encoding="utf-8"), str(path), "exec")
    return {"app_bundle_signature": "valid", "app_metadata": "standalone release",
            "python_modules": len(PYTHON_MODULES), "adapter_root_embedded": False,
            "source_bundle_embedded": False}


def build_stage() -> dict:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("在场公开版需要安装在 macOS 15+ 的 Apple Silicon 电脑上。")
    if sys.version_info < (3, 12):
        raise SystemExit("安装构建工具需要 Python 3.12 或更新版本。")
    process_guard()
    missing = [path for path in [ROOT / "native/local-speaker-install/sdk/Package.swift",
                                 ROOT / "native/local-speaker-install/sdk/LocalDependencies/NemoTextProcessing.xcframework/Info.plist",
                                 ROOT / "native/local-embedding-install/c-api.h"] if not path.exists()]
    if missing:
        raise SystemExit("依赖未准备完成，请先运行 python3 scripts/bootstrap_dependencies.py")
    subprocess.run([sys.executable, str(ROOT / "scripts/build_offline.py"), "--edition", "standalone"], cwd=ROOT, check=True)
    subprocess.run([sys.executable, str(ROOT / "scripts/offline_check.py"), "--edition", "standalone"], cwd=ROOT, check=True)
    if STAGE.exists():
        raise SystemExit(f"发现未完成的暂存安装：{STAGE}。请检查后再重试。")
    if not QA_APP.is_dir():
        raise RuntimeError("离线构建完成后没有找到 QA App")
    if APP.exists():
        old_build = APP.with_name(f"在场.previous-{dt.datetime.now().strftime('%Y%m%d%H%M%S')}.app")
        APP.rename(old_build)
    STAGE.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(QA_APP, STAGE, symlinks=True)
    build_sources = json.loads((WORK / "source-receipt.json").read_text())
    result = rewrite_bundle(STAGE, {name: sha(ROOT / name) for name in PYTHON_MODULES})
    result.update(build_sources=build_sources, install_source=str(QA_APP))
    run("codesign", "--force", "--deep", "--sign", "-", str(STAGE))
    result.update(verify(STAGE))
    STAGE.rename(APP)

    return result


def install(destination: Path) -> dict:
    if app_is_running():
        raise SystemExit("请先退出当前运行的在场，再更新应用。会议资料会继续保存在本机。")
    result = build_stage()
    destination = destination.expanduser().absolute()
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink():
        raise RuntimeError("Install destination cannot be a symbolic link")
    staged_install = destination.with_name(f".{destination.name}.installing")
    backup = destination.with_name(f"{destination.name}.previous-{dt.datetime.now().strftime('%Y%m%d%H%M%S')}")
    if staged_install.exists():
        shutil.rmtree(staged_install)
    shutil.copytree(APP, staged_install, symlinks=True)
    result.update(installed_path=str(destination), installed_app_sha256=sha(staged_install / "Contents/MacOS/MeetingAssistant"),
                  data_directory=str(Path.home() / "Library/Application Support/ZaichangStandalone"),
                  capture_started=False)
    verify(staged_install)
    # The user may have reopened 在场 while the bundle was being copied and
    # verified. Recheck immediately before replacing the installed app so an
    # active recorder is never interrupted by an update.
    if app_is_running():
        shutil.rmtree(staged_install)
        raise SystemExit("安装期间在场已重新打开；已取消更新，请先退出在场后重试。会议资料会继续保存在本机。")
    process_guard()
    if destination.exists():
        destination.rename(backup)
    try:
        staged_install.rename(destination)
    except BaseException:
        if backup.exists() and not destination.exists():
            backup.rename(destination)
        raise
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return result


def default_destination(home: Path = Path.home() / "Applications/在场.app", system: Path = Path("/Applications/在场.app")) -> Path:
    # Update the copy the user already has instead of leaving a stale one behind.
    info = system / "Contents/Info.plist"
    if home.exists() or system.is_symlink() or not info.is_file():
        return home
    return system if plistlib.loads(info.read_bytes()).get("CFBundleIdentifier") == BUNDLE_ID else home


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=default_destination())
    parser.add_argument("--build-only", action="store_true", help="Build and verify the bundle without installing it")
    args = parser.parse_args()
    if args.build_only:
        result = build_stage()
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        install(args.destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
