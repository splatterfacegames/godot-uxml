extends SceneTree
@warning_ignore_start("inference_on_variant", "unsafe_method_access", "untyped_declaration")
## Runtime equivalence: the optimized UxmlDocument against the original one
## (bench/ref/ref_uxml_document.gd, wired to the original resolver, layout,
## applier and value parser) driven through the same random sequence of
## state changes, class churn, set_enabled, refresh and resizes. After each
## step both documents are flushed and every control is snapshotted —
## geometry, visibility, input filters, disabled/editable, every theme
## override (stylebox internals included), fonts, alignment/autowrap,
## UxmlBox/UxmlField chrome, image offsets, scroll content size — and the
## diagnostics arrays are compared.
##
##   Godot --headless --path <project> -s res://bench/equiv_runtime.gd

const SLOTS := ["normal", "hover", "pressed", "disabled", "focus", "read_only", "slider"]
const COLORS := ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color",
	"font_disabled_color", "font_placeholder_color", "font_outline_color"]

var _fails := 0
var _checks := 0
var _transients := 0


func _initialize() -> void:
	if OS.get_cmdline_user_args().has("--gdscript"):
		UssCascade.use_native = false  # exercise the GDScript reference path
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	for pair in [
		["res://tests/fixtures/runtime", "Assets/UI/runtime.uxml", 120],
		["res://tests/fixtures/runtime", "Assets/UI/review.uxml", 120],
		["res://tests/fixtures/options", "Assets/UI/Options.uxml", 80],
		["res://tests/fixtures/origin", "Assets/UI/panel.uxml", 40],
		["user://godot_uxml_bench", "Assets/UI/hud.uxml", 80],
		["user://godot_uxml_bench", "Assets/UI/big.uxml", 12],
	]:
		await _run(pair[0], pair[1], pair[2], rng)
	print("EQUIV_RUNTIME %s: %d checks, %d failures, %d settled-earlier load transients" % [
		"OK" if _fails == 0 else "FAIL", _checks, _fails, _transients])
	quit(0 if _fails == 0 else 1)


func _run(project: String, path: String, steps: int, rng: RandomNumberGenerator) -> void:
	var a := RefUxmlDocument.new()
	var b := UxmlDocument.new()
	for d in [a, b]:
		root.add_child(d)
		d.size = Vector2(640, 480)
		d.load_document(path, project)
	await process_frame
	if OS.get_cmdline_user_args().has("--trace"):
		var wa: Array = a._doc.root.walk()
		var wb: Array = b._doc.root.walk()
		for k in 4:
			var diffs := 0
			for i in wa.size():
				var ca = a._controls.get(wa[i])
				if ca != null and ca.size != b._controls[wb[i]].size:
					diffs += 1
			print("  trace %s: pass %d, %d size diffs" % [path, k, diffs])
			for d in [a, b]:
				d._restyle_now()
			await process_frame
	# Known, intentional deviation (UxmlStyleApplier.BULK_THEME_OVERRIDES):
	# the new runtime's first layout after load can already be settled where
	# the original showed stale minimum sizes until its next restyle. One
	# restyle on both must converge them; that is reported, not failed.
	if not _same(a, b):
		for d in [a, b]:
			d._restyle_now()
		await process_frame
		print("NOTE %s: load geometry differed until one restyle (bulk theme overrides settle earlier)" % path)
		_transients += 1
	_cmp("%s load" % path, a, b)
	var names: Array = a._by_name.keys()
	var vocab: Array = []
	for el in a._doc.root.walk():
		for c in el.class_list():
			if not vocab.has(c):
				vocab.append(c)
	vocab.append_array(["card--selected", "selected", "hot", "big"])
	if names.is_empty():
		names = [""]
	for step in steps:
		var nm: String = names[rng.randi() % names.size()]
		var op := rng.randi() % 11
		var args: Array = []
		match op:
			0, 1, 2:
				args = [nm, ["hover", "focus", "active", "checked", "selected"][rng.randi() % 5], rng.randi() % 2 == 0]
				for d in [a, b]:
					d.set_element_state(args[0], args[1], args[2])
			3:
				var cls := PackedStringArray()
				for _j in rng.randi() % 3:
					cls.append(vocab[rng.randi() % vocab.size()])
				args = [nm, " ".join(cls)]
				for d in [a, b]:
					d.set_class(args[0], args[1])
			4:
				args = [nm, rng.randi() % 2 == 0]
				for d in [a, b]:
					d.set_enabled(args[0], args[1])
			5:
				for d in [a, b]:
					d.refresh()
			6:
				var sz := Vector2(200 + rng.randi() % 900, 150 + rng.randi() % 700)
				args = [sz]
				for d in [a, b]:
					d.size = sz
			7:
				# Label text change + refresh (HUD pattern).
				var t := str(rng.randi() % 100000)
				args = [nm, t]
				for d in [a, b]:
					var n = d.get_native(nm)
					if n is Label or n is Button:
						n.text = t
					d.refresh()
			9:
				# Text change the runtime cannot see (no refresh), then a
				# resize — the relayout must pick the new text up.
				var t2 := "x".repeat(1 + rng.randi() % 40)
				var sz2 := Vector2(200 + rng.randi() % 900, 150 + rng.randi() % 700)
				args = [nm, t2, sz2]
				for d in [a, b]:
					var n2 = d.get_native(nm)
					if n2 is Label or n2 is Button:
						n2.text = t2
					d.size = sz2
			10:
				# New relayout() (text-only update) must land exactly where
				# the original's refresh() does.
				var t3 := str(rng.randi() % 1000000)
				args = [nm, t3]
				for d in [a, b]:
					var n3 = d.get_native(nm)
					if n3 is Label or n3 is Button:
						n3.text = t3
				a.refresh()
				b.relayout()
			8:
				# Several changes coalesced into one flush.
				var nm2: String = names[rng.randi() % names.size()]
				args = [nm, nm2]
				for d in [a, b]:
					d.set_element_state(nm, "hover", true)
					d.set_element_state(nm2, "focus", true)
					d.set_element_state(nm, "hover", false)
		for d in [a, b]:
			d._restyle_now()
		await process_frame
		_cmp("%s step %d op %d %s" % [path, step, op, args], a, b)
	for d in [a, b]:
		root.remove_child(d)
		d.free()


