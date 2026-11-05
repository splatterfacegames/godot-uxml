class_name UxmlParts
extends RefCounted
## Control part trees: the elements Unity builds inside its controls.
##
## A Unity control is not one box. A Toggle is a Toggle element with a label
## Label, an input VisualElement and a checkmark VisualElement inside; a
## Foldout holds a Toggle and a `#unity-content` container. Unity's theme and
## author USS style these parts by their names and classes
## (`.unity-toggle__checkmark`, `#unity-content`, ...), so godot-uxml builds
## the same parts as real UxmlElement children of the control, in the model,
## before the cascade runs. The cascade, var(), pseudo-states and the flex
## layout then treat them like any other element.
##
## Rules every builder follows (see docs/design.md, "Control parts"):
##   * A part is a UxmlElement with `part_of` set to the control that owns it
##     and `part_role` naming its job. Parts carry Unity's `name` and `class`
##     attributes; their names never enter the document name index.
##   * Text parts are `Label` elements with a `text` attribute, so the
##     runtime and the parity harness measure them like authored labels.
##   * Author children of a control move into its content container (the
##     part Unity's `contentContainer` returns), after the parts that sit
##     before it.
##   * State-dependent control classes (`unity-toggle--no-text`, ...) are
##     merged into the element's `class` attribute and remembered in
##     `control_classes(el)`, so UxmlDocument.set_class keeps them.
##
## The part shapes were measured in Unity 6000.3 with tools/unity-dump (see
## bench/parity/unity/ctl-*.json).
##
## To add a control: write `_build_<name>(el)` returning the content
## container, register it in `_builder()`, add the tag's own classes to
## UssControls.IMPLICIT_CLASSES, add its look to themes/unity-default.uss and
## a runtime behavior in uxml_behaviors.gd.

const META_CLASSES := &"uxml_control_classes"
const META_CONTENT := &"uxml_content"
## Text attributes ("label", "text") that a <Bindings> DataBinding writes
## after load. A text part normally exists only when its attribute is not
## empty (as in Unity); for a live attribute the part is built hidden
## (`display: none`), so a later non-empty value can show it. Part trees
## are fixed after load.
const META_LIVE := &"uxml_live_text"
const HIDDEN := "display: none;"


## Build the part trees of every control in `doc` (once per load, before the
## cascade is created). Elements that are already parts are expanded by the
## builder that made them.
static func expand(doc: UxmlDocumentModel) -> void:
	if doc == null or doc.root == null:
		return
	_mark_live(doc)
	var todo: Array = []
	var depth := {}  # Foldout -> number of Foldout ancestors
	_foldout_depths(doc.root, 0, depth)
	for el in doc.root.walk():
		if el.part_of != null:
			continue
		if depth.has(el):
			el.set_meta(&"uxml_foldout_depth", depth[el])
		# Unity's SetEnabled(false) adds `unity-disabled` to the element
		# itself (not its subtree), which `enabled="false"` does at load.
		var en = el.get_attribute("enabled")
		if en != null and String(en).to_lower() == "false":
			_add_control_classes(el, ["unity-disabled"])
		if has_parts(el.local):
			todo.append(el)
	for el in todo:
		build(el)


## Record the text attributes that <Bindings> write (META_LIVE).
static func _mark_live(doc: UxmlDocumentModel) -> void:
	for el in doc.bindings:
		var live := {}
		for desc in doc.bindings[el]:
			var prop := String(desc.get("property", "")).strip_edges()
			if prop == "label" or prop == "text" or prop == "title":
				live[prop] = true
		if not live.is_empty():
			(el as UxmlElement).set_meta(META_LIVE, live)


static func _live(el: UxmlElement, attr_name: String) -> bool:
	return (el.get_meta(META_LIVE, {}) as Dictionary).has(attr_name)


