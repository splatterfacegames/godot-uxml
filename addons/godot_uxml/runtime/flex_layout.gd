class_name UxmlFlexLayout
extends RefCounted
## The authored flex subset: turns the element tree plus computed USS styles
## into border-box Rect2s, in the coordinate space of each element's parent
## control.
##
## This is a pure geometry pass — it never touches a Control. Native
## intrinsic sizes arrive through `measurer`
## (element, computed_style, content_width_hint) -> Vector2, called only for
## elements with no layout children; containers are measured from their
## children. The hint is the content-box width the text will actually get
## (for wrapped-label measurement), or -1 when indefinite.
##
## Semantics follow the USS defaults the reference engine writes into Yoga
## (vendor/uxml-preview/src/layout/yoga.ts + render/values.ts):
##   flex-direction column, flex-shrink 1, flex-grow 0, align-items stretch,
##   box-sizing border-box (width includes padding and border), display flex.
##
## Supported subset (everything else was already diagnosed by the cascade):
##   row/column + -reverse, wrap/wrap-reverse, px/%/auto sizes, basis,
##   grow/shrink, min/max, margins, padding, border widths, gap/row-gap/
##   column-gap, justify-content, align-items/align-self, align-content.
## Percentage bases (CSS): width/min/max/margin/padding/column-gap resolve
## against the containing block's content WIDTH; height/row-gap against its
## content HEIGHT; flex-basis against the container's content main size.
## A percentage against an indefinite axis falls back to auto.
## Margins live outside the border box — they consume flow space but are
## never added to the element's own size.
## display:none consumes no space; visibility:hidden lays out normally
## (the applier hides the control).
##
## ScrollView elements lay their children out inside a scroll content box
## whose width is the viewport width minus the vertical scrollbar (reserved
## only when the content actually overflows — the same two-pass Unity uses).
## Their computed content size is reported in "content_sizes" so the host
## can size the scroll container's content child.

const EPS := 0.01
const JUSTIFY := ["flex-start", "center", "flex-end", "space-between", "space-around", "space-evenly"]
const ALIGN := ["flex-start", "center", "flex-end", "stretch", "baseline"]
const ALIGN_CONTENT := ["flex-start", "center", "flex-end", "stretch", "space-between", "space-around", "space-evenly"]
const DIRECTIONS := ["column", "row", "column-reverse", "row-reverse"]
const WRAPS := ["nowrap", "wrap", "wrap-reverse"]

var _styles: Dictionary = {}
var _measurer: Callable
var _warnings: Array = []
var _warned: Dictionary = {}
var _rects: Dictionary = {}
var _content_sizes: Dictionary = {}
var _insets: Dictionary = {}
var _source: String = ""
var _file: String = ""
var _scroll_bar_width: float = 0.0


## Compute layout for `root` inside `host_size`. `options` may carry
## "source"/"file" (diagnostic locations), "scroll_bar_width", and
## "warned" — a caller-owned Dictionary the dedupe set is shared through,
## so repeated computes (restyles) do not re-emit the same warning into a
## warnings array that accumulates.
## Returns {"rects": {element: Rect2}, "content_sizes": {element: Vector2},
## "insets": {element: [Vector2 start, Vector2 end]}} — start/end are the
## resolved padding+border edges (the content-box insets) the runtime uses
## to inset wrapped natives the flex pass does not position itself.
static func compute(
	root: UxmlElement,
	styles: Dictionary,
	host_size: Vector2,
	measurer: Callable,
	warnings: Array,
	options: Dictionary = {}
) -> Dictionary:
	var l := UxmlFlexLayout.new()
	l._styles = styles
	l._measurer = measurer
	l._warnings = warnings
	l._source = String(options.get("source", ""))
	l._file = String(options.get("file", ""))
	l._scroll_bar_width = float(options.get("scroll_bar_width", 0.0))
	if options.has("warned"):
		l._warned = options["warned"]
	l._layout(root, Rect2(Vector2.ZERO, host_size), host_size.x)
	return {
		"rects": l._rects,
		"content_sizes": l._content_sizes,
		"insets": l._insets,
	}


# ---------------------------------------------------------------------------
# Style access
# ---------------------------------------------------------------------------

func _prop(el: UxmlElement, name: String) -> Variant:
	var entry = _styles.get(el, {}).get(name)
	return null if entry == null else entry["value"]