func _same(a, b) -> bool:
	return _snap(a) == _snap(b) and _diags(a) == _diags(b)


func _cmp(what: String, a, b) -> void:
	_checks += 1
	var sa := _snap(a)
	var sb := _snap(b)
	var why := ""
	if sa.size() != sb.size():
		why = "control count %d vs %d" % [sa.size(), sb.size()]
	else:
		for i in sa.size():
			if sa[i] != sb[i]:
				why = "element %d (%s) %s" % [i, sa[i].get("tag"), _leaf(sa[i], sb[i], "")]
				if why.is_empty():
					why = "element %d differs" % i
				break
	if why.is_empty() and _diags(a) != _diags(b):
		why = "diagnostics differ:\n  %s\n  %s" % [_diags(a), _diags(b)]
	if not why.is_empty():
		_fails += 1
		if _fails <= 12:
			print("FAIL %s: %s" % [what, why])


func _leaf(a, b, path: String) -> String:
	if a is Dictionary and b is Dictionary:
		for k in a:
			if not b.has(k):
				return "%s.%s missing in new" % [path, k]
			if a[k] != b[k]:
				return _leaf(a[k], b[k], "%s.%s" % [path, k])
		for k in b:
			if not a.has(k):
				return "%s.%s extra in new" % [path, k]
	return "%s: %s vs %s" % [path, a, b]


func _diags(d) -> Array:
	var out: Array = []
	for w in d.diagnostics:
		out.append([w["kind"], w["message"], w["file"], w["line"], w["column"]])
	return out


func _snap(d) -> Array:
	var out: Array = []
	var walk: Array = d._doc.root.walk()
	var idx := {}
	for i in walk.size():
		idx[walk[i]] = i
	for el in walk:
		var c: Control = d._controls.get(el)
		if c == null:
			out.append({"tag": el.local, "none": true})
			continue
		var n: Control = d._natives.get(el, c)
		var e := {"tag": el.local}
		e["style"] = _norm(d._styles.get(el, {}), idx)
		e["c"] = _ctl(c)
		if n != c:
			e["n"] = _ctl(n)
		if c is UxmlField:
			e["cap"] = _ctl(c.caption_node())
			e["ins"] = [c.inset_start, c.inset_end]
		if c is UxmlBox:
			e["box"] = [_res(c.box_style), _res(c.box_texture), _res(c.get("box_texture_style"))]
		if n is TextureRect:
			e["tr"] = [n.offset_left, n.offset_top, n.offset_right, n.offset_bottom]
		var sc = d._scroll.get(el)
		if sc != null:
			e["scroll"] = sc.custom_minimum_size
		out.append(e)
	return out


## Element references (origin "from") become preorder indices so styles of
## two separately parsed models compare by value.
func _norm(v, idx: Dictionary):
	if v is Dictionary:
		var o := {}
		for k in v:
			o[k] = _norm(v[k], idx)
		return o
	if v is Array:
		var a: Array = []
		for x in v:
			a.append(_norm(x, idx))
		return a
	if v is UxmlElement:
		return ["el", idx.get(v, -1)]
	return v


func _ctl(c: Control) -> Dictionary:
	var e := {
		"pos": c.position, "size": c.size, "visible": c.visible,
		"mouse": c.mouse_filter, "focus": c.focus_mode,
	}
	if c is BaseButton:
		e["disabled"] = c.disabled
	if c is LineEdit or c is TextEdit or c is Range:
		e["editable"] = c.editable
	if c is Label:
		e["align"] = [c.horizontal_alignment, c.vertical_alignment, c.autowrap_mode]
	elif c is Button and not c is OptionButton:
		e["align"] = c.alignment
	elif c is LineEdit:
		e["align"] = c.alignment
	var sbs := {}
	for s in SLOTS:
		if c.has_theme_stylebox_override(s):
			sbs[s] = _res(c.get_theme_stylebox(s))
	e["sb"] = sbs
	var cols := {}
	for s in COLORS:
		if c.has_theme_color_override(s):
			cols[s] = c.get_theme_color(s)
	e["col"] = cols
	if c.has_theme_font_size_override("font_size"):
		e["fs"] = c.get_theme_font_size("font_size")
	if c.has_theme_font_override("font"):
		e["font"] = _res(c.get_theme_font("font"))
	if c.has_theme_constant_override("outline_size"):
		e["outline"] = c.get_theme_constant("outline_size")
	return e


## Value snapshot of a Resource (stylebox/font/texture): class + storage
## properties, recursively for sub-resources (bounded depth).
func _res(r, depth := 0):
	if r == null:
		return null
	if not (r is Resource):
		return r
	if depth > 3:
		return r.get_class()
	if r is Texture2D:
		return [r.get_class(), r.resource_path, r.get_size()]
	var out := {"class": r.get_class()}
	for p in r.get_property_list():
		if not (p["usage"] & PROPERTY_USAGE_STORAGE):
			continue
		var pn: String = p["name"]
		if pn.begins_with("resource_") or pn == "script":
			continue
		var v = r.get(pn)
		out[pn] = _res(v, depth + 1) if v is Resource else v
	if r.has_meta("uxml_margins"):
		out["meta_margins"] = r.get_meta("uxml_margins")
	return out
