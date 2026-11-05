class_name UxmlEditorParts
extends RefCounted
## Part trees of Unity's editor controls (namespace UnityEditor.UIElements,
## usually the `uie:` prefix): ColorField, CurveField, GradientField,
## ObjectField, the mask and layer fields, the toolbar controls,
## PropertyField and InspectorElement.
##
## The shapes, names and classes were measured in Unity 6000.3 in an editor
## panel with the dark and the light editor skin (tools/unity-dump,
## bench/parity/unity/ed-*.json). UxmlParts calls `builder(local)` for
## every tag that the runtime controls do not build (docs/design.md,
## "Editor controls").
##
## Unity data that a Godot project does not have comes from Godot:
##   * layers (LayerField, LayerMaskField): the 3D physics layer names of
##     the project settings, else the 2D physics names, else "Layer 1" ..
##     "Layer 32"; `set_layer_names()` replaces them;
##   * rendering layers (RenderingLayerMaskField): the 3D render layer
##     names, else the 2D render names, else "Layer 1" .. "Layer 20";
##     `set_rendering_layer_names()` replaces them;
##   * tags (TagField): "Untagged" and the global groups of the project
##     settings; `set_tags()` replaces them.
## PropertyField and InspectorElement build their fields from the bound
## Godot Object (`property_field_content`), at bind time, as Unity builds
## them from a SerializedObject.

const META_WIDGET := &"uxml_editor_widget"  # part control kind ("curve", "gradient")

## Every editor control tag. Element tags of parts (ObjectFieldDisplay,
## BreadcrumbItem, PopupField`1) are listed so the cascade has their
## implicit classes; they are not authored.
const TAGS := {
	"ColorField": true, "CurveField": true, "GradientField": true, "ObjectField": true,
	"EnumFlagsField": true, "MaskField": true, "LayerField": true, "LayerMaskField": true,
	"RenderingLayerMaskField": true, "TagField": true,
	"Toolbar": true, "ToolbarButton": true, "ToolbarToggle": true, "ToolbarMenu": true,
	"ToolbarSpacer": true, "ToolbarBreadcrumbs": true, "ToolbarSearchField": true,
	"ToolbarPopupSearchField": true, "PropertyField": true, "InspectorElement": true,
}

## Popup field tag -> the class stems of the field, its label and its input
## (measured: ed-masks, ed-propertyfield). PopupField`1 is the enum field
## that PropertyField builds.
const POPUP := {
	"EnumFlagsField": ["base-popup-field", "enum-flags-field"],
	"MaskField": ["base-popup-field", "mask-field"],
	"LayerField": ["base-popup-field", "popup-field", "layer-field"],
	"LayerMaskField": ["base-popup-field", "mask-field", "layer-mask-field"],
	"RenderingLayerMaskField": ["base-popup-field", "rendering-layer-mask-field"],
	"TagField": ["base-popup-field", "popup-field", "tag-field"],
	"PopupField`1": ["base-popup-field", "popup-field"],
}

## Mask fields: the value is an int bit mask.
const MASKS := {"EnumFlagsField": true, "MaskField": true, "LayerMaskField": true,
	"RenderingLayerMaskField": true}

## Unity's built-in tags (a new Unity project).
const UNITY_TAGS := ["Untagged", "Respawn", "Finish", "EditorOnly", "MainCamera", "Player", "GameController"]

## Unity's InspectorElement label alignment (BaseField.AlignLabel): the
## default values of --unity-property-field-label-width-ratio,
## -label-extra-padding and -label-base-min-width (measured: ed-inspector).
const LABEL_WIDTH_RATIO := 0.45
const LABEL_EXTRA_PADDING := 37.0
const LABEL_BASE_MIN_WIDTH := 123.0
## --unity-base-field-extra-context-width (measured: 163px at 450px).
const LABEL_EXTRA_CONTEXT_WIDTH := 1.0

static var _layers = null           # PackedStringArray(32) or null: project settings
static var _render_layers = null    # PackedStringArray or null
static var _tags = null             # PackedStringArray or null


static func is_editor_control(local: String) -> bool:
	return TAGS.has(local)


## The builder for an editor control tag, or an invalid Callable.
static func builder(local: String) -> Callable:
	if not TAGS.has(local) and not POPUP.has(local):
		return Callable()  # every runtime tag: one lookup
	match local:
		"ColorField":
			return _build_color_field
		"CurveField":
			return _build_curve_field
		"GradientField":
			return _build_gradient_field
		"ObjectField":
			return _build_object_field
		"ToolbarToggle":
			return UxmlParts._build_toggle
		"ToolbarMenu":
			return _build_toolbar_menu
		"ToolbarSpacer":
			return _build_toolbar_spacer
		"ToolbarSearchField", "ToolbarPopupSearchField":
			return _build_search_field
		"InspectorElement":
			return _build_inspector
	if POPUP.has(local):
		return _build_popup
	return Callable()


# ---------------------------------------------------------------------------
# Project data: layers, rendering layers, tags
# ---------------------------------------------------------------------------

## Replace the layer names (index = layer, "" = no layer). An empty Array
## goes back to the project settings.
static func set_layer_names(names: Array) -> void:
	_layers = null if names.is_empty() else _padded(names, 32)


static func set_rendering_layer_names(names: Array) -> void:
	_render_layers = null if names.is_empty() else _padded(names, 32)


## Replace the tags. An empty Array goes back to the project settings.
static func set_tags(tags: Array) -> void:
	if tags.is_empty():
		_tags = null
		return
	var out := PackedStringArray()
	for t in tags:
		out.append(String(t))
	_tags = out