func _str(el: UxmlElement, name: String, default: String) -> String:
	var v = _prop(el, name)
	return default if v == null else String(v)


func _num(el: UxmlElement, name: String, default: float) -> float:
	var v = _prop(el, name)
	if v == null:
		return default
	var n := UssValues.parse_number(String(v))
	if is_nan(n):
		_warn_once(el, name, '%s: "%s" is not a number; %s used' % [name, v, default])
		return default
	return n


func _enum(el: UxmlElement, name: String, valid: Array, default: String) -> String:
	var v := _str(el, name, default)
	if valid.has(v):
		return v
	_warn_once(el, name, '%s: "%s" is not supported; %s used' % [name, v, default])
	return default


## A length value: {auto: bool, v: float}. `auto` covers the auto/none
## keywords, unparseable text (warned once), and percentages against an
## indefinite base (base < 0).
func _len(el: UxmlElement, name: String, base: float) -> Dictionary:
	var raw = _prop(el, name)
	if raw == null:
		return {"auto": true, "v": 0.0}
	var p := UssValues.parse_length(String(raw))
	match p["kind"]:
		"px":
			return {"auto": false, "v": p["value"]}
		"percent":
			if base < 0.0:
				return {"auto": true, "v": 0.0}
			return {"auto": false, "v": base * p["value"] / 100.0}
		"invalid":
			_warn_once(el, name, "%s: %s" % [name, p["problem"]])
			return {"auto": true, "v": 0.0}
		_:
			return {"auto": true, "v": 0.0}


## A box dimension (width/height/flex-basis): px value, or -1 for auto.
func _dim(el: UxmlElement, name: String, base: float) -> float:
	var r := _len(el, name, base)
	return -1.0 if r["auto"] else r["v"]


## A min/max bound. is_min: -1 means "no declared bound" (the caller decides
## the auto floor); !is_min: INF means none.
func _bound(el: UxmlElement, name: String, base: float, is_min: bool) -> float:
	if _prop(el, name) == null:
		return -1.0 if is_min else INF
	var r := _len(el, name, base)
	if r["auto"]:
		return -1.0 if is_min else INF
	return r["v"]


## margin/padding edges {t,r,b,l} in px. Percentages resolve against the
## containing block width, like CSS. `auto` margins are not part of the USS
## subset — diagnosed once and treated as 0. Margins may be negative (CSS
## semantics: they pull the box, and neighbors, backward); padding may not —
## a negative padding is invalid and diagnosed rather than silently clamped.
func _edges(
	el: UxmlElement, prefix: String, cb_width: float, allow_negative: bool = false
) -> Dictionary:
	var out := {}
	for side in ["top", "right", "bottom", "left"]:
		var name := "%s-%s" % [prefix, side]
		var raw = _prop(el, name)
		if raw == null:
			out[side[0]] = 0.0
			continue
		if String(raw).strip_edges() == "auto":
			_warn_once(el, name, "%s: auto is not supported; 0 used" % name)
			out[side[0]] = 0.0
			continue
		var r := _len(el, name, cb_width)
		if r["auto"]:
			out[side[0]] = 0.0
		elif r["v"] < 0.0 and not allow_negative:
			_warn_once(el, name, "%s: negative values are invalid; 0 used" % name)
			out[side[0]] = 0.0
		else:
			out[side[0]] = r["v"]
	return out


## Border widths {t,r,b,l} in px — USS borders are px-only; anything else is
## diagnosed and treated as 0.
func _borders(el: UxmlElement, cb_width: float) -> Dictionary:
	var out := {}
	for side in ["top", "right", "bottom", "left"]:
		var name := "border-%s-width" % side
		var raw = _prop(el, name)
		if raw == null:
			out[side[0]] = 0.0
			continue
		var p := UssValues.parse_length(String(raw))
		if p["kind"] == "px":
			out[side[0]] = maxf(0.0, p["value"])
		else:
			if p["kind"] == "invalid":
				_warn_once(el, name, "%s: %s" % [name, p["problem"]])
			elif p["kind"] == "percent":
				_warn_once(el, name, "%s: percentages are not supported for border width" % name)
			out[side[0]] = 0.0
	return out


func _margins(el: UxmlElement, cb_width: float) -> Dictionary:
	return _edges(el, "margin", cb_width, true)


