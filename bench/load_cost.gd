extends SceneTree
## Load cost of a 507-element editor-style document (12 panels of rows of a
## Label, a Button, a Toggle and a TextField; the document of the
## uxml-editor's `bench/frame_cost.gd --fixture=large`), and the cost of
## the text and display updates of R15.
##
##   Godot --headless --path <project> -s res://bench/load_cost.gd [-- options]
##
## Options (after `--`):
##   --gdscript     disable the native core
##   --rounds=<n>   loads per mode (default 15)
##   --profile      also print the time of each load step (a copy of the
##                  steps of UxmlDocument._finish_load, so the numbers add
##                  up to a load; the copy follows the current code)
##
## Prints one LOAD_COST line per measure: the median ms of the rounds.

const ROOT := "user://godot_uxml_bench"
const PATH := "Assets/UI/editor_large.uxml"

var _rounds := 15
var _profile := false


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--gdscript":
			UxmlParser.use_native = false
			UssParser.use_native = false
			UssCascade.use_native = false
		elif a.begins_with("--rounds="):
			_rounds = int(a.substr(9))
		elif a == "--profile":
			_profile = true
	_write()
	await process_frame
	await process_frame
	for mode in ["runtime", "editor"]:
		await _measure(mode)
	print("LOAD_COST_COMPLETE")
	quit(0)


func _doc(mode: String) -> UxmlDocument:
	var d := UxmlDocument.new()
	d.editor_theme = "always" if mode == "editor" else "never"
	root.add_child(d)
	d.size = Vector2(1280, 900)
	return d


func _measure(mode: String) -> void:
	var load := PackedFloat64Array()
	var frame := PackedFloat64Array()
	var text_fixed := PackedFloat64Array()
	var text_auto := PackedFloat64Array()
	var text_model := PackedFloat64Array()
	var display := PackedFloat64Array()
	var display_next := PackedFloat64Array()
	var steps := {}
	for i in _rounds:
		var d := _doc(mode)
		var t0 := Time.get_ticks_usec()
		d.load_document(PATH, ROOT)
		load.append((Time.get_ticks_usec() - t0) / 1000.0)
		t0 = Time.get_ticks_usec()
		await process_frame
		frame.append((Time.get_ticks_usec() - t0) / 1000.0)
		await process_frame
		# A Label of fixed size: the status label of a panel title row.
		t0 = Time.get_ticks_usec()
		d.set_text("status", "Status %d" % i)
		d._restyle_now()
		text_fixed.append((Time.get_ticks_usec() - t0) / 1000.0)
		await process_frame
		# A Label whose size follows its text.
		t0 = Time.get_ticks_usec()
		d.set_text("title-3", "Panel three, round %d" % i)
		d._restyle_now()
		text_auto.append((Time.get_ticks_usec() - t0) / 1000.0)
		await process_frame
		# A text change through the element model.
		var el := d.get_element_model("status")
		t0 = Time.get_ticks_usec()
		el.set_attribute("text", "Model %d" % i)
		d._restyle_now()
		text_model.append((Time.get_ticks_usec() - t0) / 1000.0)
		await process_frame
		# A display change of one row, then the next frame.
		var row := d.get_element_model("row-5-3")
		t0 = Time.get_ticks_usec()
		row.set_attribute("style", "display: none;")
		d._restyle_now()
		display.append((Time.get_ticks_usec() - t0) / 1000.0)
		t0 = Time.get_ticks_usec()
		await process_frame
		display_next.append((Time.get_ticks_usec() - t0) / 1000.0)
		if _profile and i > 0:
			_profile_load(mode, steps)
		root.remove_child(d)
		d.free()
		await process_frame
	_print(mode, "load", load)
	_print(mode, "first frame", frame)
	_print(mode, "set_text fixed label", text_fixed)
	_print(mode, "set_text auto label", text_auto)
	_print(mode, "model text", text_model)
	_print(mode, "display change", display)
	_print(mode, "display next frame", display_next)
	for k in steps:
		_print(mode, "step " + k, PackedFloat64Array(steps[k]))


func _print(mode: String, what: String, s: PackedFloat64Array) -> void:
	s.sort()
	print("LOAD_COST %s | %s | %.3f" % [mode, what, s[s.size() / 2]])


static func _add(steps: Dictionary, k: String, t0: int) -> int:
	var t := Time.get_ticks_usec()
	if not steps.has(k):
		steps[k] = []
	(steps[k] as Array).append((t - t0) / 1000.0)
	return t


