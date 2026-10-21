# 在场 / Zaichang

The README is the public product entry; docs/INSTALL.md owns installation and
verification instructions. Source lives in root Python modules and native/;
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
