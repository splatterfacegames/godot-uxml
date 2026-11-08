extends SceneTree
## Census of the controls of a document: kind, mouse filter, focus, children.
func _initialize() -> void:
	var path := "Assets/UI/big.uxml"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--doc="): path = a.substr(6)
	for k in 2: await process_frame
	var d := UxmlDocument.new()
	root.add_child(d)
	d.size = Vector2(1280, 800)
	d.load_document(path, "user://godot_uxml_ucmp")
	d._restyle_now()
	var counts := {}
	for el in d._controls:
		var c: Control = d._controls[el]
		var kind: String = c.get_class() if c.get_script() == null else c.get_script().get_global_name()
		var key: String = "%s mouse=%d focus=%d" % [kind, c.mouse_filter, c.focus_mode]
		counts[key] = counts.get(key, 0) + 1
	var ks := counts.keys(); ks.sort_custom(func(a, b): return counts[a] > counts[b])
	for k in ks: print("%5d %s" % [counts[k], k])
	quit(0)
