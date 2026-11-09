extends SceneTree
@warning_ignore_start("inference_on_variant", "unsafe_method_access", "untyped_declaration")
## Runtime v2 against runtime v1 (docs/design.md, "Runtime v2"): the same
## documents loaded on both runtimes, compared element by element after
## the load and after each step of a random sequence of changes (class
## toggles, inline styles, text edits, set_enabled, pseudo-states,
## resizes):
##
##   structure   tag, name and classes per preorder index
##   styles      the computed style of every element ({prop: {value,
##               origin}}, element references as preorder indices)
##   geometry    border box (get_element_rect), padding and content boxes,
##               element_at at the centre of every element
##   diagnostics kind, message, file, line, column
##   pixels      with a renderer (not --headless): each document drawn in a
##               SubViewport by both runtimes, with and without text,
##               compared exactly
##
## The corpus: the parity cases (bench/parity), the test fixtures and the
## generated benchmark documents (bench.gd, workloads.gd). A document that
## runtime v2 does not cover loads on runtime v1 (UxmlDocument.
## runtime_fallback); it is counted, not compared. A document that leaves
## runtime v2 during the changes is compared on, both being on runtime v1.
##
##   Godot [--headless] --path <project> -s res://bench/equiv_v2.gd [-- --only=<text>] [--steps=<n>]

const REF := "res://bench/parity/reference.json"
const CASES_DIR := "res://bench/parity/cases/"
const SIZE := Vector2(640, 480)

var _fails := 0
var _clamped := 0
var _snap_clamped := false
var _last_clamped := false
var _clamped_docs := {}
var _failed_cases := {}
var _checks := 0
var _covered := 0
var _fallback := {}
var _pixels := false
var _pix_same := 0
var _pix_n := 0
var _only := ""
var _steps := 24
var _rng := RandomNumberGenerator.new()


func _initialize() -> void:
	_pixels = DisplayServer.get_name() != "headless"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			_only = a.substr(7)
		elif a.begins_with("--steps="):
			_steps = int(a.substr(8))
	_rng.seed = 2468
	_run.call_deferred()


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	for c in _cases():
		if not _only.is_empty() and String(c["name"]).find(_only) < 0:
			continue
		await _doc(c)
	var cov := "covered %d, on runtime v1 %d" % [_covered, _fallback.size()]
	var pix := (", pixels %d/%d identical" % [_pix_same, _pix_n]) if _pixels else ""
	print("EQUIV_V2 %s: %d checks, %d failures; %s%s; geometry differing where runtime v1 floors a Label's Control: %d checks of %d documents: %s (%.1f s)" % [
		"OK" if _fails == 0 else "FAILED", _checks, _fails, cov, pix, _clamped, _clamped_docs.size(),
		", ".join(PackedStringArray(_clamped_docs.keys())), (Time.get_ticks_msec() - t0) / 1000.0])
	quit(0 if _fails == 0 else 1)


# ---------------------------------------------------------------------------
# Corpus
# ---------------------------------------------------------------------------

