extends SceneTree
## Cost of UxmlDocument.reload_stylesheet on the 507-element document of
## bench/load_cost.gd with two named fields (R25, R17), and of the restyle that
## the next state change runs. The edits have the sizes an editor makes:
##
##   paint       one colour of `.panel` (12 elements)
##   inherited   one inherited property of `.panel` (font-size; every row)
##   layout      one length of `.row` (96 elements)
##   transition  one `transition-delay` of `.cell` (384 elements)
##   none        no change of the text
##   selector    one selector of a rule (the rules are compiled again)
##   rule        one rule added at the end of the sheet
##
## It also times a new value of a field (R17): "field text" and "field toggle"
## through set_field_value, and "model text" and "model toggle" through the
## `value` attribute, with the flush of each.
##
##   Godot --headless --path <project> -s res://bench/reload_cost.gd [-- options]
##
## Options (after `--`):
##   --gdscript     disable the native core
##   --rounds=<n>   edits per kind (default 15)
##
## Prints RELOAD_COST lines: the median ms of the rounds of each edit, and
## "<edit> next" for the first state change after the reload, as an editor
## arms a transition run after a render.

const ROOT := "user://godot_uxml_reload_bench"
const PATH := "Assets/UI/editor_large.uxml"
const USS_PATH := "Assets/UI/editor_large.uss"

const USS := ".root { flex-direction: row; flex-wrap: wrap; padding: 4px; }\n" \
	+ ".status { width: 1200px; height: 20px; }\n" \
	+ ".panel { width: 300px; margin: 2px; background-color: #303030; border-width: 1px; border-color: #555; }\n" \
	+ ".title { -unity-font-style: bold; align-self: flex-start; }\n.row { flex-direction: row; height: 18px; }\n" \
	+ ".cell { flex-grow: 1; font-size: 10px; transition-property: min-width; transition-delay: 0s; transition-duration: 1s; }\n" \
	+ ".button:hover { background-color: #4a4a4a; }\n"

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
	d.size = Vector2(1280, 900)
	d.load_document(PATH, ROOT)
	await process_frame
	await process_frame
	var origin := ""
	for sh in d.get_document_model().sheets:
		if String(sh["origin"]).ends_with("editor_large.uss"):
			origin = sh["origin"]
	var button: UxmlElement = null
	for el in d.get_document_model().root.walk():
		if el.local == "Button" and el.part_of == null:
			button = el
			break
	# [name, text at an odd round, text at an even round]
	var kinds := [
		["paint", USS.replace("#303030", "#313131"), USS],
		["inherited", USS.replace("border-color: #555;", "border-color: #555; font-size: 12px;"),
			USS.replace("border-color: #555;", "border-color: #555; font-size: 13px;")],
		["layout", USS.replace("height: 18px", "height: 19px"), USS],
		["transition", USS.replace("transition-delay: 0s", "transition-delay: 0.1s"), USS],
		["none", USS, USS],
		["selector", USS.replace(".title {", ".title, .nothing {"), USS],
		["rule", USS + ".extra { color: #123456; }\n", USS],
	]
	for k in kinds:
		var cost := PackedFloat64Array()
		var next := PackedFloat64Array()
		for i in _rounds * 2:
			var text: String = k[1] if i % 2 == 0 else k[2]
			var t0 := Time.get_ticks_usec()
			d.reload_stylesheet(origin, text)
			var t1 := Time.get_ticks_usec()
			d.set_element_state_for(button, "hover", i % 2 == 0)
			d.get_transitions()
			var t2 := Time.get_ticks_usec()
			if i > 1:  # the first change of the kind leaves the last kind's text
				cost.append((t1 - t0) / 1000.0)
				next.append((t2 - t1) / 1000.0)
			await process_frame
		_print(k[0], cost)
		_print(String(k[0]) + " next", next)
		if d.has_method("get_last_reload_mode"):
			print("RELOAD_MODE %s %s" % [k[0], d.call("get_last_reload_mode")])
		d.reload_stylesheet(origin, USS)
		await process_frame
	await _fields(d)
	root.remove_child(d)
	d.free()
	print("RELOAD_COST_COMPLETE")
	quit(0)


func _fields(d: UxmlDocument) -> void:
	var text := d.get_element_model("field-text")
	var tog := d.get_element_model("field-toggle")
	var runs := {}
	for i in _rounds * 2:
		var t := "v%d" % i
		var on := i % 2 == 0
		var t0 := Time.get_ticks_usec()
		text.set_attribute("value", t)
		d._restyle_now()
		_add(runs, "model text", t0)
		await process_frame
		t0 = Time.get_ticks_usec()
		tog.set_attribute("value", "true" if on else "false")
		d._restyle_now()
		_add(runs, "model toggle", t0)
		await process_frame
		if not d.has_method("set_field_value"):
			continue
		t0 = Time.get_ticks_usec()
		d.call("set_field_value", "field-text", "f" + t)
		if d._restyle_queued:
			d._restyle_now()
		_add(runs, "field text", t0)
		await process_frame
		t0 = Time.get_ticks_usec()
		d.call("set_field_value", "field-toggle", not on)
		if d._restyle_queued:
			d._restyle_now()
		_add(runs, "field toggle", t0)
		await process_frame
	for k in runs:
		_print(k, PackedFloat64Array(runs[k]))


static func _add(runs: Dictionary, k: String, t0: int) -> void:
	if not runs.has(k):
		runs[k] = []
	(runs[k] as Array).append((Time.get_ticks_usec() - t0) / 1000.0)


func _print(what: String, s: PackedFloat64Array) -> void:
	s.sort()
	print("RELOAD_COST %s | %.3f" % [what, s[s.size() / 2]])


func _write() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + "/Assets/UI"))
	var u := PackedStringArray()
	u.append("<ui:UXML xmlns:ui=\"UnityEngine.UIElements\">")
	u.append("  <Style src=\"editor_large.uss\" />")
	u.append("  <ui:VisualElement name=\"root\" class=\"root\">")
	u.append("    <ui:Label name=\"status\" class=\"status\" text=\"Status\" />")
	u.append("    <ui:TextField name=\"field-text\" class=\"status\" value=\"v\" />")
	u.append("    <ui:Toggle name=\"field-toggle\" class=\"status\" />")
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
