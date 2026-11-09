extends SceneTree
## The table parse of load_source against the object parse (ms, median).
static var ROOT: String = UxmlBenchDir.of("godot_uxml_ucmp")

func _initialize() -> void:
	var uc = load("res://bench/unity_compare.gd").new()
	uc._write_docs(ProjectSettings.globalize_path(ROOT + "/Assets/UI"))
	uc.free()
	var res := UxmlResourceResolver.new(ROOT)
	var src: String = res.resolve_text("Assets/UI/big.uxml")["text"]
	var t := {"table": [], "objects": [], "scan": [], "model.parse": []}
	for i in 12:
		var t0 := Time.get_ticks_usec()
		UxmlLoader.parse_table = true
		UxmlLoader.load_source(src, "Assets/UI/big.uxml", res)
		var t1 := Time.get_ticks_usec()
		UxmlLoader.load_source(src, "Assets/UI/big.uxml", res)
		var t2 := Time.get_ticks_usec()
		ClassDB.class_call_static("UxmlNativeParser", "scan_uxml", src)
		var t3 := Time.get_ticks_usec()
		ClassDB.class_call_static("UxmlNativeModel", "parse", src)
		var t4 := Time.get_ticks_usec()
		if i >= 2:
			t["table"].append((t1 - t0) / 1000.0); t["objects"].append((t2 - t1) / 1000.0)
			t["scan"].append((t3 - t2) / 1000.0); t["model.parse"].append((t4 - t3) / 1000.0)
	for k in t:
		var a: Array = t[k]; a.sort()
		print("%-12s %7.2f ms" % [k, a[a.size() / 2]])
	quit(0)
