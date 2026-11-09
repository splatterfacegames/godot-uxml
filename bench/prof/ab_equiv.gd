extends SceneTree
## Loads the documents of bench/equiv_runtime.gd (and the workloads) with
## UxmlDocument.ab_flag off and on and compares the snapshots of
## equiv_runtime.gd (_snap, _diags) after the load and after the next frames:
## an experiment behind ab_flag must not change a result.
##   Godot --headless --path . -s res://bench/prof/ab_equiv.gd [-- --gdscript]
func _initialize() -> void:
	if OS.get_cmdline_user_args().has("--gdscript"):
		UssCascade.use_native = false
	var eq = load("res://bench/equiv_runtime.gd").new()
	var fails := 0
	var checks := 0
	for pair in [
		["res://tests/fixtures/runtime", "Assets/UI/runtime.uxml"],
		["res://tests/fixtures/runtime", "Assets/UI/review.uxml"],
		["res://tests/fixtures/options", "Assets/UI/Options.uxml"],
		["res://tests/fixtures/origin", "Assets/UI/panel.uxml"],
		[UxmlBenchDir.of("godot_uxml_bench"), "Assets/UI/hud.uxml"],
		[UxmlBenchDir.of("godot_uxml_bench"), "Assets/UI/big.uxml"],
		["res://tests/fixtures/controls", "Assets/UI/controls.uxml"],
		["res://tests/fixtures/editor", "Assets/UI/editor.uxml"],
		["res://tests/fixtures/runtime", "Assets/UI/collections.uxml"],
		["res://tests/fixtures/templates", "Assets/UI/Main.uxml"],
		[UxmlBenchDir.of("godot_uxml_ucmp"), "Assets/UI/wl_settings.uxml"],
		[UxmlBenchDir.of("godot_uxml_ucmp"), "Assets/UI/wl_inventory.uxml"],
		[UxmlBenchDir.of("godot_uxml_ucmp"), "Assets/UI/wl_dialog.uxml"],
		[UxmlBenchDir.of("godot_uxml_ucmp"), "Assets/UI/wl_listview.uxml"],
	]:
		var docs := []
		for flag in [false, true]:
			UxmlDocument.ab_flag = flag
			var d := UxmlDocument.new()
			root.add_child(d)
			d.size = Vector2(1280, 720)
			d.position = Vector2(20000, 20000)
			d.load_document(pair[1], pair[0])
			docs.append(d)
		UxmlDocument.ab_flag = true
		for stage in ["load", "frame 1", "frame 3"]:
			checks += 1
			var sa: Array = eq._snap(docs[0])
			var sb: Array = eq._snap(docs[1])
			var why := ""
			if sa.size() != sb.size():
				why = "control count %d vs %d" % [sa.size(), sb.size()]
			else:
				var shown := 0
				for i in sa.size():
					if sa[i] != sb[i]:
						why += "
   element %d (%s) %s" % [i, sa[i].get("tag"), eq._leaf(sa[i], sb[i], "")]
						shown += 1
						if shown >= (8 if OS.get_cmdline_user_args().has("--verbose") else 1):
							break
			if why.is_empty() and eq._diags(docs[0]) != eq._diags(docs[1]):
				why = "diagnostics differ"
			if not why.is_empty():
				fails += 1
				print("FAIL %s %s: %s" % [pair[1], stage, why])
			for k in (1 if stage == "load" else 2):
				await process_frame
		for d in docs:
			d.queue_free()
		await process_frame
	eq.free()
	print("AB_EQUIV %s: %d checks, %d failures" % ["OK" if fails == 0 else "FAIL", checks, fails])
	quit(0 if fails == 0 else 1)
