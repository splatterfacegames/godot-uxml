class_name UxmlStyleApplier
extends RefCounted
## Applies one element's computed USS style to its native control.
##
## Appearance goes through real theme overrides — a Button gets its computed
## background as a StyleBoxFlat on the normal/hover/pressed/focus/disabled
## slots, so the native control keeps painting and behaving like a Button.
## Because the document re-resolves the cascade on every pseudo-state
## change, the style handed in already reflects hover/focus/disabled, and it
## is written to ALL state slots; native slots only need to exist so the
## right one is picked for the current state. A property that disappears
## from the computed style gets its override removed, so leaving a state
## restores the base look exactly.
##
## Not-appearance duties handled here too:
##   display:none / visibility:hidden -> control hidden, input ignored
##   disabled (document-computed, incl. ancestors) -> native disabled flags
##   focus/mouse filters restored from the factory-recorded defaults
##
## Resource references (background-image, -unity-font) resolve through the
## project-root resolver relative to the stylesheet the winning declaration
## came from — including inline styles (the UXML path) and inherited values
## (the sheet that declared them on the ancestor).

var _resolver: UxmlResourceResolver
var _uxml_path: String
var _source: String
var _warnings: Array
var _warned: Dictionary = {}
# resolved path -> Resource or null (attempted and failed): repeated
# restyles must not re-hit the filesystem for the same reference, missing
# or not.
var _tex_cache: Dictionary = {}
var _font_cache: Dictionary = {}


func _init(
	resolver: UxmlResourceResolver,
	uxml_path: String,
	source: String,
	warnings: Array
) -> void:
	_resolver = resolver
	_uxml_path = uxml_path
	_source = source
	_warnings = warnings


## Apply `style` (computed {prop: {value, origin}}) to `control`.
## `native` is the innermost interactive control (== control when unwrapped).
## `disabled`/`gone` are document-computed effective states: attribute or
## runtime state, inherited from ancestors (display:none on an ancestor
## makes the whole subtree inert even though display itself is not
## inherited in the cascade).
func apply(
	el: UxmlElement,
	control: Control,
	native: Control,
	style: Dictionary,
	disabled: bool,
	gone_ancestor: bool = false
) -> void:
	# Snapshot the unstyled theme font BEFORE any override can exist.
	# get_theme_font() returns the current override once one is set, so a
	# lazy capture inside _font() would freeze a previously applied url()
	# font as the "base" and every later bold variation would nest on it.
	_capture_base_font(control)
	if native != control:
		_capture_base_font(native)
	if control is UxmlField:
		_capture_base_font(control.caption_node())
	var display := _str(style, "display")
	var visibility := _str(style, "visibility")
	var gone := display == "none" or gone_ancestor
	var hidden := (
		visibility == "hidden" or visibility == "collapse"
	)
	if not visibility.is_empty() and visibility != "visible" and not hidden:
		_warn(el, "visibility", 'visibility: "%s" is not supported; visible used' % visibility)
	if not display.is_empty() and display != "flex" and not gone:
		_warn(el, "display", 'display: "%s" is not supported; flex used' % display)

	control.visible = not (gone or hidden)
	if gone:
		control.mouse_filter = Control.MOUSE_FILTER_IGNORE
		control.focus_mode = Control.FOCUS_NONE
		if native != control:
			native.mouse_filter = Control.MOUSE_FILTER_IGNORE
			native.focus_mode = Control.FOCUS_NONE
		_set_disabled(native, true)
		return

	if hidden:
		control.mouse_filter = Control.MOUSE_FILTER_IGNORE
		control.focus_mode = Control.FOCUS_NONE
		if native != control:
			native.mouse_filter = Control.MOUSE_FILTER_IGNORE
			native.focus_mode = Control.FOCUS_NONE
	else:
		control.mouse_filter = int(control.get_meta("uxml_mouse", Control.MOUSE_FILTER_STOP))
		control.focus_mode = int(control.get_meta("uxml_focus", control.focus_mode))
		if native != control:
			native.mouse_filter = int(native.get_meta("uxml_mouse", Control.MOUSE_FILTER_STOP))

	_set_disabled(native, disabled)
	if disabled:
		control.focus_mode = Control.FOCUS_NONE
		if native != control:
			native.focus_mode = Control.FOCUS_NONE
	elif not hidden:
		native.focus_mode = int(native.get_meta("uxml_focus", native.focus_mode))

	if control is UxmlField:
		# The wrapper owns the element's background; the inner native gets
		# text styling only, so a Slider/TextField background paints the
		# whole field box instead of doubling up inside it.
		_apply_box(control, el, style)
		_apply_caption(control, style, el)
		_apply_themed(native, style, el, false)
	elif control is UxmlBox:
		_apply_box(control, el, style)
	else:
		_apply_themed(native, style, el, true)


