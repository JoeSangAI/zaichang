#!/usr/bin/env python3
"""Explicit live assistant validation uses the same isolated replay as offline QA.

Omit --offline only after authorization. No independent job or persistent-thread probes.
"""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.replay_meeting_assistant import main

if __name__ == '__main__':
    raise SystemExit(main())
