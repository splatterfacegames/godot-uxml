#!/usr/bin/env python3
"""godot-uxml native core vs Unity UI Toolkit: build both players, run them
interleaved, summarise. See docs/performance.md, "Native core vs Unity UI
Toolkit".

  python tools/unity-bench/run.py [--rounds 5] [--iters 60] [--skip-build]
                                  [--arms godot-release,unity-il2cpp,...]

Steps:
 1. bench/unity_compare.gd --write-docs writes the documents (the generators
    of bench.gd and workloads.gd) into Assets/Resources/UI, so Unity imports
    the same files that Godot loads.
 2. Unity builds the players (Assets/Editor/BuildBench.cs): Windows x64,
    release, IL2CPP and Mono, into Builds/<backend>/.
 3. Godot exports the bench with the official release template
    (windows_release_x86_64.exe) from a staged copy of the project, into
    Builds/godot-release/. The repository's export_presets.cfg is not touched.
 4. Rounds: each round runs every arm once, the order rotated per round.
 5. Summary: per op and arm, the median of all samples and the range of the
    round medians. out/summary.md, out/summary.json.

Arms: godot-release (release template + native core), godot-release-v2 (the
same export with --runtime=2: documents that runtime v2 covers load on it,
the others on runtime v1), godot-editor (the
editor binary, the harness of the earlier figures), unity-il2cpp,
unity-mono. Every window is 640x400 in the bottom-right corner of the work
area and does not take focus; each process exits at the end of its run, and
a run that times out is killed by its PID.
"""
import argparse
import ctypes
import json
import os
import shutil
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
DEFAULT_UNITY = r"C:/Program Files/Unity/Hub/Editor/6000.3.24f1/Editor/Unity.exe"
DEFAULT_GODOT = r"B:/dev/games/godot-builds/Godot_v4.7.1-stable_win64_console.exe"
WIN_W, WIN_H = 640, 400
ARMS = ["godot-release", "unity-il2cpp", "godot-release-v2", "godot-editor", "unity-mono"]


def corner():
    class RECT(ctypes.Structure):
        _fields_ = [("l", ctypes.c_long), ("t", ctypes.c_long), ("r", ctypes.c_long), ("b", ctypes.c_long)]
    r = RECT()
    ctypes.windll.user32.SystemParametersInfoW(0x30, 0, ctypes.byref(r), 0)
    return r.r - WIN_W - 16, r.b - WIN_H - 48


def run(cmd, timeout, log=None, cwd=None):
    out = open(log, "w", encoding="utf-8", errors="replace") if log else subprocess.DEVNULL
    p = subprocess.Popen(cmd, stdout=out, stderr=subprocess.STDOUT, cwd=cwd)
    try:
        return p.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()  # only the process this script started
        p.wait()
        return -1
    finally:
        if log:
            out.close()


def write_docs(godot):
    dst = os.path.join(HERE, "Assets", "Resources", "UI")
    os.makedirs(dst, exist_ok=True)
    rc = run([godot, "--headless", "--path", REPO, "-s", "res://bench/unity_compare.gd",
              "--", "--write-docs=" + dst], 600)
    if rc != 0:
        sys.exit("write-docs failed")


def build_unity(unity, backend):
    exe = os.path.join(HERE, "Builds", backend, "UnityBench.exe")
    log = os.path.join(HERE, "Logs", "build-%s.log" % backend)
    os.makedirs(os.path.dirname(log), exist_ok=True)
    rc = run([unity, "-batchmode", "-quit", "-projectPath", HERE, "-executeMethod", "BuildBench.Build",
              "-buildOut", exe, "-backend", backend, "-logFile", log], 3600)
    if rc != 0 or not os.path.exists(exe):
        sys.exit("Unity build (%s) failed, see %s" % (backend, log))


def export_godot(godot):
    os.makedirs(os.path.join(HERE, "Logs"), exist_ok=True)
    stage = os.path.join(HERE, "Temp", "godot-stage")
    if os.path.isdir(stage):
        shutil.rmtree(stage)
    os.makedirs(os.path.join(stage, "bench"))
    shutil.copytree(os.path.join(REPO, "addons"), os.path.join(stage, "addons"))
    for fn in ("bench.gd", "workloads.gd", "unity_compare.gd"):
        src = open(os.path.join(REPO, "bench", fn), encoding="utf-8").read()
        if fn == "unity_compare.gd":
            # The exported game starts this SceneTree as its main loop.
            src = src.replace("extends SceneTree\n", "extends SceneTree\nclass_name UxmlUnityCompare\n", 1)
        open(os.path.join(stage, "bench", fn), "w", encoding="utf-8", newline="\n").write(src)
    proj = open(os.path.join(REPO, "project.godot"), encoding="utf-8").read()
    # A release build runs only with a main scene: an empty Node.
    proj = proj.replace("[application]\n", '[application]\n\nrun/main_loop_type="UxmlUnityCompare"\n'
                        'run/main_scene="res://bench/empty.tscn"\n', 1)
    open(os.path.join(stage, "bench", "empty.tscn"), "w", encoding="utf-8", newline="\n").write(
        '[gd_scene format=3]\n\n[node name="Empty" type="Node"]\n')
    open(os.path.join(stage, "project.godot"), "w", encoding="utf-8", newline="\n").write(proj)
    open(os.path.join(stage, "export_presets.cfg"), "w", encoding="utf-8", newline="\n").write(
        '[preset.0]\n\nname="Windows Bench"\nplatform="Windows Desktop"\nrunnable=true\n'
        'dedicated_server=false\ncustom_features=""\nexport_filter="all_resources"\n'
        'include_filter="*.uxml,*.uss"\nexclude_filter=""\nexport_path=""\nscript_export_mode=2\n\n'
        '[preset.0.options]\n\nbinary_format/embed_pck=false\nbinary_format/architecture="x86_64"\n'
        'codesign/enable=false\napplication/modify_resources=false\n')
    run([godot, "--headless", "--path", stage, "--import"], 900)
    out = os.path.join(HERE, "Builds", "godot-release")
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out)
    exe = os.path.join(out, "GodotBench.exe")
    rc = run([godot, "--headless", "--path", stage, "--export-release", "Windows Bench", exe], 900,
             log=os.path.join(HERE, "Logs", "export-godot.log"))
    if rc != 0 or not os.path.exists(exe):
        sys.exit("Godot export failed, see Logs/export-godot.log")


