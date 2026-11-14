#!/usr/bin/env python3
"""Pick the stretch of a video for an ARMORY loop.

  python3 best-clip.py VIDEO [SECONDS]     -> prints the start time in seconds

composed() (the default): splits the video into shots, lines up to 12
candidate loops (one per shot), and makes a contact sheet with a row per loop
(its beginning, middle and end). Claude (small model) picks the row with the
best composition throughout: clear subject, strong framing, good light, no
titles, subtitles or logos. Without Claude (e.g. on GitHub) it
takes the longest steady, well-lit, colourful shot.

liveliest() (the old way, kept below):
Samples the video a few times a second and scores each moment by how much
the picture changes (movement, a step, a turn), ignoring near-black frames
(fades, title cards) and keeping hard cuts from counting more than real
motion. The SECONDS-long window (default 8) with the most going on wins.
The very start and end are skipped (intros, credits). Needs ffmpeg/ffprobe.
"""
import glob, json, os, re, shutil, subprocess, sys, tempfile


def duration(path):
    try:
        return float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                                     '-of', 'csv=p=0', path], capture_output=True, text=True).stdout.strip())
    except ValueError:
        return 0.0


def best_window(points, dur, win):
    """points: [(time, value)]. Start of the win-second window with the most value,
    skipping the first 4% and last 6% of the video."""
    lo, hi = dur * 0.04, dur - dur * 0.06 - win
    if hi <= lo:
        lo, hi = 0.0, max(0.0, dur - win)
    best, best_start, start = -1.0, lo, lo
    while start <= hi:
        s = sum(v for t, v in points if start <= t < start + win)
        if s > best:
            best, best_start = s, start
        start += 0.5
    return round(best_start, 2)


def liveliest(path, win=8.0):
    dur = duration(path)
    if dur <= win + 1:
        return 0.0
    fps = 4 if dur <= 900 else (2 if dur <= 3600 else 1)   # long videos: fewer samples
    vf = f"fps={fps},scale=160:-2,select='gte(scene\\,0)',signalstats,metadata=print:file=-"
    out = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-an', '-vf', vf, '-f', 'null', '-'],
                         capture_output=True, text=True).stdout
    frames, t, sc, y = [], None, 0.0, 128.0
    for line in out.splitlines():
        m = re.search(r'pts_time:([\d.]+)', line)
        if m:
            if t is not None:
                frames.append((t, sc, y))
            t, sc, y = float(m.group(1)), 0.0, 128.0
        elif 'lavfi.scene_score=' in line:
            sc = float(line.split('=')[1])
        elif 'lavfi.signalstats.YAVG=' in line:
            y = float(line.split('=')[1])
    if t is not None:
        frames.append((t, sc, y))
    if not frames:
        return round(min(5, dur / 10), 2)
    # picture change, capped so one hard cut doesn't outweigh steady
    # movement; dark frames (fades, black title cards) count for nothing
    live = [(ft, 0.0 if fy < 24 else min(fs, 0.2)) for ft, fs, fy in frames]
    return best_window(live, dur, win)


def sample(path, dur):
    """[(time, scene change, brightness, colour)] a few times a second."""
    fps = 4 if dur <= 900 else (2 if dur <= 3600 else 1)   # long videos: fewer samples
    vf = f"fps={fps},scale=160:-2,select='gte(scene\\,0)',signalstats,metadata=print:file=-"
    out = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-an', '-vf', vf, '-f', 'null', '-'],
                         capture_output=True, text=True).stdout
    frames, cur = [], None
    for line in out.splitlines():
        m = re.search(r'pts_time:([\d.]+)', line)
        if m:
            if cur: frames.append(tuple(cur))
            cur = [float(m.group(1)), 0.0, 128.0, 0.0]
        elif cur and 'lavfi.scene_score=' in line:
            cur[1] = float(line.split('=')[1])
        elif cur and 'lavfi.signalstats.YAVG=' in line:
            cur[2] = float(line.split('=')[1])
        elif cur and 'lavfi.signalstats.SATAVG=' in line:
            cur[3] = float(line.split('=')[1])
    if cur: frames.append(tuple(cur))
    return frames


def shots(frames, dur):
    """Split at hard cuts: [(start, end, mean brightness, mean colour, steadiness)]."""
    out, start, buf = [], 0.0, []
    for t, sc, y, sat in frames:
        if sc > 0.3 and buf:
            out.append((start, t, buf)); start, buf = t, []
        buf.append((sc, y, sat))
    if buf: out.append((start, dur, buf))
    return [(a, b, sum(x[1] for x in f) / len(f), sum(x[2] for x in f) / len(f),
             1 - min(1, sum(x[0] for x in f) / len(f) * 5)) for a, b, f in out]


