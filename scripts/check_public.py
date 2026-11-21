#!/usr/bin/env python3
"""Check public Git snapshots for private data before pushing.

Keep the release maintainer's settings in .local/check_public.json and the
people term table in .local. Both files are required. The JSON has "tokens",
"names", "people_terms" (a path relative to .local), optional "allow_names",
and "author" (public credits allowed only in the designated files).
"""
from __future__ import annotations

import argparse
import io
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

AUDIO = {'.pcm', '.wav', '.m4a', '.mp3', '.aac', '.flac', '.aiff', '.caf', '.ogg'}
SECRETS = re.compile(r'(?<![A-Za-z0-9])(?:sk-[A-Za-z0-9_-]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16}|LTAI[A-Za-z0-9]{16,}|AIza[A-Za-z0-9_-]{30,}'
                     r'|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|xox[baprs]-[A-Za-z0-9-]{10,})')
MACHINE_PATH = os.sep + 'Users' + os.sep
AUTHOR_FILES = {'README.md', 'LICENSE', 'CHANGELOG.md', 'install.sh',
                'native/AppUpdate.swift', 'scripts/release_public.py'}


def git(*args, root=ROOT, data=None):
    return subprocess.run(['git', '--no-replace-objects', '-C', str(root), *args],
                          input=data, capture_output=True, check=True).stdout


def committed(ref, checked, root=ROOT):
    entries = {}
    for entry in git('ls-tree', '-r', '-z', ref, root=root).split(b'\0'):
        if not entry:
            continue
        metadata, name = entry.split(b'\t', 1)
        _, kind, oid = metadata.split()
        name = os.fsdecode(name)
        if kind != b'blob':
            raise ValueError('公开检查无法检查 Git 子模块。')
        key = (name, oid)
        if key not in checked:
            entries[name] = oid
            checked.add(key)
    if not entries:
        return {}
    # Read blob objects directly, including symlink targets and files with
    # archive export attributes. The index and worktree cannot mask a hit.
    blobs = io.BytesIO(git('cat-file', '--batch', root=root,
                           data=b''.join(oid + b'\n' for oid in entries.values())))
    files = {}
    for name, oid in entries.items():
        header = blobs.readline().split()
        if len(header) != 3 or header[:2] != [oid, b'blob']:
            raise ValueError('公开检查无法读取待公开文件。')
        size = int(header[2])
        files[name] = blobs.read(size)
        if len(files[name]) != size or blobs.read(1) != b'\n':
            raise ValueError('公开检查读取到不完整的 Git 对象。')
    return files


def worktree(root=ROOT):
    files = {}
    for raw in git('ls-files', '-z', root=root).split(b'\0'):
        if not raw:
            continue
        name = os.fsdecode(raw)
        path = root / name
        if path.is_symlink():
            files[name] = os.fsencode(os.readlink(path))
        elif path.is_file():
            files[name] = path.read_bytes()
        elif path.exists():
            raise ValueError('公开检查无法检查 Git 子模块。')
        # A deleted tracked file is absent from the proposed working tree.
    return files


def private_words(root=ROOT):
    from shared_terms import parse

    def strings(key, *, required=False):
        values = config.get(key, [])
        if (not isinstance(values, list) or (required and not values)
                or any(not isinstance(value, str) or not value.strip() for value in values)):
            raise ValueError
        return values

    local = root / '.local'
    try:
        config_path = (local / 'check_public.json').resolve(strict=True)
        if config_path.parent != local.resolve():
            raise ValueError
        config = json.loads(config_path.read_text(encoding='utf-8'))
        if not isinstance(config, dict):
            raise ValueError
        tokens = [str(Path.home()), *strings('tokens', required=True)]
        names = set(strings('names'))
        author = strings('author', required=True)
        terms_name = Path(config['people_terms'])
        terms = (local / terms_name).resolve(strict=True)
        if terms_name.is_absolute() or local.resolve() not in terms.parents:
            raise ValueError
        rows = parse(terms.read_text(encoding='utf-8'))
        if not rows:
            raise ValueError
        for row in rows:
            names.update([row.term, *row.aliases, *row.misheard])
        names -= set(strings('allow_names'))
        if not names:
            raise ValueError
    except (KeyError, OSError, RuntimeError, TypeError, ValueError):
        raise ValueError('需要有效的 .local/check_public.json 和 .local 内的私人词表。') from None
    return tokens, sorted(names), author


