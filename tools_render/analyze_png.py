#!/usr/bin/env python3
"""Pixel statistics for render verification.

Usage:
    python3 analyze_png.py frame.png              # single frame: black-vs-rendering
    python3 analyze_png.py a.png b.png            # two frames: adds a motion check

Why this exists: "it looks fine" is not evidence. A black screen, a frozen
image and a bright error dialog all look plausible in a thumbnail, so the gate
is numeric:

  dark_fraction   < 0.95          -> not a black screen
  color_buckets   > 12            -> real content, not a flat fill
  diff_ratio      > 0.001         -> animating, not a frozen first frame

Requires: Pillow.  python3 -m pip install pillow
"""

import sys

from PIL import Image, ImageChops


def rgb_pixels(im):
    """Flat (r,g,b) tuple list. Avoids Image.getdata(), deprecated in Pillow 10+."""
    raw = im.tobytes()
    return [tuple(raw[i:i + 3]) for i in range(0, len(raw), 3)]


def stats(path):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    small = im.copy()
    small.thumbnail((400, 400))
    px = rgb_pixels(small)
    n = len(px)
    dark = sum(1 for r, g, b in px if r + g + b < 24)
    lum = [0.299 * r + 0.587 * g + 0.114 * b for r, g, b in px]
    mean = sum(lum) / n
    sd = (sum((x - mean) ** 2 for x in lum) / n) ** 0.5
    buckets = len({(r >> 3, g >> 3, b >> 3) for r, g, b in px})
    dark_frac = dark / n
    verdict = "BLACK" if dark_frac > 0.95 else ("RENDERING" if buckets > 12 else "FLAT")
    print(f"  {path}")
    print(f"    size={w}x{h} dark_fraction={dark_frac:.3f} "
          f"mean_luminance={mean:.1f} stddev={sd:.1f} color_buckets={buckets} "
          f"verdict={verdict}")
    return verdict


def motion(a, b):
    ia = Image.open(a).convert("RGB")
    ib = Image.open(b).convert("RGB")
    if ia.size != ib.size:
        ib = ib.resize(ia.size)
    diff = ImageChops.difference(ia, ib).convert("L")
    changed = sum(1 for p in diff.tobytes() if p > 8)
    ratio = changed / (ia.size[0] * ia.size[1])
    print(f"    motion: {ratio:.4f} of pixels changed between frames -> "
          f"{'ANIMATING' if ratio > 0.001 else 'STATIC'}")
    return ratio


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    verdicts = [stats(p) for p in argv[1:]]
    ok = all(v == "RENDERING" for v in verdicts)
    if len(argv) == 3:
        ok = ok and motion(argv[1], argv[2]) > 0.001
    print(f"  RESULT: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
