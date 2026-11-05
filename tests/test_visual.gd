extends RefCounted
## Visual USS properties: opacity, overflow and -unity-overflow-clip-box,
## transforms, text spacing and shadow, elision, white-space, rich text,
## background placement, cursor, all: initial. Every document-level check
## runs on both the native path and the GDScript reference path, and the
## two must place every control identically.

const FIXTURE := "res://tests/fixtures/runtime"

var h = null


func _init(harness) -> void:
	h = harness


func _load(native := true) -> UxmlDocument:
	UssCascade.use_native = native
	var doc := UxmlDocument.new()
	h.root.add_child(doc)
	doc.size = Vector2(500, 1400)
	doc.load_document("Assets/UI/visual.uxml", FIXTURE)
	UssCascade.use_native = true
	return doc


func _unload(doc: UxmlDocument) -> void:
	h.root.remove_child(doc)
	doc.free()


func _messages(doc: UxmlDocument) -> String:
	var out := []
	for d in doc.diagnostics:
		out.append(String(d["message"]))
	return "\n".join(out)


func _both() -> Array:
	var a := _load(true)
	var b := _load(false)
	await h.process_frame
	return [a, b]


# Native and GDScript paths agree on every rect, transform and text.
func test_native_and_gdscript_agree() -> void:
	var docs: Array = await _both()
	var a: UxmlDocument = docs[0]
	var b: UxmlDocument = docs[1]
	h.check(a._cascade._native != null, "native cascade loaded")
	h.check(b._cascade._native == null, "GDScript cascade forced")
	var bad := ""
	for n in a._by_name:
		var ca: Control = a.get_element(n)
		var cb: Control = b.get_element(n)
		if ca.position != cb.position or ca.size != cb.size:
			bad = "%s: %s %s vs %s %s" % [n, ca.position, ca.size, cb.position, cb.size]
			break
		if ca.get_transform() != cb.get_transform() or ca.modulate != cb.modulate:
			bad = "%s transform/modulate differ" % n
			break
		var na: Control = a.get_native(n)
		var nb: Control = b.get_native(n)
		if (na is Label or na is Button) and String(na.get("text")) != String(nb.get("text")):
			bad = "%s text differs: %s vs %s" % [n, na.get("text"), nb.get("text")]
			break
	h.check(bad.is_empty(), "native == GDScript placement (%s)" % bad)
	h.eq(_messages(a), _messages(b), "same diagnostics on both paths")
	_unload(a)
	_unload(b)


func test_opacity() -> void:
	var doc := _load()
	await h.process_frame
	var faded := doc.get_element("faded")
	h.check(absf(faded.modulate.a - 0.4) < 0.001, "opacity -> modulate.a (%s)" % faded.modulate.a)
	h.eq(doc.get_element("fadedkid").modulate.a, 1.0, "children keep their own modulate (perceived opacity)")
	h.eq(doc.get_element("after").modulate.a, 1.0, "no opacity -> untouched")
	var before := faded.position
	doc.set_class("faded", "box")
	await h.process_frame
	h.eq(faded.modulate.a, 1.0, "removing opacity restores 1")
	h.eq(faded.position, before, "opacity is paint-only")
	_unload(doc)


func test_overflow_and_clip_box() -> void:
	var doc := _load()
	await h.process_frame
	var c := doc.get_element("clipped")
	h.check(c.clip_contents, "overflow: hidden -> clip_contents")
	h.check(c.has_meta("uxml_clip"), "border + padding-box clip clips children inside the border")
	h.eq(c.get_meta("uxml_clip").inset, Vector4(4, 4, 4, 4), "padding-box inset is the border")
	var cc := doc.get_element("clipcontent")
	h.eq(cc.get_meta("uxml_clip").inset, Vector4(7, 7, 7, 7), "content-box inset is border + padding")
	h.check(not doc.get_element("faded").clip_contents, "overflow visible by default")
	doc.set_class("clipped", "")
	await h.process_frame
	h.check(not c.clip_contents, "overflow removed -> clip off")
	h.check(not c.has_meta("uxml_clip"), "clip item released")
	_unload(doc)


