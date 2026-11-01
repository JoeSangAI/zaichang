"""Read-only candidate search over the configured authoritative people loader.

No registry, parser, identity merge, or binding is owned here. The caller must
show candidates and obtain an explicit selection before saving a reference.
"""
from __future__ import annotations
from runtime_config import connectors
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
import unicodedata

sys.dont_write_bytecode = True
MAX_FILE_BYTES = 1024 * 1024
MAX_SOURCES = 512
MAX_PEOPLE = 4096
MAX_RESULTS = 20


class SharedPeopleUnavailable(ValueError):
    pass


def checked_text(value, maximum, *, empty=False):
    if (not isinstance(value, str) or len(value) > maximum or
            any(unicodedata.category(c).startswith('C') for c in value) or
            (not empty and not value.strip())):
        raise SharedPeopleUnavailable('shared_people_invalid_data')
    return value


def canonical_path(value, *, directory=False):
    text = checked_text(str(value), 4096)
    path = Path(text)
    if not path.is_absolute() or '..' in path.parts or str(path) != text:
        raise SharedPeopleUnavailable('shared_people_invalid_path')
    # Reject redirects, including symlink ancestors. Evidence and imported code
    # must refer to the declared owner, not a different file behind a link.
    if path.resolve(strict=True) != path or any(p.is_symlink() for p in (path, *path.parents)):
        raise SharedPeopleUnavailable('shared_people_invalid_path')
    info = path.stat()
    if directory:
        if not stat.S_ISDIR(info.st_mode):
            raise SharedPeopleUnavailable('shared_people_invalid_path')
    elif not stat.S_ISREG(info.st_mode) or info.st_size > MAX_FILE_BYTES:
        raise SharedPeopleUnavailable('shared_people_source_limit')
    return path


def load_authoritative_people(module_path=None, focus_root=None):
    config = connectors()
    module_path = module_path or config.get('people_loader')
    roots = config.get('project_roots', [])
    focus_root = focus_root or (roots[0] if roots else None)
    if not module_path or not focus_root:
        return [], None
    module_path = canonical_path(module_path)
    focus = canonical_path(focus_root, directory=True)
    spec = importlib.util.spec_from_file_location('_configured_people_readonly', module_path)
    if spec is None or spec.loader is None:
        raise SharedPeopleUnavailable('shared_people_unavailable')
    module = importlib.util.module_from_spec(spec)
    # Direct import of the existing implementation: no source copy or parser.
    spec.loader.exec_module(module)
    loader = getattr(module, 'load_people', None)
    if not callable(loader):
        raise SharedPeopleUnavailable('shared_people_unavailable')
    result = loader(focus)
    if not isinstance(result, list) or len(result) > MAX_PEOPLE:
        raise SharedPeopleUnavailable('shared_people_result_limit')
    return result, focus


def validated_person(person, focus):
    if not isinstance(person, dict):
        raise SharedPeopleUnavailable('shared_people_invalid_data')
    identifier = checked_text(person.get('id'), 80)
    if not re.fullmatch(r'person:[0-9a-f]{20}', identifier):
        raise SharedPeopleUnavailable('shared_people_invalid_data')
    name = checked_text(person.get('name'), 80)
    aliases = person.get('aliases', [])
    if not isinstance(aliases, list) or len(aliases) > 64:
        raise SharedPeopleUnavailable('shared_people_invalid_data')
    aliases = [checked_text(value, 80) for value in aliases]
    evidence = person.get('evidence')
    if not isinstance(evidence, list) or not 1 <= len(evidence) <= MAX_SOURCES:
        raise SharedPeopleUnavailable('shared_people_invalid_data')
    paths = []
    for value in evidence:
        if not isinstance(value, str):
            raise SharedPeopleUnavailable('shared_people_invalid_data')
        checked_text(value, 2048)
        path = canonical_path(value)
        if not path.is_relative_to(focus):
            raise SharedPeopleUnavailable('shared_people_invalid_path')
        paths.append(str(path))
    candidate = dict(reference=dict(id=identifier, name=name, evidence=list(dict.fromkeys(paths))[:8]),
                     organization=checked_text(person.get('organization', ''), 240, empty=True),
                     role=checked_text(person.get('role', ''), 240, empty=True))
    return candidate, [name, *aliases]


