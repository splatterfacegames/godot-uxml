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
## Documents with collection views get item sources, and a separate random
## stream scrolls them, selects and expands items (R29: rows lay out alone),
## and writes field values and placeholders (R17, R28).
##
## _run_reload checks reload_stylesheet with random stylesheet edits: a partial
## reload equals a full rebuild, on both paths, and native equals GDScript.
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
## `--gdscript` runs every document on the GDScript path. `--seed=<n>` changes
## the random sequence, `--reload-only` runs the stylesheet edits only, and
## `--only=<text>` the fixtures with that text in the path. The env variable
## RELOAD_TRACE prints each stylesheet edit.

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
	_frng.seed = 4242
	_crng.seed = 2929
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			rng.seed = int(arg.substr(7))
	for pair in [
		["res://tests/fixtures/runtime", "Assets/UI/runtime.uxml", 120],
		["res://tests/fixtures/runtime", "Assets/UI/review.uxml", 120],
		["res://tests/fixtures/options", "Assets/UI/Options.uxml", 80],
		["res://tests/fixtures/origin", "Assets/UI/panel.uxml", 40],
		["user://godot_uxml_bench", "Assets/UI/hud.uxml", 80],
		["user://godot_uxml_bench", "Assets/UI/big.uxml", 12],
		["res://tests/fixtures/controls", "Assets/UI/controls.uxml", 120],
		["res://tests/fixtures/editor", "Assets/UI/editor.uxml", 120],
		["res://tests/fixtures/runtime", "Assets/UI/collections.uxml", 120],
	]:
		var only := ""
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--only="):
				only = arg.substr(7)
		if not only.is_empty() and String(pair[1]).find(only) < 0:
			continue
		if not OS.get_cmdline_user_args().has("--reload-only"):
			await _run(pair[0], pair[1], pair[2], rng)
		await _run_reload(pair[0], pair[1], 10 if String(pair[1]).ends_with("big.uxml") else 40, rng)
	# Sheets of a template (a scope) and a template used twice.
	var only_arg := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			only_arg = arg.substr(7)
	if only_arg.is_empty() or "templates Main.uxml".find(only_arg) >= 0:
		await _run_reload("res://tests/fixtures/templates", "Assets/UI/Main.uxml", 30, rng)
	print("EQUIV_RELOAD modes: %s" % [_reload_modes])
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
		# Outside the viewport: a cursor-shape change makes Godot pick the
		# control under the mouse again, which would hover only the
		# topmost of the stacked documents.
		d.position = Vector2(20000, 20000)
		var was := UssCascade.use_native
		if d == c:
			UssCascade.use_native = false  # GDScript cascade => GDScript layout
		d.load_document(path, project)
		UssCascade.use_native = was
	await process_frame
	var lists: Array = []
	for el in a._doc.root.walk():
		if el.part_of == null and UxmlContainerParts.is_collection(el.local) and el.has_attribute("name"):
			lists.append([String(el.get_attribute("name")), el.local])
	if not lists.is_empty():
		for d in all:
			_sources(d, lists)
		for d in all:
			d.refresh()
			d._restyle_now()
		await process_frame
		for d in all:
			d._restyle_now()
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
		if not lists.is_empty() and step % 2 == 0:
			op = -1  # a step of the collection stream only
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
		if not lists.is_empty():
			args.append(_collection_op(all, lists, names))
		if step % 5 == 4:
			# Forced pseudo-states (UxmlDocument.set_forced_states), from
			# their own random stream so the ops above keep their sequence.
			var fel = a.get_element_model(names[_frng.randi() % names.size()])
			var fs := PackedStringArray()
			for st in ["hover", "focus", "active", "checked", "disabled"]:
				if _frng.randi() % 4 == 0:
					fs.append(st)
			args.append(["forced", fs])
			if fel != null:
				var path_i: Array = _path_of(a, fel)
				for d in all:
					d.set_forced_states(_at_path(d, path_i), fs)
		a.refresh()
		for d in all:
			d._restyle_now()
		await process_frame
		_cmp("%s step %d op %d %s" % [path, step, op, args], a, b)
		_cmp("%s step %d op %d %s (GDScript)" % [path, step, op, args], b, c)
	if b.local_layout_count > 0:
		print("NOTE %s: %d row layouts, %d document layouts" % [path, b.local_layout_count, b.layout_count])
	for d in all:
		root.remove_child(d)
		d.free()


