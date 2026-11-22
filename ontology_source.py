"""Optional read of a local ontology service: the one list of people, organizations and projects
kept by another app on this Mac.

Enabled only by `"ontology"` in the user's own connectors.json, and only for an http address on
this Mac. Reads use a short timeout, then the snapshot file the user named; when both fail the
caller keeps its existing sources, so recording and transcription never wait on this.

Nothing here binds a speaker channel or a voice to a subject. People found here are candidates the
user must still pick and confirm.

Corrections go back only as owner records the user made in 在场, queued locally first so a
failed delivery can be retried without sending a different record.
"""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unicodedata
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import ProxyHandler, Request, build_opener

from runtime_config import connectors, data_root

sys.dont_write_bytecode = True
TIMEOUT = 1.0
POST_TIMEOUT = 5.0
MAX_BYTES = 8 * 1024 * 1024
MAX_ITEMS = 20000
OUTBOX = 'ontology-outbox.json'
_OPENER = build_opener(ProxyHandler({}))  # loopback only: never through a proxy


class OntologyUnavailable(Exception):
    pass


def settings(config=None):
    return (connectors() if config is None else config).get('ontology')


def enabled(config=None):
    return bool(settings(config))


def normalize(value):
    return unicodedata.normalize('NFKC', value).strip().casefold() if isinstance(value, str) else ''


def text(value, limit):
    """A display string within limit and without control characters, else None."""
    if (not isinstance(value, str) or not value.strip() or value != value.strip() or len(value) > limit
            or any(unicodedata.category(c).startswith('C') for c in value)):
        return None
    return value


def texts(values, limit, maximum=64):
    return list(dict.fromkeys(v for v in (values if isinstance(values, list) else [])[:maximum] if text(v, limit)))


def http_get(url, timeout=TIMEOUT):
    request = Request(url, headers={'Accept': 'application/json'})
    with _OPENER.open(request, timeout=timeout) as response:
        data = response.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise OntologyUnavailable('ontology_too_large')
    return json.loads(data)


def http_post(url, body, timeout=POST_TIMEOUT):
    """(status, reply). Plain urllib: no Origin, Referer or browser headers."""
    request = Request(url, data=body.encode('utf-8'), method='POST', headers={'Content-Type': 'application/json'})
    try:
        with _OPENER.open(request, timeout=timeout) as response:
            return response.status, json.loads(response.read(MAX_BYTES) or b'{}')
    except HTTPError as error:
        return error.code, {}


def payload(value):
    if not isinstance(value, dict):
        raise OntologyUnavailable('ontology_invalid')
    items = value.get('items')
    items = list(items.values()) if isinstance(items, dict) else items
    if not isinstance(items, list) or len(items) > MAX_ITEMS:
        raise OntologyUnavailable('ontology_invalid')
    rows = [item for item in items if isinstance(item, dict) and text(item.get('id'), 240)
            and item.get('kind') in ('subject', 'project', 'action') and text(item.get('name'), 240)]
    redirects = value.get('redirects') if isinstance(value.get('redirects'), dict) else {}
    return dict(items=rows, redirects={k: v for k, v in redirects.items() if isinstance(k, str) and isinstance(v, str)})


def read(kinds=('subject', 'project'), *, config=None, fetch=None):
    """{'items', 'redirects', 'origin'} for the given kinds, or None when disabled or unreachable."""
    cfg = settings(config)
    if not cfg:
        return None
    fetch = fetch or http_get
    try:
        items, redirects = [], {}
        for kind in kinds:
            part = payload(fetch(cfg['url'] + '?' + urlencode({'kind': kind}), TIMEOUT))
            items += [item for item in part['items'] if item['kind'] == kind]
            redirects.update(part['redirects'])
        return dict(items=items, redirects=redirects, origin='service')
    except Exception:
        pass
    snapshot = cfg.get('snapshot')
    try:
        path = Path(snapshot)
        if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_BYTES:
            return None
        value = payload(json.loads(path.read_text(encoding='utf-8')))
    except Exception:
        return None
    return dict(items=[item for item in value['items'] if item['kind'] in kinds],
                redirects=value['redirects'], origin='snapshot')


def reference_id(item_id):
    """Stable 在场 reference for one ontology entry; the entry's own id stays its owner's."""
    return 'person:' + hashlib.sha256(('ontology:' + item_id).encode('utf-8')).hexdigest()[:20]


def _evidence(item, snapshot):
    paths = []
    for row in item.get('provenance') if isinstance(item.get('provenance'), list) else []:
        path = row.get('path') if isinstance(row, dict) else None
        if (text(path, 2048) and path.startswith('/') and os.path.normpath(path) == path
                and '..' not in Path(path).parts and path not in paths):
            paths.append(path)
    return paths[:8] or ([snapshot] if snapshot else [])


