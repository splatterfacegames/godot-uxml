class_name UxmlInputParts
extends RefCounted
## Part trees of Unity's input controls: Slider, SliderInt, MinMaxSlider,
## TextField, the numeric fields, the composite fields (vectors, rects,
## bounds), DropdownField and EnumField.
##
## The shapes, names and classes were measured in Unity 6000.3 with
## tools/unity-dump (bench/parity/unity/ctl-slider*.json, ctl-textfield*,
## ctl-numeric*, ctl-vectors, ctl-rects, ctl-dropdown*). UxmlParts calls
## `builder(local)` for every tag it does not build itself, so this file
## holds the input controls only (docs/design.md, "Control parts").
##
## Geometry that Unity computes from the layout is computed here too, as
## static functions that both the runtime behaviors and bench/parity.gd
## call:
##   * `slider_layout`: the dragger `translate` (BaseSlider places the
##     dragger with `style.translate`);
##   * `min_max_layout`: the MinMaxSlider dragger `left`/`width` and the
##     thumb offsets;
##   * `fill_style`: the fill part (`left`/`right` or `top`/`bottom` in %).



## Numeric field tag -> [class stem, input part type, label dragger].
const NUMERIC := {
	"IntegerField": ["integer-field", "IntegerInput", true],
	"LongField": ["long-field", "LongInput", true],
	"FloatField": ["float-field", "FloatInput", true],
	"DoubleField": ["double-field", "DoubleInput", true],
	"UnsignedIntegerField": ["unsigned-integer-field", "UnsignedIntegerInput", true],
	"UnsignedLongField": ["unsigned-long-field", "UnsignedLongInput", true],
	"Hash128Field": ["hash128-field", "Hash128Input", false],
}

## Composite field tag -> [class stem, sub-field tag, [[attr, part name,
## label], ...] groups]. A group is one line (Unity's field-group); a
## field without groups lists one group.
const COMPOSITE := {
	"Vector2Field": ["vector2-field", "FloatField", [[["x", "unity-x-input", "X"], ["y", "unity-y-input", "Y"]]]],
	"Vector2IntField": ["vector2-int-field", "IntegerField", [[["x", "unity-x-input", "X"], ["y", "unity-y-input", "Y"]]]],
	"Vector3Field": ["vector3-field", "FloatField", [[["x", "unity-x-input", "X"], ["y", "unity-y-input", "Y"], ["z", "unity-z-input", "Z"]]]],
	"Vector3IntField": ["vector3-int-field", "IntegerField", [[["x", "unity-x-input", "X"], ["y", "unity-y-input", "Y"], ["z", "unity-z-input", "Z"]]]],
	"Vector4Field": ["vector4-field", "FloatField", [[["x", "unity-x-input", "X"], ["y", "unity-y-input", "Y"], ["z", "unity-z-input", "Z"], ["w", "unity-w-input", "W"]]]],
	"RectField": ["rect-field", "FloatField", [[["x", "unity-x-input", "X"], ["y", "unity-y-input", "Y"]],
		[["w", "unity-width-input", "W"], ["h", "unity-height-input", "H"]]]],
	"RectIntField": ["rect-int-field", "IntegerField", [[["x", "unity-x-input", "X"], ["y", "unity-y-input", "Y"]],
		[["w", "unity-width-input", "W"], ["h", "unity-height-input", "H"]]]],
}

## Bounds field tag -> [class stem, vector tag, [[prefix, part name, label,
## class suffix], ...]].
const BOUNDS := {
	"BoundsField": ["bounds-field", "Vector3Field", [["c", "unity-m_Center-input", "Center", "center-field"],
		["e", "unity-m_Extent-input", "Extents", "extents-field"]]],
	"BoundsIntField": ["bounds-int-field", "Vector3IntField", [["p", "unity-m_Position-input", "Position", "position-field"],
		["s", "unity-m_Size-input", "Size", "size-field"]]],
}


## The builder for an input control tag, or an invalid Callable.
static func builder(local: String) -> Callable:
	match local:
		"Slider", "SliderInt":
			return _build_slider
		"MinMaxSlider":
			return _build_min_max_slider
		"TextField":
			return _build_text_field
		"DropdownField", "EnumField":
			return _build_popup_field
		"BoundsField", "BoundsIntField":
			return _build_bounds
	if NUMERIC.has(local):
		return _build_numeric
	if COMPOSITE.has(local):
		return _build_composite
	return Callable()