# ---------------------------------------------------------------------------
# reload_stylesheet: a partial reload equals a full rebuild (R25)
# ---------------------------------------------------------------------------

## Declarations an edit can add: inherited and not, layout and paint, custom
## properties and var(), keywords, transitions, and values that report.
const RELOAD_DECLS := [
	"color: rgb(1, 2, 3)", "color: var(--rl-c)", "--rl-c: rgb(9, 8, 7)", "--rl-c: rgb(7, 8, 9)",
	"color: var(--rl-missing)", "width: 123px", "width: 40%", "height: 31px", "min-width: 11px",
	"font-size: 19px", "font-size: 150%", "margin: 3px", "padding: 2px 5px", "display: none",
	"display: flex", "visibility: hidden", "opacity: 0.5", "flex-direction: row", "flex-grow: 2",
	"background-color: rgb(40, 50, 60)", "border-width: 2px", "border-color: rgb(1, 1, 1)",
	"border-radius: 4px", "transition: min-width 1s", "transition-duration: 0.5s", "transition-delay: 0.1s",
	"transition-property: all", "all: initial", "color: unset", "font-size: initial", "nonsense-prop: 1",
	"width: bogus", "display: bogus", "background-image: url(\"nope.png\")", "-unity-font-style: bold",
	"-unity-font-style: bogus", "overflow: hidden", "translate: 5px 5px", "rotate: 10deg",
	"-unity-text-align: middle-center", "text-overflow: ellipsis", "white-space: nowrap",
	"filter: blur(2px)", "letter-spacing: 1px", "position: absolute", "left: 7px",
]
const RELOAD_RULES := [
	".rl-none { color: rgb(1, 2, 3); }", "Label { color: rgb(3, 4, 5); }", "Button:hover { width: 50px; }",
	"VisualElement > Label { font-size: 15px; }", "* { --rl-c: rgb(5, 5, 5); }", ":root { font-size: 14px; }",
	"Label + Button { color: red; }", "VisualElement Label:hover { color: rgb(0, 9, 0); }",
]

var _reload_modes := {}


## The sheet `text` after one random edit.
var _crng := RandomNumberGenerator.new()


static func _tree(n: int, depth: int, tag: String) -> Array:
	var out: Array = []
	for i in n:
		var kids: Array = _tree(3, depth - 1, "%s.%d" % [tag, i]) if depth > 0 and i % 3 == 0 else []
		out.append({"id": "%s.%d" % [tag, i], "data": "Item %d %s" % [i, "wide ".repeat(i % 4)], "children": kids})
	return out


func _sources(d: UxmlDocument, lists: Array) -> void:
	var items: Array = []
	for i in 120:
		items.append("Row %d %s" % [i, "long ".repeat(i % 5)])
	for l in lists:
		if String(l[1]).contains("Tree"):
			d.set_tree_source(l[0], _tree(30, 2, "r"))
		else:
			d.set_items_source(l[0], items)


## One step of the collection and field stream (its own random sequence).
func _collection_op(all: Array, lists: Array, names: Array) -> Array:
	var l: Array = lists[_crng.randi() % lists.size()]
	var nm: String = names[_crng.randi() % names.size()]
	var op := _crng.randi() % 7
	var out: Array = ["collection", op, l[0]]
	match op:
		0, 1:
			var y := float(_crng.randi() % 1800)
			out.append(y)
			for d in all:
				d.set_scroll_offset(l[0], Vector2(0, y))
		2:
			var i := _crng.randi() % 100
			out.append(i)
			for d in all:
				d.scroll_to_item(l[0], i)
		3:
			var i2 := _crng.randi() % 60
			out.append(i2)
			for d in all:
				d.set_selection(l[0], [i2])
		4:
			if String(l[1]).contains("Tree"):
				var id := "r.%d" % (3 * (_crng.randi() % 10))
				var on := _crng.randi() % 2 == 0
				out.append([id, on])
				for d in all:
					d.set_tree_item_expanded(l[0], id, on)
		5:
			var v = "v%d" % (_crng.randi() % 1000)
			if _crng.randi() % 2 == 0:
				v = _crng.randi() % 2 == 0
			out.append([nm, v])
			for d in all:
				d.set_field_value(nm, v)
		6:
			var t := "" if _crng.randi() % 4 == 0 else "computed %s from .rule" % "x".repeat(_crng.randi() % 30)
			out.append([nm, t])
			for d in all:
				d.set_field_placeholder(nm, t)
	return out