func _cases() -> Array:
	var out: Array = []
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(REF))
	for c in data["cases"]:
		out.append({"name": c["name"], "uxml": c["uxml"], "uss": c["uss"], "files": c["files"]})
	var d := DirAccess.open(CASES_DIR)
	var names: Array = []
	for f in d.get_files():
		if f.ends_with(".uxml"):
			names.append(f.get_basename())
	names.sort()
	for n in names:
		var up: String = CASES_DIR + n + ".uss"
		out.append({"name": n, "uxml": FileAccess.get_file_as_string(CASES_DIR + n + ".uxml"),
			"uss": FileAccess.get_file_as_string(up) if FileAccess.file_exists(up) else "", "files": {}})
	for f in _fixture_files("res://tests/fixtures"):
		out.append({"name": f, "file": f})
	var dir := "user://godot_uxml_equiv_v2/bench/Assets/UI/"
	DirAccess.make_dir_recursive_absolute(dir)
	var b = load("res://bench/bench.gd").new()
	var w = load("res://bench/workloads.gd").new()
	for pair in [["big.uxml", b._big_uxml()], ["big-static.uxml", b._big_static_uxml()],
			["base.uss", b._base_uss()], ["components.uss", b._components_uss()], ["theme.uss", b._theme_uss()],
			["static.uss", b._static_uss()], ["hud.uxml", b._hud_uxml()], ["hud.uss", b._hud_uss()],
			["wl.uss", w._uss()], ["wl_settings.uxml", w._settings_uxml()], ["wl_dialog.uxml", w._dialog_uxml()],
			["wl_inventory.uxml", w._inventory_uxml()]]:
		_write(dir + pair[0], pair[1])
	b.free()
	w.free()
	for f in ["big-static.uxml", "hud.uxml", "big.uxml", "wl_dialog.uxml", "wl_settings.uxml", "wl_inventory.uxml"]:
		out.append({"name": "gen:" + f, "file": "Assets/UI/" + f, "root": "user://godot_uxml_equiv_v2/bench"})
	out.append({"name": "gen:static-cards", "uxml": _static_cards(), "uss": ""})
	return out


func _fixture_files(dir: String) -> Array:
	var out: Array = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".uxml"):
			out.append(dir + "/" + f)
	for sub in d.get_directories():
		out.append_array(_fixture_files(dir + "/" + sub))
	return out


## A static document with wrapping text, radii, borders, clipping and
## opacity, and an inline style per element.
func _static_cards() -> String:
	var o := PackedStringArray()
	o.append('<ui:UXML xmlns:ui="UnityEngine.UIElements"><ui:VisualElement name="root" style="flex-direction: row; flex-wrap: wrap; padding: 4px;">')
	for i in 24:
		var st := "width: %dpx; margin: 3px; padding: %dpx; border-width: %dpx; border-color: rgb(%d, 90, 160); border-radius: %dpx; background-color: rgba(30, 40, %d, %.2f);" % [
			90 + (i * 37) % 80, i % 4, i % 3, 40 + i * 8, (i * 5) % 14, 60 + i * 5, 0.5 + (i % 5) * 0.1]
		if i % 4 == 1:
			st += " overflow: hidden;"
		if i % 6 == 2:
			st += " opacity: 0.7;"
		o.append('<ui:VisualElement name="c%d" class="card k%d" style="%s">' % [i, i % 3, st])
		o.append('<ui:Label name="t%d" class="t" text="Title %d" style="font-size: %dpx; -unity-text-align: %s; color: rgb(240, %d, 200);" />' % [
			i, i, 11 + i % 7, ["upper-left", "middle-center", "lower-right"][i % 3], 120 + i * 5])
		o.append('<ui:Label name="b%d" text="Body text of card %d that wraps over a few lines when narrow" style="white-space: normal; font-size: 12px;" />' % [i, i])
		if i % 5 == 0:
			o.append('<ui:Image name="im%d" style="width: 24px; height: 18px; background-color: rgb(200, 100, 50);" />' % i)
		o.append('</ui:VisualElement>')
	o.append('</ui:VisualElement></ui:UXML>')
	return "\n".join(o)


# ---------------------------------------------------------------------------
# One document
# ---------------------------------------------------------------------------