static func is_input_control(local: String) -> bool:
	return builder(local).is_valid()


# ---------------------------------------------------------------------------
# Attribute helpers
# ---------------------------------------------------------------------------

static func num(el: UxmlElement, n: String, d: float) -> float:
	var v = el.get_attribute(n)
	if v == null:
		return d
	var x := UssValues.parse_number(String(v))
	return d if is_nan(x) else x


static func flag(el: UxmlElement, n: String, d: bool) -> bool:
	return UxmlParts._bool(el, n, d)


static func vertical(el: UxmlElement) -> bool:
	return UxmlParts._attr(el, "direction", "Horizontal").to_lower() == "vertical"


## The `--no-label` class, the label part (`unity-<kind>__label` per kind,
## plus `--with-dragger` when the label drags the value) and the input
## part of type `input_type`.
static func field_parts(el: UxmlElement, kinds: Array, input_type: String, input_name: String,
		input_classes: Array, dragger := false) -> UxmlElement:
	var label := UxmlParts.field_label(el, kinds)
	if label != null:
		if dragger:
			# A control class: a readonly numeric field removes it.
			UxmlParts._add_control_classes(label, ["unity-base-field__label--with-dragger"])
		el.children.append(label)
	var input := UxmlParts.part(el, input_type, "input", input_name, input_classes)
	el.children.append(input)
	return input


# ---------------------------------------------------------------------------
# Slider, SliderInt
# ---------------------------------------------------------------------------

## The clamped value, low and high of a Slider/SliderInt: [value, low, high].
static func slider_values(el: UxmlElement) -> Array:
	var integer := el.local == "SliderInt"
	var lo := num(el, "low-value", 0.0)
	var hi := num(el, "high-value", 10.0)
	var v := num(el, "value", 0.0)
	if integer:
		lo = float(int(lo))
		hi = float(int(hi))
		v = float(int(v))
	v = clampf(v, minf(lo, hi), maxf(lo, hi))
	return [v, lo, hi]


## Unity's SliderNormalizeValue: 1 for an empty range.
static func slider_normalized(v: float, lo: float, hi: float) -> float:
	if is_zero_approx(hi - lo):
		return 1.0
	return (v - lo) / (hi - lo)


## Slider/SliderInt: [label] input > (#unity-drag-container > (#unity-tracker
## [> #unity-fill], #unity-dragger-border, #unity-dragger), [TextField
## #unity-text-field]). Content container: itself.
static func _build_slider(el: UxmlElement) -> UxmlElement:
	var stem := "slider-int" if el.local == "SliderInt" else "slider"
	UxmlParts._add_control_classes(el, ["unity-base-slider--vertical" if vertical(el) else "unity-base-slider--horizontal"])
	var input := field_parts(el, ["base-slider", stem], "VisualElement", "",
		["unity-base-field__input", "unity-base-slider__input", "unity-%s__input" % stem], true)
	var drag := UxmlParts.part(el, "VisualElement", "drag-container", "unity-drag-container",
		["unity-base-slider__drag-container"])
	var tracker := UxmlParts.part(el, "VisualElement", "tracker", "unity-tracker", ["unity-base-slider__tracker"])
	drag.children.append(tracker)
	if flag(el, "fill", false):
		var fill := UxmlParts.part(el, "VisualElement", "fill", "unity-fill", ["unity-base-slider__fill"])
		fill.attributes.append({"name": "style", "value": fill_style(el), "offset": 0})
		tracker.children.append(fill)
	drag.children.append(UxmlParts.part(el, "VisualElement", "dragger-border", "unity-dragger-border",
		["unity-base-slider__dragger-border"]))
	drag.children.append(UxmlParts.part(el, "VisualElement", "dragger", "unity-dragger", ["unity-base-slider__dragger"]))
	input.children.append(drag)
	if flag(el, "show-input-field", false):
		var tf := UxmlParts.part(el, "TextField", "text-field", "unity-text-field", ["unity-base-slider__text-field"])
		tf.attributes.append({"name": "value", "value": slider_text(el), "offset": 0})
		UxmlParts._build_nested(tf)
		input.children.append(tf)
	return el


## The text of the slider's input field: `{0:g7}` for Slider, the integer
## for SliderInt (Unity's UpdateTextFieldValue).
static func slider_text(el: UxmlElement) -> String:
	var v: float = slider_values(el)[0]
	if el.local == "SliderInt":
		return str(int(v))
	return UxmlNumeric.format_g(UxmlNumeric.to_f32(v), 7, false)


