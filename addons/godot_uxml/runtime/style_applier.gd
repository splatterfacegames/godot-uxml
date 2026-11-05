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

## Batch each control's theme-override writes into one theme-changed
## notification (begin/end_bulk_theme_override). ~3x faster applies. Only
## observable difference vs. per-override notifications: right after a load
## the first layout already sees settled minimum sizes, where per-override
## notification left some stale until the next restyle. Set false for exact
## first-frame parity with the pre-optimization runtime.
const BULK_THEME_OVERRIDES := true

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
## Last insets apply_resolved_insets wrote per control; cleared whenever
## _apply_themed swaps the control's styleboxes. A repeat call with the same
## insets on the same styleboxes is a no-op and is skipped.
var _inset_memo: Dictionary = {}
## Fresh-stylebox content margins per themed control ([l, t, r, b], or null
## when the fresh stylebox does not carry the px estimate — texture boxes).
var _estimate: Dictionary = {}
## Controls whose freshly applied stylebox margins differ from the resolved
## layout insets (percentage padding, texture styleboxes): re-applying them
## changes what the next measure sees, so the document keeps re-applying and
## re-laying them out on every restyle exactly as a full restyle would.
var drifting: Dictionary = {}
## Label/Button controls whose text Unity would elide (text-overflow:
## ellipsis with overflow: hidden and no wrapping) -> overflow position
## ("start" | "middle" | "end"). The document runs update_elision() after
## every layout and paint-only restyle.
var elide: Dictionary = {}
## Controls whose overflow clip uses the content box: their UxmlClip inset
## follows the resolved insets in apply_resolved_insets.
var _clip_content: Dictionary = {}
## Cached FontVariations for letter/word spacing, keyed by base font,
## style and spacing (spacing is rare; reusing them keeps restyles cheap).
var _fv_cache: Dictionary = {}
## How many controls carry clip_text for overflow: hidden text. While zero
## the measurers skip the clip-text check entirely.
var clip_texts := 0

## The shape a texture cursor takes over while its element is hovered:
## Input.set_custom_mouse_cursor replaces one shape's image globally.
const TEXTURE_CURSOR_SHAPE := Control.CURSOR_HELP
const _TEXTURE_CURSOR_INPUT := Input.CURSOR_HELP


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
	_apply_visual(el, control, native, style)


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
	if c is Label or c is RichTextLabel:
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
	if c is RichTextLabel:
		return ["default_color"]
	return []


## The font / font size theme items a control draws its text with.
static func _font_name(c: Control) -> StringName:
	return &"normal_font" if c is RichTextLabel else &"font"


static func _font_size_name(c: Control) -> StringName:
	return &"normal_font_size" if c is RichTextLabel else &"font_size"


func _apply_themed(c: Control, style: Dictionary, el: UxmlElement, include_skin: bool) -> void:
	# All override writes for this control land as ONE theme-changed
	# notification instead of one per slot/color (10+ for a Button).
	if BULK_THEME_OVERRIDES:
		c.begin_bulk_theme_override()
		_apply_themed_inner(c, style, el, include_skin)
		c.end_bulk_theme_override()
	else:
		_apply_themed_inner(c, style, el, include_skin)


func _apply_themed_inner(c: Control, style: Dictionary, el: UxmlElement, include_skin: bool) -> void:
	if include_skin:
		var sb := _stylebox(style, el)
		var tex := _texture(style, "background-image", el)
		if sb == null and tex != null:
			sb = _image_stylebox(tex, style, el)
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
			var tsb := _image_stylebox(tex, style, el)
			for side in ["left", "top", "right", "bottom"]:
				tsb.set("content_margin_" + side, sb.get("content_margin_" + side))
			if sb.has_meta("uxml_margins"):
				tsb.set_meta("uxml_margins", sb.get_meta("uxml_margins"))
			sb = tsb
		var slots := _stylebox_slots(c)
		for slot in slots:
			if sb != null:
				c.add_theme_stylebox_override(slot, sb)
			else:
				c.remove_theme_stylebox_override(slot)
		_inset_memo.erase(c)
		if sb != null and not slots.is_empty():
			_estimate[c] = sb.get_meta("uxml_margins") if sb.has_meta("uxml_margins") else null
		else:
			_estimate.erase(c)
			drifting.erase(c)

	var color := _color(style, "color", el)
	for name in _font_color_names(c):
		if color != null:
			c.add_theme_color_override(name, color)
		elif c.has_theme_color_override(name):
			c.remove_theme_color_override(name)

	var size_name := _font_size_name(c)
	var font_size := _int(style, "font-size", el)
	if font_size > 0:
		c.add_theme_font_size_override(size_name, font_size)
	elif c.has_theme_font_size_override(size_name):
		c.remove_theme_font_size_override(size_name)

	var font_name := _font_name(c)
	var font := _font(c, style, el)
	if font != null:
		c.add_theme_font_override(font_name, font)
	elif c.has_theme_font_override(font_name):
		c.remove_theme_font_override(font_name)

	_apply_text_layout(c, style, el)
	_apply_text_outline(c, style, el)
	if _gate(c, style, _TEXT_FX_KEYS, &"uxml_textfx"):
		_apply_text_shadow(c, style, el)
		_apply_elision(c, style, el)
		if c is Label or c is RichTextLabel:
			# Last: LabelSettings must copy every text override set above.
			_apply_paragraph_spacing(c, style, el)
	if c is RichTextLabel:
		_render_rich(c)


