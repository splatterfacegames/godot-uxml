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
	_load(doc, uxml, uxml_path, root, c["uss"])
	doc.size = Vector2(panel)
	await process_frame
	await _apply_actions(doc, actions)
	_sync_unity_state(doc, dump)
	for k in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	_save(name + ".png")
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
func _load(doc: UxmlDocument, uxml: String, uxml_path: String, root: String, uss: String) -> void:
	doc._clear()
	doc._resolver = UxmlResourceResolver.new(root)
	doc._doc = UxmlLoader.load_source(uxml, uxml_path, doc._resolver, uss)
	doc._effective_root = root
	UxmlTheme.attach(doc._doc, doc.theme_path, doc.editor_theme, doc.editor_skin)
	doc._index()
	doc._restyle_now()


func _save(file: String) -> void:
	var img := _vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	img.save_png(_out.path_join(file))


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