static func _padded(names: Array, n: int) -> PackedStringArray:
	var out := PackedStringArray()
	for i in n:
		out.append(String(names[i]) if i < names.size() else "")
	return out


static func _setting_names(kinds: Array, count: int) -> PackedStringArray:
	for kind in kinds:
		var out := PackedStringArray()
		var any := false
		for i in count:
			var key := "layer_names/%s/layer_%d" % [kind, i + 1]
			var v := String(ProjectSettings.get_setting(key, "")) if ProjectSettings.has_setting(key) else ""
			out.append(v)
			any = any or not v.is_empty()
		if any:
			return out
	var fallback := PackedStringArray()
	for i in count:
		fallback.append("Layer %d" % (i + 1))
	return fallback


## The 32 layer names (index = layer; "" = not defined).
static func layer_names() -> PackedStringArray:
	if _layers != null:
		return _layers
	return _setting_names(["3d_physics", "2d_physics"], 32)


static func rendering_layer_names() -> PackedStringArray:
	if _render_layers != null:
		return _render_layers
	return _setting_names(["3d_render", "2d_render"], 20)


## The tag list: "Untagged" plus the global groups of the project.
static func tags() -> PackedStringArray:
	if _tags != null:
		return _tags
	var out := PackedStringArray(["Untagged"])
	for p in ProjectSettings.get_property_list():
		var n := String(p["name"])
		if n.begins_with("global_group/"):
			out.append(n.substr(13))
	return out


# ---------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------

static func _attr(el: UxmlElement, n: String, d: String = "") -> String:
	return UxmlParts._attr(el, n, d)


static func _flag(el: UxmlElement, n: String, d: bool) -> bool:
	return UxmlParts._bool(el, n, d)


## A ColorField value from its `value` attribute (#RGB, #RRGGBB, #RRGGBBAA,
## rgb(), rgba() or a name). Unity's default is clear black.
static func color_value(el: UxmlElement) -> Color:
	var v = el.get_attribute("value")
	if v == null or String(v).strip_edges().is_empty():
		return Color(0, 0, 0, 0)
	var r := UssValues.parse_color(String(v).strip_edges())
	return r["color"] if r["ok"] else Color(0, 0, 0, 0)


static func color_text(c: Color) -> String:
	return "#" + c.to_html(true).to_upper()


static func _css(c: Color) -> String:
	return "rgba(%s, %s, %s, %s)" % [_n(c.r * 255.0), _n(c.g * 255.0), _n(c.b * 255.0), _n(c.a)]


static func _n(v: float) -> String:
	var s := snappedf(v, 0.0001)
	return str(int(s)) if is_equal_approx(s, roundf(s)) else str(s)


## [name, mask] per menu entry of a mask field, popup field or layer field.
static func choices(el: UxmlElement) -> Array:
	var out: Array = []
	match el.local:
		"MaskField":
			var names := UxmlInputParts.choices_of(el)
			var masks := _ints(_attr(el, "choices-masks"))
			for i in names.size():
				out.append([names[i], masks[i] if i < masks.size() else (1 << i)])
		"EnumFlagsField":
			var info := UxmlInputParts.enum_info(_attr(el, "type"))
			if not info.is_empty():
				for i in (info["names"] as PackedStringArray).size():
					out.append([String(info["labels"][i]), int(info["values"][i])])
			else:
				var names2 := UxmlInputParts.choices_of(el)
				var masks2 := _ints(_attr(el, "choices-masks"))
				for i in names2.size():
					out.append([names2[i], masks2[i] if i < masks2.size() else (1 << i)])
		"LayerField", "LayerMaskField":
			var ln := layer_names()
			for i in ln.size():
				if not ln[i].is_empty():
					out.append([ln[i], 1 << i])
		"RenderingLayerMaskField":
			var rn := rendering_layer_names()
			for i in rn.size():
				if not rn[i].is_empty():
					out.append([rn[i], 1 << i])
		"TagField":
			for t in tags():
				out.append([t, 0])
		"PopupField`1":
			for c in UxmlInputParts.choices_of(el):
				out.append([c, 0])
	return out


static func _ints(s: String) -> Array:
	var out: Array = []
	for p in s.split(",", false):
		var n := UssValues.parse_number(String(p).strip_edges())
		if not is_nan(n):
			out.append(int(n))
	return out


## The mask of every entry ORed together.
static func full_mask(entries: Array) -> int:
	var m := 0
	for e in entries:
		m |= int(e[1])
	return m


## The int value of a mask field from its `value` attribute. A MaskField
## or LayerMaskField drops bits outside its entries and stores a full mask
## as -1, "Everything" (measured: ed-masks). An EnumFlagsField reads
## C# flag names ("Alpha, Gamma") or a number.
static func mask_value(el: UxmlElement) -> int:
	var raw := _attr(el, "value").strip_edges()
	var entries := choices(el)
	if el.local == "RenderingLayerMaskField" and raw.is_empty():
		return -1  # Unity's default: every rendering layer
	var v := 0
	if el.local == "EnumFlagsField":
		var n := UssValues.parse_number(raw)
		if not is_nan(n):
			v = int(n)
		else:
			for part in raw.split(",", false):
				var name := String(part).strip_edges()
				for e in entries:
					if String(e[0]).replace(" ", "") == name.replace(" ", ""):
						v |= int(e[1])
		return v
	var x := UssValues.parse_number(raw)
	v = 0 if is_nan(x) else int(x)
	return normalize_mask(el, v, entries)


static func normalize_mask(el: UxmlElement, v: int, entries: Array = []) -> int:
	if el.local == "EnumFlagsField":
		return v
	if entries.is_empty():
		entries = choices(el)
	if v == -1:
		return -1
	var full := full_mask(entries)
	v &= full
	if full != 0 and v == full:
		return -1
	return v