## USS text outline → Godot font outline. Unity's width is the outline
## thickness around each glyph; Godot's outline_size is the full stroke
## width centred on the glyph edge, so it is doubled.
func _apply_text_outline(c: Control, style: Dictionary, el: UxmlElement) -> void:
	if not (c is Label or c is Button or c is LineEdit or c is RichTextLabel):
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
## Used when -unity-slice-scale is 1 and no placement property is set;
## UxmlBackgroundStyle draws every other case.
func _texture_stylebox(tex: Texture2D, style: Dictionary, el: UxmlElement) -> StyleBoxTexture:
	var st := StyleBoxTexture.new()
	st.texture = tex
	st.texture_margin_left = _float_px(style, "-unity-slice-left", el)
	st.texture_margin_right = _float_px(style, "-unity-slice-right", el)
	st.texture_margin_top = _float_px(style, "-unity-slice-top", el)
	st.texture_margin_bottom = _float_px(style, "-unity-slice-bottom", el)
	var tint = _color(style, "-unity-background-image-tint-color", el)
	if tint != null:
		st.modulate_color = tint
	return st


## Properties that place a background image beyond a plain stretch or
## 9-slice. When none is present the image keeps the StyleBoxTexture /
## box_texture path, exactly as before these properties existed.
const _BG_PLACEMENT := [
	"background-position-x", "background-position-y", "background-repeat",
	"background-size", "-unity-slice-type",
]


func _needs_placement(style: Dictionary) -> bool:
	for k in _BG_PLACEMENT:
		if style.has(k):
			return true
	var e = style.get("-unity-slice-scale")
	if e != null:
		var n := _slice_scale(style, null)
		return not is_equal_approx(n, 1.0)
	return false


func _slice_scale(style: Dictionary, el) -> float:
	var e = style.get("-unity-slice-scale")
	if e == null:
		return 1.0
	var raw := String(e["value"])
	var n := UssValues.parse_number(raw)
	if is_nan(n):
		var p := UssValues.parse_length(raw)
		if p["kind"] == "px":
			n = float(p["value"])
		else:
			if el != null:
				_warn(el, "-unity-slice-scale", '-unity-slice-scale: "%s" is not a length; 1 used' % raw)
			return 1.0
	return n


## background-image for a stylebox slot or a UxmlBox: the StyleBoxTexture
## path, or UxmlBackgroundStyle when a placement property is present.
func _image_stylebox(tex: Texture2D, style: Dictionary, el: UxmlElement) -> StyleBox:
	if not _needs_placement(style):
		return _texture_stylebox(tex, style, el)
	var bs := UxmlBackgroundStyle.new()
	bs.texture = tex
	bs.slices = PackedInt32Array([
		roundi(_float_px(style, "-unity-slice-left", el)),
		roundi(_float_px(style, "-unity-slice-top", el)),
		roundi(_float_px(style, "-unity-slice-right", el)),
		roundi(_float_px(style, "-unity-slice-bottom", el)),
	])
	bs.slice_scale = _slice_scale(style, el)
	var stype := _str(style, "-unity-slice-type")
	if not stype.is_empty() and stype != "sliced" and stype != "tiled":
		_warn(el, "-unity-slice-type", '-unity-slice-type: "%s" is not sliced or tiled; sliced used' % stype)
	bs.slice_tiled = stype == "tiled"
	var tint = _color(style, "-unity-background-image-tint-color", el)
	if tint != null:
		bs.tint = tint
	for pair in [["background-position-x", false], ["background-position-y", true]]:
		var e = style.get(pair[0])
		if e == null:
			continue
		var r := UssValues.parse_background_position(String(e["value"]), pair[1])
		if not r["ok"]:
			_warn(el, pair[0], r["problem"])
			continue
		var spec := [r["keyword"], r["unit"], r["value"]]
		if pair[1]:
			bs.pos_y = spec
		else:
			bs.pos_x = spec
	var re = style.get("background-repeat")
	if re != null:
		var rr := UssValues.parse_background_repeat(String(re["value"]))
		if rr["ok"]:
			bs.repeat_x = rr["x"]
			bs.repeat_y = rr["y"]
		else:
			_warn(el, "background-repeat", rr["problem"])
	var se = style.get("background-size")
	if se != null:
		var sr := UssValues.parse_background_size(String(se["value"]))
		if sr["ok"]:
			bs.size_type = sr["type"]
			bs.size_x = sr["x"]
			bs.size_y = sr["y"]
		else:
			_warn(el, "background-size", sr["problem"])
	return bs


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
	if tex != null and _needs_placement(style):
		box.box_texture_style = _image_stylebox(tex, style, el)
		box.box_texture = null
	elif tex != null and _has_slice_or_tint(style):
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
	if _gate(field.caption_node(), style, _TEXT_FX_KEYS, &"uxml_textfx"):
		_apply_text_shadow(field.caption_node(), style, el)


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
	return _texture_ref(String(e["value"]), e, name, el)


## Load the url() `ref` written in style entry `e` (for diagnostics and the
## origin file relative references resolve against).
func _texture_ref(ref: String, e: Dictionary, name: String, el: UxmlElement) -> Texture2D:
	var u := UssValues.parse_url(ref)
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
	c.set_meta("uxml_base_font", c.get_theme_font(_font_name(c)))


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

	if style.has("letter-spacing") or style.has("word-spacing"):
		var spaced = _spaced_font(c, font, style, el)
		if spaced != null:
			return spaced

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


