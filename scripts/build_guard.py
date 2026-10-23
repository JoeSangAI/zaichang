"""Lease the user's existing desktop UI lock after explicit recorder-exit confirmation.

This does not inspect other processes. Use only when the user has confirmed all
recording/processing is stopped. The normal build retains process inspection.
Holding this same flock through compilation prevents the desktop UI restarting.
"""
from pathlib import Path
import fcntl
import os
import plistlib
import stat
import tempfile


def acquire_desktop_idle_lease(app: Path | None = None) -> int:
    app = app or Path.home() / 'Desktop/在场.app'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.joesang.meeting-assistant.desktop':
        raise RuntimeError('Unexpected desktop recorder identity')
    expected = Path(tempfile.gettempdir()) / f'joesang-meeting-assistant-desktop-ui-{os.getuid()}.lock'
    if info.get('AppLockPath') != str(expected):
        raise RuntimeError('Desktop recorder lock path is not the supported startup lock')
    fd = os.open(expected, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        attrs = os.fstat(fd)
        if not stat.S_ISREG(attrs.st_mode) or attrs.st_uid != os.getuid():
            raise RuntimeError('Desktop recorder lock is not an owned regular file')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BaseException:
        os.close(fd)
        raise
    return fd
