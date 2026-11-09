extends SceneTree
## Interleaved A/B of UxmlDocument.ab_flag on one load:
##   Godot --headless --path . -s res://bench/prof/ab.gd -- [--doc=big] [--n=20]
static var ROOT: String = UxmlBenchDir.of("godot_uxml_ucmp")

func _initialize() -> void:
	var doc := "big"
	var n := 20
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--doc="): doc = a.substr(6)
		elif a.begins_with("--n="): n = int(a.substr(4))
	var path := "Assets/UI/%s.uxml" % doc
	var size := Vector2(1280, 800) if doc == "big" else Vector2(1280, 720)
	for k in 3: await process_frame
	var s := {false: PackedFloat64Array(), true: PackedFloat64Array()}
	for i in n * 2 + 4:
		var flag := i % 2 == 0
		UxmlDocument.ab_flag = flag
		var t0 := Time.get_ticks_usec()
		var d := UxmlDocument.new()
		root.add_child(d)
		d.size = size
		d.load_document(path, ROOT)
		d._restyle_now()
		var dt := (Time.get_ticks_usec() - t0) / 1000.0
		if i >= 4: s[flag].append(dt)
		root.remove_child(d)
		d.free()
		await process_frame
	for f in [false, true]:
		var a: PackedFloat64Array = s[f]
		a.sort()
		print("ab_flag=%s median %.2f ms" % [f, a[a.size() / 2]])
	quit(0)
