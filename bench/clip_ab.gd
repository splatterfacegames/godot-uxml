extends SceneTree
## Cost of the default theme's overflow clipping, A/B in one process. Side
## A uses the stock default theme; side B the same theme with its "Unity
## clips these controls and parts" block removed. The sides take turns on
## the same ops (alternating iterations, so both see the same machine
## load): steady-state ops on two copies of the large bench document, and
## loads of the fixtures. Prints the median ms of each side per op.
##
##   Godot --headless --path <project> -s res://bench/clip_ab.gd [-- --rounds=N] [-- --ops=<substr>]
##
## Side B instead:
##   --keep=<selectors or a rule>  the block replaced by these selectors
##                                 (overflow: hidden) or this rule
##   --theme-b=<path>              another default theme file (e.g. an older
##                                 revision's)
##   --same                        the stock theme (the harness's noise floor)
##   --strip=contents,elide,text   steady-state document only: the stock
##                                 theme, then clip_contents, the elision
##                                 pass or clip_text switched off after the
##                                 load (the loads still compare A with the
##                                 block removed)
##
## The user:// documents come from bench/bench.gd and bench/workloads.gd
## (run them once first).

static var BENCH_ROOT: String = UxmlBenchDir.of("godot_uxml_bench")
const BLOCK_START := "/* Unity clips these controls and parts. */"
static var LOADS: Array = [
	["res://tests/fixtures/runtime", "Assets/UI/review.uxml"],
	["res://tests/fixtures/runtime", "Assets/UI/runtime.uxml"],
	["res://tests/fixtures/options", "Assets/UI/Options.uxml"],
	[UxmlBenchDir.of("godot_uxml_bench"), "Assets/UI/wl_settings.uxml"],
]

## Per side: [UxmlTheme cache entry, UssCascade theme block entry].
var _theme: Array = [null, null]
var _docs: Array = []