def people(data, snapshot=None):
    """[(candidate, names, misheard)] for subjects that are people. The organization is shown
    with the person; organizations themselves are not people to pick."""
    subjects = [item for item in data['items'] if item['kind'] == 'subject']
    organizations = {item['id']: item['name'] for item in subjects if item.get('type') == 'organization'}
    found, ids = [], set()
    for item in subjects:
        if item.get('type') != 'person' or not (name := text(item['name'], 80)):
            continue
        identifier = reference_id(item['id'])
        evidence = _evidence(item, snapshot)
        if identifier in ids or not evidence:
            continue
        ids.add(identifier)
        organization = (text(item.get('organization'), 240) or
                        text(organizations.get(item.get('organization_id'), ''), 240) or '')
        candidate = dict(reference=dict(id=identifier, name=name, evidence=evidence),
                         organization=organization, role=text(item.get('role'), 240) or '')
        aliases = [a for a in texts(item.get('aliases'), 80) if a != name]
        misheard = [m for m in texts(item.get('misrecognitions'), 80) if m != name and m not in aliases]
        found.append((candidate, [name, *aliases], misheard))
    return found


def read_people(config=None, fetch=None):
    """People from the ontology, or None when it is disabled or unreachable."""
    cfg = settings(config)
    data = read(('subject',), config=config, fetch=fetch) if cfg else None
    return None if data is None else people(data, cfg.get('snapshot'))


def term_owners(config=None, fetch=None):
    """Spelling rows in the shape of shared_terms owners: standard name, aliases, misrecognitions.

    Rows carry `ontology` so callers can keep them out of prompts unless the meeting says them."""
    from shared_terms import valid_word
    if not enabled(config):
        return []
    data = read(('subject', 'project'), config=config, fetch=fetch)
    if data is None:
        return [dict(path='ontology', layer='people', ontology='subject', rows=[], error='OntologyUnavailable')]
    owners = []
    for kind in ('subject', 'project'):
        rows, seen = [], {}
        for item in data['items']:
            if item['kind'] != kind or not valid_word(item['name']):
                continue
            term = item['name']
            aliases = [a for a in texts(item.get('aliases'), 64) if valid_word(a) and normalize(a) != normalize(term)]
            misheard = [m for m in texts(item.get('misrecognitions'), 64) if valid_word(m)
                        and normalize(m) not in {normalize(w) for w in [term, *aliases]}]
            key = term.casefold()
            if key in seen:  # equal display names (numbered ids) share one spelling row
                row = seen[key]
                row['aliases'] += [a for a in aliases if a not in row['aliases']]
                row['misheard'] += [m for m in misheard if m not in row['misheard']]
                continue
            row = dict(term=term, aliases=aliases, misheard=misheard, layer='people',
                       path='ontology:' + kind, ontology=kind)
            seen[key] = row
            rows.append(row)
        owners.append(dict(path='ontology:' + kind, layer='people', ontology=kind, rows=rows, error=None))
    return owners


# ---- Owner corrections back to the ontology -------------------------------------------------

def _outbox_path():
    return data_root() / OUTBOX


def _locked(update):
    path = _outbox_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path.with_suffix('.lock'), 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            value = json.loads(path.read_text(encoding='utf-8')) if path.is_file() else {}
        except (OSError, ValueError):
            value = {}
        entries = value.get('entries') if isinstance(value, dict) and isinstance(value.get('entries'), list) else []
        result = update(entries)
        handle, temp = tempfile.mkstemp(dir=path.parent, prefix='.ontology-outbox-')
        with os.fdopen(handle, 'w', encoding='utf-8') as stream:
            json.dump(dict(schema=1, entries=entries), stream, ensure_ascii=False)
        os.replace(temp, path)
        return result