## The steps of a load, timed one by one (a copy of load_document,
## _finish_load and _index; the restyle is timed whole, then its layout
## again on its own).
func _profile_load(mode: String, steps: Dictionary) -> void:
	var d := _doc(mode)
	var t := Time.get_ticks_usec()
	d._clear()
	var res := d._resolver_for(ROOT, null)
	d._resolver = res
	d._doc = UxmlLoader.load_file_with_resolver(PATH, res)
	d._last_text = null
	t = _add(steps, "parse (uxml, uss, imports)", t)
	d._loader_warnings = d._doc.warnings.size()
	UxmlTheme.attach(d._doc, d.theme_path, d.editor_theme, d.editor_skin)
	t = _add(steps, "theme attach", t)
	var collections := d._prepare_collections()
	UxmlParts.expand(d._doc)
	if collections:
		d._rt_warnings.append_array(UxmlBindings.extract(d._doc))
	t = _add(steps, "part trees", t)
	var stack: Array = [d._doc.root]
	while not stack.is_empty():
		var el: UxmlElement = stack.pop_back()
		for child in el.children:
			d._parents[child] = el
			stack.append(child)
	for el in d._doc.root.walk():
		if el.part_of != null:
			continue
		var n = el.get_attribute("name")
		if n != null and not d._by_name.has(String(n)):
			d._by_name[String(n)] = el
			d._el_names[el] = String(n)
	t = _add(steps, "index (parents, names)", t)
	var factory := UxmlControlFactory.new(d._resolver, d._doc.path, d._doc.source, d._rt_warnings)
	factory.element_paths = d._doc.element_paths
	var built: Array = []
	for child in d._doc.root.children:
		if UssControls.is_non_visual(child.local):
			continue
		built.append(factory.build(child))
	d._controls = factory.controls
	d._natives = factory.natives
	d._controls[d._doc.root] = d._root_box
	for el in d._controls:
		d._el_of[d._controls[el]] = el
	t = _add(steps, "control creation", t)
	d._park_hidden()
	t = _add(steps, "cascade (first resolve)", t)
	for c in built:
		if not c.has_meta(&"uxml_parked"):
			d._root_box.add_child(c)
	if "_first_pass" in d:
		d.set("_first_pass", true)
	t = _add(steps, "add_child (built controls)", t)
	var on_changed := d._on_model_changed
	for el in d._doc.root.walk():
		el.changed = on_changed
	for el in d._controls:
		if el == d._doc.root:
			continue
		d._wire(el, d._controls[el])
	t = _add(steps, "signal wiring", t)
	d._behaviors = UxmlBehaviors.attach_all(d)
	d._attrs.setup()
	d._binding.setup()
	t = _add(steps, "behaviors, attributes, bindings", t)
	var sc: GDScript = d.get_script()
	var has_profile := "profile" in sc
	if has_profile:
		sc.set("profile", {})
	d._restyle_now()
	if has_profile:
		var p: Dictionary = sc.get("profile")
		sc.set("profile", null)
		var rest := (Time.get_ticks_usec() - t) / 1000.0
		for k in ["apply", "layout"]:
			if not steps.has("first restyle: " + k):
				steps["first restyle: " + k] = []
			steps["first restyle: " + k].append(float(p.get(k, 0.0)))
			rest -= float(p.get(k, 0.0))
		if not steps.has("first restyle: cascade update, rest"):
			steps["first restyle: cascade update, rest"] = []
		steps["first restyle: cascade update, rest"].append(rest)
		t = Time.get_ticks_usec()
	else:
		t = _add(steps, "first restyle (apply + layout)", t)
	d._attrs.restore_view_data()
	d._force_layout = true
	d._placed_force = d._controls.keys()
	d._do_layout()
	d._placed_force = []
	_add(steps, "(a second full layout)", t)
	root.remove_child(d)
	d.free()


func _write() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + "/Assets/UI"))
	var u := PackedStringArray()
	u.append("<ui:UXML xmlns:ui=\"UnityEngine.UIElements\">")
	u.append("  <Style src=\"editor_large.uss\" />")
	u.append("  <ui:VisualElement name=\"root\" class=\"root\">")
	u.append("    <ui:Label name=\"status\" class=\"status\" text=\"Status\" />")
	for p in 12:
		u.append("    <ui:VisualElement name=\"panel-%d\" class=\"panel\">" % p)
		u.append("      <ui:Label name=\"title-%d\" class=\"title\" text=\"Panel %d\" />" % [p, p])
		for r in 8:
			u.append("      <ui:VisualElement name=\"row-%d-%d\" class=\"row\">" % [p, r])
			u.append("        <ui:Label class=\"cell\" text=\"Row %d\" />" % r)
			u.append("        <ui:Button class=\"cell button\" text=\"Go\" />")
			u.append("        <ui:Toggle class=\"cell\" label=\"On\" />")
			u.append("        <ui:TextField class=\"cell\" value=\"text %d\" />" % r)
			u.append("      </ui:VisualElement>")
		u.append("    </ui:VisualElement>")
	u.append("  </ui:VisualElement>")
	u.append("</ui:UXML>")
	var s := ".root { flex-direction: row; flex-wrap: wrap; padding: 4px; }\n" \
		+ ".status { width: 1200px; height: 20px; }\n" \
		+ ".panel { width: 300px; margin: 2px; background-color: #303030; border-width: 1px; border-color: #555; }\n" \
		+ ".title { -unity-font-style: bold; align-self: flex-start; }\n.row { flex-direction: row; height: 18px; }\n" \
		+ ".cell { flex-grow: 1; font-size: 10px; }\n.button:hover { background-color: #4a4a4a; }\n"
	var f := FileAccess.open(ROOT + "/" + PATH, FileAccess.WRITE)
	f.store_string("\n".join(u) + "\n")
	f.close()
	f = FileAccess.open(ROOT + "/Assets/UI/editor_large.uss", FileAccess.WRITE)
	f.store_string(s)
	f.close()