## The text a mask field shows: "Nothing", "Everything", the name of one
## entry or the names joined with ", " (Unity 6000.3, measured: ed-masks).
static func mask_text(el: UxmlElement, v: int) -> String:
	var entries := choices(el)
	var flags := el.local == "EnumFlagsField"
	if flags:
		for e in entries:
			if int(e[1]) == v:
				return String(e[0])
		if v == 0:
			return "Nothing"
	else:
		if v == 0:
			return "Nothing"
	var full := full_mask(entries)
	if v == -1 or (full != 0 and (v & full) == full and not flags):
		return "Everything"
	if flags and full != 0 and v == full:
		return "Everything"
	var names: Array = []
	for e in entries:
		var m := int(e[1])
		if m != 0 and (m & (m - 1)) == 0 and (v & m) == m:
			names.append(String(e[0]))
	return ", ".join(names)


## LayerField: the layer index of `value` (Unity's default 0).
static func layer_value(el: UxmlElement) -> int:
	var n := UssValues.parse_number(_attr(el, "value", "0"))
	return 0 if is_nan(n) else clampi(int(n), 0, 31)


## The text of a popup-based editor field at load.
static func popup_text(el: UxmlElement) -> String:
	if MASKS.has(el.local):
		return mask_text(el, mask_value(el))
	match el.local:
		"LayerField":
			var ln := layer_names()
			var i := layer_value(el)
			return ln[i] if i < ln.size() else ""
		"TagField":
			return _attr(el, "value", "Untagged")
		"PopupField`1":
			var ch := UxmlInputParts.choices_of(el)
			var i2 := UxmlInputParts.dropdown_index(el)
			return ch[i2] if i2 >= 0 else ""
	return ""


# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------

## Mask, layer, tag and enum popup fields: [label] input >
## (PopupTextElement.unity-base-popup-field__text,
## .unity-base-popup-field__arrow); a RenderingLayerMaskField also has a
## hidden warning HelpBox.
static func _build_popup(el: UxmlElement) -> UxmlElement:
	var kinds: Array = POPUP[el.local]
	var input := UxmlParts.field_parts(el, kinds)
	input.children.append(UxmlParts.part(el, "PopupTextElement", "text", "",
		["unity-text-element", "unity-base-popup-field__text"], popup_text(el)))
	input.children.append(UxmlParts.part(el, "VisualElement", "arrow", "", ["unity-base-popup-field__arrow"]))
	if el.local == "RenderingLayerMaskField":
		var hb := UxmlParts.part(el, "HelpBox", "help-box")
		hb.attributes.append({"name": "message-type", "value": "Warning", "offset": 0})
		hb.attributes.append({"name": "style", "value": UxmlParts.HIDDEN, "offset": 0})
		UxmlParts._build_nested(hb)
		el.children.append(hb)
	return el


## ColorField: [label] input > (#unity-color-container > (color, HDR
## gradients, HDR label, mixed-value label, alpha ProgressBar),
## #unity-eyedropper). `color_styles` sets the parts for the value.
static func _build_color_field(el: UxmlElement) -> UxmlElement:
	var input := UxmlParts.field_parts(el, ["color-field"])
	var box := UxmlParts.part(el, "VisualElement", "color-container", "unity-color-container",
		["unity-color-field__color-container"])
	box.children.append(UxmlParts.part(el, "VisualElement", "color", "unity-internal-color-field",
		["unity-color-field__color"]))
	for g in [["gradient", "unity-gradient-"], ["alpha-gradient", "unity-alpha-gradient-"]]:
		var gc := UxmlParts.part(el, "VisualElement", g[0] + "-container", g[1] + "container",
			["unity-color-field__gradient-container"])
		gc.children.append(UxmlParts.part(el, "VisualElement", g[0] + "-left", g[1] + "left"))
		gc.children.append(UxmlParts.part(el, "VisualElement", g[0] + "-mid"))
		gc.children.append(UxmlParts.part(el, "VisualElement", g[0] + "-right", g[1] + "right"))
		box.children.append(gc)
	box.children.append(UxmlParts.part(el, "Label", "hdr-label", "unity-hdr-label",
		["unity-color-field__hdr"], "HDR"))
	var mixed := UxmlParts.part(el, "Label", "mixed-value", "unity-mixed-value-label",
		["unity-base-field__label", "unity-base-field__label--mixed-value"], "—")
	box.children.append(mixed)
	var pb := UxmlParts.part(el, "ProgressBar", "alpha-progress", "unity-alpha-progress")
	pb.attributes.append({"name": "value", "value": "100", "offset": 0})
	UxmlParts._build_nested(pb)
	box.children.append(pb)
	input.children.append(box)
	input.children.append(UxmlParts.part(el, "VisualElement", "eyedropper", "unity-eyedropper",
		["unity-color-field__eyedropper"]))
	color_styles(el, color_value(el))
	return el


