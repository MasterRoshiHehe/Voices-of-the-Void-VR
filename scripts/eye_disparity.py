"""Eye-to-eye disparity per snap pair, labelled menu/gameplay from the UEVR log (menu thread, 2026-11-27).

For each <run>/eyes/sNNN_left.ppm + sNNN_right.ppm: horizontal shift (px) that best aligns the left eye onto
the right eye in five horizontal bands, with its correlation. On this headset (Quest 3, asymmetric per-eye
FOV) correct stereo shows a shift of about +0.24 of the eye width for far content and a little more for near
content (measured in gameplay 2026-11-27 00:21: +256 far, +264..274 near, eye width 1036). Swapped eyes give a
shift well below that (near content less than far); a mirrored image gives low correlation or a negative
shift. Black snaps (headset idle) are skipped.

Usage: .venv\\Scripts\\python -I scripts\\eye_disparity.py logs\\<run>
Prints one line per snap and a per-phase summary. Exit 0 always (it measures, it doesn't judge).
"""
import os
import re
import sys
from datetime import datetime

import numpy as np
from PIL import Image

BANDS = [(0.10, 0.25), (0.25, 0.40), (0.40, 0.55), (0.60, 0.75), (0.80, 0.95)]


def best_shift(a, b, w):
    best = (-2.0, 0)
    for s in range(-w // 2, w // 2, 2):
        A = a[:, s:] if s >= 0 else a[:, :w + s]
        B = b[:, :w - s] if s >= 0 else b[:, -s:]
        if A.shape[1] < w // 4:
            continue
        A = A - A.mean()
        B = B - B.mean()
        c = float((A * B).sum() / np.sqrt((A * A).sum() * (B * B).sum() + 1e-9))
        if c > best[0]:
            best = (c, s)
    return best


def world_changes(log_path):
    """[(datetime, world_name)] from '[votv] world ...' lines."""
    out = []
    if not os.path.exists(log_path):
        return out
    pat = re.compile(r"^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\].*\[votv\] world World (\S+)")
    with open(log_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = pat.match(line)
            if m:
                out.append((datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f"), m.group(2)))
    return out


def main():
    run = sys.argv[1]
    eyes = os.path.join(run, "eyes")
    changes = world_changes(os.path.join(run, "uevr_log.txt"))
    snaps = sorted(f[:-9] for f in os.listdir(eyes) if f.endswith("_left.ppm"))
    phases = {}
    for sid in snaps:
        lp = os.path.join(eyes, sid + "_left.ppm")
        rp = os.path.join(eyes, sid + "_right.ppm")
        if not os.path.exists(rp):
            continue
        t = datetime.fromtimestamp(os.path.getmtime(lp))
        world = "?"
        for ct, wn in changes:
            if ct <= t:
                world = wn
        L = np.asarray(Image.open(lp).convert("L"), float)
        R = np.asarray(Image.open(rp).convert("L"), float)
        if L.max() < 20 and R.max() < 20:
            print(f"{sid} {t:%H:%M:%S} {world:28s} black (headset idle)")
            continue
        h, w = L.shape
        res = []
        for y0, y1 in BANDS:
            c, s = best_shift(L[int(y0 * h):int(y1 * h)], R[int(y0 * h):int(y1 * h)], w)
            res.append((s, c))
        phase = "menu" if "menu" in world.lower() else world
        phases.setdefault(phase, []).append(res)
        print(f"{sid} {t:%H:%M:%S} {world:28s} " + " | ".join(f"{s:+4d}px ({s / w:+.3f}w) c{c:.2f}" for s, c in res))
    print("\nsummary (median shift per band, only bands with corr >= 0.5):")
    for phase, rows in phases.items():
        cols = []
        for i in range(len(BANDS)):
            good = [r[i][0] for r in rows if r[i][1] >= 0.5]
            cols.append(f"{int(np.median(good)):+d}px n{len(good)}" if good else "n0")
        print(f"  {phase:28s} {len(rows)} snaps: " + " | ".join(cols))


if __name__ == "__main__":
    main()
