extends SceneTree
## godot-uxml side of the comparison with Unity UI Toolkit (see
## tools/unity-bench and docs/performance.md, "Native core vs Unity UI
## Toolkit"). Run it through tools/unity-bench/run.py, which interleaves it
## with the Unity player.
##
##   Godot --path <project> -s res://bench/unity_compare.gd -- --out=<file.json> [--iters=N]
##   Godot --headless --path <project> -s res://bench/unity_compare.gd -- --write-docs=<dir>
##
## --write-docs writes the documents (the generators of bench.gd and
## workloads.gd, unchanged) to <dir> and quits: run.py copies them into the
## Unity project, so both sides load the same files.
##
## Each op: warm-up, then N iterations. An iteration mutates, then forces
## the restyle and layout synchronously (UxmlDocument._restyle_now()),
## inside the timed region; the frame after it is not timed. The boundary is
## "laid out and ready to draw": the Controls have their styles, sizes and
## positions. Drawing is not in it (Unity: the panel update without the
## repaint, the same boundary). Times are CPU wall time (Time.get_ticks_usec).
##
## Op names are the same in tools/unity-bench/Assets/Scripts/UiBench.cs.

const Bench := preload("res://bench/bench.gd")
const Workloads := preload("res://bench/workloads.gd")
const ROOT := "user://godot_uxml_ucmp"

var _iters := 60
var _rows: Array = []


func _initialize() -> void:
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--write-docs="):
			_write_docs(a.substr(13))
			quit(0)
			return
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--iters="):
			_iters = int(a.substr(8))
		elif a.begins_with("--runtime="):
			# Runtime v2 for the documents it covers (the others stay on v1).
			UxmlDocument.default_runtime = int(a.substr(10))
	_write_docs(ProjectSettings.globalize_path(ROOT + "/Assets/UI"))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	OS.low_processor_usage_mode = false
	_park_window()
	for k in 10:
		await process_frame
	await _big()
	await _hud()
	await _settings()
	await _inventory()
	await _dialog()
	await _listview()
	await _frames()
	var meta := {
		"side": "godot",
		"engine": Engine.get_version_info()["string"],
		"debug_build": OS.is_debug_build(),
		"native_core": ClassDB.class_exists("UxmlNativeCascade"),
		"runtime": UxmlDocument.default_runtime if UxmlDocument.default_runtime != 0 else 1,
		"executable": OS.get_executable_path().get_file(),
		"cpu": OS.get_processor_name(),
		"os": OS.get_name(),
	}
	var data := {"meta": meta, "rows": _rows}
	if not out.is_empty():
		var f := FileAccess.open(out, FileAccess.WRITE)
		f.store_string(JSON.stringify(data, " "))
		f.close()
	print("UCMP_COMPLETE")
	quit(0)


## A small window (640x400) in the bottom-right corner of the work area,
## without focus, so that runs stay out of the way (Unity: the same, in
## UiBench.cs). The documents keep their own fixed sizes, so the layout
## work does not change; the frame rows draw into this window on both sides.
func _park_window() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var size := Vector2i(640, 400)
	var area := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_position(area.position + area.size - size - Vector2i(8, 40))


# ---------------------------------------------------------------------------
# Documents