## The inline styles of a ColorField's parts for colour `c` (measured:
## ed-colorfield): the swatch shows the opaque colour; `hdr` shows the
## gradient strips and the HDR label; `show-alpha` shows the alpha bar
## (value = alpha x 100); `show-eye-dropper="false"` hides the dropper.
## Returns true when a part changed.
static func color_styles(el: UxmlElement, c: Color) -> bool:
	var hdr := _flag(el, "hdr", false)
	var alpha := _flag(el, "show-alpha", true)
	var dropper := _flag(el, "show-eye-dropper", true)
	var ldr := Color(clampf(c.r, 0, 1), clampf(c.g, 0, 1), clampf(c.b, 0, 1), 1.0)
	var rgb := _css(ldr)
	var hidden := UxmlParts.HIDDEN
	var tint := _css(ldr)
	var want := {
		"color": "background-color: %s;" % rgb,
		"gradient-container": "" if hdr else hidden,
		"alpha-gradient-container": "" if hdr else hidden,
		"hdr-label": "" if hdr else hidden,
		"mixed-value": hidden,
		"alpha-progress": "" if alpha else hidden,
		"eyedropper": "" if dropper else hidden,
		"gradient-left": "background-color: %s;" % rgb if hdr else "",
		"gradient-right": "background-color: %s;" % rgb if hdr else "",
		"alpha-gradient-left": "-unity-background-image-tint-color: %s;" % tint if hdr else "",
		"alpha-gradient-right": "-unity-background-image-tint-color: %s;" % tint if hdr else "",
	}
	var changed := false
	for role in want:
		changed = _set_style(UxmlParts.find_part(el, role), want[role]) or changed
	var pb := UxmlParts.find_part(el, "alpha-progress")
	if pb != null:
		var av := _n(clampf(c.a, 0.0, 1.0) * 100.0)
		if pb.get_attribute("value") != av:
			_set_attr_quiet(pb, "value", av)
			var prog := UxmlParts.find_part(pb, "progress")
			if prog != null:
				UxmlParts.progress_style(pb, prog)
			changed = true
	return changed


## Set (or remove, for "") the inline style of a part. True when it changed.
static func _set_style(p: UxmlElement, style: String) -> bool:
	if p == null:
		return false
	var cur = p.get_attribute("style")
	if (cur == null and style.is_empty()) or (cur != null and String(cur) == style):
		return false
	if style.is_empty():
		if p.changed.is_valid():
			p.remove_attribute("style")
		else:
			_remove_attr(p, "style")
	elif p.changed.is_valid():
		p.set_attribute("style", style)
	else:
		_set_attr_quiet(p, "style", style)
	return true


## Attribute writes before the document observes the model (no `changed`
## callback yet) go straight into the attribute list.
static func _set_attr_quiet(p: UxmlElement, n: String, v: String) -> void:
	if p.changed.is_valid():
		p.set_attribute(n, v)
		return
	for a in p.attributes:
		if a["name"] == n:
			a["value"] = v
			return
	p.attributes.append({"name": n, "value": v, "offset": 0})


static func _remove_attr(p: UxmlElement, n: String) -> void:
	for i in range(p.attributes.size() - 1, -1, -1):
		if p.attributes[i]["name"] == n:
			p.attributes.remove_at(i)


## CurveField: [label] input (draws the curve) > #unity-border.
static func _build_curve_field(el: UxmlElement) -> UxmlElement:
	var input := UxmlParts.field_parts(el, ["curve-field"])
	input.set_meta(META_WIDGET, "curve")
	input.children.append(UxmlParts.part(el, "VisualElement", "border", "unity-border",
		["unity-curve-field__border"]))
	return el


## GradientField: [label] input > background (checker) > content (draws
## the gradient).
static func _build_gradient_field(el: UxmlElement) -> UxmlElement:
	var input := UxmlParts.field_parts(el, ["gradient-field"])
	var bg := UxmlParts.part(el, "VisualElement", "background", "", ["unity-gradient-field__background"])
	var content := UxmlParts.part(el, "VisualElement", "content", "", ["unity-gradient-field__content"])
	content.set_meta(META_WIDGET, "gradient")
	bg.children.append(content)
	input.children.append(bg)
	return el


## ObjectField: [label] input > (ObjectFieldDisplay > (Image icon, Label),
## ObjectFieldSelector).
static func _build_object_field(el: UxmlElement) -> UxmlElement:
	var input := UxmlParts.field_parts(el, ["object-field"])
	var display := UxmlParts.part(el, "ObjectFieldDisplay", "display", "", ["unity-object-field__object"])
	display.children.append(UxmlParts.part(el, "Image", "icon", "", ["unity-object-field-display__icon"]))
	var label := UxmlParts.part(el, "Label", "display-label", "", ["unity-object-field-display__label"],
		object_label(el, null))
	UxmlParts._add_control_classes(label, ["unity-object-field-display__label--value-null"])
	display.children.append(label)
	input.children.append(display)
	input.children.append(UxmlParts.part(el, "ObjectFieldSelector", "selector", "", ["unity-object-field__selector"]))
	return el


## The type of an ObjectField: the `type` attribute as written (a C#
## assembly-qualified name or a Godot class), its short name and the Godot
## class that it maps to (docs/design.md, "Editor controls").
const UNITY_TYPES := {
	"Object": "Resource", "GameObject": "Node", "Transform": "Node3D", "Component": "Node",
	"MonoBehaviour": "Node", "ScriptableObject": "Resource", "MonoScript": "Script",
	"Sprite": "Texture2D", "AudioClip": "AudioStream", "AnimationClip": "Animation",
	"TextAsset": "Resource", "Cubemap": "Cubemap", "RenderTexture": "ViewportTexture",
	"Texture": "Texture",
}


static func object_type_name(el: UxmlElement) -> String:
	var t := _attr(el, "type").split(",")[0].strip_edges()
	if t.is_empty():
		return "Object"
	var dot := t.rfind(".")
	return t.substr(dot + 1) if dot >= 0 else t


static func godot_class(el: UxmlElement) -> String:
	var short := object_type_name(el)
	if UNITY_TYPES.has(short):
		return UNITY_TYPES[short]
	if ClassDB.class_exists(short):
		return short
	return "Resource"


## The display text: the object's name, or "None (<Type>)" (Unity's
## nicified type name).
static func object_label(el: UxmlElement, v: Variant) -> String:
	if v == null or (v is Object and not is_instance_valid(v)):
		return "None (%s)" % nicify(object_type_name(el))
	return object_name(v)


