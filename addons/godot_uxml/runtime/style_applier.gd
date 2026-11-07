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
## Elements cloned from a template file -> that file (UxmlDocumentModel.
## element_paths). An inline style resolves its url()s against it.
var element_paths: Dictionary = {}
var _warned: Dictionary = {}
# resolved path -> Resource or null (attempted and failed): repeated
# restyles must not re-hit the filesystem for the same reference, missing
# or not.
var _tex_cache: Dictionary = {}
## Textures of the default theme (the addon's read-only theme folder,
## UxmlResourceResolver.TRUSTED_DIRS) stay loaded across documents. Without
## this the last document holding a theme texture frees it, and the next
## load reads and decodes it from disk again (about 2.5 ms per load of a
## settings screen). Only successful loads are kept.
static var _theme_tex: Dictionary = {}
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
## Unity's line metrics on the default font (the default theme sets it):
## see _line_font.
var unity_line_metrics := false
static var _line_fonts: Dictionary = {}
## Unity's default runtime font (NotInter-Regular, an Inter clone): line
## height and ascent per em. Measured: one line of text is ceil(1.2099 x
## font-size) high (9px: 11, 10px: 13, 14px: 17, 16px: 20, 18px: 22, 20px:
## 25 in bench/parity/unity), Inter's ascender is 1984/2048 em.
const UNITY_LINE_EM := 1.2099
const UNITY_ASCENT_EM := 0.96875
## Labels fitted into a box shorter than their text line (fit_label):
## control -> the height fitted for.
var fitted: Dictionary = {}
## Labels the placement handed to fit_label: control -> [box height,
## control height after the fit]. A placement with the same box height
## that leaves the control at the same height skips fit_label, so a Label
## that stays taller than its box is not fitted again on every layout. The
## text changes the fit only through its line count, which changes the
## height of the control. apply() drops the entry.
var fit_seen: Dictionary = {}
static var _fit_fonts: Dictionary = {}
## How many controls carry clip_text for overflow: hidden text. While zero
## the measurers skip the clip-text check entirely.
var clip_texts := 0
## How many Labels/Buttons have an active -unity-text-auto-size. While zero
## the measurers skip the auto-size check entirely.
var auto_sizes := 0
## Canvas groups: filtered controls -> UxmlFilter, Labels with a blurred
## text shadow -> UxmlTextShadow. Godot does not nest canvas groups, so
## _resolve_nesting() turns off every group inside a filtered ancestor.
var _filters: Dictionary = {}
var _shadows: Dictionary = {}
## Resolved path -> UxmlFilterDefinition / Material (null: failed).
var _def_cache: Dictionary = {}
var _mat_cache: Dictionary = {}
## Plain Shader / Material -> the UxmlFilterDefinition made around it.
var _def_wrap: Dictionary = {}
## Shader named by -unity-material -> the ShaderMaterial made around it.
var _mat_wrap: Dictionary = {}
## Shader -> {uniform name: type} (prop() and filter parameter binding).
var _uniforms: Dictionary = {}

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
		if native is TextureRect and el.local == "Image":
			_apply_image(control, native, style, el)
	else:
		_apply_themed(native, style, el, true)
	_apply_visual(el, control, native, style)


## Unity's Image reads its image, scale mode and tint from the custom
## properties --unity-image, --unity-image-size (stretch-to-fill,
## scale-and-crop, scale-to-fit) and --unity-image-tint-color (Image's
## k_ImageProperty, k_ScaleModeProperty, k_TintColorProperty).
const _IMAGE_FIT := {"stretch-to-fill": TextureRect.STRETCH_SCALE,
	"scale-and-crop": TextureRect.STRETCH_KEEP_ASPECT_COVERED,
	"scale-to-fit": TextureRect.STRETCH_KEEP_ASPECT_CENTERED}


func _apply_image(box: UxmlBox, tr: TextureRect, style: Dictionary, el: UxmlElement) -> void:
	if style.has("--unity-image"):
		var tex := _texture(style, "--unity-image", el)
		if tex != null and tr.texture != tex:
			tr.texture = tex
			box.natural_size = tex.get_size()
	var fit := _str(style, "--unity-image-size")
	if _IMAGE_FIT.has(fit):
		tr.stretch_mode = _IMAGE_FIT[fit]
	var tint = _color(style, "--unity-image-tint-color", el) if style.has("--unity-image-tint-color") else null
	tr.self_modulate = tint if tint != null else Color.WHITE


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


## Per themed control without a background image: [the style entries of
## _BOX_KEYS at its last apply, the box _stylebox built from them (or
## null), that box's uxml_margins as built].
var _box_memo: Dictionary = {}
## The box of a Button without a USS box.
static var _NO_BOX := StyleBoxEmpty.new()
## The style properties _stylebox reads.
const _BOX_KEYS := ["background-color",
	"border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
	"border-top-color", "border-right-color", "border-bottom-color", "border-left-color",
	"border-top-left-radius", "border-top-right-radius",
	"border-bottom-right-radius", "border-bottom-left-radius",
	"padding-top", "padding-right", "padding-bottom", "padding-left"]


## `sb` (built by _stylebox with margins `built`) is on every slot of `c`
## and still has the margins it was built with (apply_resolved_insets, the
## only writer after _stylebox, writes only margins).
static func _installed_as_built(c: Control, slots: Array, sb: StyleBox, built) -> bool:
	if slots.is_empty() or built == null:
		return false
	for slot in slots:
		if not c.has_theme_stylebox_override(slot) or c.get_theme_stylebox(slot) != sb:
			return false
	var b: Array = built
	return (sb.get_meta("uxml_margins", null) == b and sb.content_margin_left == b[0]
		and sb.content_margin_top == b[1] and sb.content_margin_right == b[2]
		and sb.content_margin_bottom == b[3])