## The gap named `name` ("row-gap"/"column-gap"). The `gap` shorthand is
## expanded by the cascade (UssProperties.expand_shorthand), so the computed
## style only ever carries longhands — reading `gap` here would bypass the
## shorthand/longhand ordering the cascade already resolved.
## base is the content size on the gap's axis.
func _gap(el: UxmlElement, name: String, base: float) -> float:
	var raw = _prop(el, name)
	if raw == null:
		return 0.0
	var p := UssValues.parse_length(String(raw))
	match p["kind"]:
		"px":
			return maxf(0.0, p["value"])
		"percent":
			return 0.0 if base < 0.0 else maxf(0.0, base * p["value"] / 100.0)
		"invalid":
			_warn_once(el, name, "%s: %s" % [name, p["problem"]])
	return 0.0


func _warn_once(el: UxmlElement, prop: String, message: String) -> void:
	var key := "%s:%s" % [prop, message]
	if _warned.has(key):
		return
	_warned[key] = true
	_warnings.append(UxmlDiagnostic.make(
		"unsupported-value", message, _source, el.open_tag_start, _file
	))


# ---------------------------------------------------------------------------
# Element classification
# ---------------------------------------------------------------------------

## Children that participate in flex layout: visual elements that are not
## display:none. UXML/Style are document structure, never boxes.
func _flex_children(el: UxmlElement) -> Array:
	var out: Array = []
	for child in el.children:
		if UssControls.is_non_visual(child.local):
			continue
		var display := _str(child, "display", "flex")
		if display == "none":
			continue
		if display != "flex":
			_warn_once(child, "display", 'display: "%s" is not supported; flex used' % display)
		out.append(child)
	return out


func _is_scroll(el: UxmlElement) -> bool:
	return el.local == "ScrollView"


func _is_row(el: UxmlElement) -> bool:
	var d := _enum(el, "flex-direction", DIRECTIONS, "column")
	return d == "row" or d == "row-reverse"


func _reverse_main(el: UxmlElement) -> bool:
	return _enum(el, "flex-direction", DIRECTIONS, "column").ends_with("-reverse")


# ---------------------------------------------------------------------------
# Measuring (natural/intrinsic sizes)
# ---------------------------------------------------------------------------

## Natural border-box size of `el`. avail components < 0 mean indefinite;
## avail.x is the containing block's content width (the percentage base for
## width, margins and padding). border_w_hint, when >= 0, is the border-box
## width the element will actually get — the row case lets a wrapped label
## report its real height at the width the line assigned it.
func _measure(
	el: UxmlElement,
	avail: Vector2,
	border_w_hint: float = -1.0
) -> Vector2:
	var w := _dim(el, "width", avail.x)
	var h := _dim(el, "height", avail.y)
	var pad := _edges(el, "padding", avail.x)
	var bor := _borders(el, avail.x)
	var in_w: float = pad["l"] + pad["r"] + bor["l"] + bor["r"]
	var in_h: float = pad["t"] + pad["b"] + bor["t"] + bor["b"]
	var kids := _flex_children(el)
	var bw: float
	var bh: float
	if kids.is_empty():
		var hint := -1.0
		if border_w_hint >= 0.0:
			hint = maxf(0.0, border_w_hint - in_w)
		elif w >= 0.0:
			hint = maxf(0.0, w - in_w)
		var intr: Vector2 = _measurer.call(el, _styles.get(el, {}), hint)
		bw = w if w >= 0.0 else intr.x + in_w
		bh = h if h >= 0.0 else intr.y + in_h
	else:
		var cw := w - in_w if w >= 0.0 else -1.0
		var ch := h - in_h if h >= 0.0 else -1.0
		var nat := _measure_content(el, Vector2(cw, ch))
		# Native chrome (e.g. a ScrollContainer's scrollbars) can floor the
		# auto size, but an authored px/% always wins.
		var chrome: Vector2 = _measurer.call(el, _styles.get(el, {}), cw)
		bw = w if w >= 0.0 else maxf(nat.x, chrome.x) + in_w
		bh = h if h >= 0.0 else maxf(nat.y, chrome.y) + in_h
	# The border box can never be smaller than its own padding+border —
	# the floor overrides explicit dims and max bounds alike (Yoga).
	return Vector2(
		maxf(
			clampf(bw, _min_or(el, "min-width", avail.x, 0.0), _max_or(el, "max-width", avail.x)),
			in_w
		),
		maxf(
			clampf(bh, _min_or(el, "min-height", avail.y, 0.0), _max_or(el, "max-height", avail.y)),
			in_h
		)
	)


