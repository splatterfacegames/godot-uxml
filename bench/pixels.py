#!/usr/bin/env python3
"""Rendered-pixel comparison of godot-uxml with Unity 6000.3.

Unity's renders (tools/unity-dump/run.py --render bench/pixels/unity) are
committed in bench/pixels/unity/: <case>.png as drawn and
<case>.notext.png with every text colour transparent. This script renders
the same cases with godot-uxml (bench/pixels_render.gd, windowed: Godot
needs a renderer) into bench/pixels/out/godot/ and compares them:

  boxes   <case>.notext.png against <case>.notext.png: everything but text
          (backgrounds, images, borders, radii, opacity, clipping,
          transforms, filters, the controls' theme images), strictly.
          exact: fraction of pixels whose largest channel error is at most
          --tol (default 8 of 255); near: fraction within --tol of some
          pixel at most 1px away in the other image (edge antialiasing);
          max: largest channel error.
  text    the text pixels of each side: where <case>.png and
          <case>.notext.png differ by more than 24 in some channel. Unity
          and godot-uxml use different fonts and rasterisers, so text is
          compared by placement and amount: IoU of the two text masks
          (each dilated by 1px), the number of text pixels on each side,
          and per text block (the union of both masks, joined across
          3px x 1px gaps) the largest difference of the bounding-box edges.
  full    <case>.png against <case>.png within --tol (for reference).

Writes bench/pixels/out/diff/<case>.png (Unity | godot-uxml | box
differences in red, Unity-only text in blue, godot-uxml-only text in
green), prints one line per case and a summary line:

  PIXELS: <n> cases; boxes: <a> exact, <b> within 1px; ...

  python bench/pixels.py [--godot EXE] [--only a,b] [--no-render]
                         [--markdown FILE] [--tol 8]

Needs Pillow and numpy.
"""
import argparse
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
UNITY = os.path.join(HERE, "pixels", "unity")
OUT = os.path.join(HERE, "pixels", "out")
DEFAULT_GODOT = os.environ.get("GODOT", "godot")
TEXT_THRESHOLD = 24


def load(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.int16)


def chan_err(a, b):
    return np.abs(a - b).max(axis=2)


def shift_min_err(a, b):
    """Per pixel: the smallest largest-channel error of a against b and b's
    8 neighbours (1px), so antialiasing that lands 1px over still matches."""
    h, w, _ = a.shape
    pad = np.pad(b, ((1, 1), (1, 1), (0, 0)), mode="edge")
    best = None
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            nb = pad[1 + dy:1 + dy + h, 1 + dx:1 + dx + w]
            e = chan_err(a, nb)
            best = e if best is None else np.minimum(best, e)
    return best


def dilate(mask, rx=1, ry=1):
    out = mask.copy()
    h, w = mask.shape
    pad = np.pad(mask, ((ry, ry), (rx, rx)))
    for dy in range(-ry, ry + 1):
        for dx in range(-rx, rx + 1):
            out |= pad[ry + dy:ry + dy + h, rx + dx:rx + dx + w]
    return out


def components(mask):
    """Connected components (4-neighbour) of a boolean mask: a list of
    (y0, x0, y1, x1, pixel mask) boxes. Small masks only (UI renders)."""
    h, w = mask.shape
    seen = np.zeros_like(mask)
    out = []
    ys, xs = np.nonzero(mask)
    for y, x in zip(ys, xs):
        if seen[y, x]:
            continue
        stack = [(y, x)]
        seen[y, x] = True
        pts = []
        while stack:
            cy, cx = stack.pop()
            pts.append((cy, cx))
            for ny, nx in ((cy + 1, cx), (cy - 1, cx), (cy, cx + 1), (cy, cx - 1)):
                if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        p = np.array(pts)
        out.append((p[:, 0].min(), p[:, 1].min(), p[:, 0].max(), p[:, 1].max()))
    return out


def bbox(mask):
    ys, xs = np.nonzero(mask)
    if len(ys) == 0:
        return None
    return (ys.min(), xs.min(), ys.max(), xs.max())