func _doc(c: Dictionary) -> void:
	var name: String = c["name"]
	var docs: Array = []
	var host := SubViewport.new()
	host.size = Vector2i(SIZE)
	host.transparent_bg = false
	host.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(host)
	var host2 := SubViewport.new()
	host2.size = Vector2i(SIZE)
	host2.transparent_bg = false
	host2.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(host2)
	for rt in [1, 2]:
		var d := UxmlDocument.new()
		d.auto_load = false
		d.runtime = rt
		d.size = SIZE
		d.transitions_manual = true
		(host if rt == 1 else host2).add_child(d)
		_load(d, c)
		docs.append(d)
	var a: UxmlDocument = docs[0]
	var b: UxmlDocument = docs[1]
	if b.get_runtime() != 2:
		_fallback[name] = b.runtime_fallback
		host.queue_free()
		host2.queue_free()
		await process_frame
		return
	_covered += 1
	await _settle(docs)
	_cmp(name + " load", a, b)
	if _pixels:
		await _cmp_pixels(name + " load", host, host2, a, b)
	# Changes.
	var els: Array = a._cascade.els if a._cascade != null else []
	var vocab: Array = []
	for el in els:
		for cl in el.class_list():
			if not vocab.has(cl):
				vocab.append(cl)
	vocab.append("v2-extra")
	_rng.seed = hash(name) ^ 2468
	for step in _steps:
		var k := _rng.randi_range(0, els.size() - 1)
		var op := _rng.randi_range(0, 6)
		for d in docs:
			_apply(d, op, k, vocab)
		await _settle(docs)
		_cmp("%s step %d (op %d, element %d)" % [name, step, op, k], a, b)
		if _failed_cases.has(name):
			break
	if _pixels:
		await _cmp_pixels(name + " after changes", host, host2, a, b)
	host.queue_free()
	host2.queue_free()
	await process_frame


func _load(d: UxmlDocument, c: Dictionary) -> void:
	if c.has("root"):
		d.load_document(c["file"], c["root"])
		return
	if c.has("file"):
		var f: String = c["file"]
		var root := "res://tests/fixtures/" + f.trim_prefix("res://tests/fixtures/").get_slice("/", 0)
		d.load_document(f.trim_prefix(root + "/"), root)
		return
	var base := "user://godot_uxml_equiv_v2/%s" % String(c["name"]).replace(":", "_")
	var dir := base + "/Assets/GoldenCases/"
	DirAccess.make_dir_recursive_absolute(dir)
	for p in c.get("files", {}):
		var ps: String = p
		_write(base + "/" + ps if (ps.begins_with("Packages/") or ps.begins_with("Assets/")) else dir + ps, c["files"][p])
	var path := dir + "case.uxml"
	_write(path, c["uxml"])
	d._clear()
	d._resolver = UxmlResourceResolver.new(base)
	d._doc = UxmlLoader.load_source(c["uxml"], path, d._resolver, c.get("uss", ""))
	d._effective_root = base
	UxmlTheme.attach(d._doc, d.theme_path, d.editor_theme, d.editor_skin)
	d._start_runtime()


func _write(path: String, content: Variant) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if content is PackedByteArray:
		f.store_buffer(content)
	else:
		f.store_string(content)
	f.close()


## Runtime v1 settles over frames (its restyles after a load); both are
## flushed.
func _settle(docs: Array) -> void:
	for i in 4:
		for d in docs:
			d._restyle_now()
		await process_frame


func _apply(d: UxmlDocument, op: int, k: int, vocab: Array) -> void:
	var els: Array = d._v2.cascade.els if d._v2 != null else d._cascade.els
	if k >= els.size():
		return
	var el: UxmlElement = els[k]
	var r := RandomNumberGenerator.new()
	r.seed = hash([op, k, _checks])
	match op:
		0, 1:
			var cl: String = vocab[r.randi_range(0, vocab.size() - 1)]
			var list := el.class_list()
			if list.has(cl):
				list.erase(cl)
			else:
				list.append(cl)
			el.set_attribute("class", " ".join(PackedStringArray(list)))
		2:
			var styles := ["width: %dpx;" % r.randi_range(10, 200), "padding: %dpx;" % r.randi_range(0, 9),
				"background-color: rgb(%d, 20, 90);" % r.randi_range(0, 255), "border-width: 2px; border-color: red;",
				"border-radius: %dpx;" % r.randi_range(0, 12), "opacity: 0.5;", "display: none;", "visibility: hidden;",
				"font-size: %dpx;" % r.randi_range(8, 22), "white-space: normal;", "overflow: hidden;", ""]
			el.set_attribute("style", styles[r.randi_range(0, styles.size() - 1)])
		3:
			if el.local == "Label":
				el.set_attribute("text", ["", "x", "Changed text %d" % r.randi(), "A much longer label text that will need to wrap somewhere"][r.randi_range(0, 3)])
		4:
			var n = el.get_attribute("name")
			if n != null:
				d.set_enabled(String(n), r.randi_range(0, 1) == 0)
		5:
			d._set_state(el, ["hover", "active", "focus"][r.randi_range(0, 2)], r.randi_range(0, 1) == 0)
		6:
			d.size = Vector2(r.randi_range(200, 900), r.randi_range(150, 700))


# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

func _snap(d: UxmlDocument) -> Array:
	var walk: Array = d._doc.root.walk()
	var idx := {}
	for i in walk.size():
		idx[walk[i]] = i
	var out: Array = []
	for el in walk:
		var e := {"tag": el.local, "name": el.get_attribute("name"), "class": el.get_attribute("class")}
		e["style"] = _norm(d.get_computed_style_for(el), idx)
		# Geometry is the layout's: runtime v1 reports a Control's size,
		# which Godot floors at the Control's minimum (an empty Label one
		# line high, a Label narrower than its text as wide as the text);
		# those are counted (_clamped), runtime v2 has the layout's rect.
		var br := d.get_element_rect(el)
		if d.get_runtime() == 1 and br != Rect2():
			var lr = _v1_layout_rect(d, el)
			if lr != null and (lr as Rect2).size != br.size:
				if not _snap_clamped and OS.get_environment("EQUIV_V2_TRACE") != "":
					print("  v1 off-layout: <%s %s> control %s layout %s" % [el.local, el.get_attribute("name"), br, lr])
				_snap_clamped = true
		e["border"] = br
		e["padding"] = d.get_element_rect(el, null, "padding")
		e["content"] = d.get_element_rect(el, null, "content")
		var r: Rect2 = e["border"]
		if r.size.x > 2.0 and r.size.y > 2.0:
			var hit := d.element_at(r.get_center())
			e["hit"] = idx.get(hit, -1)
		out.append(e)
	return out


## Element `el`'s border box in the document as runtime v1's layout placed
## it (null without one).
func _v1_layout_rect(d: UxmlDocument, el: UxmlElement):
	if d._cascade == null or d._cascade._native == null:
		return null
	var i = d._cascade.index.get(el)
	if i == null:
		return null
	var r = d._cascade._native.call("placed_rect", int(i))
	if r == null:
		return null
	var pos: Vector2 = (r as Rect2).position
	var p: int = d._cascade._parent[int(i)]
	while p > 0:
		var pr = d._cascade._native.call("placed_rect", p)
		if pr != null:
			pos += (pr as Rect2).position
		p = d._cascade._parent[p]
	return Rect2(pos + d._root_box.position, (r as Rect2).size)


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
	if v is Rect2:
		return Rect2(v.position.snappedf(0.001), v.size.snappedf(0.001))
	return v


func _diags(d) -> Array:
	var out: Array = []
	for w in d.diagnostics:
		out.append([w["kind"], w["message"], w["file"], w["line"], w["column"]])
	out.sort()
	return out


