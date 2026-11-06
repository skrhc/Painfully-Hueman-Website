#!/bin/bash
# ------------------------------------------------------------------
# ADD PHOTOS TO INVENTORY & ARMOR
#
# 1. Put new photos in the "new-photos" folder next to this file
#    (any name; PNG, JPG, HEIC, etc.). They're added in name order.
# 2. Double-click this file (or run it in Terminal).
#
# Each photo is numbered (079.png, 080.png, ...), shrunk to max
# 1600px, saved into images/, then committed and pushed to GitHub.
# Originals are moved to new-photos/added/.
#
# Then add a row to the Google Sheet with that id and leave the
# "img" column blank; the page finds images/<id>.png by itself.
#
# Options:  --no-push   commit but don't push
#           --dry-run   only show what would happen
# ------------------------------------------------------------------

set -euo pipefail
cd "$(dirname "$0")"

MAX_SIZE=1600
INBOX="new-photos"
DONE="$INBOX/added"
PUSH=1
DRY=0
for arg in "$@"; do
  case "$arg" in
    --no-push) PUSH=0 ;;
    --dry-run) DRY=1 ;;
  esac
done

mkdir -p "$INBOX" "$DONE" images

# Highest existing number in images/ (e.g. 078.png -> 78).
last=0
for f in images/[0-9]*.*; do
  [ -e "$f" ] || continue
  n=$(basename "$f" | sed -E 's/^0*([0-9]+)\..*/\1/')
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt "$last" ] && last=$n
done

# Collect new photos (skip hidden files and the "added" folder).
photos=()
while IFS= read -r -d '' f; do photos+=("$f"); done < <(
  find "$INBOX" -maxdepth 1 -type f ! -name '.*' -print0 | sort -z
)

if [ ${#photos[@]} -eq 0 ]; then
  echo "No photos found in inventory-and-armor/$INBOX/"
  echo "Drop some in and run this again."
  exit 0
fi

added=()
for src in "${photos[@]}"; do
  last=$((last + 1))
  id=$(printf '%03d' "$last")
  out="images/$id.png"

  if [ "$DRY" -eq 1 ]; then
    echo "[dry run] $(basename "$src")  ->  $out"
    continue
  fi

  if ! sips -s format png "$src" --out "$out" >/dev/null 2>&1; then
    echo "Skipped $(basename "$src") (not an image sips can read)"
    last=$((last - 1))
    continue
  fi

  # Shrink only if bigger than MAX_SIZE on its longest side.
  w=$(sips -g pixelWidth "$out" | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$out" | awk '/pixelHeight/{print $2}')
  if [ "$w" -gt "$MAX_SIZE" ] || [ "$h" -gt "$MAX_SIZE" ]; then
    sips -Z "$MAX_SIZE" "$out" >/dev/null
  fi

  mv "$src" "$DONE/"
  added+=("$out")
  echo "Added $(basename "$src")  ->  $out   (sheet id: $last)"
done

[ "$DRY" -eq 1 ] && exit 0
[ ${#added[@]} -eq 0 ] && { echo "Nothing added."; exit 1; }

git add -- "${added[@]}"
if [ ${#added[@]} -eq 1 ]; then
  msg="Add inventory photo ${added[0]#images/}"
else
  msg="Add inventory photos ${added[0]#images/}-${added[${#added[@]}-1]#images/}"
fi
git commit -q -m "$msg" -- "${added[@]}"
echo "Committed: $msg"

if [ "$PUSH" -eq 1 ]; then
  git push -q && echo "Pushed to GitHub. Live in a minute or two."
fi

echo
echo "Next: add a row per id above in the Google Sheet, leave 'img' blank."
