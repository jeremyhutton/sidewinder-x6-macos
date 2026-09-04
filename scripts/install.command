#!/bin/bash
# Double-click this after unzipping the release.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$HERE/SidewinderX6.app"
APP_DST="/Applications/SidewinderX6.app"
AGENT_SRC="$HERE/com.vjh.sidewinder-x6.plist"
AGENT_DST="$HOME/Library/LaunchAgents/com.vjh.sidewinder-x6.plist"

if [[ ! -d "$APP_SRC" ]]; then
  osascript -e 'display alert "Sidewinder X6" message "SidewinderX6.app was not found next to this installer." as critical'
  exit 1
fi

launchctl bootout "gui/$(id -u)/com.vjh.sidewinder-x6" >/dev/null 2>&1 || true
killall SidewinderX6 >/dev/null 2>&1 || true
sleep 1

rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
xattr -dr com.apple.quarantine "$APP_DST" >/dev/null 2>&1 || true

mkdir -p "$HOME/Library/LaunchAgents" \
  "$HOME/Library/Application Support/SidewinderX6"
if [[ ! -f "$HOME/Library/Application Support/SidewinderX6/config.json" && -f "$APP_DST/Contents/Resources/config.example.json" ]]; then
  cp "$APP_DST/Contents/Resources/config.example.json" \
    "$HOME/Library/Application Support/SidewinderX6/config.json"
fi
if [[ -f "$AGENT_SRC" ]]; then
  cp "$AGENT_SRC" "$AGENT_DST"
  launchctl bootstrap "gui/$(id -u)" "$AGENT_DST" >/dev/null 2>&1 || \
    open -g -a "$APP_DST"
else
  open -g -a "$APP_DST"
fi

osascript -e 'display dialog "Sidewinder X6 is in /Applications and will start at login.

Grant Accessibility: System Settings → Privacy & Security → Accessibility → Sidewinder X6." buttons {"OK"} default button 1 with title "Sidewinder X6"'
open "x-apple.systemsettings:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true