## A text part for `attr_name`: built when the attribute is not empty, or
## built hidden when a binding writes the attribute later. Null otherwise.
static func _text_part(el: UxmlElement, attr_name: String, role: String, classes: Array) -> UxmlElement:
	var text := _attr(el, attr_name)
	if text.is_empty() and not _live(el, attr_name):
		return null
	var p := part(el, "Label", role, "", classes, text)
	if text.is_empty():
		p.attributes.append({"name": "style", "value": HIDDEN, "offset": 0})
	return p


static func _foldout_depths(el: UxmlElement, d: int, out: Dictionary) -> void:
	for c in el.children:
		if c.local == "Foldout":
			out[c] = d
			_foldout_depths(c, d + 1, out)
		else:
			_foldout_depths(c, d, out)


static func has_parts(local: String) -> bool:
	return _builder(local).is_valid()


## Build `el`'s parts (no-op for elements without a part tree).
static func build(el: UxmlElement) -> void:
	var b := _builder(el.local)
	if not b.is_valid():
		return
	var authored: Array = []
	for c in el.children:
		authored.append(c)
	el.children = []
	var content: UxmlElement = b.call(el)
	if content == null:
		content = el
	if content != el:
		# The role, not the element: a meta reference to a descendant would
		# be a RefCounted cycle.
		el.set_meta(META_CONTENT, content.part_role)
	for c in authored:
		content.children.append(c)
	if el.local == "ToggleButtonGroup":
		_button_group_classes(content)


## Unity's ToggleButtonGroup marks its buttons by position: --left, --mid,
## --right, or --standalone for a single button.
static func _button_group_classes(container: UxmlElement) -> void:
	var buttons: Array = []
	for x in container.children:
		if x.local == "Button":
			buttons.append(x)
	var n := buttons.size()
	for i in n:
		var pos := "mid"
		if n == 1:
			pos = "standalone"
		elif i == 0:
			pos = "left"
		elif i == n - 1:
			pos = "right"
		_add_control_classes(buttons[i], ["unity-button-group__button", "unity-button-group__button--" + pos])


## Where authored children of `el` live: a part, or `el` itself.
static func content_container(el: UxmlElement) -> UxmlElement:
	var role: String = el.get_meta(META_CONTENT, "")
	if role.is_empty():
		return el
	var p := find_part(el, role)
	return el if p == null else p


## The first part of `owner` with `role` (searching owner's whole subtree,
## parts of nested controls excluded), or null.
static func find_part(owner: UxmlElement, role: String) -> UxmlElement:
	for x in owner.walk():
		if x.part_of == owner and x.part_role == role:
			return x
	return null


## The classes the control itself added to `el` (kept across set_class).
static func control_classes(el: UxmlElement) -> PackedStringArray:
	return el.get_meta(META_CLASSES, PackedStringArray())


## Replace the control classes of `el` with `classes`, keeping author
## classes. Goes through set_attribute, so a live document restyles.
static func set_control_classes(el: UxmlElement, classes: PackedStringArray) -> void:
	var old := control_classes(el)
	var author: PackedStringArray = []
	for c in el.class_list():
		if not old.has(c):
			author.append(c)
	el.set_meta(META_CLASSES, classes)
	var all := author.duplicate()
	for c in classes:
		if not all.has(c):
			all.append(c)
	el.set_attribute("class", " ".join(all))


## Add or remove one control class.
static func toggle_control_class(el: UxmlElement, cls: String, on: bool) -> void:
	var cc := control_classes(el).duplicate()
	var has := cc.has(cls)
	if on == has:
		return
	if on:
		cc.append(cls)
	else:
		cc.remove_at(cc.find(cls))
	set_control_classes(el, cc)


## `author` classes plus `el`'s control classes, as one class attribute.
static func merged_class(el: UxmlElement, author: String) -> String:
	var parts: PackedStringArray = []
	for c in author.split(" ", false):
		if not parts.has(c):
			parts.append(c)
	for c in control_classes(el):
		if not parts.has(c):
			parts.append(c)
	return " ".join(parts)


# ---------------------------------------------------------------------------
# Part construction helpers
# ---------------------------------------------------------------------------

