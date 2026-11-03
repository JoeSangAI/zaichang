#!/usr/bin/env python3
"""Turn this repository's version into the GitHub release every installed 在场 offers.

Normally runs by itself from .githooks/pre-push: a push that changes VERSION in app_version.py builds and
checks the release before anything leaves, and publishes it once the commit is on GitHub. Built from a
clean checkout at HEAD, so what users receive is exactly the published source. A version already released
is left alone.

  release_public.py                  build, check and publish if this version has no release yet
  release_public.py --needs-release  exit 0 when this version has no release yet
  release_public.py --build-only     build and check into .runtime/release/<version>, publish nothing
  release_public.py --publish-built  wait for HEAD on GitHub, then publish what --build-only made
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = 'JoeSangAI/zaichang'
TEAM = '3BVM9N9HS4'
REQUIREMENT = f'identifier "com.joesang.zaichang.standalone" and anchor apple generic and certificate leaf[subject.OU] = "{TEAM}"'
MODEL_FOLDERS = ('Contents/Resources/Runtime/native/local-speaker-install', 'Contents/Resources/Runtime/native/local-embedding-install')
MINIMUM_OS = (15, 0)


def run(*args, **options):
    return subprocess.run([str(arg) for arg in args], check=True, capture_output=True, text=True, **options).stdout


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
    return digest.hexdigest()


def notes(version, changelog):
    """What this version's section of the changelog says; users read it on the update card."""
    lines, keeping = [], False
    for line in Path(changelog).read_text(encoding='utf-8').splitlines():
        if line.startswith('## '):
            if keeping: break
            keeping = line.split()[1] == version
        elif keeping: lines.append(line)
    return '\n'.join(lines).strip()


def changelog_problem(version, changelog):
    return '' if notes(version, changelog) else f'public/CHANGELOG.md 还没有 {version} 这一节：用户更新时看的就是它，写好再发版'


def released(version):
    return subprocess.run(['gh', 'release', 'view', f'v{version}', '--repo', REPO], capture_output=True).returncode == 0


def clone_version(clone):
    text = (Path(clone) / 'app_version.py').read_text(encoding='utf-8')
    return re.search(r"^VERSION = '([^']+)'", text, re.M).group(1)


def certificate_days_left(identity):
    """Days until the signing certificate runs out; a release must be signed before that."""
    pem = run('security', 'find-certificate', '-a', '-Z', '-p', '-c', 'Apple Development')
    for block in re.findall(r'SHA-1 hash: ([0-9A-F]{40})\n(-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----)', pem, re.S):
        if block[0] == identity:
            text = run('openssl', 'x509', '-noout', '-enddate', input=block[1])
            end = dt.datetime.strptime(text.strip().split('=', 1)[1].replace(' GMT', ''), '%b %d %H:%M:%S %Y')
            return (end - dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)).days
    return None


def signing_identity():
    """The release identity. After a renewal the old and new certificates sit side by side for a while;
    the one that lasts longer signs. Changing the team strands every installed copy."""
    found = run('security', 'find-identity', '-v', '-p', 'codesigning')
    choices = re.findall(r'\) ([0-9A-F]{40}) "Apple Development:[^"\n]+"', found)
    if not choices: raise RuntimeError('这台 Mac 上没有可用的开发者签名证书：先在 Xcode 的帐户设置里续期')
    return max(choices, key=lambda identity: certificate_days_left(identity) or -1)


