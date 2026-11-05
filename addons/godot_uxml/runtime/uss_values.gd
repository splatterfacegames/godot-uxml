class_name UssValues
extends RefCounted
## Interpreting USS declaration values for the runtime: lengths, numbers,
## colors, url() references.
##
## The cascade keeps declarations as author-written strings; this is the one
## place that turns them into typed values. Ported from
## vendor/uxml-preview/src/render/values.ts (Apache-2.0) with the color and
## url() handling the native runtime needs.
##
## Nothing here throws: an unreadable value returns a `problem` string so the
## caller can emit a diagnostic and fall back.

## Units USS does not have. Reported, never silently treated as pixels.
const UNSUPPORTED_UNITS := [
	"em", "rem", "vh", "vw", "vmin", "vmax", "pt", "cm", "in", "ch", "ex", "pc", "mm", "q",
]

static var _re_length := RegEx.create_from_string("^(-?(?:\\d+\\.?\\d*|\\.\\d+))([a-zA-Z%]*)$")
static var _re_number := RegEx.create_from_string("^-?(\\d+\\.?\\d*|\\.\\d+)$")


## "6px" / "50%" / "auto" / "none" / "0" ->
##   {kind: "px"|"percent"|"auto"|"none", value: float}
## or {kind: "invalid", problem: String} for anything unreadable.
## Memoized by text: the cascade keeps author strings, so the same few
## hundred values are re-read on every layout/apply. Results are shared —
## callers treat them as read-only.
static func parse_length(text: String) -> Dictionary:
	var hit = _c_parse_length.get(text)
	if hit != null:
		return hit
	if _c_parse_length.size() > 8192:
		_c_parse_length.clear()
	var out := _parse_length_uncached(text)
	_c_parse_length[text] = out
	return out


static var _c_parse_length := {}


static func _parse_length_uncached(text: String) -> Dictionary:
	var value := text.strip_edges()
	if value.is_empty():
		return {"kind": "invalid", "problem": "empty value"}
	if value == "auto" or value == "initial":
		return {"kind": "auto", "value": 0.0}
	if value == "none":
		return {"kind": "none", "value": 0.0}
	if value.begins_with("calc("):
		return {"kind": "invalid", "problem": "calc() is not supported in USS"}
	var m := _re_length.search(value)
	if m == null:
		return {"kind": "invalid", "problem": 'cannot read "%s" as a length' % value}
	var number := m.get_string(1).to_float()
	var unit := m.get_string(2).to_lower()
	if unit.is_empty() or unit == "px":
		return {"kind": "px", "value": number}
	if unit == "%":
		return {"kind": "percent", "value": number}
	if UNSUPPORTED_UNITS.has(unit):
		return {"kind": "invalid", "problem": '"%s" is not a USS unit' % unit}
	return {"kind": "invalid", "problem": 'unknown unit "%s"' % unit}


## Bare numbers such as `flex-grow: 1`. NAN when the text is not a number.
## Memoized by text: the cascade keeps author strings, so the same few
## hundred values are re-read on every layout/apply. Results are shared —
## callers treat them as read-only.
static func parse_number(text: String) -> float:
	var hit = _c_parse_number.get(text)
	if hit != null:
		return hit
	if _c_parse_number.size() > 8192:
		_c_parse_number.clear()
	var out := _parse_number_uncached(text)
	_c_parse_number[text] = out
	return out


static var _c_parse_number := {}


static func _parse_number_uncached(text: String) -> float:
	var value := text.strip_edges()
	if _re_number.search(value) == null:
		return NAN
	return value.to_float()


## url("x.png") / url('x.png') / url(x.png) -> the reference text.
## resource("name") (Unity Resources lookup) returns the whole text as
## `path`; UxmlResourceResolver.resolve() searches the Resources folders for
## it. A bare path with no wrapper is accepted for convenience and returned
## as-is.
## Memoized by text: the cascade keeps author strings, so the same few
## hundred values are re-read on every layout/apply. Results are shared —
## callers treat them as read-only.
static func parse_url(text: String) -> Dictionary:
	var hit = _c_parse_url.get(text)
	if hit != null:
		return hit
	if _c_parse_url.size() > 8192:
		_c_parse_url.clear()
	var out := _parse_url_uncached(text)
	_c_parse_url[text] = out
	return out


static var _c_parse_url := {}


