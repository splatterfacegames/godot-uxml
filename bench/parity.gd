extends SceneTree
## Parity against the reference engine and against Unity itself.
##
## Part 1 — reference engine: the uxml-preview golden cases (exported with
## their committed geometry snapshots into bench/parity/reference.json by
## bench/parity/export_reference.mjs). Each case goes through godot-uxml's
## own loader, default theme (UxmlTheme), control part trees (UxmlParts),
## cascade and flex layout with the reference's deterministic text measure
## (half an em per character, one line, font-size or 12px), then panel-space
## rects are compared by element name at the reference's 0.1px rounding.
## Parts the reference names (`unity-*`) that godot-uxml does not build yet
## are reported separately, never as matches.
##
## Part 2 — Unity: every case with a Unity dump in bench/parity/unity/
## (written by tools/unity-dump/run.py from Unity 6000.3 with its default
## runtime theme) — the reference cases above and the control corpus in
## bench/parity/cases/. Elements are matched by tree path, parts included,
## and compared on:
##   * structure: type, name and classes of every element;
##   * geometry: panel-space rect at 0.1px, with Unity's own text measure
##     for every text element (so Unity's font metrics do not count against
##     the layout) — falls back to half an em when Unity has no measure;
##   * style: margins, padding, border widths and colours, background and
##     text colour, font-size, -unity-text-align and opacity.
## Unity's pseudo-states and control values after the case's actions are
## applied to the godot-uxml model first, so a state case tests the theme
## and the cascade for that state.
##
## Negative cases (after the Slint fork's Compose parity harness): perturbed
## results that the comparison must reject, so a broken comparator cannot
## report parity.
##
## Part 3 — panel scaling: every dump in bench/parity/unity-scaled/ (the
## cases of bench/parity/scaled/matrix.json under Unity's PanelSettings at
## several screens, tools/unity-dump/run.py --scaled). The scale must
## resolve as Unity's (pixels per point and panel size, UxmlPanelScale);
## the case is laid out in points at Unity's panel size and rounded on the
## pixel grid at Unity's pixels per point, and compared as in part 2, the
## geometry in pixels (0.1px).
##
##   Godot --headless --path <project> -s res://bench/parity.gd [-- --verbose]

const REF := "res://bench/parity/reference.json"
const UNITY_DIR := "res://bench/parity/unity/"
const CASES_DIR := "res://bench/parity/cases/"
const SCALED_DIR := "res://bench/parity/unity-scaled/"
const SCALED_CASES := "res://bench/parity/scaled/cases/"
const STATES := ["hover", "active", "focus", "checked", "selected"]

var _verbose := false
## The pixel grid of the case being compared (panel scaling; 1 otherwise).
var _ppp := 1.0


func _initialize() -> void:
	_verbose = OS.get_cmdline_user_args().has("--verbose")
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(REF))
	var panel := Vector2(data["panel"]["width"], data["panel"]["height"])
	var rows: Array = []
	var counts := {"match": 0, "parts-only": 0, "differs": 0, "no-reference": 0}
	var negatives_ok := true
	var unity_cases: Array = []
	for c in data["cases"]:
		var r := _run_case(c, panel)
		counts[r["status"]] += 1
		rows.append(r)
		if r["status"] == "match" and not r["ours"].is_empty():
			negatives_ok = _negative(c, r) and negatives_ok
		unity_cases.append({"name": c["name"], "uxml": c["uxml"], "uss": c["uss"], "files": c["files"]})
	_report(data, rows, counts, negatives_ok)
	for n in _corpus_names():
		var uss_path: String = CASES_DIR + n + ".uss"
		unity_cases.append({"name": n,
			"uxml": FileAccess.get_file_as_string(CASES_DIR + n + ".uxml"),
			"uss": FileAccess.get_file_as_string(uss_path) if FileAccess.file_exists(uss_path) else "",
			"files": _case_files(CASES_DIR + n + ".files")})
	_unity_project_data()
	var unity_ok := _unity_section(unity_cases)
	var scaled_ok := _scaled_section()
	# The runtime section loads documents in the tree: after the first frame.
	_finish.call_deferred(unity_cases, 0 if negatives_ok and unity_ok and scaled_ok else 1)


func _finish(unity_cases: Array, code: int) -> void:
	await _runtime_section(unity_cases)
	quit(code)


## The other files of a corpus case (<name>.files/: templates, sheets),
## keyed by their path relative to that folder.
func _case_files(dir: String, rel: String = "") -> Dictionary:
	var out := {}
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		# Bytes: a case can have images beside its sheets.
		out[rel + f] = FileAccess.get_file_as_bytes(dir + "/" + f)
	for sub in d.get_directories():
		out.merge(_case_files(dir + "/" + sub, rel + sub + "/"))
	return out


func _corpus_names() -> Array:
	var out: Array = []
	var d := DirAccess.open(CASES_DIR)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".uxml"):
			out.append(f.get_basename())
	out.sort()
	return out


# ---------------------------------------------------------------------------
# Shared pipeline
# ---------------------------------------------------------------------------

## Write a case to user://, load it with the default theme and part trees.
func _load_case(name: String, uxml: String, uss: String, files: Dictionary, values: Dictionary = {},
		actions: Array = [], side: Dictionary = {}) -> UxmlDocumentModel:
	var root := "user://godot_uxml_parity/%s" % name
	var dir := root + "/Assets/GoldenCases/"
	DirAccess.make_dir_recursive_absolute(dir)
	for path in files:
		# Project-rooted keys (Packages/…, Assets/…) live at the project root,
		# the rest beside the case — the reference harness's resolveImport.
		var p: String = path
		var at := root + "/" + p if (p.begins_with("Packages/") or p.begins_with("Assets/")) else dir + p
		_write(at, files[path])
	var uxml_path := dir + name + ".uxml"
	_write(uxml_path, uxml)
	var resolver := UxmlResourceResolver.new(root)
	var doc := UxmlLoader.load_source(uxml, uxml_path, resolver, uss)
	if not values.is_empty():
		for el in doc.root.walk():
			var n = el.get_attribute("name")
			if n != null and values.has(String(n)):
				var vs: Dictionary = values[String(n)]
				for k in vs:
					el.set_attribute(k, vs[k])
	# Editor cases (sidecar "editor": "dark" | "light") ran in an editor
	# panel: the editor theme of that skin.
	var skin := String(side.get("editor", ""))
	UxmlTheme.attach(doc, UxmlTheme.DEFAULT, "always" if not skin.is_empty() else "auto",
		skin if not skin.is_empty() else "dark")
	UxmlParts.expand(doc)
	_model_actions(doc, actions)
	if side.has("bind"):
		_bind_editor(doc, String(side["bind"]), root)
	return doc


## Unity's project data in the dump project: the built-in layers and tags,
## one rendering layer, and the DumpFlags enum of tools/unity-dump.
func _unity_project_data() -> void:
	var layers: Array = []
	layers.resize(32)
	layers.fill("")
	layers[0] = "Default"
	layers[1] = "TransparentFX"
	layers[2] = "Ignore Raycast"
	layers[4] = "Water"
	layers[5] = "UI"
	UxmlEditorParts.set_layer_names(layers)
	UxmlEditorParts.set_rendering_layer_names(["Default"])
	UxmlEditorParts.set_tags(UxmlEditorParts.UNITY_TAGS)
	UxmlInputParts.register_enum("DumpFlags", {"None": 0, "Alpha": 1, "Beta": 2, "Gamma": 4, "AlphaBeta": 3})


## The Godot stand-ins of the ScriptableObjects that the editor cases bind
## (tools/unity-dump/Assets/Editor/DumpTarget.cs, DumpSmallTarget.cs).
const BIND_SCRIPTS := {
	"DumpTarget": """extends Resource
enum DumpEnum { First, SecondValue, Third }
@export var intValue: int = 42
@export var floatValue: float = 1.5
@export var stringValue: String = "hello"
@export var boolValue: bool = true
@export var colorValue: Color = Color(1, 0.5, 0, 1)
@export var vector2Value: Vector2 = Vector2(1, 2)
@export var vector3Value: Vector3 = Vector3(1, 2, 3)
@export var enumValue: DumpEnum = DumpEnum.SecondValue
@export_flags("Alpha", "Beta", "Gamma") var flagsValue: int = 5
@export var curveValue: Curve = Curve.new()
@export var gradientValue: Gradient = Gradient.new()
@export var textureValue: Texture2D
@export_flags_3d_physics var layerMaskValue: int = 1
""",
	"DumpSmallTarget": """extends Resource
@export var count: int = 3
@export var title: String = "Hi"
@export var active: bool = false
""",
}


## Bound editor cases: the fields that PropertyField and InspectorElement
## build at bind time, from the Godot stand-in object.
func _bind_editor(doc: UxmlDocumentModel, type_name: String, root: String) -> void:
	var path := root + "/" + type_name + ".gd"
	_write(path, BIND_SCRIPTS[type_name])
	var script := GDScript.new()
	script.source_code = BIND_SCRIPTS[type_name]
	script.resource_path = path
	script.reload()
	var obj = script.new()
	var props := {}
	for p in obj.get_property_list():
		props[String(p["name"])] = p
	for el in doc.root.walk():
		if el.part_of != null:
			continue
		if el.local == "PropertyField":
			var bp := String(el.get_attribute("binding-path"))
			if props.has(bp):
				el.children.append(UxmlEditorParts.property_field_content(el, props[bp], obj.get(bp), false))
		elif el.local == "InspectorElement":
			UxmlEditorParts.inspector_content(el, obj)


