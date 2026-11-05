extends SceneTree
## Parity against the reference engine: the uxml-preview golden cases
## (exported with their committed geometry snapshots into
## bench/parity/reference.json by bench/parity/export_reference.mjs).
##
## Each case goes through godot-uxml's own loader, cascade and flex layout
## with the reference's deterministic text measure (half an em per
## character, one line, font-size or 12px), then panel-space rects are
## compared by element name at the reference's 0.1px rounding. Control
## *parts* (unity-* children Unity builds inside controls) have no godot-uxml
## counterpart — godot-uxml maps controls to native Godot nodes — so they are
## reported separately, never as matches.
##
## Negative cases (after the Slint fork's Compose parity harness): perturbed
## results that the comparison must reject, so a broken comparator cannot
## report parity.
##
##   Godot --headless --path <project> -s res://bench/parity.gd [-- --md]

const REF := "res://bench/parity/reference.json"
const SCROLLBAR := 13.0

var _md := false


func _initialize() -> void:
	_md = OS.get_cmdline_user_args().has("--md")
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(REF))
	var panel := Vector2(data["panel"]["width"], data["panel"]["height"])
	var rows: Array = []
	var counts := {"match": 0, "parts-only": 0, "differs": 0, "no-reference": 0}
	var negatives_ok := true
	for c in data["cases"]:
		var r := _run_case(c, panel)
		counts[r["status"]] += 1
		rows.append(r)
		if r["status"] == "match" and not r["ours"].is_empty():
			negatives_ok = _negative(c, r) and negatives_ok
	_report(data, rows, counts, negatives_ok)
	quit(0 if negatives_ok else 1)


# ---------------------------------------------------------------------------

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


func _run_case(c: Dictionary, panel: Vector2) -> Dictionary:
	var name: String = c["name"]
	var root := "user://godot_uxml_parity/%s" % name
	var dir := root + "/Assets/GoldenCases/"
	DirAccess.make_dir_recursive_absolute(dir)
	for path in c["files"]:
		# Project-rooted keys (Packages/…, Assets/…) live at the project root,
		# the rest beside the case — the reference harness's resolveImport.
		var p: String = path
		var at := root + "/" + p if (p.begins_with("Packages/") or p.begins_with("Assets/")) else dir + p
		_write(at, c["files"][path])
	var uxml_path := dir + name + ".uxml"
	_write(uxml_path, c["uxml"])
	var resolver := UxmlResourceResolver.new(root)
	var doc := UxmlLoader.load_source(c["uxml"], uxml_path, resolver, c["uss"])
	var styles: Dictionary = UssStyleResolver.resolve(doc)["styles"]
	var warnings: Array = []
	# Unity's vertical scroller is 13px wide; the runtime uses Godot's own.
	var res := UxmlFlexLayout.compute(doc.root, styles, panel, _measure_fixed, warnings,
		{"scroll_bar_width": SCROLLBAR})
	var ours := _named_rects(doc.root, res["rects"])
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


## Named elements' panel-space rects, keyed like the reference harness: a
## name that appears once keeps it, repeats get #1..#n in tree order.
func _named_rects(root: UxmlElement, rects: Dictionary) -> Dictionary:
	var collected: Array = []
	var stack: Array = [[root, Vector2.ZERO]]
	while not stack.is_empty():
		var fr: Array = stack.pop_back()
		var el: UxmlElement = fr[0]
		var origin: Vector2 = fr[1]
		var r = rects.get(el)
		var abs_pos := origin
		if r != null:
			abs_pos = origin + (r as Rect2).position
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