## letter-spacing / word-spacing as a FontVariation over the element's font
## (with its -unity-font-style). Unity's text generator reads both lengths
## in em/100 units; FontVariation spacing is whole pixels, so the extra
## advance is rounded. Null when both round to zero.
func _spaced_font(c: Control, font: Font, style: Dictionary, el: UxmlElement) -> Variant:
	var fs := float(_effective_font_size(c, style, el))
	var glyph := _spacing_int(style, "letter-spacing", fs, el)
	var space := _spacing_int(style, "word-spacing", fs, el)
	if glyph == 0 and space == 0:
		return null
	var font_style := _str(style, "-unity-font-style")
	if not ["bold", "italic", "bold-and-italic"].has(font_style):
		if not (font_style.is_empty() or font_style == "normal" or font_style == "initial"):
			_warn(el, "-unity-font-style", '-unity-font-style: "%s" is not supported' % font_style)
		font_style = ""
	var base: Font = font
	if base == null:
		_capture_base_font(c)
		base = c.get_meta("uxml_base_font", null)
	var key := "%d|%s|%d|%d" % [0 if base == null else base.get_instance_id(), font_style, glyph, space]
	var hit = _fv_cache.get(key)
	if hit != null:
		return hit
	var fv := FontVariation.new()
	fv.base_font = base
	if font_style == "bold" or font_style == "bold-and-italic":
		fv.variation_embolden = 0.6
	if font_style == "italic" or font_style == "bold-and-italic":
		var t := Transform2D()
		t.x = Vector2(1.0, 0.0)
		t.y = Vector2(0.2, 1.0)
		fv.variation_transform = t
	fv.spacing_glyph = glyph
	fv.spacing_space = space
	_fv_cache[key] = fv
	return fv


## font-size in px as the control will draw it: the USS value, else the
## control's theme size.
func _effective_font_size(c: Control, style: Dictionary, el: UxmlElement) -> int:
	if style.has("font-size"):
		var n := _int(style, "font-size", el)
		if n > 0:
			return n
	return c.get_theme_font_size(_font_size_name(c))


## A Unity text spacing property in whole px at font size `fs`.
func _spacing_int(style: Dictionary, name: String, fs: float, el: UxmlElement) -> int:
	var e = style.get(name)
	if e == null:
		return 0
	var px := UssValues.spacing_px(String(e["value"]), fs)
	if is_nan(px):
		_warn(el, name, '%s: "%s" is not a px length; ignored' % [name, e["value"]])
		return 0
	return roundi(px)


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
const _SIDES := ["top", "right", "bottom", "left"]
const _CORNERS := ["top-left", "top-right", "bottom-right", "bottom-left"]
const _BW := ["border-top-width", "border-right-width", "border-bottom-width", "border-left-width"]
const _BC := ["border-top-color", "border-right-color", "border-bottom-color", "border-left-color"]
const _BR := [
	"border-top-left-radius", "border-top-right-radius",
	"border-bottom-right-radius", "border-bottom-left-radius",
]
const _PAD := ["padding-top", "padding-right", "padding-bottom", "padding-left"]


func _stylebox(style: Dictionary, el: UxmlElement) -> StyleBox:
	var bg := _color(style, "background-color", el)
	# Per-side values in [top, right, bottom, left] order; corners clockwise
	# from top-left. Diagnostics are emitted in the original order.
	var widths := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	var any_border := false
	for k in 4:
		var e = style.get(_BW[k])
		if e == null:
			continue
		var w := 0.0
		var p := UssValues.parse_length(String(e["value"]))
		if p["kind"] == "px":
			w = maxf(0.0, p["value"])
		elif p["kind"] == "invalid":
			_warn(el, "border-width", "border-%s-width: %s" % [_SIDES[k], p["problem"]])
		else:
			_warn(el, "border-width", "border-%s-width: only px is supported" % _SIDES[k])
		widths[k] = w
		any_border = any_border or w > 0.0
	var any_bcolor := false
	var first_bcolor: Variant = null
	for k in 4:
		if not style.has(_BC[k]):
			continue
		var c := _color(style, _BC[k], el)
		if c != null:
			any_bcolor = true
			if first_bcolor == null:
				first_bcolor = c
			elif c != first_bcolor:
				_warn_once_key(
					"border-color-mixed", el,
					"per-side border colors differ; StyleBoxFlat supports one border color — the first is used"
				)
	var radii := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	var any_radius := false
	for k in 4:
		var e = style.get(_BR[k])
		if e == null:
			continue
		var v := 0.0
		var p := UssValues.parse_length(String(e["value"]))
		if p["kind"] == "px":
			v = maxf(0.0, p["value"])
		elif p["kind"] == "invalid":
			_warn(el, "border-radius", "border-%s-radius: %s" % [_CORNERS[k], p["problem"]])
		else:
			_warn(el, "border-radius", "border-%s-radius: only px is supported" % _CORNERS[k])
		radii[k] = v
		any_radius = any_radius or v > 0.0

	# Authored padding insets the native content (a Label/Button's text) via
	# the stylebox's content margins — which override the automatic
	# border-width margin, so they carry border + padding together.
	# Percentages resolve in the flex pass against the containing block:
	# the px estimate here is corrected post-layout by
	# apply_resolved_insets() so painted text matches the reserved box.
	var pads := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	var any_pad := false
	for k in 4:
		var e = style.get(_PAD[k])
		if e == null:
			continue
		var p := UssValues.parse_length(String(e["value"]))
		if p["kind"] == "px":
			pads[k] = maxf(0.0, p["value"])
		elif p["kind"] == "percent":
			any_pad = true
		any_pad = any_pad or pads[k] > 0.0

	var has_visual := (
		bg != null or any_border or any_bcolor or any_radius or any_pad
	)
	if not has_visual:
		return null

	var sb := StyleBoxFlat.new()
	sb.bg_color = bg if bg != null else Color.TRANSPARENT
	sb.border_color = first_bcolor if first_bcolor != null else Color.BLACK
	sb.border_width_top = int(widths[0])
	sb.border_width_right = int(widths[1])
	sb.border_width_bottom = int(widths[2])
	sb.border_width_left = int(widths[3])
	sb.content_margin_top = widths[0] + pads[0]
	sb.content_margin_right = widths[1] + pads[1]
	sb.content_margin_bottom = widths[2] + pads[2]
	sb.content_margin_left = widths[3] + pads[3]
	# The margins inflate get_combined_minimum_size() — record what USS put
	# there so the layout's intrinsic measurer can subtract them and the
	# flex insets are not counted twice.
	sb.set_meta("uxml_margins", [
		widths[3] + pads[3],
		widths[0] + pads[0],
		widths[1] + pads[1],
		widths[2] + pads[2],
	])
	sb.corner_radius_top_left = int(radii[0])
	sb.corner_radius_top_right = int(radii[1])
	sb.corner_radius_bottom_right = int(radii[2])
	sb.corner_radius_bottom_left = int(radii[3])
	sb.draw_center = bg != null
	return sb