def compare(name, udir, gdir, ddir, tol):
    uf, un = load(os.path.join(udir, name + ".png")), load(os.path.join(udir, name + ".notext.png"))
    gp = os.path.join(gdir, name + ".png")
    if not os.path.exists(gp):
        return {"name": name, "status": "no render"}
    gf, gn = load(gp), load(os.path.join(gdir, name + ".notext.png"))
    if uf.shape != gf.shape:
        return {"name": name, "status": "size %s vs %s" % (uf.shape[:2], gf.shape[:2])}
    n = uf.shape[0] * uf.shape[1]
    # Boxes: the renders without text.
    be = chan_err(un, gn)
    bad = be > tol
    near_bad = bad & (shift_min_err(un, gn) > tol) & (shift_min_err(gn, un) > tol)
    # Text masks.
    ut = chan_err(uf, un) > TEXT_THRESHOLD
    gt = chan_err(gf, gn) > TEXT_THRESHOLD
    ud, gd = dilate(ut), dilate(gt)
    union = (ud | gd).sum()
    iou = 1.0 if union == 0 else float((ud & gd).sum()) / float(union)
    edge = 0
    blocks = 0
    for (y0, x0, y1, x1) in components(dilate(ut | gt, 3, 1)):
        blocks += 1
        ub = bbox(ut[y0:y1 + 1, x0:x1 + 1])
        gb = bbox(gt[y0:y1 + 1, x0:x1 + 1])
        if ub is None or gb is None:
            edge = max(edge, max(y1 - y0 + 1, x1 - x0 + 1))
            continue
        edge = max(edge, max(abs(int(a) - int(b)) for a, b in zip(ub, gb)))
    fe = chan_err(uf, gf)
    r = {
        "name": name,
        "box_exact": 1.0 - bad.sum() / n,
        "box_near": 1.0 - near_bad.sum() / n,
        "box_max": int(be.max()),
        "box_bad": int(bad.sum()),
        "box_far": int(near_bad.sum()),
        "text_u": int(ut.sum()),
        "text_g": int(gt.sum()),
        "text_iou": iou,
        "text_edge": int(edge),
        "text_blocks": blocks,
        "full": 1.0 - (fe > tol).sum() / n,
    }
    r["regions"] = [(int(a), int(b), int(c), int(d)) for (a, b, c, d) in components(dilate(near_bad, 2, 2))]
    r["status"] = "exact" if r["box_bad"] == 0 else ("1px" if r["box_far"] == 0 else "differs")
    # Diff image: Unity | godot-uxml | differences.
    h, w = be.shape
    diff = (np.asarray(Image.fromarray(uf.astype(np.uint8)).convert("L"), dtype=np.float32) * 0.25 + 160).astype(np.uint8)
    diff = np.stack([diff] * 3, axis=2)
    diff[ut & ~gt] = (40, 90, 255)
    diff[gt & ~ut] = (40, 190, 60)
    diff[bad & ~near_bad] = (255, 170, 0)
    diff[near_bad] = (230, 0, 0)
    sheet = np.zeros((h, w * 3 + 8, 3), dtype=np.uint8)
    sheet[:, :, :] = 255
    sheet[:, :w] = uf.astype(np.uint8)
    sheet[:, w + 4:2 * w + 4] = gf.astype(np.uint8)
    sheet[:, 2 * w + 8:] = diff
    os.makedirs(ddir, exist_ok=True)
    Image.fromarray(sheet).save(os.path.join(ddir, name + ".png"))
    return r


def unity_elements(name):
    """The Unity dump's elements with panel rects (bench/parity/unity)."""
    p = os.path.join(HERE, "parity", "unity", name + ".json")
    if not os.path.exists(p):
        return []
    d = json.load(open(p, encoding="utf-8"))
    out = []
    for e in d["elements"] + d.get("overlay", []):
        rc = e["rect"]
        label = e["type"] + ("#" + e["name"] if e["name"] else "")
        cls = [c for c in e["classes"] if c.startswith("unity-")][:1]
        if cls and not e["name"]:
            label += "." + cls[0]
        out.append((rc["x"], rc["y"], rc["x"] + rc["width"], rc["y"] + rc["height"], e["path"], label))
    return out