## The sidecar actions that give a control data instead of input (Unity's
## itemsSource, SetRootItems, SetSelection, scrollOffset), applied to the
## model the way the runtime applies them.
func _model_actions(doc: UxmlDocumentModel, actions: Array) -> void:
	var lists := {}  # element -> {texts, infos, selection}
	for act in actions:
		var op := String(act.get("op", ""))
		var el: UxmlElement = null
		if act.has("target"):
			el = doc.root.find_by_name(String(act["target"]))
		if el == null:
			continue
		match op:
			"breadcrumbs":
				for t in act.get("items", []):
					el.children.append(UxmlEditorParts.breadcrumb_item(el, str(t)))
			"items":
				var texts: Array = []
				if act.has("values"):
					for v in act["values"]:
						texts.append(str(v))
				else:
					for i in int(act.get("count", 0)):
						texts.append("Item %d" % i)
				var st: Dictionary = lists.get(el, {"selection": []})
				st["texts"] = texts
				st["infos"] = []
				lists[el] = st
			"tree-items":
				var roots: Array = act.get("items", [])
				var open := UxmlContainerParts.tree_ids(roots) if act.get("expand", false) else {}
				var flat := UxmlContainerParts.flatten_tree(roots, open)
				var texts: Array = []
				for f in flat:
					texts.append(str(f["data"]))
				var st: Dictionary = lists.get(el, {"selection": []})
				st["texts"] = texts
				st["infos"] = flat
				lists[el] = st
			"select":
				var st: Dictionary = lists.get(el, {"texts": [], "infos": []})
				st["selection"] = act.get("indices", [])
				lists[el] = st
			"scroll":
				var sv := el if el.local == "ScrollView" else UxmlParts.find_part(el, "scroll-view")
				if sv != null:
					UxmlContainerParts.set_scroll_offset(sv,
						Vector2(float(act.get("x", 0)), float(act.get("y", 0))), false)
			"wheel":
				# The after-layout pass clamps the offset to the range.
				var sv := el if el.local == "ScrollView" else UxmlParts.find_part(el, "scroll-view")
				if sv != null:
					var m := UxmlContainerParts.scroll_mode(sv)
					UxmlContainerParts.set_scroll_offset(sv, UxmlContainerParts.wheel_offset(sv,
						Vector2(float(act.get("dx", 0)), float(act.get("dy", 0))),
						m != "horizontal", m != "vertical"), false)
	for el in lists:
		var st: Dictionary = lists[el]
		var texts: Array = st["texts"]
		var rows := UxmlContainerParts.rows_of(el)
		var sel: Array = []
		for i in st["selection"]:
			sel.append(int(i))
		for k in rows.size():
			var idx := k if k < texts.size() else -1
			var info: Dictionary = st["infos"][k] if k < st["infos"].size() else {}
			UxmlContainerParts.bind_row(el, rows[k], idx, sel.has(k), info)
			if idx >= 0:
				UxmlContainerParts.bind_text(rows[k], texts[k])
		if UxmlContainerParts.is_dynamic(el):
			# DynamicHeight: the runtime sets the content to the measured
			# rows (every row of these cases is in view): auto.
			UxmlContainerParts.content_extent(el, -1.0, 0.0)
		else:
			UxmlContainerParts.content_height(el, texts.size())
		el.set_meta(&"parity_count", texts.size())


## Unity's post-layout control updates, then a new layout, until the model
## stops changing: ScrollView scrollers (UxmlContainerParts.after_layout)
## and the row count of collection views, which Unity sizes to the
## viewport (floor(viewport / item height) + 2).
func _settle(doc: UxmlDocumentModel, resolve: Callable, layout: Callable) -> Array:
	var styles: Dictionary = resolve.call()
	var res: Dictionary = layout.call(styles)
	for pass_i in 8:
		var rects: Dictionary = res["rects"]
		var size_of := func(el: UxmlElement):
			var r = rects.get(el)
			return null if r == null else (r as Rect2).size
		var rect_of := func(el: UxmlElement):
			return rects.get(el)
		var bounds_of := func(el: UxmlElement):
			return UxmlContainerParts.bounding_size(el, rect_of)
		var changed := UxmlContainerParts.after_layout(doc.root, size_of, bounds_of)
		for el in doc.root.walk():
			if not UxmlContainerParts.is_collection(el.local) or el.part_of != null:
				continue
			var rows := UxmlContainerParts.rows_of(el)
			var sv := UxmlParts.find_part(el, "scroll-view")
			var vp: UxmlElement = null if sv == null else UxmlParts.find_part(sv, "viewport")
			var vs = null if vp == null else size_of.call(vp)
			if vs == null:
				continue
			var want := mini(int(el.get_meta(&"parity_count", 0)),
				int(floor((vs as Vector2).y / UxmlContainerParts.item_height(el))) + 2)
			if rows.size() > want:
				UxmlContainerParts.trim_rows(el, want)
				changed = true
		if not changed:
			break
		styles = resolve.call()
		res = layout.call(styles)
	return [styles, res]


func _measure_fixed(el: UxmlElement, style: Dictionary, _hint: float) -> Vector2:
	var t = el.get_attribute("text")
	if t == null or String(t).is_empty():
		return Vector2.ZERO
	var fs := 12.0
	var e = style.get("font-size")
	if e != null:
		var p := UssValues.parse_length(String(e["value"]))
		if p["kind"] == "px":
			fs = p["value"]
	return Vector2(String(t).length() * fs * 0.5, fs)


# ---------------------------------------------------------------------------
# Part 1: reference engine
# ---------------------------------------------------------------------------

func _run_case(c: Dictionary, panel: Vector2) -> Dictionary:
	var name: String = c["name"]
	var doc := _load_case(name, c["uxml"], c["uss"], c["files"])
	var warnings: Array = []
	var settled := _settle(doc,
		func(): return UssStyleResolver.resolve(doc)["styles"],
		func(st: Dictionary): return UxmlFlexLayout.compute(doc.root, st, panel, _measure_fixed, warnings, {}))
	var res: Dictionary = settled[1]
	var ours := _named_rects(doc.root, res["rects"], settled[0])
	var out := {"name": name, "question": c["question"], "ours": ours,
		"measures_text": c["measuresText"], "missing_parts": [], "missing": [],
		"diffs": [], "status": "no-reference"}
	var exp = c["expected"]
	if exp == null:
		return out
	var expected: Dictionary = exp["elements"]
	_compare(expected, ours, out)
	if out["diffs"].is_empty() and out["missing"].is_empty():
		out["status"] = "match" if out["missing_parts"].is_empty() else "parts-only"
	else:
		out["status"] = "differs"
	return out


## Named authored elements' panel-space rects, keyed like the reference
## harness: a name that appears once keeps it, repeats get #1..#n in tree
## order. Parts count too (the reference names Unity's parts).
func _named_rects(root: UxmlElement, rects: Dictionary, styles: Dictionary = {}) -> Dictionary:
	var collected: Array = []
	var stack: Array = [[root, Vector2.ZERO]]
	while not stack.is_empty():
		var fr: Array = stack.pop_back()
		var el: UxmlElement = fr[0]
		var origin: Vector2 = fr[1]
		var r = rects.get(el)
		var abs_pos := origin
		if r != null:
			abs_pos = origin + (r as Rect2).position + _translate(styles.get(el, {}), (r as Rect2).size)
			var n = el.get_attribute("name")
			if n != null and el != root:
				collected.append([String(n), Rect2(abs_pos, (r as Rect2).size)])
		var kids: Array = el.children
		for k in range(kids.size() - 1, -1, -1):
			stack.append([kids[k], abs_pos])
	var counts := {}
	for e in collected:
		counts[e[0]] = counts.get(e[0], 0) + 1
	var seen := {}
	var out := {}
	for e in collected:
		var key: String = e[0]
		if counts[key] > 1:
			seen[key] = seen.get(key, 0) + 1
			key = "%s#%d" % [key, seen[key]]
		out[key] = e[1]
	return out


func _r1(v: float) -> float:
	return roundf(v * 10.0) / 10.0


func _compare(expected: Dictionary, ours: Dictionary, out: Dictionary) -> void:
	for key in expected:
		var e: Dictionary = expected[key]
		if not ours.has(key):
			if String(key).begins_with("unity-"):
				out["missing_parts"].append(key)
			else:
				out["missing"].append(key)
			continue
		var o: Rect2 = ours[key]
		var got := [_r1(o.position.x), _r1(o.position.y), _r1(o.size.x), _r1(o.size.y)]
		var want := [float(e["x"]), float(e["y"]), float(e["width"]), float(e["height"])]
		for k in 4:
			if absf(got[k] - want[k]) > 0.05:
				out["diffs"].append("%s: ours (%s, %s, %s x %s) vs ref (%s, %s, %s x %s)" % [
					key, got[0], got[1], got[2], got[3], want[0], want[1], want[2], want[3]])
				break


## The comparator must reject a 1px shift and a missing element.
func _negative(c: Dictionary, r: Dictionary) -> bool:
	var expected: Dictionary = c["expected"]["elements"]
	var ours: Dictionary = r["ours"].duplicate()
	var key: String = ours.keys()[0]
	var shifted: Rect2 = ours[key]
	ours[key] = Rect2(shifted.position + Vector2(1, 0), shifted.size)
	var o1 := {"missing_parts": [], "missing": [], "diffs": []}
	_compare(expected, ours, o1)
	ours = r["ours"].duplicate()
	ours.erase(key)
	var o2 := {"missing_parts": [], "missing": [], "diffs": []}
	_compare(expected, ours, o2)
	var ok: bool = not o1["diffs"].is_empty() and (not o2["missing"].is_empty() or not o2["missing_parts"].is_empty())
	if not ok:
		print("NEGATIVE CASE NOT DETECTED in %s" % c["name"])
	return ok


func _write(path: String, content: Variant) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if content is PackedByteArray:
		f.store_buffer(content)
	else:
		f.store_string(content)
	f.close()


func _report(data: Dictionary, rows: Array, counts: Dictionary, negatives_ok: bool) -> void:
	print("parity vs %s @ %s" % [data["source"], String(data["commit"]).substr(0, 7)])
	print("| case | status | notes |")
	print("| --- | --- | --- |")
	for r in rows:
		var notes: Array = []
		if r["measures_text"]:
			notes.append("measures text")
		if not r["diffs"].is_empty():
			notes.append("; ".join(r["diffs"].slice(0, 3)) + (" (+%d more)" % (r["diffs"].size() - 3) if r["diffs"].size() > 3 else ""))
		if not r["missing"].is_empty():
			notes.append("missing: " + ", ".join(r["missing"]))
		if not r["missing_parts"].is_empty():
			notes.append("control parts not modeled: %d" % r["missing_parts"].size())
		print("| %s | %s | %s |" % [r["name"], r["status"], " / ".join(notes)])
	print("")
	print("PARITY: %d match, %d match except control parts, %d differ, %d without reference; negative cases %s" % [
		counts["match"], counts["parts-only"], counts["differs"], counts["no-reference"],
		"detected" if negatives_ok else "NOT DETECTED"])


# ---------------------------------------------------------------------------
# Part 2: Unity
# ---------------------------------------------------------------------------

