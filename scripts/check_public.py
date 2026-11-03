#!/usr/bin/env python3
"""What this public repository may never hold: meetings, audio, keys, paths of the machine it was built on,
or the names of the people in someone's meetings. Runs before every push (.githooks/pre-push) on what is
committed at HEAD, so a draft in the working tree can't slip past it.

The owner's own private words to look for live in .local/check_public.json, which is never committed:
{"tokens": [...], "names": [...], "people_terms": "~/people.md", "allow_names": [...], "author": [...]}.
"author" are the public names that may appear only in the files that credit the author. Without the file
the general rules still apply.
"""
from __future__ import annotations

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
# Files that credit the author or have to name the repository itself.
AUTHOR_FILES = {'README.md', 'LICENSE', 'CHANGELOG.md', 'install.sh', 'AppUpdate.swift', 'release_public.py', 'AGENTS.md'}


def committed(root=ROOT, ref='HEAD'):
    names = [n for n in subprocess.run(['git', '-C', str(root), 'ls-tree', '-r', '-z', '--name-only', ref],
                                       capture_output=True, check=True).stdout.decode().split('\0') if n]
    show = lambda name: subprocess.run(['git', '-C', str(root), 'show', f'{ref}:{name}'], capture_output=True, check=True).stdout
    return {name: show(name) for name in names}


def private_words(root=ROOT):
    """(tokens, names, author) from the owner's uncommitted settings; mostly empty on any other machine."""
    path = root / '.local/check_public.json'
    if not path.is_file(): return [str(Path.home())], [], []
    config = json.loads(path.read_text(encoding='utf-8'))
    names = set(config.get('names', []))
    terms = config.get('people_terms')
    if terms and Path(terms).expanduser().is_file():
        from shared_terms import parse
        for row in parse(Path(terms).expanduser().read_text(encoding='utf-8')):
            names.update([row.term, *row.aliases])
    names -= set(config.get('allow_names', []))
    tokens = [str(Path.home()), *config.get('tokens', [])]
    return tokens, sorted(n for n in names if n), config.get('author', [])


def scan(files, tokens=(), names=(), author=()):
    hits = []
    for name, data in files.items():
        path = Path(name)
        if path.suffix.lower() in AUDIO | {'.sqlite', '.sqlite3', '.db', '.jsonl'} or \
                (path.suffix not in {'.py', '.swift'} and re.search(r'(?:transcript|会议原文|逐字稿|SessionCache)', path.name, re.I)):
            hits.append((name, 'meeting_or_audio_file'))
        text = name + '\n' + data.decode('utf-8', errors='replace')
        if path.name.startswith('.') and path.suffix == '.json' and path.parent.name == '.local': hits.append((name, 'local_settings_committed'))
        if MACHINE_PATH in text: hits.append((name, 'machine_path'))
        for token in tokens:
            if token and token in text: hits.append((name, 'private_token'))
        for credit in author:
            if credit in text and path.name not in AUTHOR_FILES: hits.append((name, 'author_outside_author_files'))
            text = text.replace(credit, '')
        for person in names:
            if (re.search(r'(?<![A-Za-z])' + re.escape(person) + r'(?![A-Za-z])', text) if person.isascii() else person in text):
                hits.append((name, 'private_person')); break
        if SECRETS.search(text): hits.append((name, 'credential_shape'))
    return hits


def main():
    tokens, names, author = private_words()
    hits = scan(committed(), tokens, names, author)
    for name, reason in hits: print(f'{name}: {reason}', file=sys.stderr)
    if hits:
        print('推送被拦下：上面这些文件含有不该公开的内容。改掉并重新提交后再推。', file=sys.stderr)
        return 1
    print(f'公开检查通过：{len(names)} 个私人名字、{len(tokens)} 个私人字符串都没出现。')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
