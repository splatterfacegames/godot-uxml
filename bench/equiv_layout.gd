extends SceneTree
## Layout equivalence: optimized UxmlFlexLayout vs the original
## (bench/ref/ref_flex_layout.gd) on live documents with the real control
## measurer, at several host sizes. The reference has no absolute
## positioning, so the subtrees of elements with absolute children are not
## compared (bench/equiv_runtime.gd compares those between the paths). Control sizes are snapshotted and
## restored between the two runs so both see identical measurer state.

var _fails := 0
var _checks := 0


func _initialize() -> void:
	if OS.get_cmdline_user_args().has("--gdscript"):
		UssCascade.use_native = false  # exercise the GDScript reference path
	for pair in [
		["res://tests/fixtures/runtime", "Assets/UI/runtime.uxml"],
		["res://tests/fixtures/runtime", "Assets/UI/review.uxml"],
		["res://tests/fixtures/options", "Assets/UI/Options.uxml"],
		["res://tests/fixtures/menu", "Assets/UI/Menu.uxml"],
		["res://tests/fixtures/origin", "Assets/UI/panel.uxml"],
		["res://tests/fixtures/templates", "Assets/UI/Main.uxml"],
		["res://tests/fixtures/editor", "Assets/UI/editor.uxml"],
		["user://godot_uxml_bench", "Assets/UI/big.uxml"],
		["user://godot_uxml_bench", "Assets/UI/hud.uxml"],
	]:
		var d := UxmlDocument.new()
		root.add_child(d)
		d.size = Vector2(800, 600)
		d.load_document(pair[1], pair[0])
		await process_frame
		# Cold, then warm cross-pass caches over a size sequence with repeats
		# and revisits (the document's own records/xcache options).
		var records := {}
		var xcache := {}
		for host in [Vector2(800, 600), Vector2(1280, 800), Vector2(333, 1000), Vector2(120, 90),
				Vector2(800, 600), Vector2(800, 600), Vector2(1280, 800), Vector2(801, 600)]:
			_compare(pair[1], d, host, {}, {})
			_compare(pair[1] + " (cached)", d, host, records, xcache)
			_compare(pair[1] + " (document path)", d, host, {}, {})
		# Panel scaling: the document's own path (native when loaded) and the
		# reference, both rounded on a pixel grid of several pixels per
		# point, and the GDScript layout against the document's path.
		for ppp in [1.3333333730697632, 0.5625, 2.0, 1.1701388359069824]:
			for host in [Vector2(800, 600), Vector2(333, 1000)]:
				_compare(pair[1] + " (document path, scaled)", d, host, {}, {}, ppp)
				_compare(pair[1] + " (gdscript vs document, scaled)", d, host, {}, {}, ppp)
		root.remove_child(d)
		d.free()
	print("EQUIV_LAYOUT %s: %d checks, %d failures" % ["OK" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _compare(name: String, d: UxmlDocument, host: Vector2, records: Dictionary, xcache: Dictionary,
		ppp: float = 1.0) -> void:
	# The controls in the tree: a hidden subtree parked out of the tree
	# (UxmlDocument._park_hidden) is never measured, and a size written to a
	# control out of the tree is clamped to a minimum size the engine only
	# keeps current inside the tree.
	var ctl := {}
	for el in d._controls:
		if d._controls[el].is_inside_tree():
			ctl[el] = d._controls[el]
	var snap := {}
	for el in ctl:
		snap[el] = ctl[el].size
	var opts := {"source": d._doc.source, "file": d._doc.path,
		"warned": {}}
	var doc_path := name.ends_with("(document path)") or name.ends_with("(document path, scaled)") 		or name.ends_with("(gdscript vs document, scaled)")
	if doc_path and d.pixel_grid:
		opts["pixel_grid"] = true
	if ppp != 1.0:
		opts["pixels_per_point"] = ppp
	var w1: Array = []
	var a: Dictionary
	if name.ends_with("(gdscript vs document, scaled)"):
		a = UxmlFlexLayout.compute(d._doc.root, d._styles, host, d._measure_leaf, w1, opts.duplicate())
	else:
		a = RefFlexLayout.compute(d._doc.root, d._styles, host, d._measure_leaf, w1, opts.duplicate())
	var after_a := {}
	for el in ctl:
		after_a[el] = ctl[el].size
		ctl[el].size = snap[el]
	var opts2 := opts.duplicate()
	opts2["warned"] = {}
	opts2["volatile"] = d._volatile_measures()
	opts2["volatile_width"] = d._volatile_width
	if not records.is_empty() or not xcache.is_empty() or name.ends_with("(cached)"):
		opts2["records"] = records
		opts2["xcache"] = xcache
		opts2["hint_free"] = true
	var w2: Array = []
	var b: Dictionary
	if doc_path:
		# The runtime's own path (native when the extension is loaded),
		# with a fresh dedupe set and warnings array, on the pixel grid of
		# `ppp`.
		var keep_w = d._layout_warned
		var keep_rt = d._rt_warnings
		var keep_ppp := d._grid_ppp
		var keep_xc := d._layout_xcache
		d._layout_warned = {}
		d._rt_warnings = w2
		if ppp != keep_ppp:
			# A new grid drops the cross-pass cache (UxmlDocument._update_scale).
			d._layout_xcache = {}
		d._grid_ppp = ppp
		b = d._compute_layout(host)
		d._grid_ppp = keep_ppp
		d._layout_xcache = keep_xc if ppp == keep_ppp else {}
		if d._native_layout():
			d._cascade._native.call("set_pixels_per_point", keep_ppp)
		d._layout_warned = keep_w
		d._rt_warnings = keep_rt
		if d.pixel_grid and not name.ends_with("(gdscript vs document, scaled)"):
			# The runtime rounds to the pixel grid (UxmlDocument.pixel_grid);
			# the reference result gets the same rounding rule.
			a = a.duplicate()
			a["rects"] = UxmlFlexLayout.round_to_pixel_grid(d._doc.root, a["rects"], ppp)
	else:
		b = UxmlFlexLayout.compute(d._doc.root, d._styles, host, d._measure_leaf, w2, opts2)
	_checks += 1
	# The reference predates `position: absolute` (it lays absolute elements
	# out as flex items, so they change intrinsic sizes too). A control with
	# absolute parts (Slider, MinMaxSlider, ProgressBar) is no oracle case:
	# its parts and its content size are left out.
	var skip := {}
	var skip_content := {}
	for el in d._doc.root.walk():
		var pe = d._styles.get(el, {}).get("position")
		if pe == null or String(pe["value"]) != "absolute" or el.part_of == null:
			continue
		var owner: UxmlElement = el.part_of
		while owner.part_of != null:
			owner = owner.part_of
		skip_content[owner] = true
		for x in owner.walk():
			if x != owner:
				skip[x] = true
				skip_content[x] = true
	var bad := ""
	for k in ["rects", "content_sizes", "insets"]:
		var keys := {}
		for el in a[k]:
			keys[el] = true
		for el in b[k]:
			keys[el] = true
		for el in keys:
			if skip.has(el) or (k == "content_sizes" and skip_content.has(el)):
				continue
			if a[k].get(el) != b[k].get(el):
				bad = "%s differs at <%s name=%s>: %s vs %s" % [k, el.local, el.get_attribute("name"), a[k].get(el), b[k].get(el)]
				break
		if not bad.is_empty():
			break
	if bad.is_empty() and w1 != w2:
		bad = "warnings differ: %s vs %s" % [w1, w2]
	if bad.is_empty():
		for el in ctl:
			if ctl[el].size != after_a[el]:
				bad = "measurer side effects differ"
				break
	if not bad.is_empty():
		_fails += 1
		print("FAIL %s @%s: %s" % [name, host, bad])