static func object_name(v: Variant) -> String:
	if v is Node:
		return String((v as Node).name)
	if v is Resource:
		var r := v as Resource
		if not r.resource_name.is_empty():
			return r.resource_name
		if not r.resource_path.is_empty():
			return r.resource_path.get_file().get_basename()
		return r.get_class()
	if v is Object:
		return (v as Object).get_class()
	return str(v)


## ToolbarMenu: (TextElement.unity-toolbar-menu__text, .unity-toolbar-menu__arrow).
static func _build_toolbar_menu(el: UxmlElement) -> UxmlElement:
	if _attr(el, "variant").to_lower() == "popup":
		UxmlParts._add_control_classes(el, ["unity-toolbar-menu--popup"])
	el.children.append(UxmlParts.part(el, "TextElement", "text", "",
		["unity-text-element", "unity-toolbar-menu__text"], _attr(el, "text")))
	el.children.append(UxmlParts.part(el, "VisualElement", "arrow", "", ["unity-toolbar-menu__arrow"]))
	return el


## ToolbarSpacer: no parts; `flex="true"` adds --flexible. Unity 6000.3
## reads `flex` from C# only; godot-uxml also reads the UXML attribute.
static func _build_toolbar_spacer(el: UxmlElement) -> UxmlElement:
	if _flag(el, "flex", false):
		UxmlParts._add_control_classes(el, ["unity-toolbar-spacer--flexible"])
	return el


## A BreadcrumbItem of ToolbarBreadcrumbs `el` (Unity's PushItem): the
## first item also has __first-item.
static func breadcrumb_item(el: UxmlElement, text: String) -> UxmlElement:
	var first := true
	for c in el.children:
		if c.part_of == el and c.part_role == "item":
			first = false
	var item := UxmlParts.part(el, "BreadcrumbItem", "item", "", [], text)
	if first:
		UxmlParts._add_control_classes(item, ["unity-toolbar-breadcrumbs__first-item"])
	return item


## ToolbarSearchField, ToolbarPopupSearchField: Button#unity-search, a
## TextField, Button#unity-cancel (--off while the text is empty).
static func _build_search_field(el: UxmlElement) -> UxmlElement:
	el.children.append(UxmlParts.part(el, "Button", "search-button", "unity-search",
		["unity-search-field-base__search-button"], ""))
	# Unity 6000.3 reads no UXML `value` for a search field (measured:
	# ed-toolbar-states): the text starts empty; code and bindings set it.
	var tf := UxmlParts.part(el, "TextField", "text-field", "", ["unity-search-field-base__text-field"])
	UxmlParts._build_nested(tf)
	var input := UxmlParts.find_part(tf, "input")
	if input != null:
		UxmlParts._append_class(input, "unity-search-field-base__text-field__input")
	el.children.append(tf)
	var cancel := UxmlParts.part(el, "Button", "cancel-button", "unity-cancel",
		["unity-search-field-base__cancel-button"], "")
	UxmlParts._add_control_classes(cancel, ["unity-search-field-base__cancel-button--off"])
	el.children.append(cancel)
	return el


## InspectorElement: the two bar containers and the content element that
## holds one PropertyField per property (built at bind time). Content
## container: the content element.
static func _build_inspector(el: UxmlElement) -> UxmlElement:
	UxmlParts._add_control_classes(el, ["unity-inspector-element--uie-default", "unity-inspector-element--uie"])
	el.children.append(UxmlParts.part(el, "VisualElement", "override-bars", "unity-prefab-override-bars-container"))
	el.children.append(UxmlParts.part(el, "VisualElement", "live-bars", "unity-live-property-bars-container"))
	var content := UxmlParts.part(el, "VisualElement", "content")
	el.children.append(content)
	return content


# ---------------------------------------------------------------------------
# PropertyField and InspectorElement content
# ---------------------------------------------------------------------------

## Unity's ObjectNames.NicifyVariableName: "m_" and "_" prefixes go, the
## first letter is upper case, and a space goes before an upper-case
## letter after a lower-case letter, before the last upper-case letter of
## a run that a lower-case letter follows, and before a digit run
## ("Texture2D" -> "Texture 2D", "vector3Value" -> "Vector 3 Value").
static func nicify(n: String) -> String:
	var s := n
	if s.begins_with("m_"):
		s = s.substr(2)
	elif s.length() > 1 and s[0] == "k" and _upper(s[1]):
		s = s.substr(1)
	elif s.begins_with("_"):
		s = s.substr(1)
	var out := ""
	for i in s.length():
		var c := s[i]
		if i > 0:
			var prev := s[i - 1]
			var next_low := i + 1 < s.length() and _lower(s[i + 1])
			if _upper(c) and (_lower(prev) or (next_low and (_upper(prev) or _digit(prev)))):
				out += " "
			elif _digit(c) and not _digit(prev) and prev != " " and prev != "_":
				out += " "
		if c == "_":
			if not out.ends_with(" "):
				out += " "
			continue
		out += c.to_upper() if i == 0 else c
	return out


static func _upper(c: String) -> bool:
	return c != c.to_lower()


static func _lower(c: String) -> bool:
	return c != c.to_upper()


static func _digit(c: String) -> bool:
	return c >= "0" and c <= "9"


## The label of a property: the PropertyField `label` when set, else the
## property name as Unity's ObjectNames.NicifyVariableName writes it
## ("intValue" -> "Int Value"); a snake_case name is capitalized as the
## Godot inspector does ("move_speed" -> "Move Speed").
static func property_label(name: String) -> String:
	var n := name
	if n.begins_with("m_"):
		n = n.substr(2)
	if n.find("_") > 0:
		return n.capitalize()
	return nicify(n)


