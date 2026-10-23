"""Synthetic authoritative loader for integration contract checks."""
import hashlib
import re

def load_people(root):
    source = root / '公司资料/内部人员与长期协作方.md'
    text = source.read_text()
    result = []
    for raw in re.findall(r'- \*\*(.+?)：\*\*', text):
        name, _, aliases = raw.partition('（')
        aliases = [s.strip() for s in aliases.rstrip('）').split('/') if s.strip()]
        result.append(dict(id='person:' + hashlib.sha256(name.encode()).hexdigest()[:20],
                           name=name, aliases=aliases, organization='示例组织', role='示例角色', evidence=[str(source)]))
    return result