func _initialize() -> void:
	var rounds := 40
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--rounds="):
			rounds = int(a.substr(9))
		elif a.begins_with("--ops="):
			only = a.substr(6)
	await process_frame
	await process_frame
	var stock := FileAccess.get_file_as_string(UxmlTheme.DEFAULT)
	var a := stock.find(BLOCK_START)
	var b := stock.find("}", a)
	var other := stock.substr(0, a) + stock.substr(b + 1)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--keep="):
			var keep := arg.substr(7)
			other = stock.substr(0, a) + (keep if keep.contains("{") else keep + " { overflow: hidden; }") + stock.substr(b + 1)
		elif arg.begins_with("--theme-b="):
			# Side B: another default theme file (e.g. an older revision's).
			other = FileAccess.get_file_as_string(arg.substr(10))
		elif arg == "--same":
			other = stock  # both sides stock: the noise floor of the harness
	# Each side's parsed theme (and the cascade's block built from it) is
	# swapped in before each of its loads; both caches are keyed by path.
	for side in 2:
		UxmlTheme.clear_cache()
		if side == 1:
			var parsed := UssParser.new().parse(other, UxmlTheme.DEFAULT)
			UxmlTheme._cache[UxmlTheme.DEFAULT] = [other, parsed["items"], parsed["warnings"]]
		var d := _load("Assets/UI/big.uxml", BENCH_ROOT, Vector2(1280, 800))
		_theme[side] = [UxmlTheme._cache[UxmlTheme.DEFAULT], UssCascade._theme_blocks[UxmlTheme.DEFAULT]]
		_docs.append(d)
	var strip := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--strip="):
			strip = arg.substr(8)
	if not strip.is_empty():
		# Side B: the stock theme too, with parts of the clipping switched
		# off after the load (comma-separated): contents (clip_contents),
		# elide (no elision pass), text (no clip_text).
		root.remove_child(_docs[1])
		_docs[1].free()
		_use(0)
		var d := _load("Assets/UI/big.uxml", BENCH_ROOT, Vector2(1280, 800))
		_docs[1] = d
		for el in d._controls:
			var c: Control = d._controls[el]
			if strip.contains("contents") and c.has_meta("uxml_clip_default") and not c.has_meta("uxml_clip"):
				c.clip_contents = false
			if strip.contains("text") and c.has_meta(&"uxml_clip_text"):
				c.remove_meta(&"uxml_clip_text")
				c.set(&"clip_text", false)
				d._applier.clip_texts -= 1
		if strip.contains("elide"):
			d._applier.elide.clear()
	await process_frame
	print("clipping controls in the large document: A %d, B %d" % [_clipped(_docs[0]), _clipped(_docs[1])])
	var ops := {
		"hover toggle (button)": func(d: UxmlDocument, f: bool):
			d.set_element_state("card-7-ok", "hover", f)
			d._restyle_now(),
		"set_class churn (card)": func(d: UxmlDocument, f: bool):
			d.set_class("card-20", "card card--selected" if f else "card")
			d._restyle_now(),
		"set_text + relayout": func(d: UxmlDocument, f: bool):
			(d.get_native("card-30-body") as Label).text = "short" if f else "a much longer body text that wraps over lines"
			d.relayout()
			d._restyle_now(),
		"resize relayout": func(d: UxmlDocument, f: bool):
			d.size = Vector2(1280, 800) if f else Vector2(1024, 720),
		"idle restyle": func(d: UxmlDocument, _f: bool):
			d._restyle_now(),
	}
	for op in ops:
		if not only.is_empty() and not op.contains(only):
			continue
		var s := [PackedFloat64Array(), PackedFloat64Array()]
		var fn: Callable = ops[op]
		for r in rounds:
			for i in 2:
				var side := i if r % 2 == 0 else 1 - i
				var t0 := Time.get_ticks_usec()
				fn.call(_docs[side], r % 2 == 0)
				var dt := (Time.get_ticks_usec() - t0) / 1000.0
				if r > 0:
					s[side].append(dt)
				await process_frame
		_report(op, s)
	for d in _docs:
		root.remove_child(d)
		d.free()
	for cs in LOADS:
		var op := "load %s" % cs[1].get_file()
		if not only.is_empty() and not op.contains(only):
			continue
		if not FileAccess.file_exists(cs[0].path_join(cs[1])):
			continue
		var s := [PackedFloat64Array(), PackedFloat64Array()]
		for r in rounds:
			for i in 2:
				var side := i if r % 2 == 0 else 1 - i
				_use(side)
				var t0 := Time.get_ticks_usec()
				var d := _load(cs[1], cs[0], Vector2(1280, 720))
				var dt := (Time.get_ticks_usec() - t0) / 1000.0
				if r > 0:
					s[side].append(dt)
				await process_frame
				root.remove_child(d)
				d.free()
		_report(op, s)
	UxmlTheme.clear_cache()
	quit(0)


func _use(side: int) -> void:
	UxmlTheme._cache[UxmlTheme.DEFAULT] = _theme[side][0]
	UssCascade._theme_blocks[UxmlTheme.DEFAULT] = _theme[side][1]


func _load(path: String, base: String, sz: Vector2) -> UxmlDocument:
	var d := UxmlDocument.new()
	root.add_child(d)
	d.size = sz
	d.load_document(path, base)
	return d


func _report(op: String, s: Array) -> void:
	var m0 := _median(s[0])
	var m1 := _median(s[1])
	print("CLIP_AB %-26s A %8.3f B %8.3f ratio %.3f" % [op, m0, m1, m0 / m1])


func _median(a: PackedFloat64Array) -> float:
	var s := a.duplicate()
	s.sort()
	return s[s.size() / 2]


func _clipped(d: UxmlDocument) -> int:
	var n := 0
	for el in d._controls:
		var c: Control = d._controls[el]
		if c.clip_contents or c.has_meta(&"uxml_clip_text"):
			n += 1
	return n