func _write_docs(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var b = Bench.new()
	var w = Workloads.new()
	var files := {
		"big.uxml": b._big_uxml(),
		"big-static.uxml": b._big_static_uxml(),
		"static.uss": b._static_uss(),
		"base.uss": b._base_uss(),
		"components.uss": b._components_uss(),
		"theme.uss": b._theme_uss(),
		"hud.uxml": b._hud_uxml(),
		"hud.uss": b._hud_uss(),
		"wl.uss": w._uss(),
		"wl_settings.uxml": w._settings_uxml(),
		"wl_inventory.uxml": w._inventory_uxml(),
		"wl_dialog.uxml": w._dialog_uxml(),
		"wl_listview.uxml": w._head() + '  <ui:VisualElement name="screen" class="screen">\n    <ui:ListView name="list" class="list" fixed-item-height="24" item-template="wl_row.uxml" show-alternating-row-backgrounds="ContentOnly" />\n  </ui:VisualElement>\n</ui:UXML>',
		"wl_row.uxml": '<ui:UXML xmlns:ui="UnityEngine.UIElements">\n  <ui:VisualElement class="lrow">\n    <ui:Label name="lname" class="lname" text="" />\n    <ui:Label name="lval" class="lval" text="" />\n  </ui:VisualElement>\n</ui:UXML>',
	}
	b.free()
	w.free()
	for fn in files:
		var f := FileAccess.open(dir.path_join(fn), FileAccess.WRITE)
		f.store_string(files[fn])
		f.close()


# ---------------------------------------------------------------------------
# Timing

func _record(op: String, s: PackedFloat64Array) -> void:
	_rows.append({"op": op, "samples": Array(s)})
	var c := s.duplicate()
	c.sort()
	print("  %-40s n=%-4d median %9.3f ms" % [op, c.size(), c[c.size() / 2]])


func _new_doc(size: Vector2) -> UxmlDocument:
	var d := UxmlDocument.new()
	root.add_child(d)
	d.size = size
	return d


func _free_doc(d: UxmlDocument) -> void:
	root.remove_child(d)
	d.free()


## Load: a new document each iteration, laid out (timed), then freed
## (not timed). `extra` runs inside the timed region after the load.
func _time_load(op: String, path: String, size: Vector2, n: int, extra := Callable()) -> void:
	var s := PackedFloat64Array()
	for i in n + 2:
		var t0 := Time.get_ticks_usec()
		var d := _new_doc(size)
		d.load_document(path, ROOT)
		if extra.is_valid():
			extra.call(d)
		d._restyle_now()
		var dt := (Time.get_ticks_usec() - t0) / 1000.0
		if i >= 2:
			s.append(dt)
		_free_doc(d)
		await process_frame
	_record(op, s)


## Mutate and lay out (timed), then one frame (not timed).
func _time_op(op: String, d: UxmlDocument, mutate: Callable, n := -1) -> void:
	if n < 0:
		n = _iters
	var s := PackedFloat64Array()
	for i in n + 4:
		var t0 := Time.get_ticks_usec()
		mutate.call(i)
		d._restyle_now()
		var dt := (Time.get_ticks_usec() - t0) / 1000.0
		if i >= 4:
			s.append(dt)
		await process_frame
	_record(op, s)


# ---------------------------------------------------------------------------
# Workloads

func _big() -> void:
	await _time_load("big: load", "Assets/UI/big.uxml", Vector2(1280, 800), maxi(10, _iters / 4))
	# Load until the end of the first frame drawn after it (the draw included).
	var s := PackedFloat64Array()
	for i in maxi(10, _iters / 4) + 2:
		var t0 := Time.get_ticks_usec()
		var f := _new_doc(Vector2(1280, 800))
		f.load_document("Assets/UI/big.uxml", ROOT)
		await process_frame
		var dt := (Time.get_ticks_usec() - t0) / 1000.0
		if i >= 2:
			s.append(dt)
		_free_doc(f)
		await process_frame
	_record("big: load + first frame", s)
	var d := _new_doc(Vector2(1280, 800))
	d.load_document("Assets/UI/big.uxml", ROOT)
	for k in 3:
		await process_frame
	print("  check card-0: %s, card-149: %s" % [d.get_element_rect(d.get_element_model("card-0")), d.get_element_rect(d.get_element_model("card-149"))])
	await _time_op("big: hover toggle (button)", d, func(i):
		d.set_element_state("card-7-ok", "hover", i % 2 == 0))
	await _time_op("big: hover toggle (card, descendant selector)", d, func(i):
		d.set_element_state("card-12", "hover", i % 2 == 0))
	await _time_op("big: restyle, no change", d, func(_i): pass)
	await _time_op("big: class change (card)", d, func(i):
		d.set_class("card-20", "card card--selected" if i % 2 == 0 else "card"))
	# Runtime v2 draws a Label with no Control: set_text.
	var body := d.get_native("card-30-body") as Label
	await _time_op("big: label text change + layout", d, func(i):
		var t := "short" if i % 2 == 0 else "a much longer body text that wraps over lines"
		if body == null:
			d.set_text("card-30-body", t)
		else:
			body.text = t
		d.relayout())
	await _time_op("big: resize", d, func(i):
		d.size = Vector2(1024, 720) if i % 2 == 0 else Vector2(1280, 800))
	_free_doc(d)
	await _big_static()


## The big document with static elements in place of its controls
## (bench.gd _big_static_uxml): runtime v2 draws all of it.
func _big_static() -> void:
	await _time_load("big-static: load", "Assets/UI/big-static.uxml", Vector2(1280, 800), maxi(10, _iters / 4))
	var s := PackedFloat64Array()
	for i in maxi(10, _iters / 4) + 2:
		var t0 := Time.get_ticks_usec()
		var f := _new_doc(Vector2(1280, 800))
		f.load_document("Assets/UI/big-static.uxml", ROOT)
		await process_frame
		var dt := (Time.get_ticks_usec() - t0) / 1000.0
		if i >= 2:
			s.append(dt)
		_free_doc(f)
		await process_frame
	_record("big-static: load + first frame", s)
	var d := _new_doc(Vector2(1280, 800))
	d.load_document("Assets/UI/big-static.uxml", ROOT)
	for k in 3:
		await process_frame
	print("  big-static: runtime %d%s; check card-0: %s, card-149: %s" % [d.get_runtime(),
		"" if d.runtime_fallback.is_empty() else " (" + d.runtime_fallback + ")",
		d.get_element_rect(d.get_element_model("card-0")), d.get_element_rect(d.get_element_model("card-149"))])
	_free_doc(d)


func _hud() -> void:
	await _time_load("hud: load", "Assets/UI/hud.uxml", Vector2(640, 360), _iters)
	var d := _new_doc(Vector2(640, 360))
	d.load_document("Assets/UI/hud.uxml", ROOT)
	for k in 3:
		await process_frame
	var labels: Array = []
	for i in 8:
		labels.append(d.get_native("val-%d" % i))
	await _time_op("hud: frame, 8 labels + layout", d, func(i):
		for k in labels.size():
			if d.get_runtime() == 2:
				d.set_text("val-%d" % k, str((i * 37 + k * 101) % 100000))
			else:
				(labels[k] as Label).text = str((i * 37 + k * 101) % 100000)
		d.relayout(), _iters * 3)
	await _time_op("hud: hover toggle", d, func(i):
		d.set_element_state("bar-0", "hover", i % 2 == 0), _iters * 3)
	_free_doc(d)


func _settings() -> void:
	await _time_load("settings: load", "Assets/UI/wl_settings.uxml", Vector2(1280, 720), _iters / 2)
	var d := _new_doc(Vector2(1280, 720))
	d.load_document("Assets/UI/wl_settings.uxml", ROOT)
	for k in 3:
		await process_frame
	await _time_op("settings: switch tab", d, func(i):
		for t in 4:
			d.set_class("page-%d" % t, "page" + ("" if t == i % 4 else " hidden"))
			d.set_class("tab-%d" % t, "tab" + (" tab--on" if t == i % 4 else "")))
	await _time_op("settings: hover row", d, func(i):
		d.set_element_state("row-0-%d" % (i % 12), "hover", i % 2 == 0))
	_free_doc(d)


func _inventory() -> void:
	await _time_load("inventory: load", "Assets/UI/wl_inventory.uxml", Vector2(1280, 720), _iters / 2)
	var d := _new_doc(Vector2(1280, 720))
	d.load_document("Assets/UI/wl_inventory.uxml", ROOT)
	for k in 3:
		await process_frame
	await _time_op("inventory: hover slot", d, func(i):
		d.set_element_state("slot-%d" % (i % 80), "hover", true)
		d.set_element_state("slot-%d" % ((i + 79) % 80), "hover", false))
	await _time_op("inventory: select slot", d, func(i):
		d.set_class("slot-%d" % (i % 80), "slot rarity-%d slot--selected" % (i % 4))
		d.set_class("slot-%d" % ((i + 79) % 80), "slot rarity-%d" % ((i + 79) % 4)))
	await _time_op("inventory: count change + layout", d, func(i):
		if d.get_runtime() == 2:
			d.set_text("count-%d" % (i % 80), str(i * 7 % 999))
		else:
			(d.get_native("count-%d" % (i % 80)) as Label).text = str(i * 7 % 999)
		d.relayout())
	_free_doc(d)


const DIALOG := "The lighthouse keeper looked at you for a long time before speaking. \"Nobody comes out here in winter,\" she said, \"not unless they are running from something, or towards it.\""


func _dialog() -> void:
	await _time_load("dialog: load", "Assets/UI/wl_dialog.uxml", Vector2(1280, 720), _iters / 2)
	var d := _new_doc(Vector2(1280, 720))
	d.load_document("Assets/UI/wl_dialog.uxml", ROOT)
	for k in 3:
		await process_frame
	var body := d.get_native("body") as Label
	await _time_op("dialog: typewriter character + layout", d, func(i):
		var t := DIALOG.substr(0, 1 + (i * 3) % DIALOG.length())
		if body == null:
			d.set_text("body", t)  # runtime v2: the core draws the Label
		else:
			body.text = t
		d.relayout(), _iters * 2)
	await _time_op("dialog: hover choice", d, func(i):
		d.set_element_state("choice-%d" % (i % 4), "hover", i % 2 == 0))
	_free_doc(d)


func _listview() -> void:
	var bind := func(row: UxmlListRow, i: int):
		(row.get_native("lname") as Label).text = "Entry %d" % i
		(row.get_native("lval") as Label).text = str(i * 3)
	await _time_load("listview: load, 10,000 items", "Assets/UI/wl_listview.uxml", Vector2(1280, 720), _iters / 2,
		func(d: UxmlDocument): d.set_list_source("list", 10000, bind))
	var d := _new_doc(Vector2(1280, 720))
	d.load_document("Assets/UI/wl_listview.uxml", ROOT)
	d.set_list_source("list", 10000, bind)
	for k in 3:
		await process_frame
	await _time_op("listview: scroll 3 rows", d, func(i):
		d.set_scroll_offset("list", Vector2(0, ((i + 1) * 72) % 200000)), _iters * 2)
	await _time_op("listview: rebind visible items", d, func(_i):
		d.refresh_list("list"))
	_free_doc(d)


## Frame time with the renderer, vsync off, no cap: an empty scene and the
## big document, idle. Wall time between frames.
func _frames() -> void:
	await _frame_series("frame: empty scene")
	var d := _new_doc(Vector2(1280, 800))
	d.load_document("Assets/UI/big.uxml", ROOT)
	for k in 30:
		await process_frame
	await _frame_series("frame: big document, idle")
	_free_doc(d)


func _frame_series(op: String) -> void:
	for k in 30:
		await process_frame
	var s := PackedFloat64Array()
	var t0 := Time.get_ticks_usec()
	for k in 300:
		await process_frame
		var t1 := Time.get_ticks_usec()
		s.append((t1 - t0) / 1000.0)
		t0 = t1
	_record(op, s)
