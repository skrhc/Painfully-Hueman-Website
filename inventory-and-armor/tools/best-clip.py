#!/usr/bin/env python3
"""Pick the liveliest stretch of a video for an ARMORY loop.

  python3 best-clip.py VIDEO [SECONDS]     -> prints the start time in seconds

Samples the video a few times a second and scores each moment by how much
the picture changes (movement, a step, a turn), ignoring near-black frames
(fades, title cards) and keeping hard cuts from counting more than real
motion. The SECONDS-long window (default 8) with the most going on wins.
The very start and end are skipped (intros, credits). Needs ffmpeg/ffprobe.
"""
import re, subprocess, sys


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


if __name__ == '__main__':
    print(liveliest(sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 8.0))
