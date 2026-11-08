extends SceneTree
## UxmlText (native/src/text.rs) against Label: pixels of 144 cases, minimum
## sizes and line counts. Godot --path . -s res://bench/prof/drawn_text.gd (windowed)
## UxmlText against Label: pixels of the cases of bench/prof/drawn_label.gd
## plus multi-paragraph, overrun, clip, label settings; and the minimum sizes.
const W := 220
const H := 64
func _mk(cls: String, s: Dictionary) -> Control:
	var l: Control = ClassDB.instantiate(cls)
	l.text = s.text
	l.add_theme_font_override("font", s.font)
	l.add_theme_font_size_override("font_size", s.size)
	l.add_theme_color_override("font_color", s.color)
	l.add_theme_constant_override("outline_size", s.outline)
	l.add_theme_color_override("font_outline_color", Color(0.1, 0.2, 0.3))
	l.add_theme_color_override("font_shadow_color", s.shadow)
	l.add_theme_constant_override("line_spacing", s.ls)
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = s.m.x; sb.content_margin_top = s.m.y; sb.content_margin_right = s.m.z; sb.content_margin_bottom = s.m.w
	l.add_theme_stylebox_override("normal", sb)
	l.horizontal_alignment = s.ha
	l.vertical_alignment = s.va
	l.autowrap_mode = s.wrap
	l.text_overrun_behavior = s.ov
	l.clip_text = s.clip
	if s.settings: 
		var ls := LabelSettings.new(); ls.font = s.font; ls.font_size = s.size + 1; ls.paragraph_spacing = 3; ls.font_color = s.color
		l.label_settings = ls
	return l
func _specs() -> Array:
	var out: Array = []
	var inter: Font = load("res://addons/godot_uxml/themes/fonts/Inter-Regular.woff2")
	var fv := FontVariation.new(); fv.base_font = inter; fv.spacing_bottom = -1
	var texts := ["Benchmark", "Item 17", "The lighthouse keeper looked at you for a long time.", "x", "", "Two\nparagraphs here", "Unicode: Üï — ½ ✓", "Two  spaces "]
	var k := 0
	for t in texts:
		for ha in [0, 1, 2]:
			for va in [0, 1, 2]:
				for wrap in [TextServer.AUTOWRAP_OFF, TextServer.AUTOWRAP_WORD_SMART]:
					var s := {"text": t, "font": inter if k % 3 else fv, "size": [12, 13, 14, 19][k % 4], "color": Color(0.9, 0.85, 0.7),
						"outline": 2 if k % 5 == 0 else 0, "shadow": Color(0, 0, 0, 0.6) if k % 7 == 0 else Color(0, 0, 0, 0),
						"ls": [0, 3][k % 2], "m": Vector4(k % 3, (k + 1) % 2 * 2, k % 2, 1), "ha": ha, "va": va, "wrap": wrap,
						"ov": TextServer.OVERRUN_TRIM_ELLIPSIS if k % 11 == 0 else 0, "clip": k % 13 == 0, "settings": k % 17 == 0,
						"box": Vector2([W, 140, 97][k % 3], [H, 30, 18][k % 3 if k % 4 == 1 else 0])}
					k += 1
					out.append(s)
	return out
func _initialize() -> void:
	var specs := _specs()
	var vps := []
	for i in 2:
		var v := SubViewport.new()
		v.size = Vector2i(W, H)
		v.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(v)
		var bg := ColorRect.new(); bg.color = Color(0.2, 0.2, 0.25); bg.size = Vector2(W, H)
		v.add_child(bg)
		vps.append(v)
	var exact := 0; var minok := 0; var lcok := 0
	var fails := []
	for i in specs.size():
		var s: Dictionary = specs[i]
		var a := _mk("Label", s); var b := _mk("UxmlText", s)
		vps[0].add_child(a); vps[1].add_child(b)
		a.size = s.box; b.size = s.box
		await process_frame
		a.size = s.box; b.size = s.box
		var ma: Vector2 = a.get_minimum_size(); var mb: Vector2 = b.get_minimum_size()
		if ma == mb: minok += 1
		else: fails.append("case %d min %s vs %s [%s]" % [i, ma, mb, s.text])
		if a.get_line_count() == b.get_line_count(): lcok += 1
		else: fails.append("case %d lines %d vs %d" % [i, a.get_line_count(), b.get_line_count()])
		for f in 3: await process_frame
		await RenderingServer.frame_post_draw
		var ia := (vps[0] as SubViewport).get_texture().get_image()
		var ib := (vps[1] as SubViewport).get_texture().get_image()
		var diff := 0
		for y in H:
			for x in W:
				if ia.get_pixel(x, y) != ib.get_pixel(x, y): diff += 1
		if diff > 0:
			ia.save_png("C:/Users/jetha/AppData/Local/Temp/claude/b7c216f8e8191eb7/9a47b3d8-66d5-4e41-b726-b86cada31e2a/scratchpad/case%d_a.png" % i); ib.save_png("C:/Users/jetha/AppData/Local/Temp/claude/b7c216f8e8191eb7/9a47b3d8-66d5-4e41-b726-b86cada31e2a/scratchpad/case%d_b.png" % i)
			print("lines a ", a.get_line_count(), " vis ", a.get_visible_line_count(), " b ", b.get_visible_line_count())
		if diff == 0: exact += 1
		else: fails.append("case %d [%s] ha%d va%d wrap%d ov%d clip%s set%s size %s/%s min %s: %d px" % [i, s.text, s.ha, s.va, s.wrap, s.ov, s.clip, s.settings, a.size, b.size, ma, diff])
		a.free(); b.free()
	for f in fails.slice(0, 20): print(f)
	print("TEXT_PX %d/%d exact, min %d/%d, lines %d/%d" % [exact, specs.size(), minok, specs.size(), lcok, specs.size()])
	quit(0)