## Post-layout correction: the flex pass has resolved percentage padding
## and border into real px insets — copy them onto the stylebox's content
## margins so native text (Label/Button/…) sits in the same content box
## the layout reserved. Called once per element after every layout, so it
## also tracks resizes. The uxml_margins meta is updated in lockstep so
## the measure path keeps subtracting exactly what the stylebox adds.
func apply_resolved_insets(c: Control, start: Vector2, end: Vector2) -> void:
	var memo = _inset_memo.get(c)
	if memo != null and memo[0] == start and memo[1] == end:
		return
	_inset_memo[c] = [start, end]
	if _clip_content.has(c):
		var clip = (c.get_meta("uxml_clip") if c.has_meta("uxml_clip") else null)
		if clip != null:
			clip.set_inset(Vector4(start.x, start.y, end.x, end.y))
	if _estimate.has(c):
		var est = _estimate[c]
		if est == null or est != [start.x, start.y, end.x, end.y]:
			drifting[c] = true
		else:
			drifting.erase(c)
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
	if c is Label or c is RichTextLabel:
		c.set_meta("uxml_halign", c.horizontal_alignment)
		c.set_meta("uxml_valign", c.vertical_alignment)
		c.set_meta("uxml_autowrap", c.autowrap_mode)
		c.set_meta("uxml_trim", c.autowrap_trim_flags)
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
	if c is Label or c is RichTextLabel:
		c.horizontal_alignment = hv.x if has_align else int(c.get_meta("uxml_halign", 0))
		c.vertical_alignment = hv.y if has_align else int(c.get_meta("uxml_valign", 0))
	elif c is Button and not c is OptionButton:
		c.alignment = hv.x if has_align else int(c.get_meta("uxml_halign", 0))
	elif c is LineEdit:
		c.alignment = hv.x if has_align else int(c.get_meta("uxml_halign", 0))
	if c is Label or c is RichTextLabel:
		var ws := _str(style, "white-space")
		# pre-wrap keeps white space at wrap points (no edge trimming); the
		# trim flags are only written once a document uses pre-wrap.
		var keep_ws := ws == "pre-wrap"
		if keep_ws or c.has_meta("uxml_trim_set"):
			c.set_meta("uxml_trim_set", true)
			c.autowrap_trim_flags = 0 if keep_ws else int(c.get_meta("uxml_trim", 0))
		match ws:
			"normal", "pre-wrap":
				c.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			"nowrap", "pre":
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


# ---------------------------------------------------------------------------
# Visual properties: opacity, overflow, transforms, cursor
# ---------------------------------------------------------------------------
# All of them leave layout alone (the document lists them in PAINT_ONLY).
# Each only writes to the control when the element declares the property
# or a previous restyle did, so documents without them are untouched.

## Visual and text-effect properties. A control enters these paths once its
## style holds one of the keys; it then stays on them (meta flag) so a later
## restyle without the property can undo what the earlier one wrote.
const _VISUAL_KEYS := [
	"opacity", "overflow", "-unity-overflow-clip-box", "translate", "rotate",
	"scale", "transform-origin", "cursor",
]
const _TEXT_FX_KEYS := [
	"text-shadow", "text-overflow", "overflow", "-unity-paragraph-spacing",
	"-unity-text-overflow-position",
]


static func _gate(c: Control, style: Dictionary, keys: Array, flag: StringName) -> bool:
	if c.has_meta(flag):
		return true
	for k in keys:
		if style.has(k):
			c.set_meta(flag, true)
			return true
	return false


