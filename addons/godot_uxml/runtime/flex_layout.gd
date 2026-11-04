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
##
## Performance notes (the algorithm above is unchanged, bit for bit):
##   * every per-element style read is memoized for the pass — padding /
##     border / margin edges per containing-block width, enums, flex
##     children, numbers — and value parsing is memoized by text in
##     UssValues, so the hot recursion does no regex or string building;
##   * _measure() results are memoized per (element, avail, hint) for
##     subtrees whose measurer is pure. options["volatile"] names elements
##     whose intrinsic size depends on measurer call history (a wrapping
##     Label is measured at the width the previous call left on it); any
##     subtree containing one is always measured for real, so the measurer
##     sees exactly the call sequence it always did;
##   * flex items are parallel packed arrays, not per-item Dictionaries.
## Diagnostics are deduplicated per (property, message) for the document's
## lifetime, so skipping a repeated identical call never drops a warning.

const EPS := 0.01
const JUSTIFY := ["flex-start", "center", "flex-end", "space-between", "space-around", "space-evenly"]
const ALIGN := ["flex-start", "center", "flex-end", "stretch", "baseline"]
const ALIGN_CONTENT := ["flex-start", "center", "flex-end", "stretch", "space-between", "space-around", "space-evenly"]
const DIRECTIONS := ["column", "row", "column-reverse", "row-reverse"]
const WRAPS := ["nowrap", "wrap", "wrap-reverse"]

const PAD_NAMES := ["padding-top", "padding-right", "padding-bottom", "padding-left"]
const MAR_NAMES := ["margin-top", "margin-right", "margin-bottom", "margin-left"]
const BOR_NAMES := ["border-top-width", "border-right-width", "border-bottom-width", "border-left-width"]
# Edge arrays are [t, r, b, l].
const T := 0
const R := 1
const B := 2
const L := 3

static var _empty_style := {}

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
var _volatile: Dictionary = {}

# Per-pass memos.
var _st := {}         # el -> style dict
var _pad_m := {}      # el -> [cb_width, PackedFloat64Array]
var _mar_m := {}      # el -> [cb_width, PackedFloat64Array]
var _bor_m := {}      # el -> PackedFloat64Array
var _kids_m := {}     # el -> Array
var _enum_m := {}     # el -> {prop: String}
var _num_m := {}      # el -> {prop: float}
var _meas_m := {}     # el -> Array of [ax, ay, hint, Vector2]
var _vol_m := {}      # el -> bool (subtree contains a volatile element)


## Compute layout for `root` inside `host_size`. `options` may carry
## "source"/"file" (diagnostic locations), "scroll_bar_width", "volatile"
## (see the class notes), and "warned" — a caller-owned Dictionary the
## dedupe set is shared through, so repeated computes (restyles) do not
## re-emit the same warning into a warnings array that accumulates.
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
	l._volatile = options.get("volatile", {})
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

func _style(el: UxmlElement) -> Dictionary:
	var s = _st.get(el)
	if s == null:
		s = _styles.get(el, _empty_style)
		_st[el] = s
	return s


func _prop(el: UxmlElement, name: String) -> Variant:
	var entry = _style(el).get(name)
	return null if entry == null else entry["value"]


func _str(el: UxmlElement, name: String, default: String) -> String:
	var v = _prop(el, name)
	return default if v == null else String(v)


func _num(el: UxmlElement, name: String, default: float) -> float:
	var m: Dictionary = _num_m.get(el, {})
	var hit = m.get(name)
	if hit != null:
		return hit
	var out := default
	var v = _prop(el, name)
	if v != null:
		var n := UssValues.parse_number(String(v))
		if is_nan(n):
			_warn_once(el, name, '%s: "%s" is not a number; %s used' % [name, v, default])
		else:
			out = n
	m[name] = out
	_num_m[el] = m
	return out


func _enum(el: UxmlElement, name: String, valid: Array, default: String) -> String:
	var m: Dictionary = _enum_m.get(el, {})
	var hit = m.get(name)
	if hit != null:
		return hit
	var v := _str(el, name, default)
	if not valid.has(v):
		_warn_once(el, name, '%s: "%s" is not supported; %s used' % [name, v, default])
		v = default
	m[name] = v
	_enum_m[el] = m
	return v


## A length value: NAN for auto. Auto covers the auto/none keywords,
## unparseable text (warned once), and percentages against an indefinite
## base (base < 0).
func _len(el: UxmlElement, name: String, base: float) -> float:
	var raw = _prop(el, name)
	if raw == null:
		return NAN
	return _len_raw(el, name, raw, base)