static func part(owner: UxmlElement, local: String, role: String,
		part_name: String = "", classes: Array = [], text = null) -> UxmlElement:
	var p := UxmlElement.new()
	p.prefix = owner.prefix
	p.local = local
	p.part_of = owner
	p.part_role = role
	p.open_tag_start = owner.open_tag_start
	p.open_tag_end = owner.open_tag_end
	p.source_end = owner.source_end
	if not part_name.is_empty():
		p.attributes.append({"name": "name", "value": part_name, "offset": 0})
	if not classes.is_empty():
		p.attributes.append({"name": "class", "value": " ".join(classes), "offset": 0})
	if text != null:
		p.attributes.append({"name": "text", "value": String(text), "offset": 0})
	return p


static func _attr(el: UxmlElement, n: String, d: String = "") -> String:
	var v = el.get_attribute(n)
	return d if v == null else String(v)


static func _bool(el: UxmlElement, n: String, d: bool) -> bool:
	var v = el.get_attribute(n)
	if v == null:
		return d
	match String(v).to_lower():
		"true", "1":
			return true
		"false", "0":
			return false
	return d


static func _add_control_classes(el: UxmlElement, classes: Array) -> void:
	var cc := control_classes(el).duplicate()
	for c in classes:
		if not cc.has(c):
			cc.append(c)
	el.set_meta(META_CLASSES, cc)
	el.attributes = el.attributes.duplicate()
	var author := _attr(el, "class")
	var merged := merged_class(el, author)
	for a in el.attributes:
		if a["name"] == "class":
			a["value"] = merged
			return
	el.attributes.append({"name": "class", "value": merged, "offset": 0})


static func _builder(local: String) -> Callable:
	match local:
		"Toggle":
			return _build_toggle
		"RadioButton":
			return _build_radio
		"RadioButtonGroup":
			return _build_radio_group
		"ToggleButtonGroup":
			return _build_toggle_button_group
		"GroupBox":
			return _build_group_box
		"HelpBox":
			return _build_help_box
		"PopupWindow":
			return _build_popup_window
		"Foldout":
			return _build_foldout
		"ProgressBar":
			return _build_progress_bar
	return Callable()


# ---------------------------------------------------------------------------
# BaseField: the label/input structure every field control shares.
# ---------------------------------------------------------------------------

## The label part of a BaseField (only when `label` is not empty, as in
## Unity) and the `--no-label` variant class otherwise. `kind` is the
## control's class stem ("toggle", "radio-button", ...): Unity adds
## `unity-<kind>__label` beside `unity-base-field__label`.
static func field_label(el: UxmlElement, kinds: Array) -> UxmlElement:
	if _attr(el, "label").is_empty():
		_add_control_classes(el, ["unity-base-field--no-label"])
	var classes := ["unity-base-field__label"]
	for k in kinds:
		classes.append("unity-%s__label" % k)
	return _text_part(el, "label", "label", classes)


## The input part of a BaseField: `unity-base-field__input` plus
## `unity-<kind>__input` per kind.
static func field_input(el: UxmlElement, kinds: Array) -> UxmlElement:
	var classes := ["unity-base-field__input"]
	for k in kinds:
		classes.append("unity-%s__input" % k)
	return part(el, "VisualElement", "input", "", classes)


## Label (when present) then input, as BaseField orders them.
static func field_parts(el: UxmlElement, kinds: Array) -> UxmlElement:
	var label := field_label(el, kinds)
	if label != null:
		el.children.append(label)
	var input := field_input(el, kinds)
	el.children.append(input)
	return input


# ---------------------------------------------------------------------------
# Controls
# ---------------------------------------------------------------------------

## Toggle: [label] input > checkmark [text]. Content container: itself.
static func _build_toggle(el: UxmlElement) -> UxmlElement:
	var input := field_parts(el, ["toggle"])
	input.children.append(part(el, "VisualElement", "checkmark", "unity-checkmark",
		["unity-toggle__checkmark"]))
	_bool_text(el, input, "toggle")
	return el


## BaseBoolField `text`: a Label after the checkmark, only when set.
static func _bool_text(el: UxmlElement, input: UxmlElement, kind: String) -> void:
	var tx := _text_part(el, "text", "text", ["unity-%s__text" % kind])
	if tx != null:
		input.children.append(tx)