func _edit_sheet(text: String, origin: String, rng: RandomNumberGenerator) -> String:
	var items: Array = UssParser.new().parse(text, origin)["items"]
	var rules: Array = []
	for it in items:
		if it["kind"] == "rule":
			rules.append(it["rule"])
	var op := rng.randi() % 12
	if rules.is_empty() or op == 0:
		return text + "\n" + RELOAD_RULES[rng.randi() % RELOAD_RULES.size()]
	var rule: Dictionary = rules[rng.randi() % rules.size()]
	var decls: Array = rule["declarations"]
	var new_decl: String = RELOAD_DECLS[rng.randi() % RELOAD_DECLS.size()]
	match op:
		1, 2, 3, 4:
			# One declaration: a new value (the most common edit), or a new one.
			if decls.is_empty():
				return text.insert(int(rule["span"]["end"]) - 1, new_decl + ";")
			var d: Dictionary = decls[rng.randi() % decls.size()]
			var v: String = d["value"]
			if v.ends_with("px") and v.substr(0, v.length() - 2).is_valid_float():
				new_decl = "%s: %dpx" % [d["property"], rng.randi() % 40]
			elif v.begins_with("#") or v.begins_with("rgb"):
				new_decl = "%s: rgb(%d, %d, %d)" % [d["property"], rng.randi() % 255, rng.randi() % 255, rng.randi() % 255]
			return text.substr(0, int(d["span"]["start"])) + new_decl + text.substr(int(d["span"]["end"]))
		5, 6:
			return text.insert(int(rule["span"]["end"]) - 1, ";" + new_decl + ";")
		7:
			if decls.is_empty():
				return text
			var d2: Dictionary = decls[rng.randi() % decls.size()]
			return text.substr(0, int(d2["span"]["start"])) + text.substr(int(d2["span"]["end"]))
		8:
			# Ancestor states (`:hover > *`) change the ancestor keys of the
			# cascade ("rules" reloads mark those subtrees).
			var suffix: String = [", .rl-none", ":hover", " Label", ", Label", ":hover > *", ":checked Label"][rng.randi() % 6]
			return text.insert(int(rule["selector_span"]["end"]), suffix)
		9:
			return text.substr(0, int(rule["span"]["start"])) + text.substr(int(rule["span"]["end"]))
		10:
			return "/* moved */\n" + text
		11:
			# A rule first: every later item moves to another index.
			return RELOAD_RULES[rng.randi() % RELOAD_RULES.size()] + "\n" + text
	return text


## The part of `b` that differs from `a` (a trace of an edit).
static func _diff_text(a: String, b: String) -> String:
	var i := 0
	while i < a.length() and i < b.length() and a[i] == b[i]:
		i += 1
	var ea := a.length()
	var eb := b.length()
	while ea > i and eb > i and a[ea - 1] == b[eb - 1]:
		ea -= 1
		eb -= 1
	return "at %d: %s -> %s" % [i, a.substr(i, ea - i), b.substr(i, eb - i)]


func _sorted_diags(d) -> Array:
	var out := _diags(d)
	out.sort_custom(func(x, y): return str(x) < str(y))
	return out


func _cmp_reload(what: String, a, b) -> void:
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
				break
	if why.is_empty() and _sorted_diags(a) != _sorted_diags(b):
		var da := _sorted_diags(a)
		var db := _sorted_diags(b)
		var only_a: Array = da.filter(func(x): return not db.has(x))
		var only_b: Array = db.filter(func(x): return not da.has(x))
		why = "diagnostics differ:\n  first only %s\n  second only %s" % [only_a, only_b]
	if not why.is_empty():
		_fails += 1
		if _fails <= 12:
			print("FAIL %s: %s" % [what, why])


