#!/usr/bin/env python3
"""Measure the overall color of every ARMORY photo for the spread-out shuffle.

Writes inventory-and-armor/colors.json: { "images/name.png": [L, C, H], ... }
  L = lightness 0-100, C = colorfulness 0-100, H = hue 0-360 (degrees).
Only the visible (non-transparent) pixels of each thumbnail count, so a
cut-out photo is measured on the object, not its empty background.

Needs ImageMagick (`magick`). Takes a few seconds for the whole archive:
  python3 inventory-and-armor/tools/colors.py
"""
import colorsys, json, math, os, subprocess

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
OUT = os.path.join(ROOT, 'colors.json')
SIZE = 48


def measure(path):
    raw = subprocess.run(['magick', path, '-resize', f'{SIZE}x{SIZE}', '-depth', '8', 'rgba:-'],
                         capture_output=True, check=True).stdout
    n = 0
    r = g = b = hx = hy = colorful = 0.0
    for i in range(0, len(raw) - 3, 4):
        if raw[i + 3] < 128:
            continue
        pr, pg, pb = raw[i] / 255, raw[i + 1] / 255, raw[i + 2] / 255
        r += pr; g += pg; b += pb; n += 1
        h, l, s = colorsys.rgb_to_hls(pr, pg, pb)
        w = s * (1 - abs(2 * l - 1))          # how colorful this pixel looks
        hx += math.cos(h * 2 * math.pi) * w
        hy += math.sin(h * 2 * math.pi) * w
        colorful += w
    if not n:
        return None
    lightness = 100 * (0.2126 * r + 0.7152 * g + 0.0722 * b) / n
    hue = (math.degrees(math.atan2(hy, hx)) + 360) % 360 if colorful else 0
    return [round(lightness, 1), round(100 * colorful / n, 1), round(hue)]


def main():
    out = {}
    img_dir = os.path.join(ROOT, 'images')
    for name in sorted(os.listdir(img_dir)):
        if not name.lower().endswith(('.png', '.jpg', '.jpeg', '.webp')):
            continue
        thumb = os.path.join(img_dir, 'thumbs', name)
        src = thumb if os.path.exists(thumb) else os.path.join(img_dir, name)
        try:
            val = measure(src)
        except subprocess.CalledProcessError:
            val = None
        if val:
            out['images/' + name] = val
    with open(OUT, 'w') as f:
        json.dump(out, f, separators=(',', ':'))
        f.write('\n')
    print(f'colors.json: {len(out)} photos')


if __name__ == '__main__':
    main()
