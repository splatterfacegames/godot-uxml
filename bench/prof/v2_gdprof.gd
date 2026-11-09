extends SceneTree
## Loads of a document on runtime v2 in the marked frames of
## tools/gdprof.py --marked (the function-level profile of the GDScript
## steps of a v2 load).
##   python tools/gdprof.py --marked --godot <exe> -- --headless --path . -s res://bench/prof/v2_gdprof.gd -- [--doc=big --n=8]
static var ROOT: String = UxmlBenchDir.of("godot_uxml_ucmp")

func _initialize() -> void:
	_run.call_deferred()

func _mark(on: bool) -> void:
	if EngineDebugger.is_active():
		EngineDebugger.send_message("gdprof:on" if on else "gdprof:off", [])

func _run() -> void:
	var n := 8
	var doc := "big"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--n="): n = int(a.substr(4))
		if a.begins_with("--doc="): doc = a.substr(6)
	var uc = load("res://bench/unity_compare.gd").new()
	uc._write_docs(ProjectSettings.globalize_path(ROOT + "/Assets/UI"))
	uc.free()
	for i in n + 2:
		var d := UxmlDocument.new()
		d.runtime = 2
		root.add_child(d)
		d.size = Vector2(1280, 800)
		await process_frame
		if i >= 2: _mark(true)
		d.load_document("Assets/UI/%s.uxml" % doc, ROOT)
		await process_frame
		if i >= 2: _mark(false)
		root.remove_child(d)
		d.free()
		await process_frame
	quit(0)
