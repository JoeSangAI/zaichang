#!/bin/bash
# Installs the latest 在场. curl -fsSL https://raw.githubusercontent.com/JoeSangAI/zaichang/main/install.sh | bash
set -euo pipefail

FEED="${ZAICHANG_FEED:-https://github.com/JoeSangAI/zaichang/releases/latest/download/latest.json}"
REQUIREMENT='identifier "com.joesang.zaichang.standalone" and anchor apple generic and certificate leaf[subject.OU] = "3BVM9N9HS4"'
DATA="$HOME/Library/Application Support/ZaichangStandalone"

say() { printf '\033[1m%s\033[0m\n' "$1"; }
stop() { printf '没有装好：%s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || stop "在场只支持 Mac。"
[ "$(uname -m)" = "arm64" ] || stop "目前只支持 Apple 芯片的 Mac（M1 及以后）。"
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 15 ] || stop "需要 macOS 15 或更新，这台是 $(sw_vers -productVersion)。"
# Any Python 3 works, from any installer. The app looks in the same places, in the same order
# (RuntimeConfiguration.pythonCandidates); /usr/bin/python3 is left out since without developer tools it only prompts.
pythons() {
  for dir in /usr/local/bin /opt/homebrew/bin "$HOME/.local/bin" "$HOME/.pyenv/shims" \
      "$HOME"/miniconda3/bin "$HOME"/anaconda3/bin "$HOME"/miniforge3/bin "$HOME"/mambaforge/bin \
      /opt/miniconda3/bin /opt/anaconda3/bin /opt/miniforge3/bin /opt/mambaforge/bin \
      /opt/homebrew/Caskroom/miniconda/base/bin /opt/homebrew/Caskroom/anaconda/base/bin \
      /opt/homebrew/Caskroom/miniforge/base/bin /opt/homebrew/Caskroom/mambaforge/base/bin \
      $(ls -d /Library/Frameworks/Python.framework/Versions/3.*/bin 2>/dev/null | sort -rV) \
      /Library/Developer/CommandLineTools/usr/bin /Applications/Xcode.app/Contents/Developer/usr/bin; do
    [ -x "$dir/python3" ] && echo "$dir/python3"
    ls "$dir" 2>/dev/null | grep -E '^python3\.[0-9]+$' | sort -t. -k2 -rn | sed "s|^|$dir/|"
  done
}
ready() { "$1" -c 'import certifi, numpy' </dev/null >/dev/null 2>&1; }
PYTHON=""
for candidate in $(pythons); do ready "$candidate" && { PYTHON="$candidate"; break; }; done
if [ -z "$PYTHON" ]; then
  PYTHON="$(pythons | head -n 1)"
  [ -n "$PYTHON" ] || stop "这台 Mac 还没有 Python 3。任意版本都行：从 https://www.python.org/downloads/macos/ 下载安装，或运行 brew install python，然后重试。"
  say "给 $PYTHON 装在场要用的 certifi 和 numpy（只装到你自己的用户目录）…"
  # Homebrew's and uv's Pythons refuse plain pip installs (PEP 668); a user-directory install leaves theirs untouched.
  "$PYTHON" -m pip install -q --user --no-warn-script-location certifi numpy </dev/null 2>/dev/null \
    || "$PYTHON" -m pip install -q --user --no-warn-script-location --break-system-packages certifi numpy </dev/null \
    || stop "没能给 $PYTHON 装上 certifi 和 numpy。可以手动运行 $PYTHON -m pip install --user certifi numpy 看看报错，然后重试。"
  ready "$PYTHON" || stop "$PYTHON 装好了 certifi 和 numpy 却仍导入不了，请把这条信息发给维护者。"
fi
say "后台工作用 $PYTHON（$("$PYTHON" -V 2>&1)）。"

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
field() { plutil -extract "$1" raw -o - "$WORK/latest.json" 2>/dev/null; }
fetch() {  # url sha256 file
  curl -fL --retry 3 --progress-bar "$1" -o "$3" || stop "下载没有完成，检查网络后再试一次。"
  echo "$2  $3" | shasum -a 256 -c - >/dev/null 2>&1 || stop "下载的文件不完整，再试一次。"
}
VERSION="$(field version)"

# The app and its voice models come as two packages; the models change rarely and are shared by releases.
if MODELS="$(field models.zip)"; then
  say "正在下载在场 $VERSION…"
  fetch "$(field patch.zip)" "$(field patch.sha256)" "$WORK/app.zip"
  say "正在下载语音模型…"
  fetch "$MODELS" "$(field models.sha256)" "$WORK/models.zip"
  ditto -x -k "$WORK/app.zip" "$WORK/unpacked"
  ditto -x -k "$WORK/models.zip" "$WORK/unpacked"
else
  say "正在下载在场 $VERSION…"
  fetch "$(field zip)" "$(field sha256)" "$WORK/app.zip"
  ditto -x -k "$WORK/app.zip" "$WORK/unpacked"
fi
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