func _apply_themed_inner(c: Control, style: Dictionary, el: UxmlElement, include_skin: bool) -> void:
	if include_skin:
		var slots := _stylebox_slots(c)
		var sb: StyleBox = null
		var keep := false
		if style.has("background-image"):
			_box_memo.erase(c)
			sb = _stylebox(style, el)
			var tex := _texture(style, "background-image", el)
			if sb == null and tex != null:
				sb = _image_stylebox(tex, style, el)
				# USS slicing never pads content: StyleBoxTexture would otherwise
				# fall back to its texture margins as content margins.
				for side in ["left", "top", "right", "bottom"]:
					sb.set("content_margin_" + side, 0.0)
			elif sb != null and tex != null and _box_drawn(sb):
				# Unity draws the background colour, the image over it and
				# the border over the image: a UxmlBoxStyle carries the image
				# between its fill and its border.
				sb = _with_image(style, el, tex)
			elif sb != null and tex != null:
				# Padding only: the image's stylebox carries the content
				# margins.
				var tsb := _image_stylebox(tex, style, el)
				for side in ["left", "top", "right", "bottom"]:
					tsb.set("content_margin_" + side, sb.get("content_margin_" + side))
				if sb.has_meta("uxml_margins"):
					tsb.set_meta("uxml_margins", sb.get_meta("uxml_margins"))
				sb = tsb
		else:
			# Without an image the box is _stylebox's, a function of the
			# style entries it reads: entries that are the same objects as
			# at the last apply (shared, read-only cascade entries) give the
			# same box, so it is not built again, and the installed box
			# stays when it is still as built.
			var inputs: Array = []
			for k in _BOX_KEYS:
				inputs.append(style.get(k))
			var memo = _box_memo.get(c)
			var same := memo != null
			if same:
				var was: Array = memo[0]
				for k in inputs.size():
					if not is_same(was[k], inputs[k]):
						same = false
						break
			if same:
				sb = memo[1]
				keep = sb != null and _installed_as_built(c, slots, sb, memo[2])
			if not keep and (not same or sb != null):
				sb = _stylebox(style, el)
				_box_memo[c] = [inputs, sb, null if sb == null else (sb.get_meta("uxml_margins") as Array).duplicate()]
		if not keep:
			# A Button without a USS box draws none (Unity's RepeatButton and
			# `all: initial` draw no box): not Godot's theme box, whose
			# content margins would also pad the text.
			if sb == null and c is BaseButton:
				sb = _NO_BOX
			for slot in slots:
				if sb == _NO_BOX and c.has_theme_stylebox_override(slot) and c.get_theme_stylebox(slot) == sb:
					continue  # installed: a new override would update the theme again
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

	if c is LineEdit or c is TextEdit:
		_apply_edit_colors(c, style, el)

	var size_name := _font_size_name(c)
	var font_size := _int(style, "font-size", el)
	if font_size > 0:
		c.add_theme_font_size_override(size_name, font_size)
	elif c.has_theme_font_size_override(size_name):
		c.remove_theme_font_size_override(size_name)

	_apply_auto_size(c, style, el)

	var font_name := _font_name(c)
	var font := _font(c, style, el)
	if c.has_meta(&"uxml_maxc"):
		# The font, size or stylebox may change: measure the width again.
		c.remove_meta(&"uxml_maxc")
	if c.has_meta(&"uxml_clip_full"):
		c.remove_meta(&"uxml_clip_full")
	if c.has_meta(&"uxml_unfit"):
		c.remove_meta(&"uxml_unfit")
	if unity_line_metrics and (c is Label or c is Button or c is LineEdit or c is TextEdit
			or c is RichTextLabel) and not _has_url_font(style):
		font = _line_font(c, font, style, el)
	var keep_fit := false
	fit_seen.erase(c)
	if fitted.has(c):
		var fb: Array = c.get_meta(&"uxml_fit_base")
		if fb[0] == (font != null) and fb[1] == (font if font != null else fb[1]):
			# Same font as the fit was made for: the fit stays.
			keep_fit = true
		else:
			# The font override below replaces the fitted font: the next
			# placement fits the Label again.
			fitted.erase(c)
			c.remove_meta(&"uxml_fit")
			c.remove_meta(&"uxml_fit_base")
	if keep_fit:
		pass
	elif font != null:
		# An unchanged override is not set again (a theme change makes the
		# control shape its text again).
		if not c.has_theme_font_override(font_name) or c.get_theme_font(font_name) != font:
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


## The caret and selection colours of a text field editor: Unity's custom
## properties --unity-cursor-color and --unity-selection-color (inherited
## from the field, measured: ctl-textfield). Without them the editor keeps
## its fallback theme (UxmlTextInput).
const _EDIT_COLORS := {"--unity-cursor-color": "caret_color", "--unity-selection-color": "selection_color"}


func _apply_edit_colors(c: Control, style: Dictionary, el: UxmlElement) -> void:
	for prop in _EDIT_COLORS:
		var item: String = _EDIT_COLORS[prop]
		var col = _color(style, prop, el) if style.has(prop) else null
		if col != null:
			c.add_theme_color_override(item, col)
		elif c.has_theme_color_override(item):
			c.remove_theme_color_override(item)


## -unity-text-auto-size: best-fit <min> <max> (Unity 6.3). Unity applies it
## only with the advanced text generator (-unity-text-generator: advanced);
## with the standard generator Unity logs a warning and ignores it, and so
## does this runtime. An active Label or Button gets the `uxml_autosize`
## meta [min, max, authored content height or -1]; both layout measurers
## then call autosize_measure(), and placement calls autosize_place().
func _apply_auto_size(c: Control, style: Dictionary, el: UxmlElement) -> void:
	var e = style.get("-unity-text-auto-size")
	var had := c.has_meta(_AUTOSIZE)
	if e == null and not had:
		return
	var spec = null
	if e != null and (c is Label or (c is Button and not c is OptionButton)):
		var r := UssValues.parse_text_auto_size(String(e["value"]))
		if not r["ok"]:
			_warn(el, "-unity-text-auto-size", r["problem"])
		elif r["best_fit"]:
			if _str(style, "-unity-text-generator") != "advanced":
				_warn_once_key("autosize-generator", el,
					"-unity-text-auto-size needs -unity-text-generator: advanced; Unity ignores it with the standard text generator")
			else:
				var ch := -1.0
				var hp := UssValues.parse_length(_str(style, "height"))
				if hp["kind"] == "px":
					var ins := _px_insets(style, true)
					ch = maxf(0.0, float(hp["value"]) - ins.y - ins.w)
				spec = [float(r["min"]), float(r["max"]), ch]
	elif e != null and c is RichTextLabel and String(e["origin"].get("kind", "")) != "inherited":
		_warn_once_key("autosize-rich", el, "-unity-text-auto-size is not applied to rich text")
	if spec == null:
		if had:
			c.remove_meta(_AUTOSIZE)
			c.remove_meta(_AUTOSIZE_FS)
			auto_sizes -= 1
		return
	if not had:
		auto_sizes += 1
	c.set_meta(_AUTOSIZE, spec)
	# Until the next placement fits the laid-out box, draw at the last
	# fitted size (or the maximum).
	var fs := int(c.get_meta(_AUTOSIZE_FS, int(floorf(spec[1]))))
	c.add_theme_font_size_override(_font_size_name(c), fs)


const _AUTOSIZE := &"uxml_autosize"
const _AUTOSIZE_FS := &"uxml_autosize_fs"


## The measurer for a best-fit text control (both layout paths call it, so
## they agree by construction): the combined minimum size at the font size
## that fits `content_w` (< 0: no width limit; the text then does not wrap,
## as Unity measures with an undefined width) and the authored content
## height. Leaves the control as it found it.
static func autosize_measure(c: Control, content_w: float) -> Vector2:
	var spec: Array = c.get_meta(_AUTOSIZE)
	var saved := _autosize_save(c)
	var s := _fit(c, content_w, float(spec[2]), float(spec[0]), float(spec[1]))
	var ms := _combined_at(c, s, content_w)
	_autosize_restore(c, saved)
	return ms


## Placement: fits the laid-out content box (width and height) and keeps
## that font size. Runs before the control gets its laid-out size, so the
## control's minimum size never holds the size open.
static func autosize_place(c: Control, content: Vector2) -> void:
	var spec: Array = c.get_meta(_AUTOSIZE)
	var saved := _autosize_save(c)
	var s := _fit(c, maxf(0.0, content.x), maxf(0.0, content.y), float(spec[0]), float(spec[1]))
	_autosize_restore(c, saved)
	c.set_meta(_AUTOSIZE_FS, s)
	var name := _font_size_name(c)
	if c.get_theme_font_size(name) != s or not c.has_theme_font_size_override(name):
		c.add_theme_font_size_override(name, s)
		if c.has_meta(&"uxml_unfit"):
			c.remove_meta(&"uxml_unfit")