func _min_or(el: UxmlElement, name: String, base: float, fallback: float) -> float:
	var b := _bound(el, name, base, true)
	return fallback if b < 0.0 else b


func _max_or(el: UxmlElement, name: String, base: float) -> float:
	return _bound(el, name, base, false)


## Natural content-box size of a container's children (no padding/border).
func _measure_content(el: UxmlElement, cavail: Vector2) -> Vector2:
	var kids := _flex_children(el)
	if kids.is_empty():
		return Vector2.ZERO
	var row := _is_row(el)
	var wrap := _enum(el, "flex-wrap", WRAPS, "nowrap") != "nowrap"
	var main := 0 if row else 1
	var cross := 1 - main
	var gap_m := _gap(el, "column-gap" if row else "row-gap", cavail[main])
	var gap_c := _gap(el, "row-gap" if row else "column-gap", cavail[cross])
	var lines: Array = []
	var cur := {"main": 0.0, "cross": 0.0, "n": 0}
	for child in kids:
		var msz := _measure(child, cavail)
		var m := _margins(child, cavail.x)
		var o_main: float
		var o_cross: float
		if row:
			o_main = msz.x + m["l"] + m["r"]
			o_cross = msz.y + m["t"] + m["b"]
		else:
			o_main = msz.y + m["t"] + m["b"]
			o_cross = msz.x + m["l"] + m["r"]
		if (
			wrap and cavail[main] >= 0.0 and cur["n"] > 0
			and cur["main"] + gap_m + o_main > cavail[main] + EPS
		):
			lines.append(cur)
			cur = {"main": 0.0, "cross": 0.0, "n": 0}
		cur["main"] += (gap_m if cur["n"] > 0 else 0.0) + o_main
		cur["cross"] = maxf(cur["cross"], o_cross)
		cur["n"] += 1
	if cur["n"] > 0:
		lines.append(cur)
	var out := Vector2.ZERO
	for i in lines.size():
		out[main] = maxf(out[main], lines[i]["main"])
		out[cross] += lines[i]["cross"] + (gap_c if i > 0 else 0.0)
	return out


# ---------------------------------------------------------------------------
# Arranging
# ---------------------------------------------------------------------------

## Lay out `el`'s subtree inside border-box `rect`. Positions are emitted in
## the coordinate space native Control.position uses: el's rect is relative
## to its parent's border-box origin, and el's children are positioned
## relative to el's own border-box origin — so `content` starts at the
## padding+border inset, not at rect.position.
func _layout(el: UxmlElement, rect: Rect2, cb_width: float) -> void:
	_rects[el] = rect
	var pad := _edges(el, "padding", cb_width)
	var bor := _borders(el, cb_width)
	# The resolved content-box insets — the runtime insets internal chrome
	# (field caption/native, scroll viewport, image rect) the flex pass
	# does not itself position.
	_insets[el] = [
		Vector2(bor["l"] + pad["l"], bor["t"] + pad["t"]),
		Vector2(bor["r"] + pad["r"], bor["b"] + pad["b"]),
	]
	var inner := Vector2(bor["l"] + pad["l"], bor["t"] + pad["t"])
	var content := Rect2(
		inner,
		Vector2(
			maxf(0.0, rect.size.x - (pad["l"] + pad["r"] + bor["l"] + bor["r"])),
			maxf(0.0, rect.size.y - (pad["t"] + pad["b"] + bor["t"] + bor["b"]))
		)
	)
	var kids := _flex_children(el)
	if kids.is_empty():
		_content_sizes[el] = Vector2.ZERO
		return
	if _is_scroll(el):
		_layout_scroll(el, content, pad, bor, kids)
		return
	_content_sizes[el] = _place(el, content, kids)