func _len_raw(el: UxmlElement, name: String, raw, base: float) -> float:
	var p := UssValues.parse_length(String(raw))
	match p["kind"]:
		"px":
			return p["value"]
		"percent":
			if base < 0.0:
				return NAN
			return base * p["value"] / 100.0
		"invalid":
			_warn_once(el, name, "%s: %s" % [name, p["problem"]])
			return NAN
		_:
			return NAN


## A box dimension (width/height/flex-basis): px value, or -1 for auto.
func _dim(el: UxmlElement, name: String, base: float) -> float:
	var r := _len(el, name, base)
	return -1.0 if is_nan(r) else r


## A min/max bound. is_min: -1 means "no declared bound" (the caller decides
## the auto floor); !is_min: INF means none.
func _bound(el: UxmlElement, name: String, base: float, is_min: bool) -> float:
	var raw = _prop(el, name)
	if raw == null:
		return -1.0 if is_min else INF
	var r := _len_raw(el, name, raw, base)
	if is_nan(r):
		return -1.0 if is_min else INF
	return r


## margin/padding edges [t,r,b,l] in px. Percentages resolve against the
## containing block width, like CSS. `auto` margins are not part of the USS
## subset — diagnosed once and treated as 0. Margins may be negative (CSS
## semantics: they pull the box, and neighbors, backward); padding may not —
## a negative padding is invalid and diagnosed rather than silently clamped.
func _edges(el: UxmlElement, names: Array, cb_width: float, allow_negative: bool) -> PackedFloat64Array:
	var out := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	var st := _style(el)
	for k in 4:
		var name: String = names[k]
		var entry = st.get(name)
		if entry == null:
			continue
		var raw = entry["value"]
		if String(raw).strip_edges() == "auto":
			_warn_once(el, name, "%s: auto is not supported; 0 used" % name)
			continue
		var r := _len_raw(el, name, raw, cb_width)
		if is_nan(r):
			continue
		elif r < 0.0 and not allow_negative:
			_warn_once(el, name, "%s: negative values are invalid; 0 used" % name)
		else:
			out[k] = r
	return out


func _padding(el: UxmlElement, cb_width: float) -> PackedFloat64Array:
	var m = _pad_m.get(el)
	if m != null and m[0] == cb_width:
		return m[1]
	var e := _edges(el, PAD_NAMES, cb_width, false)
	_pad_m[el] = [cb_width, e]
	return e


func _margins(el: UxmlElement, cb_width: float) -> PackedFloat64Array:
	var m = _mar_m.get(el)
	if m != null and m[0] == cb_width:
		return m[1]
	var e := _edges(el, MAR_NAMES, cb_width, true)
	_mar_m[el] = [cb_width, e]
	return e


## Border widths [t,r,b,l] in px — USS borders are px-only; anything else is
## diagnosed and treated as 0.
func _borders(el: UxmlElement) -> PackedFloat64Array:
	var m = _bor_m.get(el)
	if m != null:
		return m
	var out := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	var st := _style(el)
	for k in 4:
		var name: String = BOR_NAMES[k]
		var entry = st.get(name)
		if entry == null:
			continue
		var p := UssValues.parse_length(String(entry["value"]))
		if p["kind"] == "px":
			out[k] = maxf(0.0, p["value"])
		elif p["kind"] == "invalid":
			_warn_once(el, name, "%s: %s" % [name, p["problem"]])
		elif p["kind"] == "percent":
			_warn_once(el, name, "%s: percentages are not supported for border width" % name)
	_bor_m[el] = out
	return out


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
	var hit = _kids_m.get(el)
	if hit != null:
		return hit
	var out: Array = []
	for child in el.children:
		var local: String = child.local
		if local == "UXML" or local == "Style":
			continue
		var display := _str(child, "display", "flex")
		if display == "none":
			continue
		if display != "flex":
			_warn_once(child, "display", 'display: "%s" is not supported; flex used' % display)
		out.append(child)
	_kids_m[el] = out
	return out


func _is_row(el: UxmlElement) -> bool:
	var d := _enum(el, "flex-direction", DIRECTIONS, "column")
	return d == "row" or d == "row-reverse"


func _reverse_main(el: UxmlElement) -> bool:
	return _enum(el, "flex-direction", DIRECTIONS, "column").ends_with("-reverse")


