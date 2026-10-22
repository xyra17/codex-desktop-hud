#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP="$HOME/Applications/Codex Desktop HUD.app"
if [ "$(uname -s)" != "Darwin" ]; then
  echo "仅支持 macOS；当前系统无法编译 AppKit 应用。" >&2
  exit 1
fi
if ! command -v swiftc >/dev/null 2>&1; then
  echo "未检测到 swiftc，请先运行：xcode-select --install" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "未检测到 Python 3，请先安装 Python 3 (brew install python)。" >&2
  exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-hud-build.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT
printf '%s\n' '编译 macOS 原生 Codex HUD…'
swiftc -O -framework AppKit -framework CoreGraphics "$ROOT/Sources/CodexHUD.swift" "$ROOT/Sources/HUDGeometry.swift" -o "$BUILD_DIR/CodexHUD"
mv "$BUILD_DIR/CodexHUD" "$APP/Contents/MacOS/CodexHUD"
cp "$ROOT/Sources/tracker.py" "$APP/Contents/Resources/tracker.py"
command -v python3 > "$APP/Contents/Resources/python-path"
command -v codex > "$APP/Contents/Resources/codex-path" || true
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
chmod 755 "$APP/Contents/MacOS/CodexHUD"
printf '%s\n' "已安装到：$APP"
printf '%s\n' '打开 Codex 桌面 App 后，HUD 将随窗口出现；仅在 Codex 内显示；拖动移动、点击展开、右键设置或退出。'
pkill -x CodexHUD 2>/dev/null || true
ATTEMPT=0
while pgrep -x CodexHUD >/dev/null 2>&1; do
  ATTEMPT=$((ATTEMPT + 1))
  if [ "$ATTEMPT" -ge 50 ]; then
    echo '旧版 HUD 未退出，请退出后重新打开应用。' >&2
    exit 1
  fi
  sleep 0.1
done
open "$APP"
