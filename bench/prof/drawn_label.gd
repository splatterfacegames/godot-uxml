extends SceneTree
## Core-drawn text, step 1: Godot's Label (scene/gui/label.cpp, 4.7.1) ported
## to TextServer calls for the cases godot-uxml uses (LTR, no visible
## characters, no overrun, autowrap off or word-smart, the horizontal and
## vertical alignments, outline, shadow), drawn into a canvas item and
## compared pixel by pixel with a real Label. Also times both.
##   Godot --path . -s res://bench/prof/drawn_label.gd   (windowed: renders)
const W := 220
const H := 64

var ts: TextServer
var use_line_draw := OS.get_cmdline_user_args().has("--line-draw")


class Spec:
	var text := ""
	var font: Font
	var size := 13
	var color := Color.WHITE
	var outline := 0
	var outline_color := Color.BLACK
	var shadow := Color(0, 0, 0, 0)
	var shadow_ofs := Vector2(1, 1)
	var shadow_outline := 1
	var line_spacing := 3
	var halign := HORIZONTAL_ALIGNMENT_LEFT
	var valign := VERTICAL_ALIGNMENT_TOP
	var wrap := TextServer.AUTOWRAP_OFF
	var margins := Vector4(0, 0, 0, 0)  # left, top, right, bottom
	var box := Vector2(W, H)


## Label._shape for one paragraph.
func shape(s: Spec) -> Dictionary:
	var width := int(s.box.x - s.margins.x - s.margins.z)
	var para := ts.create_shaped_text()
	ts.shaped_text_set_direction(para, TextServer.DIRECTION_LTR)
	ts.shaped_text_add_string(para, s.text + String.chr(0x200B), s.font.get_rids(), s.size,
		s.font.get_opentype_features(), TranslationServer.get_tool_locale())
	var flags := TextServer.BREAK_MANDATORY
	if s.wrap == TextServer.AUTOWRAP_WORD_SMART:
		flags = TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE | TextServer.BREAK_MANDATORY
	flags |= TextServer.BREAK_TRIM_START_EDGE_SPACES | TextServer.BREAK_TRIM_END_EDGE_SPACES
	var lb := ts.shaped_text_get_line_breaks(para, width, 0, flags)
	var lines: Array = []
	for i in range(0, lb.size(), 2):
		lines.append(ts.shaped_text_substr(para, lb[i], lb[i + 1] - lb[i]))
	for l in lines:
		ts.shaped_text_set_custom_ellipsis(l, 0x2026)
		ts.shaped_text_overrun_trim_to_width(l, width, 0)
	return {"para": para, "lines": lines}


func _asc_dsc(s: Spec, rid: RID) -> Vector2:
	var font_h := int(s.font.get_height(s.size))
	var asc := ts.shaped_text_get_ascent(rid)
	var dsc := ts.shaped_text_get_descent(rid)
	if asc + dsc < font_h:
		var diff: float = font_h - (asc + dsc)
		asc += diff / 2
		dsc += diff - (diff / 2)
	return Vector2(asc, dsc)