func _has_volatile(el: UxmlElement) -> bool:
	if _volatile.is_empty():
		return false
	var hit = _vol_m.get(el)
	if hit != null:
		return hit
	var v := _volatile.has(el)
	if not v:
		for child in el.children:
			if _has_volatile(child):
				v = true
				break
	_vol_m[el] = v
	return v


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
	var memo: Array
	var pure := not _has_volatile(el)
	if pure:
		var m = _meas_m.get(el)
		if m != null:
			memo = m
			for e in memo:
				if e[0] == avail.x and e[1] == avail.y and e[2] == border_w_hint:
					return e[3]
		else:
			memo = []
			_meas_m[el] = memo
	var w := _dim(el, "width", avail.x)
	var h := _dim(el, "height", avail.y)
	var pad := _padding(el, avail.x)
	var bor := _borders(el)
	var in_w: float = pad[L] + pad[R] + bor[L] + bor[R]
	var in_h: float = pad[T] + pad[B] + bor[T] + bor[B]
	var kids := _flex_children(el)
	var bw: float
	var bh: float
	if kids.is_empty():
		var hint := -1.0
		if border_w_hint >= 0.0:
			hint = maxf(0.0, border_w_hint - in_w)
		elif w >= 0.0:
			hint = maxf(0.0, w - in_w)
		var intr: Vector2 = _measurer.call(el, _style_for_measure(el), hint)
		bw = w if w >= 0.0 else intr.x + in_w
		bh = h if h >= 0.0 else intr.y + in_h
	else:
		var cw := w - in_w if w >= 0.0 else -1.0
		var ch := h - in_h if h >= 0.0 else -1.0
		var nat := _measure_content(el, Vector2(cw, ch))
		# Native chrome (e.g. a ScrollContainer's scrollbars) can floor the
		# auto size, but an authored px/% always wins.
		var chrome: Vector2 = _measurer.call(el, _style_for_measure(el), cw)
		bw = w if w >= 0.0 else maxf(nat.x, chrome.x) + in_w
		bh = h if h >= 0.0 else maxf(nat.y, chrome.y) + in_h
	# The border box can never be smaller than its own padding+border —
	# the floor overrides explicit dims and max bounds alike (Yoga).
	var out := Vector2(
		maxf(
			clampf(bw, _min_or(el, "min-width", avail.x, 0.0), _bound(el, "max-width", avail.x, false)),
			in_w
		),
		maxf(
			clampf(bh, _min_or(el, "min-height", avail.y, 0.0), _bound(el, "max-height", avail.y, false)),
			in_h
		)
	)
	if pure:
		memo.append([avail.x, avail.y, border_w_hint, out])
	return out


## The measurer gets the element's style Dictionary exactly as before
## (a fresh {} when the element has no computed style).
func _style_for_measure(el: UxmlElement) -> Dictionary:
	return _styles.get(el, {})