## The largest whole font size in [min, max] at which the text fits the
## width (when >= 0) and the height (when >= 0); the minimum when none
## fits. Unity's advanced generator searches fractional sizes; Godot font
## sizes are whole pixels.
static func _fit(c: Control, w: float, h: float, mn: float, mx: float) -> int:
	var lo := maxi(1, ceili(mn))
	var hi := maxi(lo, floori(mx))
	if _fits(c, hi, w, h):
		return hi
	var best := lo
	var a := lo
	var b := hi - 1
	while a <= b:
		var mid := (a + b) >> 1
		if _fits(c, mid, w, h):
			best = mid
			a = mid + 1
		else:
			b = mid - 1
	return best


static func _fits(c: Control, s: int, w: float, h: float) -> bool:
	var t := _combined_at(c, s, w)
	var m := _uxml_margins(c)
	return ((w < 0.0 or t.x - m[0] - m[2] <= w + 0.01)
		and (h < 0.0 or t.y - m[1] - m[3] <= h + 0.01))


## Combined minimum size at font size `s`, with the text wrapped at content
## width `w` when the control wraps (one line when w < 0). Text clipping is
## off, so the size is the full text's.
static func _combined_at(c: Control, s: int, w: float) -> Vector2:
	c.add_theme_font_size_override(_font_size_name(c), s)
	if c is Label and c.autowrap_mode != TextServer.AUTOWRAP_OFF:
		var m := _uxml_margins(c)
		if w < 0.0:
			c.autowrap_mode = TextServer.AUTOWRAP_OFF
			var ms := c.get_combined_minimum_size()
			c.autowrap_mode = int(c.get_meta(&"uxml_autosize_wrap", TextServer.AUTOWRAP_WORD_SMART))
			return ms
		c.size = Vector2(w + m[0] + m[2], c.size.y)
	return c.get_combined_minimum_size()


## [l, t, r, b] padding + border the USS stylebox adds to the minimum size.
static func _uxml_margins(c: Control) -> Array:
	if c.has_theme_stylebox_override("normal"):
		var sb: StyleBox = c.get_theme_stylebox("normal")
		if sb != null and sb.has_meta("uxml_margins"):
			return sb.get_meta("uxml_margins")
	return [0.0, 0.0, 0.0, 0.0]


static func _autosize_save(c: Control) -> Array:
	var name := _font_size_name(c)
	var fs = c.get_theme_font_size(name) if c.has_theme_font_size_override(name) else null
	var shown = c.get(&"text")
	var full = shown
	if c.has_meta(&"uxml_full_text") and shown == c.get_meta(&"uxml_elided"):
		full = c.get_meta(&"uxml_full_text")
		c.set(&"text", full)
	var clip = c.get(&"clip_text")
	if clip == true:
		c.set(&"clip_text", false)
	if c is Label:
		c.set_meta(&"uxml_autosize_wrap", c.autowrap_mode)
	return [fs, c.size, shown, full, clip]


static func _autosize_restore(c: Control, saved: Array) -> void:
	var name := _font_size_name(c)
	if saved[0] == null:
		c.remove_theme_font_size_override(name)
	else:
		c.add_theme_font_size_override(name, int(saved[0]))
	if saved[4] == true:
		c.set(&"clip_text", true)
	if saved[2] != saved[3]:
		c.set(&"text", saved[2])
	if c.size != saved[1]:
		c.size = saved[1]


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
		# Unity's initial outline colour is transparent.
		var oc: Color = col if col != null else Color.TRANSPARENT
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


## A UxmlBoxStyle of the element's box with its background image.
func _with_image(style: Dictionary, el: UxmlElement, tex: Texture2D) -> StyleBox:
	var ub = _stylebox(style, el, true)
	var img: StyleBox
	if _needs_placement(style):
		img = _image_stylebox(tex, style, el)
	else:
		img = _texture_stylebox(tex, style, el)
	for side in ["left", "top", "right", "bottom"]:
		img.set("content_margin_" + side, 0.0)
	if ub is UxmlBoxStyle:
		ub.image = img
		return ub
	return img


## Whether a box style draws anything (a fill, a border or a radius).
static func _box_drawn(sb: StyleBox) -> bool:
	if sb is UxmlBoxStyle:
		return true
	var f := sb as StyleBoxFlat
	return f != null and (f.draw_center or f.border_width_left > 0 or f.border_width_top > 0
		or f.border_width_right > 0 or f.border_width_bottom > 0)


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
	if tex != null and box.box_style != null and _box_drawn(box.box_style):
		# A background colour, border or radius with the image: the image
		# draws between the fill and the border (UxmlBoxStyle), as in Unity.
		box.box_style = _with_image(style, el, tex)
		box.box_texture_style = null
		box.box_texture = null
	elif tex != null and _needs_placement(style):
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
## file that holds the element's `style` attribute for inline styles (the
## template file for an element cloned from a template), and for inherited
## values the file of the ancestor's declaration. Relative url()s resolve
## against this.
func _origin_file(entry: Dictionary, el: UxmlElement = null) -> String:
	return _origin_dir(entry.get("origin", {}), el)


## Walks the origin chain itself — {kind: "rule", file} is a stylesheet,
## {kind: "inherited", from, origin} wraps the origin the ancestor `from`'s
## declaration carried (nested per inheritance hop), anything else (inline,
## missing) means the file that holds the declaring element's attributes.
func _origin_dir(origin: Dictionary, el: UxmlElement = null) -> String:
	match String(origin.get("kind", "")):
		"rule":
			var f := String(origin.get("file", ""))
			return f if not f.is_empty() else _uxml_path
		"inherited":
			return _origin_dir(origin.get("origin", {}), origin.get("from") as UxmlElement)
		_:
			if el != null and not element_paths.is_empty():
				return element_paths.get(el, _uxml_path)
			return _uxml_path


func _texture(style: Dictionary, name: String, el: UxmlElement) -> Texture2D:
	var e = style.get(name)
	if e == null:
		return null
	return _texture_ref(String(e["value"]), e, name, el)


static func _is_theme_path(path: String) -> bool:
	for d in UxmlResourceResolver.TRUSTED_DIRS:
		if path.begins_with(d):
			return true
	return false


## Load the url() `ref` written in style entry `e` (for diagnostics and the
## origin file relative references resolve against).
func _texture_ref(ref: String, e: Dictionary, name: String, el: UxmlElement) -> Texture2D:
	var u := UssValues.parse_url(ref)
	if not u["ok"]:
		_warn(el, name, "%s: %s" % [name, u["problem"]])
		return null
	var r := _resolver.resolve(u["path"], _origin_file(e, el), "texture")
	if not r["ok"]:
		_report_resolver(r, el, '%s "%s"' % [name, e["value"]])
		return null
	var path: String = r["path"]
	if _tex_cache.has(path):
		return _tex_cache[path]
	var tex: Texture2D = _theme_tex.get(path)
	if tex != null:
		_tex_cache[path] = tex
		return tex
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
	if tex != null and _is_theme_path(path):
		_theme_tex[path] = tex
	if tex == null:
		_warn_diag(
			"missing-file", "texture:%s:%s" % [path, el.get_instance_id()], el,
			'%s "%s" resolved to %s but is not a readable image' % [name, e["value"], path]
		)
	return tex