static func _parse_url_uncached(text: String) -> Dictionary:
	var value := text.strip_edges()
	if value.is_empty():
		return {"ok": false, "path": "", "problem": "empty reference"}
	if value.begins_with("resource("):
		# Unity Resources lookup: the whole text goes to
		# UxmlResourceResolver.resolve, which searches the Resources folders.
		if UxmlResourceResolver.resource_name(value).is_empty():
			return {"ok": false, "path": "", "problem": 'malformed resource(): "%s"' % value}
		return {"ok": true, "path": value, "problem": ""}
	if not value.begins_with("url("):
		return {"ok": true, "path": value, "problem": ""}
	var close := value.rfind(")")
	if close < 0:
		return {"ok": false, "path": "", "problem": "unterminated url()"}
	if close != value.length() - 1:
		return {"ok": false, "path": "", "problem": 'trailing characters after url(): "%s"' % value.substr(close + 1)}
	var inner := value.substr(4, close - 4).strip_edges()
	if inner.is_empty():
		return {"ok": false, "path": "", "problem": "empty url()"}
	var q := inner.unicode_at(0)
	if q == 34 or q == 39:  # opening " or '
		if inner.length() < 2 or inner.unicode_at(inner.length() - 1) != q:
			return {"ok": false, "path": "", "problem": "mismatched quotes in url()"}
		inner = inner.substr(1, inner.length() - 2).strip_edges()
		if inner.is_empty():
			return {"ok": false, "path": "", "problem": "empty url()"}
	elif inner.unicode_at(inner.length() - 1) == 34 or inner.unicode_at(inner.length() - 1) == 39:
		return {"ok": false, "path": "", "problem": "mismatched quotes in url()"}
	return {"ok": true, "path": inner, "problem": ""}


# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------

## CSS named colors — the subset a stylesheet is likely to use. USS accepts
## the same spellings Unity does; anything not in this table and not a
## hex/rgb() value comes back with a problem rather than a wrong color.
const NAMED_COLORS := {
	"transparent": Color(0, 0, 0, 0),
	"black": Color.BLACK,
	"white": Color.WHITE,
	"red": Color.RED,
	# CSS green is #008000 — Godot's Color.GREEN is #00ff00 (CSS "lime").
	"green": Color(0.0, 128.0 / 255.0, 0.0),
	"blue": Color.BLUE,
	"yellow": Color.YELLOW,
	"cyan": Color.CYAN,
	"magenta": Color.MAGENTA,
	"gray": Color(0.50196, 0.50196, 0.50196),
	"grey": Color(0.50196, 0.50196, 0.50196),
	"silver": Color(0.75294, 0.75294, 0.75294),
	"maroon": Color(0.50196, 0.0, 0.0),
	"olive": Color(0.50196, 0.50196, 0.0),
	"lime": Color(0, 1, 0),
	"aqua": Color(0, 1, 1),
	"teal": Color(0.0, 0.50196, 0.50196),
	"navy": Color(0, 0, 0.50196),
	"fuchsia": Color(1, 0, 1),
	"purple": Color(0.50196, 0, 0.50196),
	"orange": Color(1, 0.647, 0),
	"brown": Color(0.647, 0.165, 0.165),
	"pink": Color(1, 0.753, 0.796),
	"gold": Color(1, 0.843, 0),
	"khaki": Color(0.941, 0.902, 0.549),
	"indigo": Color(0.294, 0, 0.51),
	"violet": Color(0.933, 0.51, 0.933),
	"coral": Color(1, 0.498, 0.314),
	"salmon": Color(0.98, 0.502, 0.447),
	"tomato": Color(1, 0.388, 0.278),
	"crimson": Color(0.863, 0.078, 0.235),
	"skyblue": Color(0.529, 0.808, 0.922),
	"steelblue": Color(0.275, 0.51, 0.706),
	"darkgray": Color(0.663, 0.663, 0.663),
	"darkgrey": Color(0.663, 0.663, 0.663),
	"lightgray": Color(0.827, 0.827, 0.827),
	"lightgrey": Color(0.827, 0.827, 0.827),
	"dimgray": Color(0.412, 0.412, 0.412),
	"dimgrey": Color(0.412, 0.412, 0.412),
	"rebeccapurple": Color(0.4, 0.2, 0.6),
}

static var _re_hex := RegEx.create_from_string("^#([0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")


## "#rgb" / "#rrggbb" / "#rrggbbaa" / rgb(r,g,b) / rgba(r,g,b,a) / named ->
## {color: Color} or {color: null-ish, problem: String}.
## Memoized by text: the cascade keeps author strings, so the same few
## hundred values are re-read on every layout/apply. Results are shared —
## callers treat them as read-only.
static func parse_color(text: String) -> Dictionary:
	var hit = _c_parse_color.get(text)
	if hit != null:
		return hit
	if _c_parse_color.size() > 8192:
		_c_parse_color.clear()
	var out := _parse_color_uncached(text)
	_c_parse_color[text] = out
	return out