func _min_or(el: UxmlElement, name: String, base: float, fallback: float) -> float:
	var b := _bound(el, name, base, true)
	return fallback if b < 0.0 else b


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
	var lines_main := PackedFloat64Array()
	var lines_cross := PackedFloat64Array()
	var cur_main := 0.0
	var cur_cross := 0.0
	var cur_n := 0
	var am: float = cavail[main]
	for child in kids:
		var msz := _measure(child, cavail)
		var m := _margins(child, cavail.x)
		var o_main: float
		var o_cross: float
		if row:
			o_main = msz.x + m[L] + m[R]
			o_cross = msz.y + m[T] + m[B]
		else:
			o_main = msz.y + m[T] + m[B]
			o_cross = msz.x + m[L] + m[R]
		if (
			wrap and am >= 0.0 and cur_n > 0
			and cur_main + gap_m + o_main > am + EPS
		):
			lines_main.append(cur_main)
			lines_cross.append(cur_cross)
			cur_main = 0.0
			cur_cross = 0.0
			cur_n = 0
		cur_main += (gap_m if cur_n > 0 else 0.0) + o_main
		cur_cross = maxf(cur_cross, o_cross)
		cur_n += 1
	if cur_n > 0:
		lines_main.append(cur_main)
		lines_cross.append(cur_cross)
	var out := Vector2.ZERO
	for i in lines_main.size():
		out[main] = maxf(out[main], lines_main[i])
		out[cross] += lines_cross[i] + (gap_c if i > 0 else 0.0)
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
	var pad := _padding(el, cb_width)
	var bor := _borders(el)
	# The resolved content-box insets — the runtime insets internal chrome
	# (field caption/native, scroll viewport, image rect) the flex pass
	# does not itself position.
	_insets[el] = [
		Vector2(bor[L] + pad[L], bor[T] + pad[T]),
		Vector2(bor[R] + pad[R], bor[B] + pad[B]),
	]
	var inner := Vector2(bor[L] + pad[L], bor[T] + pad[T])
	var content := Rect2(
		inner,
		Vector2(
			maxf(0.0, rect.size.x - (pad[L] + pad[R] + bor[L] + bor[R])),
			maxf(0.0, rect.size.y - (pad[T] + pad[B] + bor[T] + bor[B]))
		)
	)
	var kids := _flex_children(el)
	if kids.is_empty():
		_content_sizes[el] = Vector2.ZERO
		return
	if el.local == "ScrollView":
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
	pad: PackedFloat64Array,
	bor: PackedFloat64Array,
	kids: Array
) -> void:
	var pad_bor := Vector2(pad[L] + bor[L], pad[T] + bor[T])
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
	var min_main := "min-" + size_prop
	var max_main := "max-" + size_prop
	var min_cross := "min-" + cross_prop
	var max_cross := "max-" + cross_prop
	var asx: float = area.size.x
	# Margin edge indices along main/cross: start/end.
	var ms_i := L if row else T
	var me_i := R if row else B
	var cs_i := T if row else L
	var ce_i := B if row else R

	# Hypothetical main sizes, with min/max already applied. Items are
	# parallel arrays indexed by kid position.
	var n := kids.size()
	var it_m: Array = []
	it_m.resize(n)
	var it_main := PackedFloat64Array()
	it_main.resize(n)
	var it_min := PackedFloat64Array()
	it_min.resize(n)
	var it_max := PackedFloat64Array()
	it_max.resize(n)
	var it_inc := PackedFloat64Array()
	it_inc.resize(n)
	var it_grow := PackedFloat64Array()
	it_grow.resize(n)
	var it_shrink := PackedFloat64Array()
	it_shrink.resize(n)
	var it_frozen := PackedByteArray()
	it_frozen.resize(n)
	var it_cross := PackedFloat64Array()
	it_cross.resize(n)
	var it_ncross := PackedFloat64Array()
	it_ncross.resize(n)
	var it_pos := PackedFloat64Array()
	it_pos.resize(n)
	var it_cpos := PackedFloat64Array()
	it_cpos.resize(n)
	var it_mmain := PackedFloat64Array() # margin total on main
	it_mmain.resize(n)
	var it_mcross := PackedFloat64Array() # margin total on cross
	it_mcross.resize(n)
	for k in n:
		var child: UxmlElement = kids[k]
		var m := _margins(child, asx)
		var nat := _measure(child, area.size)
		var hyp: float
		var basis := _len(child, "flex-basis", am)
		if not is_nan(basis):
			hyp = basis
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
		var mn := _bound(child, min_main, am, true)
		if mn < 0.0:
			mn = 0.0
		var mx := _bound(child, max_main, am, false)
		var pads := _padding(child, asx)
		var bors := _borders(child)
		var in_main: float
		var in_cross: float
		if row:
			in_main = pads[L] + pads[R] + bors[L] + bors[R]
			in_cross = pads[T] + pads[B] + bors[T] + bors[B]
		else:
			in_main = pads[T] + pads[B] + bors[T] + bors[B]
			in_cross = pads[L] + pads[R] + bors[L] + bors[R]
		mn = maxf(mn, in_main)
		mx = maxf(mx, mn)
		it_m[k] = m
		it_main[k] = clampf(hyp, mn, mx)
		it_min[k] = mn
		it_max[k] = mx
		it_inc[k] = in_cross
		it_grow[k] = maxf(0.0, _num(child, "flex-grow", 0.0))
		it_shrink[k] = maxf(0.0, _num(child, "flex-shrink", 1.0))
		if row:
			it_mmain[k] = m[L] + m[R]
			it_mcross[k] = m[T] + m[B]
		else:
			it_mmain[k] = m[T] + m[B]
			it_mcross[k] = m[L] + m[R]

	# Lines: one when nowrap, else split on hypothetical outer main size.
	# A line is [first item, end item) — items stay in order.
	var line_lo := PackedInt32Array()
	var line_hi := PackedInt32Array()
	if wrap_mode == "nowrap":
		line_lo.append(0)
		line_hi.append(n)
	else:
		var start := 0
		var cur_main := 0.0
		for k in n:
			var outer: float = it_main[k] + it_mmain[k]
			var need: float = (gap_m if k > start else 0.0) + outer
			if k > start and cur_main + need > am + EPS:
				line_lo.append(start)
				line_hi.append(k)
				start = k
				cur_main = 0.0
				need = outer
			cur_main += need
		line_lo.append(start)
		line_hi.append(n)
	var nlines := line_lo.size()

	# Grow/shrink within each line.
	for li in nlines:
		_flex_line(line_lo[li], line_hi[li], it_main, it_mmain, it_min, it_max,
			it_grow, it_shrink, it_frozen, am, gap_m)

	# Cross sizes: explicit or natural, then the line cross is the max outer.
	var l_cross := PackedFloat64Array()
	l_cross.resize(nlines)
	var l_pos := PackedFloat64Array()
	l_pos.resize(nlines)
	for li in nlines:
		var line_cross := 0.0
		for k in range(line_lo[li], line_hi[li]):
			var child: UxmlElement = kids[k]
			var explicit := _dim(child, cross_prop, ac)
			var nat: float
			if explicit >= 0.0:
				nat = explicit
			else:
				# For a row item the final main size is now known — measuring
				# with it lets wrapped text report the height it really needs.
				nat = _measure(
					child, area.size,
					it_main[k] if row else -1.0
				)[cross]
			# Cross sizes floor at the cross-axis padding+border total the
			# same way the main axis does — an explicit dim or max bound
			# below it cannot produce a negative content box.
			var cmin := maxf(_min_or(child, min_cross, ac, 0.0), it_inc[k])
			nat = clampf(
				nat, cmin,
				maxf(_bound(child, max_cross, ac, false), cmin)
			)
			it_ncross[k] = nat
			line_cross = maxf(line_cross, nat + it_mcross[k])
		l_cross[li] = line_cross

	# The container's cross space distributed over lines (align-content).
	var lines_cross := 0.0
	for li in nlines:
		lines_cross += l_cross[li] + (gap_c if li > 0 else 0.0)
	if wrap_mode == "nowrap" and ac >= 0.0:
		l_cross[0] = ac
		lines_cross = ac
	elif wrap_mode != "nowrap" and ac >= 0.0 and align_content == "stretch" and ac > lines_cross:
		var extra := (ac - lines_cross) / nlines
		for li in nlines:
			l_cross[li] += extra
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
	for li in nlines:
		l_pos[li] = cpos
		cpos += l_cross[li] + cstep
	if wrap_mode == "wrap-reverse" and ac >= 0.0:
		for li in nlines:
			l_pos[li] = (
				area.position[cross] + ac
				- (l_pos[li] - area.position[cross]) - l_cross[li]
			)

	# Main-axis positions within each line (justify-content).
	var reverse := _reverse_main(el)
	for li in nlines:
		var lo := line_lo[li]
		var hi := line_hi[li]
		var cnt := hi - lo
		var used := gap_m * maxf(0.0, cnt - 1.0)
		for k in range(lo, hi):
			used += it_main[k] + it_mmain[k]
		var free := am - used
		var start := 0.0
		var step := gap_m
		match justify:
			"center":
				start = free / 2.0
			"flex-end":
				start = free
			"space-between":
				step += free / (cnt - 1) if cnt > 1 else 0.0
			"space-around":
				var u := free / cnt
				start = u / 2.0
				step += u
			"space-evenly":
				var u2 := free / (cnt + 1)
				start = u2
				step += u2
		var cursor := area.position[main] + start
		for k in range(lo, hi):
			var mk: PackedFloat64Array = it_m[k]
			it_pos[k] = cursor + mk[ms_i]
			cursor += it_mmain[k] + it_main[k] + step
		if reverse:
			for k in range(lo, hi):
				var mk: PackedFloat64Array = it_m[k]
				var outer_start: float = it_pos[k] - mk[ms_i]
				var outer_len: float = it_mmain[k] + it_main[k]
				it_pos[k] = (
					2.0 * area.position[main] + am
					- outer_start - outer_len + mk[ms_i]
				)

	# Cross position and final cross size per item (align-items/align-self).
	for li in nlines:
		var lc := l_cross[li]
		var lp := l_pos[li]
		for k in range(line_lo[li], line_hi[li]):
			var child: UxmlElement = kids[k]
			var al := _str(child, "align-self", "auto")
			if al == "auto":
				al = align_items
			if not ALIGN.has(al):
				_warn_once(child, "align-self", 'align-self: "%s" is not supported; flex-start used' % al)
				al = "flex-start"
			if al == "baseline":
				_warn_once(child, "align-items", "baseline alignment is not supported; flex-start used")
				al = "flex-start"
			var mct: float = it_mcross[k]
			if al == "stretch" and _dim(child, cross_prop, ac) < 0.0:
				# Stretch still honors min/max — a max-height:30 item in a
				# 100-high line stretches to 30, not 100 — and the
				# padding+border floor applies here too.
				var smin := maxf(_min_or(child, min_cross, ac, 0.0), it_inc[k])
				it_cross[k] = clampf(
					maxf(0.0, lc - mct),
					smin,
					maxf(_bound(child, max_cross, ac, false), smin)
				)
			else:
				it_cross[k] = it_ncross[k]
			var mk: PackedFloat64Array = it_m[k]
			var mc_start: float = mk[cs_i]
			var mc_end: float = mk[ce_i]
			match al:
				"center":
					it_cpos[k] = lp + (lc - it_cross[k] - mct) / 2.0 + mc_start
				"flex-end":
					it_cpos[k] = lp + lc - it_cross[k] - mc_end
				_:
					it_cpos[k] = lp + mc_start

	# Emit rects and recurse.
	var extent := Vector2.ZERO
	var amain: float = area.position[main]
	var across: float = area.position[cross]
	for li in nlines:
		for k in range(line_lo[li], line_hi[li]):
			var pos := Vector2.ZERO
			pos[main] = it_pos[k]
			pos[cross] = it_cpos[k]
			var size := Vector2.ZERO
			size[main] = it_main[k]
			size[cross] = it_cross[k]
			_layout(kids[k], Rect2(pos, size), asx)
			var mk: PackedFloat64Array = it_m[k]
			var mend: float = mk[me_i]
			var mcend: float = mk[ce_i]
			extent[main] = maxf(extent[main], pos[main] + size[main] + mend - amain)
			extent[cross] = maxf(extent[cross], pos[cross] + size[cross] + mcend - across)
	return extent