# ---------------------------------------------------------------------------
# Themed controls
# ---------------------------------------------------------------------------

func _stylebox_slots(c: Control) -> Array:
	if c is CheckBox:
		return ["normal", "hover", "pressed", "disabled", "focus"]
	if c is OptionButton:
		return ["normal", "hover", "pressed", "disabled", "focus"]
	if c is Button:
		return ["normal", "hover", "pressed", "disabled", "focus"]
	if c is LineEdit:
		return ["normal", "focus", "read_only"]
	if c is TextEdit:
		return ["normal", "focus", "read_only"]
	if c is Label:
		return ["normal"]
	if c is Slider:
		return ["slider"]
	return []


func _font_color_names(c: Control) -> Array:
	if c is CheckBox or c is OptionButton or c is Button:
		return [
			"font_color", "font_hover_color", "font_pressed_color",
			"font_focus_color", "font_disabled_color",
		]
	if c is LineEdit:
		return ["font_color", "font_placeholder_color"]
	if c is TextEdit:
		return ["font_color"]
	if c is Label:
		return ["font_color"]
	return []


func _apply_themed(c: Control, style: Dictionary, el: UxmlElement, include_skin: bool) -> void:
	if include_skin:
		var sb := _stylebox(style, el)
		var tex := _texture(style, "background-image", el)
		if sb == null and tex != null:
			sb = _texture_stylebox(tex, style, el)
			# USS slicing never pads content: StyleBoxTexture would otherwise
			# fall back to its texture margins as content margins.
			for side in ["left", "top", "right", "bottom"]:
				sb.set("content_margin_" + side, 0.0)
		elif sb != null and tex != null:
			# StyleBoxFlat cannot carry a texture; the image wins the fill.
			# Padding (content margins) carries over to the texture box; only
			# a visible flat background or border is lost, and diagnosed.
			var flat := sb as StyleBoxFlat
			if flat != null and (flat.bg_color.a > 0.0 or flat.border_width_left > 0
					or flat.border_width_top > 0 or flat.border_width_right > 0
					or flat.border_width_bottom > 0):
				_warn_once_key(
					"bg-image-plus-border", el,
					"background-image combined with border/background styling: the image is drawn, border styling is not"
				)
			var tsb := _texture_stylebox(tex, style, el)
			for side in ["left", "top", "right", "bottom"]:
				tsb.set("content_margin_" + side, sb.get("content_margin_" + side))
			if sb.has_meta("uxml_margins"):
				tsb.set_meta("uxml_margins", sb.get_meta("uxml_margins"))
			sb = tsb
		for slot in _stylebox_slots(c):
			if sb != null:
				c.add_theme_stylebox_override(slot, sb)
			else:
				c.remove_theme_stylebox_override(slot)

	var color := _color(style, "color", el)
	for name in _font_color_names(c):
		if color != null:
			c.add_theme_color_override(name, color)
		elif c.has_theme_color_override(name):
			c.remove_theme_color_override(name)

	var font_size := _int(style, "font-size", el)
	if font_size > 0:
		c.add_theme_font_size_override("font_size", font_size)
	elif c.has_theme_font_size_override("font_size"):
		c.remove_theme_font_size_override("font_size")

	var font := _font(c, style, el)
	if font != null:
		c.add_theme_font_override("font", font)
	elif c.has_theme_font_override("font"):
		c.remove_theme_font_override("font")

	_apply_text_layout(c, style, el)
	_apply_text_outline(c, style, el)


