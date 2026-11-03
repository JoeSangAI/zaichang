#!/usr/bin/env python3
"""Turn the public clone's current version into the GitHub release every installed 在场 offers.

Normally runs by itself at the end of sync_public.py --push. Built from the public clone, so what users
receive is exactly the published source, with no draft from this checkout. Rerunning finishes a release
that stopped halfway; a version already released is left alone.

  release_public.py               build, check and publish the clone's version if it has no release
  release_public.py --build-only  build and check into .runtime/release/<version>, publish nothing
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


def signing_identity():
    """The one release identity, or why a release can't be signed. Changing it strands every installed copy."""
    found = run('security', 'find-identity', '-v', '-p', 'codesigning')
    choices = re.findall(r'\) ([0-9A-F]{40}) "(?:Apple Development|Developer ID Application):[^"\n]+"', found)
    if len(choices) != 1: raise RuntimeError('发版需要这台 Mac 上恰好有一个开发者签名身份')
    return choices[0]


def certificate_days_left(identity):
    """Days until the signing certificate runs out; a release must be signed before that."""
    pem = run('security', 'find-certificate', '-a', '-Z', '-p', '-c', 'Apple Development')
    for block in re.findall(r'SHA-1 hash: ([0-9A-F]{40})\n(-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----)', pem, re.S):
        if block[0] == identity:
            text = run('openssl', 'x509', '-noout', '-enddate', input=block[1])
            end = dt.datetime.strptime(text.strip().split('=', 1)[1].replace(' GMT', ''), '%b %d %H:%M:%S %Y')
            return (end - dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)).days
    return None


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
        links = subprocess.run(['otool', '-L', str(path)], capture_output=True, text=True).stdout
        if home in links: found.append(f'{name}: 链接了本机路径')
        if home.encode() in path.read_bytes(): found.append(f'{name}: 含有本机路径')
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


def publish(clone, dist, version):
    commit = run('git', '-C', clone, 'rev-parse', 'HEAD').strip()
    remote = run('git', '-C', clone, 'ls-remote', 'origin', 'refs/heads/main').split()[0]
    if commit != remote: raise RuntimeError('公开仓库副本和 GitHub 不一致，先同步再发版')
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--clone', type=Path, default=ROOT.parent / 'zaichang-public')
    parser.add_argument('--build-only', action='store_true')
    args = parser.parse_args()
    try:
        print(json.dumps(release_if_new(args.clone, args.build_only), ensure_ascii=False, indent=2))
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(getattr(error, 'stderr', '') or str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
