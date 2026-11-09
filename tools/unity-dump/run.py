#!/usr/bin/env python3
"""Run UXML/USS cases through Unity and write ground-truth JSON.

Stages every case into tools/unity-dump/Assets/Cases/<name>/, starts Unity in
batch mode on the tools/unity-dump project and runs UxmlDump.Run, which writes
one <name>.json per case (see Assets/Editor/UxmlDump.cs for the format).

Case sources (both may be given):
  --cases DIR        a directory of <name>.uxml with optional <name>.uss and
                     <name>.json sidecar (default: bench/parity/cases)
                     A folder <name>.files/ beside a case holds its other
                     files (templates, sheets), copied into the case folder.
  --reference FILE   bench/parity/reference.json (the reference engine's
                     golden cases). Their files also go to Assets/GoldenCases/
                     (the folder the reference cases live in, so /Assets/...
                     and project:// paths resolve), and project-rooted
                     Packages/ files to an embedded package in Packages/;
                     the cases agree on those files, so one project holds all.

  python tools/unity-dump/run.py [--unity PATH] [--out bench/parity/unity]
                                 [--only a,b] [--no-reference]
                                 [--render bench/pixels/unity]

--render also draws each case to <DIR>/<case>.png and <case>.notext.png
(Unity runs with a graphics device for it; see UxmlDump.RenderCase).

Panel scaling (bench/parity/scaled/matrix.json):
  --scaled FILE      dump every case of the matrix under every panel setting
                     and screen it lists, as <case>__<config>__<W>x<H>, to
                     --out (default bench/parity/unity-scaled) and, with
                     --render, its renders (bench/pixels/unity-scaled).
  --scale-probe FILE write how Unity resolves the scale for a grid of panel
                     settings and screens (UxmlDump.ScaleProbe) to FILE, and
                     the PanelSettings fixtures of the matrix (saved by Unity)
                     to tests/fixtures/panel_settings/.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
DEFAULT_UNITY = r"C:/Program Files/Unity/Hub/Editor/6000.3.24f1/Editor/Unity.exe"


def stage_dir_cases(src, stage, only):
    names = []
    for fn in sorted(os.listdir(src)):
        if not fn.endswith(".uxml"):
            continue
        name = fn[:-5]
        if only and name not in only:
            continue
        d = os.path.join(stage, name)
        os.makedirs(d, exist_ok=True)
        for ext in (".uxml", ".uss", ".json"):
            p = os.path.join(src, name + ext)
            if os.path.exists(p):
                shutil.copyfile(p, os.path.join(d, name + ext))
        extra = os.path.join(src, name + ".files")
        if os.path.isdir(extra):
            shutil.copytree(extra, d, dirs_exist_ok=True)
        names.append(name)
    return names


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def stage_reference(ref_path, stage, only):
    data = json.load(open(ref_path, encoding="utf-8"))
    names, skipped = [], []
    golden = os.path.join(HERE, "Assets", "GoldenCases")
    if os.path.isdir(golden):
        shutil.rmtree(golden)
    rooted = {}
    for c in data["cases"]:
        name = c["name"]
        if only and name not in only:
            continue
        files = c.get("files") or {}
        if any(k.startswith(("Assets/", "/")) or ".." in k for k in files):
            skipped.append(name)
            continue
        conflict = False
        for k, text in files.items():
            if k.startswith("Packages/"):
                if rooted.get(k, text) != text:
                    conflict = True
                rooted[k] = text
        if conflict:
            skipped.append(name)
            continue
        for k, text in files.items():
            if k.startswith("Packages/"):
                write(os.path.join(HERE, k), text)
            else:
                write(os.path.join(golden, k), text)
        d = os.path.join(stage, name)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, name + ".uxml"), "w", encoding="utf-8") as f:
            f.write(c["uxml"])
        if c.get("uss"):
            with open(os.path.join(d, name + ".uss"), "w", encoding="utf-8") as f:
                f.write(c["uss"])
        for rel, text in files.items():
            if rel.startswith("Packages/"):
                continue
            p = os.path.join(d, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as f:
                f.write(text)
        side = {"width": data["panel"]["width"], "height": data["panel"]["height"]}
        with open(os.path.join(d, name + ".json"), "w", encoding="utf-8") as f:
            json.dump(side, f)
        names.append(name)
    return names, skipped


def scaled_name(case, config, screen):
    return "%s__%s__%dx%d" % (case, config, screen[0], screen[1])


def stage_scaled(matrix_path, stage, only):
    """Every case of the matrix under every config and screen: the case
    files under the new name, with a sidecar that carries the panel
    settings, the screen (render texture) size and the host mode."""
    m = json.load(open(matrix_path, encoding="utf-8"))
    base = os.path.dirname(os.path.abspath(matrix_path))
    names = []
    for case, opts in m["cases"].items():
        src = os.path.join(REPO, opts["dir"]) if "dir" in opts else os.path.join(REPO, "bench", "parity", "cases")
        side = {}
        sp = os.path.join(src, case + ".json")
        if os.path.exists(sp):
            side = json.load(open(sp, encoding="utf-8"))
        for cfg in m["configs"]:
            if cfg.get("cases") and case not in cfg["cases"]:
                continue
            for screen in cfg["screens"]:
                name = scaled_name(case, cfg["id"], screen)
                if only and name not in only and case not in only:
                    continue
                d = os.path.join(stage, name)
                os.makedirs(d, exist_ok=True)
                for ext in (".uxml", ".uss"):
                    p = os.path.join(src, case + ext)
                    if os.path.exists(p):
                        shutil.copyfile(p, os.path.join(d, name + ext))
                extra = os.path.join(src, case + ".files")
                if os.path.isdir(extra):
                    shutil.copytree(extra, d, dirs_exist_ok=True)
                sc = dict(side)
                sc["panel"] = cfg["panel"]
                sc["screen"] = screen
                sc["fill"] = bool(opts.get("fill", False))
                with open(os.path.join(d, name + ".json"), "w", encoding="utf-8") as f:
                    json.dump(sc, f)
                names.append(name)
    if names:
        # Unity lays out a text with a stale measure while TextCore fills its
        # dynamic font atlas with the text's glyphs (docs/parity.md,
        # ctl-numeric): a copy of each case under its first setting runs
        # before every other dump ("0-warmup-<case>"), and main() drops
        # those dumps.
        firsts = {}
        for n in names:
            firsts.setdefault(n.split("__")[0], n)
        for case, first in firsts.items():
            wname = WARMUP + "-" + case
            warm = os.path.join(stage, wname)
            shutil.copytree(os.path.join(stage, first), warm)
            for fn in os.listdir(warm):
                os.rename(os.path.join(warm, fn), os.path.join(warm, fn.replace(first, wname)))
    return names


WARMUP = "0-warmup"


def probe_rows(matrix_path):
    """The grid of UxmlDump.ScaleProbe: every scale mode with the values
    that change its result, on the screens of the matrix probe."""
    m = json.load(open(matrix_path, encoding="utf-8"))
    pr = m["probe"]
    rows = []
    for screen in pr["screens"]:
        for scale in pr["pixelScales"]:
            rows.append({"panel": {"scaleMode": "ConstantPixelSize", "scale": scale}, "screen": screen})
        for ref_dpi in pr["referenceDpis"]:
            for fb in pr["fallbackDpis"]:
                rows.append({"panel": {"scaleMode": "ConstantPhysicalSize", "referenceDpi": ref_dpi,
                                       "fallbackDpi": fb}, "screen": screen})
        for res in pr["referenceResolutions"]:
            for scale in pr["screenScales"]:
                for mt in pr["matches"]:
                    rows.append({"panel": {"scaleMode": "ScaleWithScreenSize", "referenceResolution": res,
                                           "screenMatchMode": "MatchWidthOrHeight", "match": mt,
                                           "scale": scale}, "screen": screen})
                for mode in ("Expand", "Shrink"):
                    rows.append({"panel": {"scaleMode": "ScaleWithScreenSize", "referenceResolution": res,
                                           "screenMatchMode": mode, "scale": scale}, "screen": screen})
    return {"rows": rows, "assets": m.get("assets", [])}


def run_probe(args):
    probe_in = os.path.join(HERE, "Logs", "scale-probe-in.json")
    os.makedirs(os.path.dirname(probe_in), exist_ok=True)
    data = probe_rows(args.scaled or os.path.join(REPO, "bench", "parity", "scaled", "matrix.json"))
    with open(probe_in, "w", encoding="utf-8") as f:
        json.dump(data, f)
    fixtures = os.path.join(REPO, "tests", "fixtures", "panel_settings")
    cmd = [args.unity, "-batchmode", "-projectPath", HERE, "-executeMethod", "UxmlDump.ScaleProbe",
           "-probeIn", probe_in, "-probeOut", os.path.abspath(args.scale_probe),
           "-fixtureOut", fixtures, "-logFile", args.log]
    print("probing %d panel settings through Unity..." % len(data["rows"]))
    rc = subprocess.call(cmd)
    if rc == 0:
        # One line per row, so a diff shows what changed.
        out = json.load(open(args.scale_probe, encoding="utf-8"))
        with open(args.scale_probe, "w", encoding="utf-8", newline="\n") as f:
            f.write('{"unityVersion": %s, "screenDpi": %s, "rows": [\n' % (
                json.dumps(out["unityVersion"]), json.dumps(out["screenDpi"])))
            f.write(",\n".join(json.dumps(r, sort_keys=True) for r in out["rows"]))
            f.write("\n]}\n")
    print("Unity exit %d (see %s)" % (rc, args.log))
    return rc


WARN_RE = re.compile(r"Assets/Cases/([^/]+)/([^ ]+) \(line (\d+)\): (warning|error): (.*)$")


def attach_import_warnings(log, out, names):
    """Unity's USS import diagnostics (from the log) go into each case's dump
    as "importWarnings": [{file, line, message}], so the harness can check
    that godot-uxml reports the same declarations."""
    per = {}
    for line in log.splitlines():
        m = WARN_RE.search(line)
        if not m:
            continue
        entry = {"file": m.group(2), "line": int(m.group(3)), "message": m.group(5).strip()}
        lst = per.setdefault(m.group(1), [])
        if entry not in lst:
            lst.append(entry)
    for name in names:
        p = os.path.join(out, name + ".json")
        if not os.path.exists(p):
            continue
        with open(p, encoding="utf-8") as f:
            data = json.load(f)
        data["importWarnings"] = sorted(per.get(name, []), key=lambda e: (e["file"], e["line"]))
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            json.dump(data, f, indent=1, ensure_ascii=False)
            f.write("\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--unity", default=os.environ.get("UNITY_EXE", DEFAULT_UNITY))
    ap.add_argument("--cases", default=os.path.join(REPO, "bench", "parity", "cases"))
    ap.add_argument("--reference", default=os.path.join(REPO, "bench", "parity", "reference.json"))
    ap.add_argument("--no-reference", action="store_true")
    ap.add_argument("--out", default=os.path.join(REPO, "bench", "parity", "unity"))
    ap.add_argument("--only", default="")
    ap.add_argument("--log", default=os.path.join(HERE, "Logs", "dump.log"))
    ap.add_argument("--render", default="",
                    help="also render each case to <DIR>/<case>.png and <case>.notext.png")
    ap.add_argument("--scaled", default="",
                    help="a panel-scaling matrix (bench/parity/scaled/matrix.json)")
    ap.add_argument("--scale-probe", default="",
                    help="write UxmlDump.ScaleProbe's results to this file")
    args = ap.parse_args()
    only = set(x for x in args.only.split(",") if x)
    if args.scale_probe:
        return run_probe(args)
    if args.scaled and args.out == os.path.join(REPO, "bench", "parity", "unity"):
        args.out = os.path.join(REPO, "bench", "parity", "unity-scaled")

    stage = os.path.join(HERE, "Assets", "Cases")
    if os.path.isdir(stage):
        shutil.rmtree(stage)
    os.makedirs(stage)
    names = []
    skipped = []
    if args.scaled:
        names += stage_scaled(args.scaled, stage, only)
    elif os.path.isdir(args.cases):
        names += stage_dir_cases(args.cases, stage, only)
    if not args.scaled and not args.no_reference and os.path.exists(args.reference):
        more, skipped = stage_reference(args.reference, stage, only)
        names += more
    if not names:
        print("no cases to run")
        return 1
    os.makedirs(args.out, exist_ok=True)
    os.makedirs(os.path.dirname(args.log), exist_ok=True)
    cmd = [args.unity, "-batchmode", "-projectPath", HERE,
           "-executeMethod", "UxmlDump.Run",
           "-dumpCases", "Assets/Cases", "-dumpOut", os.path.abspath(args.out),
           "-logFile", args.log]
    if args.render:
        cmd += ["-renderOut", os.path.abspath(args.render)]
    print("running %d cases through Unity..." % len(names))
    rc = subprocess.call(cmd)
    log = open(args.log, encoding="utf-8", errors="replace").read()
    failed = [l for l in log.splitlines() if "[uxml-dump]" in l and "failed" in l]
    wrote = [l for l in log.splitlines() if "[uxml-dump] wrote" in l]
    for l in failed:
        print(l)
    attach_import_warnings(log, args.out, names)
    for d in [args.out] + ([args.render] if args.render else []):
        for fn in os.listdir(d):
            if fn.startswith(WARMUP + "-"):
                os.remove(os.path.join(d, fn))
    wrote = [l for l in wrote if (" " + WARMUP + "-") not in l]
    print("Unity exit %d: %d written, %d failed, %d skipped (project-rooted files: %s)" % (
        rc, len(wrote), len(failed), len(skipped), ", ".join(skipped) or "none"))
    if rc != 0 and not wrote:
        print("see " + args.log)
    return 0 if rc == 0 and not failed else 1


if __name__ == "__main__":
    sys.exit(main())