static var _c_parse_color := {}


static func _parse_color_uncached(text: String) -> Dictionary:
	var value := text.strip_edges().to_lower()
	if value.is_empty():
		return {"color": Color.TRANSPARENT, "ok": false, "problem": "empty value"}
	if NAMED_COLORS.has(value):
		return {"color": NAMED_COLORS[value], "ok": true, "problem": ""}
	if _re_hex.search(value) != null:
		return {"color": Color.html(value), "ok": true, "problem": ""}
	if value.begins_with("rgb(") or value.begins_with("rgba("):
		var close := value.rfind(")")
		if close < 0:
			return {"color": Color.TRANSPARENT, "ok": false, "problem": "unterminated rgb()"}
		if close != value.length() - 1:
			return {
				"color": Color.TRANSPARENT, "ok": false,
				"problem": 'trailing characters after rgb(): "%s"' % value.substr(close + 1),
			}
		var inner := value.substr(value.find("(") + 1, close - value.find("(") - 1)
		var parts := inner.split(",")
		var expected := 4 if value.begins_with("rgba(") else 3
		if parts.size() != expected:
			return {
				"color": Color.TRANSPARENT, "ok": false,
				"problem": 'rgb() expects %d components, got %d' % [expected, parts.size()],
			}
		var comps: Array = []
		for i in parts.size():
			var t := String(parts[i]).strip_edges()
			var pct := t.ends_with("%")
			if pct:
				t = t.substr(0, t.length() - 1)
			if not t.is_valid_float():
				return {
					"color": Color.TRANSPARENT, "ok": false,
					"problem": 'cannot read "%s" as a color component' % parts[i],
				}
			var v := t.to_float()
			if i < 3:
				# Color channels: 0-255, or a percentage of 255.
				comps.append(clampf(v * 255.0 / 100.0 if pct else v, 0.0, 255.0))
			else:
				# Alpha: 0-1, or a percentage.
				comps.append(clampf(v / 100.0 if pct else v, 0.0, 1.0))
		var a: float = comps[3] if comps.size() == 4 else 1.0
		return {
			"color": Color(comps[0] / 255.0, comps[1] / 255.0, comps[2] / 255.0, a),
			"ok": true, "problem": "",
		}
	return {
		"color": Color.TRANSPARENT, "ok": false,
		"problem": 'cannot read "%s" as a color' % text.strip_edges(),
	}


# ---------------------------------------------------------------------------
# Visual properties (opacity, transforms, text shadow, backgrounds, cursor)
# ---------------------------------------------------------------------------
# Each parser follows Unity 6 StylePropertyReader / StylePropertyReaderHelper
# and returns a shared, memoized Dictionary with `ok` and, when false, a
# `problem` string. Callers treat the results as read-only.

static var _c_visual := {}


static func _memo(kind: String, text: String, fn: Callable) -> Dictionary:
	var key := kind + "|" + text
	var hit = _c_visual.get(key)
	if hit != null:
		return hit
	if _c_visual.size() > 8192:
		_c_visual.clear()
	var out: Dictionary = fn.call(text.strip_edges())
	_c_visual[key] = out
	return out


static func _bad(problem: String) -> Dictionary:
	return {"ok": false, "problem": problem}


## <number>, clamped to 0..1 (Unity clamps the resolved opacity).
static func parse_opacity(text: String) -> Dictionary:
	return _memo("opacity", text, _opacity)


static func _opacity(v: String) -> Dictionary:
	var n := parse_number(v)
	if is_nan(n):
		return _bad('opacity: "%s" is not a number' % v)
	return {"ok": true, "value": clampf(n, 0.0, 1.0)}


## A <length> | <percentage> component -> [px, ratio] (one of them nonzero).
static func _len_pct(part: String) -> Variant:
	var p := parse_length(part)
	match p["kind"]:
		"px":
			return [float(p["value"]), 0.0]
		"percent":
			return [0.0, float(p["value"]) / 100.0]
	return null


## translate: none | <lp> [<lp> <length>?]? -> {px: Vector2, ratio: Vector2}.
## One value translates both axes; the z component is accepted and ignored.
## A percentage is of the element's own size.
static func parse_translate(text: String) -> Dictionary:
	return _memo("translate", text, _translate)


