class_name UxmlControlFactory
extends RefCounted
## Turns UxmlElement tags into native Godot controls.
##
## The mapping (also documented in docs/design.md):
##
##   VisualElement / unknown tag -> UxmlBox (styled rectangle, real Control)
##   Label, TextElement, text parts
##                -> Label, or RichTextLabel when its text holds Unity rich
##                   text tags (enable-rich-text, default true)
##   Button       -> Button (its look comes from USS: every stylebox slot;
##                   rich text tags are removed from its text)
##   RepeatButton -> UxmlRepeatButton (Button that repeats while held)
##   Toggle, RadioButton (and a Foldout's toggle part) -> UxmlToggle
##   PopupWindow  -> Label (draws its title; the content part is a child)
##   GroupBox, HelpBox, Foldout, ProgressBar,
##   RadioButtonGroup, ToggleButtonGroup, Box, TemplateContainer and every
##   container part -> UxmlBox
##   Image        -> UxmlBox host wrapping a full-rect TextureRect, so
##                   background-color/borders still paint behind the image
##   Slider, SliderInt, MinMaxSlider -> UxmlSlider (focusable box; its parts
##                   are boxes, runtime/controls/uxml_input_parts.gd)
##   DropdownField, EnumField -> UxmlPopupField (focusable box, opens
##                   UxmlPopupMenu)
##   TextField, the numeric and composite fields -> UxmlBox; the text
##                   element part of a text field is the Godot LineEdit
##                   (TextEdit when multiline="true"), see UxmlTextInput
##   ScrollView, Scroller, ListView, TreeView, MultiColumnListView,
##   MultiColumnTreeView, TabView, Tab, TwoPaneSplitView
##                -> UxmlBox (their Unity part trees, UxmlContainerParts)
##   IMGUIContainer -> UxmlImguiBox (hosts a Godot draw callback)
##
## Control parts (UxmlParts) are ordinary elements here: each gets its own
## control. Parts never take focus; parts Unity does not pick (checkmarks,
## text labels) ignore the mouse, the others pass it to their control.
##
## "Wrapper" elements (Image hosts, text fields) are what
## UxmlDocument.get_element(name) returns; the interactive native inside is
## registered in `natives` and returned by get_native(name).
##
## Attributes consumed here: name, tooltip, focusable, text, src, image,
## enable-rich-text, parse-escape-sequences, display-tooltip-when-elided;
## the input controls read theirs in UxmlInputParts, UxmlTextInput and
## UxmlInputBehaviors. enabled is a runtime state
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
## Element cloned from a template file -> that file's path
## (UxmlDocumentModel.element_paths); relative image references in such an
## element resolve against its own file.
var element_paths: Dictionary = {}


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
## them (the element itself).
func build(el: UxmlElement) -> Control:
	var c := _create(el)
	if el.part_of != null:
		_part_input(el, c)
	controls[el] = c
	if not natives.has(el):
		natives[el] = c

	var host: Control = c
	for child in el.children:
		if UssControls.is_non_visual(child.local):
			continue
		host.add_child(build(child))
	# A text field's interactive control is the editor of its text element
	# part (get_native, focus and hover wiring).
	if NUMERIC_OR_TEXT.has(el.local):
		var ed := UxmlParts.find_part(el, "editor")
		if ed != null and controls.has(ed):
			natives[el] = controls[ed]
	_apply_common_attributes(el, c)
	# The applier restores these when visibility/disabled states clear.
	for cc in [c, natives[el]]:
		cc.set_meta("uxml_mouse", cc.mouse_filter)
		cc.set_meta("uxml_focus", cc.focus_mode)
		if cc is LineEdit or cc is TextEdit:
			# Authored editable state — readonly must survive disable/
			# re-enable and every restyle.
			cc.set_meta("uxml_editable", cc.editable)
	return c


## Fields whose native is the editor of their text element part.
const NUMERIC_OR_TEXT := {
	"TextField": true, "IntegerField": true, "LongField": true, "FloatField": true,
	"DoubleField": true, "UnsignedIntegerField": true, "UnsignedLongField": true,
	"Hash128Field": true,
}


# ---------------------------------------------------------------------------
# Per-tag construction
# ---------------------------------------------------------------------------

func _create(el: UxmlElement) -> Control:
	if el.part_of != null:
		if el.part_role == "editor":
			return UxmlTextInput.create(el)
		if el.has_meta(UxmlEditorParts.META_WIDGET):
			return UxmlEditorWidgets.part_control(el)
	match el.local:
		"Label":
			var text := _text_attr(el)
			if _bool_attr(el, "enable-rich-text", true):
				var pr := UxmlRichText.parse(text)
				if pr["rich"]:
					return _create_rich_label(el, text, pr)
			var l := Label.new()
			l.text = text
			_text_element_attrs(el, l)
			return l
		"Button":
			var b := Button.new()
			b.text = _plain_text_attr(el)
			b.focus_mode = Control.FOCUS_ALL
			_text_element_attrs(el, b)
			return b
		"Image":
			return _create_image(el)
		"Slider", "SliderInt", "MinMaxSlider":
			return UxmlSlider.new()
		"DropdownField", "EnumField":
			return UxmlPopupField.new()
		"IMGUIContainer":
			return UxmlImguiBox.new()
		"Toggle", "RadioButton":
			var t := UxmlToggle.new()
			t.radio = el.local == "RadioButton"
			t.set_pressed_no_signal(_bool_attr(el, "value", false))
			return t
		"RepeatButton":
			var rb := UxmlRepeatButton.new()
			rb.text = _plain_text_attr(el)
			_text_element_attrs(el, rb)
			rb.configure(_num_attr(el, "delay", 0.0), _num_attr(el, "interval", 0.0))
			return rb
		"TextElement", "PopupWindow", "PopupTextElement":
			# PopupWindow is a TextElement: it draws its own title text in
			# its content box; its content container part is a child.
			var te := Label.new()
			te.text = _plain_text_attr(el)
			_text_element_attrs(el, te)
			return te
		"VisualElement", "TemplateContainer":
			return UxmlBox.new()
		_:
			# Editor controls (UnityEditor.UIElements): uxml_editor_widgets.gd.
			var ec := UxmlEditorWidgets.create_control(el, self)
			if ec != null:
				return ec
			# Every unmapped tag: a styled box. Children are preserved by
			# the caller.
			return UxmlBox.new()


