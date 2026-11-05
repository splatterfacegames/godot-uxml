extends SceneTree
@warning_ignore_start("inference_on_variant", "unsafe_method_access", "untyped_declaration")
## Runtime equivalence of the optimized UxmlDocument against itself, three
## ways, driven through the same random sequence of state changes, class
## churn, set_enabled, refresh, resizes, text edits and control input:
##
##   a  — the same document with refresh() before every flush: full cascade
##        (scan_all), every control re-applied, full layout. The reference
##        for the optimization invariants (incremental cascade, partial
##        re-apply, paint-only layout skip, layout cache).
##   b  — the normal incremental document (native core when loaded).
##   c  — the incremental document on the GDScript cascade and layout.
##
## b must equal a (incremental == full) and c (native == GDScript). After
## each step all are flushed and every control is snapshotted — geometry,
## visibility, input filters, disabled/editable/pressed, every theme
## override (stylebox internals included), fonts, alignment/autowrap,
## UxmlBox/UxmlField chrome, image offsets, ScrollView offsets — and the
## diagnostics arrays are compared.
##
## Change history: until the Unity part trees (unity/controls-foundation)
## `a` was bench/ref/ref_uxml_document.gd, the pre-optimization runtime.
## That runtime has no default theme, no control parts and maps Toggle to a
## CheckBox, so its control trees can no longer be compared; the full-
## restyle document took its place as the reference for the optimization
## invariants, and the GDScript document was added for native/GDScript
## equality. Cascade and layout keep their comparisons with bench/ref in
## bench/equiv.gd and bench/equiv_layout.gd.
##
##   Godot --headless --path <project> -s res://bench/equiv_runtime.gd [-- --gdscript]
##
## `--gdscript` runs every document on the GDScript path.

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
		["res://tests/fixtures/controls", "Assets/UI/controls.uxml", 120],
		["res://tests/fixtures/editor", "Assets/UI/editor.uxml", 120],
	]:
		var only := ""
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--only="):
				only = arg.substr(7)
		if not only.is_empty() and String(pair[1]).find(only) < 0:
			continue
		await _run(pair[0], pair[1], pair[2], rng)
	print("EQUIV_RUNTIME %s: %d checks, %d failures, %d settled-earlier load transients" % [
		"OK" if _fails == 0 else "FAIL", _checks, _fails, _transients])
	quit(0 if _fails == 0 else 1)


func _run(project: String, path: String, steps: int, rng: RandomNumberGenerator) -> void:
	var a := UxmlDocument.new()
	var b := UxmlDocument.new()
	var c := UxmlDocument.new()
	var all := [a, b, c]
	for d in all:
		root.add_child(d)
		d.size = Vector2(640, 480)
		var was := UssCascade.use_native
		if d == c:
			UssCascade.use_native = false  # GDScript cascade => GDScript layout
		d.load_document(path, project)
		UssCascade.use_native = was
	await process_frame
	if not _same(a, b) or not _same(a, c):
		for d in all:
			d.refresh()
			d._restyle_now()
		await process_frame
		print("NOTE %s: load geometry differed until one restyle" % path)
		_transients += 1
	_cmp("%s load" % path, a, b)
	_cmp("%s load (GDScript)" % path, b, c)
	var names: Array = a._by_name.keys()
	var vocab: Array = []
	for el in a._doc.root.walk():
		for cl in el.class_list():
			if not vocab.has(cl):
				vocab.append(cl)
	vocab.append_array(["card--selected", "selected", "hot", "big"])
	if names.is_empty():
		names = [""]
	for step in steps:
		var nm: String = names[rng.randi() % names.size()]
		var op := rng.randi() % 13
		var args: Array = []
		match op:
			0, 1, 2:
				args = [nm, ["hover", "focus", "active", "checked", "selected"][rng.randi() % 5], rng.randi() % 2 == 0]
				for d in all:
					d.set_element_state(args[0], args[1], args[2])
			3:
				var cls := PackedStringArray()
				for _j in rng.randi() % 3:
					cls.append(vocab[rng.randi() % vocab.size()])
				args = [nm, " ".join(cls)]
				for d in all:
					d.set_class(args[0], args[1])
			4:
				args = [nm, rng.randi() % 2 == 0]
				for d in all:
					d.set_enabled(args[0], args[1])
			5:
				for d in all:
					d.refresh()
			6:
				var sz := Vector2(200 + rng.randi() % 900, 150 + rng.randi() % 700)
				args = [sz]
				for d in all:
					d.size = sz
			7:
				# Label text change + refresh (HUD pattern).
				var t := str(rng.randi() % 100000)
				args = [nm, t]
				for d in all:
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
				for d in all:
					var n2 = d.get_native(nm)
					if n2 is Label or n2 is Button:
						n2.text = t2
					d.size = sz2
			10:
				# New relayout() (text-only update) must land exactly where
				# the original's refresh() does.
				var t3 := str(rng.randi() % 1000000)
				args = [nm, t3]
				for d in all:
					var n3 = d.get_native(nm)
					if n3 is Label or n3 is Button:
						n3.text = t3
				for d in all:
					d.relayout()
			11:
				# Control input: a Toggle/RadioButton/Foldout flips, a
				# Button (ToggleButtonGroup option) is pressed.
				args = [nm]
				for d in all:
					var n4 = d.get_native(nm)
					if n4 is UxmlToggle:
						(n4 as UxmlToggle)._activate()
					elif n4 is BaseButton:
						(n4 as BaseButton).pressed.emit()
			12:
				# Model attribute writes controls react to (ProgressBar
				# value, labels and texts).
				var attr_name: String = ["value", "text", "label", "title"][rng.randi() % 4]
				var v := str(rng.randi() % 100) if attr_name == "value" else "t%d" % (rng.randi() % 1000)
				args = [nm, attr_name, v]
				for d in all:
					var m = d.get_element_model(nm)
					if m != null and m.local in ["ProgressBar", "Foldout", "Toggle", "HelpBox", "GroupBox", "Label"]:
						if attr_name == "value" and m.local in ["Foldout", "Toggle"]:
							m.set_attribute("value", "true" if int(v) % 2 == 0 else "false")
						else:
							m.set_attribute(attr_name, v)
			8:
				# Several changes coalesced into one flush.
				var nm2: String = names[rng.randi() % names.size()]
				args = [nm, nm2]
				for d in all:
					d.set_element_state(nm, "hover", true)
					d.set_element_state(nm2, "focus", true)
					d.set_element_state(nm, "hover", false)
		a.refresh()
		for d in all:
			d._restyle_now()
		await process_frame
		_cmp("%s step %d op %d %s" % [path, step, op, args], a, b)
		_cmp("%s step %d op %d %s (GDScript)" % [path, step, op, args], b, c)
	for d in all:
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
		if el.local == "ScrollView" and d._behaviors.has(el):
			e["scroll"] = d._behaviors[el].offset()
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
		# Rounded to 1e-3 px: Control.size round-trips through anchors and
		# offsets, so equal layouts written in a different order can differ
		# by ~1e-5 (seen on UxmlField inner natives).
		"pos": c.position.snappedf(0.001), "size": c.size.snappedf(0.001), "visible": c.visible,
		"mouse": c.mouse_filter, "focus": c.focus_mode,
	}
	if c is BaseButton:
		e["disabled"] = c.disabled
	if c is UxmlToggle:
		e["toggle"] = [c.button_pressed, c.disabled]
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
