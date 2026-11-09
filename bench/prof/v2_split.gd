extends SceneTree
## The model steps of a v2 load of a document, timed without a profiler:
## the native scan, the UxmlElement objects, the rest of load_source, the
## theme, the part trees and the cascade setup.
##   Godot --headless --path . -s res://bench/prof/v2_split.gd [-- --doc=big --n=9]
const ROOT := "user://godot_uxml_ucmp"

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var n := 9
	var doc := "big"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--n="): n = int(a.substr(4))
		if a.begins_with("--doc="): doc = a.substr(6)
	var uc = load("res://bench/unity_compare.gd").new()
	uc._write_docs(ProjectSettings.globalize_path(ROOT + "/Assets/UI"))
	uc.free()
	var res := UxmlResourceResolver.new(ROOT)
	var path := "Assets/UI/%s.uxml" % doc
	var t := {}
	for it in n + 2:
		var src: String = res.resolve_text(path)["text"]
		var t0 := Time.get_ticks_usec()
		var d: Dictionary = ClassDB.class_call_static("UxmlNativeParser", "scan_uxml", src)
		var t1 := Time.get_ticks_usec()
		var parsed := UxmlParser.new().parse(src, path)
		var t2 := Time.get_ticks_usec()
		var model := UxmlLoader.load_source(src, path, res)
		var t3 := Time.get_ticks_usec()
		UxmlTheme.attach(model, UxmlTheme.DEFAULT, "auto", "dark")
		var t4 := Time.get_ticks_usec()
		UxmlParts.expand(model)
		var t5 := Time.get_ticks_usec()
		var c := UssCascade.new(model)
		var t6 := Time.get_ticks_usec()
		var nel := c.els.size()
		if it >= 2:
			for kv in [["native scan", t1 - t0], ["parse (scan + objects)", t2 - t1], ["load_source (parse + sheets + checks)", t3 - t2],
					["theme attach", t4 - t3], ["part trees", t5 - t4], ["cascade setup", t6 - t5]]:
				if not t.has(kv[0]): t[kv[0]] = []
				t[kv[0]].append(kv[1] / 1000.0)
		if it == n + 1:
			print("%s: %d elements in the cascade, %d authored" % [doc, nel, parsed["root"].walk().size()])
	for k in t:
		var a: Array = t[k]
		a.sort()
		print("  %-40s %8.2f ms" % [k, a[a.size() / 2]])
	quit(0)
