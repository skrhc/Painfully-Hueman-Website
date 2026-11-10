#!/usr/bin/env python3
"""Download the best 8 seconds of a YouTube (or other) video for ARMORY.

  python3 fetch-clip.py URL OUT_DIR      -> OUT_DIR/0.<ext> (about 9 seconds)
                                            OUT_DIR/0.start (0: already trimmed)
                                            prints a JSON line: {title, uploader, start, how}

Where the 8 seconds come from:
  1. YouTube's "most replayed" graph, when the video has one (busier videos);
  2. otherwise the liveliest stretch (most movement), found by scanning a
     tiny low-quality copy with best-clip.py.
Only that stretch is downloaded at full size (720p at most, no sound).
Needs yt-dlp and ffmpeg.
"""
import glob, json, os, subprocess, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
best = import_module('best-clip')

WIN = 8.0
url, out_dir = sys.argv[1], sys.argv[2]
os.makedirs(out_dir, exist_ok=True)
YT = ['yt-dlp', '--no-playlist', '--quiet', '--no-warnings']

info = json.loads(subprocess.run(YT + ['-J', url], capture_output=True, text=True, check=True).stdout)
dur = float(info.get('duration') or 0)

heat = info.get('heatmap') or []
if heat and dur > WIN + 1:
    # each heatmap point covers a stretch of the video; weight by overlap
    pts = []
    for h in heat:
        t, e = float(h['start_time']), float(h['end_time'])
        while t < e:
            pts.append((t, float(h['value'])))
            t += 0.5
    start, how = best.best_window(pts, dur, WIN), 'most replayed'
else:
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(YT + ['-f', 'wv*[height>=144]/wv*/w', '-o', os.path.join(tmp, 'scan.%(ext)s'), url],
                       check=True)
        scan = glob.glob(os.path.join(tmp, 'scan.*'))[0]
        start, how = best.liveliest(scan, WIN), 'most movement'

end = min(start + WIN + 1, dur) if dur else start + WIN + 1
subprocess.run(YT + ['-f', 'bv*[height<=720]/b[height<=720]/bv*/b',
                     '--download-sections', f'*{start}-{end}', '--force-keyframes-at-cuts',
                     '-o', os.path.join(out_dir, '0.%(ext)s'), url], check=True)
open(os.path.join(out_dir, '0.start'), 'w').write('0\n')
print(json.dumps({'title': info.get('title'), 'uploader': info.get('uploader'), 'start': start, 'how': how}))