static func _translate(v: String) -> Dictionary:
	if v == "none":
		return {"ok": true, "px": Vector2.ZERO, "ratio": Vector2.ZERO}
	var parts := UssProperties.split_value(v)
	if parts.is_empty() or parts.size() > 3:
		return _bad('translate: "%s" expects 1 to 3 values' % v)
	var x = _len_pct(parts[0])
	var y = x if parts.size() == 1 else _len_pct(parts[1])
	if x == null or y == null:
		return _bad('translate: "%s" is not a px or %% length' % v)
	if parts.size() == 3 and parse_length(parts[2])["kind"] != "px":
		return _bad('translate: z "%s" is not a length' % parts[2])
	return {"ok": true, "px": Vector2(x[0], y[0]), "ratio": Vector2(x[1], y[1])}


## <angle> in deg | rad | grad | turn (a bare number is degrees) -> radians,
## NAN when unreadable.
static func parse_angle(text: String) -> float:
	var v := text.strip_edges().to_lower()
	for pair in [["grad", PI / 200.0], ["turn", TAU], ["deg", PI / 180.0], ["rad", 1.0]]:
		var u: String = pair[0]
		if v.ends_with(u):
			var n := parse_number(v.substr(0, v.length() - u.length()))
			return NAN if is_nan(n) else n * float(pair[1])
	var bare := parse_number(v)
	return NAN if is_nan(bare) else deg_to_rad(bare)


## rotate: none | <angle> | [x|y|z|<number>{3}] && <angle> -> {angle}.
## Godot rotates a Control in the screen plane only, so an axis other than
## z is a problem.
static func parse_rotate(text: String) -> Dictionary:
	return _memo("rotate", text, _rotate)


static func _rotate(v: String) -> Dictionary:
	if v == "none":
		return {"ok": true, "angle": 0.0}
	var parts := UssProperties.split_value(v)
	var angle := NAN
	var axis_ok := true
	match parts.size():
		1:
			angle = parse_angle(parts[0])
		2:
			var a: String = parts[0]
			var b: String = parts[1]
			if ["x", "y", "z"].has(b.to_lower()):
				var t := a
				a = b
				b = t
			angle = parse_angle(b)
			axis_ok = a.to_lower() == "z"
		4:
			angle = parse_angle(parts[3])
			var ax := parse_number(parts[0])
			var ay := parse_number(parts[1])
			var az := parse_number(parts[2])
			if is_nan(ax) or is_nan(ay) or is_nan(az):
				return _bad('rotate: "%s" has a non-numeric axis' % v)
			axis_ok = is_zero_approx(ax) and is_zero_approx(ay) and az > 0.0
		_:
			return _bad('rotate: "%s" expects an angle, optionally with an axis' % v)
	if is_nan(angle):
		return _bad('rotate: "%s" has no readable angle (deg, rad, grad or turn)' % v)
	if not axis_ok:
		return _bad('rotate: "%s" turns about a 3D axis; only z rotation is supported' % v)
	return {"ok": true, "angle": angle}


## scale: none | <number>{1,3} -> {scale: Vector2}. One value scales both
## axes; z is accepted and ignored.
static func parse_scale(text: String) -> Dictionary:
	return _memo("scale", text, _scale)


static func _scale(v: String) -> Dictionary:
	if v == "none":
		return {"ok": true, "scale": Vector2.ONE}
	var parts := UssProperties.split_value(v)
	if parts.is_empty() or parts.size() > 3:
		return _bad('scale: "%s" expects 1 to 3 numbers' % v)
	var nums: Array = []
	for p in parts:
		var n := parse_number(p)
		if is_nan(n):
			# Unity reads the number of a dimension too (scale: 2px is 2).
			var l := parse_length(p)
			if l["kind"] != "px":
				return _bad('scale: "%s" is not a number' % p)
			n = float(l["value"])
		nums.append(n)
	var sx: float = nums[0]
	var sy: float = sx if nums.size() == 1 else nums[1]
	return {"ok": true, "scale": Vector2(sx, sy)}


## One transform-origin component -> [px, ratio, can_be_x, can_be_y].
static func _origin_part(part: String) -> Variant:
	match part.to_lower():
		"left":
			return [0.0, 0.0, true, false]
		"right":
			return [0.0, 1.0, true, false]
		"top":
			return [0.0, 0.0, false, true]
		"bottom":
			return [0.0, 1.0, false, true]
		"center":
			return [0.0, 0.5, true, true]
	var lp = _len_pct(part)
	if lp == null:
		return null
	return [lp[0], lp[1], true, true]


## transform-origin (ReadTransformOrigin) -> {px: Vector2, ratio: Vector2}.
## Each axis defaults to 50%; keywords can come in either order; z is
## accepted and ignored.
static func parse_transform_origin(text: String) -> Dictionary:
	return _memo("origin", text, _transform_origin)


