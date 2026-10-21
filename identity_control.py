"""One local pipe command for idle native UI; no credentials/files/network/audio."""
import json,sys
from identity_session import IdentitySession
try:
    row=sys.stdin.readline(4_000_001)
    if len(row)>4_000_000:raise ValueError('capacity')
    r=json.loads(row);s=IdentitySession(r['session'],synthetic_only=r.get('synthetic_only') is True,human_use_authorized=r.get('human_use_authorized') is True,snapshot=r.get('state'))
    for e in s.command(r['command']):print(json.dumps(e,ensure_ascii=False),flush=True)
except Exception as e:
    known={'person_consent_required','human_identity_scope_not_authorized','need_two_people_three_independent_samples_each','samples_not_separable_keep_unknown','held_out_sample_failed_keep_unknown','segment_changed_or_unavailable','archive_domain_or_version'}
    print(json.dumps({'type':'identity_ack','ok':False,'code':str(e) if str(e) in known else 'identity_command_invalid'}));sys.exit(1)
