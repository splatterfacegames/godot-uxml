extends SceneTree
## Renders the parity cases with godot-uxml's runtime (UxmlDocument) to PNG,
## for the pixel comparison with Unity (bench/pixels.py). Needs a renderer:
## run it windowed, not --headless (bench/pixels.py starts it):
##
##   Godot --path <project> --resolution 64x64 -s res://bench/pixels_render.gd
##       -- --out <dir> [--only a,b]
##
## Each case draws in a SubViewport of the case's panel size (pixels 1:1
## with USS px) over the clear colour that the Unity side uses (white for
## the runtime theme, the editor window colour for an editor skin), and is
## captured twice: <case>.png as drawn and <case>.notext.png with every
## text colour transparent (glyphs, outline, shadow, caret, selection), so
## the comparison can tell text pixels from box pixels.
##
## The state of a case after its sidecar actions comes from the Unity dump
## (bench/parity/unity/<case>.json), as in bench/parity.gd: control values,
## pseudo-states, the run-time state classes and the selected tab go into
## the runtime at the same element paths. The data actions (items, tree
## items, selection, scroll offset, breadcrumbs, class changes and clock
## steps) run through the runtime API; pointer and keyboard actions do not
## replay (their result is in the copied state).

const REF := "res://bench/parity/reference.json"
const UNITY_DIR := "res://bench/parity/unity/"
const CASES_DIR := "res://bench/parity/cases/"
const STATES := ["hover", "active", "focus", "checked"]
const CLEAR := {"": Color8(255, 255, 255), "dark": Color8(56, 56, 56), "light": Color8(200, 200, 200)}

var _out := ""
var _only := {}
var _vp: SubViewport


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--out" and i + 1 < args.size():
			_out = args[i + 1]
		elif args[i] == "--runtime" and i + 1 < args.size():
			# Runtime v2 for the cases it covers (UxmlDocument.runtime).
			UxmlDocument.default_runtime = int(args[i + 1])
		elif args[i] == "--only" and i + 1 < args.size():
			for n in args[i + 1].split(",", false):
				_only[n] = true
	if _out.is_empty():
		_out = ProjectSettings.globalize_path("user://godot_uxml_pixels/out")
	DirAccess.make_dir_recursive_absolute(_out)
	_unity_project_data()
	_run.call_deferred()


func _run() -> void:
	var cases: Array = []
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(REF))
	for c in data["cases"]:
		cases.append({"name": c["name"], "uxml": c["uxml"], "uss": c["uss"], "files": c["files"]})
	var d := DirAccess.open(CASES_DIR)
	var names: Array = []
	for f in d.get_files():
		if f.ends_with(".uxml"):
			names.append(f.get_basename())
	names.sort()
	for n in names:
		var uss_path: String = CASES_DIR + n + ".uss"
		cases.append({"name": n,
			"uxml": FileAccess.get_file_as_string(CASES_DIR + n + ".uxml"),
			"uss": FileAccess.get_file_as_string(uss_path) if FileAccess.file_exists(uss_path) else "",
			"files": _case_files(CASES_DIR + n + ".files")})
	var done := 0
	for c in cases:
		var name: String = c["name"]
		if not _only.is_empty() and not _only.has(name):
			continue
		var dpath: String = UNITY_DIR + name + ".json"
		if not FileAccess.file_exists(dpath):
			continue
		var dump: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dpath))
		await _render_case(c, dump)
		done += 1
	print("PIXELS RENDER: %d cases -> %s" % [done, _out])
	quit(0)


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


func _write(path: String, content: Variant) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if content is PackedByteArray:
		f.store_buffer(content)
	else:
		f.store_string(content)
	f.close()


## Unity's project data in the dump project (as bench/parity.gd).
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
## (as bench/parity.gd).
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


# DumpTarget.cs: AnimationCurve.Linear(0, 0, 1, 1) and new Gradient()
# (white to white).
func _init() -> void:
	curveValue.add_point(Vector2(0, 0), 0.0, 1.0)
	curveValue.add_point(Vector2(1, 1), 1.0, 0.0)
	gradientValue.colors = PackedColorArray([Color.WHITE, Color.WHITE])
""",
	"DumpSmallTarget": """extends Resource
