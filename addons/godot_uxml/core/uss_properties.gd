class_name UssProperties
extends RefCounted
## Which properties inherit, how shorthands split, and which property names
## are inside the supported subset.
##
## Ported from vendor/uxml-preview/src/style/properties.ts (Apache-2.0).
## Shorthand expansion belongs to the cascade rather than to layout: once a
## sheet contains both `padding` and `padding-top`, deciding which one wins is
## a cascade question, and it cannot be answered without splitting first.

## Properties a child picks up from its parent when it declares nothing.
## Custom properties (`--*`) also inherit — that is what makes the
## design-token pattern work.
const INHERITED := {
	"color": true,
	"font-size": true,
	"letter-spacing": true,
	"word-spacing": true,
	"visibility": true,
	"white-space": true,
	"-unity-font": true,
	"-unity-font-definition": true,
	"-unity-font-style": true,
	"-unity-paragraph-spacing": true,
	"-unity-text-align": true,
	"-unity-text-outline-color": true,
	"-unity-text-outline-width": true,
}

## Property names inside the planned support envelope — the dedicated flex
## subset layout plus the appearance properties the final scope requires.
## Anything else still parses and cascades (the cascade is about which value
## wins, not what the value means) but the resolver reports it as
## `unsupported-property` so a typo or an out-of-scope feature is never
## silent. Until the layout/runtime milestone lands, EVERY property is
## declaration-only: being listed here means "in scope", not "renders".
##
## Deliberately outside the envelope (warn today): absolute positioning
## (position/left/top/right/bottom), overflow, opacity, cursor,
## picking-mode, letter/word/paragraph spacing, and -unity-text-outline-*.
const SUPPORTED := {
	# display
	"display": true, "visibility": true,
	# flex
	"flex": true, "flex-direction": true, "flex-wrap": true,
	"flex-grow": true, "flex-shrink": true, "flex-basis": true,
	"justify-content": true, "align-items": true, "align-self": true,
	"align-content": true, "gap": true, "row-gap": true, "column-gap": true,
	# positioning
	"position": true, "top": true, "right": true, "bottom": true, "left": true,
	# box
	"width": true, "height": true,
	"min-width": true, "min-height": true, "max-width": true, "max-height": true,
	"margin": true, "margin-top": true, "margin-right": true,
	"margin-bottom": true, "margin-left": true,
	"padding": true, "padding-top": true, "padding-right": true,
	"padding-bottom": true, "padding-left": true,
	"border-width": true,
	"border-top-width": true, "border-right-width": true,
	"border-bottom-width": true, "border-left-width": true,
	"border-color": true,
	"border-top-color": true, "border-right-color": true,
	"border-bottom-color": true, "border-left-color": true,
	"border-radius": true,
	"border-top-left-radius": true, "border-top-right-radius": true,
	"border-bottom-right-radius": true, "border-bottom-left-radius": true,
	# background & text
	"background-color": true, "background-image": true,
	"color": true, "font-size": true, "white-space": true,
	"-unity-font": true, "-unity-font-definition": true,
	"-unity-font-style": true, "-unity-text-align": true,
	# 9-slice backgrounds, image tint, text outline
	"-unity-slice-left": true, "-unity-slice-right": true,
	"-unity-slice-top": true, "-unity-slice-bottom": true,
	"-unity-slice-scale": true,
	"-unity-background-image-tint-color": true,
	"-unity-text-outline": true,
	"-unity-text-outline-width": true, "-unity-text-outline-color": true,
}

## Shorthand -> longhands. Radii run clockwise from the top-left corner,
## not top/right/bottom/left.
const BOX_SHORTHANDS := {
	"margin": ["margin-top", "margin-right", "margin-bottom", "margin-left"],
	"padding": ["padding-top", "padding-right", "padding-bottom", "padding-left"],
	"border-width": [
		"border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
	],
	"border-color": [
		"border-top-color", "border-right-color", "border-bottom-color", "border-left-color",
	],
	"border-radius": [
		"border-top-left-radius", "border-top-right-radius",
		"border-bottom-right-radius", "border-bottom-left-radius",
	],
}


static func is_inherited(property: String) -> bool:
	return property.begins_with("--") or INHERITED.has(property)