## The fill part's inline style (Unity's UpdateFill): the unfilled share
## of the track as a percentage offset.
static func fill_style(el: UxmlElement) -> String:
	var vals := slider_values(el)
	var inv := flag(el, "inverted", false)
	var pct := _pct((1.0 - slider_normalized(vals[0], vals[1], vals[2])) * 100.0)
	if vertical(el):
		return "left: 0px; right: 0px; top: %s; bottom: %s;" % ["0px" if inv else pct, pct if inv else "0px"]
	return "top: 0px; bottom: 0px; left: %s; right: %s;" % [pct if inv else "0px", "0px" if inv else pct]


static func _pct(v: float) -> String:
	var s := snappedf(v, 0.0001)
	return (str(int(s)) if is_equal_approx(s, roundf(s)) else str(s)) + "%"


static func _px(v: float) -> String:
	var s := snappedf(v, 0.0001)
	return (str(int(s)) if is_equal_approx(s, roundf(s)) else str(s)) + "px"


## Unity's UpdateDragElementPosition: the dragger offset along the track.
## `container` is the drag container size, `dragger` the dragger size,
## `margins` the dragger's left + right margin. Returns the `translate`
## value, or "" while the layout is not known.
static func slider_translate(el: UxmlElement, container: Vector2, dragger: Vector2, margins: float) -> String:
	var vals := slider_values(el)
	var t := slider_normalized(vals[0], vals[1], vals[2])
	if flag(el, "inverted", false):
		t = 1.0 - t
	if vertical(el):
		var top := (1.0 - t) * (container.y - dragger.y)
		return "0px %s" % _px(top)
	var left := t * (container.x - dragger.x - margins)
	return "%s 0px" % _px(left)


## Write the dragger and dragger-border `translate` of a Slider from the
## laid-out sizes. Unity moves the dragger only when the new position is at
## least half a pixel away. Returns true when a style changed.
static func slider_layout(el: UxmlElement, container: Vector2, dragger: Vector2, margins: float) -> bool:
	var tr := slider_translate(el, container, dragger, margins)
	if tr.is_empty():
		return false
	var changed := false
	for role in ["dragger", "dragger-border"]:
		var p := UxmlParts.find_part(el, role)
		if p == null:
			continue
		var want := "translate: %s;" % tr
		var cur = p.get_attribute("style")
		if cur != null and String(cur) == want:
			continue
		if cur == null and _translate_close(tr, "0px 0px"):
			continue
		if cur != null and _translate_close(tr, String(cur).trim_prefix("translate: ").trim_suffix(";")):
			continue
		p.set_attribute("style", want)
		changed = true
	return changed


static func _translate_close(a: String, b: String) -> bool:
	var pa := a.split(" ", false)
	var pb := b.split(" ", false)
	if pa.size() < 2 or pb.size() < 2:
		return false
	for k in 2:
		var x := UssValues.parse_number(pa[k].trim_suffix("px"))
		var y := UssValues.parse_number(pb[k].trim_suffix("px"))
		if is_nan(x) or is_nan(y) or absf(x - y) >= 0.5:
			return false
	return true


# ---------------------------------------------------------------------------
# MinMaxSlider
# ---------------------------------------------------------------------------

## [min, max, low limit, high limit], clamped as Unity's ClampValues.
static func min_max_values(el: UxmlElement) -> Array:
	var lo := num(el, "low-limit", -3.4028234663852886e38)
	var hi := num(el, "high-limit", 3.4028234663852886e38)
	if lo > hi:
		lo = hi
	var a := num(el, "min-value", 0.0)
	var b := num(el, "max-value", 10.0)
	if b > hi:
		b = hi
	var x := clampf(a, lo, b)
	var y := clampf(b, a, hi)
	return [x, y, lo, hi]


