extends SceneTree
## Engine cost of a Label: new, entering the tree, minimum size, in a few
## variants (docs/design.md, "Core-drawn elements").
##   Godot --headless --path . -s res://bench/prof/label_cost.gd
func _variant(name: String, setup: Callable, n := 400) -> void:
	var host := Control.new()
	root.add_child(host)
	var cs: Array = []
	var t0 := Time.get_ticks_usec()
	for i in n:
		var c := Label.new()
		setup.call(c, i)
		cs.append(c)
	var t1 := Time.get_ticks_usec()
	for c in cs: host.add_child(c)
	var t2 := Time.get_ticks_usec()
	for c in cs: c.get_combined_minimum_size()
	var t3 := Time.get_ticks_usec()
	print("%-28s new+setup %.1f add_child %.1f min %.1f" % [name, (t1-t0)/float(n), (t2-t1)/float(n), (t3-t2)/float(n)])
	host.free()
func _initialize() -> void:
	for k in 3: await process_frame
	var font := ThemeDB.fallback_font
	for rep in 2:
		await _variant("plain text", func(c, i): c.text = "Item %d" % i)
		await _variant("empty", func(c, i): pass)
		await _variant("no autotranslate", func(c, i): c.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED; c.text = "Item %d" % i)
		await _variant("font override", func(c, i): c.add_theme_font_override("font", font); c.text = "Item %d" % i)
		await _variant("hidden", func(c, i): c.visible = false; c.text = "Item %d" % i)
		await _variant("no a11y name", func(c, i): c.accessibility_name = "x"; c.text = "Item %d" % i)
	var p := Control.new()
	root.add_child(p)
	var t0 := Time.get_ticks_usec()
	for i in 400:
		var c := Label.new(); c.text = "Item %d" % i
		p.add_child(c)
	print("add to in-tree directly %.1f" % ((Time.get_ticks_usec() - t0) / 400.0))
	var q := Control.new()
	t0 = Time.get_ticks_usec()
	for i in 400:
		var c := Label.new(); c.text = "Item %d" % i
		q.add_child(c)
	var t1 := Time.get_ticks_usec()
	root.add_child(q)
	print("build off-tree %.1f, enter as one subtree %.1f" % [(t1 - t0) / 400.0, (Time.get_ticks_usec() - t1) / 400.0])
	quit(0)