## RadioButton: [label] input > checkmark-background > checkmark, [text].
static func _build_radio(el: UxmlElement) -> UxmlElement:
	var input := field_parts(el, ["radio-button"])
	var bg := part(el, "VisualElement", "checkmark-background", "",
		["unity-radio-button__checkmark-background"])
	bg.children.append(part(el, "VisualElement", "checkmark", "unity-checkmark",
		["unity-radio-button__checkmark"]))
	input.children.append(bg)
	_bool_text(el, input, "radio-button")
	return el


## RadioButtonGroup: [label] input > (#choicesContentContainer with one
## RadioButton per `choices` entry, #contentContainer for authored
## RadioButtons — the content container).
static func _build_radio_group(el: UxmlElement) -> UxmlElement:
	var label := field_label(el, [])
	if label != null:
		el.children.append(label)
	var input := part(el, "VisualElement", "input", "", ["unity-base-field__input"])
	el.children.append(input)
	var choices := part(el, "VisualElement", "choices", "choicesContentContainer",
		["unity-radio-button-group__container"])
	var content := part(el, "VisualElement", "container", "contentContainer",
		["unity-radio-button-group__container"])
	input.children.append(choices)
	input.children.append(content)
	var raw := _attr(el, "choices")
	if not raw.is_empty():
		for choice in raw.split(","):
			var rb := part(el, "RadioButton", "choice")
			rb.attributes.append({"name": "text", "value": String(choice).strip_edges(), "offset": 0})
			_build_nested(rb)
			choices.children.append(rb)
	return content


## ToggleButtonGroup: [label] then the button container, which is both the
## field input and the content container (authored Buttons go into it).
static func _build_toggle_button_group(el: UxmlElement) -> UxmlElement:
	var label := field_label(el, [])
	if label != null:
		el.children.append(label)
	var container := part(el, "ButtonGroupContainer", "container",
		"unity-toggle-button-group__container", ["unity-button-group", "unity-base-field__input"])
	el.children.append(container)
	return container


## GroupBox: [label]; content container: itself.
static func _build_group_box(el: UxmlElement) -> UxmlElement:
	var label := _text_part(el, "text", "label", ["unity-group-box__label"])
	if label != null:
		el.children.append(label)
	return el


## HelpBox: [icon] label. Unity leaves the icon out of the hierarchy for
## message-type None.
static func _build_help_box(el: UxmlElement) -> UxmlElement:
	if _attr(el, "message-type", "None").to_lower() in ["info", "warning", "error"]:
		var icon := part(el, "VisualElement", "icon", "", ["unity-help-box__icon"])
		el.children.append(icon)
		help_box_icon(el, icon)
	el.children.append(part(el, "Label", "label", "",
		["unity-help-box__label", "unity-text-element__selectable"], _attr(el, "text")))
	return el


## The icon variant class for the HelpBox's `message-type`; None hides it.
static func help_box_icon(el: UxmlElement, icon: UxmlElement) -> void:
	var kind := _attr(el, "message-type", "None").to_lower()
	var cls := ["unity-help-box__icon"]
	var style := ""
	match kind:
		"info", "warning", "error":
			cls.append("unity-help-box__icon--" + kind)
		_:
			style = "display: none;"
	icon.attributes = [{"name": "class", "value": " ".join(cls), "offset": 0}]
	if not style.is_empty():
		icon.attributes.append({"name": "style", "value": style, "offset": 0})


## PopupWindow: its text is drawn by itself (a TextElement); authored
## children go into `#unity-content-container`.
static func _build_popup_window(el: UxmlElement) -> UxmlElement:
	var content := part(el, "VisualElement", "content", "unity-content-container",
		["unity-popup-window__content-container"])
	el.children.append(content)
	return content