## True when -unity-font or -unity-font-definition names a font file.
static func _has_url_font(style: Dictionary) -> bool:
	for prop in ["-unity-font", "-unity-font-definition"]:
		var e = style.get(prop)
		if e != null and String(e["value"]).begins_with("url("):
			return true
	return false


## Unity's line height on Godot's default font. Unity lays a line of its
## default font out ceil(1.2099 x font-size) high with the baseline 0.969
## em below the line top; Godot's default font is taller (20px at 14px:
## a TextField 42px high, Unity 39px). A FontVariation with whole-pixel top
## and bottom spacing gives the Godot font Unity's line height and
## baseline, so text boxes, field heights and line pitch measure as in
## Unity. The glyphs keep Godot's font. Cached per base font and size.
func _line_font(c: Control, font: Font, style: Dictionary, el: UxmlElement) -> Font:
	var base := font
	if base == null:
		_capture_base_font(c)
		base = c.get_meta("uxml_base_font", null)
	if base == null:
		return font
	var fs := _effective_font_size(c, style, el)
	if fs <= 0:
		return font
	# Cached per font (by content for a FontVariation) and size.
	var per = _line_fonts.get(_font_key(base) if base is FontVariation else base)
	if per == null:
		per = {}
		_line_fonts[_font_key(base) if base is FontVariation else base] = per
	var hit = per.get(fs)
	if hit == null:
		var want_h := ceilf(UNITY_LINE_EM * fs - 0.001)
		var top := roundi(UNITY_ASCENT_EM * fs - base.get_ascent(fs))
		var bottom := roundi(want_h - base.get_height(fs)) - top
		hit = base if top == 0 and bottom == 0 else with_spacing(base, top, bottom)
		per[fs] = hit
	return hit if hit != base or font != null else font


## A cache key for a font by content: _font() makes a new FontVariation
## for a bold or italic style on each apply, so a key by instance would
## keep every one of them (and its TextServer caches) alive.
static func _font_key(f: Font) -> String:
	if f == null:
		return "-"
	if f is FontVariation:
		var v := f as FontVariation
		if v.has_meta(_FONT_KEY):
			return v.get_meta(_FONT_KEY)
		return "v%s|%s|%s|%d|%d|%d|%d|%s|%s" % [_font_key(v.base_font), v.variation_embolden,
			v.variation_transform, v.spacing_top, v.spacing_bottom, v.spacing_space, v.spacing_glyph,
			v.variation_opentype, v.opentype_features]
	return "f%d" % f.get_instance_id()


## `base` with extra top and bottom spacing. Godot does not stack nested
## FontVariations (the outer one replaces the spacing, embolden and
## transform of the inner one), so a FontVariation base is copied and its
## spacing grows.
static func with_spacing(base: Font, top: int, bottom: int) -> FontVariation:
	var fv: FontVariation
	if base is FontVariation:
		fv = (base as FontVariation).duplicate()
		fv.remove_meta(_FONT_KEY)  # the copy's content differs
		fv.set_spacing(TextServer.SPACING_TOP, fv.get_spacing(TextServer.SPACING_TOP) + top)
		fv.set_spacing(TextServer.SPACING_BOTTOM, fv.get_spacing(TextServer.SPACING_BOTTOM) + bottom)
	else:
		fv = FontVariation.new()
		fv.base_font = base
		fv.set_spacing(TextServer.SPACING_TOP, top)
		fv.set_spacing(TextServer.SPACING_BOTTOM, bottom)
	# This runtime does not change the font after this point: its content
	# key is kept on it (fit_label looks the key of the line font up for
	# every fit; formatting it cost about 16 us).
	fv.set_meta(_FONT_KEY, _font_key(fv))
	return fv


## Meta: the _font_key of a FontVariation made by with_spacing.
const _FONT_KEY := &"uxml_font_key"


## Max-content width of a wrapping Label (its longest paragraph, as one
## line) plus its stylebox margins: what Unity's TextElement measures
## without a width bound. The native measurer computes the same value
## (layout.rs, label_max_content).
static func label_max_content(l: Label) -> float:
	# Shaping a paragraph and the theme lookups cost microseconds: the width
	# is kept on the Label for its text (`uxml_maxc`; apply() drops it with
	# a font, size or stylebox change). The native measurer reads and
	# writes the same meta.
	if l.has_meta(&"uxml_maxc"):
		var c: Array = l.get_meta(&"uxml_maxc")
		if c[0] == l.text:
			return c[1]
	var font: Font = l.get_theme_font(&"font")
	var fs: int = l.get_theme_font_size(&"font_size")
	var ls := l.label_settings
	if ls != null:
		if ls.font != null:
			font = ls.font
		fs = ls.font_size
	var t := l.text
	if l.uppercase:
		t = t.to_upper()
	var w := 0.0
	if font != null and not t.is_empty():
		w = font.get_multiline_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fs).x
	var sb := l.get_theme_stylebox(&"normal")
	var total := w + (0.0 if sb == null else sb.get_minimum_size().x)
	l.set_meta(&"uxml_maxc", [l.text, total])
	return total


## Godot floors a Control at its minimum size, and the minimum height of a
## Label is one line of its font. Unity draws text that does not fit its
## box: a Label in a 20px TreeView row is 14px high, and a Label row of a
## ListView is as high as the item. When the layout gives a one-line Label
## less height than its line, the Label gets a FontVariation of its font
## with a negative bottom spacing as large as the deficit (whole pixels).
## The control then takes the laid-out height, and the text keeps its
## baseline. `uxml_fit` (on the control) holds the deficit; the measurers
## measure it as unfitted (unfitted_height), so the measure does not
## change. Called after the control got its laid-out size.
func fit_label(c: Label, want: Vector2) -> void:
	var fit: int = int(c.get_meta(&"uxml_fit", 0))
	var need := 0
	if c.autowrap_mode == TextServer.AUTOWRAP_OFF and c.label_settings == null and c.get_line_count() <= 1:
		need = maxi(0, int(ceilf(unfitted_height(c) - want.y - 0.01)))
	if fit > 0 and need > fit and c.size.y > unfitted_height(c) - fit + 0.01:
		# Godot does not shrink the line below a floor (the glyph extent),
		# and the fitted Label is held at that floor already: a larger
		# deficit leaves its size and text as they are. The fit stays, so
		# boxes of changing small heights do not swap fonts.
		need = fit
	if need == fit:
		if need > 0:
			fitted[c] = want.y
		if c.size != want:
			c.update_minimum_size()
			c.size = want
		return
	var had: bool
	var base: Font
	if fit > 0:
		var keep: Array = c.get_meta(&"uxml_fit_base")
		had = keep[0]
		base = keep[1]
	else:
		had = c.has_theme_font_override(&"font")
		base = c.get_theme_font(&"font")
	if need == 0:
		if had:
			c.add_theme_font_override(&"font", base)
		else:
			c.remove_theme_font_override(&"font")
		c.remove_meta(&"uxml_fit")
		c.remove_meta(&"uxml_fit_base")
		fitted.erase(c)
	else:
		var key := "%s|%d" % [_font_key(base), need]
		var fv: FontVariation = _fit_fonts.get(key)
		if fv == null:
			fv = with_spacing(base, 0, -need)
			_fit_fonts[key] = fv
		c.add_theme_font_override(&"font", fv)
		c.set_meta(&"uxml_fit", need)
		if fit == 0:
			c.set_meta(&"uxml_fit_base", [had, base])
	if need > 0:
		# The height fitted for: a placement at the same height skips the fit.
		fitted[c] = want.y
	c.update_minimum_size()
	c.size = want


