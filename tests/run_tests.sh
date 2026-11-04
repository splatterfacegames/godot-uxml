#!/usr/bin/env bash
# Guarded test runner for godot-uxml. Thin shim over tests/run_tests.py —
# the heavy lifting (bounded subprocesses, process-tree kill on timeout,
# output inspection) lives there because it cannot be done reliably in
# portable shell. Requires Python 3 on PATH.
#
# Windows Git Bash:
#   GODOT="B:/dev/games/godot-builds/Godot_v4.7.1-stable_win64_console.exe" \
#       bash tests/run_tests.sh
# Overrides: GODOT (executable, default: 'godot' on PATH),
#            PROJECT (project root, default: parent of tests/),
#            TEST_SCRIPT, SUITE_TIMEOUT.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PY=""
for cand in python python3 py; do
	if command -v "$cand" >/dev/null 2>&1; then PY="$cand"; break; fi
done
if [ -z "$PY" ]; then
	echo "WRAPPER FAIL: Python 3 not found on PATH" >&2
	exit 90
fi

ARGS=(--godot "${GODOT:-godot}" --project "${PROJECT:-$(cd "$SCRIPT_DIR/.." && pwd)}")
[ -n "${TEST_SCRIPT:-}" ] && ARGS+=(--script "$TEST_SCRIPT")
[ -n "${SUITE_TIMEOUT:-}" ] && ARGS+=(--timeout "$SUITE_TIMEOUT")

"$PY" "$SCRIPT_DIR/run_tests.py" "${ARGS[@]}"
exit $?
