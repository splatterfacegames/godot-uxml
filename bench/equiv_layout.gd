extends SceneTree
## Layout equivalence: optimized UxmlFlexLayout vs the original
## (bench/ref/ref_flex_layout.gd) on live documents with the real control
## measurer, at several host sizes. Control sizes are snapshotted and
## restored between the two runs so both see identical measurer state.

var _fails := 0
var _checks := 0


func _initialize() -> void:
	for pair in [
		["res://tests/fixtures/runtime", "Assets/UI/runtime.uxml"],
		["res://tests/fixtures/runtime", "Assets/UI/review.uxml"],
		["res://tests/fixtures/options", "Assets/UI/Options.uxml"],
		["res://tests/fixtures/menu", "Assets/UI/Menu.uxml"],
		["res://tests/fixtures/origin", "Assets/UI/panel.uxml"],
		["user://godot_uxml_bench", "Assets/UI/big.uxml"],
		["user://godot_uxml_bench", "Assets/UI/hud.uxml"],
	]:
		var d := UxmlDocument.new()
		root.add_child(d)
		d.size = Vector2(800, 600)
		d.load_document(pair[1], pair[0])
		await process_frame
		for host in [Vector2(800, 600), Vector2(1280, 800), Vector2(333, 1000), Vector2(120, 90)]:
			_compare(pair[1], d, host)
		root.remove_child(d)
		d.free()
	print("EQUIV_LAYOUT %s: %d checks, %d failures" % ["OK" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _compare(name: String, d: UxmlDocument, host: Vector2) -> void:
	var snap := {}
	for el in d._controls:
		snap[el] = d._controls[el].size
	var opts := {"source": d._doc.source, "file": d._doc.path,
		"scroll_bar_width": d._scroll_bar_width(), "warned": {}}
	var w1: Array = []
	var a := RefFlexLayout.compute(d._doc.root, d._styles, host, d._measure_leaf, w1, opts.duplicate())
	var after_a := {}
	for el in d._controls:
		after_a[el] = d._controls[el].size
		d._controls[el].size = snap[el]
	var opts2 := opts.duplicate()
	opts2["warned"] = {}
	opts2["volatile"] = d._volatile_measures()
	var w2: Array = []
	var b := UxmlFlexLayout.compute(d._doc.root, d._styles, host, d._measure_leaf, w2, opts2)
	_checks += 1
	var bad := ""
	for k in ["rects", "content_sizes", "insets"]:
		if a[k] != b[k]:
			bad = k
			for el in a[k]:
				if a[k][el] != b[k].get(el):
					bad = "%s differs at <%s name=%s>: %s vs %s" % [k, el.local, el.get_attribute("name"), a[k][el], b[k].get(el)]
					break
	if bad.is_empty() and w1 != w2:
		bad = "warnings differ: %s vs %s" % [w1, w2]
	if bad.is_empty():
		for el in d._controls:
			if d._controls[el].size != after_a[el]:
				bad = "measurer side effects differ"
				break
	if not bad.is_empty():
		_fails += 1
		print("FAIL %s @%s: %s" % [name, host, bad])
