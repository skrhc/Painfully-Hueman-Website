#!/bin/bash
# ------------------------------------------------------------------
# Turns submissions from the private ADD page (inventory-and-armor/add/)
# into ARMORY items. Run by the "ARMORY submissions" GitHub Action on a
# Mac runner; it can also be run by hand on a Mac.
#
# Each submission is a folder inbox/<time>/ holding entry.json
# ({section, maker, name, note, credit, keep_bg}) and photos 1.jpg, 2.jpg...
# For each one: background removed (paintings cropped to the canvas, books
# kept whole), shrunk to 1600px, a 600px thumb made, the item added to
# added.json with the next free id, and the inbox folder deleted.
# ------------------------------------------------------------------

set -euo pipefail
cd "$(dirname "$0")/.."

MAX_SIZE=1600
shopt -s nullglob
subs=(inbox/*/)
[ ${#subs[@]} -gt 0 ] || { echo "Inbox is empty."; exit 0; }

mkdir -p images/thumbs
TOOLS=$(mktemp -d)   # built tools live outside the repo
swiftc -O tools/remove-bg.swift -o "$TOOLS/remove-bg"
swiftc -O tools/crop-painting.swift -o "$TOOLS/crop-painting"

# Highest id so far: the Google Sheet and added.json.
SHEET_URL=$(grep -o "https://docs.google.com/spreadsheets/[^'\"]*" index.html | head -1)
sheet_max=$(curl -fsL "$SHEET_URL&t=$(date +%s)" \
  | awk -F, '$1 ~ /^[0-9]+$/ && $1+0 > m { m = $1+0 } END { print m+0 }')
[ "${sheet_max:-0}" -gt 0 ] || { echo "Couldn't read the Google Sheet."; exit 1; }

slug() {
  printf '%s' "$1" | perl -CS -MUnicode::Normalize -pe '$_ = NFD($_); s/\pM//g' \
    | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E \
    -e "s/'//g" -e $'s/\xe2\x80\x99//g' -e 's/[^a-z0-9]+/-/g' -e 's/^-+//' -e 's/-+$//'
}
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")' "$1" "$2"; }

for sub in "${subs[@]}"; do
  sub=${sub%/}
  entry="$sub/entry.json"
  [ -f "$entry" ] || { echo "No entry.json in $sub, skipped."; continue; }
  section=$(field "$entry" section | tr '[:lower:]' '[:upper:]')
  maker=$(field "$entry" maker); name=$(field "$entry" name)
  keep_bg=$(field "$entry" keep_bg)
  base=$(slug "$maker $name"); [ -n "$base" ] || base="item"

  imgs=()
  for src in $(ls "$sub" | grep -v '^entry.json$' | sort -n); do
    src="$sub/$src"
    out="images/$base.png"; k=2
    while [ -e "$out" ]; do out="images/$base-$k.png"; k=$((k + 1)); done

    cut=1
    if [ "$keep_bg" != "True" ] && [ "$section" != "PAINTING" ] && [ "$section" != "BOOK" ]; then
      set +e; "$TOOLS/remove-bg" "$src" "$out"; bg=$?; set -e
      if [ "$bg" -eq 0 ]; then cut=0; fi
    fi
    if [ "$section" = "PAINTING" ] && [ "$keep_bg" != "True" ]; then
      set +e; "$TOOLS/crop-painting" "$src" "$out" 4 >/dev/null; pc=$?; set -e
      if [ "$pc" -eq 0 ]; then cut=0; fi
    fi
    if [ "$cut" -ne 0 ]; then
      sips -s format png "$src" --out "$out" >/dev/null || { echo "Can't read $src"; continue; }
    fi
    w=$(sips -g pixelWidth "$out" | awk '/pixelWidth/{print $2}')
    h=$(sips -g pixelHeight "$out" | awk '/pixelHeight/{print $2}')
    if [ "$w" -gt "$MAX_SIZE" ] || [ "$h" -gt "$MAX_SIZE" ]; then sips -Z "$MAX_SIZE" "$out" >/dev/null; fi
    sips -Z 600 "$out" --out "images/thumbs/$(basename "$out")" >/dev/null
    imgs+=("$out")
    echo "$src -> $out"
  done

  if [ ${#imgs[@]} -eq 0 ]; then echo "No usable photos in $sub, left in the inbox."; continue; fi

  python3 - "$entry" "$sheet_max" "${imgs[@]}" <<'EOF'
import json, sys
entry, sheet_max, imgs = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
e = json.load(open(entry))
try:
    items = json.load(open('added.json'))
except FileNotFoundError:
    items = []
next_id = max([sheet_max] + [int(i['id']) for i in items if str(i.get('id', '')).isdigit()]) + 1
items.append({
    'id': str(next_id),
    'section': (e.get('section') or '').strip().upper(),
    'img': ', '.join(imgs),
    'maker': (e.get('maker') or '').strip().upper(),
    'name': (e.get('name') or '').strip().upper(),
    'note': (e.get('note') or '').strip(),
    'credit': (e.get('credit') or '').strip(),
})
json.dump(items, open('added.json', 'w'), ensure_ascii=False, indent=1)
open('added.json', 'a').write('\n')
print('Added item', next_id)
EOF
  rm -rf "$sub"
done
