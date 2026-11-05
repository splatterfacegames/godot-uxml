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
##   Godot --headless --path <project> -s res://bench/parity.gd [-- --verbose]

const REF := "res://bench/parity/reference.json"
const UNITY_DIR := "res://bench/parity/unity/"
const CASES_DIR := "res://bench/parity/cases/"
const STATES := ["hover", "active", "focus", "checked", "selected"]

var _verbose := false


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
			"files": {}})
	var unity_ok := _unity_section(unity_cases)
	quit(0 if negatives_ok and unity_ok else 1)


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
		actions: Array = []) -> UxmlDocumentModel:
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
	UxmlTheme.attach(doc, UxmlTheme.DEFAULT)
	UxmlParts.expand(doc)
	_model_actions(doc, actions)
	return doc


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
		var changed := UxmlContainerParts.after_layout(doc.root, size_of)
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


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
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
		"geo": 0, "geo_ok": 0, "geo_half": 0, "style": 0, "style_ok": 0, "pixel_only": 0}
	var negatives_ok := true
	for c in cases:
		var dpath: String = UNITY_DIR + String(c["name"]) + ".json"
		if not FileAccess.file_exists(dpath):
			continue
		var dump: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dpath))
		var r := _run_unity(c, dump)
		rows.append(r)
		tot["cases"] += 1
		for k in ["elements", "struct_ok", "geo", "geo_ok", "geo_half", "style", "style_ok"]:
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
	print("UNITY PARITY: %d/%d cases match (%d more differ only by pixel-grid rounding); structure %d/%d elements, geometry %d/%d values (%d more within 0.5px), style %d/%d values; negative cases %s" % [
		tot["match"], tot["cases"], tot["pixel_only"], tot["struct_ok"], tot["elements"], tot["geo_ok"], tot["geo"],
		tot["geo_half"], tot["style_ok"], tot["style"], "detected" if negatives_ok else "NOT DETECTED"])
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
	var side := CASES_DIR + name + ".json"
	if FileAccess.file_exists(side):
		var sj = JSON.parse_string(FileAccess.get_file_as_string(side))
		if sj is Dictionary:
			actions = sj.get("actions", [])
	var doc := _load_case("unity-" + name, c["uxml"], c["uss"], c["files"], values, actions)
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
	for u in uels:
		var el = ours.get(String(u["path"]))
		# The layout measure (DoMeasure) when the dump has it: a password
		# mask, a placeholder or one empty line of an input field.
		var key := "layoutMeasure" if u.has("layoutMeasure") else "textMeasure"
		if el != null and u.has(key):
			measures[el] = Vector2(float(u[key]["width"]), float(u[key]["height"]))
	# Unity measures text only on elements without children (Yoga leaves).
	var measurer := func(el: UxmlElement, style: Dictionary, hint: float) -> Vector2:
		if not el.children.is_empty():
			return Vector2.ZERO
		if measures.has(el):
			return measures[el]
		return _measure_fixed(el, style, hint)
	var panel := Vector2(dump["panel"]["width"], dump["panel"]["height"])
	var resolve_fn := func(): return UssStyleResolver.resolve(doc, {"element_states": es})["styles"]
	var layout_fn := func(st: Dictionary): return UxmlFlexLayout.compute(doc.root, st, panel, measurer, [],
		{"pixel_grid": true})
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
	for el in doc.root.walk():
		if UxmlInputParts.layout_styles(el, size_of, style_of):
			relaid = true
	if relaid:
		settled = _settle(doc, resolve_fn, layout_fn)
		styles = settled[0]
		res = settled[1]
	ours = _paths(doc.root)
	var abs := _abs_rects(doc.root, res["rects"], styles)
	var out := {"name": name, "status": "match", "notes": [], "elements": 0, "struct_ok": 0, "geo_half": 0,
		"geo": 0, "geo_ok": 0, "style": 0, "style_ok": 0, "pairs": []}
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
				var dv := absf(_r1(got[k]) - _r1(want[k]))
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
		for diff in _style_diffs(u["style"], st, out):
			out["notes"].append("%s %s" % [label, diff])
	for path in ours:
		if not seen.has(ours[path]):
			out["notes"].append("extra element %s %s" % [path, ours[path].local])
			out["elements"] += 1
	if not out["notes"].is_empty():
		out["status"] = "differs"
	out["abs"] = abs
	return out


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
	var out := {}
	var stack: Array = [[root, Vector2.ZERO]]
	while not stack.is_empty():
		var fr: Array = stack.pop_back()
		var el: UxmlElement = fr[0]
		var origin: Vector2 = fr[1]
		var r = rects.get(el)
		var p := origin
		if r != null:
			p = origin + (r as Rect2).position + _translate(styles.get(el, {}), (r as Rect2).size)
			if el != root:
				out[el] = Rect2(p, (r as Rect2).size)
		for ch in el.children:
			stack.append([ch, p])
	return out


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
func _style_diffs(us: Dictionary, st: Dictionary, out: Dictionary) -> Array:
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
			if pl["kind"] == "px":
				got = pl["value"]
			else:
				got = NAN
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
