#!/usr/bin/env python3
"""Run a SceneTree script of the repository on the official release template.

    python tools/prof_release.py [--godot <editor exe>] [--skip-export]
                                 [--script res://bench/prof/ops.gd] -- <user args>

Stages a copy of the project (addons/ and bench/), makes the script the main
loop of the export (a class_name is added to it), exports it with the
release template (windows_release_x86_64.exe) into
tools/unity-bench/Builds/godot-prof/ and runs it in a small window at the
bottom right of the work area, without focus. The documents of
bench/unity_compare.gd must be in UxmlBenchDir.of("godot_uxml_ucmp") (any run of
unity_compare.gd or tools/unity-bench/run.py writes them; --write-docs
writes them first). The release template has no script profiler, so
function-level profiles (tools/gdprof.py) run on the editor binary; the
native timers (UxmlNative.prof_enable / prof_take) and bench/prof/ops.gd
--op=big-steps work here.
"""
import argparse
import ctypes
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
OUT = os.path.join(REPO, "tools", "unity-bench", "Builds", "godot-prof")
STAGE = os.path.join(REPO, "tools", "unity-bench", "Temp", "godot-prof-stage")


def corner(w, h):
    class RECT(ctypes.Structure):
        _fields_ = [("l", ctypes.c_long), ("t", ctypes.c_long), ("r", ctypes.c_long), ("b", ctypes.c_long)]
    r = RECT()
    ctypes.windll.user32.SystemParametersInfoW(0x30, 0, ctypes.byref(r), 0)
    return r.r - w - 16, r.b - h - 48


def export(godot, script):
    if os.path.isdir(STAGE):
        shutil.rmtree(STAGE)
    shutil.copytree(os.path.join(REPO, "addons"), os.path.join(STAGE, "addons"))
    shutil.copytree(os.path.join(REPO, "bench"), os.path.join(STAGE, "bench"),
                    ignore=shutil.ignore_patterns("pixels", "ref", "parity", "*.png"))
    rel = script.replace("res://", "")
    p = os.path.join(STAGE, rel)
    src = open(p, encoding="utf-8").read()
    src = src.replace("extends SceneTree\n", "extends SceneTree\nclass_name UxmlProfMain\n", 1)
    open(p, "w", encoding="utf-8", newline="\n").write(src)
    proj = open(os.path.join(REPO, "project.godot"), encoding="utf-8").read()
    proj = proj.replace("[application]\n", '[application]\n\nrun/main_loop_type="UxmlProfMain"\n'
                        'run/main_scene="res://bench/empty_prof.tscn"\n', 1)
    open(os.path.join(STAGE, "bench", "empty_prof.tscn"), "w", encoding="utf-8", newline="\n").write(
        '[gd_scene format=3]\n\n[node name="Empty" type="Node"]\n')
    open(os.path.join(STAGE, "project.godot"), "w", encoding="utf-8", newline="\n").write(proj)
    open(os.path.join(STAGE, "export_presets.cfg"), "w", encoding="utf-8", newline="\n").write(
        '[preset.0]\n\nname="Windows Prof"\nplatform="Windows Desktop"\nrunnable=true\n'
        'dedicated_server=false\ncustom_features=""\nexport_filter="all_resources"\n'
        'include_filter="*.uxml,*.uss"\nexclude_filter=""\nexport_path=""\nscript_export_mode=2\n\n'
        '[preset.0.options]\n\nbinary_format/embed_pck=false\nbinary_format/architecture="x86_64"\n'
        'codesign/enable=false\napplication/modify_resources=false\n')
    for _ in range(3):  # --import can exit with 139 (pre-existing); retry
        if subprocess.call([godot, "--headless", "--path", STAGE, "--import"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, timeout=900) == 0:
            break
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    exe = os.path.join(OUT, "GodotProf.exe")
    rc = subprocess.call([godot, "--headless", "--path", STAGE, "--export-release", "Windows Prof", exe],
                         stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, timeout=900)
    if rc != 0 or not os.path.exists(exe):
        sys.exit("export failed (%d)" % rc)
    return exe


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", default=r"B:/dev/games/godot-builds/Godot_v4.7.1-stable_win64_console.exe")
    ap.add_argument("--script", default="res://bench/prof/ops.gd")
    ap.add_argument("--skip-export", action="store_true")
    ap.add_argument("--write-docs", action="store_true")
    ap.add_argument("--timeout", type=int, default=1200)
    ap.add_argument("user", nargs="*")
    a = ap.parse_args()
    if a.write_docs:
        subprocess.call([a.godot, "--headless", "--path", REPO, "-s", "res://bench/unity_compare.gd",
                         "--", "--write-docs=" + os.path.join(STAGE + "-docs")], timeout=600)
    exe = os.path.join(OUT, "GodotProf.exe") if a.skip_export else export(a.godot, a.script)
    x, y = corner(640, 400)
    cmd = [exe, "--position", "%d,%d" % (x, y), "--resolution", "640x400", "--"] + a.user
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    try:
        out, _ = p.communicate(timeout=a.timeout)
    except subprocess.TimeoutExpired:
        p.kill()  # only the process this script started
        out, _ = p.communicate()
    sys.stdout.write(out)
    return p.returncode


if __name__ == "__main__":
    sys.exit(main())