## The field tag and its attributes for a Godot property. `info` is a
## property list entry (name, type, hint, hint_string, class_name), `v` the
## current value. Returns [tag, {attr: value}, kinds of the label/input
## extra classes] (docs/design.md, "PropertyField").
static func field_for(info: Dictionary, v: Variant) -> Array:
	var type := int(info.get("type", typeof(v)))
	var hint := int(info.get("hint", PROPERTY_HINT_NONE))
	var hs := String(info.get("hint_string", ""))
	match type:
		TYPE_BOOL:
			return ["Toggle", {"value": "true" if v else "false"}]
		TYPE_INT:
			if hint == PROPERTY_HINT_ENUM:
				var e := _hint_enum(hs)
				var idx := (e[1] as Array).find(int(v))
				return ["PopupField`1", {"choices": ",".join(e[2]), "index": str(idx)}]
			if hint == PROPERTY_HINT_FLAGS:
				var f := _hint_flags(hs)
				return ["EnumFlagsField", {"choices": ",".join(f[0]), "choices-masks": ",".join(f[1]),
					"value": str(int(v))}]
			if hint in [PROPERTY_HINT_LAYERS_2D_PHYSICS, PROPERTY_HINT_LAYERS_3D_PHYSICS,
					PROPERTY_HINT_LAYERS_2D_RENDER, PROPERTY_HINT_LAYERS_3D_RENDER,
					PROPERTY_HINT_LAYERS_2D_NAVIGATION, PROPERTY_HINT_LAYERS_3D_NAVIGATION,
					PROPERTY_HINT_LAYERS_AVOIDANCE]:
				var tag := "RenderingLayerMaskField" if hint in [PROPERTY_HINT_LAYERS_2D_RENDER,
					PROPERTY_HINT_LAYERS_3D_RENDER] else "LayerMaskField"
				return [tag, {"value": str(int(v))}]
			if hint == PROPERTY_HINT_RANGE:
				var r := hs.split(",")
				if r.size() >= 2:
					return ["SliderInt", {"low-value": r[0].strip_edges(), "high-value": r[1].strip_edges(),
						"value": str(int(v)), "show-input-field": "true"}]
			return ["IntegerField", {"value": str(int(v))}]
		TYPE_FLOAT:
			if hint == PROPERTY_HINT_RANGE:
				var r2 := hs.split(",")
				if r2.size() >= 2:
					return ["Slider", {"low-value": r2[0].strip_edges(), "high-value": r2[1].strip_edges(),
						"value": str(float(v)), "show-input-field": "true"}]
			return ["FloatField", {"value": UxmlBinding._str(float(v))}]
		TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH:
			if hint == PROPERTY_HINT_ENUM:
				var opts := hs.split(",")
				return ["PopupField`1", {"choices": hs, "index": str(opts.find(String(v)))}]
			var a := {"value": String(v)}
			if hint == PROPERTY_HINT_MULTILINE_TEXT:
				a["multiline"] = "true"
			return ["TextField", a]
		TYPE_COLOR:
			var ca := {"value": color_text(v)}
			if hint == PROPERTY_HINT_COLOR_NO_ALPHA:
				ca["show-alpha"] = "false"
			return ["ColorField", ca]
		TYPE_VECTOR2:
			return ["Vector2Field", {"x": UxmlBinding._str(v.x), "y": UxmlBinding._str(v.y)}]
		TYPE_VECTOR2I:
			return ["Vector2IntField", {"x": str(v.x), "y": str(v.y)}]
		TYPE_VECTOR3:
			return ["Vector3Field", {"x": UxmlBinding._str(v.x), "y": UxmlBinding._str(v.y), "z": UxmlBinding._str(v.z)}]
		TYPE_VECTOR3I:
			return ["Vector3IntField", {"x": str(v.x), "y": str(v.y), "z": str(v.z)}]
		TYPE_VECTOR4:
			return ["Vector4Field", {"x": UxmlBinding._str(v.x), "y": UxmlBinding._str(v.y),
				"z": UxmlBinding._str(v.z), "w": UxmlBinding._str(v.w)}]
		TYPE_RECT2:
			return ["RectField", {"x": UxmlBinding._str(v.position.x), "y": UxmlBinding._str(v.position.y),
				"w": UxmlBinding._str(v.size.x), "h": UxmlBinding._str(v.size.y)}]
		TYPE_RECT2I:
			return ["RectIntField", {"x": str(v.position.x), "y": str(v.position.y), "w": str(v.size.x), "h": str(v.size.y)}]
		TYPE_AABB:
			var c: Vector3 = v.get_center()
			var e3: Vector3 = v.size / 2.0
			return ["BoundsField", {"cx": UxmlBinding._str(c.x), "cy": UxmlBinding._str(c.y), "cz": UxmlBinding._str(c.z),
				"ex": UxmlBinding._str(e3.x), "ey": UxmlBinding._str(e3.y), "ez": UxmlBinding._str(e3.z)}]
		TYPE_OBJECT:
			var cls := String(info.get("class_name", ""))
			if cls.is_empty() and hint == PROPERTY_HINT_RESOURCE_TYPE:
				cls = hs.split(",")[0]
			if cls == "Curve" or v is Curve:
				return ["CurveField", {}]
			if cls == "Gradient" or v is Gradient:
				return ["GradientField", {}]
			if cls.is_empty():
				cls = "Resource" if not v is Node else "Node"
			var oa := {"type": cls}
			if ClassDB.is_parent_class(cls, "Node"):
				oa["allow-scene-objects"] = "true"
			return ["ObjectField", oa]
	return ["Label", {"text": "No GUI implemented for %s" % type_string(type)}]