static func _transform_origin(v: String) -> Dictionary:
	var parts := UssProperties.split_value(v)
	if parts.is_empty() or parts.size() > 3:
		return _bad('transform-origin: "%s" expects 1 to 3 values' % v)
	var x := [0.0, 0.5]
	var y := [0.0, 0.5]
	var a = _origin_part(parts[0])
	if a == null:
		return _bad('transform-origin: "%s" is not a keyword, px or %% value' % parts[0])
	if parts.size() == 1:
		if a[2]:
			x = [a[0], a[1]]
		else:
			y = [a[0], a[1]]
	else:
		var b = _origin_part(parts[1])
		if b == null:
			return _bad('transform-origin: "%s" is not a keyword, px or %% value' % parts[1])
		if parts.size() == 3 and parse_length(parts[2])["kind"] != "px":
			return _bad('transform-origin: z "%s" is not a length' % parts[2])
		if a[2] and b[3]:
			x = [a[0], a[1]]
			y = [b[0], b[1]]
		elif b[2] and a[3]:
			x = [b[0], b[1]]
			y = [a[0], a[1]]
		else:
			return _bad('transform-origin: "%s" names the same axis twice' % v)
	return {"ok": true, "px": Vector2(x[0], y[0]), "ratio": Vector2(x[1], y[1])}


## text-shadow (ReadTextShadow): <length>{2,3} && <color>? ->
## {offset: Vector2, blur: float, color: Color}. Without a color the shadow
## is transparent, exactly as in Unity.
static func parse_text_shadow(text: String) -> Dictionary:
	return _memo("shadow", text, _text_shadow)


static func _text_shadow(v: String) -> Dictionary:
	if v == "none":
		return {"ok": true, "offset": Vector2.ZERO, "blur": 0.0, "color": Color(0, 0, 0, 0)}
	var lens: Array = []
	var color = null
	var color_at := -1
	for p in UssProperties.split_value(v):
		var l := parse_length(p)
		if l["kind"] == "px":
			lens.append(float(l["value"]))
			continue
		var c := parse_color(p)
		if not c["ok"] or color != null:
			return _bad('text-shadow: cannot read "%s"' % p)
		color = c["color"]
		color_at = lens.size()
	if lens.size() < 2 or lens.size() > 3:
		return _bad('text-shadow: "%s" expects 2 or 3 lengths and an optional color' % v)
	if color_at != -1 and color_at != 0 and color_at != lens.size():
		return _bad('text-shadow: "%s" puts the color between the lengths' % v)
	return {
		"ok": true, "offset": Vector2(lens[0], lens[1]),
		"blur": lens[2] if lens.size() == 3 else 0.0,
		"color": color if color != null else Color(0, 0, 0, 0),
	}


## background-position-x / -y (ReadBackgroundPosition):
##   <keyword> | <lp> | <keyword> <lp>
## -> {keyword: center|left|right|top|bottom, unit: "px"|"percent", value}.
## A bare length measures from the leading edge (left or top).
static func parse_background_position(text: String, vertical: bool) -> Dictionary:
	return _memo("bgpos-y" if vertical else "bgpos-x", text,
		_bg_pos_y if vertical else _bg_pos_x)


static func _bg_pos_x(v: String) -> Dictionary:
	return _bg_pos(v, false)


static func _bg_pos_y(v: String) -> Dictionary:
	return _bg_pos(v, true)


static func _bg_pos(v: String, vertical: bool) -> Dictionary:
	var prop := "background-position-y" if vertical else "background-position-x"
	var lead := "top" if vertical else "left"
	var trail := "bottom" if vertical else "right"
	var parts := UssProperties.split_value(v)
	var kw := ""
	var len_part := ""
	if parts.size() == 1:
		var w := String(parts[0]).to_lower()
		if w == "center" or w == lead or w == trail:
			kw = w
		else:
			kw = lead
			len_part = parts[0]
	elif parts.size() == 2:
		kw = String(parts[0]).to_lower()
		len_part = parts[1]
		if kw != lead and kw != trail:
			return _bad('%s: "%s" -- an offset needs %s or %s' % [prop, v, lead, trail])
	else:
		return _bad('%s: "%s" expects a keyword and/or one length' % [prop, v])
	var out := {"ok": true, "keyword": kw, "unit": "px", "value": 0.0}
	if not len_part.is_empty():
		var l := parse_length(len_part)
		if l["kind"] != "px" and l["kind"] != "percent":
			return _bad('%s: cannot read "%s" as px or %%' % [prop, len_part])
		out["unit"] = l["kind"]
		out["value"] = float(l["value"])
	return out


## background-repeat (ReadBackgroundRepeat) -> {x, y}, each one of
## repeat | space | round | no-repeat.
static func parse_background_repeat(text: String) -> Dictionary:
	return _memo("bgrep", text, _bg_repeat)


