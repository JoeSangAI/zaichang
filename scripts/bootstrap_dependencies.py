#!/usr/bin/env python3
"""Fetch pinned, open-source runtime dependencies into ignored native/local-* folders."""
from __future__ import annotations

import argparse
import hashlib
import fcntl
import json
import shutil
import ssl
import tarfile
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = Path(__file__).with_name("dependency_manifest.json")
ALLOWED_HOSTS = {
    "codeload.github.com", "github.com", "release-assets.githubusercontent.com",
    "objects.githubusercontent.com", "raw.githubusercontent.com", "huggingface.co", "cdn-lfs.huggingface.co",
    "us.aws.cdn.hf.co", "cas-bridge.xethub.hf.co",
}


class ApprovedRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urllib.parse.urlsplit(newurl)
        if parsed.scheme != "https" or parsed.hostname not in ALLOWED_HOSTS:
            raise RuntimeError("Dependency download redirected outside approved upstream hosts")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def safe_relative(value: str) -> Path:
    parsed = PurePosixPath(value)
    if parsed.is_absolute() or not parsed.parts or any(part in {"", ".", ".."} for part in parsed.parts):
        raise ValueError(f"Unsafe dependency path in manifest: {value!r}")
    return Path(*parsed.parts)


def file_digest(path: Path, algorithm: str) -> str:
    digest = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_verified(path: Path, spec: dict) -> bool:
    if not path.is_file() or path.stat().st_size != spec["bytes"]:
        return False
    if spec.get("sha256"):
        return file_digest(path, "sha256") == spec["sha256"]
    if not spec.get("sha256") and spec.get("git_blob_oid"):
        blob_hash = hashlib.sha1()
        blob_hash.update(f"blob {path.stat().st_size}\0".encode())
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                blob_hash.update(chunk)
        return blob_hash.hexdigest() == spec["git_blob_oid"]
    return False


def fetch(spec: dict, target: Path, *, force: bool = False) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_file() and not force:
        if is_verified(target, spec):
            return
        raise RuntimeError(f"Existing dependency fails its pinned hash: {target.relative_to(ROOT)}")
    partial = target.with_name(target.name + ".partial")
    partial.unlink(missing_ok=True)
    digest = hashlib.sha256()
    count = 0
    last_report = 0
    try:
        import certifi
        tls_context = ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        tls_context = ssl.create_default_context()
    opener = urllib.request.build_opener(ApprovedRedirects(), urllib.request.HTTPSHandler(context=tls_context))
    request = urllib.request.Request(spec["url"], headers={"User-Agent": "zaichang-open-source-bootstrap/1"})
    try:
        with opener.open(request, timeout=60) as response, partial.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                count += len(chunk)
                if count > spec["bytes"]:
                    raise RuntimeError("Upstream file exceeds pinned size")
                digest.update(chunk)
                output.write(chunk)
                if count - last_report >= 25 * 1024 * 1024:
                    print(f"downloaded {target.name}: {count // (1024 * 1024)} / {spec['bytes'] // (1024 * 1024)} MB",
                          flush=True)
                    last_report = count
        if not spec.get("sha256") and spec.get("git_blob_oid"):
            git_blob = hashlib.sha1(f"blob {count}\0".encode())
            with partial.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    git_blob.update(chunk)
            blob_valid = git_blob.hexdigest() == spec["git_blob_oid"]
        else:
            blob_valid = True
        if count != spec["bytes"] or (spec.get("sha256") and digest.hexdigest() != spec["sha256"]) or not blob_valid:
            raise RuntimeError("Downloaded dependency does not match pinned size and SHA-256")
        partial.replace(target)
    except BaseException:
        partial.unlink(missing_ok=True)
        raise


def extract_tar(archive_path: Path, destination: Path, strip_components: int = 1) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive_path, "r:*") as archive:
        for member in archive.getmembers():
            relative = PurePosixPath(member.name)
            parts = relative.parts[strip_components:]
            if not parts:
                continue
            if relative.is_absolute() or any(part in {".", ".."} for part in relative.parts):
                raise RuntimeError("Unsafe member in dependency tarball")
            output = destination.joinpath(*parts)
            if member.issym() or member.islnk() or member.isdev():
                raise RuntimeError("Dependency tarball contains a link or special file")
            if member.isdir():
                output.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                output.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    raise RuntimeError("Unreadable dependency archive member")
                with source, output.open("wb") as target:
                    shutil.copyfileobj(source, target)