def arm_cmd(arm, args, out_json):
    x, y = corner()
    pos = ["--position", "%d,%d" % (x, y), "--resolution", "%dx%d" % (WIN_W, WIN_H)]
    user = ["--", "--iters=%d" % args.iters, "--out=" + out_json]
    if arm == "godot-release":
        return [os.path.join(HERE, "Builds", "godot-release", "GodotBench.exe")] + pos + user
    if arm == "godot-release-v2":
        # The same export; documents that runtime v2 covers load on it.
        return [os.path.join(HERE, "Builds", "godot-release", "GodotBench.exe")] + pos + user + ["--runtime=2"]
    if arm == "godot-editor":
        return [args.godot, "--path", REPO] + pos + ["-s", "res://bench/unity_compare.gd"] + user
    backend = arm.split("-")[1]
    return [os.path.join(HERE, "Builds", backend, "UnityBench.exe"), "-benchOut", out_json,
            "-iters", str(args.iters), "-screen-width", str(WIN_W), "-screen-height", str(WIN_H),
            "-screen-fullscreen", "0", "-logFile", out_json[:-5] + ".log"]


def summarise(outdir, arms, rounds):
    data = {}  # arm -> op -> list of per-round sample lists
    meta = {}
    for arm in arms:
        for r in range(rounds):
            p = os.path.join(outdir, "r%d-%s.json" % (r, arm))
            if not os.path.exists(p):
                continue
            d = json.load(open(p, encoding="utf-8"))
            meta[arm] = d["meta"]
            for row in d["rows"]:
                data.setdefault(arm, {}).setdefault(row["op"], []).append(row["samples"])
    ops = []
    for arm in arms:
        for op in data.get(arm, {}):
            if op not in ops:
                ops.append(op)
    summary = {"meta": meta, "ops": {}}
    for op in ops:
        summary["ops"][op] = {}
        for arm in arms:
            runs = data.get(arm, {}).get(op)
            if not runs:
                continue
            pooled = [v for s in runs for v in s]
            meds = [statistics.median(s) for s in runs]
            summary["ops"][op][arm] = {"median": statistics.median(pooled), "n": len(pooled),
                                        "rounds": len(runs), "round_min": min(meds), "round_max": max(meds)}
    json.dump(summary, open(os.path.join(outdir, "summary.json"), "w"), indent=1)
    lines = ["| op | " + " | ".join(arms) + " |", "| --- |" + " ---: |" * len(arms)]
    for op in ops:
        cells = []
        for arm in arms:
            s = summary["ops"][op].get(arm)
            cells.append("%.3f (%.3f-%.3f)" % (s["median"], s["round_min"], s["round_max"]) if s else "-")
        lines.append("| %s | %s |" % (op, " | ".join(cells)))
    text = "\n".join(lines) + "\n"
    open(os.path.join(outdir, "summary.md"), "w").write(text)
    print(text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--unity", default=os.environ.get("UNITY_EXE", DEFAULT_UNITY))
    ap.add_argument("--godot", default=os.environ.get("GODOT", DEFAULT_GODOT))
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--iters", type=int, default=60)
    ap.add_argument("--arms", default=",".join(ARMS))
    ap.add_argument("--skip-build", action="store_true")
    ap.add_argument("--summary-only", action="store_true")
    ap.add_argument("--out", default=os.path.join(HERE, "out"))
    args = ap.parse_args()
    arms = [a for a in args.arms.split(",") if a]
    os.makedirs(args.out, exist_ok=True)
    if args.summary_only:
        summarise(args.out, arms, args.rounds)
        return 0
    if not args.skip_build:
        write_docs(args.godot)
        for backend in ("il2cpp", "mono"):
            if "unity-" + backend in arms:
                print("building Unity player (%s)..." % backend, flush=True)
                build_unity(args.unity, backend)
        if "godot-release" in arms or "godot-release-v2" in arms:
            print("exporting Godot release build...", flush=True)
            export_godot(args.godot)
    failures = []
    for r in range(args.rounds):
        order = arms[r % len(arms):] + arms[:r % len(arms)]
        for arm in order:
            out_json = os.path.join(args.out, "r%d-%s.json" % (r, arm))
            if os.path.exists(out_json):
                os.remove(out_json)
            for attempt in range(2):  # one retry after a crash
                t0 = time.time()
                rc = run(arm_cmd(arm, args, out_json), 900, log=out_json[:-5] + ".stdout.log")
                ok = os.path.exists(out_json)
                print("round %d %-14s rc=%d %s %.0fs" % (r, arm, rc, "ok" if ok else "NO RESULT", time.time() - t0), flush=True)
                if ok:
                    break
                failures.append({"round": r, "arm": arm, "rc": rc})
                shutil.copyfile(out_json[:-5] + ".stdout.log", out_json[:-5] + ".fail%d.log" % attempt)
    json.dump(failures, open(os.path.join(args.out, "failures.json"), "w"), indent=1)
    summarise(args.out, arms, args.rounds)
    return 0


if __name__ == "__main__":
    sys.exit(main())
