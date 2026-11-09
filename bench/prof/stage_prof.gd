extends SceneTree
## One model step of a load under tools/gdprof.py --marked: the step runs
## alone in the marked frames (the model is loaded before).
##   python tools/gdprof.py --marked --godot <exe> -- --headless --path . -s res://bench/prof/stage_prof.gd -- --stage=parts [--doc=big --n=10]
const ROOT := "user://godot_uxml_ucmp"

func _initialize() -> void:
	_run.call_deferred()

func _mark(on: bool) -> void:
	if EngineDebugger.is_active():
		EngineDebugger.send_message("gdprof:on" if on else "gdprof:off", [])

func _run() -> void:
	var n := 10
	var doc := "big"
	var stage := "parts"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--n="): n = int(a.substr(4))
		if a.begins_with("--doc="): doc = a.substr(6)
		if a.begins_with("--stage="): stage = a.substr(8)
	var uc = load("res://bench/unity_compare.gd").new()
	uc._write_docs(ProjectSettings.globalize_path(ROOT + "/Assets/UI"))
	uc.free()
	var res := UxmlResourceResolver.new(ROOT)
	var path := "Assets/UI/%s.uxml" % doc
	for it in n:
		var src: String = res.resolve_text(path)["text"]
		var model: UxmlDocumentModel = null
		if stage != "load_source":
			model = UxmlLoader.load_source(src, path, res)
			UxmlTheme.attach(model, UxmlTheme.DEFAULT, "auto", "dark")
			if stage != "parts":
				UxmlParts.expand(model)
		await process_frame
		_mark(true)
		await process_frame
		match stage:
			"load_source":
				model = UxmlLoader.load_source(src, path, res)
			"parts":
				UxmlParts.expand(model)
			"cascade":
				UssCascade.new(model)
		await process_frame
		_mark(false)
	print("STAGE_PROF_DONE")
	quit(0)