def extract_zip(archive_path: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive_path) as archive:
        for member in archive.infolist():
            relative = PurePosixPath(member.filename)
            if relative.is_absolute() or any(part in {".", ".."} for part in relative.parts):
                raise RuntimeError("Unsafe member in dependency zip")
            # Do not reproduce symlinks supplied by an archive.
            if (member.external_attr >> 16) & 0o170000 == 0o120000:
                raise RuntimeError("Dependency zip contains a symbolic link")
            if member.is_dir():
                destination.joinpath(*relative.parts).mkdir(parents=True, exist_ok=True)
            else:
                output = destination.joinpath(*relative.parts)
                output.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(member) as source, output.open("wb") as target:
                    shutil.copyfileobj(source, target)


def use_local_nemo_framework(sdk: Path) -> None:
    package = sdk / "Package.swift"
    text = package.read_text(encoding="utf-8")
    remote = '''.binaryTarget(
            name: "NemoTextProcessing",
            url:
                "https://github.com/FluidInference/text-processing-rs/releases/download/v0.3.1/NemoTextProcessing.xcframework.zip",
            checksum: "5fa8c10d4ec26c1bb2413125f351a7222a4c68a23b74476680fbada7e26fc6aa"
        ),'''
    local = '''.binaryTarget(
            name: "NemoTextProcessing",
            path: "LocalDependencies/NemoTextProcessing.xcframework"
        ),'''
    if text.count(remote) != 1:
        raise RuntimeError("Pinned FluidAudio package no longer matches the expected Nemo binary target")
    package.write_text(text.replace(remote, local), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", action="store_true", help="Show pinned sources and total size without downloading")
    parser.add_argument("--force", action="store_true", help="Redownload every asset, even if its pinned hash already matches")
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    files = manifest["files"]
    archives = list(manifest["archives"].values())
    total_bytes = sum(item["bytes"] for item in [*files, *archives])
    if args.plan:
        print(json.dumps({"revision": manifest["revision"], "files": len(files),
                          "download_bytes": total_bytes,
                          "model_license": manifest["licensed_model"]},
                         ensure_ascii=False, indent=2))
        return 0
    lock_path = ROOT / ".runtime/bootstrap.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock_handle = lock_path.open("w")
    try:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as error:
        raise SystemExit("另一个依赖下载任务正在运行；请等待它完成后再重试。") from error
    for item in archives:
        relative = safe_relative(item["path"])
        print(f"downloading {relative} ({item['bytes']} bytes)", flush=True)
        fetch(item, ROOT / relative, force=args.force)
        print(f"verified {relative}", flush=True)
    for item in files:
        relative = safe_relative(item["path"])
        target = ROOT / relative
        if not is_verified(target, item):
            print(f"downloading {relative} ({item['bytes']} bytes)", flush=True)
        fetch(item, target, force=args.force)
        print(f"verified {relative}", flush=True)

    # FluidAudio's low diarizer loader expects its compiled model directly
    # under the supplied runtime-models directory. Normalize the pinned source
    # tree here so development QA and the shipped app exercise the same layout.
    model_root = ROOT / "native/local-speaker-install/runtime-models"
    low_source = model_root / "monolithic/v2/Nemotron3Diarizer_low.mlmodelc"
    low_runtime = model_root / "Nemotron3Diarizer_low.mlmodelc"
    silence_source = ROOT / "native/local-speaker-install/learnable_sil_emb.bin"
    silence_runtime = model_root / "learnable_sil_emb.bin"
    if not (low_source / "weights/weight.bin").is_file() or not silence_source.is_file():
        raise SystemExit("依赖清单缺少 FluidAudio 必需的低延迟声纹模型或 silence embedding。")
    if low_runtime.exists():
        shutil.rmtree(low_runtime)
    shutil.copytree(low_source, low_runtime)
    shutil.copy2(silence_source, silence_runtime)

    # SDK and binary library archives are unpacked only after their hashes pass.
    sdk_archive = ROOT / manifest["archives"]["fluid_audio"]["path"]
    sdk = ROOT / "native/local-speaker-install/sdk"
    if sdk.exists():
        shutil.rmtree(sdk)
    extract_tar(sdk_archive, sdk)
    nemo_archive = ROOT / manifest["archives"]["nemo_text_processing"]["path"]
    local_dependencies = sdk / "LocalDependencies"
    extract_zip(nemo_archive, local_dependencies)
    use_local_nemo_framework(sdk)
    sherpa_archive = ROOT / manifest["archives"]["sherpa_onnx"]["path"]
    unpack = ROOT / ".runtime/dependencies/sherpa-unpack"
    if unpack.exists():
        shutil.rmtree(unpack)
    extract_tar(sherpa_archive, unpack, strip_components=1)
    libs = ROOT / "native/local-embedding-install/runtime/lib"
    libs.mkdir(parents=True, exist_ok=True)
    for source in unpack.rglob("*.dylib"):
        shutil.copy2(source, libs / source.name)
    print(json.dumps({"bootstrap": "complete", "files_verified": len(files) + len(archives),
                      "download_bytes": total_bytes, "capture": False, "audio_uploaded": False,
                      "settings_changed": False}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