## A PROPERTY_HINT_ENUM hint string: [names, values, labels].
static func _hint_enum(hs: String) -> Array:
	var names := PackedStringArray()
	var values: Array = []
	var labels := PackedStringArray()
	var next := 0
	for item in hs.split(","):
		var kv := String(item).split(":")
		var n := kv[0].strip_edges()
		next = int(kv[1]) if kv.size() > 1 else next
		names.append(n)
		values.append(next)
		labels.append(nicify(n) if n.find(" ") < 0 else n)
		next += 1
	return [names, values, labels]


## A PROPERTY_HINT_FLAGS hint string: [labels, masks as strings].
static func _hint_flags(hs: String) -> Array:
	var labels := PackedStringArray()
	var masks := PackedStringArray()
	var bit := 1
	for item in hs.split(","):
		var kv := String(item).split(":")
		var n := kv[0].strip_edges()
		var m := int(kv[1]) if kv.size() > 1 else bit
		labels.append(nicify(n) if n.find(" ") < 0 else n)
		masks.append(str(m))
		bit = m << 1 if kv.size() > 1 and m > 0 else bit << 1
	return [labels, masks]


## Build the field of PropertyField `pf` for property `info` with value
## `v`: a part element (role "field") with Unity's names and classes
## (measured: ed-propertyfield, ed-inspector). `inspector` adds the
## InspectorElement classes. Returns the field element; the caller adds it
## to `pf`.
static func property_field_content(pf: UxmlElement, info: Dictionary, v: Variant, inspector: bool) -> UxmlElement:
	var prop := String(info.get("name", ""))
	var spec := field_for(info, v)
	var tag: String = spec[0]
	var field := UxmlParts.part(pf, tag, "field", "unity-input-" + prop)
	var label = pf.get_attribute("label")
	var text := property_label(prop) if label == null else String(label)
	var attrs: Dictionary = spec[1]
	field.attributes.append({"name": "label", "value": text, "offset": 0})
	for k in attrs:
		field.attributes.append({"name": k, "value": String(attrs[k]), "offset": 0})
	if tag == "Label":
		field.attributes = [{"name": "name", "value": "unity-input-" + prop, "offset": 0},
			{"name": "text", "value": "%s: %s" % [text, attrs.get("text", "")], "offset": 0}]
	UxmlParts._build_nested(field)
	var cls := ["unity-base-field__aligned"]
	if inspector:
		cls.append("unity-base-field__inspector-field")
	UxmlParts._add_control_classes(field, cls)
	var lp := UxmlParts.find_part(field, "label")
	if lp != null:
		UxmlParts._append_class(lp, "unity-property-field__label")
	var ip := UxmlParts.find_part(field, "input")
	if ip == null:
		ip = UxmlParts.find_part(field, "container")
	if ip != null and tag != "Label":
		UxmlParts._append_class(ip, "unity-property-field__input")
	if inspector:
		UxmlParts._add_control_classes(pf, ["unity-property-field__inspector-property"])
	if tag == "ObjectField" or tag == "CurveField" or tag == "GradientField":
		field.set_meta(&"uxml_initial_value", v)
		if tag == "ObjectField":
			object_display(field, v)
	return field


## The ObjectField display parts for value `v`: the label text, the
## --value-null class and the icon size (Unity's 16x16 icon, clamped by
## the icon's max size). Returns true when a part changed.
static func object_display(el: UxmlElement, v: Variant) -> bool:
	var changed := false
	var label := UxmlParts.find_part(el, "display-label")
	var icon := UxmlParts.find_part(el, "icon")
	var null_v := v == null or (v is Object and not is_instance_valid(v))
	if label != null:
		var t := object_label(el, v)
		if label.get_attribute("text") != t:
			_set_attr_quiet(label, "text", t)
			changed = true
		var has := UxmlParts.control_classes(label).has("unity-object-field-display__label--value-null")
		if has != null_v:
			if label.changed.is_valid():
				UxmlParts.toggle_control_class(label, "unity-object-field-display__label--value-null", null_v)
			else:
				var cc := UxmlParts.control_classes(label).duplicate()
				if null_v:
					cc.append("unity-object-field-display__label--value-null")
				else:
					cc.remove_at(cc.find("unity-object-field-display__label--value-null"))
				label.set_meta(UxmlParts.META_CLASSES, cc)
				var base: PackedStringArray = []
				for c in String(label.get_attribute("class")).split(" ", false):
					if c != "unity-object-field-display__label--value-null":
						base.append(c)
				_set_attr_quiet(label, "class", UxmlParts.merged_class(label, " ".join(base)))
			changed = true
	if icon != null:
		changed = _set_style(icon, "" if null_v else "width: 16px; height: 16px;") or changed
	return changed


## The PropertyFields of an InspectorElement for `obj`: one per editor
## property (script variables first are as listed by Godot), the script
## first and disabled, as Unity lists m_Script. Returns the PropertyField
## elements; each has the meta `uxml_property` (the property info) and
## the value.
static func inspector_properties(obj: Object) -> Array:
	var out: Array = []
	if obj == null:
		return out
	var script = obj.get_script()
	if script != null:
		out.append({"name": "script", "type": TYPE_OBJECT, "hint": PROPERTY_HINT_RESOURCE_TYPE,
			"hint_string": "Script", "class_name": "Script", "usage": PROPERTY_USAGE_DEFAULT, "_script": true})
	for p in obj.get_property_list():
		var usage := int(p["usage"])
		if usage & PROPERTY_USAGE_EDITOR == 0:
			continue
		if usage & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP) != 0:
			continue
		if String(p["name"]) == "script" or String(p["name"]).begins_with("metadata/"):
			continue
		if script != null and usage & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue  # a scripted object lists its own variables, as Unity lists serialized fields
		out.append(p)
	return out