static func is_supported(property: String) -> bool:
	return property.begins_with("--") or SUPPORTED.has(property)


## Split a value on top-level whitespace, keeping `rgb(1, 2, 3)` in one piece.
static func split_value(value: String) -> Array:
	var parts: Array = []
	var depth := 0
	var start := -1
	for i in value.length():
		var c := value.unicode_at(i)
		if c == 40:
			depth += 1
		elif c == 41:
			depth = maxi(0, depth - 1)
		var space := depth == 0 and (c == 32 or c == 9 or c == 10 or c == 13 or c == 12)
		if space:
			if start >= 0:
				parts.append(value.substr(start, i - start))
				start = -1
		elif start < 0:
			start = i
	if start >= 0:
		parts.append(value.substr(start))
	return parts


## top, right, bottom, left from the CSS 1-to-4 value pattern.
static func _box(values: Array) -> Variant:
	if values.is_empty():
		return null
	var a = values[0]
	var b = values[1] if values.size() > 1 else a
	var c = values[2] if values.size() > 2 else a
	var d = values[3] if values.size() > 3 else b
	return [a, b, c, d]


static var _re_number := RegEx.create_from_string("^-?(\\d+\\.?\\d*|\\.\\d+)$")


static func _is_number(value: String) -> bool:
	return _re_number.search(value) != null


static func _expand_flex(values: Array) -> Array:
	if values.is_empty():
		return []
	var a: String = values[0]
	if a == "none":
		return [["flex-grow", "0"], ["flex-shrink", "0"], ["flex-basis", "auto"]]
	if a == "auto":
		return [["flex-grow", "1"], ["flex-shrink", "1"], ["flex-basis", "auto"]]

	if values.size() == 1:
		if _is_number(a):
			return [["flex-grow", a], ["flex-shrink", "1"], ["flex-basis", "0"]]
		return [["flex-grow", "1"], ["flex-shrink", "1"], ["flex-basis", a]]

	var b: String = values[1]
	if values.size() == 2:
		if _is_number(b):
			return [["flex-grow", a], ["flex-shrink", b], ["flex-basis", "0"]]
		return [["flex-grow", a], ["flex-shrink", "1"], ["flex-basis", b]]

	return [["flex-grow", a], ["flex-shrink", b], ["flex-basis", values[2]]]


## One declaration -> the longhand declarations it stands for, as
## [[property, value], ...]. Returns [[property, value]] unchanged for
## anything it does not split.
## A shorthand whose arity is outside its grammar (gap: 3+ values, box
## shorthand: 5+ values, flex: 4+ values) is invalid at parse time: the
## expansion is empty, so the declaration contributes nothing to the
## cascade — an earlier valid declaration still wins. The resolver
## diagnoses the empty expansion.
static func expand_shorthand(property: String, value: String) -> Array:
	if property == "flex":
		var flex_values := split_value(value)
		if flex_values.size() > 3:
			return []
		return _expand_flex(flex_values)

	# gap: <row-gap> [<column-gap>] — expanding here keeps cascade order
	# honest: a later row-gap longhand beats an earlier gap shorthand and
	# vice versa.
	if property == "gap":
		var parts := split_value(value)
		if parts.is_empty():
			return [[property, value]]
		if parts.size() > 2:
			return []
		var col: String = parts[1] if parts.size() > 1 else parts[0]
		return [["row-gap", parts[0]], ["column-gap", col]]

	# -unity-text-outline: <width> <color> (either order, either optional).
	if property == "-unity-text-outline":
		var w := ""
		var c := ""
		for part in split_value(value):
			if w.is_empty() and (part.ends_with("px") or _is_number(part)):
				w = part
			elif c.is_empty():
				c = part
			else:
				return []
		var out_o: Array = []
		if not w.is_empty():
			out_o.append(["-unity-text-outline-width", w])
		if not c.is_empty():
			out_o.append(["-unity-text-outline-color", c])
		return out_o

	var targets = BOX_SHORTHANDS.get(property)
	if targets == null:
		return [[property, value]]

	var split := split_value(value)
	if split.size() > 4:
		return []
	var values := _box(split)
	if values == null:
		return [[property, value]]
	var out: Array = []
	for i in targets.size():
		out.append([targets[i], values[i]])
	return out
