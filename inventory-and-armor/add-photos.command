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
#    More photos of the same item: same name plus " #2", " #3"...
#        outerwear - FRKM SCD - Nightblade Jacket #2.jpg
#    They become one item; the first photo is the cover.
#    To keep a photo's background, add "(keep bg)" to its name:
#        object - Unknown - Box (keep bg).jpg
#    Paintings (section "painting") always keep their background.
# 2. Double-click this file (or run it in Terminal).
#
# Each photo has its background removed and is cropped to the item
# (photos that are already transparent are left as they are), saved
# into images/ with a web-safe name built from the maker and item
# name (frkm-scd-nightblade-jacket.png), shrunk to max 1600px, then committed and pushed to GitHub. Originals
# are moved to new-photos/added/.
#
# 3. Finished sheet rows are copied to your clipboard. Click the
#    first empty cell in the sheet's "id" column and paste.
#    Columns: id, section, img, maker, name, note, credit.
#
# Options:  --no-push   commit but don't push
#           --dry-run   only show what would happen
#           --keep-bg   don't remove backgrounds
# ------------------------------------------------------------------

set -euo pipefail
cd "$(dirname "$0")"

MAX_SIZE=1600
INBOX="new-photos"
DONE="$INBOX/added"
LAST_ID_FILE="$DONE/.last-id"
PUSH=1
DRY=0
REMOVE_BG=1
for arg in "$@"; do
  case "$arg" in
    --no-push) PUSH=0 ;;
    --dry-run) DRY=1 ;;
    --keep-bg) REMOVE_BG=0 ;;
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
  printf '%s' "$1" | perl -CS -MUnicode::Normalize -pe '$_ = NFD($_); s/\pM//g' \
    | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E \
    -e "s/'//g" -e $'s/\xe2\x80\x99//g' -e 's/[^a-z0-9]+/-/g' -e 's/^-+//' -e 's/-+$//'
}

