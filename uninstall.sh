#!/bin/sh
set -eu
APP="$HOME/Applications/Codex Desktop HUD.app"
if [ "$(uname -s)" != "Darwin" ]; then exit 1; fi
osascript -e 'tell application "System Events" to set pids to unix id of every process whose name is "CodexHUD"' >/dev/null 2>&1 || true
rm -rf "$APP"
rm -rf "$HOME/Library/Caches/CodexDesktopHUD"
echo "已删除 Codex Desktop HUD 应用与额度缓存；Codex.app 和登录凭据均未更改。"