func test_transforms() -> void:
	var doc := _load()
	await h.process_frame
	var m := doc.get_element("moved")
	var after := doc.get_element("after")
	h.eq(after.position.x, 200.0, "transforms never move layout (sibling at 200)")
	h.check(m.offset_transform_enabled and not m.offset_transform_visual_only, "offset transform on, input follows")
	h.eq(m.offset_transform_position, Vector2(10, 0), "translate px")
	h.eq(m.offset_transform_position_ratio, Vector2(0, 0.5), "translate % is of the element's own size")
	h.check(is_equal_approx(m.offset_transform_rotation, PI / 2), "rotate 90deg")
	h.eq(m.offset_transform_scale, Vector2(2, 1), "scale x y")
	h.eq(m.offset_transform_pivot_ratio, Vector2(0, 0), "transform-origin left top")
	# position + translate (10 + 0, 0.5 * 40) + R*S about the top-left.
	var xf := m.get_transform()
	h.check(xf.origin.is_equal_approx(m.position + Vector2(10, 20)), "translate applied (%s)" % xf.origin)
	h.check(xf.x.is_equal_approx(Vector2(0, 2)), "scale then rotate (%s)" % xf.x)
	doc.set_class("moved", "box")
	await h.process_frame
	h.check(not m.offset_transform_enabled, "transform removed -> off")
	h.eq(m.get_transform().origin, m.position, "no residual transform")
	_unload(doc)


func test_transform_values() -> void:
	h.eq(UssValues.parse_translate("5px")["px"], Vector2(5, 5), "one translate value is both axes")
	h.check(not UssValues.parse_translate("1em")["ok"], "em is not a USS length")
	h.check(is_equal_approx(UssValues.parse_rotate("0.25turn")["angle"], PI / 2), "turn")
	h.check(is_equal_approx(UssValues.parse_rotate("-100grad")["angle"], -PI / 2), "grad")
	h.check(is_equal_approx(UssValues.parse_rotate("z 1rad")["angle"], 1.0), "z axis rotate")
	h.check(not UssValues.parse_rotate("x 30deg")["ok"], "3D rotate is a problem")
	h.eq(UssValues.parse_scale("none")["scale"], Vector2.ONE, "scale none")
	h.eq(UssValues.parse_scale("-1 1 1")["scale"], Vector2(-1, 1), "scale z ignored")
	var o := UssValues.parse_transform_origin("bottom right")
	h.eq(o["ratio"], Vector2(1, 1), "keywords in either order")
	h.eq(UssValues.parse_transform_origin("top")["ratio"], Vector2(0.5, 0), "one vertical keyword")
	var o2 := UssValues.parse_transform_origin("20px 10%")
	h.eq([o2["px"], o2["ratio"]], [Vector2(20, 0), Vector2(0, 0.1)], "px and % origin")


func test_letter_and_word_spacing() -> void:
	var doc := _load()
	await h.process_frame
	var spaced: Label = doc.get_element("spaced")
	var plain: Label = doc.get_element("plain")
	var fv := spaced.get_theme_font("font") as FontVariation
	h.check(fv != null, "spacing -> FontVariation")
	# Unity reads the spacing in em/100: 50 at font-size 20 -> 10px.
	h.eq(fv.spacing_glyph, 10, "letter-spacing in em/100 units")
	h.eq(fv.spacing_space, 20, "word-spacing in em/100 units")
	h.check(spaced.size.x > plain.size.x + 50.0,
		"spacing widens the measured label (%s vs %s)" % [spaced.size.x, plain.size.x])
	_unload(doc)


func test_paragraph_spacing() -> void:
	var doc := _load()
	await h.process_frame
	var p: Label = doc.get_element("paraspaced")
	var q: Label = doc.get_element("paras")
	h.check(p.label_settings != null, "paragraph spacing -> LabelSettings")
	h.eq(p.label_settings.paragraph_spacing, 20.0, "paragraph spacing in em/100 units")
	h.check(p.label_settings.font == q.get_theme_font("font"), "LabelSettings keeps the USS font")
	h.eq(p.label_settings.font_size, 20, "LabelSettings keeps the USS font size")
	h.check(p.size.y > q.size.y + 15.0, "paragraph spacing is measured (%s vs %s)" % [p.size.y, q.size.y])
	h.check(q.label_settings == null, "no paragraph spacing -> no LabelSettings")
	_unload(doc)


