# 在场 / Zaichang

用户说“帮我安装在场”时，按 [docs/AGENT_SETUP.md](docs/AGENT_SETUP.md) 执行基础安装、验证，再主动介绍可选增强。每项增强获得用户同意后才配置；密钥由用户自己在应用设置里填写，agent 不索要、不代登。

The README is the public product entry; docs/AGENT_SETUP.md owns agent-led
installation and docs/INSTALL.md owns the manual installation path. Source lives in root Python modules and native/;
scripts/ owns build and packaging. Runtime state and downloaded dependencies
must stay ignored by Git.

- Preserve recording and append-only audio journals before optional AI work.
- Keep source audio and original transcript available; corrections are derived.
- Speaker channels are not people. Do not guess identities from conversation.
- Public builds use independent user data and the installing user's credentials.
- Never commit meetings, audio, voiceprints, credentials or private local paths.
- Validate through the build/offline checks and Python test suite documented in
  INSTALL.md. Offline verification must not start recording or cloud API calls.
- Homepage screenshots must show the actual product, with explicitly labelled
  public example data; do not present generated UI as implemented behavior.