static func _bg_repeat(v: String) -> Dictionary:
	var parts := UssProperties.split_value(v.to_lower())
	var valid := ["repeat", "space", "round", "no-repeat"]
	if parts.size() == 1:
		if parts[0] == "repeat-x":
			return {"ok": true, "x": "repeat", "y": "no-repeat"}
		if parts[0] == "repeat-y":
			return {"ok": true, "x": "no-repeat", "y": "repeat"}
		if valid.has(parts[0]):
			return {"ok": true, "x": parts[0], "y": parts[0]}
	elif parts.size() == 2 and valid.has(parts[0]) and valid.has(parts[1]):
		return {"ok": true, "x": parts[0], "y": parts[1]}
	return _bad('background-repeat: "%s" is not repeat-x, repeat-y or 1-2 of repeat, space, round, no-repeat' % v)


## background-size (ReadBackgroundSize): [<lp>|auto]{1,2} | cover | contain
## -> {type: "length"|"cover"|"contain", x: [unit, value], y: [unit, value]}
## with unit "auto"|"px"|"percent". One length means `<x> auto`.
static func parse_background_size(text: String) -> Dictionary:
	return _memo("bgsize", text, _bg_size)


static func _bg_size(v: String) -> Dictionary:
	var parts := UssProperties.split_value(v.to_lower())
	if parts.size() == 1 and (parts[0] == "cover" or parts[0] == "contain"):
		return {"ok": true, "type": parts[0], "x": ["auto", 0.0], "y": ["auto", 0.0]}
	if parts.is_empty() or parts.size() > 2:
		return _bad('background-size: "%s" expects cover, contain or 1-2 sizes' % v)
	var axes: Array = []
	for p in parts:
		if p == "auto":
			axes.append(["auto", 0.0])
			continue
		var l := parse_length(p)
		if l["kind"] != "px" and l["kind"] != "percent":
			return _bad('background-size: cannot read "%s" as px, %% or auto' % p)
		axes.append([l["kind"], float(l["value"])])
	if axes.size() == 1:
		# Unity: one length sets x and leaves y auto; a lone `auto` is
		# auto on both axes.
		axes.append(["auto", 0.0])
	return {"ok": true, "type": "length", "x": axes[0], "y": axes[1]}


## Unity cursor keywords -> Control.CursorShape. Unity draws keyword cursors
## in Editor UI only; this runtime maps them to the nearest Godot shape.
const CURSOR_SHAPES := {
	"arrow": Control.CURSOR_ARROW,
	"text": Control.CURSOR_IBEAM,
	"resize-vertical": Control.CURSOR_VSIZE,
	"resize-horizontal": Control.CURSOR_HSIZE,
	"link": Control.CURSOR_POINTING_HAND,
	"slide-arrow": Control.CURSOR_HSIZE,
	"resize-up-right": Control.CURSOR_BDIAGSIZE,
	"resize-up-left": Control.CURSOR_FDIAGSIZE,
	"move-arrow": Control.CURSOR_MOVE,
	"rotate-arrow": Control.CURSOR_DRAG,
	"scale-arrow": Control.CURSOR_FDIAGSIZE,
	"arrow-plus": Control.CURSOR_CAN_DROP,
	"arrow-minus": Control.CURSOR_FORBIDDEN,
	"pan": Control.CURSOR_DRAG,
	"orbit": Control.CURSOR_DRAG,
	"zoom": Control.CURSOR_CROSS,
	"fps": Control.CURSOR_CROSS,
	"split-resize-up-down": Control.CURSOR_VSPLIT,
	"split-resize-left-right": Control.CURSOR_HSPLIT,
	"not-allowed": Control.CURSOR_FORBIDDEN,
}


## cursor (ReadCursor): <keyword> | [<url>|<resource>] [<int> <int>]? ->
## {kind: "keyword", shape} or {kind: "texture", ref, hotspot: Vector2}.
static func parse_cursor(text: String) -> Dictionary:
	return _memo("cursor", text, _cursor)