func _apply_visual(el: UxmlElement, c: Control, native: Control, style: Dictionary) -> void:
	if not _gate(c, style, _VISUAL_KEYS, &"uxml_vis"):
		return
	_apply_opacity(c, style, el)
	_apply_overflow(c, style, el)
	_apply_transform(c, style, el)
	_apply_cursor(c, native, style, el)


## opacity -> modulate alpha. Godot multiplies each canvas item of the
## subtree by it, which is Unity's "perceived opacity": a child is not
## composited as a group (docs: you see the parent through the child).
func _apply_opacity(c: Control, style: Dictionary, el: UxmlElement) -> void:
	var a := 1.0
	var e = style.get("opacity")
	if e != null:
		var r := UssValues.parse_opacity(String(e["value"]))
		if r["ok"]:
			a = r["value"]
		else:
			_warn(el, "opacity", r["problem"])
	if c.modulate.a != a:
		c.modulate = Color(c.modulate, a)


## overflow: hidden (and Unity's scroll) -> clip_contents, which clips the
## subtree at the border box. -unity-overflow-clip-box picks a smaller
## clip rect: padding-box (Unity's default) is inside the border,
## content-box is inside the padding too. When that rect differs from the
## border box, a UxmlClip clips the children while the element's own
## background and border still draw in full.
func _apply_overflow(c: Control, style: Dictionary, el: UxmlElement) -> void:
	var ov := _str(style, "overflow")
	var hidden := ov == "hidden" or ov == "scroll"
	if not ov.is_empty() and not hidden and ov != "visible":
		_warn(el, "overflow", 'overflow: "%s" is not visible, hidden or scroll; visible used' % ov)
	if hidden or c.has_meta("uxml_clip_default"):
		if not c.has_meta("uxml_clip_default"):
			c.set_meta("uxml_clip_default", c.clip_contents)
		var want: bool = hidden or bool(c.get_meta("uxml_clip_default"))
		if c.clip_contents != want:
			c.clip_contents = want
	var box := _str(style, "-unity-overflow-clip-box")
	if not box.is_empty() and box != "padding-box" and box != "content-box":
		_warn(el, "-unity-overflow-clip-box", '-unity-overflow-clip-box: "%s" is not padding-box or content-box' % box)
		box = "padding-box"
	var inset := Vector4.ZERO
	if hidden:
		if box == "content-box" and not (c is UxmlField):
			var memo = _inset_memo.get(c)
			if memo != null:
				inset = Vector4(memo[0].x, memo[0].y, memo[1].x, memo[1].y)
			else:
				inset = _px_insets(style, true)
		else:
			inset = _px_insets(style, false)
	var clip = (c.get_meta("uxml_clip") if c.has_meta("uxml_clip") else null)
	if hidden and inset != Vector4.ZERO:
		if clip == null:
			clip = UxmlClip.new(c)
			c.set_meta("uxml_clip", clip)
		clip.set_inset(inset)
		if box == "content-box":
			_clip_content[c] = true
		else:
			_clip_content.erase(c)
	elif clip != null:
		clip.detach()
		c.remove_meta("uxml_clip")
		_clip_content.erase(c)


## Border (and, with padding, px padding) insets as left, top, right,
## bottom. Percentage padding is resolved later by apply_resolved_insets.
func _px_insets(style: Dictionary, with_padding: bool) -> Vector4:
	var v := [0.0, 0.0, 0.0, 0.0]  # top right bottom left
	for k in 4:
		for prop in ([_BW[k], _PAD[k]] if with_padding else [_BW[k]]):
			var e = style.get(prop)
			if e == null:
				continue
			var p := UssValues.parse_length(String(e["value"]))
			if p["kind"] == "px":
				v[k] += maxf(0.0, p["value"])
	return Vector4(v[3], v[0], v[1], v[2])


## translate / rotate / scale / transform-origin -> Control.offset_transform
## (Godot 4.7). It is applied after layout and never moves the layout box,
## exactly as Unity's transform: position + translate + origin +
## rotate * scale * (point - origin). Percentages (translate of the
## element's own size, origin) are ratios Godot re-resolves on resize.
## offset_transform_visual_only = false: input follows the transform, as
## Unity picking does.
func _apply_transform(c: Control, style: Dictionary, el: UxmlElement) -> void:
	var te = style.get("translate")
	var re = style.get("rotate")
	var se = style.get("scale")
	var oe = style.get("transform-origin")
	if te == null and re == null and se == null and oe == null:
		if c.offset_transform_enabled:
			c.offset_transform_enabled = false
			c.offset_transform_position = Vector2.ZERO
			c.offset_transform_position_ratio = Vector2.ZERO
			c.offset_transform_rotation = 0.0
			c.offset_transform_scale = Vector2.ONE
			c.offset_transform_pivot = Vector2.ZERO
			c.offset_transform_pivot_ratio = Vector2(0.5, 0.5)
		return
	var tpx := Vector2.ZERO
	var tratio := Vector2.ZERO
	if te != null:
		var t := UssValues.parse_translate(String(te["value"]))
		if t["ok"]:
			tpx = t["px"]
			tratio = t["ratio"]
		else:
			_warn(el, "translate", t["problem"])
	var angle := 0.0
	if re != null:
		var r := UssValues.parse_rotate(String(re["value"]))
		if r["ok"]:
			angle = r["angle"]
		else:
			_warn(el, "rotate", r["problem"])
	var sc := Vector2.ONE
	if se != null:
		var s := UssValues.parse_scale(String(se["value"]))
		if s["ok"]:
			sc = s["scale"]
		else:
			_warn(el, "scale", s["problem"])
	var opx := Vector2.ZERO
	var oratio := Vector2(0.5, 0.5)
	if oe != null:
		var o := UssValues.parse_transform_origin(String(oe["value"]))
		if o["ok"]:
			opx = o["px"]
			oratio = o["ratio"]
		else:
			_warn(el, "transform-origin", o["problem"])
	c.offset_transform_enabled = true
	c.offset_transform_visual_only = false
	c.offset_transform_position = tpx
	c.offset_transform_position_ratio = tratio
	c.offset_transform_rotation = angle
	c.offset_transform_scale = sc
	c.offset_transform_pivot = opx
	c.offset_transform_pivot_ratio = oratio


