extends RefCounted
## Hidden subtrees out of the scene tree (UxmlDocument._park_hidden): the
## authored subtrees that are display:none at load are built but kept out
## of the tree until they are shown or the API hands out one of their
## controls. Everything observable must match a load that keeps every
## control in the tree (UxmlDocument.park_hidden = false): the drawn
## controls (geometry, visibility, paint, text, transforms, clipping,
## order), the diagnostics, the computed styles, and every control the
## API returns.

const FIXTURE := "res://tests/fixtures/parking"
const PATH := "Assets/UI/parking.uxml"

var h = null


func _init(harness) -> void:
	h = harness


func _load(park: bool, theme := true) -> UxmlDocument:
	var was: bool = UxmlDocument.park_hidden
	UxmlDocument.park_hidden = park
	var doc := UxmlDocument.new()
	if not theme:
		doc.theme_path = ""
	h.root.add_child(doc)
	doc.size = Vector2(640, 480)
	doc.load_document(PATH, FIXTURE)
	UxmlDocument.park_hidden = was
	return doc


func _unload(doc: UxmlDocument) -> void:
	h.root.remove_child(doc)
	doc.free()


static func _box(sb: StyleBox) -> String:
	if sb == null:
		return "-"
	if sb is StyleBoxFlat:
		var f := sb as StyleBoxFlat
		return "flat(%s %d,%d,%d,%d %s r%d,%d,%d,%d m%s,%s,%s,%s %s)" % [
			f.bg_color, f.border_width_left, f.border_width_top, f.border_width_right,
			f.border_width_bottom, f.border_color, f.corner_radius_top_left,
			f.corner_radius_top_right, f.corner_radius_bottom_right,
			f.corner_radius_bottom_left, f.content_margin_left, f.content_margin_top,
			f.content_margin_right, f.content_margin_bottom, f.draw_center]
	return sb.get_class()


## One line per node: what the node draws and where (only nodes drawn,
## `visible_only`, or every node in the tree), in tree order, indented by
## depth. Two documents with the same lines draw the same thing.
static func snapshot(n: Node, visible_only: bool, depth := 0, out: Array = []) -> Array:
	var ci := n as CanvasItem
	if ci != null and visible_only and not ci.visible:
		return out
	var line := "%s%s" % ["  ".repeat(depth), n.get_class()]
	var sc = n.get_script()
	if sc != null:
		line += "<%s>" % sc.resource_path.get_file()
	var c := n as Control
	if c != null:
		line += " pos=%s size=%s vis=%s mod=%s smod=%s clip=%s mouse=%d focus=%d z=%d" % [
			c.position, c.size, c.visible, c.modulate, c.self_modulate,
			c.clip_contents, c.mouse_filter, c.focus_mode, c.z_index]
		line += " xf=%s/%s/%s/%s" % [c.offset_transform_enabled, c.offset_transform_position,
			c.offset_transform_rotation, c.offset_transform_scale]
		if not c.tooltip_text.is_empty():
			line += " tip=%s" % c.tooltip_text
		if c is Label or c is Button or c is LineEdit:
			line += " text=%s" % c.get("text")
			line += " fc=%s fs=%d font=%s" % [c.get_theme_color("font_color"),
				c.get_theme_font_size("font_size"), c.get_theme_font("font")]
			line += " sb=%s" % _box(c.get_theme_stylebox("normal"))
			line += " min=%s" % c.get_combined_minimum_size()
		if c is UxmlBox:
			line += " box=%s tex=%s" % [_box(c.box_style), c.box_texture]
		if c is TextureRect:
			line += " tr=%s,%s,%s,%s" % [c.offset_left, c.offset_top, c.offset_right, c.offset_bottom]
	out.append(line)
	for ch in n.get_children(true):
		snapshot(ch, visible_only, depth + 1, out)
	return out


func _same(a: Array, b: Array, msg: String) -> void:
	if a == b:
		h.check(true, msg)
		return
	var k := 0
	while k < mini(a.size(), b.size()) and a[k] == b[k]:
		k += 1
	h.check(false, "%s -- %d vs %d lines, first difference at %d:\n  parked: %s\n  in tree: %s" % [
		msg, a.size(), b.size(), k, a[k] if k < a.size() else "<end>",
		b[k] if k < b.size() else "<end>"])


