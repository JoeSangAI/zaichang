# 在场 / Zaichang

用户说“帮我安装在场”时，按 [docs/AGENT_SETUP.md](docs/AGENT_SETUP.md) 执行基础安装、验证，再主动介绍可选增强。每项增强获得用户同意后才配置；密钥由用户自己在应用设置里填写，agent 不索要、不代登。

The README is the public product entry; docs/AGENT_SETUP.md owns agent-led
installation and docs/INSTALL.md owns the manual installation path. Source lives in root Python modules and native/;
scripts/ owns build and packaging. Runtime state and downloaded dependencies
must stay ignored by Git.

If `.local/AGENTS.private.md` exists, read it too: it holds this machine's private rules, and
`.local/STATUS.md` holds the owner's current state. `.local/` is never committed.

## Rules that must hold

- One app, one data directory (`~/Library/Application Support/ZaichangStandalone`), one release. The
  author uses the same build everyone installs; anything personal comes from that user's own
  `connectors.json`, never from a separate version.
- Recording never stops for processing. When conversion, transcription or the disk fall behind, audio is
  held (minutes, not seconds) and the transcript catches up later; only a stretch longer than that is left
  as a padded gap, and the recording goes on.
- Preserve recording and append-only audio journals before optional AI work.
- Keep source audio and original transcript available; corrections are derived.
- Speaker channels are not people. Do not guess identities from conversation.
- Users bring their own credentials; they live in that user's Keychain and never in the repository.
- Never commit meetings, audio, voiceprints, credentials or private local paths.
  `scripts/check_public.py` guards every push.
- Validate through `scripts/build_offline.py`, `scripts/offline_check.py` and
  `python3 -m unittest discover -s tests -t .`. Offline verification must not start recording or cloud API calls.
- Homepage screenshots must show the actual product, with explicitly labelled
  public example data; do not present generated UI as implemented behavior.
- Review `native/FirstRunGuide.swift` for every release (services, permissions, steps, wording) and only
  then set `FIRST_RUN_REVIEWED_FOR` in `app_version.py`; releasing refuses otherwise.

## Releasing

A release is a version bump: change `VERSION` and `BUILD` in `app_version.py`, add a section to
`CHANGELOG.md` written for the people who use 在场, commit, `git push`. `.githooks/pre-push` runs the public
check, builds and signs the app from the clean checkout, refuses a bundle that depends on this machine,
and publishes the GitHub release once the push lands; every installed 在场 then fetches it quietly and
swaps it in after a quit. A push that keeps `VERSION` reaches nobody. Enable the hook in a new checkout
with `git config core.hooksPath .githooks`.

Updates install only when the new app is signed by the release team (`AppUpdate.swift`), so the signing
identity must stay the same: changing it strands everyone on the old version and resets their permissions.
The Apple Development certificate is renewed once a year in Xcode → Settings → Accounts → Manage
Certificates; the release script picks the longest-lasting one.
