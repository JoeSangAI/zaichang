"""Shared source-ID validation; reference/raw audio never enters cloud accounting."""
import re

def is_transcript_track(value):
    return isinstance(value,str) and (value in {'mic','remote'} or
        re.fullmatch(r'(?:mic-g|remote-g|app-[a-f0-9]{16}-g)[1-9][0-9]{0,2}|app-[a-f0-9]{16}',value) is not None)

def transcript_tracks(directory):
    suffix='-manifest.json'
    return sorted(path.name[:-len(suffix)] for path in directory.glob('*'+suffix)
                  if not path.is_symlink() and is_transcript_track(path.name[:-len(suffix)]))

def recording_control_signal(command,session):
    import signal
    if not isinstance(command,dict) or command.get('session')!=session or command.get('operation')!='recording_control':
        return None
    return {'pause':signal.SIGUSR1,'resume':signal.SIGUSR2,
            'finish':signal.SIGWINCH}.get(command.get('action'))