# Turn "section - maker - item name.jpg" into sheet columns.
# Sets: SECTION MAKER NAME BASE PHOTO_NO (BASE = file name without
# extension or photo number).
parse_details() {
  local s parts=()
  s=$(basename "$1"); s="${s%.*}"
  # Drop an ordering prefix like "1. " or "02. "
  [[ "$s" =~ ^[0-9]+\.\ +(.*)$ ]] && s="${BASH_REMATCH[1]}"
  # Drop a photo number like " #2" or " (2)": extra photos of one item
  # "(keep bg)" anywhere in the name: don't remove the background
  KEEP_BG=0
  shopt -s nocasematch
  if [[ "$s" =~ ^(.*[^[:space:]])?[[:space:]]*\(keep[[:space:]]*bg\)(.*)$ ]]; then
    s="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"; KEEP_BG=1
  fi
  shopt -u nocasematch
  PHOTO_NO=1
  if [[ "$s" =~ ^(.*[^[:space:]])[[:space:]]+(#|\()([0-9]+)\)?$ ]]; then
    s="${BASH_REMATCH[1]}"; PHOTO_NO="${BASH_REMATCH[3]}"
  fi
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

# Background removal helper: built once from tools/remove-bg.swift
# (about a minute the first time), then reused.
BG_TOOL="$INBOX/.tools/remove-bg"
if [ "$REMOVE_BG" -eq 1 ] && [ "$DRY" -eq 0 ]; then
  if [ ! -x "$BG_TOOL" ] || [ tools/remove-bg.swift -nt "$BG_TOOL" ]; then
    echo "Setting up background removal (one time, about a minute)..."
    mkdir -p "$INBOX/.tools"
    if ! swiftc -O tools/remove-bg.swift -o "$BG_TOOL" 2>/dev/null; then
      echo "  Couldn't set it up; photos will keep their backgrounds."
      REMOVE_BG=0
    fi
  fi
fi

# Order photos by file name (ignoring capitals and photo number), then by
# photo number, so "Jacket.jpg" comes before "Jacket #2.jpg" and is the cover.
sorted=()
while IFS= read -r -d '' line; do sorted+=("${line#*$'\t'*$'\t'}"); done < <(
  for f in "${photos[@]}"; do
    parse_details "$f"
    k=$(basename "$f"); k="${k%.*}"
    [[ "$k" =~ ^(.*[^[:space:]])[[:space:]]+(#|\()([0-9]+)\)?$ ]] && k="${BASH_REMATCH[1]}"
    printf '%s\t%05d\t%s\0' "$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')" "$PHOTO_NO" "$f"
  done | LC_ALL=C sort -z -t $'\t' -k1,1 -k2,2n
)
photos=("${sorted[@]}")

# Sheet text is all capitals, however the file name was typed.
caps() { printf '%s' "$1" | LC_ALL=en_US.UTF-8 tr '[:lower:]' '[:upper:]'; }

# Group photos into items: photos with the same section, maker and
# name (e.g. "... Jacket.jpg", "... Jacket #2.jpg") become one item.
item_keys=(); item_section=(); item_maker=(); item_name=(); item_imgs=()
find_item() {  # sets IDX to the item for the current photo, adding one if new
  local key i
  if [ -n "$MAKER$NAME" ]; then
    key=$(printf '%s|%s|%s' "$SECTION" "$MAKER" "$NAME" | tr '[:upper:]' '[:lower:]')
  else
    key="__single__$BASE"   # no details: each photo is its own item
  fi
  for ((i = 0; i < ${#item_keys[@]}; i++)); do
    [ "${item_keys[i]}" = "$key" ] && { IDX=$i; return; }
  done
  IDX=${#item_keys[@]}
  item_keys+=("$key"); item_section+=("$(caps "$SECTION")"); item_maker+=("$(caps "$MAKER")")
  item_name+=("$(caps "$NAME")"); item_imgs+=("")
}

added=()
thumbs=()
for src in "${photos[@]}"; do
  parse_details "$src"
  find_item
  out=$(pick_name)

  if [ "$DRY" -eq 1 ]; then
    added+=("$out")
    item_imgs[IDX]="${item_imgs[IDX]:+${item_imgs[IDX]}, }$out"
    echo "[dry run] $(basename "$src")  ->  $out"
    continue
  fi

  # Remove the background (skipped if already transparent), else just convert.
  cut=1
  sec=$(caps "$SECTION")
  if [ "$REMOVE_BG" -eq 1 ] && [ "$KEEP_BG" -eq 0 ] && [ "$sec" != "PAINTING" ]; then
    set +e; "$BG_TOOL" "$src" "$out" 2>/dev/null; bg=$?; set -e
    case "$bg" in
      0) cut=0 ;;
      3) ;;  # already transparent
      4) echo "  (couldn't find a subject in $(basename "$src"), kept its background)" ;;
    esac
  fi
  if [ "$cut" -ne 0 ] && ! sips -s format png "$src" --out "$out" >/dev/null 2>&1; then
    echo "Skipped $(basename "$src") (not an image that can be read)"
    rm -f "$out"
    continue
  fi

  # Shrink only if bigger than MAX_SIZE on its longest side.
  w=$(sips -g pixelWidth "$out" | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$out" | awk '/pixelHeight/{print $2}')
  if [ "$w" -gt "$MAX_SIZE" ] || [ "$h" -gt "$MAX_SIZE" ]; then
    sips -Z "$MAX_SIZE" "$out" >/dev/null
  fi

  # Small preview copy for the gallery on the website.
  mkdir -p images/thumbs
  thumb="images/thumbs/$(basename "$out")"
  sips -Z 600 "$out" --out "$thumb" >/dev/null 2>&1 && thumbs+=("$thumb")

  mv "$src" "$DONE/"
  added+=("$out")
  item_imgs[IDX]="${item_imgs[IDX]:+${item_imgs[IDX]}, }$out"
  echo "Added $(basename "$src")  ->  $out"
done

# One sheet row per item: id, section, img(s), maker, name, note, credit
rows=""
summary=""
for ((i = 0; i < ${#item_keys[@]}; i++)); do
  [ -n "${item_imgs[i]}" ] || continue
  last=$((last + 1))
  n=$(printf '%s' "${item_imgs[i]}" | awk -F', ' '{print NF}')
  rows+="$last"$'\t'"${item_section[i]}"$'\t'"${item_imgs[i]}"$'\t'"${item_maker[i]}"$'\t'"${item_name[i]}"$'\t\t\n'
  summary+="  $last | ${item_section[i]:--} | ${item_maker[i]:--} | ${item_name[i]:--}  ($n photo$([ "$n" -gt 1 ] && echo s || true))"$'\n'
done

if [ "$DRY" -eq 1 ]; then
  echo
  echo "[dry run] These sheet rows would be made:"
  printf '%s' "$summary"
  exit 0
fi
[ ${#added[@]} -eq 0 ] && { echo "Nothing added."; exit 1; }

echo "$last" > "$LAST_ID_FILE"

git add -- "${added[@]}" ${thumbs[@]+"${thumbs[@]}"}
if [ ${#added[@]} -eq 1 ]; then
  msg="Add inventory photo ${added[0]#images/}"
else
  msg="Add ${#added[@]} inventory photos"
fi
git commit -q -m "$msg" -- "${added[@]}" ${thumbs[@]+"${thumbs[@]}"}
echo "Committed: $msg"

printf '%s' "$rows" | pbcopy
printf '%s' "$rows" > "$DONE/sheet-rows-$(date +%Y%m%d-%H%M%S).tsv"
echo
echo "Sheet rows copied to your clipboard:"
printf '%s' "$summary"
echo
echo "Next: in the Google Sheet, click the first empty cell in the 'id'"
echo "column and paste (Cmd+V). Add any notes or credits after."

if [ "$PUSH" -eq 1 ]; then
  echo
  if git push -q; then
    echo "Pushed to GitHub. Live in a minute or two."
  else
    echo "Couldn't push to GitHub. The photos are saved and committed on"
    echo "this Mac; they'll go up next time a push works."
  fi
fi