## MinMaxSlider: [label] input > (#unity-tracker, #unity-dragger >
## (#unity-thumb-min, #unity-thumb-max)).
static func _build_min_max_slider(el: UxmlElement) -> UxmlElement:
	var input := field_parts(el, ["min-max-slider"], "VisualElement", "",
		["unity-base-field__input", "unity-min-max-slider__input"])
	input.children.append(UxmlParts.part(el, "VisualElement", "tracker", "unity-tracker", ["unity-min-max-slider__tracker"]))
	var dragger := UxmlParts.part(el, "VisualElement", "dragger", "unity-dragger", ["unity-min-max-slider__dragger"])
	dragger.children.append(UxmlParts.part(el, "VisualElement", "thumb-min", "unity-thumb-min", ["unity-min-max-slider__min-thumb"]))
	dragger.children.append(UxmlParts.part(el, "VisualElement", "thumb-max", "unity-thumb-max", ["unity-min-max-slider__max-thumb"]))
	input.children.append(dragger)
	return el


## Unity's MinMaxSlider.UpdateDragElementPosition: `input_w` is the input
## width, `thumbs` the min and max thumb widths, `edges` the dragger's
## [left border + margin, right border + margin]. Returns the inline styles
## {role: style}.
static func min_max_styles(el: UxmlElement, input_w: float, thumbs: Vector2, edges: Vector2) -> Dictionary:
	var v := min_max_values(el)
	var span: float = v[3] - v[2]
	var n0: float = 0.0 if span == 0.0 else (v[0] - v[2]) / span
	var n1: float = 0.0 if span == 0.0 else (v[1] - v[2]) / span
	var min_w := edges.x + edges.y
	var left := _round_even(lerpf(thumbs.x, input_w - thumbs.y - min_w, n0))
	var right := _round_even(lerpf(thumbs.x + min_w, input_w - thumbs.y, n1))
	return {
		"dragger": "left: %s; width: %s;" % [_px(left), _px(right - left)],
		"thumb-min": "left: %s;" % _px(-thumbs.x - edges.x),
		"thumb-max": "right: %s;" % _px(-thumbs.y - edges.y),
	}


## Mathf.Round: halves round to even.
static func _round_even(v: float) -> float:
	var r := roundf(v)
	if absf(v - floorf(v) - 0.5) < 1e-9:
		r = floorf(v) if int(floorf(v)) % 2 == 0 else ceilf(v)
	return r


## Write the MinMaxSlider inline styles; true when one changed.
static func min_max_layout(el: UxmlElement, input_w: float, thumbs: Vector2, edges: Vector2) -> bool:
	var changed := false
	var styles := min_max_styles(el, input_w, thumbs, edges)
	for role in styles:
		var p := UxmlParts.find_part(el, role)
		if p == null:
			continue
		var cur = p.get_attribute("style")
		if cur != null and String(cur) == styles[role]:
			continue
		p.set_attribute("style", styles[role])
		changed = true
	return changed


# ---------------------------------------------------------------------------
# TextField and the numeric fields
# ---------------------------------------------------------------------------

## The editable text part: a TextElement whose control is the Godot
## LineEdit/TextEdit (UxmlControlFactory, role "editor").
static func _editor(el: UxmlElement, text: String, multiline: bool) -> UxmlElement:
	var classes := ["unity-text-element", "unity-text-element__selectable",
		"unity-text-element--inner-input-field-component"]
	var te := UxmlParts.part(el, "TextElement", "editor", "", classes, text)
	if multiline:
		te.set_meta(&"uxml_multiline", true)
	return te


## The initial text of a TextField: `value` (Unity also reads `text`),
## cut to `max-length`.
static func text_value(el: UxmlElement) -> String:
	var v = el.get_attribute("value")
	if v == null:
		v = el.get_attribute("text")
	var s := "" if v == null else String(v)
	var ml := int(num(el, "max-length", -1.0))
	if ml >= 0 and s.length() > ml:
		s = s.substr(0, ml)
	return s


## TextField: [label] TextInput#unity-text-input > TextElement (single
## line) or > .unity-base-text-field__multiline-container > TextElement.
static func _build_text_field(el: UxmlElement) -> UxmlElement:
	var multiline := flag(el, "multiline", false)
	var input := field_parts(el, ["base-text-field", "text-field"], "TextInput", "unity-text-input",
		["unity-base-text-field__input",
		"unity-base-text-field__input--multiline" if multiline else "unity-base-text-field__input--single-line",
		"unity-base-field__input", "unity-text-field__input"])
	var text := text_value(el)
	if text.is_empty() and not UxmlParts._attr(el, "placeholder-text").is_empty():
		UxmlParts._append_class(input, "unity-base-text-field__input--placeholder")
	var te := _editor(el, text, multiline)
	if multiline:
		var box := UxmlParts.part(el, "VisualElement", "multiline-container", "",
			["unity-base-text-field__multiline-container"])
		box.children.append(te)
		input.children.append(box)
	else:
		input.children.append(te)
	return el