## Godot floors a Control at its minimum size, and a Button's minimum is
## its text plus its stylebox's content margins (the USS border and
## padding). Unity draws a Button's text over a box that is too small for
## it, centred in the content box (measured: bench/pixels.py, a 30px
## Button with 10px padding and a 17px line). When the layout gives a
## Button less than that, its content margins shrink on that axis so the
## Button takes the laid-out size: on the vertical axis around the
## content box's centre (Godot centres a Button's text vertically), on the
## horizontal axis by the text alignment. The text then sits where Unity
## draws it; the box draws at the laid-out size. The margins (and the
## `uxml_margins` meta the measurers subtract) are put back when the box
## is large enough again. `start` and `end` are the element's insets.
## Called by both placements after the inset hook. Returns whether the
## Button is fitted (`uxml_bfit`).
func fit_button(c: Button, want: Vector2, start: Vector2, end: Vector2) -> bool:
	var sb := c.get_theme_stylebox(&"normal")
	if sb == null or not c.has_theme_stylebox_override(&"normal"):
		return false
	var cur := Vector2(sb.content_margin_left + sb.content_margin_right,
		sb.content_margin_top + sb.content_margin_bottom)
	var text := c.get_minimum_size() - cur
	var m := [start.x, start.y, end.x, end.y]  # left, top, right, bottom
	if want.y < start.y + end.y + text.y - 0.01:
		var top := clampf(start.y + (want.y - start.y - end.y - text.y) * 0.5, 0.0, start.y)
		m[1] = top
		m[3] = clampf(want.y - text.y - top, 0.0, end.y)
	if not c.clip_text and want.x < start.x + end.x + text.x - 0.01:
		var free := want.x - start.x - end.x - text.x
		var left := start.x
		var align = c.get(&"alignment")
		if align == null or int(align) == HORIZONTAL_ALIGNMENT_CENTER:
			left = start.x + free * 0.5
		elif int(align) == HORIZONTAL_ALIGNMENT_RIGHT:
			left = start.x + free
		left = clampf(left, 0.0, start.x)
		m[0] = left
		m[2] = clampf(want.x - text.x - left, 0.0, end.x)
	var fitted: bool = m != [start.x, start.y, end.x, end.y]
	if not fitted and not c.has_meta(&"uxml_bfit"):
		return false
	var seen := {}
	for slot in _stylebox_slots(c):
		if not c.has_theme_stylebox_override(slot):
			continue
		var s := c.get_theme_stylebox(slot)
		if s == null or seen.has(s):
			continue
		seen[s] = true
		if s.content_margin_left != m[0]:
			s.content_margin_left = m[0]
		if s.content_margin_top != m[1]:
			s.content_margin_top = m[1]
		if s.content_margin_right != m[2]:
			s.content_margin_right = m[2]
		if s.content_margin_bottom != m[3]:
			s.content_margin_bottom = m[3]
		s.set_meta("uxml_margins", [m[0], m[1], m[2], m[3]])
	if fitted:
		c.set_meta(&"uxml_bfit", true)
	else:
		c.remove_meta(&"uxml_bfit")
	c.update_minimum_size()
	c.size = want
	return fitted


## The height of a one-line Label with the font it has without fit_label:
## one line of that font plus the stylebox margins. fit_label and both
## measurers use it, so neither depends on when Godot updates the minimum
## size of the Label after a font change. The native measurer computes the
## same value (layout.rs, unfitted_height). The value is kept on the Label
## (`uxml_unfit`) until apply(), new insets or a best-fit font size drop it.
static func unfitted_height(c: Label) -> float:
	if c.has_meta(&"uxml_unfit"):
		return c.get_meta(&"uxml_unfit")
	var base: Font = c.get_theme_font(&"font")
	if c.has_meta(&"uxml_fit_base"):
		base = (c.get_meta(&"uxml_fit_base") as Array)[1]
	var fh := 0.0 if base == null else base.get_height(c.get_theme_font_size(&"font_size"))
	var sb := c.get_theme_stylebox(&"normal")
	var out := fh + (0.0 if sb == null else sb.get_minimum_size().y)
	c.set_meta(&"uxml_unfit", out)
	return out


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
			var rr := _resolver.resolve(path, _origin_file(e, el), "font")
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


## `force_box`: a UxmlBoxStyle even when StyleBoxFlat would draw the box
## the same (a background image goes between its fill and its border).
func _stylebox(style: Dictionary, el: UxmlElement, force_box := false) -> StyleBox:
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
			# On the pixel grid, as the layout lays the border out (and
			# Unity draws it: 1.5px draws 2px wide).
			w = UxmlFlexLayout.grid_box(maxf(0.0, p["value"]), true)
		elif p["kind"] == "invalid":
			_warn(el, "border-width", "border-%s-width: %s" % [_SIDES[k], p["problem"]])
		else:
			_warn(el, "border-width", "border-%s-width: only px is supported" % _SIDES[k])
		widths[k] = w
		any_border = any_border or w > 0.0
	var any_bcolor := false
	var first_bcolor: Variant = null
	# Unity's initial border colour is transparent (measured: a border
	# width without a colour draws nothing).
	var bcolors: Array[Color] = [Color.TRANSPARENT, Color.TRANSPARENT, Color.TRANSPARENT, Color.TRANSPARENT]
	var mixed := false
	for k in 4:
		if not style.has(_BC[k]):
			continue
		var c = _color(style, _BC[k], el)
		if c != null:
			any_bcolor = true
			bcolors[k] = c
			if first_bcolor == null:
				first_bcolor = c
	var drawn: Variant = null
	for k in 4:
		if widths[k] > 0.0:
			if drawn == null:
				drawn = bcolors[k]
			elif bcolors[k] != drawn:
				mixed = true
	if not mixed:
		# The colour of the drawn sides (StyleBoxFlat has one).
		for k in 4:
			if widths[k] > 0.0:
				first_bcolor = bcolors[k]
				break
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

	# StyleBoxFlat draws a box like Unity when its corners are square, its
	# drawn sides have one colour and it has no background under a border;
	# Unity's elliptic corners, per-side colours and the background under
	# the border (seen through a translucent border, or an opaque one at
	# an opacity below 1) need UxmlBoxStyle.
	if force_box or any_radius or mixed or (any_border and bg != null and bg.a > 0.0):
		var ub := UxmlBoxStyle.new()
		ub.bg_color = bg if bg != null else Color.TRANSPARENT
		ub.widths = widths.duplicate()
		ub.colors = bcolors
		ub.radii = radii.duplicate()
		_box_margins(ub, widths, pads)
		return ub
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg if bg != null else Color.TRANSPARENT
	sb.border_color = first_bcolor if first_bcolor != null else Color.TRANSPARENT
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
	sb.draw_center = bg != null
	return sb