def problems_in(app, version, home=None):
    """Why this bundle must not reach anyone: it has only ever been built on the machine it ran on."""
    app = Path(app); home = str(home or Path.home())
    found = []
    for path in sorted(p for p in app.rglob('*') if p.is_file()):
        if '__pycache__' in path.parts or path.suffix == '.pyc': found.append(f'{path.name}: Python 缓存进了应用包')
        if path.is_symlink() or path.stat().st_size < 4 or path.read_bytes()[:4] not in {b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'}: continue
        name = path.relative_to(app)
        build = subprocess.run(['vtool', '-show-build', str(path)], capture_output=True, text=True).stdout
        minimum = re.search(r'minos (\d+)\.(\d+)', build)
        if minimum and (int(minimum[1]), int(minimum[2])) > MINIMUM_OS: found.append(f'{name}: 要求系统 {minimum[1]}.{minimum[2]}，高于 15.0')
        # The first line of otool's answer is the file itself; only what it loads matters.
        links = subprocess.run(['otool', '-L', str(path)], capture_output=True, text=True).stdout.splitlines()[1:]
        rpaths = subprocess.run(['otool', '-l', str(path)], capture_output=True, text=True).stdout
        if any(home in line for line in links) or f'path {home}' in rpaths: found.append(f'{name}: 依赖本机路径')
    info = run('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleShortVersionString', app / 'Contents/Info.plist').strip()
    if info != version: found.append(f'版本号是 {info}，应为 {version}')
    return found


def verify_signature(app):
    run('codesign', '--verify', '--deep', '--strict', f'-R={REQUIREMENT}', app)


def package(app, dist, version, repo=REPO):
    """The whole zip, the small zip without the models, and the feed. The small one is proven to reassemble."""
    app, dist = Path(app), Path(dist)
    if dist.exists(): shutil.rmtree(dist)
    dist.mkdir(parents=True)
    whole, small = dist / 'Zaichang.zip', dist / 'Zaichang-update.zip'
    run('ditto', '-c', '-k', '--keepParent', app, whole)
    with tempfile.TemporaryDirectory(dir=dist) as temporary:
        stripped = Path(temporary) / app.name
        run('cp', '-Rc', app, stripped)
        for relative in MODEL_FOLDERS: shutil.rmtree(stripped / relative)
        run('ditto', '-c', '-k', '--keepParent', stripped, small)
        again = Path(temporary) / 'again'
        run('ditto', '-x', '-k', small, again)
        for relative in MODEL_FOLDERS: run('cp', '-Rc', app / relative, again / app.name / relative)
        verify_signature(again / app.name)
    base = f'https://github.com/{repo}/releases/download/v{version}'
    changelog = app / 'Contents/Resources/Runtime/CHANGELOG.md'
    feed = {'version': version, 'sha256': sha(whole), 'notes': notes(version, changelog), 'zip': f'{base}/{whole.name}',
            'patch': {'zip': f'{base}/{small.name}', 'sha256': sha(small),
                      'models': (app / 'Contents/Resources/Runtime/models.id').read_text().strip()}}
    (dist / 'latest.json').write_text(json.dumps(feed, ensure_ascii=False, indent=1), encoding='utf-8')
    (dist / 'notes.md').write_text(feed['notes'], encoding='utf-8')
    return feed


def build(clone, version):
    sys.path.insert(0, str(clone))
    import app_version
    problem = app_version.first_run_review_problem()
    if problem: raise RuntimeError(problem)
    identity = signing_identity()
    days = certificate_days_left(identity)
    if days is not None and days < 1: raise RuntimeError('签名证书已过期：先在 Xcode 里续期，再发版')
    if days is not None and days < 30: print(f'提醒：签名证书还有 {days} 天到期，到期前要在 Xcode 里续期。', file=sys.stderr)
    work = Path(clone) / '.runtime/build/standalone'
    for old in work.glob('在场.previous-*.app'): shutil.rmtree(old)
    subprocess.run([sys.executable, 'scripts/install_standalone.py', '--build-only', '--sign', identity], cwd=clone, check=True,
                   stdout=subprocess.DEVNULL)
    app = work / '在场.app'
    verify_signature(app)
    problems = problems_in(app, version)
    if problems: raise RuntimeError('这个包不能发：\n' + '\n'.join(problems))
    return app


def publish(clone, dist, version, wait=0):
    commit = run('git', '-C', clone, 'rev-parse', 'HEAD').strip()
    for _ in range(wait // 5 + 1):
        remote = run('git', '-C', clone, 'ls-remote', 'origin', 'refs/heads/main').split()[0]
        if commit == remote: break
        time.sleep(5)
    if commit != remote: raise RuntimeError('这个提交还不在 GitHub 上，先推送再发版')
    run('gh', 'release', 'create', f'v{version}', dist / 'Zaichang.zip', dist / 'Zaichang-update.zip', dist / 'latest.json',
        '--repo', REPO, '--target', commit, '--title', f'在场 {version}', '--notes-file', dist / 'notes.md')
    # What installed copies will actually read.
    url = f'https://github.com/{REPO}/releases/latest/download/latest.json'
    if json.loads(run('curl', '-fsSL', '--retry', '3', url))['version'] != version:
        raise RuntimeError('发布后读回的版本不对')


def release_if_new(clone, build_only=False):
    clone = Path(clone); version = clone_version(clone)
    if not build_only and released(version): return {'released': False, 'version': version, 'reason': '这个版本已经发布过'}
    problem = changelog_problem(version, clone / 'CHANGELOG.md')
    if problem: raise RuntimeError(problem)
    dist = ROOT / '.runtime/release' / version
    feed = package(build(clone, version), dist, version)
    if build_only: return {'released': False, 'version': version, 'dist': str(dist), 'feed': feed}
    publish(clone, dist, version)
    return {'released': True, 'version': version, 'whole_mb': (dist / 'Zaichang.zip').stat().st_size >> 20,
            'update_mb': (dist / 'Zaichang-update.zip').stat().st_size >> 20}


def publish_built(clone):
    """After the push: publish exactly what the pre-push build checked."""
    clone = Path(clone); version = clone_version(clone)
    if released(version): return {'released': False, 'version': version, 'reason': '这个版本已经发布过'}
    dist = ROOT / '.runtime/release' / version
    feed = json.loads((dist / 'latest.json').read_text(encoding='utf-8'))
    if feed['version'] != version or sha(dist / 'Zaichang.zip') != feed['sha256']: raise RuntimeError('构建好的安装包和这个版本对不上，重新构建')
    publish(clone, dist, version, wait=300)
    return {'released': True, 'version': version}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--clone', type=Path, default=ROOT)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--build-only', action='store_true')
    mode.add_argument('--publish-built', action='store_true')
    mode.add_argument('--needs-release', action='store_true')
    args = parser.parse_args()
    try:
        if args.needs_release: return 1 if released(clone_version(args.clone)) else 0
        result = publish_built(args.clone) if args.publish_built else release_if_new(args.clone, args.build_only)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(getattr(error, 'stderr', '') or str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