## A computed style as text, without the element objects its inherited
## origins point at (each document has its own).
static func _style(doc: UxmlDocument, n: String) -> String:
	var re := RegEx.create_from_string("<RefCounted#-?[0-9]+>")
	return re.sub(str(doc.get_computed_style(n)), "<el>", true)


func _diag(doc: UxmlDocument) -> Array:
	var out: Array = []
	for d in doc.diagnostics:
		out.append("%s|%s" % [d.get("kind", ""), d.get("message", "")])
	return out


func test_hidden_subtrees_are_parked() -> void:
	var doc := _load(true)
	var names: Array = []
	for el in doc._parked:
		names.append(String(el.get_attribute("name")))
	names.sort()
	h.check(names == ["hidden-first", "hidden-last", "inline-hidden", "page-1", "page-2", "tab-b", "tab-c", "unity-content"],
		"the authored display:none subtrees (not those inside them) and a collapsed Foldout's content are parked: %s" % [names])
	var page: Control = doc._controls[doc._by_name["page-1"]]
	h.check(not page.is_inside_tree() and page.get_parent() == null,
		"a parked subtree is out of the tree")
	h.check(doc._controls[doc._by_name["quality"]] != null,
		"the controls of a parked subtree are built")
	h.check(doc._behaviors.has(doc._by_name["quality"]),
		"the behaviors of a parked subtree are attached")
	var off := _load(false)
	h.check(off._parked.is_empty(), "park_hidden = false parks nothing")
	_unload(off)
	_unload(doc)


func test_parked_load_draws_the_same() -> void:
	for theme in [true, false]:
		var a := _load(true, theme)
		var b := _load(false, theme)
		await h.process_frame
		_same(snapshot(a, true), snapshot(b, true),
			"after the load (theme %s) the drawn controls are the same" % theme)
		_same(_diag(a), _diag(b), "the same diagnostics (theme %s)" % theme)
		for n in ["page-1", "quality", "player", "fold", "long", "inline-label"]:
			h.check(_style(a, n) == _style(b, n),
				"the computed style of %s is the same while parked" % n)
		# Show the pages in turn, as a tab bar would.
		for p in [1, 2, 0, 2, 1]:
			for d in [a, b]:
				for t in 3:
					d.set_class("page-%d" % t, "page" + ("" if t == p else " hidden"))
				d._restyle_now()
			await h.process_frame
			_same(snapshot(a, true), snapshot(b, true),
				"page %d shown (theme %s): the drawn controls are the same" % [p, theme])
			_same(_diag(a), _diag(b), "page %d shown: the same diagnostics" % p)
		var shown: Control = a._controls[a._by_name["page-1"]]
		h.check(shown.is_inside_tree(), "a shown subtree entered the tree")
		_unload(a)
		_unload(b)


func test_inline_and_nested_hidden_shown() -> void:
	var a := _load(true)
	var b := _load(false)
	for d in [a, b]:
		d.set_class("page-1", "page")
		d._restyle_now()
		d.get_element_model("nested-hidden").set_attribute("class", "")
		d.get_element_model("inline-hidden").set_attribute("style", "")
		d.get_element_model("hidden-first").set_attribute("class", "")
		d.get_element_model("hidden-last").set_attribute("class", "")
		d._restyle_now()
	await h.process_frame
	_same(snapshot(a, true), snapshot(b, true),
		"hidden first/last/inline/nested elements shown in place: the same drawing")
	a.get_focus_ring()  # every parked subtree into the tree
	_same(snapshot(a, false), snapshot(b, false), "and the same node tree")
	_unload(a)
	_unload(b)