## Our elements by Unity-style tree path ("0/1/0"): children indices of
## visual elements under the document root, parts included.
func _paths(root: UxmlElement) -> Dictionary:
	var out := {}
	var stack: Array = [[root, ""]]
	while not stack.is_empty():
		var fr: Array = stack.pop_back()
		var el: UxmlElement = fr[0]
		var base: String = fr[1]
		var k := 0
		for ch in el.children:
			if UssControls.is_non_visual(ch.local):
				continue
			var p := str(k) if base.is_empty() else base + "/" + str(k)
			out[p] = ch
			stack.append([ch, p])
			k += 1
	return out


func _unity_section(cases: Array) -> bool:
	var rows: Array = []
	var tot := {"cases": 0, "match": 0, "elements": 0, "struct_ok": 0,
		"geo": 0, "geo_ok": 0, "geo_half": 0, "style": 0, "style_ok": 0, "pixel_only": 0,
		"diag": 0, "diag_ok": 0, "props": 0, "props_ok": 0}
	var negatives_ok := true
	for c in cases:
		var dpath: String = UNITY_DIR + String(c["name"]) + ".json"
		if not FileAccess.file_exists(dpath):
			continue
		var dump: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dpath))
		var r := _run_unity(c, dump)
		rows.append(r)
		tot["cases"] += 1
		for k in ["elements", "struct_ok", "geo", "geo_ok", "geo_half", "style", "style_ok", "diag", "diag_ok", "props", "props_ok"]:
			tot[k] += r[k]
		if (r["status"] != "match" and r["struct_ok"] == r["elements"] and r["style_ok"] == r["style"]
				and r["geo_ok"] + r["geo_half"] == r["geo"]):
			tot["pixel_only"] += 1
		if r["status"] == "match":
			tot["match"] += 1
			negatives_ok = _unity_negative(r) and negatives_ok
	print("")
	if rows.is_empty():
		print("UNITY PARITY: no Unity dumps in %s (run tools/unity-dump/run.py)" % UNITY_DIR)
		return true
	var meta: Dictionary = {}
	var d0: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(UNITY_DIR + String(rows[0]["name"]) + ".json"))
	meta = d0.get("metadata", {})
	print("parity vs Unity %s (%s), pixelsPerPoint %s" % [
		meta.get("unityVersion", "?"), meta.get("theme", "?"), meta.get("pixelsPerPoint", "?")])
	print("| case | status | structure | geometry | style | first differences |")
	print("| --- | --- | ---: | ---: | ---: | --- |")
	for r in rows:
		var notes: Array = r["notes"]
		var shown := "; ".join(notes.slice(0, 3 if not _verbose else notes.size()))
		if notes.size() > 3 and not _verbose:
			shown += " (+%d more)" % (notes.size() - 3)
		print("| %s | %s | %d/%d | %d/%d | %d/%d | %s |" % [r["name"], r["status"],
			r["struct_ok"], r["elements"], r["geo_ok"], r["geo"], r["style_ok"], r["style"], shown])
	print("")
	# Unity rounds every layout edge to the pixel grid (Yoga's
	# RoundToPixelGrid); godot-uxml's layout keeps fractions. Differences of
	# at most half a pixel are counted separately so other causes stand out.
	print("UNITY PARITY: %d/%d cases match (%d more differ only by pixel-grid rounding); structure %d/%d elements, geometry %d/%d values (%d more within 0.5px), style %d/%d values, element properties %d/%d, import diagnostics %d/%d; negative cases %s" % [
		tot["match"], tot["cases"], tot["pixel_only"], tot["struct_ok"], tot["elements"], tot["geo_ok"], tot["geo"],
		tot["geo_half"], tot["style_ok"], tot["style"], tot["props_ok"], tot["props"], tot["diag_ok"], tot["diag"],
		"detected" if negatives_ok else "NOT DETECTED"])
	return negatives_ok


## The runtimes' rects against Unity's, for the corpus cases whose sidecar
## has `"runtime": true`: the sections above lay the model out without
## Controls; here each case loads in a UxmlDocument on runtime v1 (one Control
## per element, which Godot floors at its minimum size) and on runtime v2,
## and every element's get_element_rect() is compared with Unity's panel
## rect (to 0.5px). Measured, not gated.
func _runtime_section(cases: Array) -> void:
	var tot := {1: [0, 0], 2: [0, 0]}
	var notes: Array = []
	var names: Array = []
	for c in cases:
		var side_path: String = CASES_DIR + String(c["name"]) + ".json"
		var dpath: String = UNITY_DIR + String(c["name"]) + ".json"
		if not FileAccess.file_exists(side_path) or not FileAccess.file_exists(dpath):
			continue
		var side = JSON.parse_string(FileAccess.get_file_as_string(side_path))
		if not side is Dictionary or not bool(side.get("runtime", false)):
			continue
		names.append(c["name"])
		var dump: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dpath))
		var size := Vector2(float(side.get("width", 400)), float(side.get("height", 300)))
		for rt in [1, 2]:
			var d := UxmlDocument.new()
			d.auto_load = false
			d.runtime = rt
			root.add_child(d)
			d.size = size
			d._clear()
			var base := "user://godot_uxml_parity_runtime/" + String(c["name"])
			DirAccess.make_dir_recursive_absolute(base + "/Assets/GoldenCases")
			d._resolver = UxmlResourceResolver.new(base)
			d._doc = UxmlLoader.load_source(c["uxml"], base + "/Assets/GoldenCases/case.uxml", d._resolver, c["uss"])
			UxmlTheme.attach(d._doc, d.theme_path, d.editor_theme, d.editor_skin)
			d._start_runtime()
			# Runtime v1 settles over frames (bench/equiv_v2.gd _settle).
			for k in 4:
				d._restyle_now()
				await process_frame
			var ours := _paths(d._doc.root)
			for e in dump["elements"]:
				var el = ours.get(String(e["path"]))
				if el == null:
					continue
				var u: Dictionary = e["rect"]
				var ur := Rect2(float(u["x"]), float(u["y"]), float(u["width"]), float(u["height"]))
				var gr := d.get_element_rect(el)
				tot[rt][1] += 1
				if absf(gr.position.x - ur.position.x) <= 0.5 and absf(gr.position.y - ur.position.y) <= 0.5 						and absf(gr.size.x - ur.size.x) <= 0.5 and absf(gr.size.y - ur.size.y) <= 0.5:
					tot[rt][0] += 1
				elif notes.size() < 6:
					notes.append("%s runtime v%d %s %s: %s vs Unity %s" % [c["name"], d.get_runtime(), e["path"],
						e["type"] + ("#" + String(e["name"]) if not String(e["name"]).is_empty() else ""), gr, ur])
			root.remove_child(d)
			d.free()
	if names.is_empty():
		return
	print("")
	for n in notes:
		print("  " + n)
	print("UNITY RUNTIME RECTS: runtime v1 %d/%d, runtime v2 %d/%d within 0.5px (%s)" % [
		tot[1][0], tot[1][1], tot[2][0], tot[2][1], ", ".join(PackedStringArray(names))])


## Part 3: the panel-scaling dumps (see the header). Prints one row per
## dump and a summary per scale; returns false when a negative case is not
## detected.
func _scaled_section() -> bool:
	var d := DirAccess.open(SCALED_DIR)
	if d == null:
		print("\nSCALED PARITY: no dumps in %s (run tools/unity-dump/run.py --scaled bench/parity/scaled/matrix.json)" % SCALED_DIR)
		return true
	var files: Array = []
	for f in d.get_files():
		if f.ends_with(".json"):
			files.append(f)
	files.sort()
	var rows: Array = []
	var per := {}   # "config screen ppp" -> totals
	var tot := {"cases": 0, "match": 0, "elements": 0, "struct_ok": 0, "geo": 0, "geo_ok": 0,
		"style": 0, "style_ok": 0, "props": 0, "props_ok": 0, "diag": 0, "diag_ok": 0, "scale": 0, "scale_ok": 0}
	var negatives_ok := true
	for f in files:
		var name := String(f).get_basename()
		var parts := name.split("__")
		if parts.size() != 3:
			continue
		var base := parts[0]
		var dump: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SCALED_DIR + f))
		var sc: Dictionary = dump.get("scaling", {})
		# The staged case had the dump's name: its sheet's warnings are the
		# base case's.
		for w in dump.get("importWarnings", []):
			w["file"] = String(w["file"]).replace(name, base)
		if sc.is_empty():
			continue
		var dir := CASES_DIR if FileAccess.file_exists(CASES_DIR + base + ".uxml") else SCALED_CASES
		var uss_path: String = dir + base + ".uss"
		var c := {"name": base,
			"uxml": FileAccess.get_file_as_string(dir + base + ".uxml"),
			"uss": FileAccess.get_file_as_string(uss_path) if FileAccess.file_exists(uss_path) else "",
			"files": _case_files(dir + base + ".files"),
			"sidecar": dir + base + ".json"}
		# The scale, as Unity resolved it.
		var scr: Array = sc["screen"]
		var res := UxmlPanelScale.resolve(UxmlPanelScale.settings_from_unity(sc["settings"]),
			Vector2(float(scr[0]), float(scr[1])), float(sc.get("screenDpi", 0.0)))
		var F := UxmlPanelScale.f32
		var ps: Vector2 = res["panel_size"]
		var scale_ok: bool = (F.call(float(res["pixels_per_point"])) == F.call(float(sc["pixelsPerPoint"]))
			and F.call(ps.x) == F.call(float(sc["root"]["width"])) and F.call(ps.y) == F.call(float(sc["root"]["height"])))
		_ppp = float(sc["pixelsPerPoint"])
		var r := _run_unity(c, dump)
		r["name"] = name
		_ppp = 1.0
		tot["scale"] += 1
		if scale_ok:
			tot["scale_ok"] += 1
		else:
			r["notes"].push_front("scale: ours %s pixels per point, panel %s; Unity %s, %s" % [res["pixels_per_point"], ps, sc["pixelsPerPoint"], sc["root"]])
			r["status"] = "differs"
		rows.append(r)
		tot["cases"] += 1
		for k in ["elements", "struct_ok", "geo", "geo_ok", "style", "style_ok", "props", "props_ok", "diag", "diag_ok"]:
			tot[k] += r[k]
		if r["status"] == "match":
			tot["match"] += 1
			_ppp = float(sc["pixelsPerPoint"])
			negatives_ok = _unity_negative(r) and negatives_ok
			_ppp = 1.0
		var key := "%s %dx%d @%.4f" % [parts[1], int(scr[0]), int(scr[1]), float(sc["pixelsPerPoint"])]
		var t: Dictionary = per.get(key, {"cases": 0, "match": 0, "geo": 0, "geo_ok": 0, "style": 0, "style_ok": 0})
		t["cases"] += 1
		t["match"] += 1 if r["status"] == "match" else 0
		for k in ["geo", "geo_ok", "style", "style_ok"]:
			t[k] += r[k]
		per[key] = t
	print("")
	print("scaled parity vs Unity (PanelSettings; geometry in pixels)")
	print("| case | status | structure | geometry | style | first differences |")
	print("| --- | --- | ---: | ---: | ---: | --- |")
	for r in rows:
		var notes: Array = r["notes"]
		var shown := "; ".join(notes.slice(0, 3 if not _verbose else notes.size()))
		if notes.size() > 3 and not _verbose:
			shown += " (+%d more)" % (notes.size() - 3)
		print("| %s | %s | %d/%d | %d/%d | %d/%d | %s |" % [r["name"], r["status"],
			r["struct_ok"], r["elements"], r["geo_ok"], r["geo"], r["style_ok"], r["style"], shown])
	print("")
	print("| config | screen | pixels per point | cases | geometry | style |")
	print("| --- | --- | ---: | ---: | ---: | ---: |")
	var keys := per.keys()
	keys.sort()
	for k in keys:
		var t: Dictionary = per[k]
		var kp := String(k).split(" ")
		print("| %s | %s | %s | %d/%d | %d/%d | %d/%d |" % [kp[0], kp[1], kp[2].trim_prefix("@"),
			t["match"], t["cases"], t["geo_ok"], t["geo"], t["style_ok"], t["style"]])
	print("")
	print("SCALED PARITY: %d/%d cases match; scale %d/%d; structure %d/%d, geometry %d/%d (pixels), style %d/%d, element properties %d/%d, import diagnostics %d/%d; negative cases %s" % [
		tot["match"], tot["cases"], tot["scale_ok"], tot["scale"], tot["struct_ok"], tot["elements"],
		tot["geo_ok"], tot["geo"], tot["style_ok"], tot["style"], tot["props_ok"], tot["props"],
		tot["diag_ok"], tot["diag"], "detected" if negatives_ok else "NOT DETECTED"])
	return negatives_ok