def explain(r):
    """Each region of box differences with the smallest Unity element that
    holds it."""
    els = unity_elements(r["name"])
    lines = []
    for (y0, x0, y1, x1) in r.get("regions", [])[:12]:
        best = None
        for (ex0, ey0, ex1, ey1, path, label) in els:
            if ex0 - 2 <= x0 and ey0 - 2 <= y0 and ex1 + 2 >= x1 and ey1 + 2 >= y1:
                area = (ex1 - ex0) * (ey1 - ey0)
                if best is None or area <= best[0]:
                    best = (area, path, label)
        lines.append("    (%d,%d)-(%d,%d) %s" % (x0, y0, x1, y1, "%s %s" % (best[1], best[2]) if best else "-"))
    return lines


def render(godot, names, gdir):
    os.makedirs(gdir, exist_ok=True)
    cmd = [godot, "--path", REPO, "--resolution", "64x64", "-s", "res://bench/pixels_render.gd",
           "--", "--out", gdir]
    if names:
        cmd += ["--only", ",".join(names)]
    p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = p.stdout + p.stderr
    errs = [l for l in out.splitlines() if "SCRIPT ERROR" in l or l.startswith("ERROR")]
    for l in errs[:20]:
        print("godot: " + l)
    done = [l for l in out.splitlines() if l.startswith("PIXELS RENDER")]
    print(done[0] if done else "godot-uxml render failed (exit %d)" % p.returncode)
    return bool(done)


def fmt(r):
    if "box_exact" not in r:
        return "| %s | %s | | | | | | |" % (r["name"], r["status"])
    return "| %s | %s | %.2f%% | %.2f%% | %d | %.2f | %d / %d | %d |" % (
        r["name"], r["status"], 100 * r["box_exact"], 100 * r["box_near"], r["box_max"],
        r["text_iou"], r["text_u"], r["text_g"], r["text_edge"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", default=DEFAULT_GODOT)
    ap.add_argument("--only", default="")
    ap.add_argument("--no-render", action="store_true")
    ap.add_argument("--unity", default=UNITY)
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--tol", type=int, default=8)
    ap.add_argument("--markdown", default="")
    ap.add_argument("--json", default="")
    ap.add_argument("--explain", action="store_true",
                    help="list each region of box differences with the Unity element that holds it")
    args = ap.parse_args()
    only = [x for x in args.only.split(",") if x]
    names = sorted(f[:-4] for f in os.listdir(args.unity) if f.endswith(".png") and not f.endswith(".notext.png"))
    if only:
        names = [n for n in names if n in only]
    gdir = os.path.join(args.out, "godot")
    ddir = os.path.join(args.out, "diff")
    if not args.no_render and not render(args.godot, only, gdir):
        return 1
    rows = [compare(n, args.unity, gdir, ddir, args.tol) for n in names]
    head = ["| case | boxes | exact | within 1px | max error | text IoU | text px Unity / godot-uxml | text edge px |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    lines = head + [fmt(r) for r in rows]
    print("\n".join(lines))
    if args.explain:
        for r in rows:
            if r.get("regions"):
                print(r["name"])
                print("\n".join(explain(r)))
    done =[r for r in rows if "box_exact" in r]
    exact = sum(1 for r in done if r["status"] == "exact")
    aa = sum(1 for r in done if r["status"] == "1px")
    px = sum(r["box_exact"] for r in done) / max(1, len(done))
    near = sum(r["box_near"] for r in done) / max(1, len(done))
    iou = sum(r["text_iou"] for r in done) / max(1, len(done))
    summary = ("PIXELS: %d cases (%d not rendered); boxes: %d exact, %d more within 1px, %d differ; "
               "box pixels %.3f%% exact, %.3f%% within 1px; text mask IoU %.3f (mean)") % (
        len(done), len(rows) - len(done), exact, aa, len(done) - exact - aa, 100 * px, 100 * near, iou)
    print("")
    print(summary)
    if args.markdown:
        with open(args.markdown, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n\n" + summary + "\n")
    if args.json:
        with open(args.json, "w", encoding="utf-8", newline="\n") as f:
            json.dump(rows, f, indent=1, default=float)
    return 0


if __name__ == "__main__":
    sys.exit(main())