## Foldout: a Toggle part (`unity-foldout__toggle`) with the arrow
## checkmark and the text, then `#unity-content`, the content container.
static func _build_foldout(el: UxmlElement) -> UxmlElement:
	_add_control_classes(el, ["unity-foldout--depth-%d" % _foldout_depth(el)])
	var toggle := part(el, "Toggle", "toggle", "", ["unity-foldout__toggle"])
	var open := _bool(el, "value", true)
	toggle.attributes.append({"name": "value", "value": "true" if open else "false", "offset": 0})
	var text := _attr(el, "text")
	if not text.is_empty():
		toggle.attributes.append({"name": "text", "value": text, "offset": 0})
	if _live(el, "text"):
		toggle.set_meta(META_LIVE, {"text": true})
	_build_nested(toggle)
	var input := find_part(toggle, "input")
	if input != null:
		_append_class(input, "unity-foldout__input")
	var check := find_part(toggle, "checkmark")
	if check != null:
		_append_class(check, "unity-foldout__checkmark")
	var tx := find_part(toggle, "text")
	if tx != null:
		_append_class(tx, "unity-foldout__text")
	el.children.append(toggle)
	var content := part(el, "VisualElement", "content", "unity-content", ["unity-foldout__content"])
	if not open:
		content.attributes.append({"name": "style", "value": "display: none;", "offset": 0})
	el.children.append(content)
	return content


## Unity's `unity-foldout--depth-N`: N Foldout ancestors (set by expand).
static func _foldout_depth(el: UxmlElement) -> int:
	return int(el.get_meta(&"uxml_foldout_depth", 0))


## ProgressBar: container > background > (progress, title-container >
## title).
static func _build_progress_bar(el: UxmlElement) -> UxmlElement:
	var container := part(el, "VisualElement", "container", "unity-progress-bar",
		["unity-progress-bar__container"])
	var bg := part(el, "VisualElement", "background", "", ["unity-progress-bar__background"])
	var progress := part(el, "VisualElement", "progress", "", ["unity-progress-bar__progress"])
	var tc := part(el, "VisualElement", "title-container", "", ["unity-progress-bar__title-container"])
	var title := part(el, "Label", "title", "", ["unity-progress-bar__title"], _attr(el, "title"))
	tc.children.append(title)
	bg.children.append(progress)
	bg.children.append(tc)
	container.children.append(bg)
	el.children.append(container)
	progress_style(el, progress)
	return el


## The progress part's inline geometry for the bar's value.
static func progress_style(el: UxmlElement, progress: UxmlElement) -> void:
	var lo := UssValues.parse_number(_attr(el, "low-value", "0"))
	var hi := UssValues.parse_number(_attr(el, "high-value", "100"))
	var v := UssValues.parse_number(_attr(el, "value", "0"))
	if is_nan(lo):
		lo = 0.0
	if is_nan(hi):
		hi = 100.0
	if is_nan(v):
		v = lo
	# Measured in Unity 6000.3 (ctl-progressbar, ctl-progress-range): the
	# fill is value / high-value, clamped to 0..1 — low-value does not shift
	# it (low 10, high 30, value 20 fills 2/3, not 1/2).
	var ratio := 0.0 if is_zero_approx(hi) else clampf(v / hi, 0.0, 1.0)
	var right := snappedf((1.0 - ratio) * 100.0, 0.0001)
	var txt := str(int(right)) if is_equal_approx(right, roundf(right)) else str(right)
	var style := "right: %s%%;" % txt
	for a in progress.attributes:
		if a["name"] == "style":
			if a["value"] != style:
				progress.set_attribute("style", style)
			return
	progress.attributes.append({"name": "style", "value": style, "offset": 0})


# ---------------------------------------------------------------------------

## Parts that are themselves controls (a Foldout's Toggle, a group's
## RadioButtons) get their own part trees; their parts belong to them.
static func _build_nested(el: UxmlElement) -> void:
	build(el)


static func _append_class(el: UxmlElement, cls: String) -> void:
	for a in el.attributes:
		if a["name"] == "class":
			a["value"] = String(a["value"]) + " " + cls
			return
	el.attributes.append({"name": "class", "value": cls, "offset": 0})