## The initial text of a numeric field: the parsed `value`, formatted as
## the field formats it.
static func numeric_text(el: UxmlElement) -> String:
	var v = el.get_attribute("value")
	return UxmlNumeric.format(el.local, UxmlNumeric.parse_attr(el.local, "" if v == null else String(v)))


## IntegerField, LongField, FloatField, DoubleField, UnsignedIntegerField,
## UnsignedLongField, Hash128Field: [label] <Type>Input#unity-text-input >
## TextElement.
static func _build_numeric(el: UxmlElement) -> UxmlElement:
	var spec: Array = NUMERIC[el.local]
	var stem: String = spec[0]
	var input := field_parts(el, ["base-text-field", stem], spec[1], "unity-text-input",
		["unity-base-text-field__input", "unity-base-text-field__input--single-line",
		"unity-base-field__input", "unity-%s__input" % stem], spec[2])
	input.children.append(_editor(el, numeric_text(el), false))
	return el


# ---------------------------------------------------------------------------
# Composite fields
# ---------------------------------------------------------------------------

static func _sub_field(owner: UxmlElement, tag: String, part_name: String, label: String,
		value: String, classes: Array, role: String) -> UxmlElement:
	var f := UxmlParts.part(owner, tag, role, part_name, classes)
	f.attributes.append({"name": "label", "value": label, "offset": 0})
	f.attributes.append({"name": "value", "value": value, "offset": 0})
	UxmlParts._build_nested(f)
	return f


## Vector2/3/4(Int)Field, RectField, RectIntField: [label] input > the
## sub-fields (one FloatField or IntegerField per component); Rect fields
## put them in two `.unity-composite-field__field-group` lines. Two-field
## lines end with a `.unity-composite-field__field-spacer`.
static func _build_composite(el: UxmlElement) -> UxmlElement:
	var spec: Array = COMPOSITE[el.local]
	var stem: String = spec[0]
	var input := field_parts(el, ["composite-field", stem], "VisualElement", "",
		["unity-base-field__input", "unity-composite-field__input", "unity-%s__input" % stem])
	var groups: Array = spec[2]
	for gi in groups.size():
		var host := input
		if groups.size() > 1:
			host = UxmlParts.part(el, "VisualElement", "group-%d" % gi, "", ["unity-composite-field__field-group"])
			input.children.append(host)
		var fields: Array = groups[gi]
		for fi in fields.size():
			var f: Array = fields[fi]
			var classes := ["unity-composite-field__field"]
			if fi == 0:
				classes.append("unity-composite-field__field--first")
			var raw = el.get_attribute(f[0])
			var value := "0" if raw == null else String(raw)
			host.children.append(_sub_field(el, spec[1], f[1], f[2], value, classes, "field-" + String(f[0])))
		if fields.size() == 2:
			host.children.append(UxmlParts.part(el, "VisualElement", "spacer-%d" % gi, "",
				["unity-composite-field__field-spacer"]))
	return el


## BoundsField, BoundsIntField: [label] input > two Vector3(Int)Fields
## (center and extents, or position and size). Unity builds a Bounds from
## `cx..cz` and `ex..ez` as center and size, so the extents shown are half
## of `ex..ez`.
static func _build_bounds(el: UxmlElement) -> UxmlElement:
	var spec: Array = BOUNDS[el.local]
	var stem: String = spec[0]
	var input := field_parts(el, [stem], "VisualElement", "",
		["unity-base-field__input", "unity-%s__input" % stem])
	for sub in spec[2]:
		var f := UxmlParts.part(el, spec[1], "field-" + String(sub[0]), sub[1], ["unity-%s__%s" % [stem, sub[3]]])
		f.attributes.append({"name": "label", "value": sub[2], "offset": 0})
		for axis in ["x", "y", "z"]:
			var raw = el.get_attribute(String(sub[0]) + axis)
			var v := 0.0 if raw == null else UssValues.parse_number(String(raw))
			if is_nan(v):
				v = 0.0
			if el.local == "BoundsField" and sub[0] == "e":
				v *= 0.5
			if el.local == "BoundsIntField":
				v = float(int(v))
			f.attributes.append({"name": axis, "value": UxmlNumeric.format_g(v, 7, false), "offset": 0})
		UxmlParts._build_nested(f)
		input.children.append(f)
	return el


