#!/bin/bash
# ------------------------------------------------------------------
# ADD PHOTOS TO INVENTORY & ARMOR
#
# 1. Put new photos in the "new-photos" folder next to this file
#    (PNG, JPG, HEIC, etc.). They're added in name order; start
#    names with "1. ", "2. " etc. to set the order (it's ignored).
#    Name each one:   section - maker - item name.jpg
#    e.g.             outerwear - FRKM SCD - Nightblade Jacket.jpg
#    (Use space-dash-space between parts. "maker - name.jpg" also
#    works; a name with no " - " just gets a blank row.)
# 2. Double-click this file (or run it in Terminal).
#
# Each photo is numbered (079.png, 080.png, ...), shrunk to max
# 1600px, saved into images/, then committed and pushed to GitHub.
# Originals are moved to new-photos/added/.
#
# 3. Finished sheet rows are copied to your clipboard. Click the
#    first empty cell in the sheet's "id" column and paste.
#    Columns: id, section, img (blank), maker, name, note, credit.
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

# Turn "section - maker - item name.jpg" into sheet columns.
# Sets: SECTION MAKER NAME (blank if the file name has no " - ").
trim() { local t="$1"; t="${t#"${t%%[![:space:]]*}"}"; printf '%s' "${t%"${t##*[![:space:]]}"}"; }
parse_details() {
  local s parts=()
  s=$(basename "$1"); s="${s%.*}"
  # Drop an ordering prefix like "1. " or "02. "
  [[ "$s" =~ ^[0-9]+\.\ +(.*)$ ]] && s="${BASH_REMATCH[1]}"
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

added=()
rows=""
for src in "${photos[@]}"; do
  last=$((last + 1))
  id=$(printf '%03d' "$last")
  out="images/$id.png"

  if [ "$DRY" -eq 1 ]; then
    parse_details "$src"
    echo "[dry run] $(basename "$src")  ->  $out"
    echo "          section: ${SECTION:--}   maker: ${MAKER:--}   name: ${NAME:--}"
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

  parse_details "$src"
  mv "$src" "$DONE/"
  added+=("$out")
  # id, section, img (blank), maker, name, note, credit
  rows+="$last"$'\t'"$SECTION"$'\t\t'"$MAKER"$'\t'"$NAME"$'\t\t\n'
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

printf '%s' "$rows" | pbcopy
printf '%s' "$rows" > "$DONE/sheet-rows-$(date +%Y%m%d-%H%M%S).tsv"
echo
echo "Sheet rows copied to your clipboard:"
printf '%s' "$rows" | awk -F'\t' '{printf "  %s | %s | %s | %s\n", $1, $2, $4, $5}'
echo
echo "Next: in the Google Sheet, click the first empty cell in the 'id'"
echo "column and paste (Cmd+V). Add any notes or credits after."