## Random stylesheet edits, state changes and running transitions on three
## documents: a and g rebuild everything at each reload, on the current
## path and on GDScript; b and c reload partially on the same paths.
func _run_reload(project: String, path: String, steps: int, rng: RandomNumberGenerator) -> void:
	var a := UxmlDocument.new()
	var b := UxmlDocument.new()
	var c := UxmlDocument.new()
	var g := UxmlDocument.new()
	var all := [a, b, c, g]
	a._partial_reload = false
	g._partial_reload = false
	for d in all:
		d.transitions_manual = true
		root.add_child(d)
		d.size = Vector2(640, 480)
		d.position = Vector2(20000, 20000)
		var was := UssCascade.use_native
		if d == c or d == g:
			UssCascade.use_native = false
		d.load_document(path, project)
		UssCascade.use_native = was
	await process_frame
	for d in all:
		d.refresh()
		d._restyle_now()
	await process_frame
	var texts := {}
	var origins: Array = []
	for sh in a._doc.sheets:
		if not bool(sh.get("theme", false)) and not String(sh["origin"]).is_empty() and not texts.has(sh["origin"]):
			texts[sh["origin"]] = String(sh["source"])
			origins.append(sh["origin"])
	var names: Array = a._by_name.keys()
	if origins.is_empty():
		for d in all:
			root.remove_child(d)
			d.free()
		return
	var pristine := texts.duplicate()
	for step in steps:
		# Input between edits: states, and running transitions to end.
		if not names.is_empty():
			var nm: String = names[rng.randi() % names.size()]
			var st: String = ["hover", "focus", "active", "checked"][rng.randi() % 4]
			var on := rng.randi() % 2 == 0
			for d in all:
				d.set_element_state(nm, st, on)
			if rng.randi() % 3 == 0:
				for d in all:
					d._restyle_now()
					d.advance_transitions(0.1)
		var origin: String = origins[rng.randi() % origins.size()]
		var text: String = texts[origin]
		var prev_text := text
		if text.length() > 20000 or rng.randi() % 16 == 0:
			text = pristine[origin]  # back to the first text (edits accumulate)
		text = _edit_sheet(text, origin, rng)
		texts[origin] = text
		var was := UssCascade.use_native
		for d in all:
			if d == c or d == g:
				UssCascade.use_native = false
			d.reload_stylesheet(origin, text)
			UssCascade.use_native = was
		var mode: String = b.get_last_reload_mode()
		_reload_modes[mode] = int(_reload_modes.get(mode, 0)) + 1
		if mode != c.get_last_reload_mode():
			_fails += 1
			print("FAIL %s step %d: reload mode %s vs %s" % [path, step, mode, c.get_last_reload_mode()])
		await process_frame
		for d in all:
			d._restyle_now()
		await process_frame
		if OS.has_environment("RELOAD_TRACE"):
			print("STEP %s %d %s origin=%s\n%s\n---" % [path, step, mode, origin, _diff_text(prev_text, text)])
		_cmp_reload("%s reload step %d (%s)" % [path, step, mode], a, b)
		_cmp_reload("%s reload step %d (%s, GDScript)" % [path, step, mode], g, c)
		_cmp_reload("%s reload step %d (%s, full native vs full GDScript)" % [path, step, mode], a, g)
		_cmp_reload("%s reload step %d (%s, native vs GDScript)" % [path, step, mode], b, c)
	for d in all:
		root.remove_child(d)
		d.free()


var _frng := RandomNumberGenerator.new()


## Child indices from the root to `el`, to find the same element in the
## other documents.
static func _path_of(d, el) -> Array:
	var out: Array = []
	var cur = el
	while cur != d._doc.root:
		var p = d._parents.get(cur)
		if p == null:
			return []
		out.push_front((p.children as Array).find(cur))
		cur = p
	return out


static func _at_path(d, path: Array):
	var cur = d._doc.root
	for i in path:
		cur = cur.children[i]
	return cur


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
			if typeof(a[k]) != typeof(b[k]) or a[k] != b[k]:
				return _leaf(a[k], b[k], "%s.%s" % [path, k])
		for k in b:
			if not a.has(k):
				return "%s.%s extra in new" % [path, k]
	return "%s: %s vs %s" % [path, a, b]


func _diags(d) -> Array:
	var out: Array = []
	for w in d.diagnostics:
		out.append([w["kind"], w["message"], w["file"], w["line"], w["column"], w.get("end_offset")])
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
	if r is FontFile:
		# (unity/fidelity) A font file by identity: its storage holds the
		# whole font data and the glyph caches. Every text control now has a
		# FontVariation over the theme font (Unity's line height), so a
		# snapshot by value copied megabytes per control and step.
		return [r.get_class(), r.resource_path, r.get_instance_id()]
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
