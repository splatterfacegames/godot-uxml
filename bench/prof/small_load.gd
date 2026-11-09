extends SceneTree
## The fixed cost of a small v2 load, step by step (ms, median of n).
##   Godot --headless --path . -s res://bench/prof/small_load.gd [-- --doc=wl_dialog --n=40]
static var ROOT: String = UxmlBenchDir.of("godot_uxml_ucmp")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var n := 40
	var doc := "wl_dialog"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--n="): n = int(a.substr(4))
		if a.begins_with("--doc="): doc = a.substr(6)
	var uc = load("res://bench/unity_compare.gd").new()
	uc._write_docs(ProjectSettings.globalize_path(ROOT + "/Assets/UI"))
	uc.free()
	var path := "Assets/UI/%s.uxml" % doc
	var t := {}
	for i in n + 3:
		var marks := []
		var t0 := Time.get_ticks_usec()
		var res := UxmlResourceResolver.new(ROOT)
		marks.append(["resolver", Time.get_ticks_usec()])
		var txt: Dictionary = res.resolve_text(path)
		marks.append(["resolve_text", Time.get_ticks_usec()])
		UxmlLoader.parse_table = true
		var m := UxmlLoader.load_source(txt["text"], txt["path"], res)
		marks.append(["load_source", Time.get_ticks_usec()])
		UxmlTheme.attach(m, UxmlTheme.DEFAULT, "auto", "dark")
		marks.append(["theme attach", Time.get_ticks_usec()])
		UxmlParts.expand(m)
		marks.append(["parts", Time.get_ticks_usec()])
		var c := UssCascade.new(m)
		marks.append(["cascade new", Time.get_ticks_usec()])
		var d := UxmlDocument.new()
		d.runtime = 2
		root.add_child(d)
		d.size = Vector2(1280, 800)
		marks.append(["doc new + add_child", Time.get_ticks_usec()])
		d.load_document(path, ROOT)
		marks.append(["load_document (all)", Time.get_ticks_usec()])
		root.remove_child(d)
		d.free()
		marks.append(["remove + free", Time.get_ticks_usec()])
		if i >= 3:
			var prev := t0
			for mk in marks:
				if not t.has(mk[0]): t[mk[0]] = []
				t[mk[0]].append((mk[1] - prev) / 1000.0)
				prev = mk[1]
		await process_frame
	for k in t:
		var a: Array = t[k]; a.sort()
		print("  %-24s %7.3f ms" % [k, a[a.size() / 2]])
	quit(0)
