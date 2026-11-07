extends SceneTree
## What a restyle reuses (UxmlStyleApplier.restyle_reuse), A/B in one
## process. Side A reuses: box shapes and records from the cache of their
## style values, an installed box recoloured in place, no write of an
## unchanged theme override, no theme update for an apply that writes none.
## Side B does all of that work every time, as before. The sides take
## turns on the same ops (alternating iterations, so both see the same
## machine load) on two copies of the large bench document and of the HUD
## document, and on loads of the fixtures. Prints the median ms of each
## side per op. The redraws run in the frame after the op, outside the
## timing (headless frame times are frame pacing; bench/render_cost.gd
## measures drawing).
##
##   Godot --headless --path <project> -s res://bench/box_ab.gd [-- --rounds=N] [-- --ops=<substr>] [-- --no-theme]
##
## The user:// documents come from bench/bench.gd and bench/workloads.gd
## (run them once first). The caches are static: side A's loads find what
## earlier loads put there, as later loads of a session do.

const BENCH_ROOT := "user://godot_uxml_bench"
const LOADS := [
	["res://tests/fixtures/runtime", "Assets/UI/review.uxml"],
	["res://tests/fixtures/runtime", "Assets/UI/runtime.uxml"],
	["res://tests/fixtures/options", "Assets/UI/Options.uxml"],
	["user://godot_uxml_bench", "Assets/UI/wl_settings.uxml"],
	["user://godot_uxml_bench", "Assets/UI/wl_inventory.uxml"],
]

var _docs: Array = []
var _huds: Array = []
var _no_theme := false


func _initialize() -> void:
	var rounds := 60
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--rounds="):
			rounds = int(a.substr(9))
		elif a.begins_with("--ops="):
			only = a.substr(6)
		elif a == "--no-theme":
			_no_theme = true
	await process_frame
	for side in 2:
		_use(side)
		_docs.append(_load("Assets/UI/big.uxml", BENCH_ROOT, Vector2(1280, 800)))
		_huds.append(_load("Assets/UI/hud.uxml", BENCH_ROOT, Vector2(640, 360)))
	await process_frame
	var frame := [0, 0]
	var ops := {
		"hover toggle (button)": func(d: UxmlDocument, _h: UxmlDocument, f: bool):
			d.set_element_state("card-7-ok", "hover", f)
			d._restyle_now(),
		"hover toggle (card)": func(d: UxmlDocument, _h: UxmlDocument, f: bool):
			d.set_element_state("card-12", "hover", f)
			d._restyle_now(),
		"hover move (card i -> i+1)": func(d: UxmlDocument, _h: UxmlDocument, _f: bool):
			var sd := _docs.find(d)
			frame[sd] += 1
			var i: int = frame[sd] % 150
			d.set_element_state("card-%d" % i, "hover", false)
			d.set_element_state("card-%d" % ((i + 1) % 150), "hover", true)
			d._restyle_now(),
		"focus toggle (list item)": func(d: UxmlDocument, _h: UxmlDocument, f: bool):
			d.set_element_state("item-5", "focus", f)
			d._restyle_now(),
		"set_class churn (card)": func(d: UxmlDocument, _h: UxmlDocument, f: bool):
			d.set_class("card-20", "card card--selected" if f else "card")
			d._restyle_now(),
		"set_text + refresh": func(d: UxmlDocument, _h: UxmlDocument, f: bool):
			(d.get_native("card-30-body") as Label).text = "short" if f else "a much longer body text that wraps over lines"
			d.refresh()
			d._restyle_now(),
		"hud frame (8 labels + refresh)": func(_d: UxmlDocument, h: UxmlDocument, _f: bool):
			var sd := _huds.find(h)
			frame[sd] += 1
			for i in 8:
				(h.get_native("val-%d" % i) as Label).text = str((frame[sd] * 37 + i * 101) % 100000)
			h.refresh()
			h._restyle_now(),
		"hud hover toggle": func(_d: UxmlDocument, h: UxmlDocument, f: bool):
			h.set_element_state("bar-0", "hover", f)
			h._restyle_now(),
	}
	for op in ops:
		if not only.is_empty() and not op.contains(only):
			continue
		await _ab(op, rounds, func(side: int, r: int):
			(ops[op] as Callable).call(_docs[side], _huds[side], r % 2 == 0))
	for spec in [
		["transition frame (bg color)", "card-7-ok",
			"transition: background-color 1000s linear; background-color: rgb(10, 20, 30);",
			"transition: background-color 1000s linear; background-color: rgb(250, 200, 100);"],
		["transition frame (card border color)", "card-9",
			"transition: border-color 1000s linear; border-color: rgb(10, 20, 30);",
			"transition: border-color 1000s linear; border-color: rgb(250, 200, 100);"],
	]:
		if not only.is_empty() and not spec[0].contains(only):
			continue
		for side in 2:
			_use(side)
			var d: UxmlDocument = _docs[side]
			d.transitions_manual = true
			var m := d.get_element_model(spec[1])
			m.set_attribute("style", spec[2])
			d._restyle_now()
			m.set_attribute("style", spec[3])
			d._restyle_now()
		await process_frame
		await _ab(spec[0], rounds * 2, func(side: int, _r: int):
			(_docs[side] as UxmlDocument).advance_transitions(0.016))
		for side in 2:
			_use(side)
			_docs[side].get_element_model(spec[1]).set_attribute("style", "")
			_docs[side]._restyle_now()
			_docs[side].transitions_manual = false
	for d in _docs + _huds:
		root.remove_child(d)
		d.free()
	for cs in LOADS:
		var op := "load %s" % cs[1].get_file()
		if not only.is_empty() and not op.contains(only):
			continue
		if not FileAccess.file_exists(cs[0].path_join(cs[1])):
			continue
		var s := [PackedFloat64Array(), PackedFloat64Array()]
		for r in rounds / 2:
			for i in 2:
				var side := i if r % 2 == 0 else 1 - i
				_use(side)
				var t0 := Time.get_ticks_usec()
				var d := _load(cs[1], cs[0], Vector2(1280, 720))
				var dt := (Time.get_ticks_usec() - t0) / 1000.0
				await process_frame
				if r > 0:
					s[side].append(dt)
				root.remove_child(d)
				d.free()
		_report(op, s)
	UxmlStyleApplier.restyle_reuse = true
	quit(0)


## Alternates `fn` (side, round) on the two sides, a frame after each
## call (untimed).
func _ab(op: String, rounds: int, fn: Callable) -> void:
	var s := [PackedFloat64Array(), PackedFloat64Array()]
	for r in rounds:
		for i in 2:
			var side := i if r % 2 == 0 else 1 - i
			_use(side)
			var t0 := Time.get_ticks_usec()
			fn.call(side, r)
			var dt := (Time.get_ticks_usec() - t0) / 1000.0
			await process_frame
			if r > 0:
				s[side].append(dt)
	_report(op, s)


func _use(side: int) -> void:
	UxmlStyleApplier.restyle_reuse = side == 0


func _load(path: String, base: String, sz: Vector2) -> UxmlDocument:
	var d := UxmlDocument.new()
	if _no_theme:
		d.theme_path = ""
	root.add_child(d)
	d.size = sz
	d.load_document(path, base)
	return d


func _report(op: String, s: Array) -> void:
	var m0 := _median(s[0])
	var m1 := _median(s[1])
	print("BOX_AB %-36s A %8.3f B %8.3f ratio %.3f" % [op, m0, m1, m0 / m1])


func _median(a: PackedFloat64Array) -> float:
	var s := a.duplicate()
	s.sort()
	return s[s.size() / 2]