## Label NOTIFICATION_DRAW with get_layout_data, for one paragraph.
func draw(s: Spec, sh: Dictionary, ci: RID) -> void:
	var lines: Array = sh["lines"]
	var total_h := 0.0
	var visible := 0
	for l in lines:
		var ad := _asc_dsc(s, l)
		total_h += ad.x + ad.y + s.line_spacing
		if total_h > ceilf(s.box.y - (s.margins.y + s.margins.w) + s.line_spacing):
			break
		visible += 1
	var last := mini(lines.size(), visible)
	total_h = 0.0
	for i in last:
		var ad := _asc_dsc(s, lines[i])
		total_h += ad.x + ad.y + s.line_spacing
	total_h += s.margins.y + s.margins.w
	var vbegin := 0
	if visible > 0:
		match s.valign:
			VERTICAL_ALIGNMENT_CENTER:
				vbegin = int((s.box.y - (total_h - s.line_spacing)) / 2)
			VERTICAL_ALIGNMENT_BOTTOM:
				vbegin = int(s.box.y - (total_h - s.line_spacing))
	var ofs := Vector2(0, s.margins.y + vbegin)
	for i in last:
		var l: RID = lines[i]
		var lsize := ts.shaped_text_get_size(l)
		match s.halign:
			HORIZONTAL_ALIGNMENT_CENTER:
				ofs.x = int(s.box.x - lsize.x) / 2
			HORIZONTAL_ALIGNMENT_RIGHT:
				ofs.x = int(s.box.x - s.margins.z - lsize.x)
			_:
				ofs.x = s.margins.x
		var ad := _asc_dsc(s, l)
		ofs.y += ad.x
		if use_line_draw:
			# TextServer.shaped_text_draw: the same glyph loop, in the engine.
			if s.shadow.a != 0 and s.shadow_outline > 0:
				ts.shaped_text_draw_outline(l, ci, ofs + s.shadow_ofs, -1, -1, s.shadow_outline, s.shadow)
			if s.shadow.a > 0:
				ts.shaped_text_draw(l, ci, ofs + s.shadow_ofs, -1, -1, s.shadow)
			if s.outline > 0 and s.outline_color.a != 0:
				ts.shaped_text_draw_outline(l, ci, ofs, -1, -1, s.outline, s.outline_color)
			ts.shaped_text_draw(l, ci, ofs, -1, -1, s.color)
		else:
			var glyphs := ts.shaped_text_get_glyphs(l)
			var trim := ts.shaped_text_get_trim_pos(l)
			if s.shadow.a != 0 and s.shadow_outline > 0:
				_glyphs(glyphs, trim, ci, ofs + s.shadow_ofs, s.shadow, s.shadow_outline)
			if s.shadow.a > 0:
				_glyphs(glyphs, trim, ci, ofs + s.shadow_ofs, s.shadow, -1)
			if s.outline > 0 and s.outline_color.a != 0:
				_glyphs(glyphs, trim, ci, ofs, s.outline_color, s.outline)
			_glyphs(glyphs, trim, ci, ofs, s.color, -1)
		ofs.y += ad.y + s.line_spacing


func _glyphs(glyphs: Array, trim: int, ci: RID, ofs: Vector2, color: Color, outline: int) -> void:
	var o := ofs
	for j in glyphs.size():
		if trim >= 0 and j >= trim:
			break
		var g: Dictionary = glyphs[j]
		for k in int(g["repeat"]):
			var rid: RID = g["font_rid"]
			if rid != RID():
				if outline > 0:
					ts.font_draw_glyph_outline(rid, ci, g["font_size"], outline, o + g["offset"], g["index"], color)
				else:
					ts.font_draw_glyph(rid, ci, g["font_size"], o + g["offset"], g["index"], color)
			o.x += float(g["advance"])


func _label(s: Spec) -> Label:
	var l := Label.new()
	l.text = s.text
	l.add_theme_font_override("font", s.font)
	l.add_theme_font_size_override("font_size", s.size)
	l.add_theme_color_override("font_color", s.color)
	l.add_theme_constant_override("outline_size", s.outline)
	l.add_theme_color_override("font_outline_color", s.outline_color)
	l.add_theme_color_override("font_shadow_color", s.shadow)
	l.add_theme_constant_override("shadow_offset_x", int(s.shadow_ofs.x))
	l.add_theme_constant_override("shadow_offset_y", int(s.shadow_ofs.y))
	l.add_theme_constant_override("line_spacing", s.line_spacing)
	l.add_theme_constant_override("shadow_outline_size", s.shadow_outline)
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = s.margins.x
	sb.content_margin_top = s.margins.y
	sb.content_margin_right = s.margins.z
	sb.content_margin_bottom = s.margins.w
	l.add_theme_stylebox_override("normal", sb)
	l.horizontal_alignment = s.halign
	l.vertical_alignment = s.valign
	l.autowrap_mode = s.wrap
	l.size = s.box
	return l


