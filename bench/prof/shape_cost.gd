extends SceneTree
## TextServer shaping cost against a Label's life in a load: how many times a
## Label shapes, and what one shaping costs.
func _initialize() -> void:
	for k in 2: await process_frame
	var ts := TextServerManager.get_primary_interface()
	var font: Font = load("res://addons/godot_uxml/themes/fonts/Inter-Regular.woff2")
	var n := 500
	var texts: Array = []
	for i in n: texts.append("Item %d label" % i)
	for rep in 2:
		var t0 := Time.get_ticks_usec()
		var rids: Array = []
		for s in texts:
			var r := ts.create_shaped_text()
			ts.shaped_text_add_string(r, s + String.chr(0x200B), font.get_rids(), 13, font.get_opentype_features(), "")
			ts.shaped_text_get_size(r)
			var lb := ts.shaped_text_get_line_breaks(r, 400.0, 0, TextServer.BREAK_MANDATORY)
			var line := ts.shaped_text_substr(r, lb[0], lb[1] - lb[0])
			ts.shaped_text_get_size(line)
			rids.append(r); rids.append(line)
		var t1 := Time.get_ticks_usec()
		for r in rids: ts.free_rid(r)
		print("TS shape+line per text: %.1f us" % ((t1 - t0) / float(n)))
		var host := Control.new()
		root.add_child(host)
		var ls: Array = []
		t0 = Time.get_ticks_usec()
		for s in texts:
			var l := Label.new()
			l.text = s
			l.add_theme_font_override("font", font)
			l.add_theme_font_size_override("font_size", 13)
			ls.append(l)
		var t2 := Time.get_ticks_usec()
		for l in ls: host.add_child(l)
		var t3 := Time.get_ticks_usec()
		for l in ls: l.get_combined_minimum_size()
		var t4 := Time.get_ticks_usec()
		print("Label: new+overrides off-tree %.1f, enter %.1f, first min %.1f us" % [(t2-t0)/float(n), (t3-t2)/float(n), (t4-t3)/float(n)])
		host.free()
	quit(0)