def ask_claude(sheet, rows, timeout=240):
    claude = shutil.which('claude') or os.path.expanduser('~/.local/bin/claude')
    if not os.path.exists(claude) or os.environ.get('ARMORY_NO_CLAUDE'):
        return None
    prompt = f"""Read the image file {sheet}. It is a contact sheet with {rows} rows (row 1 is the top).
Each row is one possible 8-second clip from a video: its beginning, middle and end, left to right.
The chosen clip becomes a silent looping preview in ARMORY, a visual archive of fashion, art, design, film and
performance, shown as a small tile in a grid.
Pick the row whose clip has the strongest composition all the way through: a clear subject, deliberate framing
(symmetry, thirds, strong lines or shapes), good light and colour, in focus, reads well small. Reject any row
with a title card, credits, subtitles, captions, a logo or watermark, a game menu or HUD, black or blurry frames,
a talking-head interview or an unfocused crowd in any of its three frames.
Reply with ONLY JSON: {{"row": n, "why": "a few words"}}"""
    try:
        r = subprocess.run([claude, '-p', prompt, '--output-format', 'json', '--model', 'haiku',
                            '--allowedTools', 'Read'], capture_output=True, text=True, timeout=timeout,
                           cwd=os.path.dirname(sheet))
        out = json.loads(r.stdout or '{}')
        m = re.search(r'\{.*\}', out.get('result') or '', re.S)
        if r.returncode or out.get('is_error') or not m:
            return None
        pick = json.loads(m.group(0))
        return int(pick['row']) - 1, pick.get('why', '')
    except Exception:
        return None


def composed(path, win=8.0, verbose=False):
    """Start of the best-composed win-second stretch (see the top of this file)."""
    dur = duration(path)
    if dur <= win + 1:
        return 0.0
    lo, hi = dur * 0.04, dur - dur * 0.06          # skip intros and credits
    sh = [s for s in shots(sample(path, dur), dur) if s[1] > lo and s[0] < hi and s[2] >= 30]
    if not sh:
        return liveliest(path, win)
    # candidates: prefer shots long enough to hold the loop, spread over the video
    long_ = [s for s in sh if s[1] - s[0] >= win * 0.75]
    if len(long_) < 12:   # fast cutting (trailers, montages): take the longest shots of 2s+ too
        more = sorted((s for s in sh if 2 <= s[1] - s[0] < win * 0.75), key=lambda s: s[0] - s[1])
        long_ = sorted(long_ + more[:30 - len(long_)]) or sorted(sh, key=lambda s: s[0] - s[1])[:30]
    if len(long_) > 30:
        step = len(long_) / 30
        long_ = [long_[int(i * step)] for i in range(30)]

    def start_in(s):
        a, b = max(s[0], lo), min(s[1], hi)
        if b - a < win:    # a short shot: start on it, so the loop opens with what was picked
            return round(a + 0.1, 2)
        return round(a + (b - a - win) / 2, 2)   # centred in the shot

    def fallback():
        best = max(long_, key=lambda s: min(s[1] - s[0], 3 * win) / (3 * win) + s[4] + s[3] / 120
                   - (0.5 if s[2] < 45 or s[2] > 220 else 0))
        return start_in(best)

    # each candidate loop is one row of the contact sheet: its beginning, middle and end
    if len(long_) > 12:
        step = len(long_) / 12
        long_ = [long_[int(i * step)] for i in range(12)]
    starts = [min(start_in(s), max(0.0, dur - win)) for s in long_]
    tmp = tempfile.mkdtemp()
    try:
        n = 0
        for st in starts:
            for off in (0.6, win / 2, win - 0.6):
                subprocess.run(['ffmpeg', '-v', 'error', '-ss', f'{st + off:.2f}', '-i', path, '-frames:v', '1',
                                '-vf', 'scale=256:144:force_original_aspect_ratio=decrease,pad=256:144:-1:-1:color=white',
                                '-y', os.path.join(tmp, f'f{n:03d}.jpg')], capture_output=True)
                n += 1
        got = sorted(glob.glob(os.path.join(tmp, 'f*.jpg')))
        if len(got) != n:
            return fallback()
        sheet = os.path.join(tmp, 'sheet.jpg')
        subprocess.run(['ffmpeg', '-v', 'error', '-framerate', '1', '-i', os.path.join(tmp, 'f%03d.jpg'),
                        '-vf', f'tile=3x{len(starts)}:padding=6:margin=12:color=white', '-frames:v', '1', '-y', sheet],
                       capture_output=True)
        pick = ask_claude(sheet, len(starts)) if os.path.exists(sheet) else None
        if verbose:
            shutil.copy(sheet, os.path.splitext(path)[0] + '-sheet.jpg')
            sys.stderr.write(f'{len(starts)} candidates; claude: {pick}\n')
        if not pick or not 0 <= pick[0] < len(starts):
            return fallback()
        return starts[pick[0]]
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    print(composed(sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 8.0, '-v' in sys.argv))