## cursor: a Unity keyword -> mouse_default_cursor_shape (Unity itself
## draws keyword cursors only in Editor UI); url() -> that image while the
## element is hovered, with its hotspot, through TEXTURE_CURSOR_SHAPE.
func _apply_cursor(c: Control, native: Control, style: Dictionary, el: UxmlElement) -> void:
	var e = style.get("cursor")
	if e == null and not c.has_meta("uxml_cursor_default"):
		return
	if not c.has_meta("uxml_cursor_default"):
		c.set_meta("uxml_cursor_default", [c.mouse_default_cursor_shape, native.mouse_default_cursor_shape])
	var defaults: Array = c.get_meta("uxml_cursor_default")
	var shape := int(defaults[0])
	var native_shape := int(defaults[1])
	var tex: Texture2D = null
	var hot := Vector2.ZERO
	if e != null:
		var r := UssValues.parse_cursor(String(e["value"]))
		if not r["ok"]:
			_warn(el, "cursor", r["problem"])
		elif r["kind"] == "keyword":
			shape = r["shape"]
			native_shape = shape
		else:
			tex = _texture_ref(String(r["ref"]), e, "cursor", el)
			if tex != null:
				shape = TEXTURE_CURSOR_SHAPE
				native_shape = shape
				hot = r["hotspot"]
	c.mouse_default_cursor_shape = shape
	native.mouse_default_cursor_shape = native_shape
	if tex != null:
		c.set_meta("uxml_cursor_tex", [tex, hot])
		if not c.has_meta("uxml_cursor_wired"):
			c.set_meta("uxml_cursor_wired", true)
			c.mouse_entered.connect(UxmlStyleApplier._cursor_hover.bind(c, true))
			c.mouse_exited.connect(UxmlStyleApplier._cursor_hover.bind(c, false))
	elif c.has_meta("uxml_cursor_tex"):
		c.remove_meta("uxml_cursor_tex")
		if c.has_meta("uxml_cursor_on"):
			_cursor_hover(c, false)


static func _cursor_hover(c: Control, on: bool) -> void:
	var spec = (c.get_meta("uxml_cursor_tex") if c.has_meta("uxml_cursor_tex") else null)
	if on and spec != null:
		c.set_meta("uxml_cursor_on", true)
		Input.set_custom_mouse_cursor(spec[0], _TEXTURE_CURSOR_INPUT, spec[1])
	elif c.has_meta("uxml_cursor_on"):
		c.remove_meta("uxml_cursor_on")
		Input.set_custom_mouse_cursor(null, _TEXTURE_CURSOR_INPUT)


# ---------------------------------------------------------------------------
# Text effects: shadow, paragraph spacing, elision, rich text
# ---------------------------------------------------------------------------

## text-shadow -> Label / RichTextLabel font shadow. Godot draws a sharp
## shadow: a blur radius is diagnosed and not drawn. Other controls have
## no text shadow; that is diagnosed only where the element declares the
## property itself (it inherits, so containers pass it down to everything).
func _apply_text_shadow(c: Control, style: Dictionary, el: UxmlElement) -> void:
	var e = style.get("text-shadow")
	if not (c is Label or c is RichTextLabel):
		if e != null and String(e["origin"].get("kind", "")) != "inherited":
			_warn_once_key("text-shadow-control", el,
				"text-shadow is drawn for Label text only; this control draws none")
		return
	var sh = null
	if e != null:
		var r := UssValues.parse_text_shadow(String(e["value"]))
		if not r["ok"]:
			_warn(el, "text-shadow", r["problem"])
		elif (r["color"] as Color).a > 0.0:
			sh = r
			if r["blur"] > 0.0:
				_warn_once_key("text-shadow-blur", el,
					"text-shadow blur radius is not supported; the shadow is drawn sharp")
	if sh != null:
		c.add_theme_color_override("font_shadow_color", sh["color"])
		c.add_theme_constant_override("shadow_offset_x", roundi(sh["offset"].x))
		c.add_theme_constant_override("shadow_offset_y", roundi(sh["offset"].y))
		c.add_theme_constant_override("shadow_outline_size", 0)
	elif c.has_theme_color_override("font_shadow_color"):
		c.remove_theme_color_override("font_shadow_color")
		for k in ["shadow_offset_x", "shadow_offset_y", "shadow_outline_size"]:
			if c.has_theme_constant_override(k):
				c.remove_theme_constant_override(k)