@export var count: int = 3
@export var title: String = "Hi"
@export var active: bool = false
""",
}


func _bind_target(type_name: String, root: String) -> Object:
	var path := root + "/" + type_name + ".gd"
	_write(path, BIND_SCRIPTS[type_name])
	var script := GDScript.new()
	script.source_code = BIND_SCRIPTS[type_name]
	script.resource_path = path
	script.reload()
	return script.new()


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


func _render_case(c: Dictionary, dump: Dictionary) -> void:
	var name: String = c["name"]
	var sidecar := {}
	var side := CASES_DIR + name + ".json"
	if FileAccess.file_exists(side):
		var sj = JSON.parse_string(FileAccess.get_file_as_string(side))
		if sj is Dictionary:
			sidecar = sj
	var actions: Array = sidecar.get("actions", [])
	var skin := String(sidecar.get("editor", ""))
	var panel := Vector2i(int(dump["panel"]["width"]), int(dump["panel"]["height"]))
	# Files as bench/parity.gd lays them out.
	var root := "user://godot_uxml_pixels/cases/%s" % name
	var dir := root + "/Assets/GoldenCases/"
	DirAccess.make_dir_recursive_absolute(dir)
	var files: Dictionary = c["files"]
	for path in files:
		var p: String = path
		_write(root + "/" + p if (p.begins_with("Packages/") or p.begins_with("Assets/")) else dir + p, files[path])
	var uxml_path := dir + name + ".uxml"
	var uxml: String = c["uxml"]
	_write(uxml_path, uxml)

	_vp = SubViewport.new()
	_vp.size = panel
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.gui_embed_subwindows = true
	get_root().add_child(_vp)
	RenderingServer.set_default_clear_color(CLEAR.get(skin, CLEAR[""]))
	var doc := UxmlDocument.new()
	doc.auto_load = false
	doc.transitions_manual = true
	if not skin.is_empty():
		doc.editor_theme = "always"
		doc.editor_skin = skin
	doc.position = Vector2.ZERO
	doc.size = Vector2(panel)
	_vp.add_child(doc)
	_load(doc, uxml, uxml_path, root, c["uss"], actions)
	if sidecar.has("bind"):
		doc.set_data_source(_bind_target(String(sidecar["bind"]), root))
	doc.size = Vector2(panel)
	await process_frame
	await _apply_actions(doc, actions)
	_sync_unity_state(doc, dump)
	for k in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	_save(name + ".png")
	_save_rects(doc, name + ".rects.json")
	_hide_text(doc)
	for k in 2:
		await process_frame
	await RenderingServer.frame_post_draw
	_save(name + ".notext.png")
	_vp.queue_free()
	await process_frame


## UxmlDocument.load_source with the case sheet attached to the case root,
## as the dumper attaches it (host.styleSheets.Add) and bench/parity.gd
## loads it (UxmlLoader.load_source with the sheet).
## C# properties that a case sets (`set-prop`; Unity 6000.3 has no UXML
## attribute for them) become the attributes godot-uxml reads, before the
## controls are built, as bench/parity.gd does.
const PROP_ATTRS := {"flex": "flex", "choicesMasks": "choices-masks"}


func _load(doc: UxmlDocument, uxml: String, uxml_path: String, root: String, uss: String,
		actions: Array = []) -> void:
	doc._clear()
	doc._resolver = UxmlResourceResolver.new(root)
	doc._doc = UxmlLoader.load_source(uxml, uxml_path, doc._resolver, uss)
	for act in actions:
		if String(act.get("op", "")) == "set-value" and act.get("value") is Array:
			_initial_curve_gradient(doc._doc.find_by_name(String(act.get("target", ""))), act["value"])
			continue
		if String(act.get("op", "")) != "set-prop":
			continue
		var attr: String = PROP_ATTRS.get(String(act.get("prop", "")), "")
		var el: UxmlElement = doc._doc.find_by_name(String(act.get("target", "")))
		if attr.is_empty() or el == null:
			continue
		var v = act.get("value")
		if v is Array:
			var parts := PackedStringArray()
			for x in v:
				parts.append(str(int(x)) if x is float else str(x))
			el.set_attribute(attr, ",".join(parts))
		else:
			el.set_attribute(attr, str(v).to_lower() if v is bool else str(v))
	doc._effective_root = root
	UxmlTheme.attach(doc._doc, doc.theme_path, doc.editor_theme, doc.editor_skin)
	doc._start_runtime()


## A CurveField's or GradientField's `set-value` ([[time, value], ...] or
## [[time, "#rrggbb"], ...]) as the field's initial value: an
## AnimationCurve's keys with flat tangents (Unity's Keyframe(time, value))
## and a Gradient's colour keys.
func _initial_curve_gradient(el: UxmlElement, keys: Array) -> void:
	if el == null:
		return
	if el.local == "CurveField":
		var c := Curve.new()
		for k in keys:
			c.add_point(Vector2(float(k[0]), float(k[1])))
		el.set_meta(&"uxml_initial_value", c)
	elif el.local == "GradientField":
		var g := Gradient.new()
		var offs := PackedFloat32Array()
		var cols := PackedColorArray()
		for k in keys:
			offs.append(float(k[0]))
			cols.append(Color.html(String(k[1])))
		g.offsets = offs
		g.colors = cols
		el.set_meta(&"uxml_initial_value", g)


func _save(file: String) -> void:
	var img := _vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	img.save_png(_out.path_join(file))


## Each element's control rect relative to the document, by tree path:
## what the runtime laid out (bench/pixels.py compares it with Unity's).
func _save_rects(doc: UxmlDocument, file: String) -> void:
	var out := {}
	var ours := _paths(doc._doc.root)
	var origin := doc.get_global_transform()
	if doc.get_runtime() == 2:
		for p in ours:
			var r := doc.get_element_rect(ours[p])
			if r != Rect2() and doc._v2.rt.call("is_shown", doc._v2.index_of(ours[p])):
				out[p] = [r.position.x, r.position.y, r.size.x, r.size.y]
		out["__runtime"] = 2
	elif UxmlDocument.default_runtime == 2:
		out["__fallback"] = doc.runtime_fallback
	for p in ([] if doc.get_runtime() == 2 else ours):
		var c = doc._controls.get(ours[p])
		if not (c is Control) or not (c as Control).is_visible_in_tree():
			continue
		var t := origin.affine_inverse() * (c as Control).get_global_transform()
		if t.x.distance_to(Vector2.RIGHT) > 1e-4 or t.y.distance_to(Vector2.DOWN) > 1e-4:
			continue  # rotated or scaled: Unity's worldBound is a bounding box
		out[p] = [t.origin.x, t.origin.y, (c as Control).size.x, (c as Control).size.y]
	var f := FileAccess.open(_out.path_join(file), FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()


func _apply_actions(doc: UxmlDocument, actions: Array) -> void:
	for act in actions:
		var op := String(act.get("op", ""))
		var target := String(act.get("target", ""))
		match op:
			"items":
				var values: Array = []
				if act.has("values"):
					for v in act["values"]:
						values.append(str(v))
				else:
					for i in int(act.get("count", 0)):
						values.append("Item %d" % i)
				doc.set_items_source(target, values)
			"tree-items":
				doc.set_tree_source(target, _tree_items(act.get("items", [])))
				if act.get("expand", false):
					for id in _tree_ids(act.get("items", [])):
						doc.set_tree_item_expanded(target, id, true)
			"select":
				var idx: Array = []
				for i in act.get("indices", []):
					idx.append(int(i))
				doc.set_selection(target, idx)
			"scroll":
				doc.set_scroll_offset(target, Vector2(float(act.get("x", 0)), float(act.get("y", 0))))
			"breadcrumbs":
				for t in act.get("items", []):
					doc.push_breadcrumb(target, str(t))
			"add-class", "remove-class":
				var el := doc.get_element_model(target)
				if el != null:
					var cls := String(act["class"])
					var list := el.class_list()
					if op == "add-class" and not list.has(cls):
						list.append(cls)
					elif op == "remove-class":
						list.erase(cls)
					el.set_attribute("class", " ".join(list))
				doc._restyle_now()
			"advance":
				doc._restyle_now()
				doc.advance_transitions(float(act["ms"]) / 1000.0)
			"submit":
				# A dropdown opens its menu (Unity's GenericDropdownMenu in the
				# panel; the runtime's UxmlPopupMenu, embedded in the viewport).
				var el := doc.get_element_model(target)
				var b = null if el == null else doc._behaviors.get(el)
				if b != null and b.has_method("open_menu"):
					b.open_menu()
			"focus":
				var el := doc.get_element_model(target)
				var ctl = null if el == null else doc._natives.get(el, doc._controls.get(el))
				if ctl is Control and (ctl as Control).focus_mode != Control.FOCUS_NONE:
					(ctl as Control).grab_focus()
		await process_frame


func _tree_items(src: Array) -> Array:
	var out: Array = []
	for o in src:
		out.append({"id": int(o["id"]), "data": str(o.get("data", o["id"])),
			"children": _tree_items(o.get("children", []))})
	return out


func _tree_ids(src: Array) -> Array:
	var out: Array = []
	for o in src:
		out.append(int(o["id"]))
		out.append_array(_tree_ids(o.get("children", [])))
	return out


## Unity's control values, pseudo-states, run-time state classes and
## selected tabs after the case's actions, at the same element paths.
func _sync_unity_state(doc: UxmlDocument, dump: Dictionary) -> void:
	var ours := _paths(doc._doc.root)
	for u in dump["elements"]:
		_sync_el(doc, ours, u)
	doc._restyle_now()
	# An open menu: Unity's overlay/0 is the menu element, the root's first
	# child of the menu's own document.
	for m in doc.find_children("*", "UxmlPopupMenu", true, false):
		var md: UxmlDocument = m._doc
		if md == null:
			continue
		var mine := _paths(md._doc.root)
		for u in dump.get("overlay", []):
			var p := String(u["path"])
			if p.begins_with("overlay/0"):
				var mp := "0" + p.substr("overlay/0".length())
				var el = mine.get(mp)
				if el != null:
					var have: Array = u["pseudoStates"]
					for st in STATES:
						md._set_state(el, st, have.has(st) or (st == "checked" and have.has("selected")))
		md._restyle_now()


func _sync_el(doc: UxmlDocument, ours: Dictionary, u: Dictionary) -> void:
	var el = ours.get(String(u["path"]))
	if el != null:
		var e: UxmlElement = el
		var props: Dictionary = u.get("props", {})
		var ut := String(u["type"])
		if props.has("value"):
			if ut in ["Toggle", "Foldout", "RadioButton"] and props["value"] is bool:
				_set_attr(e, "value", "true" if props["value"] else "false")
			elif ut in ["Slider", "SliderInt"] and (props["value"] is float or props["value"] is int):
				_set_attr(e, "value", str(props["value"]))
		if ut == "MinMaxSlider" and props.has("minValue"):
			_set_attr(e, "min-value", str(props["minValue"]))
			_set_attr(e, "max-value", str(props["maxValue"]))
		if ut == "TabView" and props.has("selectedTabIndex") and e.get_attribute("name") != null:
			doc.select_tab(String(e.get_attribute("name")), int(props["selectedTabIndex"]))
		for cls in UxmlInputParts.STATE_CLASSES:
			var want: bool = (u["classes"] as Array).has(cls)
			if e.class_list().has(cls) != want:
				UxmlParts.toggle_control_class(e, cls, want)
		var have: Array = u["pseudoStates"]
		for s in STATES:
			doc._set_state(e, s, have.has(s) or (s == "checked" and have.has("selected")))


func _set_attr(e: UxmlElement, k: String, v: String) -> void:
	if str(e.get_attribute(k)) != v:
		e.set_attribute(k, v)


## Every text colour transparent: Labels and RichTextLabels draw no glyph
## (their shaping and size stay), inputs and buttons get transparent font,
## outline, caret and selection colours.
func _hide_text(n: Node) -> void:
	if n is UxmlDocument and n.get_runtime() == 2:
		n._v2.rt.call("set_text_hidden", true)
		n._v2.rt.call("draw")
	for ch in n.get_children(true):
		_hide_text(ch)
	if n is Label:
		n.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
		n.visible_characters = 0
	elif n is RichTextLabel:
		n.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
		n.visible_characters = 0
	elif n is LineEdit or n is TextEdit or n is Button:
		for k in ["font_color", "font_placeholder_color", "font_uneditable_color", "font_readonly_color",
				"font_selected_color", "font_outline_color", "caret_color", "selection_color",
				"font_hover_color", "font_pressed_color", "font_focus_color", "font_disabled_color",
				"font_hover_pressed_color", "background_color"]:
			if k == "background_color" and not n is TextEdit:
				continue
			if k == "background_color":
				continue
			n.add_theme_color_override(k, Color(0, 0, 0, 0))
