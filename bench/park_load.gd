extends SceneTree
## Load cost of parking hidden subtrees (UxmlDocument.park_hidden), A/B in
## one process: each document is loaded 60 times (12 for the large ones)
## after the main loop started, alternating parked / not parked, so both
## sides see the same machine load. Prints the median ms of each side and
## the controls in the tree / built after a parked load.
##
##   Godot --headless --path <project> -s res://bench/park_load.gd [-- --no-theme]
##
## The user:// documents come from bench/bench.gd and bench/workloads.gd.
func _initialize() -> void:
	await process_frame
	await process_frame
	var no_theme := OS.get_cmdline_user_args().has("--no-theme")
	var cases := [
		["res://tests/fixtures/menu", "Assets/UI/Menu.uxml"],
		["res://tests/fixtures/options", "Assets/UI/Options.uxml"],
		["res://tests/fixtures/runtime", "Assets/UI/runtime.uxml"],
		["res://tests/fixtures/runtime", "Assets/UI/review.uxml"],
		[UxmlBenchDir.of("godot_uxml_bench"), "Assets/UI/wl_settings.uxml"],
		[UxmlBenchDir.of("godot_uxml_bench"), "Assets/UI/wl_inventory.uxml"],
		[UxmlBenchDir.of("godot_uxml_bench"), "Assets/UI/wl_list.uxml"],
		[UxmlBenchDir.of("godot_uxml_bench"), "Assets/UI/big.uxml"],
		["res://tests/fixtures/parking", "Assets/UI/parking.uxml"],
	]
	for cs in cases:
		if not FileAccess.file_exists(cs[0].path_join(cs[1])):
			continue
		var n := 60 if not cs[1].contains("big") and not cs[1].contains("wl_list") else 12
		var s := PackedFloat64Array()
		var s_off := PackedFloat64Array()
		var in_tree := 0
		var built := 0
		for i in n:
			var d := UxmlDocument.new()
			if no_theme:
				d.theme_path = ""
			root.add_child(d)
			d.size = Vector2(1280, 720)
			UxmlDocument.park_hidden = i % 2 == 0
			var t0 := Time.get_ticks_usec()
			d.load_document(cs[1], cs[0])
			(s if i % 2 == 0 else s_off).append((Time.get_ticks_usec() - t0) / 1000.0)
			if i == 0:
				in_tree = _count(d) - 2
				built = d._controls.size() - 1
				for el in d._controls:
					var c: Control = d._controls[el]
					for ch in c.get_children():
						if not d._el_of.has(ch):
							built += 1
			await process_frame
			root.remove_child(d)
			d.free()
		s.sort()
		s_off.sort()
		print("PARK_LOAD %s park %.3f nopark %.3f ratio %.3f in_tree %d built %d" % [cs[1].get_file(), s[s.size() / 2], s_off[s_off.size() / 2], s[s.size() / 2] / s_off[s_off.size() / 2], in_tree, built])
	UxmlDocument.park_hidden = true
	quit(0)

func _count(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count(ch)
	return c
