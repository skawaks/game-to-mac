#!/usr/bin/env python3
"""
make_icns.py - build a native-looking macOS .icns app icon from a square PNG.

Written for the game-to-mac skill: ports usually ship with no CFBundleIconFile target
at all (Finder/Dock shows the blank default icon), and the pretty AI-generated PNG you
can make in one shot is the wrong shape for macOS (flat white corners, square-ish
curvature, full-bleed). This tool fixes all three, deterministically, no extra credits.

Pipeline
  1. --erase x0,y0,x1,y1   remove blemishes / "AI generated" watermarks by smoothly
                           extrapolating the surrounding artwork (2-edge Coons blend).
                           Repeatable. Safe on smooth gradients, which is what the
                           corners of an icon almost always are.
  2. background removal    flood-fill the flat white/plain background connected to the
                           four canvas corners, then harmonically extend the artwork
                           into it (Jacobi diffusion). Result: transparent corners with
                           NO white fringe / light halo, because the RGB under the new
                           alpha edge is real artwork colour, not white.
                           Unlike a naive "min>threshold -> alpha 0" this never punches
                           holes in white *interior* art (highlights, white stars, ...).
  3. native curvature      masks the artwork with the Apple squircle-ish radius
                           (0.225 x content) so the icon sits correctly next to native
                           apps instead of looking like a squarish tile.
  4. Big Sur icon grid     content 824x824 centred on a 1024x1024 transparent canvas.
  5. .icns                 renders the 10 required .iconset bitmaps and runs iconutil.

Usage
  python3 make_icns.py --input icon.png --output Icon.icns
  python3 make_icns.py --input icon.png --output Icon.icns --erase 860,926,1024,1024
  python3 make_icns.py --input icon.png --check                 # diagnostics only
  python3 make_icns.py --input icon.png --output Icon.icns --flat   # keep white bg

Then, in the .app:
  cp Icon.icns "<App>.app/Contents/Resources/Icon.icns"
  # Info.plist must contain: <key>CFBundleIconFile</key><string>Icon</string>
  touch "<App>.app" && killall Dock        # refresh the cached icon

Requires: Pillow, numpy (pip install pillow numpy).
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw

CANVAS = 1024          # master canvas (Apple icon grid)
CONTENT = 824          # Big Sur+ app icons: artwork occupies 824 of 1024, centred
RADIUS_RATIO = 0.2250  # corner radius / content  (~185.4 / 824, Apple's template)
ICONSET = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]


# ---------------------------------------------------------------- helpers

def srgb_alpha_rounded_rect(size: int, radius: float, ss: int = 4) -> np.ndarray:
    """Anti-aliased rounded-rect alpha mask in [0,1], supersampled `ss` times."""
    img = Image.new("L", (size * ss, size * ss), 0)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, size * ss - 1, size * ss - 1],
                        radius=radius * ss, fill=255)
    img = img.resize((size, size), Image.LANCZOS)
    return np.asarray(img).astype(np.float32) / 255.0


def carry_clean(edge: np.ndarray, bg_max: float) -> np.ndarray:
    """Replace background-coloured samples in a 1-D edge strip with the last valid
    artwork sample, so the blend below never pulls white into the artwork."""
    out = edge.copy()
    last = None
    for i in range(len(out)):
        if out[i].min() <= bg_max:
            last = out[i].copy()
        elif last is not None:
            out[i] = last
    # backfill a leading run of background samples from the first valid colour
    last = None
    for i in range(len(out) - 1, -1, -1):
        if out[i].min() <= bg_max:
            last = out[i].copy()
        elif last is not None:
            out[i] = last
    return out


def erase_rect(a: np.ndarray, x0: int, y0: int, x1: int, y1: int, bg_max: float) -> None:
    """2-edge Coons blend: fill [x0,y0,x1,y1) from the clean strips just above and
    just left of the rectangle. In-place."""
    h, w, _ = a.shape
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(w, x1), min(h, y1)
    if x1 - x0 < 2 or y1 - y0 < 2:
        return
    top = carry_clean(a[y0 - 1, x0:x1], bg_max)          # row above the hole
    left = carry_clean(a[y0:y1, x0 - 1], bg_max)         # column left of it
    ty = (np.arange(y1 - y0, dtype=np.float32) + 1.0) / float(y1 - y0)
    ty = ty[:, None, None]
    patch = (1.0 - ty) * top[None, :, :] + ty * left[:, None, :]
    a[y0:y1, x0:x1] = patch


def flood_background(mn: np.ndarray, threshold: float) -> np.ndarray:
    """Mask of the flat background connected to the four canvas corners."""
    h, w = mn.shape
    seed = mn > threshold
    out = np.zeros((h, w), dtype=bool)
    stack = [(0, 0), (0, w - 1), (h - 1, 0), (h - 1, w - 1)]
    while stack:
        y, x = stack.pop()
        if out[y, x] or not seed[y, x]:
            continue
        out[y, x] = True
        if x > 0 and seed[y, x - 1] and not out[y, x - 1]:
            stack.append((y, x - 1))
        if x < w - 1 and seed[y, x + 1] and not out[y, x + 1]:
            stack.append((y, x + 1))
        if y > 0 and seed[y - 1, x] and not out[y - 1, x]:
            stack.append((y - 1, x))
        if y < h - 1 and seed[y + 1, x] and not out[y + 1, x]:
            stack.append((y + 1, x))
    return out


def harmonic_fill(a: np.ndarray, mask: np.ndarray, iters: int = 260,
                  report=None) -> None:
    """Extend artwork colour into `mask` (in-place) by solving Laplace's equation
    (Jacobi). The canvas border stays unconstrained, so the fill is a smooth
    continuation of the artwork with no white sink at the edges."""
    if not mask.any():
        return
    ys, xs = np.nonzero(mask)
    y0, y1 = max(0, ys.min() - 2), min(a.shape[0], ys.max() + 3)
    x0, x1 = max(0, xs.min() - 2), min(a.shape[1], xs.max() + 3)
    sub = a[y0:y1, x0:x1]
    m = mask[y0:y1, x0:x1]
    for it in range(iters):
        p = np.pad(sub, ((1, 1), (1, 1), (0, 0)), mode="edge")
        mean = (p[:-2, 1:-1] + p[2:, 1:-1] + p[1:-1, :-2] + p[1:-1, 2:]) * 0.25
        sub[m] = mean[m]
        if report and it % 64 == 0:
            report(it)
    a[y0:y1, x0:x1] = sub


# ---------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description="Build a macOS .icns from a square PNG.")
    ap.add_argument("--input", required=True, help="source PNG (square, >=1024 recommended)")
    ap.add_argument("--output", help="target .icns path")
    ap.add_argument("--erase", action="append", default=[],
                    metavar="X0,Y0,X1,Y1", help="rect to reconstruct (repeatable)")
    ap.add_argument("--bg-threshold", type=float, default=195.0,
                    help="min-channel above which a pixel counts as flat background (195)")
    ap.add_argument("--iters", type=int, default=260, help="diffusion iterations (260)")
    ap.add_argument("--no-native-radius", action="store_true",
                    help="keep the artwork's own corner curvature")
    ap.add_argument("--no-grid", action="store_true",
                    help="full-bleed artwork instead of the 824/1024 Big Sur grid")
    ap.add_argument("--keep-master", metavar="PATH", help="also write the 1024 PNG master")
    ap.add_argument("--check", action="store_true", help="report diagnostics and exit")
    args = ap.parse_args()

    src = Image.open(args.input).convert("RGB")
    if src.width != src.height:
        print(f"! source is {src.width}x{src.height}, not square - it will be squashed")
    a = np.asarray(src).astype(np.float32)
    mn = a.min(axis=2)

    print(f"source      : {args.input}  {src.width}x{src.height}")

    # ---- diagnostics -------------------------------------------------
    bg = flood_background(mn, args.bg_threshold)
    print(f"background  : {int(bg.sum())} px ({100 * bg.mean():.2f}%) connected to the corners")
    for name, (sy, sx) in {
        "TL": (slice(0, 300), slice(0, 300)), "TR": (slice(0, 300), slice(-300, None)),
        "BL": (slice(-300, None), slice(0, 300)), "BR": (slice(-300, None), slice(-300, None)),
    }.items():
        print(f"  corner {name}: {100 * bg[sy, sx].mean():5.1f}% background")
    if args.check:
        ys, xs = np.nonzero(bg)
        if len(xs):
            print(f"  bg bbox   : x {xs.min()}..{xs.max()}  y {ys.min()}..{ys.max()}")
        return 0

    # ---- 1. erase watermarks / blemishes (source pixel coords) --------
    for spec in args.erase:
        try:
            x0, y0, x1, y1 = (int(round(float(v))) for v in spec.split(","))
        except ValueError:
            print(f"! bad --erase rect: {spec}")
            return 2
        erase_rect(a, x0, y0, x1, y1, args.bg_threshold)
        print(f"erased      : {spec} reconstructed from its top/left edges")

    # ---- 2. background -> artwork-coloured, then transparent ----------
    mn = a.min(axis=2)
    bg = flood_background(mn, args.bg_threshold)
    harmonic_fill(a, bg, iters=args.iters)

    size = a.shape[1]
    if args.no_grid:
        content, canvas, radius = size, size, RADIUS_RATIO * size
    else:
        content, canvas = CONTENT, CANVAS
        radius = RADIUS_RATIO * canvas
    if args.no_native_radius:
        alpha = np.ones((size, size), dtype=np.float32)
    else:
        alpha = srgb_alpha_rounded_rect(size, radius)

    art_rgb = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGB")
    art_a = Image.fromarray((np.clip(alpha, 0, 1) * 255).astype(np.uint8), "L")
    if content != size:
        art_rgb = art_rgb.resize((content, content), Image.LANCZOS)
        art_a = art_a.resize((content, content), Image.LANCZOS)
    art = art_rgb.convert("RGBA")
    art.putalpha(art_a)

    master = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    off = (canvas - content) // 2
    master.alpha_composite(art, (off, off))
    master = master.resize((1024, 1024), Image.LANCZOS) if canvas != 1024 else master

    if args.keep_master:
        master.save(args.keep_master)
        print(f"master      : {args.keep_master}  {master.size[0]}x{master.size[1]} RGBA")

    if not args.output:
        print("! no --output given, nothing written")
        return 0

    # ---- 5. iconset + iconutil ---------------------------------------
    tmp = tempfile.mkdtemp(prefix="iconset_")
    try:
        iset = os.path.join(tmp, "Icon.iconset")
        os.makedirs(iset, exist_ok=True)
        for px, fname in ICONSET:
            master.resize((px, px), Image.LANCZOS).save(os.path.join(iset, fname))
        out = os.path.abspath(args.output)
        os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
        r = subprocess.run(["iconutil", "-c", "icns", iset, "-o", out],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(f"! iconutil failed: {r.stderr.strip()}")
            return r.returncode
        print(f"icns        : {out}  ({os.path.getsize(out) / 1024:.0f} KB)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