func _run_unity(c: Dictionary, dump: Dictionary) -> Dictionary:
	var name: String = c["name"]
	var uels: Array = dump["elements"]
	# Control values after the case's actions (a clicked Toggle, a closed
	# Foldout) go into the model before the part trees are built.
	var values := {}
	for u in uels:
		var n := String(u["name"])
		var props: Dictionary = u.get("props", {})
		if n.is_empty() or values.has(n) or not props.has("value"):
			continue
		var ut := String(u["type"])
		if ut in ["Toggle", "Foldout", "RadioButton"] and props["value"] is bool:
			values[n] = {"value": "true" if props["value"] else "false"}
		elif ut in ["Slider", "SliderInt"] and (props["value"] is float or props["value"] is int):
			values[n] = {"value": str(props["value"])}
		elif ut == "MinMaxSlider" and props.has("minValue"):
			values[n] = {"min-value": str(props["minValue"]), "max-value": str(props["maxValue"])}
	var actions: Array = []
	var side: String = c.get("sidecar", CASES_DIR + name + ".json")
	var sidecar := {}
	if FileAccess.file_exists(side):
		var sj = JSON.parse_string(FileAccess.get_file_as_string(side))
		if sj is Dictionary:
			sidecar = sj
			actions = sj.get("actions", [])
	# C# properties that the case sets (Unity 6000.3 has no UXML attribute
	# for them) become the attributes godot-uxml reads.
	for act in actions:
		var op := String(act.get("op", ""))
		var tn := String(act.get("target", ""))
		if tn.is_empty() or not (op == "set-prop" or op == "set-value"):
			continue
		var vs: Dictionary = values.get(tn, {})
		var v = act.get("value")
		if op == "set-prop":
			var attr: String = {"flex": "flex", "choicesMasks": "choices-masks"}.get(String(act.get("prop", "")), "")
			if attr.is_empty():
				continue
			if v is Array:
				var parts := PackedStringArray()
				for x in v:
					parts.append(str(int(x)) if x is float else str(x))
				vs[attr] = ",".join(parts)
			else:
				vs[attr] = str(v).to_lower() if v is bool else str(v)
		elif v is float or v is int:
			vs["value"] = str(int(v)) if float(v) == floorf(float(v)) else str(v)
		else:
			continue
		values[tn] = vs
	var doc := _load_case("unity-" + name, c["uxml"], c["uss"], c["files"], values, actions, sidecar)
	var ours := _paths(doc.root)
	# Classes the input controls toggle at run time (a focused slider's
	# --movable dragger, the placeholder class), copied like pseudo-states.
	for u in uels:
		var sel = ours.get(String(u["path"]))
		if sel == null:
			continue
		for cls in UxmlInputParts.STATE_CLASSES:
			var want: bool = (u["classes"] as Array).has(cls)
			if (sel as UxmlElement).class_list().has(cls) != want:
				UxmlParts.toggle_control_class(sel, cls, want)
	# The selected tab of a TabView after the case's actions.
	for u in uels:
		var tv = ours.get(String(u["path"]))
		if tv != null and String(u["type"]) == "TabView" and u.get("props", {}).has("selectedTabIndex"):
			UxmlContainerParts.select_tab_model(tv, int(u["props"]["selectedTabIndex"]))
	# Unity's pseudo-states, applied to the elements at the same paths.
	var es := {}
	for u in uels:
		var el = ours.get(String(u["path"]))
		if el == null:
			continue
		var st: Array = []
		for s in u["pseudoStates"]:
			if STATES.has(String(s)):
				st.append(String(s))
		if not st.is_empty():
			es[el] = st
	var styles: Dictionary = {}
	var measures := {}
	var bounded := {}
	for u in uels:
		var el = ours.get(String(u["path"]))
		# The layout measure (DoMeasure) when the dump has it: a password
		# mask, a placeholder or one empty line of an input field.
		var key := "layoutMeasure" if u.has("layoutMeasure") else "textMeasure"
		if el != null and u.has(key):
			measures[el] = Vector2(float(u[key]["width"]), float(u[key]["height"]))
		# Unity's measure at a width (a wrapping text): at the laid-out
		# content width and at the parent's content width.
		if el != null:
			var at: Array = []
			for mk in ["contentMeasure", "atMostMeasure"]:
				if u.has(mk):
					at.append([float(u[mk]["at"]), Vector2(float(u[mk]["width"]), float(u[mk]["height"]))])
			if not at.is_empty():
				bounded[el] = at
	# Unity measures text only on elements without children (Yoga leaves).
	var measurer := func(el: UxmlElement, style: Dictionary, hint: float) -> Vector2:
		if not el.children.is_empty():
			return Vector2.ZERO
		if measures.has(el):
			var m: Vector2 = measures[el]
			if hint >= 0.0 and hint < m.x - 0.5:
				for b in bounded.get(el, []):
					if absf(float(b[0]) - hint) < 0.6:
						return b[1]
			return m
		return _measure_fixed(el, style, hint)
	var panel := Vector2(dump["panel"]["width"], dump["panel"]["height"])
	var resolve_fn := func(): return UssStyleResolver.resolve(doc, {"element_states": es})["styles"]
	var timed = _timed_styles(doc, actions, {"element_states": es})
	if timed != null:
		resolve_fn = timed
	var layout_fn := func(st: Dictionary): return UxmlFlexLayout.compute(doc.root, st, panel, measurer, [],
		{"pixel_grid": true, "pixels_per_point": _ppp})
	var settled := _settle(doc, resolve_fn, layout_fn)
	styles = settled[0]
	var res: Dictionary = settled[1]
	# Styles Unity's controls compute from the layout (a slider's dragger
	# translate, a MinMaxSlider's dragger box): the same functions as the
	# runtime behaviors, then the cascade and the layout again.
	var rects: Dictionary = res["rects"]
	var size_of := func(x: UxmlElement) -> Vector2:
		var r = rects.get(x)
		return Vector2.ZERO if r == null else (r as Rect2).size
	var style_of := func(x: UxmlElement) -> Dictionary:
		return styles.get(x, {})
	var relaid := false
	# A click on a Slider without a page size jumps the dragger centre to
	# the pointer (BaseSlider.SetSliderValueFromClick), as the runtime's
	# slider behavior does; the value then moves it only by more than half
	# a pixel (SliderUtilities.UpdateDragElementPosition).
	if _slider_clicks(doc, actions, rects, styles):
		relaid = true
	for el in doc.root.walk():
		if el.local == "TwoPaneSplitView" and el.part_of == null:
			var m := UxmlContainerParts.two_pane_margins(el, style_of)
			if m != 0.0 and UxmlContainerParts.two_pane_style(el,
					float(UxmlInputParts.num(el, "fixed-pane-initial-dimension", 100.0)), m):
				relaid = true
	for el in doc.root.walk():
		if UxmlInputParts.layout_styles(el, size_of, style_of):
			relaid = true
	# Editor controls: the ColorField alpha bar, the InspectorElement label
	# alignment (BaseField.AlignLabel).
	var abs0 := _abs_rects(doc.root, rects, styles)
	var size_or_null := func(x: UxmlElement):
		var r = rects.get(x)
		return null if r == null else (r as Rect2).size
	if UxmlEditorParts.layout_styles(doc.root, size_or_null, func(x): return abs0.get(x), style_of):
		relaid = true
	if relaid:
		settled = _settle(doc, resolve_fn, layout_fn)
		styles = settled[0]
		res = settled[1]
	ours = _paths(doc.root)
	var abs := _abs_rects(doc.root, res["rects"], styles)
	var parents := {}
	for pe in doc.root.walk():
		for ch in pe.children:
			parents[ch] = pe
	var out := {"name": name, "status": "match", "notes": [], "elements": 0, "struct_ok": 0, "geo_half": 0,
		"geo": 0, "geo_ok": 0, "style": 0, "style_ok": 0, "diag": 0, "diag_ok": 0, "props": 0, "props_ok": 0, "pairs": []}
	var seen := {}
	# Unity does not resolve styles under display:none; those elements are
	# compared on structure only.
	var hidden_under := {}
	for u in uels:
		var par := String(u["parent"])
		if hidden_under.has(par) or (par != "" and _udisplay_none(uels, par)):
			hidden_under[String(u["path"])] = true
	for u in uels:
		var path := String(u["path"])
		out["elements"] += 1
		var el = ours.get(path)
		var label := _ulabel(u)
		if el == null:
			out["notes"].append("%s missing" % label)
			continue
		seen[el] = true
		var sd := _structure_diff(u, el)
		if sd.is_empty():
			out["struct_ok"] += 1
		else:
			out["notes"].append("%s: %s" % [label, sd])
		var r = abs.get(el)
		var want := [float(u["rect"]["x"]), float(u["rect"]["y"]),
			float(u["rect"]["width"]), float(u["rect"]["height"])]
		var got := [0.0, 0.0, 0.0, 0.0]
		# Unity keeps stale rects under a display:none ancestor; only the
		# hidden element itself (0x0) is compared.
		var hidden := String(u["style"].get("display", "flex")) == "none" or hidden_under.has(path)
		if r != null:
			got = [(r as Rect2).position.x, (r as Rect2).position.y, (r as Rect2).size.x, (r as Rect2).size.y]
		out["pairs"].append([el, want])
		if not hidden_under.has(path) and (not hidden or r != null):
			for k in 4:
				out["geo"] += 1
				# In pixels (at 1 pixel per point, the points themselves).
				var dv := absf(_r1(got[k] * _ppp) - _r1(want[k] * _ppp))
				if dv <= 0.05:
					out["geo_ok"] += 1
				else:
					if dv <= 0.55:
						out["geo_half"] += 1
					out["notes"].append("%s %s: ours %s vs Unity %s" % [label, ["x", "y", "w", "h"][k], _r1(got[k]), _r1(want[k])])
		var st: Dictionary = styles.get(el, {})
		# Unity reports layout-derived margins/padding/borders, which are 0 on
		# a display:none element; its own and its subtree's styles are not
		# compared.
		if hidden_under.has(path) or String(u["style"].get("display", "flex")) == "none":
			continue
		var par_el = parents.get(el)
		var base_w := NAN
		if par_el != null and res["rects"].has(par_el):
			var pst: Dictionary = styles.get(par_el, {})
			base_w = (res["rects"][par_el] as Rect2).size.x
			for bp in ["padding-left", "padding-right", "border-left-width", "border-right-width"]:
				var pe = pst.get(bp)
				if pe != null:
					var pl := UssValues.parse_length(String(pe["value"]))
					if pl["kind"] == "px":
						base_w -= UxmlFlexLayout.grid_box(float(pl["value"]), bp.begins_with("border"), _ppp)
		for diff in _style_diffs(u["style"], st, out, base_w):
			out["notes"].append("%s %s" % [label, diff])
		var lr = res["rects"].get(el)
		var own: Vector2 = Vector2.ZERO if lr == null else (lr as Rect2).size
		for diff in _ext_style_diffs(u["style"], st, el, styles, parents, own, out):
			out["notes"].append("%s %s" % [label, diff])
	for path in ours:
		if not seen.has(ours[path]):
			out["notes"].append("extra element %s %s" % [path, ours[path].local])
			out["elements"] += 1
	if not out["notes"].is_empty():
		out["status"] = "differs"
	# Element properties: enabledInHierarchy against the effective
	# disabled state of the cascade (enabled="false" and its subtree, as
	# Unity's SetEnabled); counted with the structure.
	var dcas := UssCascade.new(doc)
	dcas.update({"element_states": es}, true)
	var dflags: PackedByteArray = dcas.disabled_flags()
	for u in uels:
		var pel = ours.get(String(u["path"]))
		if pel == null or not u.has("enabledInHierarchy") or not dcas.index.has(pel):
			continue
		out["props"] += 1
		var ours_en: bool = dflags[int(dcas.index[pel])] == 0
		if ours_en == bool(u["enabledInHierarchy"]):
			out["props_ok"] += 1
		else:
			out["notes"].append("%s enabledInHierarchy: ours %s vs Unity %s" % [_ulabel(u), ours_en, u["enabledInHierarchy"]])
			out["status"] = "differs"
		# picking-mode of the plain authored elements (the UXML attribute;
		# a control picks with its own defaults, and its parts take the
		# runtime's mouse handling).
		var plain: bool = String(u["type"]) in ["VisualElement", "Label", "TextElement", "Image", "Box", "TemplateContainer"]
		if (pel as UxmlElement).part_of == null and u.has("pickingMode") and plain:
			out["props"] += 1
			var pm := "Ignore" if str((pel as UxmlElement).get_attribute("picking-mode")) == "Ignore" else "Position"
			if pm == String(u["pickingMode"]):
				out["props_ok"] += 1
			else:
				out["notes"].append("%s pickingMode: ours %s vs Unity %s" % [_ulabel(u), pm, u["pickingMode"]])
				out["status"] = "differs"
	# Unity's USS import diagnostics (run.py adds them to the dump): each
	# needs a godot-uxml diagnostic on the same line of the same sheet.
	var ours_diag: Array = doc.warnings + UssStyleResolver.resolve(doc, {"element_states": es})["warnings"]
	for w in dump.get("importWarnings", []):
		out["diag"] = out.get("diag", 0) + 1
		var found := false
		for d in ours_diag:
			var f := String(d.get("file", ""))
			if int(d.get("line", -1)) == int(w["line"]) and (f.get_file() == String(w["file"]).get_file()
					or (f.is_empty() or f.get_extension() == "uxml") and String(w["file"]) == name + ".uss"):
				found = true
				break
		if found:
			out["diag_ok"] = out.get("diag_ok", 0) + 1
		else:
			out["notes"].append("no diagnostic for Unity's %s line %d: %s" % [w["file"], w["line"], w["message"]])
			out["status"] = "differs"
	# ... and the value diagnostics of godot-uxml need a Unity warning on
	# their line (no extra ones).
	if dump.has("importWarnings"):
		var lines := {}
		for w in dump["importWarnings"]:
			lines["%s:%d" % [String(w["file"]).get_file(), int(w["line"])]] = true
		for d in doc.warnings:
			if not String(d.get("kind", "")) in ["invalid-value", "invalid-shorthand"]:
				continue
			var f := String(d.get("file", ""))
			var key := "%s:%d" % [name + ".uss" if (f.is_empty() or f.get_extension() == "uxml") else f.get_file(), int(d.get("line", -1))]
			out["diag"] = out.get("diag", 0) + 1
			if lines.has(key):
				out["diag_ok"] = out.get("diag_ok", 0) + 1
			else:
				out["notes"].append("diagnostic Unity does not give: %s" % d["message"])
				out["status"] = "differs"
	out["abs"] = abs
	return out