def search_people(query, *, module_path=None, focus_root=None):
    query = checked_text(query, 80).strip().casefold()
    people, focus = load_authoritative_people(module_path, focus_root)
    found = []
    ids = set()
    for person in people:
        candidate, names = validated_person(person, focus)
        identifier = candidate['reference']['id']
        if identifier in ids:
            raise SharedPeopleUnavailable('shared_people_duplicate_id')
        ids.add(identifier)
        folded = [name.casefold() for name in names]
        if any(query in name for name in folded):
            found.append((0 if query in folded else 1, candidate))
    found.sort(key=lambda row: (row[0], row[1]['reference']['name'], row[1]['reference']['id']))
    return dict(schema=1, status='ok', requires_confirmation=True,
                candidates=[row[1] for row in found[:MAX_RESULTS]], truncated=len(found)>MAX_RESULTS)


def name_variants(name):
    """The whole name first, then its parts: 示例甲（示例公司） and 错字 Alias."""
    bare = re.sub(r'[（(].*?[)）]', '', name).strip()
    return list(dict.fromkeys([name, bare, *bare.split()]))


def resolve_names(names, *, module_path=None, focus_root=None, rows=None):
    """Map each name to its one authoritative spelling, when there is exactly one.

    People owners decide first; a term table's alias or known misspelling applies
    only to a whole name. An ambiguous name stays as it is.
    """
    people, focus = load_authoritative_people(module_path, focus_root)
    owners = {}
    for person in people:
        candidate, spellings = validated_person(person, focus)
        for spelling in spellings:
            owners.setdefault(spelling.casefold(), set()).add(candidate['reference']['name'])
    terms = {}
    if rows is None:
        from shared_terms import compiled_owners
        rows = [row for owner in compiled_owners() if owner['layer'] in ('people', 'project') for row in owner['rows']]
    for row in rows:
        for spelling in [row['term'], *row['aliases'], *row['misheard']]:
            terms.setdefault(spelling.casefold(), set()).add(row['term'])
    resolved = {}
    for name in names:
        checked_text(name, 80)
        for variant in name_variants(name):
            found = owners.get(variant.casefold(), set())
            if not found and variant == name:
                found = terms.get(name.casefold(), set())
            if found:
                if len(found) == 1:
                    resolved[name] = next(iter(found))
                break
    return dict(schema=1, status='ok', resolved=resolved)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--query')
    parser.add_argument('--resolve-names', help='JSON list of names to map to authoritative spellings')
    args = parser.parse_args()
    if bool(args.query) == bool(args.resolve_names):
        parser.error('give exactly one of --query or --resolve-names')
    def timeout(*_):
        raise SharedPeopleUnavailable('shared_people_timeout')
    signal.signal(signal.SIGALRM, timeout)
    signal.setitimer(signal.ITIMER_REAL, 8 if args.resolve_names else 2.5)
    try:
        output = search_people(args.query) if args.query else resolve_names(json.loads(args.resolve_names))
        encoded = json.dumps(output, ensure_ascii=False)
        if len(encoded.encode()) > 128 * 1024:
            raise SharedPeopleUnavailable('shared_people_result_limit')
        print(encoded)
        return 0
    except Exception as error:
        code = str(error) if isinstance(error, SharedPeopleUnavailable) else 'shared_people_unavailable'
        print(json.dumps(dict(schema=1, status='unavailable', code=code,
                              requires_confirmation=True, candidates=[])))
        return 1
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


if __name__ == '__main__':
    raise SystemExit(main())