## USS text outline → Godot font outline. Unity's width is the outline
## thickness around each glyph; Godot's outline_size is the full stroke
## width centred on the glyph edge, so it is doubled.
func _apply_text_outline(c: Control, style: Dictionary, el: UxmlElement) -> void:
	if not (c is Label or c is Button or c is LineEdit):
		return
	var w := _float_px(style, "-unity-text-outline-width", el)
	var col = _color(style, "-unity-text-outline-color", el)
	if w > 0.0:
		c.add_theme_constant_override("outline_size", maxi(1, roundi(w * 2.0)))
		var oc: Color = col if col != null else Color.BLACK
		c.add_theme_color_override("font_outline_color", oc)
	else:
		if c.has_theme_constant_override("outline_size"):
			c.remove_theme_constant_override("outline_size")
		if c.has_theme_color_override("font_outline_color"):
			c.remove_theme_color_override("font_outline_color")


func _float_px(style: Dictionary, name: String, el: UxmlElement) -> float:
	var e = style.get(name)
	if e == null:
		return 0.0
	var n := UssValues.parse_number(String(e["value"]))
	if not is_nan(n):
		return n
	var p := UssValues.parse_length(String(e["value"]))
	if p["kind"] == "px":
		return float(p["value"])
	_warn(el, name, '%s: "%s" is not a length; ignored' % [name, e["value"]])
	return 0.0


## background-image as a StyleBoxTexture honouring -unity-slice-* (9-slice
## margins in source pixels) and -unity-background-image-tint-color.
## -unity-slice-scale other than 1 is diagnosed and treated as 1.
func _texture_stylebox(tex: Texture2D, style: Dictionary, el: UxmlElement) -> StyleBoxTexture:
	var st := StyleBoxTexture.new()
	st.texture = tex
	st.texture_margin_left = _float_px(style, "-unity-slice-left", el)
	st.texture_margin_right = _float_px(style, "-unity-slice-right", el)
	st.texture_margin_top = _float_px(style, "-unity-slice-top", el)
	st.texture_margin_bottom = _float_px(style, "-unity-slice-bottom", el)
	var scale_e = style.get("-unity-slice-scale")
	if scale_e != null:
		var s := _float_px(style, "-unity-slice-scale", el)
		if not is_equal_approx(s, 1.0):
			_warn(el, "-unity-slice-scale", "-unity-slice-scale: only 1 is supported; 1 used")
	var tint = _color(style, "-unity-background-image-tint-color", el)
	if tint != null:
		st.modulate_color = tint
	return st


func _has_slice_or_tint(style: Dictionary) -> bool:
	for k in ["-unity-slice-left", "-unity-slice-right", "-unity-slice-top",
			"-unity-slice-bottom", "-unity-background-image-tint-color"]:
		if style.has(k):
			return true
	return false


## Wrapped natives (inside UxmlField) still get the field's box painted on
## the wrapper, not on the inner control — so _apply_themed skips stylebox
## for them and the wrapper gets it. For sliders the groove slot is themed
## on the native control itself.
func _apply_box(box: UxmlBox, el: UxmlElement, style: Dictionary) -> void:
	box.box_style = _stylebox(style, el)
	var tex := _texture(style, "background-image", el)
	if tex != null and _has_slice_or_tint(style):
		box.box_texture_style = _texture_stylebox(tex, style, el)
		box.box_texture = null
	else:
		box.box_texture_style = null
		box.box_texture = tex


func _apply_caption(field: UxmlField, style: Dictionary, el: UxmlElement) -> void:
	var color := _color(style, "color", el)
	var font := _font(field.caption_node(), style, el)
	var font_size := _int(style, "font-size", el)
	field.apply_caption_style(
		font, font_size,
		color if color != null else Color.WHITE,
		color != null
	)
	_apply_text_outline(field.caption_node(), style, el)


