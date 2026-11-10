#!/bin/bash
# Double-click to install (or reinstall) the ARMORY Mac helper, which fetches
# the 8-second clips for video links sent from the ADD page. It runs every
# minute while you're logged in. To remove it, run this with "remove":
#   bash install-mac-helper.command remove
set -e
cd "$(dirname "$0")"
LABEL="com.painfullyhueman.armory-helper"
DEST="$HOME/Library/Application Support/ArmoryHelper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if [ "${1:-}" = "remove" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"; rm -rf "$DEST"
  echo "ARMORY Mac helper removed."; exit 0
fi

command -v brew >/dev/null || { echo "Homebrew is needed first: https://brew.sh"; exit 1; }
for tool in yt-dlp ffmpeg; do command -v "$tool" >/dev/null || brew install --quiet "$tool"; done

mkdir -p "$DEST" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp tools/mac-helper.sh "$DEST/mac-helper.sh"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$DEST/mac-helper.sh</string></array>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/ArmoryHelper.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/ArmoryHelper.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "ARMORY Mac helper installed. It checks for video links every minute."
echo "Log: ~/Library/Logs/ArmoryHelper.log"