## Build the PropertyFields of InspectorElement `insp` for `obj` into its
## content part (model only). Returns the PropertyField elements.
static func inspector_content(insp: UxmlElement, obj: Object) -> Array:
	var content := UxmlParts.content_container(insp)
	var out: Array = []
	for info in inspector_properties(obj):
		var name := String(info["name"])
		# Unity's name of the script property is m_Script.
		var shown := "m_Script" if info.get("_script", false) else name
		var pf := UxmlParts.part(insp, "PropertyField", "property", "PropertyField:" + shown)
		pf.attributes.append({"name": "binding-path", "value": name, "offset": 0})
		var v = obj.get_script() if info.get("_script", false) else obj.get(name)
		var shown_info: Dictionary = info.duplicate()
		shown_info["name"] = shown
		var field := property_field_content(pf, shown_info, v, true)
		pf.children.append(field)
		if info.get("_script", false):
			# Unity shows m_Script disabled: the PropertyField is disabled.
			UxmlParts._add_control_classes(pf, ["unity-disabled"])
			pf.attributes.append({"name": "enabled", "value": "false", "offset": 0})
		pf.set_meta(&"uxml_property", info)
		content.children.append(pf)
		out.append(pf)
	return out


# ---------------------------------------------------------------------------
# Layout-dependent styles (runtime and bench/parity.gd)
# ---------------------------------------------------------------------------

## Unity's ProgressBar.CalculateOppositeProgressWidth for the alpha bar of a
## ColorField: right = w - max(w x alpha, 1) in px, w = floor(background
## width - 2) (measured: ed-colorfield, right 124.5098px for alpha 128 at
## 252px). Returns true when the style changed.
static func color_alpha_layout(el: UxmlElement, size_of: Callable) -> bool:
	var pb := UxmlParts.find_part(el, "alpha-progress")
	if pb == null or pb.get_attribute("style") == UxmlParts.HIDDEN:
		return false
	var bg := UxmlParts.find_part(pb, "background")
	var prog := UxmlParts.find_part(pb, "progress")
	if bg == null or prog == null:
		return false
	var s = size_of.call(bg)
	if s == null or (s as Vector2).x <= 0.0:
		return false
	var w := floorf((s as Vector2).x - 2.0)
	var v := UssValues.parse_number(_attr(pb, "value", "0")) / 100.0
	var right := w - maxf(w * clampf(v, 0.0, 1.0), 1.0)
	var want := "right: %spx;" % _n(right)
	var cur = prog.get_attribute("style")
	if cur != null and String(cur) == want:
		return false
	prog.set_attribute("style", want)
	return true


## Every layout-dependent style of the editor controls under `root`:
## the ColorField alpha bars and the InspectorElement label alignment.
static func layout_styles(root: UxmlElement, size_of: Callable, rect_of: Callable, style_of: Callable) -> bool:
	var changed := false
	for el in root.walk():
		if el.local == "ColorField":
			changed = color_alpha_layout(el, size_of) or changed
	return align_labels(root, rect_of, style_of) or changed

## Unity's BaseField.AlignLabel for a field with `unity-base-field__aligned`
## inside an InspectorElement: label min-width = 123 - spacing - field
## padding, width = (inspector width + 1) x 0.45 - (37 + spacing + field
## padding),
## where spacing is the field's x offset in the inspector's content box.
## `rect_of(el)` gives the panel-space Rect2 (or null); `style_of(el)` the
## computed style. Returns true when a label style changed.
static func align_labels(root: UxmlElement, rect_of: Callable, style_of: Callable, parents: Dictionary = {}) -> bool:
	var changed := false
	for insp in root.walk():
		if insp.local != "InspectorElement":
			continue
		var ir = rect_of.call(insp)
		if ir == null:
			continue
		var ist: Dictionary = style_of.call(insp)
		var ipad := UxmlInputParts.style_px(ist, "padding-left")
		for f in insp.walk():
			if f == insp or not UxmlParts.control_classes(f).has("unity-base-field__aligned"):
				continue
			var label := UxmlParts.find_part(f, "label")
			var fr = rect_of.call(f)
			if label == null or fr == null:
				continue
			var fst: Dictionary = style_of.call(f)
			var fpad := UxmlInputParts.style_px(fst, "padding-left")
			var spacing: float = (fr as Rect2).position.x - (ir as Rect2).position.x - ipad
			var min_w := maxf(LABEL_BASE_MIN_WIDTH - spacing - fpad, 0.0)
			var w := maxf(0.0, ((ir as Rect2).size.x + LABEL_EXTRA_CONTEXT_WIDTH) * LABEL_WIDTH_RATIO
				- (LABEL_EXTRA_PADDING + spacing + fpad))
			var want := "min-width: %spx; width: %spx;" % [_n(min_w), _n(w)]
			var cur = label.get_attribute("style")
			if cur != null and String(cur) == want:
				continue
			if cur != null and _close_style(String(cur), min_w, w):
				continue
			label.set_attribute("style", want)
			changed = true
	return changed


## Unity writes a new label width only when it moved by more than 1e-4.
static func _close_style(cur: String, min_w: float, w: float) -> bool:
	var parts := cur.replace("min-width:", "").replace("width:", "").replace("px", "").split(";", false)
	if parts.size() < 2:
		return false
	return absf(float(parts[0]) - min_w) < 1e-4 and absf(float(parts[1]) - w) < 1e-4
