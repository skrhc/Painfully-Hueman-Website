#!/bin/bash
# ------------------------------------------------------------------
# ADD PHOTOS TO INVENTORY & ARMOR
#
# 1. Put new photos in the "new-photos" folder next to this file
#    (PNG, JPG, HEIC, etc.). Name each one:
#        section - maker - item name.jpg
#    e.g. outerwear - FRKM SCD - Nightblade Jacket.jpg
#    Use space-dash-space between parts. "maker - name.jpg" also
#    works. Start names with "1. ", "2. " to set the order.
# 2. Double-click this file (or run it in Terminal).
#
# Each photo is saved into images/ with a web-safe name built from
# the maker and item name (frkm-scd-nightblade-jacket.png), shrunk
# to max 1600px, then committed and pushed to GitHub. Originals
# are moved to new-photos/added/.
#
# 3. Finished sheet rows are copied to your clipboard. Click the
#    first empty cell in the sheet's "id" column and paste.
#    Columns: id, section, img, maker, name, note, credit.
#
# Options:  --no-push   commit but don't push
#           --dry-run   only show what would happen
# ------------------------------------------------------------------

set -euo pipefail
cd "$(dirname "$0")"

MAX_SIZE=1600
INBOX="new-photos"
DONE="$INBOX/added"
LAST_ID_FILE="$DONE/.last-id"
PUSH=1
DRY=0
for arg in "$@"; do
  case "$arg" in
    --no-push) PUSH=0 ;;
    --dry-run) DRY=1 ;;
  esac
done

mkdir -p "$INBOX" "$DONE" images

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

# Next id = highest id in the Google Sheet (or from the last run, if
# those rows haven't been pasted in yet) + 1.
last=0
SHEET_URL=$(grep -o "https://docs.google.com/spreadsheets/[^'\"]*" index.html | head -1 || true)
if [ -n "$SHEET_URL" ]; then
  sheet_max=$(curl -fsL "$SHEET_URL&t=$(date +%s)" 2>/dev/null \
    | awk -F, '$1 ~ /^[0-9]+$/ && $1+0 > m { m = $1+0 } END { print m+0 }' || echo 0)
  last=${sheet_max:-0}
fi
if [ -f "$LAST_ID_FILE" ]; then
  local_last=$(cat "$LAST_ID_FILE")
  [[ "$local_last" =~ ^[0-9]+$ ]] && [ "$local_last" -gt "$last" ] && last=$local_last
fi
if [ "$last" -eq 0 ]; then
  echo "Couldn't read the Google Sheet to find the next id."
  echo "Check your internet connection and try again."
  exit 1
fi

trim() { local t="$1"; t="${t#"${t%%[![:space:]]*}"}"; printf '%s' "${t%"${t##*[![:space:]]}"}"; }

# "FRKM SCD 25FW Nightblade" -> "frkm-scd-25fw-nightblade"
slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E \
    -e "s/'//g" -e $'s/\xe2\x80\x99//g' -e 's/[^a-z0-9]+/-/g' -e 's/^-+//' -e 's/-+$//'
}

# Turn "section - maker - item name.jpg" into sheet columns.
# Sets: SECTION MAKER NAME BASE (BASE = file name without extension).
parse_details() {
  local s parts=()
  s=$(basename "$1"); s="${s%.*}"
  # Drop an ordering prefix like "1. " or "02. "
  [[ "$s" =~ ^[0-9]+\.\ +(.*)$ ]] && s="${BASH_REMATCH[1]}"
  BASE="$s"
  while [[ "$s" == *" - "* ]]; do parts+=("$(trim "${s%% - *}")"); s="${s#* - }"; done
  parts+=("$(trim "$s")")
  SECTION=""; MAKER=""; NAME=""
  if [ ${#parts[@]} -eq 2 ]; then
    MAKER="${parts[0]}"; NAME="${parts[1]}"
  elif [ ${#parts[@]} -ge 3 ]; then
    SECTION="${parts[0]}"; MAKER="${parts[1]}"
    NAME="${parts[2]}"
    local i; for ((i = 3; i < ${#parts[@]}; i++)); do NAME="$NAME - ${parts[i]}"; done
  fi
}

# images/<slug>.png, adding -2, -3 ... if that name is taken.
pick_name() {
  local base k=2 out
  if [ -n "$MAKER$NAME" ]; then base=$(slug "$MAKER $NAME"); else base=$(slug "$BASE"); fi
  [ -n "$base" ] || base="item-$last"
  out="images/$base.png"
  while [ -e "$out" ] || [[ " ${added[*]-} " == *" $out "* ]]; do
    out="images/$base-$k.png"; k=$((k + 1))
  done
  printf '%s' "$out"
}

added=()
rows=""
for src in "${photos[@]}"; do
  last=$((last + 1))
  parse_details "$src"
  out=$(pick_name)

  if [ "$DRY" -eq 1 ]; then
    echo "[dry run] $(basename "$src")"
    echo "          -> $out   (id $last)"
    echo "          section: ${SECTION:--}   maker: ${MAKER:--}   name: ${NAME:--}"
    added+=("$out")
    continue
  fi

  if ! sips -s format png "$src" --out "$out" >/dev/null 2>&1; then
    echo "Skipped $(basename "$src") (not an image sips can read)"
    rm -f "$out"
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
  # id, section, img, maker, name, note, credit
  rows+="$last"$'\t'"$SECTION"$'\t'"$out"$'\t'"$MAKER"$'\t'"$NAME"$'\t\t\n'
  echo "Added $(basename "$src")  ->  $out   (id $last)"
done

[ "$DRY" -eq 1 ] && exit 0
[ ${#added[@]} -eq 0 ] && { echo "Nothing added."; exit 1; }

echo "$last" > "$LAST_ID_FILE"

git add -- "${added[@]}"
if [ ${#added[@]} -eq 1 ]; then
  msg="Add inventory photo ${added[0]#images/}"
else
  msg="Add ${#added[@]} inventory photos"
fi
git commit -q -m "$msg" -- "${added[@]}"
echo "Committed: $msg"

if [ "$PUSH" -eq 1 ]; then
  git push -q && echo "Pushed to GitHub. Live in a minute or two."
fi

printf '%s' "$rows" | pbcopy
printf '%s' "$rows" > "$DONE/sheet-rows-$(date +%Y%m%d-%H%M%S).tsv"
echo
echo "Sheet rows copied to your clipboard:"
printf '%s' "$rows" | awk -F'\t' '{printf "  %s | %s | %s | %s\n", $1, $2, $4, $5}'
echo
echo "Next: in the Google Sheet, click the first empty cell in the 'id'"
echo "column and paste (Cmd+V). Add any notes or credits after."