## Content margins (border + padding) of a UxmlBoxStyle, as _stylebox
## gives a StyleBoxFlat.
static func _box_margins(sb: StyleBox, widths: PackedFloat64Array, pads: PackedFloat64Array) -> void:
	sb.content_margin_top = widths[0] + pads[0]
	sb.content_margin_right = widths[1] + pads[1]
	sb.content_margin_bottom = widths[2] + pads[2]
	sb.content_margin_left = widths[3] + pads[3]
	sb.set_meta("uxml_margins", [
		widths[3] + pads[3],
		widths[0] + pads[0],
		widths[1] + pads[1],
		widths[2] + pads[2],
	])


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
	if c.has_meta(&"uxml_maxc"):
		c.remove_meta(&"uxml_maxc")
	if c.has_meta(&"uxml_clip_full"):
		c.remove_meta(&"uxml_clip_full")
	if c.has_meta(&"uxml_unfit"):
		c.remove_meta(&"uxml_unfit")
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
		# Usually the stylebox already has these margins (_stylebox put the
		# USS px border + padding there): a write of the same value would
		# still emit `changed` and make the control update its minimum size
		# and theme (about 60 us per Label), so only differing sides are
		# written.
		if sb.content_margin_left != start.x:
			sb.content_margin_left = start.x
		if sb.content_margin_top != start.y:
			sb.content_margin_top = start.y
		if sb.content_margin_right != end.x:
			sb.content_margin_right = end.x
		if sb.content_margin_bottom != end.y:
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
		# Unity's initial -unity-text-align is upper-left (a Button's theme
		# rule sets middle-center; a RepeatButton has none).
		c.alignment = hv.x if has_align else HORIZONTAL_ALIGNMENT_LEFT
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
	"scale", "transform-origin", "cursor", "filter", "-unity-material",
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
	# Each call below returns at once when its property is absent and it
	# wrote nothing before; the same tests are made here first, because
	# overflow alone (the default theme clips many control parts) brings
	# most controls onto this path.
	if style.has("opacity") or c.modulate.a != 1.0:
		_apply_opacity(c, style, el)
	_apply_overflow(c, style, el)
	if (c.offset_transform_enabled or style.has("translate") or style.has("rotate")
			or style.has("scale") or style.has("transform-origin")):
		_apply_transform(c, style, el)
	if style.has("cursor") or c.has_meta(&"uxml_cursor_default"):
		_apply_cursor(c, native, style, el)
	if style.has("filter") or c.has_meta(&"uxml_filter"):
		_apply_filter(c, style, el)
	if style.has("-unity-material") or c.has_meta(&"uxml_mat_default"):
		_apply_material(c, native, style, el)


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
	if ov == "scroll" and el != null and el.part_of != null and str(el.get_attribute("class")).contains("unity-scroll-view__content-container"):
		# Unity's ScrollView content container is `scroll` for the layout
		# but does not clip (disableClipping); the viewport clips.
		hidden = false
	var had := c.has_meta(&"uxml_clip_default")
	if hidden or had:
		if not had:
			c.set_meta(&"uxml_clip_default", c.clip_contents)
		var want: bool = hidden or bool(c.get_meta(&"uxml_clip_default"))
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
	var clip = (c.get_meta(&"uxml_clip") if c.has_meta(&"uxml_clip") else null)
	# Unity clips to the rounded inner outline of a box with a radius.
	var radii := PackedFloat64Array()
	if hidden:
		for k in 4:
			var re = style.get(_BR[k])
			if re != null:
				var p := UssValues.parse_length(String(re["value"]))
				if p["kind"] == "px" and float(p["value"]) > 0.0:
					radii.resize(4)
					radii[k] = float(p["value"])
	if hidden and (inset != Vector4.ZERO or not radii.is_empty()):
		if clip == null:
			clip = UxmlClip.new(c)
			c.set_meta("uxml_clip", clip)
		clip.set_inset(inset)
		clip.set_radii(radii)
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
	# Most clipped controls have no border: absent entries skip the call.
	var e = style.get("border-top-width")
	var t := 0.0 if e == null else _px_of(e)
	e = style.get("border-right-width")
	var r := 0.0 if e == null else _px_of(e)
	e = style.get("border-bottom-width")
	var b := 0.0 if e == null else _px_of(e)
	e = style.get("border-left-width")
	var l := 0.0 if e == null else _px_of(e)
	if with_padding:
		e = style.get("padding-top")
		t += 0.0 if e == null else _px_of(e)
		e = style.get("padding-right")
		r += 0.0 if e == null else _px_of(e)
		e = style.get("padding-bottom")
		b += 0.0 if e == null else _px_of(e)
		e = style.get("padding-left")
		l += 0.0 if e == null else _px_of(e)
	return Vector4(l, t, r, b)


## A non-negative px length entry, else 0 (percentages are resolved by the
## layout, see apply_resolved_insets).
static func _px_of(e) -> float:
	if e == null:
		return 0.0
	var p := UssValues.parse_length(String(e["value"]))
	return maxf(0.0, p["value"]) if p["kind"] == "px" else 0.0


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


## filter (Unity 6.3) -> UxmlFilter: the element and its subtree draw into
## a canvas group with Unity's filter math (see UxmlFilter). Only controls
## whose style has `filter`, or had it, take this path.
func _apply_filter(c: Control, style: Dictionary, el: UxmlElement) -> void:
	var e = style.get("filter")
	var f = c.get_meta(&"uxml_filter") if c.has_meta(&"uxml_filter") else null
	if e == null and f == null:
		return
	var funcs: Array = []
	if e != null:
		var r := UssValues.parse_filter(String(e["value"]))
		if not r["ok"]:
			_warn(el, "filter", r["problem"])
		else:
			funcs = r["funcs"]
			for p in r["problems"]:
				_warn(el, "filter", p)
	if funcs.is_empty():
		if f != null:
			f.detach()
			c.remove_meta(&"uxml_filter")
			_filters.erase(c)
			_resolve_nesting()
		return
	var fresh := false
	if f == null:
		f = UxmlFilter.new(c)
		c.set_meta(&"uxml_filter", f)
		c.set_meta(&"uxml_el", el)
		_filters[c] = f
		fresh = true
	var scale := _pixel_scale(c)
	var custom = null
	for fn in funcs:
		if fn["name"] == "filter":
			custom = fn
			break
	if custom != null:
		if funcs.size() > 1:
			_warn_once_key("filter-custom-chain", el,
				"filter: a custom filter() function draws alone; the other functions of the list are not drawn")
		_apply_custom_filter(f, custom, e, el, scale)
	else:
		var ops: Array = []
		var pre := 0
		var sig2 := 0.0
		var margin := 0.0
		var blurred := false
		for fn in funcs:
			var p = fn["params"][0] if not fn["params"].is_empty() else 0.0
			if fn["name"] == "blur":
				var sg := maxf(0.0, UssValues.filter_float(p)) * scale
				sig2 += sg * sg
				margin += UxmlFilter.blur_margin(sg)
				blurred = blurred or sg > 0.0
				continue
			if ops.size() >= UxmlFilter.MAX_OPS:
				_warn_once_key("filter-too-many", el,
					"filter: more than %d color functions; the rest are not drawn" % UxmlFilter.MAX_OPS)
				break
			ops.append(UxmlFilter.color_effect(fn["name"], p))
			if not blurred:
				pre += 1
		f.set_builtin(ops, pre, sqrt(sig2), margin)
	if fresh:
		_resolve_nesting()


