#!/usr/bin/env bash
# Build https://godot-uxml.splatterfacegames.com into site/dist:
# the Web export of examples/web_demo (GDScript path, Compatibility
# renderer, no threads) in site/dist/demo, and the static page from
# site/public. Files over the Pages limit move to site/.r2-upload.
#
#   GODOT=<godot 4.7.1> site/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"

rm -rf site/dist site/.r2-upload
mkdir -p site/dist/demo

# project.godot has no main scene; the export needs one. Add it for the
# web feature only and put the file back afterwards.
cp project.godot site/project.godot.orig
trap 'mv -f site/project.godot.orig project.godot' EXIT
python3 - <<'PY'
p = "project.godot"
t = open(p, encoding="utf-8").read()
line = 'run/main_scene.web="res://examples/web_demo/web_demo.tscn"\n'
if line not in t:
    t = t.replace("[application]\n", "[application]\n\n" + line, 1)
open(p, "w", encoding="utf-8", newline="\n").write(t)
PY

# The first import after a checkout can crash; a second one passes.
"$GODOT" --headless --path . --import || "$GODOT" --headless --path . --import
"$GODOT" --headless --path . --export-release Web site/dist/demo/index.html
test -s site/dist/demo/index.pck

cp -R site/public/. site/dist/
node site/prepare_r2_assets.mjs site/dist site/.r2-upload