# ---------------------------------------------------------------------------
# Value interpretation
# ---------------------------------------------------------------------------

func _str(style: Dictionary, name: String) -> String:
	var e = style.get(name)
	return "" if e == null else String(e["value"])


func _color(style: Dictionary, name: String, el: UxmlElement) -> Variant:
	var e = style.get(name)
	if e == null:
		return null
	var r := UssValues.parse_color(String(e["value"]))
	if not r["ok"]:
		_warn(el, name, "%s: %s" % [name, r["problem"]])
		return null
	return r["color"]


func _int(style: Dictionary, name: String, el: UxmlElement) -> int:
	var e = style.get(name)
	if e == null:
		return 0
	var n := UssValues.parse_number(String(e["value"]))
	if is_nan(n):
		var p := UssValues.parse_length(String(e["value"]))
		if p["kind"] == "px":
			return int(p["value"])
		_warn(el, name, '%s: "%s" is not a size; ignored' % [name, e["value"]])
		return 0
	return int(n)


## The file a winning declaration came from: the stylesheet for rules, the
## UXML for inline styles, and for inherited values the sheet the ancestor's
## declaration came from. Relative url()s resolve against this.
func _origin_file(entry: Dictionary) -> String:
	return _origin_dir(entry.get("origin", {}))


## Walks the origin chain itself — {kind: "rule", file} is a stylesheet,
## {kind: "inherited", origin} wraps the origin the ancestor's declaration
## carried (nested per inheritance hop), anything else (inline, missing)
## means the UXML file.
func _origin_dir(origin: Dictionary) -> String:
	match String(origin.get("kind", "")):
		"rule":
			var f := String(origin.get("file", ""))
			return f if not f.is_empty() else _uxml_path
		"inherited":
			return _origin_dir(origin.get("origin", {}))
		_:
			return _uxml_path


