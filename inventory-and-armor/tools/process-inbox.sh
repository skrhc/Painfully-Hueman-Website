#!/bin/bash
# ------------------------------------------------------------------
# Turns requests from the private ADD page (inventory-and-armor/add/)
# into ARMORY items. Run by the "ARMORY submissions" GitHub Action on a
# Mac runner; it can also be run by hand on a Mac.
#
# Each request is a folder inbox/<time>/ holding either:
#   entry.json ({section, maker, name, note, credit, keep_bg}) + photos
#     1.jpg, 2.png...  -> a new item, added to added.json with the next id
#   redo.json ({id, mode}) -> that item's photos made again from the
#     originals; mode: "cut" (remove background), "keep" (whole photo),
#     "painting" (crop to the canvas)
# Originals are kept in originals/ (same name as the finished photo).
# Finished photos: shrunk to 1600px, plus a 600px copy in images/thumbs/.
#
# Videos (1.mp4, 2.mov...) need ffmpeg. They become an animated cover, like a
# GIF, not a hosted video: the item's img list gets "images/<n>.png, videos/<n>.mp4":
#   images/<n>.png  a still frame (thumbnail, colors, and what shows until it moves)
#   videos/<n>.mp4  an 8-second silent loop, 720px wide (a GIF-like clip, about
#                   a tenth the size of an actual GIF)
# The original video is not kept.
# ------------------------------------------------------------------

set -euo pipefail
cd "$(dirname "$0")/.."

