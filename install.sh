#!/bin/bash
# Installs the latest 在场. curl -fsSL https://raw.githubusercontent.com/JoeSangAI/zaichang/main/install.sh | bash
set -euo pipefail

FEED="https://github.com/JoeSangAI/zaichang/releases/latest/download/latest.json"
REQUIREMENT='identifier "com.joesang.zaichang.standalone" and anchor apple generic and certificate leaf[subject.OU] = "3BVM9N9HS4"'
DATA="$HOME/Library/Application Support/ZaichangStandalone"

say() { printf '\033[1m%s\033[0m\n' "$1"; }
stop() { printf '没有装好：%s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || stop "在场只支持 Mac。"
[ "$(uname -m)" = "arm64" ] || stop "目前只支持 Apple 芯片的 Mac（M1 及以后）。"
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 15 ] || stop "需要 macOS 15 或更新，这台是 $(sw_vers -productVersion)。"
/usr/local/bin/python3 -c 'import certifi, numpy' 2>/dev/null \
  || stop "在场的后台工作要用 /usr/local/bin/python3（3.12）和 certifi、numpy。按 docs/INSTALL.md 装好 Python，再运行 /usr/local/bin/python3 -m pip install certifi numpy，然后重试。"

# Update the copy the user already has instead of leaving a stale one behind.
DEST="${ZAICHANG_INSTALL_DIR:-$HOME/Applications}"
if [ -z "${ZAICHANG_INSTALL_DIR:-}" ] && [ ! -e "$HOME/Applications/在场.app" ] && [ -d "/Applications/在场.app" ] && [ ! -L "/Applications/在场.app" ]; then
  DEST="/Applications"
fi
APP="$DEST/在场.app"
[ ! -L "$APP" ] || stop "$APP 是一个链接，不是应用本身。"
# Never close it from here: it may be recording.
pgrep -f "$APP/Contents/MacOS/MeetingAssistant" >/dev/null && stop "在场正在运行。保存并退出后再装，会议资料不受影响。"
mkdir -p "$DEST"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say "正在查找最新版本…"
curl -fsSL --retry 3 "$FEED" -o "$WORK/latest.json" || stop "连不上 GitHub，检查网络后再试一次。"
field() { plutil -extract "$1" raw -o - "$WORK/latest.json"; }
VERSION="$(field version)"; ZIP="$(field zip)"; SHA="$(field sha256)"

say "正在下载在场 $VERSION…"
curl -fL --retry 3 --progress-bar "$ZIP" -o "$WORK/app.zip" || stop "下载没有完成，检查网络后再试一次。"
echo "$SHA  $WORK/app.zip" | shasum -a 256 -c - >/dev/null 2>&1 || stop "下载的文件不完整，再试一次。"

ditto -x -k "$WORK/app.zip" "$WORK/unpacked"
xattr -dr com.apple.quarantine "$WORK/unpacked/在场.app" 2>/dev/null || true
codesign --verify --deep --strict "-R=$REQUIREMENT" "$WORK/unpacked/在场.app" 2>/dev/null || stop "这份安装包的签名不对，没有安装。"

pgrep -f "$APP/Contents/MacOS/MeetingAssistant" >/dev/null && stop "在场刚被打开了。退出后再装一次。"
if [ -e "$APP" ]; then
  mkdir -p "$DATA"
  rm -rf "$DATA/previous-version.app"
  mv "$APP" "$DATA/previous-version.app"
fi
mv "$WORK/unpacked/在场.app" "$APP"

say "在场 $VERSION 装好了，在“$DEST”里。"
echo "会议资料在 $DATA，安装和更新都不会动它。以后的新版本在场会自己下载，退出时换上。"
