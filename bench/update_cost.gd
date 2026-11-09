extends SceneTree
## Cost of the updates an editor makes at selection rate, on the 507-element
## document of bench/reload_cost.gd with a hierarchy TreeView (300 items) and
## an inspector of 70 TextFields:
##
##   tree scroll       scroll_to_item of the TreeView, far and back (R29)
##   tree wheel        a scroll offset of one row (R29)
##   select scroll     a selection and scroll_to_item of the selected item
##   toggle            set_field_value of a Toggle (R17)
##   model toggle      the `value` attribute of a Toggle
##   forced            set_forced_states(["hover"]) of a panel, and clear
##   field values      70 set_field_value calls of text fields (R17)
##   placeholders      70 new placeholders (R28: set_field_placeholder, else
##                     the `placeholder-text` attribute)
##
## Each sample is the call and the restyles that it queues. LAYOUTS gives the
## layout passes of the rounds.
##
##   Godot --headless --path <project> -s res://bench/update_cost.gd [-- options]
##
## Options (after `--`):
##   --gdscript     disable the native core
##   --rounds=<n>   samples per kind (default 15)

static var ROOT: String = UxmlBenchDir.of("godot_uxml_update_bench")
const PATH := "Assets/UI/editor_update.uxml"
const USS_PATH := "Assets/UI/editor_update.uss"

const USS := ".root { flex-direction: row; flex-wrap: wrap; padding: 4px; }\n" \
	+ ".status { width: 1200px; height: 20px; }\n" \
	+ ".panel { width: 300px; margin: 2px; background-color: #303030; border-width: 1px; border-color: #555; }\n" \
	+ ".panel:hover { background-color: #383838; }\n" \
	+ ".title { -unity-font-style: bold; align-self: flex-start; }\n.row { flex-direction: row; height: 18px; }\n" \
	+ ".cell { flex-grow: 1; font-size: 10px; transition-property: min-width; transition-delay: 0s; transition-duration: 1s; }\n" \
	+ ".button:hover { background-color: #4a4a4a; }\n" \
	+ ".side { width: 300px; height: 600px; flex-direction: column; }\n" \
	+ ".hier { height: 300px; }\n.insp { flex-grow: 1; }\n" \
	+ ".insp .unity-text-field { height: 18px; text-overflow: ellipsis; }\n" \
	+ ".field-toggle:checked { color: #ffcc00; }\n"

var _rounds := 15


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--gdscript":
			UxmlParser.use_native = false
			UssParser.use_native = false
			UssCascade.use_native = false
			UxmlDocument.use_native_layout = false
		elif a.begins_with("--rounds="):
			_rounds = int(a.substr(9))
	_write()
	await process_frame
	await process_frame
	var d := UxmlDocument.new()
	d.editor_theme = "never"
	d.transitions_manual = true
	root.add_child(d)
	d.size = Vector2(1600, 1000)
	d.load_document(PATH, ROOT)
	await process_frame
	var roots: Array = []
	for i in 300:
		roots.append({"id": i, "data": "Element %d" % i, "children": []})
	d.set_tree_source("hier", roots)
	await process_frame
	await process_frame
	_flush(d)
	var panel: UxmlElement = d.get_element_model("panel-3")
	var runs := {}
	var layouts := {}
	for i in _rounds * 2 + 2:
		var on := i % 2 == 0
		var keep := i >= 2
		_time(d, runs, layouts, keep, "tree scroll", func(): d.scroll_to_item("hier", 250 if on else 0))
		await process_frame
		_time(d, runs, layouts, keep, "tree wheel", func(): d.set_scroll_offset("hier", Vector2(0, 22.0 * (3 + i % 2))))
		await process_frame
		_time(d, runs, layouts, keep, "select scroll", func():
			var at := 40 + i * 7
			d.set_selection("hier", [at])
			d.scroll_to_item("hier", at))
		await process_frame
		if d.has_method("set_field_value"):
			_time(d, runs, layouts, keep, "toggle", func(): d.call("set_field_value", "field-toggle", on))
			await process_frame
		_time(d, runs, layouts, keep, "model toggle", func():
			d.get_element_model("field-toggle2").set_attribute("value", "true" if on else "false"))
		await process_frame
		if d.has_method("set_forced_states"):
			_time(d, runs, layouts, keep, "forced", func():
				if on:
					d.set_forced_states(panel, PackedStringArray(["hover"]))
				else:
					d.clear_forced_states())
			await process_frame
		if d.has_method("set_field_value"):
			_time(d, runs, layouts, keep, "field values", func():
				for f in 70:
					d.call("set_field_value", "f%d" % f, "value %d %d" % [f, i]))
			await process_frame
		_time(d, runs, layouts, keep, "placeholders", func():
			for f in 70:
				var t := "computed %d from .rule-%d (round %d)" % [f, f, i]
				if d.has_method("set_field_placeholder"):
					d.call("set_field_placeholder", "f%d" % f, t)
				else:
					d.get_element_model("f%d" % f).set_attribute("placeholder-text", t))
		await process_frame
	for k in runs:
		var s := PackedFloat64Array(runs[k])
		s.sort()
		print("UPDATE_COST %s | %.3f" % [k, s[s.size() / 2]])
		print("LAYOUTS %s | %d" % [k, layouts[k]])
	root.remove_child(d)
	d.free()
	print("UPDATE_COST_COMPLETE")
	quit(0)


static func _flush(d: UxmlDocument) -> void:
	var n := 0
	while d._restyle_queued and n < 8:
		d._restyle_now()
		n += 1


func _time(d: UxmlDocument, runs: Dictionary, layouts: Dictionary, keep: bool, k: String, body: Callable) -> void:
	_flush(d)
	var l0 := d.layout_count
	var t0 := Time.get_ticks_usec()
	body.call()
	_flush(d)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	if not keep:
		return
	if not runs.has(k):
		runs[k] = []
		layouts[k] = 0
	(runs[k] as Array).append(ms)
	layouts[k] += d.layout_count - l0


func _write() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + "/Assets/UI"))
	var u := PackedStringArray()
	u.append("<ui:UXML xmlns:ui=\"UnityEngine.UIElements\">")
	u.append("  <Style src=\"editor_update.uss\" />")
	u.append("  <ui:VisualElement name=\"root\" class=\"root\">")
	u.append("    <ui:Label name=\"status\" class=\"status\" text=\"Status\" />")
	u.append("    <ui:Toggle name=\"field-toggle\" class=\"status field-toggle\" />")
	u.append("    <ui:Toggle name=\"field-toggle2\" class=\"status field-toggle\" />")
	u.append("    <ui:VisualElement name=\"side\" class=\"side\">")
	u.append("      <ui:TreeView name=\"hier\" class=\"hier\" fixed-item-height=\"22\" />")
	u.append("      <ui:ScrollView name=\"insp\" class=\"insp\">")
	for f in 70:
		u.append("        <ui:TextField name=\"f%d\" label=\"Field %d\" value=\"v\" placeholder-text=\"computed\" />" % [f, f])
	u.append("      </ui:ScrollView>")
	u.append("    </ui:VisualElement>")
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
	var f := FileAccess.open(ROOT + "/" + PATH, FileAccess.WRITE)
	f.store_string("\n".join(u) + "\n")
	f.close()
	f = FileAccess.open(ROOT + "/" + USS_PATH, FileAccess.WRITE)
	f.store_string(USS)
	f.close()
