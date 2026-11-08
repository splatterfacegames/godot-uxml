extends SceneTree
## An op of bench/unity_compare.gd split into the mutation, the timed restyle
## and the settling restyle of the next frame, with the layouts each ran.
##   Godot --headless --path . -s res://bench/prof/split.gd -- --op=<op> [--n=N]
const ROOT := "user://godot_uxml_ucmp"
func _bind(row, i):
	(row.get_native("lname") as Label).text = "Entry %d" % i
	(row.get_native("lval") as Label).text = str(i * 3)
func _initialize() -> void:
	var op := "lv-scroll"
	var n := 60
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--op="): op = a.substr(5)
		elif a.begins_with("--n="): n = int(a.substr(4))
	for k in 3: await process_frame
	var path := "Assets/UI/big.uxml"
	var size := Vector2(1280, 800)
	if op.begins_with("settings"): path = "Assets/UI/wl_settings.uxml"; size = Vector2(1280, 720)
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
		"lv-scroll": f = func(i): d.set_scroll_offset("list", Vector2(0, ((i + 1) * 72) % 200000))
		"lv-rebind": f = func(_i): d.refresh_list("list")
		"hud-hover": f = func(i): d.set_element_state("bar-0", "hover", i % 2 == 0)
		"class": f = func(i): d.set_class("card-20", "card card--selected" if i % 2 == 0 else "card")
		"text":
			var body := d.get_native("card-30-body") as Label
			f = func(i):
				body.text = "short" if i % 2 == 0 else "a much longer body text that wraps over lines"
				d.relayout()
		"dialog-type":
			var body := d.get_native("body") as Label
			var t := "The lighthouse keeper looked at you for a long time before speaking. \"Nobody comes out here in winter,\" she said."
			f = func(i):
				body.text = t.substr(0, 1 + (i * 3) % t.length())
				d.relayout()
		"settings-tab": f = func(i):
			for t in 4:
				d.set_class("page-%d" % t, "page" + ("" if t == i % 4 else " hidden"))
				d.set_class("tab-%d" % t, "tab" + (" tab--on" if t == i % 4 else ""))
	var a := PackedFloat64Array(); var b := PackedFloat64Array(); var c := PackedFloat64Array()
	var lc := PackedFloat64Array()
	for i in n + 4:
		var l0 := d.layout_count
		var t0 := Time.get_ticks_usec()
		f.call(i)
		var t1 := Time.get_ticks_usec()
		d._restyle_now()
		var t2 := Time.get_ticks_usec()
		var l1 := d.layout_count
		d._restyle_now()  # what the next frame's deferred restyle does
		var t3 := Time.get_ticks_usec()
		if i >= 4:
			a.append((t1 - t0) / 1000.0); b.append((t2 - t1) / 1000.0); c.append((t3 - t2) / 1000.0)
			lc.append(float(d.layout_count - l1) * 10 + float(l1 - l0))
		await process_frame
	for arr in [a, b, c, lc]: arr.sort()
	print("%s mutate %.3f restyle %.3f settle %.3f  layouts(settle*10+timed) %s" % [op, a[a.size()/2], b[b.size()/2], c[c.size()/2], lc[lc.size()/2]])
	quit(0)