# ---------------------------------------------------------------------------
# DropdownField, EnumField
# ---------------------------------------------------------------------------

## DropdownField: [label] input > (PopupTextElement.unity-base-popup-field__text,
## .unity-base-popup-field__arrow). EnumField: the same shape with
## unity-enum-field__* classes and a TextElement for the text.
static func _build_popup_field(el: UxmlElement) -> UxmlElement:
	var enum_field := el.local == "EnumField"
	var input: UxmlElement
	if enum_field:
		input = field_parts(el, ["enum-field"], "VisualElement", "",
			["unity-base-field__input", "unity-enum-field__input"])
		input.children.append(UxmlParts.part(el, "TextElement", "text", "", ["unity-text-element", "unity-enum-field__text"],
			popup_initial_text(el)))
		input.children.append(UxmlParts.part(el, "VisualElement", "arrow", "", ["unity-enum-field__arrow"]))
	else:
		input = field_parts(el, ["base-popup-field", "popup-field"], "VisualElement", "",
			["unity-base-field__input", "unity-base-popup-field__input", "unity-popup-field__input"])
		input.children.append(UxmlParts.part(el, "PopupTextElement", "text", "", ["unity-text-element", "unity-base-popup-field__text"],
			popup_initial_text(el)))
		input.children.append(UxmlParts.part(el, "VisualElement", "arrow", "", ["unity-base-popup-field__arrow"]))
	return el


## The `choices` attribute as a list (Unity's ParseStringListAttribute:
## comma-separated, trimmed).
static func choices_of(el: UxmlElement) -> PackedStringArray:
	var out := PackedStringArray()
	var raw := UxmlParts._attr(el, "choices")
	if raw.strip_edges().is_empty():
		return out
	for c in raw.split(","):
		out.append(String(c).strip_edges())
	return out


## The selected index of a DropdownField at load. Unity 6000.3 reads
## `index` only; its `value` attribute maps to a placeholder property and
## selects nothing (measured: ctl-dropdown, `value="High"` shows no text).
static func dropdown_index(el: UxmlElement) -> int:
	var n := choices_of(el).size()
	var i := int(num(el, "index", -1.0))
	return i if i >= 0 and i < n else -1


## The text a DropdownField or EnumField shows at load.
static func popup_initial_text(el: UxmlElement) -> String:
	if el.local == "EnumField":
		var info := enum_info(UxmlParts._attr(el, "type"))
		if info.is_empty():
			return ""
		var i := enum_index(info, UxmlParts._attr(el, "value"))
		return "" if i < 0 else String(info["labels"][i])
	var i2 := dropdown_index(el)
	return "" if i2 < 0 else choices_of(el)[i2]


# ---------------------------------------------------------------------------
# EnumField types
# ---------------------------------------------------------------------------

## Registered enum types: key -> {names, values, labels, obsolete}.
static var _enums := {}


## Register an enum for EnumField `type`. `type_name` is matched against the
## attribute as written (`"Ns.Type, Assembly"`), without the assembly, and
## as the last name segment. `values` is a GDScript enum Dictionary
## (name -> int) or an Array of names (value = position). `obsolete` lists
## names that Unity would mark [Obsolete]: they show only with
## `include-obsolete-values="true"`.
static func register_enum(type_name: String, values: Variant, obsolete: Array = []) -> void:
	var names := PackedStringArray()
	var ints: Array = []
	if values is Dictionary:
		for k in values:
			names.append(String(k))
			ints.append(int(values[k]))
	else:
		for i in (values as Array).size():
			names.append(String(values[i]))
			ints.append(i)
	var labels := PackedStringArray()
	for n in names:
		labels.append(nicify(n))
	var obs := {}
	for o in obsolete:
		obs[String(o)] = true
	_enums[type_name] = {"names": names, "values": ints, "labels": labels, "obsolete": obs}


static func unregister_enum(type_name: String) -> void:
	_enums.erase(type_name)


## The registered enum for a `type` attribute, or {}.
static func enum_info(type_attr: String) -> Dictionary:
	var t := type_attr.strip_edges()
	if t.is_empty():
		return {}
	if _enums.has(t):
		return _enums[t]
	var bare := t.split(",")[0].strip_edges()
	if _enums.has(bare):
		return _enums[bare]
	var last := _last_segment(bare)
	for k in _enums:
		var kb := String(k).split(",")[0].strip_edges()
		if kb == bare or _last_segment(kb) == last:
			return _enums[k]
	return {}