func _slider_clicks(doc: UxmlDocumentModel, actions: Array, rects: Dictionary, styles: Dictionary) -> bool:
	var abs := {}
	var changed := false
	for act in actions:
		if str(act.get("op", "")) != "click" or not act.has("x"):
			continue
		if abs.is_empty():
			abs = _abs_rects(doc.root, rects, styles)
		var pt := Vector2(float(act["x"]), float(act["y"]))
		for el in doc.root.walk():
			if not (el.local == "Slider" or el.local == "SliderInt"):
				continue
			if absf(float(UxmlInputParts.num(el, "page-size", 0.0))) > 0.000001:
				continue
			var drag := UxmlParts.find_part(el, "drag-container")
			var dragger := UxmlParts.find_part(el, "dragger")
			if drag == null or dragger == null or not abs.has(drag) or not rects.has(dragger):
				continue
			var r: Rect2 = abs[drag]
			if not r.has_point(pt):
				continue
			var dsz: Vector2 = (rects[dragger] as Rect2).size
			var vertical := str(el.get_attribute("direction")) == "Vertical"
			var at := Vector2.ZERO
			if vertical:
				at.y = clampf(pt.y - r.position.y - dsz.y / 2.0, 0.0, r.size.y - dsz.y)
			else:
				at.x = clampf(pt.x - r.position.x - dsz.x / 2.0, 0.0, r.size.x - dsz.x)
			for role in ["dragger", "dragger-border"]:
				var p := UxmlParts.find_part(el, role)
				if p != null:
					var tr := "translate: %s %s;" % [UxmlInputParts._px(at.x), UxmlInputParts._px(at.y)]
					if p.get_attribute("style") == null:
						p.attributes.append({"name": "style", "value": tr, "offset": 0})
					else:
						p.set_attribute("style", tr)
					changed = true
	return changed


## Cases that change classes and advance the clock (transitions sampled at
## a time): one cascade with the runtime's transitions (UssTransitions), the
## class changes and clock steps of the sidecar in order. Returns the
## resolve function of the settled cascade, or null for a case without them.
func _timed_styles(doc: UxmlDocumentModel, actions: Array, opts: Dictionary):
	var timed: Array = []
	for a in actions:
		if String(a.get("op", "")) in ["add-class", "remove-class", "advance"]:
			timed.append(a)
	if timed.is_empty():
		return null
	var cas := UssCascade.new(doc)
	cas.update(opts, true)
	var trs := UssTransitions.new(cas)
	for a in timed:
		var op := String(a["op"])
		if op == "advance":
			trs.advance(float(a.get("ms", 0)))
			if trs.tick():
				cas.update(opts, false, PackedInt32Array(), true)
			continue
		var t: UxmlElement = doc.root.find_by_name(String(a.get("target", "")))
		if t == null:
			continue
		var cls := String(a.get("class", ""))
		var list: Array = t.class_list().duplicate()
		if op == "add-class" and not list.has(cls):
			list.append(cls)
		elif op == "remove-class":
			list.erase(cls)
		if t.get_attribute("class") == null:
			t.attributes.append({"name": "class", "value": " ".join(list), "offset": 0})
		else:
			t.set_attribute("class", " ".join(list))
		var ch := cas.update(opts, false, PackedInt32Array([int(cas.index[t])]))
		if not ch.is_empty():
			trs.after_update(ch, cas.last_old, opts)
	return func():
		cas.update(opts, false)
		return cas.styles


