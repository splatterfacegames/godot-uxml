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
static func parse_length(text: String) -> Dictionary:
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
static func parse_number(text: String) -> float:
	var value := text.strip_edges()
	if _re_number.search(value) == null:
		return NAN
	return value.to_float()


## url("x.png") / url('x.png') / url(x.png) -> the reference text.
## resource("name") is Unity resource lookup — out of scope, returns a
## problem so the caller diagnoses instead of guessing. A bare path with no
## wrapper is accepted for convenience and returned as-is.
static func parse_url(text: String) -> Dictionary:
	var value := text.strip_edges()
	if value.is_empty():
		return {"ok": false, "path": "", "problem": "empty reference"}
	if value.begins_with("resource("):
		return {
			"ok": false, "path": "",
			"problem": "resource() lookup is not supported; use url() with a project path",
		}
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
static func parse_color(text: String) -> Dictionary:
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
