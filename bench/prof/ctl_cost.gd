extends SceneTree
class Probe extends Control:
	var n := 0
	func _notification(what):
		if what == NOTIFICATION_THEME_CHANGED and lookup:
			get_theme_stylebox("normal", "Label"); get_theme_stylebox("focus", "Label")
			get_theme_constant("line_spacing", "Label"); get_theme_constant("paragraph_spacing", "Label")
			get_theme_font("font", "Label"); get_theme_font_size("font_size", "Label")
			get_theme_color("font_color", "Label"); get_theme_color("font_shadow_color", "Label")
			get_theme_constant("shadow_offset_x", "Label"); get_theme_constant("shadow_offset_y", "Label")
			get_theme_color("font_outline_color", "Label"); get_theme_constant("outline_size", "Label")
			get_theme_constant("shadow_outline_size", "Label")
	var lookup := true
func _run(name: String, mk: Callable, n := 500) -> void:
	var host := Control.new()
	root.add_child(host)
	var cs: Array = []
	var t0 := Time.get_ticks_usec()
	for i in n: cs.append(mk.call())
	var t1 := Time.get_ticks_usec()
	for c in cs: host.add_child(c)
	var t2 := Time.get_ticks_usec()
	for c in cs: c.get_combined_minimum_size()
	var t3 := Time.get_ticks_usec()
	print("%-34s new %.1f add_child %.1f min %.1f" % [name, (t1-t0)/float(n), (t2-t1)/float(n), (t3-t2)/float(n)])
	host.free()
func _initialize() -> void:
	for k in 3: await process_frame
	for rep in 2:
		_run("Control", func(): return Control.new())
		_run("UxmlText text+3 overrides+min", func():
			var t: Control = ClassDB.instantiate("UxmlText"); t.text = "Item 17"
			t.add_theme_font_size_override("font_size", 14); t.add_theme_color_override("font_color", Color.RED); t.add_theme_constant_override("line_spacing", 0)
			return t)
		_run("Label text+3 overrides", func():
			var t := Label.new(); t.text = "Item 17"
			t.add_theme_font_size_override("font_size", 14); t.add_theme_color_override("font_color", Color.RED); t.add_theme_constant_override("line_spacing", 0)
			return t)
		_run("Label", func(): return Label.new())
		_run("Probe (13 lookups)", func(): return Probe.new())
		_run("Probe (no lookups)", func(): var p := Probe.new(); p.lookup = false; return p)
		_run("Control mouse ignore", func(): var c := Control.new(); c.mouse_filter = Control.MOUSE_FILTER_IGNORE; return c)
	quit(0)
