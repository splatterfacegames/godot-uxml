#!/usr/bin/env python3
"""Build the godot-uxml native core (release) and install it into the addon.

    python native/build.py            # host target
    python native/build.py --target x86_64-pc-windows-msvc

Without the binary the addon runs on its GDScript implementation; with it,
UssCascade (and later stages) delegate to the native backend.
"""
import argparse
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BIN = HERE.parent / "addons" / "godot_uxml" / "bin"
OUT = {  # rust target triple -> (artifact, installed name)
    "x86_64-pc-windows-msvc": ("godot_uxml_native.dll", "godot_uxml_native.windows.x86_64.dll"),
    "x86_64-unknown-linux-gnu": ("libgodot_uxml_native.so", "libgodot_uxml_native.linux.x86_64.so"),
    "aarch64-apple-darwin": ("libgodot_uxml_native.dylib", "libgodot_uxml_native.macos.arm64.dylib"),
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default="x86_64-pc-windows-msvc")
    a = ap.parse_args()
    if a.target not in OUT:
        print("unsupported target %s" % a.target)
        return 1
    r = subprocess.run(["cargo", "build", "--release", "--target", a.target], cwd=HERE)
    if r.returncode != 0:
        return r.returncode
    art, name = OUT[a.target]
    BIN.mkdir(parents=True, exist_ok=True)
    shutil.copy2(HERE / "target" / a.target / "release" / art, BIN / name)
    print("installed %s" % (BIN / name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