## The interpolation defaults of the custom filter function `ref` (the
## transition system pads a shorter filter list with them).
func filter_interpolation_defaults(ref: String, e: Dictionary, el: UxmlElement) -> Array:
	var d := _filter_def(ref, e, el)
	return [] if d == null else d.interpolation_defaults


## Render-target pixels per USS pixel at the control (Unity scales the blur
## sigma by the panel's pixels per point).
static func _pixel_scale(c: Control) -> float:
	if not c.is_inside_tree():
		return 1.0
	var t := c.get_viewport().get_final_transform() * c.get_global_transform_with_canvas()
	var d := absf(t.determinant())
	return sqrt(d) if d > 0.0 else 1.0


## A custom function: its UxmlFilterDefinition's material (one copy per
## element, so each element binds its own parameters).
func _apply_custom_filter(f: UxmlFilter, fn: Dictionary, e: Dictionary, el: UxmlElement, scale: float) -> void:
	var def: UxmlFilterDefinition = _filter_def(String(fn["ref"]), e, el)
	if def == null or def.material == null:
		f.set_custom(null, 0.0)
		f.set_builtin([], 0, 0.0, 0.0)
		return
	var inst: Material = f.get_meta(&"uxml_custom_mat") if f.has_meta(&"uxml_custom_mat") else null
	if inst == null or f.get_meta(&"uxml_custom_def") != def:
		inst = def.material.duplicate()
		f.set_meta(&"uxml_custom_mat", inst)
		f.set_meta(&"uxml_custom_def", def)
	var params: Array = fn["params"]
	var n := def.parameter_names.size()
	if params.size() > n and n > 0:
		_warn_once_key("filter-extra", el, "filter: %s takes %d parameters; the extra ones are ignored" % [fn["ref"], n])
	for i in n:
		var dflt = def.interpolation_defaults[i] if i < def.interpolation_defaults.size() else 0.0
		var v = params[i] if i < params.size() else dflt
		# Unity resets a parameter of the wrong type to its default.
		if (v is Color) != (dflt is Color):
			v = dflt
		_set_param(inst, def.parameter_names[i], v)
	var m := def.margins
	f.set_custom(inst, maxf(maxf(m.x, m.y), maxf(m.z, m.w)) * scale)


## The UxmlFilterDefinition a filter() reference names (see
## UxmlFilterDefinition for the Unity -> Godot mapping). Cached per path.
func _filter_def(ref: String, e: Dictionary, el: UxmlElement) -> UxmlFilterDefinition:
	var res = _load_godot_resource(ref, e, el, "filter", ["tres", "res", "gdshader"], _def_cache)
	if res == null:
		return null
	if res is UxmlFilterDefinition:
		return res
	var hit = _def_wrap.get(res)
	if hit != null:
		return hit
	var mat = res
	if res is Shader:
		mat = ShaderMaterial.new()
		mat.shader = res
	if mat is Material:
		var d := UxmlFilterDefinition.from_material(mat)
		_def_wrap[res] = d
		return d
	_warn_diag("missing-file", "filterdef:%s:%s" % [ref, el.get_instance_id()], el,
		'filter: "%s" is not a UxmlFilterDefinition, ShaderMaterial or Shader' % ref)
	return null


## Loads the Godot resource for a Unity asset reference: the resolved file
## when Godot can load it, else the same path with each extension of
## `alt` (a Unity .asset or .mat file has a Godot .tres beside it).
func _load_godot_resource(ref: String, e: Dictionary, el: UxmlElement, kind: String,
		alt: Array, cache: Dictionary) -> Variant:
	var u := UssValues.parse_url(ref)
	if not u["ok"]:
		_warn(el, kind, '%s "%s": %s' % [kind, ref, u["problem"]])
		return null
	var r := _resolver.resolve(u["path"], _origin_file(e, el), kind)
	if not r["ok"]:
		_report_resolver(r, el, '%s "%s"' % [kind, ref])
		return null
	var path: String = r["path"]
	if cache.has(path):
		return cache[path]
	var cands: Array = [path]
	for x in alt:
		var cand: String = path.get_basename() + "." + x
		if not cands.has(cand):
			cands.append(cand)
	var res = null
	for cand in cands:
		if ResourceLoader.exists(cand):
			res = ResourceLoader.load(cand)
			if res != null:
				break
	if res == null:
		_warn_diag("missing-file", "%s:%s:%s" % [kind, path, el.get_instance_id()], el,
			'%s "%s" resolved to %s, but no Godot resource is there (tried %s)' % [
				kind, ref, path, ", ".join(PackedStringArray(cands))])
	cache[path] = res
	return res


## Sets a shader parameter named after a Unity property: the name as
## written, else without a leading underscore, else in lower case (Unity
## shader properties are usually `_Name`). Converts vectors and colors to
## the uniform's type.
func _set_param(mat: Material, name: String, value) -> void:
	var sm := mat as ShaderMaterial
	if sm == null or sm.shader == null:
		return
	var u: Dictionary = _uniforms.get(sm.shader, {})
	if u.is_empty():
		for d in sm.shader.get_shader_uniform_list():
			u[String(d["name"])] = int(d.get("type", TYPE_NIL))
		_uniforms[sm.shader] = u
	var key := name
	if not u.has(key):
		for cand in [name.trim_prefix("_"), name.trim_prefix("_").to_lower(), name.trim_prefix("_").to_snake_case()]:
			if u.has(cand):
				key = cand
				break
	var t: int = u.get(key, TYPE_NIL)
	var v = value
	if value is Vector4:
		match t:
			TYPE_VECTOR2:
				v = Vector2(value.x, value.y)
			TYPE_VECTOR3:
				v = Vector3(value.x, value.y, value.z)
			TYPE_COLOR:
				v = Color(value.x, value.y, value.z, value.w)
			TYPE_FLOAT:
				v = value.x
	elif value is Color:
		match t:
			TYPE_VECTOR3:
				v = Vector3(value.r, value.g, value.b)
			TYPE_VECTOR4:
				v = Vector4(value.r, value.g, value.b, value.a)
	elif value is float and t == TYPE_INT:
		v = int(value)
	sm.set_shader_parameter(key, v)


## Godot does not nest canvas groups: a filter inside a filtered ancestor,
## and a blurred text shadow inside a filtered element, are turned off (the
## shadow then draws sharp) and diagnosed.
func _resolve_nesting() -> void:
	for c in _filters.keys():
		if not is_instance_valid(c):
			_filters.erase(c)
	for c in _shadows.keys():
		if not is_instance_valid(c):
			_shadows.erase(c)
	for c in _filters:
		var nested := _filtered_ancestor(c.get_parent())
		_filters[c].set_enabled(not nested)
		if nested:
			_nest_warn(c, "filter: Godot does not nest canvas groups; this filter inside a filtered element is not drawn")
	for c in _shadows:
		var nested2 := _filtered_ancestor(c)
		_shadows[c].set_enabled(not nested2)
		_sharp_shadow(c, nested2)
		if nested2:
			_nest_warn(c, "text-shadow: the blur is not drawn inside a filtered element (Godot does not nest canvas groups); the shadow is drawn sharp")


