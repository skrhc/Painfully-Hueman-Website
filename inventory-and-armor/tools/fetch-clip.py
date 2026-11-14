#!/usr/bin/env python3
"""Download the best 8 seconds of a YouTube (or other) video for ARMORY.

  python3 fetch-clip.py URL OUT_DIR      -> OUT_DIR/0.<ext> (about 9 seconds)
                                            OUT_DIR/0.start (0: already trimmed)
                                            prints a JSON line: {title, uploader, start, how}

Where the 8 seconds come from: the best-composed shot (best-clip.py looks at
one still per shot of a small low-quality copy and picks the best-framed one).
Only that stretch is downloaded at full size (720p at most, no sound).
Needs yt-dlp and ffmpeg.
"""
import glob, json, os, subprocess, sys, tempfile
sys.dont_write_bytecode = True   # keep __pycache__ out of the repo

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
best = import_module('best-clip')

WIN = 8.0
url, out_dir = sys.argv[1], sys.argv[2]
os.makedirs(out_dir, exist_ok=True)
YT = ['yt-dlp', '--no-playlist', '--quiet', '--no-warnings']

r = subprocess.run(YT + ['-J', url], capture_output=True, text=True)
if r.returncode:
    sys.stderr.write((r.stderr or 'yt-dlp failed').strip()[-600:] + '\n')
    sys.exit(1)
info = json.loads(r.stdout)
dur = float(info.get('duration') or 0)

# the best-composed shot, judged from a small low-quality copy (best-clip.py)
with tempfile.TemporaryDirectory() as tmp:
    subprocess.run(YT + ['-f', 'wv*[height>=240][height<=360]/wv*[height>=144]/wv*/w',
                         '-o', os.path.join(tmp, 'scan.%(ext)s'), url], check=True)
    scan = glob.glob(os.path.join(tmp, 'scan.*'))[0]
    start, how = best.composed(scan, WIN), 'composition'

end = min(start + WIN + 1, dur) if dur else start + WIN + 1
subprocess.run(YT + ['-f', 'bv*[height<=720]/b[height<=720]/bv*/b',
                     '--download-sections', f'*{start}-{end}', '--force-keyframes-at-cuts',
                     '-o', os.path.join(out_dir, '0.%(ext)s'), url], check=True)
open(os.path.join(out_dir, '0.start'), 'w').write('0\n')

# an ARMORY submission: fill in a missing maker / name from the channel / title
entry = os.path.join(out_dir, 'entry.json')
if os.path.exists(entry):
    e = json.load(open(entry))
    if not (e.get('maker') or '').strip(): e['maker'] = info.get('uploader') or ''
    if not (e.get('name') or '').strip(): e['name'] = info.get('title') or ''
    if not (e.get('section') or '').strip():   # from YouTube's own category
        cats = ' '.join(info.get('categories') or []).lower()
        e['section'] = ('music video' if 'music' in cats else 'film' if 'film' in cats else
                        'video game' if 'gaming' in cats else 'education' if 'education' in cats else 'video')
    json.dump(e, open(entry, 'w'), ensure_ascii=False)

print(json.dumps({'title': info.get('title'), 'uploader': info.get('uploader'), 'start': start, 'how': how}))