## The `text` attribute, with \n \t \uXXXX ... decoded when
## parse-escape-sequences is true (Unity's default is false).
func _text_attr(el: UxmlElement) -> String:
	var t := _attr(el, "text")
	if t.find("\\") >= 0 and _bool_attr(el, "parse-escape-sequences", false):
		t = UxmlRichText.unescape(t)
	return t


## The `text` attribute for a control that draws its own plain text (Button,
## RepeatButton, PopupWindow title): Unity rich text tags are removed, with
## a diagnostic, because these Godot controls cannot draw styled runs.
func _plain_text_attr(el: UxmlElement) -> String:
	var t := _text_attr(el)
	if _bool_attr(el, "enable-rich-text", true):
		var pr := UxmlRichText.parse(t)
		if pr["rich"]:
			_warn(el, "text", "rich text tags on a %s: the Godot control draws plain text, so the tags are removed" % el.local)
			t = pr["plain"]
	return t


## TextElement attributes the runtime reads later (applier elision).
func _text_element_attrs(el: UxmlElement, c: Control) -> void:
	if el.has_attribute("display-tooltip-when-elided"):
		c.set_meta("uxml_tooltip_elided", _bool_attr(el, "display-tooltip-when-elided", true))


## A Label whose text holds rich text tags: a RichTextLabel that sizes to
## its content (fit_content) and behaves like a Label otherwise: no
## scrolling, no selection, no wrap until white-space asks for it, and
## mouse input only when it has links (meta_clicked).
func _create_rich_label(el: UxmlElement, text: String, pr: Dictionary) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = false
	r.fit_content = true
	r.scroll_active = false
	r.selection_enabled = false
	r.context_menu_enabled = false
	r.shortcut_keys_enabled = false
	r.autowrap_mode = TextServer.AUTOWRAP_OFF
	r.meta_underlined = false
	r.focus_mode = Control.FOCUS_NONE
	var has_link := false
	for op in pr["ops"]:
		if op[0] == "+" and (op[1] == "link" or op[1] == "a"):
			has_link = true
			break
	r.mouse_filter = Control.MOUSE_FILTER_STOP if has_link else Control.MOUSE_FILTER_IGNORE
	r.set_meta("uxml_rich", pr)
	r.set_meta("uxml_rich_src", text)
	r.add_text(pr["plain"])  # until the applier renders the styled runs
	for tag in pr["dropped"]:
		_warn(el, "text", "rich text tag <%s> is not supported; its text is drawn without the effect" % tag)
	_text_element_attrs(el, r)
	return r


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




# ---------------------------------------------------------------------------
# Shared attributes and resources
# ---------------------------------------------------------------------------

func _apply_common_attributes(el: UxmlElement, c: Control) -> void:
	var tooltip := _attr(el, "tooltip")
	if not tooltip.is_empty():
		c.tooltip_text = tooltip
	# `focusable` applies to the actual focus target — for wrapped controls
	# (Slider/TextField/DropdownField/Image) that is the inner
	# native, not the wrapper. The wrapper itself never becomes a tab stop,
	# so focusable="true" cannot add one and focusable="false" genuinely
	# removes the element from focus navigation.
	var target: Control = natives.get(el, c)
	if el.has_attribute("focusable"):
		target.focus_mode = (
			Control.FOCUS_ALL if _attr(el, "focusable") == "true"
			else Control.FOCUS_NONE
		)
	elif (c is UxmlBox and not (c is UxmlToggle or c is UxmlSlider or c is UxmlPopupField or c is UxmlImguiBox)) \
			or c is Label or c is RichTextLabel:
		c.focus_mode = Control.FOCUS_NONE
	if target != c:
		c.focus_mode = Control.FOCUS_NONE


## Container and collection parts that Unity does not pick
## (UxmlContainerParts).
const UNPICKED_CONTAINER_PARTS := ["viewport", "slider", "sort-indicator", "sort-arrow",
	"sort-index", "column-content", "column-icon", "column-title", "column-container",
	"resize-handle-container", "content-viewport", "header-label", "header-image",
	"header-underline", "reorderable-handle-bar"]


## Parts never take focus (Unity delegates it to the control), except the
## interactive parts that are controls themselves (a Foldout's Toggle).
## Unity does not pick a Toggle's checkmark or text label; those ignore the
## mouse so the control under them receives it.
func _part_input(el: UxmlElement, c: Control) -> void:
	if c is UxmlToggle or c is BaseButton or c is LineEdit or c is TextEdit 			or c is UxmlSlider or c is UxmlPopupField:
		return
	c.focus_mode = Control.FOCUS_NONE
	match el.part_role:
		"checkmark", "text", "checkmark-background", "title", "title-container", "progress", "icon", "arrow":
			c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_:
			if UNPICKED_CONTAINER_PARTS.has(el.part_role):
				c.mouse_filter = Control.MOUSE_FILTER_IGNORE
			else:
				c.mouse_filter = Control.MOUSE_FILTER_PASS


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
	var r := _resolver.resolve(ref, element_paths.get(el, _uxml_path))
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