func _udisplay_none(uels: Array, path: String) -> bool:
	for u in uels:
		if String(u["path"]) == path:
			return String(u["style"].get("display", "flex")) == "none"
	return false


func _ulabel(u: Dictionary) -> String:
	var n := String(u["name"])
	return "%s[%s]" % [u["type"], u["path"]] + ("#" + n if not n.is_empty() else "")


## Unity's worldBound includes the element's translate (ScrollView
## content and Scroller draggers move by translate).
func _translate(style: Dictionary, size: Vector2) -> Vector2:
	var e = style.get("translate")
	if e == null:
		return Vector2.ZERO
	var t := UssValues.parse_translate(String(e["value"]))
	if not t["ok"]:
		return Vector2.ZERO
	return t["px"] + t["ratio"] * size


func _abs_rects(root: UxmlElement, rects: Dictionary, styles: Dictionary = {}) -> Dictionary:
	# Unity's worldBound: the box of the element's rect through its world
	# transform (layout position, translate, and rotate / scale about the
	# transform-origin, composed with every ancestor's).
	var out := {}
	var stack: Array = [[root, Transform2D.IDENTITY]]
	while not stack.is_empty():
		var fr: Array = stack.pop_back()
		var el: UxmlElement = fr[0]
		var world: Transform2D = fr[1]
		var r = rects.get(el)
		if r != null:
			world = world * _local_transform(styles.get(el, {}), r as Rect2)
			if el != root:
				var sz := (r as Rect2).size
				var pts := [world * Vector2.ZERO, world * Vector2(sz.x, 0), world * Vector2(0, sz.y), world * sz]
				var box := Rect2(pts[0], Vector2.ZERO)
				for q in pts:
					box = box.expand(q)
				out[el] = box
		for ch in el.children:
			stack.append([ch, world])
	return out


func _local_transform(style: Dictionary, r: Rect2) -> Transform2D:
	var t := Transform2D(0.0, r.position + _translate(style, r.size))
	var angle := 0.0
	var e = style.get("rotate")
	if e != null:
		var pr := UssValues.parse_rotate(String(e["value"]))
		if pr["ok"]:
			angle = pr["angle"]
	var sc := Vector2.ONE
	e = style.get("scale")
	if e != null:
		var ps := UssValues.parse_scale(String(e["value"]))
		if ps["ok"]:
			sc = ps["scale"]
	if angle == 0.0 and sc == Vector2.ONE:
		return t
	var o := r.size * 0.5
	e = style.get("transform-origin")
	if e != null:
		var po := UssValues.parse_transform_origin(String(e["value"]))
		if po["ok"]:
			o = po["px"] + po["ratio"] * r.size
	return t * Transform2D(0.0, o) * Transform2D(angle, sc, 0.0, Vector2.ZERO) * Transform2D(0.0, -o)


func _structure_diff(u: Dictionary, el: UxmlElement) -> String:
	var bits: Array = []
	if String(u["type"]) != el.local:
		bits.append("type %s vs Unity %s" % [el.local, u["type"]])
	var nm = el.get_attribute("name")
	var ours_name := "" if nm == null else String(nm)
	if ours_name != String(u["name"]):
		bits.append("name '%s' vs Unity '%s'" % [ours_name, u["name"]])
	var ours_cls := {}
	for cl in el.class_list():
		ours_cls[cl] = true
	for cl in UssControls.implicit_classes_of(el.local):
		ours_cls[cl] = true
	var unity_cls := {}
	for cl in u["classes"]:
		unity_cls[String(cl)] = true
	var missing: Array = []
	var extra: Array = []
	for cl in unity_cls:
		if not ours_cls.has(cl):
			missing.append(cl)
	for cl in ours_cls:
		if not unity_cls.has(cl):
			extra.append(cl)
	if not missing.is_empty():
		bits.append("missing classes " + ",".join(missing))
	if not extra.is_empty():
		bits.append("extra classes " + ",".join(extra))
	return "; ".join(bits)


const LENGTHS := ["margin-left", "margin-top", "margin-right", "margin-bottom",
	"padding-left", "padding-top", "padding-right", "padding-bottom",
	"border-left-width", "border-top-width", "border-right-width", "border-bottom-width",
	"border-top-left-radius", "border-top-right-radius",
	"border-bottom-left-radius", "border-bottom-right-radius"]
const COLORS := ["background-color", "border-left-color", "border-top-color",
	"border-right-color", "border-bottom-color", "color", "-unity-background-image-tint-color"]


## Unity's resolved values vs ours. Unset properties of ours compare as
## their initial values (0px, transparent, opacity 1, upper-left). `color`
## and `font-size` are only compared where ours is set: Godot's own
## defaults stand in for an unset one.
func _style_diffs(us: Dictionary, st: Dictionary, out: Dictionary, base_w: float = NAN) -> Array:
	var diffs: Array = []
	for p in LENGTHS:
		if not us.has(p):
			continue
		out["style"] += 1
		var want := float(us[p])
		var got := 0.0
		var e = st.get(p)
		if e != null:
			var pl := UssValues.parse_length(String(e["value"]))
			var radius := String(p).ends_with("radius")
			if pl["kind"] == "px":
				got = pl["value"]
			elif pl["kind"] == "percent" and radius:
				# Unity resolves a radius to its number (50% is 50).
				got = pl["value"]
			elif pl["kind"] == "percent":
				# A margin or padding percentage: of the parent's content width.
				got = float(pl["value"]) * base_w / 100.0
			elif pl["kind"] == "auto" and String(p).begins_with("margin"):
				got = 0.0
			else:
				got = NAN
			# The layout's pixel-grid value of a box length (Unity rounds
			# margins, padding and borders).
			if not is_nan(got) and not radius:
				got = UxmlFlexLayout.grid_box(got, String(p).begins_with("border"), _ppp)
		if not is_nan(got) and absf(got - want) <= 0.05:
			out["style_ok"] += 1
		else:
			diffs.append("%s: ours %s vs Unity %s" % [p, e["value"] if e != null else "unset", want])
	for p in COLORS:
		if not us.has(p):
			continue
		var e = st.get(p)
		if (p == "color") and e == null:
			continue
		out["style"] += 1
		var want := _ucolor(String(us[p]))
		var got := Color(0, 0, 0, 0) if p != "-unity-background-image-tint-color" else Color.WHITE
		if e != null:
			var pc := UssValues.parse_color(String(e["value"]))
			if pc["ok"]:
				got = pc["color"]
		if _color_eq(got, want):
			out["style_ok"] += 1
		else:
			diffs.append("%s: ours %s vs Unity %s" % [p, _fmt(got), us[p]])
	if us.has("font-size") and st.has("font-size"):
		out["style"] += 1
		var pl := UssValues.parse_length(String(st["font-size"]["value"]))
		if pl["kind"] == "px" and absf(float(pl["value"]) - float(us["font-size"])) <= 0.05:
			out["style_ok"] += 1
		else:
			diffs.append("font-size: ours %s vs Unity %s" % [st["font-size"]["value"], us["font-size"]])
	if us.has("-unity-text-align"):
		out["style"] += 1
		var e = st.get("-unity-text-align")
		var got := "upper-left" if e == null else String(e["value"])
		if got == String(us["-unity-text-align"]):
			out["style_ok"] += 1
		else:
			diffs.append("-unity-text-align: ours %s vs Unity %s" % [got, us["-unity-text-align"]])
	if us.has("opacity"):
		out["style"] += 1
		var e = st.get("opacity")
		var got := 1.0 if e == null else UssValues.parse_number(String(e["value"]))
		if absf(got - float(us["opacity"])) <= 0.005:
			out["style_ok"] += 1
		else:
			diffs.append("opacity: ours %s vs Unity %s" % [got, us["opacity"]])
	return diffs


func _ucolor(s: String) -> Color:
	var inner := s.trim_prefix("rgba(").trim_suffix(")")
	var p := inner.split(",")
	if p.size() != 4:
		return Color(0, 0, 0, 0)
	return Color(float(p[0]) / 255.0, float(p[1]) / 255.0, float(p[2]) / 255.0, float(p[3]))


func _color_eq(a: Color, b: Color) -> bool:
	if a.a < 0.002 and b.a < 0.002:
		return true
	return (absf(a.r - b.r) < 0.006 and absf(a.g - b.g) < 0.006
		and absf(a.b - b.b) < 0.006 and absf(a.a - b.a) < 0.006)


func _fmt(c: Color) -> String:
	return "rgba(%d, %d, %d, %.3f)" % [roundi(c.r * 255), roundi(c.g * 255), roundi(c.b * 255), c.a]


## A matching Unity case must stop matching when one rect moves 1px.
func _unity_negative(r: Dictionary) -> bool:
	var pairs: Array = r["pairs"]
	if pairs.is_empty():
		return true
	var abs: Dictionary = r["abs"]
	for pr in pairs:
		var el: UxmlElement = pr[0]
		var want: Array = pr[1]
		if not abs.has(el):
			continue
		var moved := (abs[el] as Rect2).position.x + 1.0
		if absf(_r1(moved) - _r1(want[0])) <= 0.05:
			print("UNITY NEGATIVE CASE NOT DETECTED in %s" % r["name"])
			return false
		return true
	return true


# ---------------------------------------------------------------------------
# Every other resolved value (Unity's IResolvedStyle and the computed style)
# ---------------------------------------------------------------------------