def pending():
    """Queued corrections, read without creating or rewriting the outbox."""
    try:
        value = json.loads(_outbox_path().read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return []
    entries = value.get('entries') if isinstance(value, dict) else None
    return [dict(entry) for entry in entries if isinstance(entry, dict)] if isinstance(entries, list) else []


def queue_misrecognition(item_id, heard, *, session, operation_id, quote, now=None, config=None):
    """Remember one owner correction (`heard` is how 在场 wrote the name of `item_id`).
    Queuing the same session operation again changes nothing."""
    if not enabled(config):
        return None
    if not text(item_id, 240) or not text(heard, 64) or not text(quote, 2000):
        raise ValueError('ontology_invalid_correction')
    if not text(session, 200) or not text(operation_id, 200):
        raise ValueError('ontology_invalid_correction')
    ref = f'zaichang:{session}#{operation_id}'
    entry = dict(ref=ref, item_id=item_id, heard=heard, quote=quote, at=int(time.time() if now is None else now))

    def add(entries):
        if not any(old.get('ref') == ref for old in entries):
            entries.append(entry)
        return ref
    return _locked(add)


def _record(entry, item):
    known = [normalize(w) for w in [item.get('name'), *texts(item.get('aliases'), 240)]]
    current = texts(item.get('misrecognitions'), 240, maximum=1024)
    if normalize(entry['heard']) in known or normalize(entry['heard']) in map(normalize, current):
        return None
    request_id = entry['ref'] if len(entry['ref']) <= 160 else 'zaichang:' + hashlib.sha256(entry['ref'].encode()).hexdigest()
    return dict(op='update', actor='owner', at=entry['at'], id=item['id'], kind=item['kind'],
                fields=dict(misrecognitions=[*current, entry['heard']]),
                evidence=[dict(ref=entry['ref'], quote=entry['quote'])], request_id=request_id)


def deliver(*, config=None, fetch=None, post=None):
    """Send queued corrections. Returns {ref: outcome}; an unreachable service keeps the entry
    for the next try and the exact same record is resent, so the service sees a duplicate."""
    cfg = settings(config)
    if not cfg:
        return {}
    fetch, post = fetch or http_get, post or http_post
    outcomes = {}

    if not pending():
        return {}

    def run(entries):
        keep = []
        for entry in entries:
            ref = entry.get('ref')
            try:
                body = entry.get('body')
                if body is None:
                    try:
                        found = payload(fetch(cfg['url'] + '?' + urlencode({'id': entry['item_id']}), TIMEOUT))['items']
                    except HTTPError as error:
                        if error.code == 404:
                            outcomes[ref] = 'not_found'
                            continue
                        raise
                    if len(found) != 1 or found[0]['kind'] not in ('subject', 'project'):
                        outcomes[ref] = 'not_found'
                        continue
                    body = _record(entry, found[0])
                    if body is None:
                        outcomes[ref] = 'already_known'
                        continue
                    entry['body'] = body  # fixed from now on: a retry must be the same record
                status, _ = post(cfg['url'], json.dumps(body, ensure_ascii=False, sort_keys=True))
            except Exception:
                outcomes[ref] = 'pending'
                keep.append(entry)
                continue
            if status in (200, 201):
                outcomes[ref] = 'saved' if status == 201 else 'duplicate'
            elif status >= 500 or status in (408, 429):
                outcomes[ref] = 'pending'
                keep.append(entry)
            else:
                outcomes[ref] = f'rejected_{status}'
        entries[:] = keep
    _locked(run)
    return outcomes


def report_misrecognition(item_id, heard, *, session, operation_id, quote, config=None, fetch=None, post=None, now=None):
    """Queue and try to deliver at once. Local saving never depends on the outcome."""
    ref = queue_misrecognition(item_id, heard, session=session, operation_id=operation_id, quote=quote,
                               now=now, config=config)
    if ref is None:
        return 'disabled'
    return deliver(config=config, fetch=fetch, post=post).get(ref, 'pending')


def main():
    parser = argparse.ArgumentParser(description='Optional local ontology connector.')
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--status', action='store_true', help='where people and terms come from now')
    group.add_argument('--report-misrecognition', metavar='JSON',
                       help='{"item_id","heard","session","operation_id","quote"} from an owner correction')
    group.add_argument('--deliver', action='store_true', help='retry queued corrections')
    args = parser.parse_args()
    if args.status:
        data = read() if enabled() else None
        print(json.dumps(dict(schema=1, enabled=enabled(), origin=data and data['origin'],
                              subjects=sum(i['kind'] == 'subject' for i in data['items']) if data else 0,
                              projects=sum(i['kind'] == 'project' for i in data['items']) if data else 0,
                              pending=len(pending()) if enabled() else 0)))
        return 0 if not enabled() or data else 1
    if args.deliver:
        print(json.dumps(dict(schema=1, outcomes=deliver()), ensure_ascii=False))
        return 0
    value = json.loads(args.report_misrecognition)
    outcome = report_misrecognition(value['item_id'], value['heard'], session=value['session'],
                                    operation_id=value['operation_id'], quote=value['quote'])
    print(json.dumps(dict(schema=1, outcome=outcome), ensure_ascii=False))
    return 0 if outcome in ('saved', 'duplicate', 'already_known', 'pending', 'disabled') else 1


if __name__ == '__main__':
    raise SystemExit(main())