## ScrollView children live inside a scroll content box that is as wide as
## the viewport allows and as tall as the content needs. Positions are
## emitted in the content control's coordinate space, whose origin is the
## element's top-left (padding and border offset the content inside it).
func _layout_scroll(
	el: UxmlElement,
	content: Rect2,
	pad: Dictionary,
	bor: Dictionary,
	kids: Array
) -> void:
	var pad_bor := Vector2(pad["l"] + bor["l"], pad["t"] + bor["t"])
	var avail_w := content.size.x
	var nat := _measure_content(el, Vector2(avail_w, -1.0))
	if nat.y > content.size.y + EPS and _scroll_bar_width > 0.0:
		# Content overflows vertically: reserve the scrollbar width and
		# measure again, matching Unity's two-pass settle.
		avail_w = maxf(0.0, avail_w - _scroll_bar_width)
		nat = _measure_content(el, Vector2(avail_w, -1.0))
	var content_h := maxf(nat.y, content.size.y)
	var area := Rect2(pad_bor, Vector2(avail_w, content_h))
	_place(el, area, kids)
	# Children start at the padding/border inset; the content box spans from
	# the content control's origin to the furthest child edge.
	_content_sizes[el] = Vector2(avail_w, nat.y) + pad_bor


## The flex algorithm proper: place `kids` inside `area` (positions are
## emitted relative to area's coordinate space) and return the used content
## extent. This one routine handles row/column, wrap, grow/shrink, justify
## and align for normal containers and for ScrollView content.
func _place(el: UxmlElement, area: Rect2, kids: Array) -> Vector2:
	var row := _is_row(el)
	var wrap_mode := _enum(el, "flex-wrap", WRAPS, "nowrap")
	var justify := _enum(el, "justify-content", JUSTIFY, "flex-start")
	var align_items := _enum(el, "align-items", ALIGN, "stretch")
	var align_content := _enum(el, "align-content", ALIGN_CONTENT, "flex-start")
	var main := 0 if row else 1
	var cross := 1 - main
	var am := area.size[main]
	var ac := area.size[cross]
	var gap_m := _gap(el, "column-gap" if row else "row-gap", am)
	var gap_c := _gap(el, "row-gap" if row else "column-gap", ac)
	var size_prop := "width" if row else "height"
	var cross_prop := "height" if row else "width"

	# Hypothetical main sizes, with min/max already applied.
	var items: Array = []
	for child in kids:
		var m := _margins(child, area.size.x)
		var nat := _measure(child, area.size)
		var hyp: float
		var basis := _len(child, "flex-basis", am)
		if not basis["auto"]:
			hyp = basis["v"]
		else:
			var explicit := _dim(child, size_prop, am)
			hyp = explicit if explicit >= 0.0 else nat[main]
		# A flex item's automatic CONTENT minimum is 0 — Yoga does not
		# floor flex items at their content size: verified against
		# installed yoga-layout 3.2.1, a 200px item holding 160px of
		# content shrinks to 150 in a 300px row. The border box, though,
		# never shrinks below the resolved padding+border total on that
		# axis (a w80 child with 24px padding + 4px border in a 20px row
		# ends 28, not 20) — and that floor also overrides explicit dims
		# and authored max bounds.
		var mn := _bound(child, "min-" + size_prop, am, true)
		if mn < 0.0:
			mn = 0.0
		var mx := _bound(child, "max-" + size_prop, am, false)
		var pads := _edges(child, "padding", area.size.x)
		var bors := _borders(child, area.size.x)
		var in_main: float
		var in_cross: float
		if row:
			in_main = pads["l"] + pads["r"] + bors["l"] + bors["r"]
			in_cross = pads["t"] + pads["b"] + bors["t"] + bors["b"]
		else:
			in_main = pads["t"] + pads["b"] + bors["t"] + bors["b"]
			in_cross = pads["l"] + pads["r"] + bors["l"] + bors["r"]
		mn = maxf(mn, in_main)
		mx = maxf(mx, mn)
		items.append({
			"el": child, "m": m, "nat": nat,
			"main": clampf(hyp, mn, mx),
			"min": mn, "max": mx, "in_cross": in_cross,
			"grow": maxf(0.0, _num(child, "flex-grow", 0.0)),
			"shrink": maxf(0.0, _num(child, "flex-shrink", 1.0)),
			"frozen": false,
			"cross": 0.0, "nat_cross": 0.0, "pos": 0.0, "cross_pos": 0.0,
		})

	# Lines: one when nowrap, else split on hypothetical outer main size.
	var lines: Array = []
	if wrap_mode == "nowrap":
		lines.append({"items": items, "cross": 0.0, "pos": 0.0})
	else:
		var cur: Array = []
		var cur_main := 0.0
		for it in items:
			var outer: float = it["main"] + _mtotal(it["m"], main)
			var need: float = (gap_m if not cur.is_empty() else 0.0) + outer
			if not cur.is_empty() and cur_main + need > am + EPS:
				lines.append({"items": cur, "cross": 0.0, "pos": 0.0})
				cur = []
				cur_main = 0.0
				need = outer
			cur_main += need
			cur.append(it)
		lines.append({"items": cur, "cross": 0.0, "pos": 0.0})

	# Grow/shrink within each line.
	for line in lines:
		_flex_line(line["items"], am, gap_m, main)

	# Cross sizes: explicit or natural, then the line cross is the max outer.
	for line in lines:
		var line_cross := 0.0
		for it in line["items"]:
			var explicit := _dim(it["el"], cross_prop, ac)
			var nat: float
			if explicit >= 0.0:
				nat = explicit
			else:
				# For a row item the final main size is now known — measuring
				# with it lets wrapped text report the height it really needs.
				nat = _measure(
					it["el"], area.size,
					it["main"] if row else -1.0
				)[cross]
			# Cross sizes floor at the cross-axis padding+border total the
			# same way the main axis does — an explicit dim or max bound
			# below it cannot produce a negative content box.
			var cmin := maxf(
				_min_or(it["el"], "min-" + cross_prop, ac, 0.0), it["in_cross"])
			nat = clampf(
				nat, cmin,
				maxf(_max_or(it["el"], "max-" + cross_prop, ac), cmin)
			)
			it["nat_cross"] = nat
			line_cross = maxf(line_cross, nat + _mtotal(it["m"], cross))
		line["cross"] = line_cross

	# The container's cross space distributed over lines (align-content).
	var nlines := lines.size()
	var lines_cross := 0.0
	for i in nlines:
		lines_cross += lines[i]["cross"] + (gap_c if i > 0 else 0.0)
	if wrap_mode == "nowrap" and ac >= 0.0:
		lines[0]["cross"] = ac
		lines_cross = ac
	elif wrap_mode != "nowrap" and ac >= 0.0 and align_content == "stretch" and ac > lines_cross:
		var extra := (ac - lines_cross) / nlines
		for line in lines:
			line["cross"] += extra
		lines_cross = ac

	var free_c := ac - lines_cross if ac >= 0.0 else 0.0
	var cpos := area.position[cross]
	var cstep := gap_c
	match align_content:
		"center":
			cpos += free_c / 2.0
		"flex-end":
			cpos += free_c
		"space-between":
			cstep += free_c / (nlines - 1) if nlines > 1 else 0.0
		"space-around":
			var u := free_c / nlines
			cpos += u / 2.0
			cstep += u
		"space-evenly":
			var u2 := free_c / (nlines + 1)
			cpos += u2
			cstep += u2
	for line in lines:
		line["pos"] = cpos
		cpos += line["cross"] + cstep
	if wrap_mode == "wrap-reverse" and ac >= 0.0:
		for line in lines:
			line["pos"] = (
				area.position[cross] + ac
				- (line["pos"] - area.position[cross]) - line["cross"]
			)

	# Main-axis positions within each line (justify-content).
	for line in lines:
		var li: Array = line["items"]
		var used := gap_m * maxf(0.0, li.size() - 1.0)
		for it in li:
			used += it["main"] + _mtotal(it["m"], main)
		var free := am - used
		var start := 0.0
		var step := gap_m
		match justify:
			"center":
				start = free / 2.0
			"flex-end":
				start = free
			"space-between":
				step += free / (li.size() - 1) if li.size() > 1 else 0.0
			"space-around":
				var u := free / li.size()
				start = u / 2.0
				step += u
			"space-evenly":
				var u2 := free / (li.size() + 1)
				start = u2
				step += u2
		var cursor := area.position[main] + start
		for it in li:
			it["pos"] = cursor + it["m"]["l" if row else "t"]
			cursor += _mtotal(it["m"], main) + it["main"] + step
		if _reverse_main(el):
			for it in li:
				var outer_start: float = it["pos"] - it["m"]["l" if row else "t"]
				var outer_len: float = _mtotal(it["m"], main) + it["main"]
				it["pos"] = (
					2.0 * area.position[main] + am
					- outer_start - outer_len + it["m"]["l" if row else "t"]
				)

	# Cross position and final cross size per item (align-items/align-self).
	for line in lines:
		for it in line["items"]:
			var al := _str(it["el"], "align-self", "auto")
			if al == "auto":
				al = align_items
			if not ALIGN.has(al):
				_warn_once(it["el"], "align-self", 'align-self: "%s" is not supported; flex-start used' % al)
				al = "flex-start"
			if al == "baseline":
				_warn_once(it["el"], "align-items", "baseline alignment is not supported; flex-start used")
				al = "flex-start"
			var mct := _mtotal(it["m"], cross)
			if al == "stretch" and _dim(it["el"], cross_prop, ac) < 0.0:
				# Stretch still honors min/max — a max-height:30 item in a
				# 100-high line stretches to 30, not 100 — and the
				# padding+border floor applies here too.
				var smin := maxf(
					_min_or(it["el"], "min-" + cross_prop, ac, 0.0), it["in_cross"])
				it["cross"] = clampf(
					maxf(0.0, line["cross"] - mct),
					smin,
					maxf(_max_or(it["el"], "max-" + cross_prop, ac), smin)
				)
			else:
				it["cross"] = it["nat_cross"]
			var mc_start: float = it["m"]["t" if row else "l"]
			var mc_end: float = it["m"]["b" if row else "r"]
			match al:
				"center":
					it["cross_pos"] = line["pos"] + (line["cross"] - it["cross"] - mct) / 2.0 + mc_start
				"flex-end":
					it["cross_pos"] = line["pos"] + line["cross"] - it["cross"] - mc_end
				_:
					it["cross_pos"] = line["pos"] + mc_start

	# Emit rects and recurse.
	var extent := Vector2.ZERO
	for line in lines:
		for it in line["items"]:
			var pos := Vector2.ZERO
			pos[main] = it["pos"]
			pos[cross] = it["cross_pos"]
			var size := Vector2.ZERO
			size[main] = it["main"]
			size[cross] = it["cross"]
			_layout(it["el"], Rect2(pos, size), area.size.x)
			var mend: float = it["m"]["r" if row else "b"]
			var mcend: float = it["m"]["b" if row else "r"]
			extent[main] = maxf(extent[main], pos[main] + size[main] + mend - area.position[main])
			extent[cross] = maxf(extent[cross], pos[cross] + size[cross] + mcend - area.position[cross])
	return extent