func test_foldout_opens() -> void:
	var a := _load(true)
	var b := _load(false)
	var content := UxmlParts.find_part(a.get_element_model("opts"), "content")
	h.check(a._parked.has(content), "a collapsed Foldout's content is parked")
	for d in [a, b]:
		var t: UxmlToggle = d._controls[UxmlParts.find_part(d._by_name["opts"], "toggle")]
		t._activate()  # a click on the Foldout's toggle
		d._restyle_now()
	await h.process_frame
	h.check(not a._parked.has(content), "opening the Foldout puts its content in the tree")
	_same(snapshot(a, true), snapshot(b, true), "the opened Foldout draws the same")
	for d in [a, b]:
		var t: UxmlToggle = d._controls[UxmlParts.find_part(d._by_name["opts"], "toggle")]
		t._activate()
		d._restyle_now()
	await h.process_frame
	_same(snapshot(a, true), snapshot(b, true), "closed again: the same")
	_unload(a)
	_unload(b)


func test_tabs() -> void:
	var a := _load(true)
	var b := _load(false)
	h.check(a._parked.has(a._by_name["tab-c"]), "an unselected Tab is parked")
	for step in [[1, -1], [2, -1], [-1, 0], [0, -1]]:
		for d in [a, b]:
			if step[0] >= 0:
				d._behaviors[d._by_name["tv"]].select(step[0], true)
			else:
				d.move_tab("tv", 2, step[1])
			d._restyle_now()
		await h.process_frame
		_same(snapshot(a, true), snapshot(b, true), "TabView step %s: the same drawing" % [step])
	a.get_focus_ring()
	_same(snapshot(a, false), snapshot(b, false), "TabView: the same node tree")
	_unload(a)
	_unload(b)


func test_api_controls_are_in_the_tree() -> void:
	var a := _load(true)
	var b := _load(false)
	var c := a.get_element("deep-button")
	h.check(c != null and c.is_inside_tree(), "get_element on a parked control puts it in the tree")
	h.check(c == a._controls[a._by_name["deep-button"]], "the same control the document styles")
	h.check(not a._parked.has(a._by_name["page-2"]), "its subtree is no longer parked")
	h.check(a._parked.has(a._by_name["page-1"]), "other subtrees stay parked")
	var n := a.get_native("quality")
	h.check(n != null and n.is_inside_tree(), "get_native on a parked control puts it in the tree")
	h.check(n.get_script() == b.get_native("quality").get_script(),
		"get_native returns the same kind of control")
	var screen := a.get_element("screen")
	h.check(a._parked.size() == 2, "get_element on an ancestor puts the subtrees below it in the tree: %d left" % a._parked.size())
	h.check(screen.get_child_count() == b.get_element("screen").get_child_count(),
		"an ancestor returned by the API has all its children")
	a.get_focus_ring()
	h.check(a._parked.is_empty(), "get_focus_ring puts every parked subtree in the tree")
	_same(snapshot(a, false), snapshot(b, false),
		"once every subtree is in the tree, the node tree is the one built without parking")
	_unload(a)
	_unload(b)


func test_parked_values_and_signals() -> void:
	var a := _load(true)
	var got: Array = []
	a.value_changed.connect(func(n, v): got.append([n, v]))
	var dd := a.get_native("quality")
	h.check(dd.is_inside_tree(), "dropdown in the tree when handed out")
	var s := a.get_native("vol")
	h.check(s != null and is_equal_approx(float(s.get("value")), 40.0), "a visible slider keeps its value")
	var t := a.get_native("player") as LineEdit
	h.check(t != null and t.text == "Ada", "a parked text field's editor has its value")
	_unload(a)


func test_reload_and_free_leave_no_orphans() -> void:
	await h.process_frame
	var before := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	var a := _load(true)
	a.reload()
	await h.process_frame
	_unload(a)
	await h.process_frame
	await h.process_frame
	var after := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	h.check(after <= before, "reload and free release the parked subtrees (orphans %d -> %d)" % [before, after])


func test_theme_above_disables_parking() -> void:
	var holder := Control.new()
	holder.theme = Theme.new()
	h.root.add_child(holder)
	var doc := UxmlDocument.new()
	holder.add_child(doc)
	doc.size = Vector2(640, 480)
	doc.load_document(PATH, FIXTURE)
	h.check(doc._parked.is_empty(),
		"under a Godot theme nothing is parked (parked controls would read the default theme)")
	h.root.remove_child(holder)
	holder.free()
