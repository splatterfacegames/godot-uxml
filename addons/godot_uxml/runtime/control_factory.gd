class_name UxmlControlFactory
extends RefCounted
## Turns UxmlElement tags into native Godot controls.
##
## The mapping (also documented in docs/design.md):
##
##   VisualElement / unknown tag -> UxmlBox (styled rectangle, real Control)
##   Label        -> Label
##   Button       -> Button
##   Image        -> UxmlBox host wrapping a full-rect TextureRect, so
##                   background-color/borders still paint behind the image
##   Slider       -> UxmlField(Label caption + HSlider)
##   SliderInt    -> UxmlField(Label caption + HSlider, step/rounded 1)
##   ScrollView   -> UxmlBox host wrapping ScrollContainer + content Control
##   Toggle       -> CheckBox (its built-in caption is the label)
##   TextField    -> UxmlField(Label caption + LineEdit, or TextEdit when
##                   multiline="true")
##   DropdownField-> UxmlField(Label caption + OptionButton)
##
## "Wrapper" elements (UxmlField, Image/ScrollView hosts) are what
## UxmlDocument.get_element(name) returns; the interactive native inside is
## registered in `natives` and returned by get_native(name).
##
## Attributes consumed here: name, tooltip, focusable, text, label, value,
## low-value, high-value, choices, index, src, image, placeholder-text,
## max-length, readonly, multiline, mask-char. enabled is a runtime state
## (handled by the document/applier), style/class belong to the cascade.
## Invalid attribute values produce an `unsupported-value` diagnostic and a
## fallback, never a crash.

var _resolver: UxmlResourceResolver
var _uxml_path: String
var _source: String
var _warnings: Array
var _warned: Dictionary = {}

## element -> outer Control (what flex positions)
var controls: Dictionary = {}
## element -> innermost interactive native Control (defaults to outer)
var natives: Dictionary = {}
## ScrollView element -> its scroll content Control (children's parent)
var scroll_contents: Dictionary = {}


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


## Build the control subtree for `el` and register it in `controls`.
## Children are created recursively and parented to the control that hosts
## them (the element itself, or its scroll content).
func build(el: UxmlElement) -> Control:
	var c := _create(el)
	controls[el] = c
	if not natives.has(el):
		natives[el] = c
	_apply_common_attributes(el, c)
	# The applier restores these when visibility/disabled states clear.
	for cc in [c, natives[el]]:
		cc.set_meta("uxml_mouse", cc.mouse_filter)
		cc.set_meta("uxml_focus", cc.focus_mode)
		if cc is LineEdit or cc is TextEdit:
			# Authored editable state — readonly must survive disable/
			# re-enable and every restyle.
			cc.set_meta("uxml_editable", cc.editable)

	var host: Control = scroll_contents.get(el, c)
	for child in el.children:
		if UssControls.is_non_visual(child.local):
			continue
		host.add_child(build(child))
	return c


# ---------------------------------------------------------------------------
# Per-tag construction
# ---------------------------------------------------------------------------

func _create(el: UxmlElement) -> Control:
	match el.local:
		"Label":
			var l := Label.new()
			l.text = _attr(el, "text")
			return l
		"Button":
			var b := Button.new()
			b.text = _attr(el, "text")
			b.focus_mode = Control.FOCUS_ALL
			return b
		"Image":
			return _create_image(el)
		"Slider", "SliderInt":
			return _create_slider(el, el.local == "SliderInt")
		"ScrollView", "ListView":
			return _create_scroll(el)
		"Toggle":
			var t := CheckBox.new()
			var caption := _first_attr(el, ["label", "text"])
			t.text = caption
			t.button_pressed = _bool_attr(el, "value", false)
			t.focus_mode = Control.FOCUS_ALL
			return t
		"TextField":
			return _create_text_field(el)
		"DropdownField":
			return _create_dropdown(el)
		_:
			# VisualElement and every unmapped tag: a styled box. Children
			# are preserved by the caller.
			return UxmlBox.new()


