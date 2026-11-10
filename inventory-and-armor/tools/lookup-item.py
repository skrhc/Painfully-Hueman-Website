#!/usr/bin/env python3
"""Look up what an ARMORY submission is from its photo, and fill in the blanks.

  python3 lookup-item.py INBOX_DIR     (INBOX_DIR holds entry.json + 1.jpg, 2.png...)

Claude Code (the `claude` command, signed in with your Claude plan) looks at the
first photo, searches the web to confirm what it is, and fills in whatever was
left empty in entry.json: section, maker, name, note, credit. Anything you
typed on the ADD page is kept. The answer is marked in entry.json as
"looked_up" ({sure, source}) so the item can be checked later.
If it can't tell what the item is, maker and name become UNKNOWN.
Needs: claude, and ffmpeg when the only file is a video.
"""
import glob, json, os, re, shutil, subprocess, sys, tempfile
sys.dont_write_bytecode = True

SECTIONS = ('FOOTWEAR TOP BOTTOMS OUTERWEAR HEADWEAR HOOD EYEWEAR JEWELRY BAG PAINTING SCULPTURE PHOTO '
            'BOOK OBJECT FURNITURE LIGHTING HARDWARE FILM PERFORMANCE')
FIELDS = ('section', 'maker', 'name', 'note', 'credit')

sub = sys.argv[1]
entry_path = os.path.join(sub, 'entry.json')
entry = json.load(open(entry_path))
claude = shutil.which('claude') or os.path.expanduser('~/.local/bin/claude')

files = sorted((f for f in glob.glob(os.path.join(sub, '*')) if not re.search(r'\.(json|start|txt)$', f)),
               key=lambda f: os.path.basename(f))
tmp = tempfile.mkdtemp()
photo = None
for f in files:
    if not re.search(r'\.(mp4|mov|m4v|webm|mkv)$', f, re.I):
        photo = f; break
if not photo and files:   # only a video: look at a frame from it
    photo = os.path.join(tmp, 'frame.jpg')
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', '3', '-i', files[0], '-frames:v', '1', photo])
if photo and not re.search(r'\.(jpe?g|png|gif|webp)$', photo, re.I):   # HEIC etc: make a JPEG it can read
    jpg = os.path.join(tmp, 'photo.jpg')
    subprocess.run(['sips', '-s', 'format', 'jpeg', photo, '--out', jpg], capture_output=True)
    photo = jpg
if not photo or not os.path.exists(photo):
    sys.exit('No photo to look at.')
# work on a copy outside the repo, so nothing else in the folder is touched
shutil.copy(photo, os.path.join(tmp, 'photo' + os.path.splitext(photo)[1].lower()))
photo = os.path.join(tmp, 'photo' + os.path.splitext(photo)[1].lower())

given = {k: (entry.get(k) or '').strip() for k in FIELDS}
prompt = f"""You are cataloguing an item for ARMORY, a visual archive of clothing, art, design and objects.
Read the image file {photo} and work out exactly what it is. Use web search to confirm it
(the maker's site, a museum or gallery page, a retailer, a press article). Don't guess wildly:
if you can't identify it with reasonable confidence, say so.

What the person already typed (keep these; empty means unknown): {json.dumps(given, ensure_ascii=False)}

Reply with ONLY one JSON object, no other text:
{{"section": one of [{SECTIONS}],
 "maker": the designer, brand, artist or company (as they write it),
 "name": the item or work's title; for artworks add the year, like "CLAVO, 1978"; for fashion include the season or model if known,
 "note": one or two plain factual sentences (medium, size, year, collection), or "",
 "credit": the credit line as the source publishes it (museum/collection and accession number, gallery and photographer, or the brand), or "",
 "source": the URL that confirms it, or "",
 "sure": true if a source confirms it, false if it's your best guess}}
If you can't tell what it is, use "" for maker and name and false for sure."""

try:
    r = subprocess.run([claude, '-p', prompt, '--output-format', 'json',
                        '--allowedTools', 'Read', 'WebSearch', 'WebFetch'],
                       capture_output=True, text=True, timeout=420, cwd=tmp)
    out = json.loads(r.stdout or '{}')
    text = out.get('result') or ''
    if r.returncode or out.get('is_error'):
        raise RuntimeError((text or r.stderr or 'claude failed').strip()[-400:])
    m = re.search(r'\{.*\}', text, re.S)
    found = json.loads(m.group(0)) if m else {}
except Exception as err:   # still add the item; it just stays unknown
    sys.stderr.write(f'lookup failed: {err}\n')
    found = {'sure': False, 'error': str(err)[-300:]}
finally:
    shutil.rmtree(tmp, ignore_errors=True)

for k in FIELDS:
    if not given[k] and isinstance(found.get(k), str) and found[k].strip():
        entry[k] = found[k].strip()
for k in ('maker', 'name'):
    if not (entry.get(k) or '').strip():
        entry[k] = 'UNKNOWN'
if not (entry.get('section') or '').strip():
    entry['section'] = 'OBJECT'
entry['looked_up'] = {'sure': bool(found.get('sure')), 'source': found.get('source') or ''}
if found.get('error'): entry['looked_up']['error'] = found['error']
json.dump(entry, open(entry_path, 'w'), ensure_ascii=False, indent=1)
print(json.dumps({k: entry.get(k) for k in FIELDS + ('looked_up',)}, ensure_ascii=False))
