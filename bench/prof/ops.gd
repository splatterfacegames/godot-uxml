extends SceneTree
## Profiling driver: runs one operation of bench/unity_compare.gd many times
## between gdprof markers (tools/gdprof.py --marked).
##   Godot --path . -s res://bench/prof/ops.gd -- --op=<op> [--n=N]
const ROOT := "user://godot_uxml_ucmp"
var _n := 30

func _mark(on: bool) -> void:
	if ClassDB.class_exists("UxmlNative"):
		if on:
			ClassDB.class_call_static("UxmlNative", "prof_take")
		ClassDB.class_call_static("UxmlNative", "prof_enable", on)
		if not on:
			var p: Dictionary = ClassDB.class_call_static("UxmlNative", "prof_take")
			var ks := p.keys()
			ks.sort_custom(func(a, b): return p[a][0] > p[b][0])
			for k in ks:
				print("  native %-28s %9.2f ms %8d calls" % [k, p[k][0] / _n, p[k][1] / _n])
			print("  (per iteration)")
	if EngineDebugger.is_active():
		EngineDebugger.send_message("gdprof:on" if on else "gdprof:off", [])

func _initialize() -> void:
	var op := "big-load"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--op="): op = a.substr(5)
		elif a.begins_with("--n="): _n = int(a.substr(4))
		elif a == "--gdscript":
			UxmlParser.use_native = false
			UssParser.use_native = false
			UssCascade.use_native = false
	for k in 3: await process_frame
	var t0 := Time.get_ticks_usec()
	match op:
		"big-load": await _load("Assets/UI/big.uxml", Vector2(1280, 800))
		"settings-load": await _load("Assets/UI/wl_settings.uxml", Vector2(1280, 720))
		"inventory-load": await _load("Assets/UI/wl_inventory.uxml", Vector2(1280, 720))
		"dialog-load": await _load("Assets/UI/wl_dialog.uxml", Vector2(1280, 720))
		"lv-load": await _load("Assets/UI/wl_listview.uxml", Vector2(1280, 720), true)
		_:
			await _op(op)
	print("PROF_DONE %.1f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	quit(0)

func _bind(row, i):
	(row.get_native("lname") as Label).text = "Entry %d" % i
	(row.get_native("lval") as Label).text = str(i * 3)

func _load(path: String, size: Vector2, lv := false) -> void:
	var s := PackedFloat64Array()
	for i in _n + 2:
		if i == 2: _mark(true)
		var t0 := Time.get_ticks_usec()
		var d := UxmlDocument.new()
		root.add_child(d)
		d.size = size
		d.load_document(path, ROOT)
		if lv: d.set_list_source("list", 10000, _bind)
		d._restyle_now()
		s.append((Time.get_ticks_usec() - t0) / 1000.0)
		root.remove_child(d)
		d.free()
		await process_frame
	_mark(false)
	s.sort()
	print("median %.3f ms" % s[s.size() / 2])

func _op(op: String) -> void:
	var path := "Assets/UI/big.uxml"
	var size := Vector2(1280, 800)
	if op.begins_with("settings"): path = "Assets/UI/wl_settings.uxml"; size = Vector2(1280, 720)
	if op.begins_with("inv"): path = "Assets/UI/wl_inventory.uxml"; size = Vector2(1280, 720)
	if op.begins_with("dialog"): path = "Assets/UI/wl_dialog.uxml"; size = Vector2(1280, 720)
	if op.begins_with("lv"): path = "Assets/UI/wl_listview.uxml"; size = Vector2(1280, 720)
	if op.begins_with("hud"): path = "Assets/UI/hud.uxml"; size = Vector2(640, 360)
	var d := UxmlDocument.new()
	root.add_child(d)
	d.size = size
	d.load_document(path, ROOT)
	if op.begins_with("lv"): d.set_list_source("list", 10000, _bind)
	for k in 3: await process_frame
	var f: Callable
	match op:
		"noop": f = func(_i): pass
		"hover-button": f = func(i): d.set_element_state("card-7-ok", "hover", i % 2 == 0)
		"hover-card": f = func(i): d.set_element_state("card-12", "hover", i % 2 == 0)
		"class": f = func(i): d.set_class("card-20", "card card--selected" if i % 2 == 0 else "card")
		"text":
			var body := d.get_native("card-30-body") as Label
			f = func(i):
				body.text = "short" if i % 2 == 0 else "a much longer body text that wraps over lines"
				d.relayout()
		"resize": f = func(i): d.size = Vector2(1024, 720) if i % 2 == 0 else Vector2(1280, 800)
		"hud-frame":
			var labels: Array = []
			for i in 8: labels.append(d.get_native("val-%d" % i))
			f = func(i):
				for k in labels.size(): (labels[k] as Label).text = str((i * 37 + k * 101) % 100000)
				d.relayout()
		"settings-tab": f = func(i):
			for t in 4:
				d.set_class("page-%d" % t, "page" + ("" if t == i % 4 else " hidden"))
				d.set_class("tab-%d" % t, "tab" + (" tab--on" if t == i % 4 else ""))
		"settings-hover": f = func(i): d.set_element_state("row-0-%d" % (i % 12), "hover", i % 2 == 0)
		"inv-select": f = func(i):
			d.set_class("slot-%d" % (i % 80), "slot rarity-%d slot--selected" % (i % 4))
			d.set_class("slot-%d" % ((i + 79) % 80), "slot rarity-%d" % ((i + 79) % 4))
		"inv-count": f = func(i):
			(d.get_native("count-%d" % (i % 80)) as Label).text = str(i * 7 % 999)
			d.relayout()
		"dialog-type":
			var body := d.get_native("body") as Label
			var t := "The lighthouse keeper looked at you for a long time before speaking. \"Nobody comes out here in winter,\" she said."
			f = func(i):
				body.text = t.substr(0, 1 + (i * 3) % t.length())
				d.relayout()
		"lv-scroll": f = func(i): d.set_scroll_offset("list", Vector2(0, ((i + 1) * 72) % 200000))
		"lv-rebind": f = func(_i): d.refresh_list("list")
	var s := PackedFloat64Array()
	for i in _n + 4:
		if i == 4: _mark(true)
		var t0 := Time.get_ticks_usec()
		f.call(i)
		d._restyle_now()
		s.append((Time.get_ticks_usec() - t0) / 1000.0)
		await process_frame
	_mark(false)
	s.sort()
	print("median %.3f ms" % s[s.size() / 2])