## Keyword properties: Unity key -> [our property, initial value].
const ENUM_PROPS := {
	"align-content": ["align-content", "flex-start"], "align-items": ["align-items", "stretch"],
	"align-self": ["align-self", "auto"], "justify-content": ["justify-content", "flex-start"],
	"display": ["display", "flex"], "position": ["position", "relative"],
	"flex-direction": ["flex-direction", "column"], "flex-wrap": ["flex-wrap", "nowrap"],
	"visibility": ["visibility", "visible"], "overflow": ["overflow", "visible"],
	"white-space": ["white-space", "normal"], "text-overflow": ["text-overflow", "clip"],
	"-unity-text-overflow-position": ["-unity-text-overflow-position", "end"],
	"-unity-overflow-clip-box": ["-unity-overflow-clip-box", "padding-box"],
	"-unity-font-style-and-weight": ["-unity-font-style", "normal"],
	"-unity-text-generator": ["-unity-text-generator", "standard"],
	"-unity-editor-text-rendering-mode": ["-unity-editor-text-rendering-mode", "sdf"],
	"-unity-slice-type": ["-unity-slice-type", "sliced"],
}
## Number properties -> initial value. Unity resolves a dimension to its
## number (letter-spacing: 3px is 3).
const NUM_PROPS := {
	"flex-grow": 0.0, "flex-shrink": 1.0, "-unity-text-outline-width": 0.0,
	"-unity-slice-scale": 1.0, "letter-spacing": 0.0, "word-spacing": 0.0,
	"-unity-paragraph-spacing": 0.0,
}
const INT_PROPS := ["-unity-slice-left", "-unity-slice-right", "-unity-slice-top", "-unity-slice-bottom"]
## Lengths as authored (Unity's computed style) -> initial value.
const COMPUTED_LENGTHS := {
	"width": "auto", "height": "auto", "min-width": "auto", "min-height": "auto",
	"max-width": "none", "max-height": "none", "flex-basis": "auto",
	"left": "auto", "top": "auto", "right": "auto", "bottom": "auto",
	"margin-left": "0", "margin-top": "0", "margin-right": "0", "margin-bottom": "0",
	"padding-left": "0", "padding-top": "0", "padding-right": "0", "padding-bottom": "0",
	"border-top-left-radius": "0", "border-top-right-radius": "0",
	"border-bottom-left-radius": "0", "border-bottom-right-radius": "0",
	"letter-spacing": "0", "word-spacing": "0", "-unity-paragraph-spacing": "0",
}
## Unity's MouseCursor ids of the cursor keywords.
const CURSOR_IDS := {
	"arrow": 0, "text": 1, "resize-vertical": 2, "resize-horizontal": 3, "link": 4,
	"slide-arrow": 5, "resize-up-right": 6, "resize-up-left": 7, "move-arrow": 8,
	"rotate-arrow": 9, "scale-arrow": 10, "arrow-plus": 11, "arrow-minus": 12,
	"pan": 13, "orbit": 14, "zoom": 15, "fps": 16,
	"split-resize-up-down": 18, "split-resize-left-right": 19, "not-allowed": 20,
}


## Our value of a property: "" when unset or `initial` (the initial value).
func _ov(st: Dictionary, p: String) -> String:
	var e = st.get(p)
	if e == null:
		return ""
	var v := String(e["value"]).strip_edges()
	return "" if v.to_lower() == "initial" else v


static func _kw(s: String) -> String:
	return s.to_lower().replace("-", "").replace("_", "").replace(" ", "")


## A length in one canonical form for both sides: "auto", "none", "12px",
## "50%"; "" when it is not a length.
static func _canon_len(s: String) -> String:
	var v := s.strip_edges().to_lower()
	if v == "auto" or v == "none":
		return v
	var pct := v.ends_with("%")
	var num := v.trim_suffix("%").trim_suffix("px")
	if not num.is_valid_float():
		return ""
	var f := snappedf(float(num), 0.01)
	if f == 0.0:
		return "0px"
	return ("%s%%" if pct else "%spx") % _n2(f)


static func _n2(f: float) -> String:
	var t := "%.2f" % f
	if t.contains("."):
		t = t.rstrip("0").rstrip(".")
	return t


static func _num_of(s: String) -> float:
	var v := s.strip_edges().to_lower()
	if v.is_valid_float():
		return float(v)
	for u in ["px", "%"]:
		if v.ends_with(u) and v.trim_suffix(u).is_valid_float():
			return float(v.trim_suffix(u))
	return NAN


## "(2.00, 3.00, 1.00)" -> [2, 3, 1].
static func _vec(s: String) -> Array:
	var inner := s.strip_edges().trim_prefix("(").trim_suffix(")")
	var out: Array = []
	for p in inner.split(","):
		out.append(float(p.strip_edges()))
	return out


## "a=1 b=(1, 2) c=rgba(1, 2, 3, 1)" -> {a: "1", b: "(1, 2)", c: "rgba(...)"}.
static func _fields(s: String) -> Dictionary:
	var out := {}
	var i := 0
	while i < s.length():
		var eq := s.find("=", i)
		if eq < 0:
			break
		var key := s.substr(i, eq - i).strip_edges()
		var j := eq + 1
		var depth := 0
		while j < s.length():
			var c := s[j]
			if c == "(" or c == "{":
				depth += 1
			elif c == ")" or c == "}":
				depth -= 1
			elif c == " " and depth == 0:
				break
			j += 1
		out[key] = s.substr(eq + 1, j - eq - 1)
		i = j + 1
	return out


func _check(out: Dictionary, diffs: Array, ok: bool, what: String) -> void:
	out["style"] += 1
	if ok:
		out["style_ok"] += 1
	else:
		diffs.append(what)


## Our resolved font-size in px: a percentage of the parent's (Unity
## computes it at cascade time); null when the theme leaves it to Godot.
func _font_px(el: UxmlElement, styles: Dictionary, parents: Dictionary):
	var st: Dictionary = styles.get(el, {})
	var v := _ov(st, "font-size")
	if v.is_empty():
		return null
	var pl := UssValues.parse_length(v)
	if pl["kind"] == "px":
		return float(pl["value"])
	if pl["kind"] == "percent":
		var par = parents.get(el)
		var base = null if par == null else _font_px(par, styles, parents)
		return null if base == null else float(base) * float(pl["value"]) / 100.0
	return NAN