static func _cursor(v: String) -> Dictionary:
	var kw := v.to_lower()
	if CURSOR_SHAPES.has(kw):
		return {"ok": true, "kind": "keyword", "shape": CURSOR_SHAPES[kw]}
	var parts := UssProperties.split_value(v)
	if parts.is_empty():
		return _bad("cursor: empty value")
	var first: String = parts[0]
	if not (first.begins_with("url(") or first.begins_with("resource(")):
		return _bad('cursor: "%s" is not a Unity cursor keyword or a texture' % v)
	var hot := Vector2.ZERO
	if parts.size() == 3:
		var hx := parse_number(parts[1])
		var hy := parse_number(parts[2])
		if is_nan(hx) or is_nan(hy):
			return _bad('cursor: hotspot "%s %s" needs two integers' % [parts[1], parts[2]])
		hot = Vector2(hx, hy)
	elif parts.size() != 1:
		return _bad('cursor: "%s" expects a texture and an optional x y hotspot' % v)
	return {"ok": true, "kind": "texture", "ref": first, "hotspot": hot}


## letter-spacing / word-spacing / -unity-paragraph-spacing: a <length>
## that Unity's text generator reads in em/100 units (the value times
## font-size / 100 px). Returns that px amount; NAN when unreadable.
static func spacing_px(text: String, font_size: float) -> float:
	var l := parse_length(text)
	match l["kind"]:
		"px":
			return float(l["value"]) * font_size / 100.0
		"auto":
			return 0.0
	return NAN


# ---------------------------------------------------------------------------
# filter, -unity-material and -unity-text-auto-size (Unity 6.3)
# ---------------------------------------------------------------------------

## Unity's built-in filter functions (StyleValueFunction) plus `filter()`,
## the custom function that names a FilterFunctionDefinition asset.
const FILTER_FUNCTIONS := [
	"blur", "grayscale", "contrast", "hue-rotate", "invert", "opacity", "sepia", "tint", "filter",
]

static var _re_dimension := RegEx.create_from_string(
	"^([+-]?(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][+-]?\\d+)?)([a-zA-Z%]*)$")


## filter (StylePropertyReader.ReadListFilterFunction): `none` or one or
## more functions -> {ok, funcs: Array, problems: PackedStringArray}.
## Each function is {name, params: Array, ref: String}; a parameter is a
## float (StyleProperty.ConvertDimensionToFilterFloat: % / 100, angles in
## radians, ms / 1000, every other unit as written) or a Color. `ref` is the
## definition reference of `filter()` (url(), resource() or a quoted path).
## Unity rejects the whole value for an unknown function or an empty
## argument list (StyleSheetImportErrorCode.MissingFunctionArgument): ok is
## false. A built-in function with more than one argument keeps the first
## (Unity logs an error and the shader reads parameter 0): a problem.
static func parse_filter(text: String) -> Dictionary:
	return _memo("filter", text, _filter)


static func _filter(v: String) -> Dictionary:
	var out := {"ok": true, "funcs": [], "problems": PackedStringArray()}
	var low := v.to_lower()
	if low == "none" or low == "initial" or v.is_empty():
		return out
	var funcs: Array = []
	for tok in UssProperties.split_value(v):
		var t := String(tok)
		var open := t.find("(")
		if open <= 0 or not t.ends_with(")"):
			return _bad('filter: "%s" is not a filter function' % t)
		var name := t.substr(0, open).to_lower()
		if not FILTER_FUNCTIONS.has(name):
			return _bad('filter: "%s" is not a Unity filter function' % name)
		var args := _func_args(t.substr(open + 1, t.length() - open - 2))
		if args.is_empty():
			return _bad("filter: %s() needs an argument" % name)
		var fn := {"name": name, "params": [], "ref": ""}
		if name == "filter":
			var first: String = args[0]
			if first.begins_with("\"") or first.begins_with("'"):
				first = first.substr(1, first.length() - 2)
			fn["ref"] = first
			args.remove_at(0)
		if args.size() > 4:
			return _bad("filter: %s() takes at most 4 parameters" % name)
		for a in args:
			var p = _filter_param(String(a))
			if p == null:
				return _bad('filter: %s(): cannot read "%s"' % [name, a])
			fn["params"].append(p)
		if name != "filter" and fn["params"].size() != 1:
			out["problems"].append("filter: %s() takes 1 parameter, %d given; the first is used" % [name, fn["params"].size()])
		funcs.append(fn)
	out["funcs"] = funcs
	return out


## Arguments of a function call: split on top-level commas and white space
## (Unity tolerates commas between filter arguments).
static func _func_args(inner: String) -> Array:
	var out: Array = []
	var depth := 0
	var buf := ""
	for i in inner.length():
		var c := inner.unicode_at(i)
		if c == 40:
			depth += 1
		elif c == 41:
			depth = maxi(0, depth - 1)
		if depth == 0 and (c == 44 or c == 32 or c == 9 or c == 10 or c == 13):
			if not buf.strip_edges().is_empty():
				out.append(buf.strip_edges())
			buf = ""
		else:
			buf += inner[i]
	if not buf.strip_edges().is_empty():
		out.append(buf.strip_edges())
	return out