## -unity-paragraph-spacing (em/100 units, like letter-spacing): extra space
## after each line break. RichTextLabel has paragraph_separation; a Label
## has no theme item for it, so a LabelSettings carries it together with
## copies of the Label's resolved text overrides (Godot draws a Label with
## LabelSettings instead of its theme).
func _apply_paragraph_spacing(c: Control, style: Dictionary, el: UxmlElement) -> void:
	var px := 0
	if style.has("-unity-paragraph-spacing"):
		px = _spacing_int(style, "-unity-paragraph-spacing",
			float(_effective_font_size(c, style, el)), el)
	if c is RichTextLabel:
		if px != 0:
			c.add_theme_constant_override("paragraph_separation", px)
		elif c.has_theme_constant_override("paragraph_separation"):
			c.remove_theme_constant_override("paragraph_separation")
		return
	var l := c as Label
	if px == 0:
		if l.has_meta("uxml_label_settings"):
			l.remove_meta("uxml_label_settings")
			l.label_settings = null
		return
	var ls := LabelSettings.new()
	ls.font = l.get_theme_font("font")
	ls.font_size = l.get_theme_font_size("font_size")
	ls.font_color = l.get_theme_color("font_color")
	ls.line_spacing = l.get_theme_constant("line_spacing")
	ls.paragraph_spacing = px
	ls.outline_size = l.get_theme_constant("outline_size")
	ls.outline_color = l.get_theme_color("font_outline_color")
	ls.shadow_color = l.get_theme_color("font_shadow_color")
	ls.shadow_size = l.get_theme_constant("shadow_outline_size")
	ls.shadow_offset = Vector2(
		l.get_theme_constant("shadow_offset_x"), l.get_theme_constant("shadow_offset_y"))
	l.set_meta("uxml_label_settings", true)
	l.label_settings = ls


## overflow: hidden on single-line Label/Button text, text-overflow and
## -unity-text-overflow-position.
## A Godot Label or Button never gets narrower than its text; with overflow
## hidden Unity keeps the authored box and clips the text, so such a
## control gets clip_text (the measurer turns it off to measure the full
## text, see UxmlDocument._measure_leaf). Unity elides (with "...") only
## when text-overflow is ellipsis, overflow is hidden and the text does
## not wrap (TextElement.isElided); the elided string is computed after
## layout by update_elision(), this records which controls take part.
func _apply_elision(c: Control, style: Dictionary, el: UxmlElement) -> void:
	var is_text := c is Label or (c is Button and not c is OptionButton)
	var ov0 := _str(style, "overflow")
	var clip_text: bool = (is_text and (ov0 == "hidden" or ov0 == "scroll")
		and c.autowrap_mode == TextServer.AUTOWRAP_OFF)
	if clip_text:
		if not c.has_meta("uxml_clip_text"):
			c.set_meta("uxml_clip_text_default", c.clip_text)
			c.set_meta("uxml_clip_text", true)
			clip_texts += 1
		c.clip_text = true
	elif c.has_meta("uxml_clip_text"):
		c.clip_text = bool(c.get_meta("uxml_clip_text_default"))
		c.remove_meta("uxml_clip_text")
		c.remove_meta("uxml_clip_text_default")
		clip_texts -= 1
	var to := _str(style, "text-overflow")
	if not to.is_empty() and to != "clip" and to != "ellipsis":
		_warn(el, "text-overflow", 'text-overflow: "%s" is not clip or ellipsis' % to)
	var pos := _str(style, "-unity-text-overflow-position")
	if not pos.is_empty() and not ["start", "middle", "end"].has(pos):
		_warn(el, "-unity-text-overflow-position",
			'-unity-text-overflow-position: "%s" is not start, middle or end; end used' % pos)
		pos = "end"
	var ov := _str(style, "overflow")
	var on: bool = (is_text and to == "ellipsis" and (ov == "hidden" or ov == "scroll")
		and c.autowrap_mode == TextServer.AUTOWRAP_OFF)
	if c is RichTextLabel and to == "ellipsis" and (ov == "hidden" or ov == "scroll"):
		_warn_once_key("rich-elide", el, "text-overflow: ellipsis is not applied to rich text; the text is clipped")
	if on:
		elide[c] = "end" if pos.is_empty() else pos
	elif elide.has(c):
		elide.erase(c)
		_unelide(c)


## Puts the full text back on a control that is no longer elided.
func _unelide(c: Control) -> void:
	if not c.has_meta("uxml_full_text"):
		return
	if String(c.get("text")) == String(c.get_meta("uxml_elided")):
		c.set("text", c.get_meta("uxml_full_text"))
	c.remove_meta("uxml_full_text")
	c.remove_meta("uxml_elided")
	_elided_tooltip(c, false, "")


