#!/bin/bash
# Double-click to install (or reinstall) the ARMORY Mac helper, which fetches
# the 8-second clips for video links sent from the ADD page, and looks up
# photos sent without a maker / name (using Claude Code on your Claude plan).
# It runs every minute while you're logged in. To remove it, run this with "remove":
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
  security delete-generic-password -a armory -s armory-claude-token >/dev/null 2>&1 || true
  echo "ARMORY Mac helper removed."; exit 0
fi

command -v brew >/dev/null || { echo "Homebrew is needed first: https://brew.sh"; exit 1; }
for tool in yt-dlp ffmpeg; do command -v "$tool" >/dev/null || brew install --quiet "$tool"; done

# Claude Code, for looking up photos. It runs in the background, so it gets its
# own long-lived sign-in (your Claude plan, no API key), kept in the keychain.
export PATH="$HOME/.local/bin:$PATH"
if ! command -v claude >/dev/null; then
  echo "Installing Claude Code (Anthropic's official installer)…"
  curl -fsSL https://claude.ai/install.sh | bash
fi
if ! security find-generic-password -a armory -s armory-claude-token -w >/dev/null 2>&1; then
  echo
  echo "One-time sign-in so the helper can look up photos."
  echo "A browser window opens: sign in with your Claude account and approve."
  echo "Then copy the long token it prints (starts with sk-ant-oat) and paste it here."
  echo
  claude setup-token || true
  echo
  read -r -s -p "Paste the token, then press Return (or just Return to skip): " TOKEN; echo
  if [ -n "$TOKEN" ]; then
    security add-generic-password -U -a armory -s armory-claude-token -w "$TOKEN"
    echo "Saved in the keychain."
  else
    echo "Skipped: photos without a maker / name will be added as UNKNOWN. Run this again to sign in."
  fi
fi

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
echo "ARMORY Mac helper installed. It checks for video links and photos to look up every minute."
echo "Log: ~/Library/Logs/ArmoryHelper.log"