def scan(files, tokens=(), names=(), author=()):
    hits = []
    patterns = [(person, re.compile(r'(?<![A-Za-z])' + re.escape(person) + r'(?![A-Za-z])')
                 if person.isascii() else None) for person in names]
    for name, data in files.items():
        path = Path(name)
        if path.suffix.lower() in AUDIO | {'.sqlite', '.sqlite3', '.db', '.jsonl'} or \
                (path.suffix not in {'.py', '.swift'} and re.search(r'(?:transcript|会议原文|逐字稿|SessionCache)', path.name, re.I)):
            hits.append((name, 'meeting_or_audio_file'))
        text = name + '\n' + data.decode('utf-8', errors='replace')
        if '.local' in path.parts: hits.append((name, 'local_settings_committed'))
        if MACHINE_PATH in text: hits.append((name, 'machine_path'))
        if any(token in text for token in tokens): hits.append((name, 'private_token'))
        for credit in author:
            if credit in text and name not in AUTHOR_FILES:
                hits.append((name, 'author_outside_author_files'))
            text = text.replace(credit, '')
        if any(person in text and (pattern is None or pattern.search(text)) for person, pattern in patterns):
            hits.append((name, 'private_person'))
        if SECRETS.search(text): hits.append((name, 'credential_shape'))
    return hits


def push_commits(updates, root=ROOT):
    """Check every pushed tip and every commit newly introduced by the updates."""
    tips = set()
    bases = set()
    for local_oid, remote_oid in updates:
        for oid in (local_oid, remote_oid):
            if not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', oid):
                raise ValueError('公开检查收到无效的 Git 对象 ID。')
        if local_oid.strip('0'):
            tips.add(git('rev-parse', '--verify', local_oid + '^{commit}', root=root).decode().strip())
        if remote_oid.strip('0'):
            bases.add(git('rev-parse', '--verify', remote_oid + '^{commit}', root=root).decode().strip())
    if not tips:
        return []
    # New refs may have no base. Walk their whole reachable history whenever
    # the push provides no existing remote tip that proves a commit is shared.
    boundary = [*sorted(tips), *('^' + base for base in sorted(bases))]
    outgoing = git('rev-list', '--stdin', root=root, data=('\n'.join(boundary) + '\n').encode())
    return sorted(tips.union(outgoing.decode().splitlines()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--worktree', action='store_true', help='scan tracked files before committing')
    mode.add_argument('--ref', help='scan one commit (default: HEAD)')
    mode.add_argument('--push', nargs=2, action='append', metavar=('LOCAL_OID', 'REMOTE_OID'),
                      help='scan the updates reported by the pre-push hook')
    args = parser.parse_args()
    try:
        tokens, names, author = private_words()
        if args.worktree:
            hits = [('worktree', *hit) for hit in scan(worktree(), tokens, names, author)]
            count = 1
        else:
            commits = (push_commits(args.push) if args.push else [
                git('rev-parse', '--verify', (args.ref or 'HEAD') + '^{commit}').decode().strip()])
            checked = set()
            hits = []
            for commit in commits:
                hits.extend((commit[:12], *hit) for hit in scan(committed(commit, checked), tokens, names, author))
            count = len(commits)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        message = str(error) if isinstance(error, ValueError) else '无法读取待检查的 Git 对象或文件。'
        print('公开检查未通过。' + message, file=sys.stderr)
        return 1
    for ref, name, reason in hits:
        print(f'{ref} {name}: {reason}', file=sys.stderr)
    if hits:
        print('公开检查未通过。请清理以上文件后重试。', file=sys.stderr)
        return 1
    print(f'公开检查通过。快照 {count} 份，私人词条 {len(names)} 项，私人字符串 {len(tokens)} 项，命中 0。')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