## Elides every participating control at its current (laid-out) width.
## Runs after layout in both layout paths, so they stay identical. While
## elided, `uxml_full_text` holds the text and `uxml_elided` the shown
## form; the measurer swaps the full text back in to measure, so the
## intrinsic size is the full text's, as in Unity. Text that game code set
## in the meantime is taken as the new full text.
func update_elision() -> void:
	for c in elide.keys():
		if not is_instance_valid(c):
			elide.erase(c)
			continue
		var cur := String(c.get("text"))
		var full := cur
		if c.has_meta("uxml_full_text") and cur == String(c.get_meta("uxml_elided")):
			full = c.get_meta("uxml_full_text")
		var font: Font = c.get_theme_font("font")
		var fs: int = c.get_theme_font_size("font_size")
		var sb: StyleBox = c.get_theme_stylebox("normal")
		var width: float = c.size.x - (sb.get_minimum_size().x if sb != null else 0.0)
		var shown := full if font == null else elide_text(full, width, elide[c], font, fs)
		if shown == full:
			if c.has_meta("uxml_full_text"):
				c.remove_meta("uxml_full_text")
				c.remove_meta("uxml_elided")
			if cur != full:
				c.set("text", full)
			_elided_tooltip(c, false, full)
		else:
			c.set_meta("uxml_full_text", full)
			c.set_meta("uxml_elided", shown)
			if cur != shown:
				c.set("text", shown)
			_elided_tooltip(c, true, full)


## display-tooltip-when-elided (default true): the full text becomes the
## tooltip while the text is elided, replacing any authored tooltip, and
## the authored tooltip returns afterwards. A Label ignores the mouse by
## default, so it passes mouse input while it shows the tooltip (unless
## picking-mode="Ignore" asks for no pointer input).
func _elided_tooltip(c: Control, on: bool, full: String) -> void:
	if on and bool(c.get_meta("uxml_tooltip_elided", true)):
		if not c.has_meta("uxml_tip_saved"):
			c.set_meta("uxml_tip_saved", c.tooltip_text)
		c.tooltip_text = full
		# picking-mode="Ignore" (uxml_mouse_authored) keeps the element
		# transparent to the pointer, tooltip or not.
		var picking_ignored: bool = (c.has_meta("uxml_mouse_authored")
			and int(c.get_meta("uxml_mouse", 0)) == Control.MOUSE_FILTER_IGNORE)
		if c.visible and not picking_ignored and c.mouse_filter == Control.MOUSE_FILTER_IGNORE:
			c.set_meta("uxml_tip_mouse", true)
			c.mouse_filter = Control.MOUSE_FILTER_PASS
	elif c.has_meta("uxml_tip_saved"):
		c.tooltip_text = c.get_meta("uxml_tip_saved")
		c.remove_meta("uxml_tip_saved")
		if c.has_meta("uxml_tip_mouse"):
			c.remove_meta("uxml_tip_mouse")
			if c.mouse_filter == Control.MOUSE_FILTER_PASS:
				c.mouse_filter = Control.MOUSE_FILTER_IGNORE


## Unity TextElement.ElideText: binary search for the longest text that
## fits `width` with "..." at the start, middle or end. Unity allows the
## text 1px into the right padding before it elides (extraWidth).
static func elide_text(text: String, width: float, pos: String, font: Font, fs: int) -> String:
	const ELLIPSIS := "..."
	var measure := func(t: String) -> float:
		return font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	if measure.call(text) <= width + 1.0:
		return text
	var min_text := ELLIPSIS if text.length() > 1 else text
	if measure.call(min_text) >= width:
		return min_text
	var last := text.length() - 1
	var prev_fit := -1
	var truncated := text
	var lo := 1 if pos == "start" else 0
	var hi := last if (pos == "start" or pos == "middle") else last - 1
	var mid := (lo + hi) / 2
	while lo <= hi:
		if pos == "start":
			truncated = ELLIPSIS + text.substr(mid, last - (mid - 1))
		elif pos == "end":
			truncated = text.substr(0, mid) + ELLIPSIS
		else:
			truncated = ("" if mid - 1 <= 0 else text.substr(0, mid - 1)) + ELLIPSIS \
				+ ("" if last - (mid - 1) <= 0 else text.substr(last - (mid - 1)))
		var w: float = measure.call(truncated)
		if absf(w - width) < 0.0001:
			return truncated
		if pos == "start":
			if w > width:
				if prev_fit == mid - 1:
					return ELLIPSIS + text.substr(prev_fit, last - (prev_fit - 1))
				lo = mid + 1
			else:
				hi = mid - 1
				prev_fit = mid
		else:
			if w > width:
				if prev_fit == mid - 1:
					if pos == "end":
						return text.substr(0, prev_fit) + ELLIPSIS
					var k := maxi(prev_fit - 1, 0)
					return text.substr(0, k) + ELLIPSIS + text.substr(last - k)
				hi = mid - 1
			else:
				lo = mid + 1
				prev_fit = mid
		mid = (lo + hi) / 2
	return truncated


## Rebuilds a rich text Label's content when its text or base text style
## changed (the factory stores the parsed tags in `uxml_rich`).
func _render_rich(c: RichTextLabel) -> void:
	var pr = (c.get_meta("uxml_rich") if c.has_meta("uxml_rich") else null)
	if pr == null:
		return
	var font: Font = c.get_theme_font("normal_font")
	var fs: int = c.get_theme_font_size("normal_font_size")
	var col: Color = c.get_theme_color("default_color")
	var key := [String(c.get_meta("uxml_rich_src", "")),
		0 if font == null else font.get_instance_id(), fs, col]
	if c.get_meta("uxml_rich_key", []) == key:
		return
	c.set_meta("uxml_rich_key", key)
	UxmlRichText.render(c, pr["ops"], font, fs, col)