static func _last_segment(type_name: String) -> String:
	var n := type_name.replace("+", ".")
	return n.get_slice(".", n.get_slice_count(".") - 1)


## Index of the entry named (or numbered) `value`; the first entry for an
## empty value, as Unity shows the default enum value; -1 if none.
static func enum_index(info: Dictionary, value: String) -> int:
	var names: PackedStringArray = info.get("names", PackedStringArray())
	if names.is_empty():
		return -1
	var v := value.strip_edges()
	if v.is_empty():
		return 0
	var i := names.find(v)
	if i >= 0:
		return i
	for k in names.size():
		if names[k].to_lower() == v.to_lower():
			return k
	if v.is_valid_int():
		return (info["values"] as Array).find(int(v))
	return -1


## Unity's ObjectNames.NicifyVariableName: "FlexStart" -> "Flex Start",
## "m_Value" -> "Value", "kSpeed" -> "Speed", "HTTPServer" -> "HTTP Server".
static func nicify(n: String) -> String:
	var s := n
	if s.begins_with("m_"):
		s = s.substr(2)
	elif s.length() > 1 and s[0] == "k" and s[1] == s[1].to_upper() and s[1] != s[1].to_lower():
		s = s.substr(1)
	elif s.begins_with("_"):
		s = s.substr(1)
	var out := ""
	for i in s.length():
		var c := s[i]
		var up := c != c.to_lower()
		if i > 0 and up:
			var prev := s[i - 1]
			var prev_up := prev != prev.to_lower()
			var next_low := i + 1 < s.length() and s[i + 1] != s[i + 1].to_upper()
			if not prev_up or next_low:
				if prev != " " and prev != "_":
					out += " "
		elif i > 0 and c.is_valid_int() and not s[i - 1].is_valid_int():
			out += " "
		if c == "_":
			out += " "
			continue
		out += c.to_upper() if i == 0 else c
	return out


# ---------------------------------------------------------------------------
# Layout-dependent styles
# ---------------------------------------------------------------------------

## The px value of `prop` in a computed style (0 when unset or not px).
static func style_px(style: Dictionary, prop: String) -> float:
	var e = style.get(prop)
	if e == null:
		return 0.0
	var p := UssValues.parse_length(String(e["value"]))
	return float(p["value"]) if p["kind"] == "px" else 0.0


## Write the layout-dependent inline styles of the Slider and MinMaxSlider
## `el` from laid-out sizes: `size_of.call(el) -> Vector2` and
## `style_of.call(el) -> Dictionary` (computed style). Returns true when a
## style changed. The runtime behaviors and bench/parity.gd share it.
static func layout_styles(el: UxmlElement, size_of: Callable, style_of: Callable) -> bool:
	match el.local:
		"Slider", "SliderInt":
			var drag := UxmlParts.find_part(el, "drag-container")
			var dragger := UxmlParts.find_part(el, "dragger")
			if drag == null or dragger == null:
				return false
			var ds: Dictionary = style_of.call(dragger)
			return slider_layout(el, size_of.call(drag), size_of.call(dragger),
				style_px(ds, "margin-left") + style_px(ds, "margin-right"))
		"MinMaxSlider":
			var input := UxmlParts.find_part(el, "input")
			var dragger2 := UxmlParts.find_part(el, "dragger")
			var t0 := UxmlParts.find_part(el, "thumb-min")
			var t1 := UxmlParts.find_part(el, "thumb-max")
			if input == null or dragger2 == null or t0 == null or t1 == null:
				return false
			var st: Dictionary = style_of.call(dragger2)
			var edges := Vector2(style_px(st, "border-left-width") + style_px(st, "margin-left"),
				style_px(st, "border-right-width") + style_px(st, "margin-right"))
			return min_max_layout(el, (size_of.call(input) as Vector2).x,
				Vector2((size_of.call(t0) as Vector2).x, (size_of.call(t1) as Vector2).x), edges)
	return false


## Classes a control toggles on its parts at run time (focus, typing). The
## parity harness copies them from Unity's dump like pseudo-states.
const STATE_CLASSES := ["unity-base-slider--movable", "unity-min-max-slider--movable",
	"unity-base-text-field__input--placeholder"]