func _create_image(el: UxmlElement) -> Control:
	var box := UxmlBox.new()
	var tr := TextureRect.new()
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Unity's Image defaults to ScaleToFit: keep aspect, centered.
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(tr)

	var ref := _first_attr(el, ["src", "image"])
	if not ref.is_empty():
		var tex := _load_texture(ref, el)
		if tex != null:
			tr.texture = tex
			# The texture size is the intrinsic MEASURE, not a hard floor —
			# natural_size feeds the flex measure without clamping the
			# laid-out box the way custom_minimum_size would.
			box.natural_size = tex.get_size()
	natives[el] = tr
	return box


func _create_slider(el: UxmlElement, integer: bool) -> Control:
	var s := HSlider.new()
	s.min_value = _num_attr(el, "low-value", 0.0)
	s.max_value = _num_attr(el, "high-value", 100.0)
	if integer:
		s.step = 1.0
		s.rounded = true
	s.value = clampf(
		_num_attr(el, "value", s.min_value), s.min_value, s.max_value
	)
	s.focus_mode = Control.FOCUS_ALL
	var f := UxmlField.new(s, _first_attr(el, ["label"]))
	natives[el] = s
	return f


func _create_scroll(el: UxmlElement) -> Control:
	var box := UxmlBox.new()
	var sc := ScrollContainer.new()
	sc.set_anchors_preset(Control.PRESET_FULL_RECT)
	sc.follow_focus = true
	sc.focus_mode = Control.FOCUS_ALL
	var content := Control.new()
	content.name = "uxml-scroll-content"
	content.mouse_filter = Control.MOUSE_FILTER_PASS
	sc.add_child(content)
	box.add_child(sc)
	scroll_contents[el] = content
	natives[el] = sc
	return box


func _create_text_field(el: UxmlElement) -> Control:
	var field: Control
	var multiline := _attr(el, "multiline") == "true"
	if el.has_attribute("multiline") and not multiline and _attr(el, "multiline") != "false":
		_warn(el, "multiline", 'multiline="%s" is not a valid bool; treated as false' % _attr(el, "multiline"))
	if multiline:
		var te := TextEdit.new()
		te.text = _attr(el, "value")
		te.placeholder_text = _attr(el, "placeholder-text")
		te.editable = not _bool_attr(el, "readonly", false)
		te.focus_mode = Control.FOCUS_ALL
		field = te
	else:
		var le := LineEdit.new()
		le.text = _attr(el, "value")
		le.placeholder_text = _attr(el, "placeholder-text")
		if el.has_attribute("max-length"):
			le.max_length = int(_num_attr(el, "max-length", 0.0))
		le.editable = not _bool_attr(el, "readonly", false)
		if el.has_attribute("mask-char"):
			var mask := _attr(el, "mask-char")
			le.secret = true
			le.secret_character = mask if not mask.is_empty() else "*"
		le.focus_mode = Control.FOCUS_ALL
		field = le
	var f := UxmlField.new(field, _first_attr(el, ["label"]))
	natives[el] = field
	return f


func _create_dropdown(el: UxmlElement) -> Control:
	var ob := OptionButton.new()
	var raw := _attr(el, "choices")
	var choices: Array = []
	if not raw.is_empty():
		for part in raw.split(","):
			choices.append(String(part).strip_edges())
	for item in choices:
		ob.add_item(String(item))
	# `value` selects by choice text (Unity DropdownField.value is a string —
	# "1080" means the item whose text is 1080, not item index 1080).
	# `index` selects by position and wins when both are present.
	var selected := -1
	if el.has_attribute("index"):
		selected = int(_num_attr(el, "index", -1.0))
		if selected < 0 or selected >= choices.size():
			_warn(el, "index", 'index="%d" is out of range; first item selected' % selected)
			selected = 0 if choices.size() > 0 else -1
	elif el.has_attribute("value"):
		selected = choices.find(_attr(el, "value"))
		if selected < 0:
			_warn(el, "value", 'value="%s" matches no choice; first item selected' % _attr(el, "value"))
			selected = 0 if choices.size() > 0 else -1
	if selected >= 0:
		ob.selected = selected
	ob.focus_mode = Control.FOCUS_ALL
	var f := UxmlField.new(ob, _first_attr(el, ["label"]))
	natives[el] = ob
	return f


