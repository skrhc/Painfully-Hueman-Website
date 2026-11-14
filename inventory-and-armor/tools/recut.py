#!/usr/bin/env python3
"""Cut ARMORY video loops again from their YouTube links, with the current
picker (best-clip.py: composition, no title cards or big text, turned upright).

  python3 tools/recut.py LINKS.json [ids...]

LINKS.json: {"<item id>": ["videos/<stem>.mp4", "<youtube link>"], ...}
Replaces videos/<stem>.mp4, images/<stem>.png and images/thumbs/<stem>.png
in place (same names, so the items don't change). Run from inventory-and-armor/
on the studio Mac (needs yt-dlp, ffmpeg, swift, and claude signed in).
"""
import glob, json, os, shutil, subprocess, sys, tempfile
sys.dont_write_bytecode = True

here = os.path.dirname(os.path.abspath(__file__))
os.chdir(os.path.dirname(here))
sys.path.insert(0, here)
from importlib import import_module
best = import_module('best-clip')

links = json.load(open(sys.argv[1]))
only = set(sys.argv[2:])


def run(*a):
    return subprocess.run(list(a), capture_output=True, text=True)


for iid, (video, url) in links.items():
    if only and iid not in only:
        continue
    if not url or not os.path.exists(video):
        print(iid, 'skipped (no link or no video)', flush=True); continue
    stem = os.path.splitext(os.path.basename(video))[0]
    tmp = tempfile.mkdtemp()
    try:
        r = run(sys.executable, os.path.join(here, 'fetch-clip.py'), url, tmp)
        clip = (glob.glob(os.path.join(tmp, '0.*')) or [None])[0]
        if r.returncode or not clip or clip.endswith('.start'):
            clip = next((c for c in glob.glob(os.path.join(tmp, '0.*')) if not c.endswith('.start')), None)
        if r.returncode or not clip:
            print(iid, 'fetch failed:', (r.stderr or '').strip()[-200:], flush=True); continue
        info = json.loads(r.stdout.strip().splitlines()[-1])
        # black bars off, then upright, as process-inbox.sh does
        out = run('ffmpeg', '-v', 'info', '-t', '8', '-i', clip, '-an', '-vf',
                  'fps=2,cropdetect=limit=24:round=2:reset=0', '-f', 'null', '-').stderr
        crops = [w for w in out.split() if w.startswith('crop=')]
        vf = [crops[-1]] if crops else []
        turn = best.turn_filter(clip, 0.0)
        if turn: vf.append(turn)
        still = os.path.join(tmp, 'still.png')
        run('ffmpeg', '-v', 'error', '-y', '-ss', '2', '-i', clip, *(['-vf', ','.join(vf)] if vf else []),
            '-frames:v', '1', still)
        if not os.path.exists(still):
            print(iid, 'no still', flush=True); continue
        newv = os.path.join(tmp, 'loop.mp4')
        r = run('ffmpeg', '-v', 'error', '-y', '-t', '8', '-i', clip, '-an', '-vf',
                ','.join(vf + ['fps=24', "scale='min(720,iw)':-2"]), '-c:v', 'libx264', '-preset', 'slow',
                '-crf', '27', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', newv)
        if r.returncode or not os.path.exists(newv):
            print(iid, 'encode failed:', r.stderr[-200:], flush=True); continue
        shutil.move(newv, video)
        if max(int(x) for x in run('sips', '-g', 'pixelWidth', '-g', 'pixelHeight', still).stdout.split()[-3::2]) > 1600:
            run('sips', '-Z', '1600', still)
        shutil.move(still, f'images/{stem}.png')
        run('sips', '-Z', '600', f'images/{stem}.png', '--out', f'images/thumbs/{stem}.png')
        print(iid, f"ok: from {info.get('start')}s{' turned ' + turn if turn else ''}", flush=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
