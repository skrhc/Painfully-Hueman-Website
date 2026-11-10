#!/bin/bash
# ------------------------------------------------------------------
# ARMORY Mac helper: fetches video-link clips for the ADD page.
#
# YouTube refuses downloads from GitHub's servers, so when a submission
# has a video link, this Mac fetches its best 8 seconds (tools/fetch-clip.py)
# and pushes the clip into the submission's inbox folder; the usual GitHub
# job then makes the loop and adds the item.
#
# Installed by install-mac-helper.command, which runs this every minute
# (macOS LaunchAgent). It keeps its own small copy of the repository (just
# the inbox and tools) in ~/Library/Application Support/ArmoryHelper,
# outside the Desktop. Log: ~/Library/Logs/ArmoryHelper.log
# Needs: git (with push access), python3, yt-dlp, ffmpeg (Homebrew).
# ------------------------------------------------------------------
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
REPO_URL="https://github.com/skrhc/Painfully-Hueman-Website.git"
HOME_DIR="$HOME/Library/Application Support/ArmoryHelper"
WORK="$HOME_DIR/repo"
LOCK="$HOME_DIR/lock"

mkdir -p "$HOME_DIR"
# one run at a time (a long download can outlast a minute)
if ! mkdir "$LOCK" 2>/dev/null; then
  # a lock older than 30 minutes is left over from a crash
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then rmdir "$LOCK"; mkdir "$LOCK" || exit 0; else exit 0; fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# a small copy: only the ARMORY inbox and tools are checked out
if [ ! -d "$WORK/.git" ]; then
  log "setting up $WORK"
  git clone -q --depth 1 --filter=blob:none --sparse "$REPO_URL" "$WORK" || { log "clone failed"; exit 1; }
  git -C "$WORK" sparse-checkout set inventory-and-armor/inbox inventory-and-armor/tools
fi
cd "$WORK" || exit 1
git fetch -q --depth 1 origin main && git reset -q --hard origin/main || { log "can't reach GitHub"; exit 0; }

# YouTube changes often; keep yt-dlp fresh (at most once a day)
STAMP="$HOME_DIR/yt-dlp-updated"
if [ -z "$(find "$STAMP" -mtime -1 2>/dev/null)" ]; then
  brew upgrade --quiet yt-dlp >/dev/null 2>&1; touch "$STAMP"
fi

shopt -s nullglob
for entry in inventory-and-armor/inbox/*/entry.json; do
  sub=$(dirname "$entry")
  url=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("video_url") or "")' "$entry")
  [ -n "$url" ] || continue
  have=("$sub"/0.*); [ ${#have[@]} -eq 0 ] || continue
  [ -f "$sub/failed.txt" ] && continue
  log "fetching $url ($sub)"
  if out=$(python3 inventory-and-armor/tools/fetch-clip.py "$url" "$sub" 2>"$HOME_DIR/last-error.txt"); then
    log "fetched: $out"
    msg="ARMORY: video clip for $(basename "$sub")"
  else
    log "failed: $(tail -c 400 "$HOME_DIR/last-error.txt")"
    { echo "The Mac helper couldn't fetch $url:"; tail -c 400 "$HOME_DIR/last-error.txt"; } > "$sub/failed.txt"
    msg="ARMORY: couldn't fetch video for $(basename "$sub")"
  fi
  git add -A "$sub"
  git -c user.name="armory-mac" -c user.email="armory@users.noreply.github.com" commit -q -m "$msg"
  for i in 1 2 3; do
    git pull -q --rebase origin main && git push -q origin HEAD:main && break
    sleep 5
  done || log "push failed"
done