# ---------------------------------------------------------------------------
# Shared attributes and resources
# ---------------------------------------------------------------------------

func _apply_common_attributes(el: UxmlElement, c: Control) -> void:
	var tooltip := _attr(el, "tooltip")
	if not tooltip.is_empty():
		c.tooltip_text = tooltip
	# `focusable` applies to the actual focus target — for wrapped controls
	# (Slider/TextField/DropdownField/ScrollView/Image) that is the inner
	# native, not the wrapper. The wrapper itself never becomes a tab stop,
	# so focusable="true" cannot add one and focusable="false" genuinely
	# removes the element from focus navigation.
	var target: Control = natives.get(el, c)
	if el.has_attribute("focusable"):
		target.focus_mode = (
			Control.FOCUS_ALL if _attr(el, "focusable") == "true"
			else Control.FOCUS_NONE
		)
	elif c is UxmlBox or c is Label:
		c.focus_mode = Control.FOCUS_NONE
	if target != c:
		c.focus_mode = Control.FOCUS_NONE


func _attr(el: UxmlElement, name: String, default: String = "") -> String:
	var v = el.get_attribute(name)
	return default if v == null else String(v)


func _first_attr(el: UxmlElement, names: Array) -> String:
	for n in names:
		var v = el.get_attribute(n)
		if v != null and not String(v).is_empty():
			return String(v)
	return ""


func _bool_attr(el: UxmlElement, name: String, default: bool) -> bool:
	var v = el.get_attribute(name)
	if v == null:
		return default
	match String(v).to_lower():
		"true", "1":
			return true
		"false", "0":
			return false
		_:
			_warn(el, name, '"%s" is not a valid bool for %s; %s used' % [v, name, default])
			return default


func _num_attr(el: UxmlElement, name: String, default: float) -> float:
	var v = el.get_attribute(name)
	if v == null:
		return default
	var n := UssValues.parse_number(String(v))
	if is_nan(n):
		_warn(el, name, '"%s" is not a number for %s; %s used' % [v, name, default])
		return default
	return n


## Load a texture through the project-root sandbox. res:// files come
## through ResourceLoader (imported assets); anything readable as an image
## file (user://, unpacked trees) falls back to Image.load. A reference that
## resolves but cannot be decoded still reports missing-file: the resource
## is explicitly absent, not silently skipped.
func _load_texture(ref: String, el: UxmlElement) -> Texture2D:
	var r := _resolver.resolve(ref, _uxml_path)
	if not r["ok"]:
		_report_resolver(r, el, 'image reference "%s"' % ref)
		return null
	var path: String = r["path"]
	if ResourceLoader.exists(path):
		var res := ResourceLoader.load(path)
		if res is Texture2D:
			return res
	elif FileAccess.file_exists(path):
		# Only hand real paths to the image loader — a missing file prints a
		# generic engine ERROR instead of our structured diagnostic.
		var img := Image.new()
		if img.load(path) == OK:
			return ImageTexture.create_from_image(img)
	_warnings.append(UxmlDiagnostic.make(
		"missing-file",
		'image "%s" resolved to %s but is not a readable texture' % [ref, path],
		_source, el.open_tag_start, _uxml_path
	))
	return null


func _report_resolver(res: Dictionary, el: UxmlElement, what: String) -> void:
	var d: Dictionary = res["diagnostic"]
	_warnings.append(UxmlDiagnostic.make(
		d.get("kind", "missing-file"),
		"%s could not be resolved: %s" % [what, d.get("message", "")],
		_source, el.open_tag_start, _uxml_path
	))


func _warn(el: UxmlElement, attr: String, message: String) -> void:
	var key := "%s:%s" % [attr, message]
	if _warned.has(key):
		return
	_warned[key] = true
	_warnings.append(UxmlDiagnostic.make(
		"unsupported-value", message, _source, el.open_tag_start, _uxml_path
	))
