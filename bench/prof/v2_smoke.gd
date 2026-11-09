extends SceneTree
## Loads documents on runtime v2 once and prints the runtime, the fallback
## reason and the handles made (phase 5 smoke test).
##   Godot --headless --path . -s res://bench/prof/v2_smoke.gd [-- --doc=big]
static var ROOT: String = UxmlBenchDir.of("godot_uxml_ucmp")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var docs := ["wl_dialog", "wl_settings", "wl_inventory", "big", "hud", "big-static", "wl_listview"]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--doc="): docs = a.substr(6).split(",")
	var uc = load("res://bench/unity_compare.gd").new()
	uc._write_docs(ProjectSettings.globalize_path(ROOT + "/Assets/UI"))
	uc.free()
	for doc in docs:
		var d := UxmlDocument.new()
		d.runtime = 2
		root.add_child(d)
		d.size = Vector2(1280, 800)
		var t0 := Time.get_ticks_usec()
		UxmlDocumentModel._dbg_handles = {} if OS.get_cmdline_user_args().has("--who") else null
		d.load_document("Assets/UI/%s.uxml" % doc, ROOT)
		if UxmlDocumentModel._dbg_handles != null:
			var dh: Dictionary = UxmlDocumentModel._dbg_handles
			var ks := dh.keys(); ks.sort_custom(func(a, b): return dh[a] > dh[b])
			for k in ks.slice(0, 12): print("   %5d %s" % [dh[k], k])
			UxmlDocumentModel._dbg_handles = null
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		var m: UxmlDocumentModel = d._doc
		var made := 0
		for h in m._handles:
			if h != null: made += 1
		print("%s: runtime %d (%s) %.1f ms, table %s, %d handles of %d rows, %d diagnostics" % [doc, d.get_runtime(), d.runtime_fallback, ms,
			m.table != null, made, (m.table.size() if m.table != null else -1), d.diagnostics.size()])
		for w in d.diagnostics.slice(0, 3):
			print("   ", w.get("message") if w is Dictionary else w)
		root.remove_child(d)
		d.free()
		await process_frame
	print("SMOKE_DONE")
	quit(0)