func _specs() -> Array:
	var out: Array = []
	var inter: Font = load("res://addons/godot_uxml/themes/fonts/Inter-Regular.woff2")
	var texts := ["Benchmark", "Item 17", "The lighthouse keeper looked at you for a long time.", "x",
		"Unicode: Üï — ½ ✓", "Two  spaces"]
	var k := 0
	for t in texts:
		for ha in [HORIZONTAL_ALIGNMENT_LEFT, HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_RIGHT]:
			for va in [VERTICAL_ALIGNMENT_TOP, VERTICAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_BOTTOM]:
				for wrap in [TextServer.AUTOWRAP_OFF, TextServer.AUTOWRAP_WORD_SMART]:
					var s := Spec.new()
					s.text = t
					s.font = inter
					s.size = [12, 13, 14, 19][k % 4]
					s.halign = ha
					s.valign = va
					s.wrap = wrap
					s.color = Color(0.9, 0.85, 0.7)
					s.margins = Vector4(k % 3, (k + 1) % 2 * 2, k % 2, 1)
					s.box = Vector2([W, 140, 97][k % 3], H)
					if k % 5 == 0:
						s.outline = 2
						s.outline_color = Color(0.1, 0.2, 0.3)
					if k % 7 == 0:
						s.shadow = Color(0, 0, 0, 0.6)
					k += 1
					out.append(s)
	return out


func _initialize() -> void:
	ts = TextServerManager.get_primary_interface()
	var specs := _specs()
	var va := SubViewport.new()
	var vb := SubViewport.new()
	for v in [va, vb]:
		v.size = Vector2i(W, H)
		v.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(v)
		var bg := ColorRect.new()
		bg.color = Color(0.2, 0.2, 0.25)
		bg.size = Vector2(W, H)
		v.add_child(bg)
	var holder := Control.new()
	holder.size = Vector2(W, H)
	vb.add_child(holder)
	var ci := RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(ci, holder.get_canvas_item())
	var exact := 0
	var worst := 0
	var fails: Array = []
	for i in specs.size():
		var s: Spec = specs[i]
		var l := _label(s)
		va.add_child(l)
		await process_frame
		s.box = l.size  # a Label is never smaller than its minimum size
		RenderingServer.canvas_item_clear(ci)
		var sh := shape(s)
		draw(s, sh, ci)
		for f in 3:
			await process_frame
		await RenderingServer.frame_post_draw
		var ia := va.get_texture().get_image()
		var ib := vb.get_texture().get_image()
		var diff := 0
		var maxd := 0
		for y in H:
			for x in W:
				var a := ia.get_pixel(x, y)
				var b := ib.get_pixel(x, y)
				var dd := int(roundf(maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b)) * 255))
				if dd > 0:
					diff += 1
					maxd = maxi(maxd, dd)
		if diff == 0:
			exact += 1
		else:
			fails.append("case %d [%s] h%d v%d wrap%d size%d box%s: %d px differ, max %d" % [
				i, s.text, s.halign, s.valign, s.wrap, s.size, s.box, diff, maxd])
		worst = maxi(worst, maxd)
		l.queue_free()
		ts.free_rid(sh["para"])
		for r in sh["lines"]:
			ts.free_rid(r)
	for f in fails.slice(0, 12):
		print(f)
	print("DRAWN_LABEL pixels: %d of %d cases exact, max channel error %d" % [exact, specs.size(), worst])
	await _time(specs)
	quit(0)


func _time(specs: Array) -> void:
	var host := Control.new()
	root.add_child(host)
	var n := 400
	var t0 := Time.get_ticks_usec()
	for i in n:
		var l := _label(specs[i % specs.size()])
		host.add_child(l)
		l.get_combined_minimum_size()
	var t1 := Time.get_ticks_usec()
	var items: Array = []
	for i in n:
		var c := RenderingServer.canvas_item_create()
		RenderingServer.canvas_item_set_parent(c, host.get_canvas_item())
		var sh := shape(specs[i % specs.size()])
		draw(specs[i % specs.size()], sh, c)
		items.append(c)
	var t2 := Time.get_ticks_usec()
	print("DRAWN_LABEL time per text: Label (new, overrides, enter, measure) %.1f us; TextServer port in GDScript (shape, draw) %.1f us" % [
		(t1 - t0) / float(n), (t2 - t1) / float(n)])
	for c in items:
		RenderingServer.free_rid(c)
	host.free()
