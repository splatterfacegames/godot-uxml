#!/usr/bin/env python3
"""Run UXML/USS cases through Unity and write ground-truth JSON.

Stages every case into tools/unity-dump/Assets/Cases/<name>/, starts Unity in
batch mode on the tools/unity-dump project and runs UxmlDump.Run, which writes
one <name>.json per case (see Assets/Editor/UxmlDump.cs for the format).

Case sources (both may be given):
  --cases DIR        a directory of <name>.uxml with optional <name>.uss and
                     <name>.json sidecar (default: bench/parity/cases)
  --reference FILE   bench/parity/reference.json (the reference engine's
                     golden cases); cases whose files sit outside the case
                     folder (project-rooted Assets/ or Packages/ paths) are
                     skipped, because one Unity project cannot hold them all.

  python tools/unity-dump/run.py [--unity PATH] [--out bench/parity/unity]
                                 [--only a,b] [--no-reference]
"""
import argparse
import json
import os
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
        names.append(name)
    return names


def stage_reference(ref_path, stage, only):
    data = json.load(open(ref_path, encoding="utf-8"))
    names, skipped = [], []
    for c in data["cases"]:
        name = c["name"]
        if only and name not in only:
            continue
        files = c.get("files") or {}
        if any(k.startswith(("Assets/", "Packages/", "/")) or ".." in k for k in files):
            skipped.append(name)
            continue
        d = os.path.join(stage, name)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, name + ".uxml"), "w", encoding="utf-8") as f:
            f.write(c["uxml"])
        if c.get("uss"):
            with open(os.path.join(d, name + ".uss"), "w", encoding="utf-8") as f:
                f.write(c["uss"])
        for rel, text in files.items():
            p = os.path.join(d, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as f:
                f.write(text)
        side = {"width": data["panel"]["width"], "height": data["panel"]["height"]}
        with open(os.path.join(d, name + ".json"), "w", encoding="utf-8") as f:
            json.dump(side, f)
        names.append(name)
    return names, skipped


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--unity", default=os.environ.get("UNITY_EXE", DEFAULT_UNITY))
    ap.add_argument("--cases", default=os.path.join(REPO, "bench", "parity", "cases"))
    ap.add_argument("--reference", default=os.path.join(REPO, "bench", "parity", "reference.json"))
    ap.add_argument("--no-reference", action="store_true")
    ap.add_argument("--out", default=os.path.join(REPO, "bench", "parity", "unity"))
    ap.add_argument("--only", default="")
    ap.add_argument("--log", default=os.path.join(HERE, "Logs", "dump.log"))
    args = ap.parse_args()
    only = set(x for x in args.only.split(",") if x)

    stage = os.path.join(HERE, "Assets", "Cases")
    if os.path.isdir(stage):
        shutil.rmtree(stage)
    os.makedirs(stage)
    names = []
    if os.path.isdir(args.cases):
        names += stage_dir_cases(args.cases, stage, only)
    skipped = []
    if not args.no_reference and os.path.exists(args.reference):
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
    print("running %d cases through Unity..." % len(names))
    rc = subprocess.call(cmd)
    log = open(args.log, encoding="utf-8", errors="replace").read()
    failed = [l for l in log.splitlines() if "[uxml-dump]" in l and "failed" in l]
    wrote = [l for l in log.splitlines() if "[uxml-dump] wrote" in l]
    for l in failed:
        print(l)
    print("Unity exit %d: %d written, %d failed, %d skipped (project-rooted files: %s)" % (
        rc, len(wrote), len(failed), len(skipped), ", ".join(skipped) or "none"))
    if rc != 0 and not wrote:
        print("see " + args.log)
    return 0 if rc == 0 and not failed else 1


if __name__ == "__main__":
    sys.exit(main())