## One filter parameter: a color, or a number with an optional unit.
static func _filter_param(a: String):
	var m := _re_dimension.search(a)
	if m != null:
		var n := m.get_string(1).to_float()
		match m.get_string(2).to_lower():
			"%":
				return n * 0.01
			"deg":
				return deg_to_rad(n)
			"turn":
				return n * PI * 2.0
			"grad":
				return n * PI / 200.0
			"ms":
				return n * 0.001
			"", "px", "rad", "s":
				return n
		return null
	var c := parse_color(a)
	if c["ok"]:
		return c["color"]
	return null


## A filter parameter as Unity's FilterParameter.floatValue: a color
## parameter reads as 0.
static func filter_float(p) -> float:
	return float(p) if (p is float or p is int) else 0.0


## A filter parameter as FilterParameter.colorValue: a float parameter
## reads as Color.clear.
static func filter_color(p) -> Color:
	return p if p is Color else Color(0, 0, 0, 0)


## -unity-material (StyleProperty.TryGetMaterialDefinition):
## `none` | (url() | resource()) prop("name" value...)* ->
## {ok, ref: String, props: Array of {name, type, value}}. `type` is
## "float" (one number), "vector" (2 to 4 numbers, value a 4-float Array),
## "color" or "texture" (value the url()/resource() text).
static func parse_material(text: String) -> Dictionary:
	return _memo("material", text, _material)


static func _material(v: String) -> Dictionary:
	var low := v.to_lower()
	if low == "none" or low == "initial" or v.is_empty():
		return {"ok": true, "ref": "", "props": []}
	var parts := UssProperties.split_value(v)
	var first := String(parts[0])
	if not (first.begins_with("url(") or first.begins_with("resource(")):
		return _bad('-unity-material: "%s" is not url(), resource() or none' % first)
	var props: Array = []
	for k in range(1, parts.size()):
		var t := String(parts[k])
		if not (t.begins_with("prop(") and t.ends_with(")")):
			return _bad('-unity-material: "%s" is not prop("name" value)' % t)
		var args := _func_args(t.substr(5, t.length() - 6))
		if args.size() < 2:
			return _bad('-unity-material: %s needs a quoted name and a value' % t)
		var pname := String(args[0])
		if pname.length() < 2 or not ((pname.begins_with("\"") and pname.ends_with("\"")) or (pname.begins_with("'") and pname.ends_with("'"))):
			return _bad('-unity-material: %s: the property name must be quoted' % t)
		pname = pname.substr(1, pname.length() - 2)
		var a1 := String(args[1])
		if a1.begins_with("url(") or a1.begins_with("resource("):
			props.append({"name": pname, "type": "texture", "value": a1})
			continue
		var nums: Array = []
		for j in range(1, args.size()):
			var n := parse_number(String(args[j]))
			if is_nan(n):
				nums.clear()
				break
			nums.append(n)
		if not nums.is_empty() and nums.size() <= 4:
			if nums.size() == 1:
				props.append({"name": pname, "type": "float", "value": float(nums[0])})
			else:
				while nums.size() < 4:
					nums.append(0.0)
				props.append({"name": pname, "type": "vector", "value": nums})
			continue
		var c := parse_color(a1)
		if c["ok"] and args.size() == 2:
			props.append({"name": pname, "type": "color", "value": c["color"]})
			continue
		return _bad('-unity-material: %s: cannot read the value' % t)
	return {"ok": true, "ref": first, "props": props}


## -unity-text-auto-size (StylePropertyReaderHelper.ReadTextAutoSize):
## `none` | `best-fit <min> <max>` -> {ok, best_fit: bool, min, max} in px.
static func parse_text_auto_size(text: String) -> Dictionary:
	return _memo("autosize", text, _auto_size)


static func _auto_size(v: String) -> Dictionary:
	var parts := UssProperties.split_value(v)
	if parts.size() == 1 and (String(parts[0]).to_lower() == "none" or String(parts[0]).to_lower() == "initial"):
		return {"ok": true, "best_fit": false, "min": 10.0, "max": 100.0}
	if parts.size() != 3 or String(parts[0]).to_lower() != "best-fit":
		return _bad('-unity-text-auto-size: "%s" is not none or best-fit <min> <max>' % v)
	var lo := parse_length(String(parts[1]))
	var hi := parse_length(String(parts[2]))
	if lo["kind"] != "px" or hi["kind"] != "px":
		return _bad('-unity-text-auto-size: "%s": the sizes must be px lengths' % v)
	return {"ok": true, "best_fit": true, "min": float(lo["value"]), "max": float(hi["value"])}
