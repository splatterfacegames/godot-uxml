extends SceneTree
func _initialize() -> void:
	for k in 3: await process_frame
	var host := Control.new()
	root.add_child(host)
	var cs: Array = []
	for i in 500:
		var t: Control = ClassDB.instantiate("UxmlText"); t.text = "Item %d" % i
		t.add_theme_font_size_override("font_size", 14); t.add_theme_color_override("font_color", Color.RED); t.add_theme_constant_override("line_spacing", 0)
		cs.append(t)
	UxmlNative.prof_take(); UxmlNative.prof_enable(true)
	var t0 := Time.get_ticks_usec()
	for c in cs: host.add_child(c)
	var t1 := Time.get_ticks_usec()
	UxmlNative.prof_enable(false)
	var p: Dictionary = UxmlNative.prof_take()
	for k in p: print("%-12s %8.2f ms %6d calls" % [k, p[k][0], p[k][1]])
	print("add_child per item %.1f us" % ((t1 - t0) / 500.0))
	quit(0)
