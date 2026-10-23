#!/usr/bin/env python3
"""Read-only local connector diagnostics; no person names or model calls."""
import json
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from runtime_config import connectors, data_root
from shared_terms import compiled_owners


def check():
    config=connectors();path=data_root()/'connectors.json'
    owners=compiled_owners(max_age=-1)
    errors=sum(bool(o['error']) for o in owners)
    fields={key:Path(config[key]).exists() for key in ('general_terms','people_terms','people_loader') if key in config}
    roots=[Path(p).is_dir() for p in config.get('project_roots',[])]
    invalid=path.exists() and not config
    # Report malformed optional fields as invalid, not as a successful disabled setup.
    try: raw=json.loads(path.read_text()) if path.exists() else {}
    except (ValueError,OSError):raw={}
    for key in ('general_terms','people_terms','people_loader','archive','context_hint'):
        if isinstance(raw,dict) and raw.get(key) and key not in config:invalid=True
    if isinstance(raw,dict) and raw.get('project_roots'):
        if not isinstance(raw['project_roots'],list) or len(config.get('project_roots',[]))!=len(raw['project_roots']):invalid=True
    return {'ok':not invalid and errors==0 and all(fields.values()) and all(roots),
            'configured':bool(config),'project_roots_exist':roots,'configured_files_exist':fields,
            'term_rows':{layer:sum(len(o['rows']) for o in owners if o['layer']==layer) for layer in ('project','people','general')},
            'term_errors':errors,'archive_enabled':'archive' in config,'people_loader_enabled':bool(config.get('people_loader') and roots),
            'context_hint_enabled':bool(config.get('context_hint'))}


if __name__=='__main__':
    result=check();print(json.dumps(result,ensure_ascii=False,indent=2));raise SystemExit(0 if result['ok'] else 1)