func _texture(style: Dictionary, name: String, el: UxmlElement) -> Texture2D:
	var e = style.get(name)
	if e == null:
		return null
	var u := UssValues.parse_url(String(e["value"]))
	if not u["ok"]:
		_warn(el, name, "%s: %s" % [name, u["problem"]])
		return null
	var r := _resolver.resolve(u["path"], _origin_file(e))
	if not r["ok"]:
		_report_resolver(r, el, '%s "%s"' % [name, e["value"]])
		return null
	var path: String = r["path"]
	if _tex_cache.has(path):
		return _tex_cache[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		var res := ResourceLoader.load(path)
		if res is Texture2D:
			tex = res
	elif FileAccess.file_exists(path):
		# Not an imported resource — try the raw image loader only when the
		# file is really there; a bare Image.load on a missing path prints a
		# generic engine ERROR we cannot attribute to the element.
		var img := Image.new()
		if img.load(path) == OK:
			tex = ImageTexture.create_from_image(img)
	_tex_cache[path] = tex
	if tex == null:
		_warn_diag(
			"missing-file", "texture:%s:%s" % [path, el.get_instance_id()], el,
			'%s "%s" resolved to %s but is not a readable image' % [name, e["value"], path]
		)
	return tex


## Records the control's pre-override theme font once, at apply() entry —
## guaranteed to run before the first add_theme_font_override, which a
## capture inside _font() could not promise. (A flag meta rather than the
## font key itself: set_meta(key, null) removes keys, so a null theme font
## would look unrecorded forever.)
func _capture_base_font(c: Control) -> void:
	if c == null or c.has_meta("uxml_base_font_set"):
		return
	c.set_meta("uxml_base_font_set", true)
	c.set_meta("uxml_base_font", c.get_theme_font("font"))


func _font(c: Control, style: Dictionary, el: UxmlElement) -> Font:
	var path := ""
	for prop in ["-unity-font", "-unity-font-definition"]:
		var e = style.get(prop)
		if e == null:
			continue
		var raw := String(e["value"])
		if raw == "initial" or raw == "inherit" or raw.is_empty():
			continue
		var u := UssValues.parse_url(raw)
		if u["ok"]:
			path = u["path"]
			var rr := _resolver.resolve(path, _origin_file(e))
			if not rr["ok"]:
				_report_resolver(rr, el, '%s "%s"' % [prop, raw])
				path = ""
			else:
				path = rr["path"]
		else:
			# Font family names (not file references) are diagnosed once.
			_warn(el, prop, '%s: "%s" is a font name, not a file; named families are not supported, use url()' % [prop, raw])
	var font: Font = null
	if not path.is_empty():
		font = _load_font(path, el)

	var font_style := _str(style, "-unity-font-style")
	if font_style.is_empty() or font_style == "normal" or font_style == "initial":
		return font
	if not ["bold", "italic", "bold-and-italic"].has(font_style):
		_warn(el, "-unity-font-style", '-unity-font-style: "%s" is not supported' % font_style)
		return font
	var fv := FontVariation.new()
	if font != null:
		fv.base_font = font
	else:
		# Captured by apply() before any override could land — the real
		# theme font, never a previous url() font or FontVariation.
		_capture_base_font(c)
		fv.base_font = c.get_meta("uxml_base_font", null)
	if font_style == "bold" or font_style == "bold-and-italic":
		fv.variation_embolden = 0.6
	if font_style == "italic" or font_style == "bold-and-italic":
		var t := Transform2D()
		t.x = Vector2(1.0, 0.0)
		t.y = Vector2(0.2, 1.0)
		fv.variation_transform = t
	return fv


func _load_font(path: String, el: UxmlElement) -> Font:
	if _font_cache.has(path):
		return _font_cache[path]
	var font: Font = null
	if ResourceLoader.exists(path):
		var res := ResourceLoader.load(path)
		if res is Font:
			font = res
	elif FileAccess.file_exists(path):
		# Same gate as textures: never hand a missing path to the engine
		# loader — its generic ERROR line cannot be tied back to the style.
		var ff := FontFile.new()
		if ff.load_dynamic_font(path) == OK:
			font = ff
	_font_cache[path] = font
	if font == null:
		_warn_diag(
			"missing-file", "font:%s:%s" % [path, el.get_instance_id()], el,
			'font "%s" resolved to %s but is not a readable font' % [path, path]
		)
	return font


## background/border/radius -> a StyleBox. background-image becomes a
## StyleBoxTexture for themed controls (UxmlBox paints it separately as
## box_texture); mixed per-side border colors collapse to the top side's —
## StyleBoxFlat has a single border color, the difference is diagnosed.
func _stylebox(style: Dictionary, el: UxmlElement) -> StyleBox:
	var bg := _color(style, "background-color", el)
	var widths := {}
	var any_border := false
	for side in ["top", "right", "bottom", "left"]:
		var e = style.get("border-%s-width" % side)
		var w := 0.0
		if e != null:
			var p := UssValues.parse_length(String(e["value"]))
			if p["kind"] == "px":
				w = maxf(0.0, p["value"])
			elif p["kind"] == "invalid":
				_warn(el, "border-width", "border-%s-width: %s" % [side, p["problem"]])
			else:
				_warn(el, "border-width", "border-%s-width: only px is supported" % side)
		widths[side] = w
		any_border = any_border or w > 0.0
	var bcolors := {}
	var any_bcolor := false
	var first_bcolor: Variant = null
	for side in ["top", "right", "bottom", "left"]:
		var c := _color(style, "border-%s-color" % side, el)
		bcolors[side] = c
		if c != null:
			any_bcolor = true
			if first_bcolor == null:
				first_bcolor = c
			elif c != first_bcolor:
				_warn_once_key(
					"border-color-mixed", el,
					"per-side border colors differ; StyleBoxFlat supports one border color — the first is used"
				)
	var radii := {}
	var any_radius := false
	for corner in ["top-left", "top-right", "bottom-right", "bottom-left"]:
		var e = style.get("border-%s-radius" % corner)
		var v := 0.0
		if e != null:
			var p := UssValues.parse_length(String(e["value"]))
			if p["kind"] == "px":
				v = maxf(0.0, p["value"])
			elif p["kind"] == "invalid":
				_warn(el, "border-radius", "border-%s-radius: %s" % [corner, p["problem"]])
			else:
				_warn(el, "border-radius", "border-%s-radius: only px is supported" % corner)
		radii[corner] = v
		any_radius = any_radius or v > 0.0

	# Authored padding insets the native content (a Label/Button's text) via
	# the stylebox's content margins — which override the automatic
	# border-width margin, so they carry border + padding together.
	# Percentages resolve in the flex pass against the containing block:
	# the px estimate here is corrected post-layout by
	# apply_resolved_insets() so painted text matches the reserved box.
	var pads := {}
	var any_pad := false
	for side in ["top", "right", "bottom", "left"]:
		var e = style.get("padding-%s" % side)
		var pad := 0.0
		if e != null:
			var p := UssValues.parse_length(String(e["value"]))
			if p["kind"] == "px":
				pad = maxf(0.0, p["value"])
			elif p["kind"] == "percent":
				any_pad = true
		pads[side] = pad
		any_pad = any_pad or pad > 0.0

	var has_visual := (
		bg != null or any_border or any_bcolor or any_radius or any_pad
	)
	if not has_visual:
		return null

	var sb := StyleBoxFlat.new()
	sb.bg_color = bg if bg != null else Color.TRANSPARENT
	sb.border_color = first_bcolor if first_bcolor != null else Color.BLACK
	for side in ["top", "right", "bottom", "left"]:
		sb.set("border_width_%s" % side, int(widths[side]))
		sb.set("content_margin_%s" % side, float(widths[side]) + pads[side])
	# The margins inflate get_combined_minimum_size() — record what USS put
	# there so the layout's intrinsic measurer can subtract them and the
	# flex insets are not counted twice.
	sb.set_meta("uxml_margins", [
		float(widths["left"]) + pads["left"],
		float(widths["top"]) + pads["top"],
		float(widths["right"]) + pads["right"],
		float(widths["bottom"]) + pads["bottom"],
	])
	for corner in ["top_left", "top_right", "bottom_right", "bottom_left"]:
		sb.set("corner_radius_%s" % corner, int(radii[
			{"top_left": "top-left", "top_right": "top-right",
			 "bottom_right": "bottom-right", "bottom_left": "bottom-left"}[corner]
		]))
	sb.draw_center = bg != null
	return sb


## Post-layout correction: the flex pass has resolved percentage padding
## and border into real px insets — copy them onto the stylebox's content
## margins so native text (Label/Button/…) sits in the same content box
## the layout reserved. Called once per element after every layout, so it
## also tracks resizes. The uxml_margins meta is updated in lockstep so
## the measure path keeps subtracting exactly what the stylebox adds.
func apply_resolved_insets(c: Control, start: Vector2, end: Vector2) -> void:
	var seen := {}
	for slot in [
		"normal", "hover", "pressed", "disabled", "focus", "read_only", "slider"
	]:
		if not c.has_theme_stylebox_override(slot):
			continue
		var sb := c.get_theme_stylebox(slot)
		if sb == null or seen.has(sb):
			continue
		seen[sb] = true
		# content_margin_* is a StyleBox BASE-class property — it insets
		# native content for flat AND texture styleboxes. texture_margin_*
		# is nine-patch source slicing and is deliberately left alone.
		sb.content_margin_left = start.x
		sb.content_margin_top = start.y
		sb.content_margin_right = end.x
		sb.content_margin_bottom = end.y
		# Recorded unconditionally so the measure path subtracts exactly
		# what the stylebox adds — texture styleboxes count too.
		sb.set_meta("uxml_margins", [start.x, start.y, end.x, end.y])


## Records the control's pre-USS text defaults once, so a restyle that no
## longer carries -unity-text-align/white-space restores them instead of
## leaving the state styling stuck on the control.
func _remember_text_defaults(c: Control) -> void:
	if c.has_meta("uxml_text_defaults"):
		return
	c.set_meta("uxml_text_defaults", true)
	if c is Label:
		c.set_meta("uxml_halign", c.horizontal_alignment)
		c.set_meta("uxml_valign", c.vertical_alignment)
		c.set_meta("uxml_autowrap", c.autowrap_mode)
	elif c is Button and not c is OptionButton:
		# OptionButton is a Button but has no `alignment` property.
		c.set_meta("uxml_halign", c.alignment)
	elif c is LineEdit:
		c.set_meta("uxml_halign", c.alignment)


func _apply_text_layout(c: Control, style: Dictionary, el: UxmlElement) -> void:
	_remember_text_defaults(c)
	var align := _str(style, "-unity-text-align")
	var hv := Vector2i(-1, -1)
	if not align.is_empty():
		hv = _parse_text_align(align, el)
	var has_align := hv.x >= 0
	if c is Label:
		c.horizontal_alignment = hv.x if has_align else int(c.get_meta("uxml_halign", 0))
		c.vertical_alignment = hv.y if has_align else int(c.get_meta("uxml_valign", 0))
	elif c is Button and not c is OptionButton:
		c.alignment = hv.x if has_align else int(c.get_meta("uxml_halign", 0))
	elif c is LineEdit:
		c.alignment = hv.x if has_align else int(c.get_meta("uxml_halign", 0))
	if c is Label:
		var ws := _str(style, "white-space")
		match ws:
			"normal":
				c.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			"nowrap":
				c.autowrap_mode = TextServer.AUTOWRAP_OFF
			"":
				c.autowrap_mode = int(c.get_meta("uxml_autowrap", 0))
			_:
				_warn(el, "white-space", 'white-space: "%s" is not supported' % ws)


func _parse_text_align(v: String, el: UxmlElement) -> Vector2i:
	match v:
		"upper-left": return Vector2i(0, 0)
		"upper-center": return Vector2i(1, 0)
		"upper-right": return Vector2i(2, 0)
		"middle-left": return Vector2i(0, 1)
		"middle-center": return Vector2i(1, 1)
		"middle-right": return Vector2i(2, 1)
		"lower-left": return Vector2i(0, 2)
		"lower-center": return Vector2i(1, 2)
		"lower-right": return Vector2i(2, 2)
		_:
			_warn(el, "-unity-text-align", '-unity-text-align: "%s" is not supported' % v)
			return Vector2i(-1, -1)


func _set_disabled(native: Control, on: bool) -> void:
	if native is LineEdit or native is TextEdit:
		# Disabled forces non-editable; clearing it restores the AUTHORED
		# editable state (recorded by the factory) so a readonly field stays
		# readonly through load, restyles and disable/re-enable.
		if on:
			native.editable = false
		else:
			native.editable = bool(native.get_meta("uxml_editable", true))
	elif native is Range:
		native.editable = not on
	elif native is BaseButton:
		native.disabled = on


func _report_resolver(res: Dictionary, el: UxmlElement, what: String) -> void:
	var d: Dictionary = res["diagnostic"]
	_warn_diag(
		d.get("kind", "missing-file"),
		"resolver:%s:%s:%s" % [what, d.get("message", ""), el.get_instance_id()], el,
		"%s could not be resolved: %s" % [what, d.get("message", "")]
	)


## The one door every diagnostic goes through: `key` dedupes for the
## applier's whole lifetime (one per document load), `kind` is preserved so
## missing-file/path-outside-root keep their identity, and the element's
## own source position is always attached.
func _warn_diag(kind: String, key: String, el: UxmlElement, message: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	_warnings.append(UxmlDiagnostic.make(
		kind, message, _source, el.open_tag_start, _uxml_path
	))


func _warn(el: UxmlElement, prop: String, message: String) -> void:
	_warn_diag(
		"unsupported-value",
		"%s:%s:%s" % [prop, message, el.get_instance_id()], el, message
	)


func _warn_once_key(key: String, el: UxmlElement, message: String) -> void:
	_warn_diag("unsupported-value", "%s:%s" % [key, el.get_instance_id()], el, message)
