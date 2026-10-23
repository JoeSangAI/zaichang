"""Edition and data-root contract inherited by all Python workers."""
import os
from pathlib import Path


def edition(environment=None):
    env = os.environ if environment is None else environment
    return 'standalone' if env.get('ZAICHANG_EDITION') == 'standalone' else 'joe'


def standalone():
    return edition() == 'standalone'


def data_root(environment=None):
    env = os.environ if environment is None else environment
    value = env.get('ZAICHANG_DATA_ROOT', '')
    if value and Path(value).is_absolute() and '..' not in Path(value).parts:
        return Path(value)
    if value and '/' not in value and value not in {'.', '..'}:
        return Path.home() / 'Library/Application Support' / value
    name = 'ZaichangStandalone' if edition(env) == 'standalone' else 'MeetingAssistant'
    return Path.home() / 'Library/Application Support' / name


# Optional integration configuration is user-owned, never bundled with the app.
def connectors():
    import json
    from urllib.parse import urlsplit
    try:
        path = data_root() / 'connectors.json'
        if path.stat().st_size > 65536:
            return {}
        value = json.loads(path.read_text(encoding='utf-8'))
        if not isinstance(value, dict) or type(value.get('schema')) is not int or value['schema'] != 1:
            return {}
    except (OSError, ValueError):
        return {}
    result = {'schema': 1}
    def path_value(value):
        if not isinstance(value, str) or not value.strip() or any(ord(c) < 32 for c in value):
            return None
        try:
            path = Path(value).expanduser()
        except (RuntimeError, OSError, ValueError):
            return None
        return str(path) if path.is_absolute() and '..' not in path.parts else None
    roots = value.get('project_roots', [])
    result['project_roots'] = list(dict.fromkeys(p for v in roots if (p := path_value(v)))) if isinstance(roots, list) else []
    for key in ('general_terms', 'people_terms', 'people_loader'):
        if path := path_value(value.get(key)):
            result[key] = path
    hint = value.get('context_hint')
    if isinstance(hint, str) and hint.strip():
        result['context_hint'] = hint.strip()[:16000]
    archive = value.get('archive')
    if isinstance(archive, dict) and isinstance(archive.get('url'), str) and isinstance(archive.get('app_id'), str):
        try:
            url = urlsplit(archive['url'])
            if (url.scheme in ('http', 'https') and url.hostname and not url.username and not url.password
                    and not url.query and not url.fragment and archive['app_id'].strip()):
                result['archive'] = {'url': archive['url'].rstrip('/'), 'app_id': archive['app_id'].strip()}
        except ValueError:
            pass
    bridge = value.get('agent_bridge')
    if isinstance(bridge, dict) and isinstance(bridge.get('tunnel_id'), str) and bridge['tunnel_id'].strip():
        key_file, server = path_value(bridge.get('key_file')), path_value(bridge.get('mcp_server'))
        if key_file and server:
            result['agent_bridge'] = {'tunnel_id':bridge['tunnel_id'].strip(), 'key_file':key_file, 'mcp_server':server}
    return result


def context_guidance():
    config = connectors()
    lines = []
    if config.get('project_roots'):
        lines.append('用户配置的项目资料目录：' + '、'.join(config['project_roots']))
    if config.get('context_hint'):
        lines.append(config['context_hint'])
    return ('\n\n用户配置的资料指引：\n' + '\n'.join(lines)) if lines else ''