func _filtered_ancestor(n: Node) -> bool:
	while n != null:
		if _filters.has(n):
			return true
		n = n.get_parent()
	return false


func _nest_warn(c: Control, message: String) -> void:
	var el = c.get_meta(&"uxml_el") if c.has_meta(&"uxml_el") else null
	if el != null:
		_warn_once_key("nest:" + message.substr(0, 12), el, message)


## -unity-material (Unity 6.3) -> CanvasItem.material on the element's
## controls (the value inherits, so descendants get it too, as in Unity).
## prop() values go to a per-control copy of the material.
func _apply_material(c: Control, native: Control, style: Dictionary, el: UxmlElement) -> void:
	var e = style.get("-unity-material")
	if e == null and not c.has_meta(&"uxml_mat_default"):
		return
	if not c.has_meta(&"uxml_mat_default"):
		c.set_meta(&"uxml_mat_default", [c.material, native.material])
	var defaults: Array = c.get_meta(&"uxml_mat_default")
	var mat: Material = null
	var set_any := false
	if e != null:
		var r := UssValues.parse_material(String(e["value"]))
		if not r["ok"]:
			_warn(el, "-unity-material", r["problem"])
		elif not String(r["ref"]).is_empty():
			var base = _load_godot_resource(String(r["ref"]), e, el, "material",
				["tres", "res", "material", "gdshader"], _mat_cache)
			if base is Shader:
				var sm = _mat_wrap.get(base)
				if sm == null:
					sm = ShaderMaterial.new()
					sm.shader = base
					_mat_wrap[base] = sm
				base = sm
			if base is Material:
				set_any = true
				mat = base
				var props: Array = r["props"]
				if not props.is_empty():
					var inst = c.get_meta(&"uxml_mat_inst") if c.has_meta(&"uxml_mat_inst") else null
					if inst == null or inst[0] != base:
						inst = [base, base.duplicate()]
						c.set_meta(&"uxml_mat_inst", inst)
					mat = inst[1]
					for pr in props:
						var v = pr["value"]
						match String(pr["type"]):
							"vector":
								v = Vector4(v[0], v[1], v[2], v[3])
							"texture":
								v = _texture_ref(String(v), e, "-unity-material", el)
						_set_param(mat, String(pr["name"]), v)
			elif base != null:
				_warn(el, "-unity-material", '-unity-material: "%s" is not a Godot Material or Shader' % r["ref"])
	var m0: Material = mat if set_any else defaults[0]
	var m1: Material = mat if set_any else defaults[1]
	if c.material != m0:
		c.material = m0
	if native != c and native.material != m1:
		native.material = m1
	if c is UxmlField:
		var cap: Control = c.caption_node()
		if cap != null and cap.use_parent_material != set_any:
			cap.use_parent_material = set_any


# ---------------------------------------------------------------------------
# Text effects: shadow, paragraph spacing, elision, rich text
# ---------------------------------------------------------------------------

## text-shadow -> Label / RichTextLabel font shadow. Godot draws a sharp
## shadow; a Label with a blur radius gets a UxmlTextShadow (a blurred copy
## of the text, sigma = blur / 2 as in CSS). A rich text Label draws the
## shadow sharp and the blur is diagnosed. Other controls have no text
## shadow; that is diagnosed only where the element declares the property
## itself (it inherits, so containers pass it down to everything).
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
	var blur := 0.0 if sh == null else float(sh["blur"])
	var soft = c.get_meta(&"uxml_shadow") if c.has_meta(&"uxml_shadow") else null
	if blur > 0.0 and c is RichTextLabel:
		_warn_once_key("text-shadow-blur", el,
			"text-shadow blur radius is not drawn on rich text; the shadow is drawn sharp")
	elif blur > 0.0:
		if soft == null:
			soft = UxmlTextShadow.new(c)
			c.set_meta(&"uxml_shadow", soft)
			c.set_meta(&"uxml_el", el)
			_shadows[c] = soft
			_resolve_nesting()
		soft.set_shadow(sh["color"], sh["offset"], blur * 0.5)
		c.set_meta(&"uxml_shadow_sharp", [sh["color"], sh["offset"]])
		_sharp_shadow(c, not soft.enabled)
		return
	if soft != null:
		soft.detach()
		c.remove_meta(&"uxml_shadow")
		c.remove_meta(&"uxml_shadow_sharp")
		_shadows.erase(c)
	if sh != null:
		_theme_shadow(c, sh["color"], sh["offset"])
	elif c.has_theme_color_override("font_shadow_color"):
		_theme_shadow(c, null, Vector2.ZERO)


## Godot's own (sharp) font shadow: color null removes it.
static func _theme_shadow(c: Control, color, offset: Vector2) -> void:
	if color != null:
		c.add_theme_color_override("font_shadow_color", color)
		c.add_theme_constant_override("shadow_offset_x", roundi(offset.x))
		c.add_theme_constant_override("shadow_offset_y", roundi(offset.y))
		c.add_theme_constant_override("shadow_outline_size", 0)
	else:
		c.remove_theme_color_override("font_shadow_color")
		for k in ["shadow_offset_x", "shadow_offset_y", "shadow_outline_size"]:
			if c.has_theme_constant_override(k):
				c.remove_theme_constant_override(k)


## A blurred-shadow Label draws the theme shadow (sharp) only while its blur
## group is off (inside a filtered element).
static func _sharp_shadow(c: Control, on: bool) -> void:
	var spec = c.get_meta(&"uxml_shadow_sharp") if c.has_meta(&"uxml_shadow_sharp") else null
	if on and spec != null:
		_theme_shadow(c, spec[0], spec[1])
	elif c.has_theme_color_override("font_shadow_color"):
		_theme_shadow(c, null, Vector2.ZERO)


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
## update_elision's last pass per control: [text, width, position, font size].
var _elide_memo := {}


func _apply_elision(c: Control, style: Dictionary, el: UxmlElement) -> void:
	_elide_memo.erase(c)
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
func update_elision(only: Array = []) -> void:
	# This runs after every layout: the common case (nothing changed) is
	# kept to the memo test, without copying the keys.
	var gone: Array = []
	for c in (elide if only.is_empty() else only):
		if only.size() > 0 and not elide.has(c):
			continue
		if not is_instance_valid(c):
			gone.append(c)
			continue
		# Nothing to redo when the width, the text and the position are
		# those of the last pass (an apply of the control forgets the memo:
		# a style can change the font).
		var memo = _elide_memo.get(c)
		if (memo != null and memo[1] == c.size.x and memo[0] == c.get(&"text") and memo[2] == elide[c]
				and memo[3] == c.get_theme_font_size(&"font_size")):
			continue
		_elide_one(c)
	for c in gone:
		elide.erase(c)
		_elide_memo.erase(c)


func _elide_one(c: Control) -> void:
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
	_elide_memo[c] = [String(c.get("text")), c.size.x, elide[c], fs]


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