## Distribute a line's free main-axis space: grow when positive, shrink
## (scaled by basis) when negative, freezing items that hit min/max and
## redistributing until stable — bounded by the item count.
func _flex_line(
	lo: int, hi: int,
	it_main: PackedFloat64Array, it_mmain: PackedFloat64Array,
	it_min: PackedFloat64Array, it_max: PackedFloat64Array,
	it_grow: PackedFloat64Array, it_shrink: PackedFloat64Array,
	it_frozen: PackedByteArray, am: float, gap_m: float
) -> void:
	var cnt := hi - lo
	for _iter in range(cnt + 1):
		var used := gap_m * maxf(0.0, cnt - 1.0)
		for k in range(lo, hi):
			used += it_main[k] + it_mmain[k]
		var free := am - used
		if absf(free) < EPS:
			break
		var froze := false
		if free > 0.0:
			var gsum := 0.0
			for k in range(lo, hi):
				if it_frozen[k] == 0:
					gsum += it_grow[k]
			if gsum <= 0.0:
				break
			var eff := free if gsum >= 1.0 else free * gsum
			for k in range(lo, hi):
				if it_frozen[k] != 0 or it_grow[k] <= 0.0:
					continue
				var target: float = it_main[k] + eff * it_grow[k] / gsum
				if target > it_max[k] + EPS:
					it_main[k] = it_max[k]
					it_frozen[k] = 1
					froze = true
				elif target < it_min[k] - EPS:
					it_main[k] = it_min[k]
					it_frozen[k] = 1
					froze = true
				else:
					it_main[k] = target
		else:
			var ssum := 0.0
			for k in range(lo, hi):
				if it_frozen[k] == 0:
					ssum += it_shrink[k] * it_main[k]
			if ssum <= 0.0:
				break
			var eff := -free if ssum >= 1.0 else -free * ssum
			for k in range(lo, hi):
				if it_frozen[k] != 0 or it_shrink[k] <= 0.0:
					continue
				var target: float = it_main[k] - eff * it_shrink[k] * it_main[k] / ssum
				if target < it_min[k] - EPS:
					it_main[k] = it_min[k]
					it_frozen[k] = 1
					froze = true
				elif target > it_max[k] + EPS:
					it_main[k] = it_max[k]
					it_frozen[k] = 1
					froze = true
				else:
					it_main[k] = target
		if not froze:
			break
