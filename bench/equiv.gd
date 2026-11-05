extends SceneTree
## Equivalence check: the optimized cascade (UssStyleResolver / UssCascade)
## against the original resolver kept verbatim in bench/ref/ (extracted from
## git at the pre-optimization commit). Compares computed styles INCLUDING
## Dictionary key order, and the full warnings array, on every test fixture
## plus the synthetic bench document, for several option sets — and drives
## random incremental update() sequences (state/class/style/enabled churn)
## against fresh reference resolves.
##
##   Godot --headless --path <project> -s res://bench/equiv.gd
## Run bench/bench.gd once first so the synthetic document exists.

var _fails := 0
var _checks := 0


func _initialize() -> void:
	if OS.get_cmdline_user_args().has("--gdscript"):
		UssCascade.use_native = false  # exercise the GDScript reference path
	# The comparator must be able to fail: key order, nested values, arrays.
	assert(not _diff({"a": 1, "b": 2}, {"b": 2, "a": 1}, "").is_empty())
	assert(not _diff({"a": {"v": [1, 2]}}, {"a": {"v": [1, 3]}}, "").is_empty())
	assert(_diff({"a": {"v": [1, 2]}}, {"a": {"v": [1, 2]}}, "").is_empty())
	if not _diff({"a": 1, "b": 2}, {"b": 2, "a": 1}, "").is_empty():
		print("comparator self-test ok")
	var docs: Array = []
	for pair in [
		["res://tests/fixtures/runtime", "Assets/UI/runtime.uxml"],
		["res://tests/fixtures/runtime", "Assets/UI/review.uxml"],
		["res://tests/fixtures/runtime", "Assets/UI/bad.uxml"],
		["res://tests/fixtures/options", "Assets/UI/Options.uxml"],
		["res://tests/fixtures/menu", "Assets/UI/Menu.uxml"],
		["res://tests/fixtures/resolution", "Assets/UI/screen.uxml"],
		["res://tests/fixtures/nested-styles", "Assets/UI/Nested.uxml"],
		["res://tests/fixtures/malformed", "Assets/UI/Malformed.uxml"],
		["res://tests/fixtures/unsupported", "Assets/UI/Unsupported.uxml"],
		["res://tests/fixtures/assets", "Assets/UI/Assets.uxml"],
		["res://tests/fixtures/scope", "Assets/UI/scoped.uxml"],
		["res://tests/fixtures/traversal", "Assets/UI/main.uxml"],
		["res://tests/fixtures/cycle", "Assets/UI/cycle.uxml"],
		["res://tests/fixtures/origin", "Assets/UI/panel.uxml"],
		["res://tests/fixtures/templates", "Assets/UI/Main.uxml"],
		["user://godot_uxml_bench", "Assets/UI/big.uxml"],
		["user://godot_uxml_bench", "Assets/UI/hud.uxml"],
	]:
		var d := UxmlLoader.load_file(pair[1], pair[0])
		if d.path.is_empty():
			print("skip (missing): %s" % pair[1])
			continue
		docs.append([pair[1], d])
	docs.append(["inline-var", _inline_doc()])

	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for entry in docs:
		var name: String = entry[0]
		var d: UxmlDocumentModel = entry[1]
		var els := d.root.walk()
		for opts in _option_sets(d, els, rng):
			_compare(name, d, opts)
		_incremental(name, d, els, rng, 60 if els.size() < 300 else 15)
	print("EQUIV %s: %d checks, %d failures" % ["OK" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


func _inline_doc() -> UxmlDocumentModel:
	var uxml := """<ui:UXML xmlns:ui="UnityEngine.UIElements">
  <ui:VisualElement name="a" class="x y" style="--p: 3px; padding: var(--p) 2px; color: var(--c, red); margin: 1px 2px 3px 4px 5px; bogus">
    <ui:Label name="b" class="z" style="--c: var(--c); font-size: var(--missing); /*c*/ color: blue" />
    <ui:Button name="c" class="x" enabled="false" style="gap: 1px 2px 3px; flex: 1 0 auto" />
  </ui:VisualElement>
</ui:UXML>"""
	var uss := """
:root { --c: green; --pad: 4px 8px; }
.x { color: var(--c); padding: var(--pad); }
.x .z, .y > .z { color: red; border-width: 1px 2px; }
.x:hover .z { color: yellow; }
Button:disabled { color: gray; }
#b:focus { font-size: 20px; }
.z::before { color: red; }
.x + .z { color: red; }
* { --u: 1px; }
"""
	return UxmlLoader.load_source(uxml, "res://inline.uxml", UxmlResourceResolver.new("res://"), uss)


func _option_sets(d: UxmlDocumentModel, els: Array, rng: RandomNumberGenerator) -> Array:
	var out: Array = [{}, {"active_states": ["hover"]}, {"active_states": ["disabled", "focus"]}]
	out.append({"states": {"Button": ["hover"], ".card": ["focus"], "[x]": ["hover"], "#nope": ["active"]}})
	for _k in 3:
		var es := {}
		var dis := {}
		var en := {}
		for _j in 6:
			var el: UxmlElement = els[rng.randi() % els.size()]
			es[el] = [["hover"], ["focus", "active"], ["checked", "bogus"], ["selected"]][rng.randi() % 4]
		for _j in 2:
			dis[els[rng.randi() % els.size()]] = true
			en[els[rng.randi() % els.size()]] = true
		out.append({"element_states": es, "disabled_elements": dis, "enabled_elements": en})
	return out


func _compare(name: String, d: UxmlDocumentModel, opts: Dictionary) -> void:
	var a := RefStyleResolver.resolve(d, opts)
	var b := UssStyleResolver.resolve(d, opts)
	_same_result(name, a, b["styles"], b["warnings"])


func _same_result(name: String, ref: Dictionary, styles: Dictionary, warnings: Array) -> void:
	_checks += 1
	var why := _diff(ref["styles"], styles, "styles")
	if why.is_empty():
		why = _diff(ref["warnings"], warnings, "warnings")
	if not why.is_empty():
		_fails += 1
		if _fails <= 10:
			print("FAIL %s: %s" % [name, why])


## "" when a and b are equal including Dictionary key order.
func _diff(a, b, path: String) -> String:
	if typeof(a) != typeof(b):
		return "%s: type %s vs %s" % [path, typeof(a), typeof(b)]
	if a is Dictionary:
		var ka: Array = a.keys()
		var kb: Array = b.keys()
		if ka.size() != kb.size():
			return "%s: %d keys vs %d" % [path, ka.size(), kb.size()]
		for i in ka.size():
			if typeof(ka[i]) != typeof(kb[i]) or ka[i] != kb[i]:
				return "%s: key order differs at %d (%s vs %s)" % [path, i, ka[i], kb[i]]
			var sub := _diff(a[ka[i]], b[kb[i]], "%s.%s" % [path, ka[i]])
			if not sub.is_empty():
				return sub
		return ""
	if a is Array:
		if a.size() != b.size():
			return "%s: size %d vs %d" % [path, a.size(), b.size()]
		for i in a.size():
			var sub := _diff(a[i], b[i], "%s[%d]" % [path, i])
			if not sub.is_empty():
				return sub
		return ""
	if a is Object:
		return "" if a == b else "%s: object differs" % path
	return "" if a == b else "%s: %s vs %s" % [path, a, b]


## Random runtime-style churn applied to the model, incremental update()
## after each step, compared against a fresh reference resolve.
func _incremental(name: String, d: UxmlDocumentModel, els: Array, rng: RandomNumberGenerator, steps: int) -> void:
	var vocab: Array = []
	for el in els:
		for c in el.class_list():
			if not vocab.has(c):
				vocab.append(c)
	vocab.append_array(["card--selected", "x", "y", "z", "list-item"])
	var cas := UssCascade.new(d)
	var es := {}
	var dis := {}
	var en := {}
	var opts := {"element_states": es, "disabled_elements": dis, "enabled_elements": en}
	cas.update(opts)
	for _s in steps:
		var el: UxmlElement = els[rng.randi() % els.size()]
		match rng.randi() % 6:
			0, 1:
				var st: String = ["hover", "focus", "active", "checked", "selected"][rng.randi() % 5]
				var cur: Array = es.get(el, [])
				cur = cur.duplicate()
				if cur.has(st):
					cur.erase(st)
				else:
					cur.append(st)
				if cur.is_empty():
					es.erase(el)
				else:
					es[el] = cur
			2:
				var cls := PackedStringArray()
				for _j in rng.randi() % 3:
					cls.append(vocab[rng.randi() % vocab.size()])
				_set_attr(el, "class", " ".join(cls))
			3:
				if dis.has(el):
					dis.erase(el)
				else:
					dis[el] = true
			4:
				if en.has(el):
					en.erase(el)
				else:
					en[el] = true
			5:
				_set_attr(el, "style", ["color: red;", "--c: blue; padding: var(--c)", "", "margin: 2px"][rng.randi() % 4])
		cas.update(opts)
		var ref := RefStyleResolver.resolve(d, opts)
		_same_result("%s incremental" % name, ref, cas.styles, cas.collect_warnings())


func _set_attr(el: UxmlElement, attr: String, value: String) -> void:
	for a in el.attributes:
		if a["name"] == attr:
			a["value"] = value
			return
	el.attributes.append({"name": attr, "value": value, "offset": 0})
