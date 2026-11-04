#!/usr/bin/env python3
"""Guarded headless test runner for godot-uxml.

A bare `godot --script` invocation cannot be trusted:
  - Godot exits 0 even when the run aborts on a SCRIPT ERROR.
  - A run that never reaches quit() hangs forever.
  - The Windows *_console.exe is a launcher: killing it alone orphans the
    child engine process, which then keeps running.

This runner therefore:
  1. --check-only compiles every GDScript file and inspects BOTH the
     process exit status and the output (SCRIPT ERROR / Parse Error).
  2. Runs the suite with a bounded timeout; on timeout it kills the whole
     process tree (taskkill /T /F on Windows, process-group kill on POSIX).
  3. Requires the SUITE_COMPLETE marker and a PASS summary; any SCRIPT
     ERROR / Parse Error / generic engine "ERROR:" line / FAIL line or
     nonzero exit fails the run. Structured runtime diagnostics are the
     supported way to report missing resources — an engine ERROR means
     something reached a loader unchecked.

Requires: Python 3 on PATH. Run via tests/run_tests.sh.
Overrides: --godot, --project, --script, --timeout.
"""

import argparse
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

ERROR_TOKENS = ("SCRIPT ERROR", "Parse Error")


def engine_errors(out):
    """Lines that are engine-level errors, not test output.

    Godot prints `ERROR: ...` (and `USER ERROR:`/`SCRIPT ERROR:`) for
    runtime failures such as Image.load on a missing file. Test lines
    never start with ERROR, so a left-margin ERROR token is unambiguous.
    """
    return [
        line for line in out.splitlines()
        if line.lstrip().startswith(("ERROR:", "USER ERROR:", "SCRIPT ERROR:"))
    ]


def fail(msg, code=1):
    print("WRAPPER FAIL: %s" % msg)
    sys.exit(code)


def kill_tree(proc):
    """Kill proc and every descendant it may have spawned."""
    if os.name == "nt":
        # taskkill /T walks the whole tree; the Godot console launcher
        # spawns a child engine process that must not be orphaned.
        subprocess.run(
            ["taskkill", "/F", "/T", "/PID", str(proc.pid)],
            capture_output=True,
        )
    else:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            proc.kill()


def run_bounded(cmd, timeout, label):
    """Run cmd; return (exit_code, output). Timeout -> kills tree, (-9, out)."""
    popen_kwargs = dict(
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
    )
    if os.name != "nt":
        popen_kwargs["start_new_session"] = True
    proc = subprocess.Popen(cmd, **popen_kwargs)
    try:
        out, _ = proc.communicate(timeout=timeout)
        return proc.returncode, out or ""
    except subprocess.TimeoutExpired:
        kill_tree(proc)
        out, _ = proc.communicate()
        print("WRAPPER FAIL: %s timed out after %ds (process tree killed)" % (label, timeout))
        return -9, out or ""


def res_path(project, path):
    return "res://" + path.relative_to(project).as_posix()


def main():
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", default=os.environ.get("GODOT", "godot"),
                    help="Godot executable (default: $GODOT or 'godot' on PATH)")
    ap.add_argument("--project", default=os.environ.get("PROJECT", str(here.parent)),
                    help="project root (default: parent of this script's directory)")
    ap.add_argument("--script", default=os.environ.get("TEST_SCRIPT", "res://tests/run_tests.gd"),
                    help="suite entry point (default: res://tests/run_tests.gd)")
    ap.add_argument("--timeout", type=int,
                    default=int(os.environ.get("SUITE_TIMEOUT", "120")),
                    help="seconds before each Godot run is killed (default: 120)")
    args = ap.parse_args()

    project = Path(args.project).resolve()
    if not (project / "project.godot").exists():
        fail("no project.godot under %s" % project)

    scripts = sorted(
        list((project / "addons").rglob("*.gd")) + list((project / "tests").glob("*.gd"))
    )
    if not scripts:
        fail("no .gd scripts found under %s" % project)

    # 1) Compile every script; check exit status AND output.
    for f in scripts:
        code, out = run_bounded(
            [args.godot, "--headless", "--path", str(project),
             "--check-only", "--script", res_path(project, f)],
            args.timeout, "compile check",
        )
        if code == -9:
            sys.exit(6)
        bad = any(t in out for t in ERROR_TOKENS)
        if code != 0 or bad:
            sys.stdout.write(out)
            fail("compile check failed for %s (exit %d)" % (f.name, code), 2)
    print("COMPILE OK: %d scripts" % len(scripts))

    # 2) Run the suite with a timeout.
    started = time.time()
    code, out = run_bounded(
        [args.godot, "--headless", "--path", str(project), "--script", args.script],
        args.timeout, "test suite",
    )
    sys.stdout.write(out)
    if code == -9:
        sys.exit(6)
    if any(t in out for t in ERROR_TOKENS):
        fail("script errors in suite output", 3)
    generic = engine_errors(out)
    if generic:
        fail("unexpected engine ERROR lines in suite output:\n    %s"
             % "\n    ".join(generic[:10]), 3)
    if "SUITE_COMPLETE" not in out:
        fail("suite did not reach SUITE_COMPLETE (aborted mid-run?)", 4)
    if "\nPASS:" not in "\n" + out:
        fail("suite did not report a PASS summary", 5)
    if any(line.startswith("FAIL") for line in out.splitlines()):
        fail("individual checks failed", 7)
    if code != 0:
        fail("Godot exited %d" % code, 8)
    print("SUITE OK (%ds)" % int(time.time() - started))
    sys.exit(0)


if __name__ == "__main__":
    main()