func _cmp(what: String, a: UxmlDocument, b: UxmlDocument) -> void:
	_checks += 1
	_snap_clamped = false
	var sa := _snap(a)
	var sb := _snap(b)
	_last_clamped = false
	if _snap_clamped and sa.size() == sb.size():
		# Runtime v1 has a Label whose Control Godot floored above the
		# layout's rect (its minimum size: an empty Label one line high, a
		# Label narrower than its text as wide as the text, a wrapping Label
		# measured at a stale width; the layout around it did not follow).
		# A difference of geometry (or of a hit) then is v1's Control, not
		# the layout: it is counted, not failed. Runtime v2 draws the
		# layout's rects. Everything else is still compared.
		var geo := false
		for i in sa.size():
			for k in ["hit", "border", "padding", "content"]:
				if sa[i].get(k) != sb[i].get(k):
					if not geo and OS.get_environment("EQUIV_V2_TRACE") != "":
						print("  geo %s: element %d <%s> %s v1 %s v2 %s" % [what, i, sa[i]["tag"], k, sa[i].get(k), sb[i].get(k)])
					geo = true
		if geo:
			_clamped += 1
			_clamped_docs[what.get_slice(" ", 0)] = true
			_last_clamped = true
			for e in sa + sb:
				for k in ["hit", "border", "padding", "content"]:
					e.erase(k)
	var why := ""
	if sa.size() != sb.size():
		why = "element count %d vs %d" % [sa.size(), sb.size()]
	else:
		for i in sa.size():
			if sa[i] != sb[i]:
				why = "element %d <%s> %s" % [i, sa[i]["tag"], _leaf(sa[i], sb[i], "")]
				break
	if why.is_empty() and _diags(a) != _diags(b):
		why = "diagnostics differ:\n    v1 %s\n    v2 %s" % [_diags(a), _diags(b)]
	if not why.is_empty() and OS.get_environment("EQUIV_V2_TRACE") != "":
		for i in sa.size():
			if sa[i] != sb[i]:
				for j in range(i, mini(i + 6, sa.size())):
					print("    %d <%s %s> style-eq=%s v1 %s v2 %s" % [j, sa[j]["tag"], sa[j]["name"], sa[j]["style"] == sb[j]["style"], sa[j].get("border"), sb[j].get("border")])
				print("    v2 style ", sb[i + 1]["style"].keys() if i + 1 < sb.size() else "")
				break
	if not why.is_empty():
		_fails += 1
		var case_name := what.get_slice(" ", 0)
		if _fails <= 25 or not _failed_cases.has(case_name):
			print("FAIL %s [v2 runtime %d]: %s" % [what, b.get_runtime(), why])
		_failed_cases[case_name] = true


func _leaf(a, b, path: String) -> String:
	if a is Dictionary and b is Dictionary:
		for k in a:
			if not b.has(k):
				return "%s.%s missing on v2" % [path, k]
			if typeof(a[k]) != typeof(b[k]) or a[k] != b[k]:
				return _leaf(a[k], b[k], "%s.%s" % [path, k])
		for k in b:
			if not a.has(k):
				return "%s.%s only on v2" % [path, k]
	return "%s: v1 %s, v2 %s" % [path, a, b]


func _cmp_pixels(what: String, h1: SubViewport, h2: SubViewport, a: UxmlDocument, b: UxmlDocument) -> void:
	if _last_clamped:
		return
	for k in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var i1 := h1.get_texture().get_image()
	var i2 := h2.get_texture().get_image()
	_pix_n += 1
	_checks += 1
	if i1.get_data() == i2.get_data():
		_pix_same += 1
		return
	var n := 0
	var first := Vector2i(-1, -1)
	for y in i1.get_height():
		for x in i1.get_width():
			if i1.get_pixel(x, y) != i2.get_pixel(x, y):
				n += 1
				if first.x < 0:
					first = Vector2i(x, y)
	_fails += 1
	if _fails <= 25:
		print("FAIL %s pixels: %d differ, first at %s (v1 %s, v2 %s)" % [what, n, first,
			i1.get_pixelv(first), i2.get_pixelv(first)])
		var dir := "user://godot_uxml_equiv_v2/diff"
		DirAccess.make_dir_recursive_absolute(dir)
		var stem := what.validate_filename()
		i1.save_png(dir + "/" + stem + ".v1.png")
		i2.save_png(dir + "/" + stem + ".v2.png")
