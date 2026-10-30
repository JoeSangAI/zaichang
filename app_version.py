"""The one version both editions ship. Bump it here and nowhere else."""
VERSION = '0.4.2'
BUILD = '2026103003'
# Set to VERSION only after checking native/FirstRunGuide.swift still fits this release:
# new services, permissions, setup steps or wording. Installing and publishing refuse otherwise.
FIRST_RUN_REVIEWED_FOR = '0.4.2'


def first_run_review_problem():
    if FIRST_RUN_REVIEWED_FOR != VERSION:
        return f'发版前先复核首次启动引导（native/FirstRunGuide.swift），确认后把 FIRST_RUN_REVIEWED_FOR 改成 {VERSION}'
    return ''