MAX_SIZE=1600
shopt -s nullglob
subs=(inbox/*/)
[ ${#subs[@]} -gt 0 ] || { echo "Inbox is empty."; exit 0; }

mkdir -p images/thumbs originals
TOOLS=$(mktemp -d)   # built tools live outside the repo
swiftc -O tools/remove-bg.swift -o "$TOOLS/remove-bg"
swiftc -O tools/crop-painting.swift -o "$TOOLS/crop-painting"

slug() {
  printf '%s' "$1" | perl -CS -MUnicode::Normalize -pe '$_ = NFD($_); s/\pM//g' \
    | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E \
    -e "s/'//g" -e $'s/\xe2\x80\x99//g' -e 's/[^a-z0-9]+/-/g' -e 's/^-+//' -e 's/-+$//'
}
field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")' "$1" "$2"; }

# make_photo SRC OUT MODE   (MODE: cut | keep | painting)
make_photo() {
  local src="$1" out="$2" mode="$3" fallback=1 tmp w h rc
  tmp="$TOOLS/work.png"; rm -f "$tmp"
  if [ "$mode" = "cut" ]; then
    set +e; "$TOOLS/remove-bg" "$src" "$tmp"; rc=$?; set -e
    if [ "$rc" -eq 0 ]; then fallback=0; fi
  elif [ "$mode" = "painting" ]; then
    set +e; "$TOOLS/crop-painting" "$src" "$tmp" 4 >/dev/null; rc=$?; set -e
    if [ "$rc" -eq 0 ]; then fallback=0; fi
  fi
  if [ "$fallback" -ne 0 ]; then
    sips -s format png "$src" --out "$tmp" >/dev/null || { echo "Can't read $src"; return 1; }
  fi
  w=$(sips -g pixelWidth "$tmp" | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$tmp" | awk '/pixelHeight/{print $2}')
  if [ "$w" -gt "$MAX_SIZE" ] || [ "$h" -gt "$MAX_SIZE" ]; then sips -Z "$MAX_SIZE" "$tmp" >/dev/null; fi
  mv "$tmp" "$out"
  sips -Z 600 "$out" --out "images/thumbs/$(basename "$out")" >/dev/null
  echo "$src -> $out ($mode)"
}

is_video() { case "$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')" in mp4|mov|m4v|webm|mkv) return 0 ;; esac; return 1; }

# make_video SRC STEM  -> images/STEM.png (still) + videos/STEM.mp4 (silent loop)
# The 8 seconds: SRC's .start file if there is one (a YouTube clip, already
# trimmed to its best part), otherwise the liveliest stretch (tools/best-clip.py).
# Black bars around the picture are cropped off.
make_video() {
  local src="$1" stem="$2" start still crop
  command -v ffmpeg >/dev/null || { echo "ffmpeg is missing; can't process $src"; return 1; }
  mkdir -p videos
  if [ -f "${src%.*}.start" ]; then start=$(cat "${src%.*}.start")
  else start=$(python3 tools/best-clip.py "$src" 8 2>/dev/null || echo 0); fi
  crop=$(ffmpeg -v info -ss "$start" -t 8 -i "$src" -an -vf "fps=2,cropdetect=limit=24:round=2:reset=0" -f null - 2>&1 \
    | grep -o 'crop=[0-9:]*' | tail -1)
  [ -n "$crop" ] && crop="$crop," || crop=""
  still="$TOOLS/still.png"; rm -f "$still"
  ffmpeg -v error -y -ss "$(python3 -c "print($start + 2)")" -i "$src" -vf "${crop%,}" -frames:v 1 "$still" 2>/dev/null ||
    ffmpeg -v error -y -i "$src" -frames:v 1 "$still"
  make_photo "$still" "images/$stem.png" keep || return 1
  ffmpeg -v error -y -ss "$start" -t 8 -i "$src" -an -vf "${crop}fps=24,scale='min(720,iw)':-2" \
    -c:v libx264 -preset slow -crf 27 -pix_fmt yuv420p -movflags +faststart "videos/$stem.mp4"
  echo "$src -> videos/$stem.mp4 (8s loop from ${start}s) + images/$stem.png"
}

# The mode a new photo gets from its section.
auto_mode() {
  if [ "$2" = "True" ] || [ "$1" = "BOOK" ]; then echo keep
  elif [ "$1" = "PAINTING" ]; then echo painting
  else echo cut; fi
}

sheet_max=""
for sub in "${subs[@]}"; do
  sub=${sub%/}

  # ---------- redo an item's photos ----------
  if [ -f "$sub/redo.json" ]; then
    id=$(field "$sub/redo.json" id); mode=$(field "$sub/redo.json" mode)
    case "$mode" in cut|keep|painting) ;; *) echo "Unknown mode '$mode' in $sub"; rm -rf "$sub"; continue ;; esac
    imgs=$(python3 -c 'import json,sys
for i in json.load(open("added.json")):
    if str(i["id"]) == sys.argv[1]: print("\n".join(p.strip() for p in i["img"].split(",") if p.strip()))' "$id")
    while IFS= read -r out; do
      [ -n "$out" ] || continue
      is_video "$out" && continue          # videos and their still frames stay as they are
      [ -e "videos/$(basename "${out%.*}").mp4" ] && continue
      base=$(basename "${out%.*}")
      orig=(originals/"$base".*)
      if [ ${#orig[@]} -gt 0 ]; then src="${orig[0]}"
      else src="$TOOLS/orig-$base.png"; cp "$out" "$src"; fi   # no original kept: start from the current photo
      make_photo "$src" "$out" "$mode" || true
    done <<< "$imgs"
    python3 - "$id" "$mode" <<'EOF'
import json, sys
items = json.load(open('added.json'))
for i in items:
    if str(i['id']) == sys.argv[1]:
        i['photos'] = sys.argv[2]
json.dump(items, open('added.json', 'w'), ensure_ascii=False, indent=1)
open('added.json', 'a').write('\n')
EOF
    rm -rf "$sub"
    continue
  fi

  # ---------- a new item ----------
  entry="$sub/entry.json"
  [ -f "$entry" ] || { echo "Nothing to do in $sub, skipped."; continue; }
  if [ -z "$sheet_max" ]; then
    SHEET_URL=$(grep -o "https://docs.google.com/spreadsheets/[^'\"]*" index.html | head -1)
    sheet_max=$(curl -fsL "$SHEET_URL&t=$(date +%s)" \
      | awk -F, '$1 ~ /^[0-9]+$/ && $1+0 > m { m = $1+0 } END { print m+0 }')
    [ "${sheet_max:-0}" -gt 0 ] || { echo "Couldn't read the Google Sheet."; exit 1; }
  fi
  # a video link (YouTube etc.): its best 8 seconds arrive as 0.<ext>, the cover.
  # YouTube refuses GitHub's servers, so on GitHub the clip is fetched by the
  # Mac helper (tools/mac-helper.sh), which adds 0.<ext> to this folder; until
  # then the submission waits here. Run by hand on a Mac, it's fetched now.
  if [ -f "$sub/failed.txt" ]; then           # the Mac helper gave up on the link
    cat "$sub/failed.txt"; rm -rf "$sub"; continue
  fi
  video_url=$(field "$entry" video_url)
  fetched=("$sub"/0.*)   # (nullglob: empty until the clip has been fetched)
  if [ -n "$video_url" ] && [ ${#fetched[@]} -eq 0 ]; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "Waiting for the Mac helper to fetch $video_url ($sub)."; continue
    fi
    if ! meta=$(python3 tools/fetch-clip.py "$video_url" "$sub"); then
      echo "Couldn't fetch $video_url; left in the inbox."; continue
    fi
    echo "Fetched $video_url: $meta"
  fi
  section=$(field "$entry" section | tr '[:lower:]' '[:upper:]')
  maker=$(field "$entry" maker); name=$(field "$entry" name)
  mode=$(auto_mode "$section" "$(field "$entry" keep_bg)")
  base=$(slug "$maker $name"); [ -n "$base" ] || base="item"

  imgs=()
  for f in $(ls "$sub" | grep -v -E '\.(json|start)$' | sort -n); do
    src="$sub/$f"
    out="images/$base.png"; k=2
    while [ -e "$out" ] || [ -e "videos/$(basename "${out%.*}").mp4" ]; do out="images/$base-$k.png"; k=$((k + 1)); done
    if is_video "$f"; then
      stem=$(basename "${out%.*}")
      make_video "$src" "$stem" || continue
      imgs+=("$out" "videos/$stem.mp4")
      continue
    fi
    make_photo "$src" "$out" "$mode" || continue
    cp "$src" "originals/$(basename "${out%.*}").${f##*.}"
    imgs+=("$out")
  done

  if [ ${#imgs[@]} -eq 0 ]; then echo "No usable photos in $sub, left in the inbox."; continue; fi

  python3 - "$entry" "$sheet_max" "$mode" "${imgs[@]}" <<'EOF'
import json, sys
entry, sheet_max, mode, imgs = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4:]
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
    'photos': mode,
})
json.dump(items, open('added.json', 'w'), ensure_ascii=False, indent=1)
open('added.json', 'a').write('\n')
print('Added item', next_id)
EOF
  rm -rf "$sub"
done
