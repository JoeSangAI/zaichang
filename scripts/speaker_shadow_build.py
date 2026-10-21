#!/usr/bin/env python3
"""Build the isolated Community-1 raw diarization probe into ignored runtime state."""
from __future__ import annotations

import argparse
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SDK = ROOT / "native/local-speaker-install/sdk"
PACKAGE = ROOT / ".runtime/speaker_shadow/raw-cli/swift-package"
SCRATCH = ROOT / ".runtime/speaker_shadow/raw-cli/swift-build"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, default=DEFAULT_SDK, help="Existing local FluidAudio source package; read only")
    args = parser.parse_args()
    sdk = args.sdk.expanduser().resolve()
    if not sdk.is_dir():
        raise SystemExit(f"local_speaker_sdk_missing:{sdk}")
    source = ROOT / "native/MeetingSpeakerShadow.swift"
    if not source.is_file():
        raise SystemExit(f"shadow_source_missing:{source}")
    package = PACKAGE / "Sources/Shadow"
    package.mkdir(parents=True, exist_ok=True)
    sdk_path = str(sdk).replace("\\", "\\\\").replace('"', '\\"')
    (PACKAGE / "Package.swift").write_text(
        "// swift-tools-version: 6.0\n"
        "import PackageDescription\n"
        "let package = Package(name: \"SpeakerShadow\", platforms: [.macOS(.v14)], "
        f"dependencies: [.package(path: \"{sdk_path}\")], "
        "targets: [.executableTarget(name: \"Shadow\", dependencies: [.product(name: \"FluidAudio\", package: \"sdk\")])], "
        "swiftLanguageModes: [.v5])\n",
        encoding="utf-8",
    )
    (package / "main.swift").write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
    env = dict(os.environ)
    result = subprocess.run(
        ["swift", "build", "--package-path", str(PACKAGE), "--scratch-path", str(SCRATCH)],
        env=env, check=False,
    )
    if result.returncode:
        return result.returncode
    executable = SCRATCH / "arm64-apple-macosx/debug/Shadow"
    print(executable)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