func _ext_style_diffs(us: Dictionary, st: Dictionary, el: UxmlElement, styles: Dictionary,
		parents: Dictionary, size: Vector2, out: Dictionary) -> Array:
	var diffs: Array = []
	var comp: Dictionary = us.get("computed", {})
	for uk in ENUM_PROPS:
		if not us.has(uk) and not comp.has(uk):
			continue
		var spec: Array = ENUM_PROPS[uk]
		var want := String(us[uk] if us.has(uk) else comp[uk])
		var got := _ov(st, spec[0])
		if got.is_empty():
			got = spec[1]
		_check(out, diffs, _kw(got) == _kw(want), "%s: ours %s vs Unity %s" % [uk, got, want])
	for uk in NUM_PROPS:
		if not us.has(uk):
			continue
		var v := _ov(st, uk)
		var got: float = NUM_PROPS[uk] if v.is_empty() else _num_of(v)
		_check(out, diffs, not is_nan(got) and absf(got - float(us[uk])) <= 0.005,
			"%s: ours %s vs Unity %s" % [uk, v if not v.is_empty() else "unset", us[uk]])
	# Slices belong to a background image: compared where godot-uxml draws
	# no image of its own (its theme images are not Unity's textures).
	var own_image := not _ov(st, "background-image").is_empty() \
		and str(st["background-image"].get("origin", "")).find("godot_uxml/themes/") >= 0
	for uk in INT_PROPS:
		if not us.has(uk) or own_image:
			continue
		var v := _ov(st, uk)
		var got := 0.0 if v.is_empty() else _num_of(v)
		_check(out, diffs, not is_nan(got) and int(got) == int(us[uk]),
			"%s: ours %s vs Unity %s" % [uk, v if not v.is_empty() else "unset", us[uk]])
	# Lengths as authored: for authored elements. A control sets many of
	# its parts' lengths from C# (a progress bar's `right`, a slider
	# tracker's `100%`); those parts are compared on their resolved values
	# and geometry.
	for uk in COMPUTED_LENGTHS:
		if not comp.has(uk) or el.part_of != null:
			continue
		var v := _ov(st, uk)
		var inl = el.get_attribute("style")
		if v.is_empty() and inl != null and String(inl).find(uk + ":") >= 0:
			# Unity's computed style keeps an inline length that `all:
			# initial` beat, while its layout uses the initial value
			# (measured: uss-all-2); the layout (geometry) is compared.
			continue
		var got := _canon_len(v if not v.is_empty() else String(COMPUTED_LENGTHS[uk]))
		var want := _canon_len(String(comp[uk]))
		var same := got == want
		if not same and got.ends_with("px") == want.ends_with("px") and got.ends_with("%") == want.ends_with("%"):
			same = absf(_num_of(got) - _num_of(want)) <= 0.011
		_check(out, diffs, same and not got.is_empty(), "computed %s: ours %s vs Unity %s" % [uk, v if not v.is_empty() else "unset", comp[uk]])
	if us.has("font-size"):
		var fp = _font_px(el, styles, parents)
		if fp != null:
			_check(out, diffs, absf(float(fp) - float(us["font-size"])) <= 0.05,
				"resolved font-size: ours %s vs Unity %s" % [fp, us["font-size"]])
	if us.has("-unity-text-outline-color"):
		var v := _ov(st, "-unity-text-outline-color")
		var got := Color(0, 0, 0, 0)
		if not v.is_empty():
			var pc := UssValues.parse_color(v)
			got = pc["color"] if pc["ok"] else Color(1, 0, 1, 0.5)
		_check(out, diffs, _color_eq(got, _ucolor(String(us["-unity-text-outline-color"]))),
			"-unity-text-outline-color: ours %s vs Unity %s" % [_fmt(got), us["-unity-text-outline-color"]])
	# filter: Unity's function list (`blur(3)`, `hue-rotate(1.570796)`,
	# `tint(RGBA(0.000, 1.000, 0.588, 1.000))`) against the parsed value.
	if us.has("filter"):
		var v := _ov(st, "filter")
		var got: Array = []
		var pf := UssValues.parse_filter(v)
		for fn in pf["funcs"] if pf["ok"] else []:
			got.append(_filter_fn(String(fn["name"]), fn["params"]))
		var want: Array = []
		for s in us["filter"]:
			want.append(_canon_unity_filter(String(s)))
		_check(out, diffs, got == want, "filter: ours %s vs Unity %s" % [got, us["filter"]])
	# -unity-material: the material asset's name (prop() values are
	# compared by pixels, bench/pixels.py).
	if us.has("-unity-material"):
		var v := _ov(st, "-unity-material")
		var got := "null"
		if not v.is_empty():
			var pm := UssValues.parse_material(v)
			var ref := String(pm["ref"]) if pm["ok"] else ""
			if not ref.is_empty():
				got = ref.trim_prefix("url(").trim_prefix("resource(").trim_suffix(")") \
					.replace("\"", "").replace("'", "").get_file().get_basename()
				# Unity's MaterialDefinition text: `Name { _P=value, ... }`.
				var ps := PackedStringArray()
				for pp in pm["props"]:
					var pv = pp["value"]
					if pv is Color:
						ps.append("%s=RGBA(%.3f, %.3f, %.3f, %.3f)" % [pp["name"], pv.r, pv.g, pv.b, pv.a])
					else:
						ps.append("%s=%s" % [pp["name"], str(pv)])
				if not ps.is_empty():
					got += " { " + ", ".join(ps) + " }"
		_check(out, diffs, got == String(us["-unity-material"]),
			"-unity-material: ours %s vs Unity %s" % [got, us["-unity-material"]])
	# Background placement.
	var bg := {}
	for axis in ["x", "y"]:
		var uk: String = "background-position-" + axis
		if not us.has(uk):
			continue
		var v := _ov(st, uk)
		var got := "center 0px"
		if not v.is_empty():
			var pp := UssValues.parse_background_position(v, axis == "y")
			got = ("%s %s" % [pp["keyword"], _canon_len(str(pp["value"]) + ("%" if pp["unit"] == "percent" else "px"))]) if pp["ok"] else "invalid " + v
		var f := _fields(String(us[uk]).trim_prefix("(").trim_suffix(")").replace(":", "="))
		var want := "%s %s" % [String(f.get("type", "")).to_lower(), _canon_len(String(f.get("x", "")))]
		bg[axis] = got
		_check(out, diffs, got == want, "%s: ours %s vs Unity %s" % [uk, got, us[uk]])
	if us.has("background-repeat"):
		var v := _ov(st, "background-repeat")
		var got := "norepeat norepeat"
		if not v.is_empty():
			var pr := UssValues.parse_background_repeat(v)
			got = (_kw(pr["x"]) + " " + _kw(pr["y"])) if pr["ok"] else "invalid " + v
		var f := _fields(String(us["background-repeat"]).trim_prefix("(").trim_suffix(")").replace(":", "=").replace(",", ""))
		var want := _kw(String(f.get("x", ""))) + " " + _kw(String(f.get("y", "")))
		bg["repeat"] = got
		_check(out, diffs, got == want, "background-repeat: ours %s vs Unity %s" % [got, us["background-repeat"]])
	if us.has("background-size"):
		var v := _ov(st, "background-size")
		var got := "length 100% 100%"
		if not v.is_empty():
			var ps := UssValues.parse_background_size(v)
			if not ps["ok"]:
				got = "invalid " + v
			elif ps["type"] != "length":
				got = String(ps["type"])
			else:
				var ax := []
				for a in [ps["x"], ps["y"]]:
					ax.append("auto" if a[0] == "auto" else _canon_len(str(a[1]) + ("%" if a[0] == "percent" else "px")))
				got = "length %s %s" % ax
		var f := _fields(String(us["background-size"]).trim_prefix("(").trim_suffix(")").replace(":", "=").replace(",", ""))
		var t := String(f.get("sizeType", "")).to_lower()
		var want := t if t != "length" else "length %s %s" % [_canon_len(String(f.get("x", ""))), _canon_len(String(f.get("y", "")))]
		bg["size"] = got
		_check(out, diffs, got == want, "background-size: ours %s vs Unity %s" % [got, us["background-size"]])
	if us.has("-unity-background-scale-mode") and bg.size() == 4:
		# Unity derives the scale mode from the four placement longhands.
		var mode := "stretchtofill"
		if bg["x"] == "center 0px" and bg["y"] == "center 0px" and bg["repeat"] == "norepeat norepeat":
			if bg["size"] == "cover":
				mode = "scaleandcrop"
			elif bg["size"] == "contain":
				mode = "scaletofit"
		_check(out, diffs, mode == _kw(String(us["-unity-background-scale-mode"])),
			"-unity-background-scale-mode: ours %s vs Unity %s" % [mode, us["-unity-background-scale-mode"]])
	# Transforms (resolved in px of the element's own size).
	if us.has("translate"):
		var v := _ov(st, "translate")
		var got := Vector2.ZERO
		if not v.is_empty():
			var pt := UssValues.parse_translate(v)
			got = pt["px"] + pt["ratio"] * size if pt["ok"] else Vector2(NAN, NAN)
		var w := _vec(String(us["translate"]))
		_check(out, diffs, absf(got.x - w[0]) <= 0.05 and absf(got.y - w[1]) <= 0.05,
			"translate: ours %s vs Unity %s" % [got, us["translate"]])
	if us.has("rotate"):
		var v := _ov(st, "rotate")
		var got := 0.0
		if not v.is_empty():
			var pr := UssValues.parse_rotate(v)
			got = pr["angle"] if pr["ok"] else NAN
		var want := UssValues.parse_angle(String(us["rotate"]).split(" ")[0])
		_check(out, diffs, not is_nan(got) and absf(got - want) <= 0.0005,
			"rotate: ours %s vs Unity %s" % [v if not v.is_empty() else "unset", us["rotate"]])
	if us.has("scale"):
		var v := _ov(st, "scale")
		var got := Vector2.ONE
		if not v.is_empty():
			var ps := UssValues.parse_scale(v)
			got = ps["scale"] if ps["ok"] else Vector2(NAN, NAN)
		var w := _vec(String(us["scale"]))
		_check(out, diffs, absf(got.x - w[0]) <= 0.005 and absf(got.y - w[1]) <= 0.005,
			"scale: ours %s vs Unity %s" % [got, us["scale"]])
	if us.has("transform-origin"):
		var v := _ov(st, "transform-origin")
		var got := size * 0.5
		if not v.is_empty():
			var po := UssValues.parse_transform_origin(v)
			got = po["px"] + po["ratio"] * size if po["ok"] else Vector2(NAN, NAN)
		var w := _vec(String(us["transform-origin"]))
		_check(out, diffs, absf(got.x - w[0]) <= 0.05 and absf(got.y - w[1]) <= 0.05,
			"transform-origin: ours %s vs Unity %s" % [got, us["transform-origin"]])
	# Text: shadow, auto size; the cursor.
	if comp.has("text-shadow"):
		var f := _fields(String(comp["text-shadow"]))
		var v := _ov(st, "text-shadow")
		var sh := {"ok": true, "offset": Vector2.ZERO, "blur": 0.0, "color": Color(0, 0, 0, 0)}
		if not v.is_empty():
			sh = UssValues.parse_text_shadow(v)
		var wo := _vec(String(f.get("offset", "(0, 0)")))
		var ok: bool = sh["ok"] and absf(sh["offset"].x - wo[0]) <= 0.05 and absf(sh["offset"].y - wo[1]) <= 0.05 \
			and absf(float(sh["blur"]) - float(f.get("blurRadius", "0"))) <= 0.05 \
			and _color_eq(sh["color"], _ucolor(String(f.get("color", ""))))
		_check(out, diffs, ok, "text-shadow: ours %s vs Unity %s" % [v if not v.is_empty() else "unset", comp["text-shadow"]])
	if comp.has("-unity-text-auto-size"):
		var f := _fields(String(comp["-unity-text-auto-size"]))
		var v := _ov(st, "-unity-text-auto-size")
		var pa := UssValues.parse_text_auto_size(v if not v.is_empty() else "none")
		var best := String(f.get("mode", "")) == "BestFit"
		var ok: bool = pa["ok"] and pa["best_fit"] == best
		if ok and best:
			ok = absf(float(pa["min"]) - _num_of(String(f.get("minSize", "")))) <= 0.05 \
				and absf(float(pa["max"]) - _num_of(String(f.get("maxSize", "")))) <= 0.05
		_check(out, diffs, ok, "-unity-text-auto-size: ours %s vs Unity %s" % [v if not v.is_empty() else "unset", comp["-unity-text-auto-size"]])
	if comp.has("cursor"):
		var f := _fields(String(comp["cursor"]))
		var v := _ov(st, "cursor")
		var id := 0
		if not v.is_empty():
			var pc := UssValues.parse_cursor(v)
			id = CURSOR_IDS.get(v.to_lower(), -1) if pc["ok"] and pc["kind"] == "keyword" else -1
		_check(out, diffs, str(id) == String(f.get("defaultCursorId", "0")),
			"cursor: ours %s vs Unity %s" % [v if not v.is_empty() else "unset", comp["cursor"]])
	# Transitions: the four lists as Unity keeps them.
	for uk in ["transition-property", "transition-duration", "transition-timing-function", "transition-delay"]:
		if not us.has(uk):
			continue
		var v := _ov(st, uk)
		var got: Array = []
		var initial: String = {"transition-property": "all", "transition-duration": "0s",
			"transition-timing-function": "ease", "transition-delay": "0s"}[uk]
		for part in (v if not v.is_empty() else initial).split(","):
			got.append(_canon_tr(uk, part))
		var want: Array = []
		for part in us[uk]:
			want.append(_canon_tr(uk, str(part)))
		_check(out, diffs, got == want, "%s: ours %s vs Unity %s" % [uk, got, want])
	return diffs


## One filter function as text, numbers to 3 decimals, a colour as
## r,g,b,a to 3 decimals: `blur(3.000)`, `tint(0.000,1.000,0.588,1.000)`.
static func _filter_fn(name: String, params: Array) -> String:
	var ps := PackedStringArray()
	for p in params:
		if p is Color:
			ps.append("%.3f,%.3f,%.3f,%.3f" % [p.r, p.g, p.b, p.a])
		else:
			ps.append("%.3f" % float(p))
	return "%s(%s)" % [name, ",".join(ps)]


## Unity's dump of a filter function in _filter_fn's form.
static func _canon_unity_filter(s: String) -> String:
	var open := s.find("(")
	var name := s.substr(0, open)
	var inner := s.substr(open + 1, s.length() - open - 2)
	if inner.begins_with("RGBA("):
		var c := inner.trim_prefix("RGBA(").trim_suffix(")").split(",")
		var ps := PackedStringArray()
		for x in c:
			ps.append("%.3f" % String(x).strip_edges().to_float())
		return "%s(%s)" % [name, ",".join(ps)]
	return "%s(%.3f)" % [name, inner.to_float()]


static func _canon_tr(prop: String, s: String) -> String:
	var v := s.strip_edges().to_lower()
	if prop == "transition-duration" or prop == "transition-delay":
		if v.ends_with("ms"):
			return _n2(float(v.trim_suffix("ms")))
		if v.ends_with("s"):
			return _n2(float(v.trim_suffix("s")) * 1000.0)
		return "?" + v
	if prop == "transition-timing-function":
		return _kw(v)
	return "none" if v == "<null>" else v
