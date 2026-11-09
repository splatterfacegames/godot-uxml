extends SceneTree
## ListView scroll of 3 rows on runtime v2 (as bench/unity_compare.gd), timed
## and in the marked frames of tools/gdprof.py --marked.
##   Godot --headless --path . -s res://bench/prof/list_scroll.gd [-- --n=200 --runtime=2]
static var ROOT: String = UxmlBenchDir.of("godot_uxml_ucmp")

func _initialize() -> void:
	_run.call_deferred()

func _mark(on: bool) -> void:
	if EngineDebugger.is_active():
		EngineDebugger.send_message("gdprof:on" if on else "gdprof:off", [])

func _run() -> void:
	var n := 200
	var rt := 2
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--n="): n = int(a.substr(4))
		if a.begins_with("--runtime="): rt = int(a.substr(10))
	var uc = load("res://bench/unity_compare.gd").new()
	uc._write_docs(ProjectSettings.globalize_path(ROOT + "/Assets/UI"))
	uc.free()
	var bind := func(row: UxmlListRow, i: int):
		var ln := row.get_native("lname") as Label
		if ln == null:
			row.set_text("lname", "Entry %d" % i)
			row.set_text("lval", str(i * 3))
		else:
			ln.text = "Entry %d" % i
			(row.get_native("lval") as Label).text = str(i * 3)
	var d := UxmlDocument.new()
	d.runtime = rt
	root.add_child(d)
	d.size = Vector2(1280, 720)
	d.load_document("Assets/UI/wl_listview.uxml", ROOT)
	d.set_list_source("list", 10000, bind)
	for k in 3:
		await process_frame
	var s: Array = []
	var prof := OS.get_cmdline_user_args().has("--native")
	if prof:
		UxmlNative.prof_enable(true)
		UxmlNative.prof_take()
	for i in n + 4:
		if i == 4: _mark(true)
		var t0 := Time.get_ticks_usec()
		d.set_scroll_offset("list", Vector2(0, ((i + 1) * 72) % 200000))
		d._restyle_now()
		if i >= 4: s.append((Time.get_ticks_usec() - t0) / 1000.0)
		await process_frame
	_mark(false)
	if prof:
		var pt: Dictionary = UxmlNative.prof_take()
		for k in pt: print("    native %-24s %8.3f ms/op %6d calls" % [k, pt[k][0] / n, pt[k][1]])
	s.sort()
	print("scroll 3 rows (runtime %d): median %.3f ms" % [d.get_runtime(), s[s.size() / 2]])
	quit(0)