func test_text_shadow() -> void:
	var doc := _load()
	await h.process_frame
	var kid: Label = doc.get_element("shadowkid")
	h.eq(kid.get_theme_constant("shadow_offset_x"), 2, "shadow x offset (inherited)")
	h.eq(kid.get_theme_constant("shadow_offset_y"), 3, "shadow y offset")
	h.check(absf(kid.get_theme_color("font_shadow_color").a - 0.5) < 0.01, "shadow color")
	var msgs := _messages(doc)
	h.check(not msgs.contains("blur radius is not supported"), "blur is drawn, not diagnosed")
	h.check((doc.get_element("blurry") as Label).has_meta(&"uxml_shadow"), "blurred shadow copy")
	h.check(not msgs.contains("drawn for Label text only"), "inherited shadow on a Button is not diagnosed")
	h.check(UssValues.parse_text_shadow("red 1px 2px")["ok"], "color first")
	h.eq(UssValues.parse_text_shadow("1px 2px")["color"].a, 0.0, "no color -> transparent (Unity)")
	h.check(not UssValues.parse_text_shadow("1px red 2px")["ok"], "color between lengths is invalid")
	_unload(doc)


func test_elision() -> void:
	var doc := _load()
	await h.process_frame
	var full := "The quick brown fox jumps over the lazy dog"
	var e: Label = doc.get_element("elide-end")
	h.check(e.text.ends_with("...") and e.text.length() < full.length(), "end ellipsis (%s)" % e.text)
	h.check(e.text.begins_with("The"), "end keeps the start")
	var s: Label = doc.get_element("elide-start")
	h.check(s.text.begins_with("...") and s.text.ends_with("dog"), "start ellipsis (%s)" % s.text)
	var m: Label = doc.get_element("elide-mid")
	h.check(m.text.begins_with("The") and m.text.ends_with("dog") and m.text.contains("..."), "middle ellipsis (%s)" % m.text)
	var font := e.get_theme_font("font")
	var fs := e.get_theme_font_size("font_size")
	h.check(font.get_string_size(e.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= 121.0, "elided text fits the content box")
	h.eq(e.tooltip_text, full, "display-tooltip-when-elided (default true) shows the full text")
	var nt: Label = doc.get_element("elide-notip")
	h.eq(nt.tooltip_text, "authored", "display-tooltip-when-elided=false keeps the authored tooltip")
	h.eq((doc.get_element("elide-visible") as Label).text, full, "overflow visible -> no ellipsis")
	h.eq((doc.get_element("elide-fits") as Label).text, "Fox", "fitting text is not elided")
	h.eq(e.size.x, 120.0, "the box keeps its authored width")
	# Widening the box restores the full text and the tooltip.
	doc.get_element_model("elide-end").set_attribute("style", "width: 480px;")
	await h.process_frame
	await h.process_frame
	h.eq(e.text, full, "full text back once it fits")
	h.eq(e.tooltip_text, "", "tooltip cleared once it fits")
	# Game code sets new text: elision takes it as the new full text.
	doc.get_element_model("elide-end").set_attribute("style", "")
	await h.process_frame
	doc.set_text("elide-end", full + " again and again")
	await h.process_frame
	h.check(e.text.ends_with("..."), "new text elided")
	h.eq(e.tooltip_text, full + " again and again", "tooltip is the new full text")
	_unload(doc)


func test_white_space() -> void:
	var doc := _load()
	await h.process_frame
	var pre: Label = doc.get_element("pre")
	var pw: Label = doc.get_element("prewrap")
	h.eq(pre.autowrap_mode, TextServer.AUTOWRAP_OFF, "pre does not wrap")
	h.eq(pw.autowrap_mode, TextServer.AUTOWRAP_WORD_SMART, "pre-wrap wraps")
	h.eq(pw.autowrap_trim_flags, 0, "pre-wrap keeps white space at wrap points")
	var probe := Label.new()
	var default_trim := probe.autowrap_trim_flags
	probe.free()
	var plain: Label = doc.get_element("plain")
	h.eq(plain.autowrap_trim_flags, default_trim, "trim flags untouched without pre-wrap")
	doc.set_class("prewrap", "")
	await h.process_frame
	h.eq(pw.autowrap_trim_flags, default_trim, "trim flags restored")
	_unload(doc)


func test_ignored_text_properties() -> void:
	var doc := _load()
	await h.process_frame
	var msgs := _messages(doc)
	h.check(not msgs.contains("-unity-text-generator"), "-unity-text-generator accepted silently")
	h.check(not msgs.contains("-unity-editor-text-rendering-mode"), "-unity-editor-text-rendering-mode accepted silently")
	var kinds := []
	for d in doc.diagnostics:
		kinds.append(d["kind"])
	h.check(not kinds.has("unsupported-attribute"), "TextElement attributes are known")
	h.check(not kinds.has("unsupported-property"), "no visual property is unsupported")
	_unload(doc)


func test_rich_text() -> void:
	var doc := _load()
	await h.process_frame
	var r := doc.get_element("rich") as RichTextLabel
	h.check(r != null, "tags -> RichTextLabel")
	h.eq(r.get_parsed_text(), "Bold and red 2", "tags removed from the shown text")
	var plain: Label = doc.get_element("richplain")
	h.check(r.size.x > plain.size.x * 0.8 and r.size.x < plain.size.x * 1.3,
		"rich label measures like its plain text (%s vs %s)" % [r.size.x, plain.size.x])
	h.check(r.size.y >= plain.size.y - 1.0, "rich label height measured (%s)" % r.size.y)
	h.check(r.get_theme_font_size("normal_font_size") == 20, "font-size reaches the rich label")
	h.check(doc.get_element("richoff") is Label, "enable-rich-text=false -> Label")
	h.eq((doc.get_element("richoff") as Label).text, "<b>raw</b>", "tags kept as text")
	var lit := doc.get_element("richlit") as RichTextLabel
	h.eq(lit.get_parsed_text(), "<b> a <unknown>", "noparse and unknown tags stay literal")
	var drop := doc.get_element("richdrop") as RichTextLabel
	h.eq(drop.get_parsed_text(), "x link", "unsupported tag dropped, link text kept")
	h.check(_messages(doc).contains("<sprite> is not supported"), "unsupported tag diagnosed")
	h.eq(drop.mouse_filter, Control.MOUSE_FILTER_STOP, "links make the label clickable")
	h.eq((doc.get_element("escapes") as Label).text, "a\nbA", "parse-escape-sequences")
	h.eq((doc.get_element("noescapes") as Label).text, "a\\nb", "escapes off by default")
	h.eq((doc.get_element("richbtn") as Button).text, "Go", "Button text loses its tags")
	doc.set_text("rich", "<i>new</i>")
	await h.process_frame
	h.eq(r.get_parsed_text(), "new", "set_text re-parses rich text")
	_unload(doc)


func test_rich_text_parser() -> void:
	var p := UxmlRichText.parse("<size=150%>a</size><#00ff00>b</color><br><alpha=#80>c<mark=#ffff0080>d</mark>")
	h.check(p["rich"], "rich")
	h.eq(p["plain"], "ab\ncd", "plain text")
	h.eq(UxmlRichText.parse("a < b > c")["rich"], false, "comparison signs are not tags")
	h.eq(UxmlRichText.parse("<color=nope>x</color>")["ops"][0], ["t", "<color=nope>x"], "bad color stays literal up to the close")
	h.eq(UxmlRichText.parse('<a href="https://x.y">go</a>')["ops"][0], ["+", "a", "https://x.y"], "a href")
	h.eq(UxmlRichText._size_spec("-5"), ["rel", -5.0], "size=-5 is relative")
	h.eq(UxmlRichText._size_spec("2em"), ["em", 2.0], "size em")


func test_background_tiles() -> void:
	var bs := UxmlBackgroundStyle.new()
	bs.size_x = ["px", 10.0]
	bs.size_y = ["px", 8.0]
	bs.repeat_x = "repeat"
	bs.pos_x = ["left", "px", 0.0]
	bs.pos_y = ["top", "px", 0.0]
	var t := bs.tiles(Vector2(8, 8), Vector2(35, 8))
	var xs := []
	for tile in t:
		xs.append((tile[0] as Rect2).position.x)
	h.eq(xs, [0.0, 10.0, 20.0, 30.0], "repeat-x from the left edge")
	h.eq((t[3][0] as Rect2).size.x, 5.0, "last tile cropped to the box")
	h.eq((t[3][1] as Rect2).size.x, 4.0, "its source region is cropped too")
	var fit := UxmlBackgroundStyle.new()
	fit.size_type = "contain"
	var ft := fit.tiles(Vector2(8, 8), Vector2(40, 20))
	h.eq(ft.size(), 1, "contain: one image")
	h.eq(ft[0][0], Rect2(10, 0, 20, 20), "contain keeps the aspect, centered")
	var cover := UxmlBackgroundStyle.new()
	cover.size_type = "cover"
	var ct := cover.tiles(Vector2(8, 8), Vector2(40, 20))
	h.eq(ct[0][0], Rect2(0, 0, 40, 20), "cover fills the box")
	h.eq(ct[0][1], Rect2(0, 2, 8, 4), "cover crops the source")
	var sp := UxmlBackgroundStyle.new()
	sp.size_x = ["px", 10.0]
	sp.size_y = ["px", 10.0]
	sp.repeat_x = "space"
	var st := sp.tiles(Vector2(8, 8), Vector2(35, 10))
	var sx := []
	for tile in st:
		sx.append((tile[0] as Rect2).position.x)
	sx.sort()
	h.eq(sx, [0.0, 12.5, 25.0], "space spreads whole tiles")
	var rnd := UxmlBackgroundStyle.new()
	rnd.size_x = ["px", 10.0]
	rnd.size_y = ["px", 10.0]
	rnd.repeat_x = "round"
	rnd.pos_x = ["left", "px", 0.0]
	var rt := rnd.tiles(Vector2(8, 8), Vector2(36, 10))
	h.eq((rt[0][2] as Rect2).size.x, 9.0, "round resizes tiles to fit a whole count")
	var right := UxmlBackgroundStyle.new()
	right.size_x = ["px", 10.0]
	right.size_y = ["px", 10.0]
	right.pos_x = ["right", "px", 4.0]
	right.pos_y = ["bottom", "percent", 0.0]
	h.eq(right.tiles(Vector2(8, 8), Vector2(40, 30))[0][0], Rect2(26, 20, 10, 10), "right 4px bottom")


func test_background_styles() -> void:
	var doc := _load()
	await h.process_frame
	var tiles := doc.get_element("tiles") as UxmlBox
	h.check(tiles.box_texture_style is UxmlBackgroundStyle, "placement -> UxmlBackgroundStyle")
	h.eq((tiles.box_texture_style as UxmlBackgroundStyle).repeat_x, "repeat", "repeat-x")
	var fit := doc.get_element("fit") as UxmlBox
	h.eq((fit.box_texture_style as UxmlBackgroundStyle).size_type, "contain", "scale-to-fit -> contain")
	var btn := doc.get_element("bgbtn") as Button
	var sb := btn.get_theme_stylebox("normal")
	h.check(sb is UxmlBackgroundStyle, "themed control gets the placement stylebox")
	h.eq(sb.content_margin_left, 7.0, "padding (6px) plus the theme border (1px) still insets the text")
	h.check(sb.has_meta("uxml_margins"), "margins meta for the measurer")
	var plain := doc.get_element("plainbg") as UxmlBox
	h.check(plain.box_texture != null and plain.box_texture_style == null, "no placement -> unchanged stretch path")
	_unload(doc)


func test_slice_scale_and_type() -> void:
	var src := '<ui:UXML xmlns:ui="UnityEngine.UIElements"><ui:VisualElement name="n" style="width: 30px; height: 30px; background-image: url(&quot;icon.png&quot;); -unity-slice-left: 2; -unity-slice-right: 2; -unity-slice-top: 2; -unity-slice-bottom: 2; -unity-slice-scale: 2px; -unity-slice-type: tiled;" /><ui:VisualElement name="one" style="width: 30px; height: 30px; background-image: url(&quot;icon.png&quot;); -unity-slice-left: 2; -unity-slice-scale: 1px;" /></ui:UXML>'
	var f := FileAccess.open("user://visual_slice.uxml", FileAccess.WRITE)
	f.store_string(src)
	f.close()
	var doc := UxmlDocument.new()
	h.root.add_child(doc)
	doc.size = Vector2(100, 100)
	# The fixture root holds icon.png; the document file lives in user://.
	DirAccess.copy_absolute("res://tests/fixtures/runtime/Assets/UI/icon.png", "user://icon.png")
	doc.load_document("user://visual_slice.uxml", "user://")
	await h.process_frame
	var n := doc.get_element("n") as UxmlBox
	var bs := n.box_texture_style as UxmlBackgroundStyle
	h.check(bs != null, "slice scale != 1 -> UxmlBackgroundStyle")
	h.eq(bs.slice_scale, 2.0, "slice scale read")
	h.check(bs.slice_tiled, "slice type tiled")
	h.eq(bs.slices, PackedInt32Array([2, 2, 2, 2]), "slices")
	h.check(not _messages(doc).contains("-unity-slice-scale"), "no slice-scale diagnostic any more")
	h.check((doc.get_element("one") as UxmlBox).box_texture_style is StyleBoxTexture, "scale 1 keeps StyleBoxTexture")
	_unload(doc)


func test_cursor() -> void:
	var doc := _load()
	await h.process_frame
	h.eq(doc.get_element("linkcursor").mouse_default_cursor_shape, Control.CURSOR_POINTING_HAND, "cursor: link")
	var t := doc.get_element("texcursor")
	h.eq(t.mouse_default_cursor_shape, UxmlStyleApplier.TEXTURE_CURSOR_SHAPE, "texture cursor shape")
	h.check(t.has_meta("uxml_cursor_tex"), "texture cursor recorded")
	h.eq(t.get_meta("uxml_cursor_tex")[1], Vector2(2, 3), "hotspot")
	doc.set_class("linkcursor", "")
	await h.process_frame
	h.eq(doc.get_element("linkcursor").mouse_default_cursor_shape, Control.CURSOR_ARROW, "cursor removed -> default")
	h.check(not UssValues.parse_cursor("pointer")["ok"], "CSS pointer is not a Unity keyword")
	_unload(doc)


func test_all_initial_runtime() -> void:
	var doc := _load()
	await h.process_frame
	var r := doc.get_element("reset") as UxmlBox
	h.check(r.box_style == null, "all: initial drops the background")
	h.eq(r.modulate.a, 1.0, "all: initial drops opacity")
	h.check(not doc.get_computed_style("reset").has("width"), "all: initial drops width")
	_unload(doc)


# Transitions write animated values into the computed style; the applier
# paints them (opacity -> modulate, translate -> offset transform).
func test_transitioned_visual_values_paint() -> void:
	var src := '<ui:UXML xmlns:ui="UnityEngine.UIElements"><Style src="tr.uss" /><ui:VisualElement name="n" class="t" /></ui:UXML>'
	var uss := '.t { width: 10px; height: 10px; transition: opacity 1s linear, translate 1s linear; } .t.on { opacity: 0; translate: 100px 0px; }'
	for pair in [["user://visual_tr.uxml", src], ["user://tr.uss", uss]]:
		var f := FileAccess.open(pair[0], FileAccess.WRITE)
		f.store_string(pair[1])
		f.close()
	var doc := UxmlDocument.new()
	doc.transitions_manual = true
	h.root.add_child(doc)
	doc.size = Vector2(100, 100)
	doc.load_document("user://visual_tr.uxml", "user://")
	await h.process_frame
	doc.set_class("n", "t on")
	doc._restyle_now()
	doc.advance_transitions(0.5)
	var n := doc.get_element("n")
	h.check(absf(n.modulate.a - 0.5) < 0.05, "opacity mid-transition painted (%s)" % n.modulate.a)
	h.check(absf(n.offset_transform_position.x - 50.0) < 5.0,
		"translate mid-transition painted (%s)" % n.offset_transform_position)
	doc.advance_transitions(1.0)
	h.check(n.modulate.a < 0.01, "opacity reaches its end value")
	_unload(doc)