## Distribute a line's free main-axis space: grow when positive, shrink
## (scaled by basis) when negative, freezing items that hit min/max and
## redistributing until stable — bounded by the item count.
func _flex_line(items: Array, am: float, gap_m: float, main: int) -> void:
	for _iter in range(items.size() + 1):
		var used := gap_m * maxf(0.0, items.size() - 1.0)
		for it in items:
			used += it["main"] + _mtotal(it["m"], main)
		var free := am - used
		if absf(free) < EPS:
			break
		var froze := false
		if free > 0.0:
			var gsum := 0.0
			for it in items:
				if not it["frozen"]:
					gsum += it["grow"]
			if gsum <= 0.0:
				break
			var eff := free if gsum >= 1.0 else free * gsum
			for it in items:
				if it["frozen"] or it["grow"] <= 0.0:
					continue
				var target: float = it["main"] + eff * it["grow"] / gsum
				if target > it["max"] + EPS:
					it["main"] = it["max"]
					it["frozen"] = true
					froze = true
				elif target < it["min"] - EPS:
					it["main"] = it["min"]
					it["frozen"] = true
					froze = true
				else:
					it["main"] = target
		else:
			var ssum := 0.0
			for it in items:
				if not it["frozen"]:
					ssum += it["shrink"] * it["main"]
			if ssum <= 0.0:
				break
			var eff := -free if ssum >= 1.0 else -free * ssum
			for it in items:
				if it["frozen"] or it["shrink"] <= 0.0:
					continue
				var target: float = it["main"] - eff * it["shrink"] * it["main"] / ssum
				if target < it["min"] - EPS:
					it["main"] = it["min"]
					it["frozen"] = true
					froze = true
				elif target > it["max"] + EPS:
					it["main"] = it["max"]
					it["frozen"] = true
					froze = true
				else:
					it["main"] = target
		if not froze:
			break


# Total margin along an axis index (0=x,1=y).
func _mtotal(m: Dictionary, axis: int) -> float:
	return m["l"] + m["r"] if axis == 0 else m["t"] + m["b"]
