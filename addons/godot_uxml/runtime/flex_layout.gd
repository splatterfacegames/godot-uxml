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
## A ScrollView is its Unity part tree (UxmlContainerParts) and lays out
## through the same flex rules as every other element; the runtime shows
## and sizes its Scrollers after the layout, as Unity does.
##
## Measure bounds (Yoga's AtMost measure mode): every measure of a flex
## item gets the space its container has on each axis, less the item's
## margins (bx, by; -1 for none). A container that measures its content
## passes its own bound on (less padding and border), so a row-wrap grid in
## an auto-sized container wraps at the container width. A leaf measure is
## clamped to the bound, as Unity's TextElement and Image clamp their
## measure (TextUtilities.PostProcessMeasuredSize), and a leaf without a
## width hint is measured at the bound width (wrapping text). An
## `overflow: scroll` container does not bound its children on its main
## axis, and its own auto size stays inside its bound (Yoga).
##
## Performance notes (the algorithm above is unchanged, bit for bit):
##   * every per-element style read is memoized for the pass — padding /
##     border / margin edges per containing-block width, enums, flex
##     children, numbers — and value parsing is memoized by text in
##     UssValues, so the hot recursion does no regex or string building;
##   * _measure() results are memoized per canonical (element, avail,
##     hint, bound) — avail only through the element's own percentage
##     props. options["volatile"] maps elements whose
##     intrinsic size depends on measurer call history (a wrapping Label is
##     measured at the width the previous call left on it) to the control's
##     current width; the layout tracks that width through the pass
##     (options["volatile_width"] reads the engine-clamped result back),
##     memoizes per actual width, and subtree memo entries key on and
##     replay the labels' widths — every real measurer call happens at the
##     width the original call sequence would have used;
##   * options["records"] + options["xcache"] (caller-owned Dictionaries)
##     keep parsed style records and a validated cross-pass measure/layout
##     cache (see the "Entries" notes below);
##   * flex items are parallel packed arrays, not per-item Dictionaries.
## Diagnostics are deduplicated per (property, message) for the document's
## lifetime, so skipping a repeated identical call never drops a warning.

const EPS := 0.01
const JUSTIFY := ["flex-start", "center", "flex-end", "space-between", "space-around", "space-evenly"]
const ALIGN := ["flex-start", "center", "flex-end", "stretch", "baseline"]
const ALIGN_CONTENT := ["flex-start", "center", "flex-end", "stretch", "space-between", "space-around", "space-evenly"]
const DIRECTIONS := ["column", "row", "column-reverse", "row-reverse"]
const WRAPS := ["nowrap", "wrap", "wrap-reverse"]
const POSITIONS := ["relative", "absolute"]

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
var _recs := {}       # el -> layout record (this pass)
var _shared_recs = null  # caller-owned el -> record cache across passes
var _pad_m := {}      # el -> [cb_width, PackedFloat64Array]
var _mar_m := {}      # el -> [cb_width, PackedFloat64Array]
var _bor_m := {}      # el -> PackedFloat64Array
var _kids_m := {}     # el -> Array
var _abs_m := {}      # el -> Array (position:absolute children)
var _enum_m := {}     # el -> {prop: String}
var _num_m := {}      # el -> {prop: float}
var _meas_m := {}     # el -> Array of [ax, ay, hint, Vector2]
var _sens_m := {}     # el -> _sens bits
var _vl_m := {}       # el -> volatile elements in subtree
var _vw := {}         # volatile el -> tracked actual control width
var _vmemo := {}      # volatile el -> [set memo, read memo]
var _volatile_width: Callable
static var _no_list: Array = []
static var _no_state := PackedFloat64Array()
# Cross-pass cache (options["xcache"], caller-owned): el -> [measure
# entries, layout entries]. Every entry carries the measurer calls its
# result depended on; a candidate hit is only taken after replaying those
# calls (once per element/argument per pass) returns identical results, so
# a text change or a deferred theme update can never be served stale.
var _xc = null
var _hint_free := false      # options["hint_free"]: only volatile measures read the hint
## options["hinted"]: non-volatile elements whose measure still reads the
## width hint (best-fit text, -unity-text-auto-size). A column with
## align stretch also measures them at their stretched width, as Yoga does.
var _hinted: Dictionary = {}
# Entries — measure: [kx, ky, kh, out, entry_state, exit_state, calls,
# kids, ids, eid, el, bx, by]; layout: [size, cb_width, scroll_bar_width,
# entry_state, exit_state, sub, calls, kids, ids, eid, el, rects, insets,
# content_sizes]. `calls` are the entry's OWN measurer calls, `kids` the
# child entries its computation used, `ids` the layout-record ids of el and
# its direct children (any change to a descendant's style changes some
# entry's ids on the way up). Validity is checked recursively, memoized per
# pass by eid.
const E_CALLS := 6
const E_KIDS := 7
const E_IDS := 8
const E_EID := 9
const E_EL := 10
var _frames: Array = []      # stack of [calls, kids] being recorded
var _ids_m := {}             # el -> PackedInt64Array (this pass)
var _ok_m := {}              # eid -> bool (this pass)
var _val_m := {}             # el -> {arg -> result} replayed this pass
static var _eid_seq := 0
var _laid: Array = []        # elements laid out this pass, in order
const XC_MAX := 6            # cached entries per element and kind
static var _rec_seq := 0
static var _no_ids := PackedInt64Array()


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
	l._shared_recs = options.get("records")
	l._volatile_width = options.get("volatile_width", Callable())
	if l._shared_recs != null:
		l._xc = options.get("xcache")
	l._hint_free = bool(options.get("hint_free", false))
	l._hinted = options.get("hinted", {})
	if options.has("warned"):
		l._warned = options["warned"]
	l._layout(root, Rect2(Vector2.ZERO, host_size), host_size.x)
	var rects: Dictionary = l._rects
	if bool(options.get("pixel_grid", false)):
		rects = round_to_pixel_grid(root, rects)
	return {
		"rects": rects,
		"content_sizes": l._content_sizes,
		"insets": l._insets,
	}


## Yoga's RoundToPixelGrid at one pixel per point, as Unity rounds every
## layout: a position rounds on its own, a size is the difference of the
## rounded absolute edges, and children start from the unrounded absolute
## position. Halves round up. Returns a new Dictionary (the cross-pass
## cache keeps the unrounded rects). The native layout does the same
## (layout.rs, round_to_pixel_grid).
static func round_to_pixel_grid(root: UxmlElement, rects: Dictionary) -> Dictionary:
	var out := rects.duplicate()
	_round_node(root, 0.0, 0.0, rects, out)
	return out


static func _round_node(el: UxmlElement, abs_l: float, abs_t: float, src: Dictionary, out: Dictionary) -> void:
	var r = src.get(el)
	if r == null:
		return
	var rr: Rect2 = r
	var left := float(rr.position.x)
	var top := float(rr.position.y)
	var al := abs_l + left
	var at := abs_t + top
	out[el] = Rect2(_pixel(al) - _pixel(abs_l), _pixel(at) - _pixel(abs_t),
		_pixel(al + float(rr.size.x)) - _pixel(al), _pixel(at + float(rr.size.y)) - _pixel(at))
	for c in el.children:
		_round_node(c, al, at, src, out)


## Yoga's roundValueToPixelGrid (no forced ceil/floor).
static func _pixel(v: float) -> float:
	var f := fmod(v, 1.0)
	if f < 0.0:
		f += 1.0
	if absf(f) < 0.0001:
		return v - f
	if absf(f - 1.0) < 0.0001:
		return v - f + 1.0
	return v - f + (1.0 if (f > 0.5 or absf(f - 0.5) < 0.0001) else 0.0)


# ---------------------------------------------------------------------------
# Style access — pre-parsed layout records
# ---------------------------------------------------------------------------
#
# Every layout property of an element is parsed once into a record:
#   [style Dictionary (identity), kinds PackedByteArray, values
#    PackedFloat64Array, raws Array, problems Dictionary pid -> String,
#    enums Dictionary name -> String]
# Records hold parse results only — diagnostics are still emitted at the
# exact use sites (and in the exact order) the original accessors emitted
# them. With options["records"] (a caller-owned Dictionary) records survive
# across passes and are rebuilt only when the element's computed style
# Dictionary is a different object.

const P_W := 0
const P_H := 1
const P_MINW := 2
const P_MINH := 3
const P_MAXW := 4
const P_MAXH := 5
const P_BASIS := 6
const P_PAD := 7      # 7..10 top,right,bottom,left
const P_MAR := 11     # 11..14
const P_BOR := 15     # 15..18
const P_RGAP := 19
const P_CGAP := 20
const P_GROW := 21
const P_SHRINK := 22
const P_POS := 23     # 23..26 top,right,bottom,left (position offsets)
const P_ASPECT := 27  # aspect-ratio: K_NUM width/height, K_AUTO, K_NAN invalid
const NP := 28
const PNAMES := [
	"width", "height", "min-width", "min-height", "max-width", "max-height", "flex-basis",
	"padding-top", "padding-right", "padding-bottom", "padding-left",
	"margin-top", "margin-right", "margin-bottom", "margin-left",
	"border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
	"row-gap", "column-gap", "flex-grow", "flex-shrink",
	"top", "right", "bottom", "left", "aspect-ratio",
]
const ENUM_NAMES := [
	"display", "flex-direction", "flex-wrap", "justify-content",
	"align-items", "align-content", "align-self", "position", "overflow",
]
# kinds
const K_NONE := 0     # property absent
const K_PX := 1
const K_PCT := 2
const K_AUTO := 3     # auto / none / initial (parse_length "auto"/"none")
const K_BAD := 4      # unparseable: problems[pid]
const K_AUTOKW := 5   # edges only: the literal keyword auto (diagnosed)
const K_NUM := 6      # grow/shrink: a number
const K_NAN := 7      # grow/shrink: not a number


static func _build_rec(st: Dictionary) -> Array:
	var kinds := PackedByteArray()
	kinds.resize(NP)
	var vals := PackedFloat64Array()
	vals.resize(NP)
	var raws: Array = []
	raws.resize(NP)
	var probs := {}
	for pid in NP:
		var entry = st.get(PNAMES[pid])
		if entry == null:
			continue
		var raw = entry["value"]
		raws[pid] = raw
		if pid == P_ASPECT:
			var ar := _parse_ratio(String(raw))
			if is_nan(ar):
				kinds[pid] = K_NAN
			elif ar <= 0.0:
				kinds[pid] = K_AUTO
			else:
				kinds[pid] = K_NUM
				vals[pid] = ar
			continue
		if pid == P_GROW or pid == P_SHRINK:
			var n := UssValues.parse_number(String(raw))
			if is_nan(n):
				kinds[pid] = K_NAN
			else:
				kinds[pid] = K_NUM
				vals[pid] = n
			continue
		if pid >= P_PAD and pid < P_BOR and String(raw).strip_edges() == "auto":
			kinds[pid] = K_AUTOKW
			continue
		var p := UssValues.parse_length(String(raw))
		match p["kind"]:
			"px":
				kinds[pid] = K_PX
				vals[pid] = p["value"]
			"percent":
				kinds[pid] = K_PCT
				vals[pid] = p["value"]
			"invalid":
				kinds[pid] = K_BAD
				probs[pid] = p["problem"]
			_:
				kinds[pid] = K_AUTO
	var enums := {}
	for name in ENUM_NAMES:
		var entry = st.get(name)
		if entry != null:
			enums[name] = String(entry["value"])
	_rec_seq += 1
	return [st, kinds, vals, raws, probs, enums, _rec_seq]


## aspect-ratio text -> width/height ratio; 0 for auto, NAN when invalid.
## Unity accepts `auto`, a number, or `<number> / <number>`.
static func _parse_ratio(text: String) -> float:
	var t := text.strip_edges()
	if t == "auto":
		return 0.0
	var parts := t.split("/")
	if parts.size() > 2:
		return NAN
	var a := UssValues.parse_number(parts[0].strip_edges())
	if is_nan(a) or a < 0.0:
		return NAN
	if parts.size() == 1:
		return a
	var b := UssValues.parse_number(parts[1].strip_edges())
	if is_nan(b) or b <= 0.0:
		return NAN
	return a / b


## The element's aspect ratio (width / height), or 0 when none applies.
func _ratio(el: UxmlElement) -> float:
	var rec := _rec(el)
	match rec[1][P_ASPECT]:
		K_NUM:
			return rec[2][P_ASPECT]
		K_NAN:
			_warn_once(el, "aspect-ratio", 'aspect-ratio: "%s" is not a valid ratio; auto used' % rec[3][P_ASPECT])
	return 0.0


func _rec(el: UxmlElement) -> Array:
	var r = _recs.get(el)
	if r != null:
		return r
	var st: Dictionary = _styles.get(el, _empty_style)
	if _shared_recs != null:
		var sr = _shared_recs.get(el)
		if sr != null and is_same(sr[0], st):
			_recs[el] = sr
			return sr
	r = _build_rec(st)
	if _shared_recs != null:
		_shared_recs[el] = r
	_recs[el] = r
	return r


func _str(el: UxmlElement, name: String, default: String) -> String:
	var v = _rec(el)[5].get(name)
	return default if v == null else v


func _num(el: UxmlElement, pid: int, default: float) -> float:
	var m: Dictionary = _num_m.get(el, {})
	var hit = m.get(pid)
	if hit != null:
		return hit
	var out := default
	var rec := _rec(el)
	var k: int = rec[1][pid]
	if k == K_NAN:
		var name: String = PNAMES[pid]
		_warn_once(el, name, '%s: "%s" is not a number; %s used' % [name, rec[3][pid], default])
	elif k == K_NUM:
		out = rec[2][pid]
	m[pid] = out
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


## A length value from the record: NAN for auto. Auto covers the auto/none
## keywords, unparseable text (warned once), percentages against an
## indefinite base (base < 0), and an absent property.
func _lenr(el: UxmlElement, rec: Array, pid: int, base: float) -> float:
	match rec[1][pid]:
		K_PX:
			return rec[2][pid]
		K_PCT:
			if base < 0.0:
				return NAN
			return base * rec[2][pid] / 100.0
		K_BAD:
			var name: String = PNAMES[pid]
			_warn_once(el, name, "%s: %s" % [name, rec[4][pid]])
			return NAN
	return NAN


func _len(el: UxmlElement, pid: int, base: float) -> float:
	return _lenr(el, _rec(el), pid, base)


## A box dimension (width/height/flex-basis): px value, or -1 for auto.
func _dim(el: UxmlElement, pid: int, base: float) -> float:
	var r := _lenr(el, _rec(el), pid, base)
	return -1.0 if is_nan(r) else r


## A min/max bound. is_min: -1 means "no declared bound" (the caller decides
## the auto floor); !is_min: INF means none.
func _bound(el: UxmlElement, pid: int, base: float, is_min: bool) -> float:
	var rec := _rec(el)
	if rec[1][pid] == K_NONE:
		return -1.0 if is_min else INF
	var r := _lenr(el, rec, pid, base)
	if is_nan(r):
		return -1.0 if is_min else INF
	return r


## margin/padding edges [t,r,b,l] in px. Percentages resolve against the
## containing block width, like CSS. `auto` margins are not part of the USS
## subset — diagnosed once and treated as 0. Margins may be negative (CSS
## semantics: they pull the box, and neighbors, backward); padding may not —
## a negative padding is invalid and diagnosed rather than silently clamped.
func _edges(el: UxmlElement, base_pid: int, cb_width: float, allow_negative: bool) -> PackedFloat64Array:
	var out := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	var rec := _rec(el)
	var kinds: PackedByteArray = rec[1]
	for k in 4:
		var pid := base_pid + k
		var kind := kinds[pid]
		if kind == K_NONE:
			continue
		if kind == K_AUTOKW:
			if base_pid != P_MAR:
				var name: String = PNAMES[pid]
				_warn_once(el, name, "%s: auto is not supported; 0 used" % name)
			continue
		var r := _lenr(el, rec, pid, cb_width)
		if is_nan(r):
			continue
		elif r < 0.0 and not allow_negative:
			var name2: String = PNAMES[pid]
			_warn_once(el, name2, "%s: negative values are invalid; 0 used" % name2)
		else:
			out[k] = r
	return out


func _padding(el: UxmlElement, cb_width: float) -> PackedFloat64Array:
	var m = _pad_m.get(el)
	if m != null and m[0] == cb_width:
		return m[1]
	var e := _edges(el, P_PAD, cb_width, false)
	_pad_m[el] = [cb_width, e]
	return e


func _margins(el: UxmlElement, cb_width: float) -> PackedFloat64Array:
	var m = _mar_m.get(el)
	if m != null and m[0] == cb_width:
		return m[1]
	var e := _edges(el, P_MAR, cb_width, true)
	_mar_m[el] = [cb_width, e]
	return e


## Border widths [t,r,b,l] in px — USS borders are px-only; anything else is
## diagnosed and treated as 0.
func _borders(el: UxmlElement) -> PackedFloat64Array:
	var m = _bor_m.get(el)
	if m != null:
		return m
	var out := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	var rec := _rec(el)
	var kinds: PackedByteArray = rec[1]
	for k in 4:
		var pid := P_BOR + k
		match kinds[pid]:
			K_PX:
				out[k] = maxf(0.0, rec[2][pid])
			K_BAD:
				var name: String = PNAMES[pid]
				_warn_once(el, name, "%s: %s" % [name, rec[4][pid]])
			K_PCT:
				var name2: String = PNAMES[pid]
				_warn_once(el, name2, "%s: percentages are not supported for border width" % name2)
	_bor_m[el] = out
	return out


## The gap `pid` (P_RGAP/P_CGAP). The `gap` shorthand is expanded by the
## cascade (UssProperties.expand_shorthand), so the computed style only ever
## carries longhands — reading `gap` here would bypass the shorthand/
## longhand ordering the cascade already resolved.
## base is the content size on the gap's axis.
func _gap(el: UxmlElement, pid: int, base: float) -> float:
	var rec := _rec(el)
	match rec[1][pid]:
		K_PX:
			return maxf(0.0, rec[2][pid])
		K_PCT:
			return 0.0 if base < 0.0 else maxf(0.0, base * rec[2][pid] / 100.0)
		K_BAD:
			var name: String = PNAMES[pid]
			_warn_once(el, name, "%s: %s" % [name, rec[4][pid]])
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
	var abs: Array = []
	for child in el.children:
		var local: String = child.local
		if local == "UXML" or local == "Style":
			continue
		var display := _str(child, "display", "flex")
		if display == "none":
			continue
		if display != "flex":
			_warn_once(child, "display", 'display: "%s" is not supported; flex used' % display)
		if _rec(child)[5].has("position") and _enum(child, "position", POSITIONS, "relative") == "absolute":
			abs.append(child)
		else:
			out.append(child)
	_kids_m[el] = out
	_abs_m[el] = abs
	return out


func _is_row(el: UxmlElement) -> bool:
	var d := _enum(el, "flex-direction", DIRECTIONS, "column")
	return d == "row" or d == "row-reverse"


func _reverse_main(el: UxmlElement) -> bool:
	return _enum(el, "flex-direction", DIRECTIONS, "column").ends_with("-reverse")


## Which inputs of _measure(el, avail, hint) can change its result:
## bit 1 avail.x (a percentage width/min-width/max-width/padding), bit 2
## avail.y (a percentage height/min-height/max-height), bit 4 the hint (el
## is a layout leaf). Everything else in _measure depends on the element's
## own style and its children, which are measured against el's own
## explicit size — never against avail.
func _sens(el: UxmlElement) -> int:
	var hit = _sens_m.get(el)
	if hit != null:
		return hit
	var kinds: PackedByteArray = _rec(el)[1]
	var s := 0
	if (kinds[P_W] == K_PCT or kinds[P_MINW] == K_PCT or kinds[P_MAXW] == K_PCT
			or kinds[P_PAD] == K_PCT or kinds[P_PAD + 1] == K_PCT
			or kinds[P_PAD + 2] == K_PCT or kinds[P_PAD + 3] == K_PCT):
		s |= 1
	if kinds[P_H] == K_PCT or kinds[P_MINH] == K_PCT or kinds[P_MAXH] == K_PCT:
		s |= 2
	# Leaves and containers both read the width hint (see _stretch_hint).
	s |= 4
	_sens_m[el] = s
	return s


# ---------------------------------------------------------------------------
# Measuring (natural/intrinsic sizes)
# ---------------------------------------------------------------------------

## Natural border-box size of `el`. avail components < 0 mean indefinite;
## avail.x is the containing block's content width (the percentage base for
## width, margins and padding). border_w_hint, when >= 0, is the border-box
## width the element will actually get — the row case lets a wrapped label
## report its real height at the width the line assigned it. bx/by, when
## >= 0, are the largest border-box size the container has for el (Yoga's
## AtMost; see the class notes).
func _measure(
	el: UxmlElement,
	avail: Vector2,
	border_w_hint: float = -1.0,
	bx: float = -1.0,
	by: float = -1.0
) -> Vector2:
	# Canonical memo key: avail reaches the result only through the
	# element's OWN percentage props (children are measured against its own
	# explicit size), and the hint only matters for leaves. Subtrees holding
	# volatile (wrapping-label) measures also key on those labels' current
	# widths and replay the widths the real calls would leave behind.
	var sens := _sens(el)
	var kx := avail.x if sens & 1 else 0.0
	var ky := avail.y if sens & 2 else 0.0
	var kh := border_w_hint if sens & 4 else -1.0
	var vl := _vlist(el)
	var entry := _vstate(vl) if not vl.is_empty() else _no_state
	var memo: Array
	var m = _meas_m.get(el)
	if m != null:
		memo = m
		for e in memo:
			if e[0] == kx and e[1] == ky and e[2] == kh and e[11] == bx and e[12] == by and e[4] == entry:
				var ex: PackedFloat64Array = e[5]
				for k in vl.size():
					_vw[vl[k]] = ex[k]
				if not _frames.is_empty():
					_frames.back()[1].append(e)
				return e[3]
	else:
		memo = []
		_meas_m[el] = memo
	if _xc != null:
		var xe = _xc.get(el)
		if xe != null:
			for e in xe[0]:
				if (e[0] == kx and e[1] == ky and e[2] == kh and e[11] == bx
						and e[12] == by and e[4] == entry and _entry_ok(e)):
					var ex2: PackedFloat64Array = e[5]
					for k in vl.size():
						_vw[vl[k]] = ex2[k]
					memo.append(e)
					if not _frames.is_empty():
						_frames.back()[1].append(e)
					return e[3]
	_frames.append([[], []])
	var w := _dim(el, P_W, avail.x)
	var h := _dim(el, P_H, avail.y)
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
		elif bx >= 0.0:
			# Yoga AtMost: text lays out in the width the container has.
			hint = maxf(0.0, bx - in_w)
		var intr := _measure_call(el, hint)
		# Unity clamps a leaf measure to the space the leaf has (AtMost).
		var ix: float = intr.x
		var iy: float = intr.y
		if bx >= 0.0:
			ix = minf(ix, maxf(0.0, bx - in_w))
		if by >= 0.0:
			iy = minf(iy, maxf(0.0, by - in_h))
		bw = w if w >= 0.0 else ix + in_w
		bh = h if h >= 0.0 else iy + in_h
	else:
		var cw := w - in_w if w >= 0.0 else -1.0
		if cw < 0.0 and border_w_hint >= 0.0:
			cw = maxf(0.0, border_w_hint - in_w)
		var ch := h - in_h if h >= 0.0 else -1.0
		# The content bound: the content size, else the measure bound.
		var lx := cw
		if lx < 0.0 and bx >= 0.0:
			lx = maxf(0.0, bx - in_w)
		var ly := ch
		if ly < 0.0 and by >= 0.0:
			ly = maxf(0.0, by - in_h)
		var nat := _measure_content(el, Vector2(cw, ch), lx, ly)
		# Native chrome (e.g. a wrapped control's minimum size) can floor the
		# auto size, but an authored px/% always wins.
		var chrome := _measure_call(el, cw)
		bw = w if w >= 0.0 else maxf(nat.x, chrome.x) + in_w
		bh = h if h >= 0.0 else maxf(nat.y, chrome.y) + in_h
	var ar := _ratio(el)
	if ar > 0.0:
		if h >= 0.0 and w < 0.0:
			bw = h * ar
		elif h < 0.0:
			bh = bw / ar
	# The border box can never be smaller than its own padding+border —
	# the floor overrides explicit dims and max bounds alike (Yoga).
	var ox := maxf(
		clampf(bw, _min_or(el, P_MINW, avail.x, 0.0), _bound(el, P_MAXW, avail.x, false)),
		in_w
	)
	var oy := maxf(
		clampf(bh, _min_or(el, P_MINH, avail.y, 0.0), _bound(el, P_MAXH, avail.y, false)),
		in_h
	)
	if not kids.is_empty() and (bx >= 0.0 or by >= 0.0) and _str(el, "overflow", "visible") == "scroll":
		# Yoga: an auto-sized scroll box measured AtMost stays inside the
		# space it has on its cross axis. On its main axis only when the
		# box and one of its children grow: else Yoga sizes the main axis
		# to the content first (availableInnerMainDim = sizeConsumed).
		var row := _is_row(el)
		var main_clamp := false
		if _num(el, P_GROW, 0.0) > 0.0:
			for k in kids:
				if _num(k, P_GROW, 0.0) > 0.0:
					main_clamp = true
					break
		if bx >= 0.0 and w < 0.0 and border_w_hint < 0.0 and (main_clamp or not row):
			ox = maxf(minf(ox, bx), in_w)
		if by >= 0.0 and h < 0.0 and (main_clamp or row):
			oy = maxf(minf(oy, by), in_h)
	var out := Vector2(ox, oy)
	var fr: Array = _frames.pop_back()
	_eid_seq += 1
	var ent := [kx, ky, kh, out, entry, _vstate(vl) if not vl.is_empty() else _no_state,
		fr[0], fr[1], _ids_of(el) if _xc != null else _no_ids, _eid_seq, el, bx, by]
	_ok_m[_eid_seq] = true
	memo.append(ent)
	if _xc != null:
		var xe2 = _xc.get(el)
		if xe2 == null:
			xe2 = [[], []]
			_xc[el] = xe2
		var lst: Array = xe2[0]
		if lst.size() >= XC_MAX:
			lst.pop_front()
		lst.append(ent)
	if not _frames.is_empty():
		_frames.back()[1].append(ent)
	return out


## The border-box width hint of an item in a column whose cross axis
## stretches it (-1: none): a container, or a best-fit text item (`hinted`).
## Other leaves keep their measures.
func _stretch_hint(child: UxmlElement, row: bool, align_items: String, ac: float, m: PackedFloat64Array) -> float:
	if row or ac < 0.0:
		return -1.0
	# Yoga measures a stretched child at the stretched width: a container
	# whose content wraps gets its real height (a row-wrap grid in a
	# ScrollView). Leaves: only best-fit text reads the hint.
	if _flex_children(child).is_empty() and (_hinted.is_empty() or not _hinted.has(child)):
		return -1.0
	var al := _str(child, "align-self", "auto")
	if al == "auto":
		al = align_items
	if al != "stretch" or _dim(child, P_W, ac) >= 0.0:
		return -1.0
	return maxf(0.0, ac - m[L] - m[R])


## The measurer, with volatile elements emulated. A volatile measure is a
## pure function of the control's actual width: a call with a hint >= 0 sets
## that width first (the engine may clamp it — the real resulting width is
## read back through options["volatile_width"]), a call without one reads
## at the current width. Tracking that width per element lets results be
## memoized while every real call still happens at the exact width the
## original call sequence would have measured at.
func _measure_call(el: UxmlElement, hint: float) -> Vector2:
	if not _volatile.has(el):
		var r0: Vector2 = _measurer.call(el, _style_for_measure(el), hint)
		if not _frames.is_empty():
			_frames.back()[0].append([el, false, hint, r0])
		return r0
	var vm: Array = _vmemo.get(el, [])
	if vm.is_empty():
		vm = [{}, {}]  # [set-calls: hint -> [actual width, result], reads: width -> result]
		_vmemo[el] = vm
		if not _vw.has(el):
			_vw[el] = float(_volatile[el])
	var res: Vector2
	var used: float
	if hint >= 0.0:
		var hit = vm[0].get(hint)
		if hit != null:
			_vw[el] = hit[0]
			used = hit[0]
			res = hit[1]
		else:
			res = _measurer.call(el, _style_for_measure(el), hint)
			var actual: float = _volatile_width.call(el) if _volatile_width.is_valid() else hint
			vm[0][hint] = [actual, res]
			vm[1][actual] = res
			_vw[el] = actual
			used = actual
	else:
		used = _vw[el]
		var hit2 = vm[1].get(used)
		if hit2 != null:
			res = hit2
		else:
			# Measure at the tracked width: setting a width the control
			# already reached is a no-op, so this reads exactly what a
			# hint-less call at that point of the original sequence read.
			res = _measurer.call(el, _style_for_measure(el), used)
			vm[1][used] = res
	if not _frames.is_empty():
		_frames.back()[0].append([el, true, used, res])
	return res


## True when a cached entry still holds this pass: its element's and direct
## children's style records are the same objects, its own measurer calls
## replay to identical results, and every child entry it used is valid.
func _entry_ok(e: Array) -> bool:
	var eid: int = e[E_EID]
	var hit = _ok_m.get(eid)
	if hit != null:
		return hit
	var ok: bool = _ids_of(e[E_EL]) == e[E_IDS] and _calls_ok(e[E_CALLS])
	if ok:
		for kid in e[E_KIDS]:
			if not _entry_ok(kid):
				ok = false
				break
	_ok_m[eid] = ok
	return ok


## Replays recorded measurer calls; true when every one still returns the
## recorded result. Pure calls repeat with the same hint (side-effect
## free); volatile calls measure at the recorded actual width, which must
## still be reachable (the engine's clamp unchanged). Each element/argument
## is replayed at most once per pass.
func _calls_ok(calls: Array) -> bool:
	for c in calls:
		var el: UxmlElement = c[0]
		var vol: bool = c[1]
		if vol != _volatile.has(el):
			return false
		var arg: float = c[2]
		if not vol and _hint_free and not _hinted.has(el):
			# The caller guarantees non-volatile measures ignore the hint:
			# one replay per element per pass covers every recorded call.
			arg = -1.0
		var vm = _val_m.get(el)
		if vm == null:
			vm = {}
			_val_m[el] = vm
		var r = vm.get(arg)
		if r == null:
			r = _measurer.call(el, _style_for_measure(el), arg)
			if vol and _volatile_width.is_valid() and _volatile_width.call(el) != arg:
				r = Vector2(NAN, NAN)
			vm[arg] = r
		if r != c[3]:
			return false
	return true


## Layout-record ids of el and its direct children (all of them — a
## display:none child turning visible changes its record).
func _ids_of(el: UxmlElement) -> PackedInt64Array:
	var hit = _ids_m.get(el)
	if hit != null:
		return hit
	var out := PackedInt64Array()
	out.append(_rec(el)[6])
	for child in el.children:
		out.append(_rec(child)[6])
	_ids_m[el] = out
	return out


## Volatile elements inside el's subtree (el included), document order.
func _vlist(el: UxmlElement) -> Array:
	if _volatile.is_empty():
		return _no_list
	var hit = _vl_m.get(el)
	if hit != null:
		return hit
	var out: Array = []
	if _volatile.has(el):
		out.append(el)
	for child in el.children:
		var sub := _vlist(child)
		if not sub.is_empty():
			out.append_array(sub)
	if out.is_empty():
		out = _no_list
	_vl_m[el] = out
	return out


func _vstate(vl: Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(vl.size())
	for k in vl.size():
		var e: UxmlElement = vl[k]
		var v = _vw.get(e)
		out[k] = float(_volatile[e]) if v == null else v
	return out


## The measurer gets the element's style Dictionary exactly as before
## (a fresh {} when the element has no computed style).
func _style_for_measure(el: UxmlElement) -> Dictionary:
	return _styles.get(el, {})


func _min_or(el: UxmlElement, pid: int, base: float, fallback: float) -> float:
	var b := _bound(el, pid, base, true)
	return fallback if b < 0.0 else b


## Natural content-box size of a container's children (no padding/border).
## lx/ly bound the content (Yoga AtMost; -1 for none): lines wrap at the
## main bound, and each child is measured at most as large as the bound
## less its margins.
func _measure_content(el: UxmlElement, cavail: Vector2, lx: float = -1.0, ly: float = -1.0) -> Vector2:
	var kids := _flex_children(el)
	if kids.is_empty():
		return Vector2.ZERO
	var row := _is_row(el)
	var wrap := _enum(el, "flex-wrap", WRAPS, "nowrap") != "nowrap"
	var main := 0 if row else 1
	var cross := 1 - main
	var gap_m := _gap(el, P_CGAP if row else P_RGAP, cavail[main])
	var gap_c := _gap(el, P_RGAP if row else P_CGAP, cavail[cross])
	var lines_main := PackedFloat64Array()
	var lines_cross := PackedFloat64Array()
	var cur_main := 0.0
	var cur_cross := 0.0
	var cur_n := 0
	var am: float = lx if row else ly
	# Yoga: a scroll container does not bound its children on its main axis.
	if _str(el, "overflow", "visible") == "scroll":
		if row:
			lx = -1.0
		else:
			ly = -1.0
	for child in kids:
		var m := _margins(child, cavail.x)
		var msz := _measure(child, cavail, -1.0,
			-1.0 if lx < 0.0 else maxf(0.0, lx - m[L] - m[R]),
			-1.0 if ly < 0.0 else maxf(0.0, ly - m[T] - m[B]))
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
	if _xc == null:
		_layout_body(el, rect, cb_width)
		return
	var vl := _vlist(el)
	var entry := _vstate(vl) if not vl.is_empty() else _no_state
	var xe = _xc.get(el)
	if xe != null:
		for e in xe[1]:
			if (e[0] == rect.size and e[1] == cb_width and e[2] == _scroll_bar_width
					and e[3] == entry and _entry_ok(e)):
				# Reuse: descendants' rects are relative to their parents, so
				# only el's own rect comes from the caller.
				var sub: Array = e[5]
				var rs: Array = e[11]
				var ins: Array = e[12]
				var cs: Array = e[13]
				_rects[el] = rect
				_insets[el] = ins[0]
				_content_sizes[el] = cs[0]
				for k in range(1, sub.size()):
					var x: UxmlElement = sub[k]
					_rects[x] = rs[k]
					_insets[x] = ins[k]
					_content_sizes[x] = cs[k]
				_laid.append_array(sub)
				var ex: PackedFloat64Array = e[4]
				for k in vl.size():
					_vw[vl[k]] = ex[k]
				if not _frames.is_empty():
					_frames.back()[1].append(e)
				return
	_frames.append([[], []])
	var start := _laid.size()
	_layout_body(el, rect, cb_width)
	var fr: Array = _frames.pop_back()
	var sub2: Array = _laid.slice(start)
	var n := sub2.size()
	var rs2: Array = []
	rs2.resize(n)
	var ins2: Array = []
	ins2.resize(n)
	var cs2: Array = []
	cs2.resize(n)
	for k in n:
		var x2: UxmlElement = sub2[k]
		rs2[k] = _rects[x2]
		ins2[k] = _insets[x2]
		cs2[k] = _content_sizes.get(x2, Vector2.ZERO)
	if xe == null:
		xe = [[], []]
		_xc[el] = xe
	var lst: Array = xe[1]
	if lst.size() >= XC_MAX:
		lst.pop_front()
	_eid_seq += 1
	var ent := [rect.size, cb_width, _scroll_bar_width, entry,
		_vstate(vl) if not vl.is_empty() else _no_state, sub2,
		fr[0], fr[1], _ids_of(el), _eid_seq, el, rs2, ins2, cs2]
	_ok_m[_eid_seq] = true
	lst.append(ent)
	if not _frames.is_empty():
		_frames.back()[1].append(ent)


func _layout_body(el: UxmlElement, rect: Rect2, cb_width: float) -> void:
	_rects[el] = rect
	if _xc != null:
		_laid.append(el)
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
	var abs: Array = _abs_m[el]
	if kids.is_empty():
		_content_sizes[el] = Vector2.ZERO
	else:
		_content_sizes[el] = _place(el, content, kids)
	if not abs.is_empty():
		_layout_abs(el, rect.size, pad, bor, abs)


## Relative-position offset of a flow item (Yoga: the leading offset wins,
## else minus the trailing one). Percentages resolve against the containing
## block's content box; an offset never moves siblings or the extent.
func _rel_offset(child: UxmlElement, base: Vector2) -> Vector2:
	var out := Vector2.ZERO
	var lft := _len(child, P_POS + L, base.x)
	if not is_nan(lft):
		out.x = lft
	else:
		var rgt := _len(child, P_POS + R, base.x)
		if not is_nan(rgt):
			out.x = -rgt
	var top := _len(child, P_POS + T, base.y)
	if not is_nan(top):
		out.y = top
	else:
		var bot := _len(child, P_POS + B, base.y)
		if not is_nan(bot):
			out.y = -bot
	return out


## position:absolute children: sized and placed against el's padding box
## (Yoga). Offsets are measured from the padding-box edges; left+right (or
## top+bottom) with an auto size stretch the box; without an offset on an
## axis the child goes where the container's justify-content (main axis) /
## align-items|align-self (cross axis) puts it: start at the content edge,
## center and flex-end against the border box, as Yoga does.
func _layout_abs(el: UxmlElement, size: Vector2, pad: PackedFloat64Array, bor: PackedFloat64Array, kids: Array) -> void:
	var cbw := maxf(0.0, size.x - bor[L] - bor[R])
	var cbh := maxf(0.0, size.y - bor[T] - bor[B])
	var row := _is_row(el)
	var reverse := _reverse_main(el)
	var justify := _enum(el, "justify-content", JUSTIFY, "flex-start")
	var align_items := _enum(el, "align-items", ALIGN, "stretch")
	for child in kids:
		var m := _margins(child, cbw)
		var pads := _padding(child, cbw)
		var bors := _borders(child)
		var in_w: float = pads[L] + pads[R] + bors[L] + bors[R]
		var in_h: float = pads[T] + pads[B] + bors[T] + bors[B]
		var lft := _len(child, P_POS + L, cbw)
		var rgt := _len(child, P_POS + R, cbw)
		var top := _len(child, P_POS + T, cbh)
		var bot := _len(child, P_POS + B, cbh)
		var w := _dim(child, P_W, cbw)
		if w < 0.0 and not is_nan(lft) and not is_nan(rgt):
			w = maxf(0.0, cbw - lft - rgt - m[L] - m[R])
		var h := _dim(child, P_H, cbh)
		if h < 0.0 and not is_nan(top) and not is_nan(bot):
			h = maxf(0.0, cbh - top - bot - m[T] - m[B])
		var aar := _ratio(child)
		if aar > 0.0:
			if w >= 0.0 and h < 0.0:
				h = w / aar
			elif h >= 0.0 and w < 0.0:
				w = h * aar
		if w < 0.0 or h < 0.0:
			var nat := _measure(child, Vector2(cbw, cbh), w)
			if w < 0.0:
				w = nat.x
			if h < 0.0:
				h = nat.y
		w = maxf(clampf(w, _min_or(child, P_MINW, cbw, 0.0), _bound(child, P_MAXW, cbw, false)), in_w)
		h = maxf(clampf(h, _min_or(child, P_MINH, cbh, 0.0), _bound(child, P_MAXH, cbh, false)), in_h)
		var al := _str(child, "align-self", "auto")
		if al == "auto":
			al = align_items
		var x: float
		if not is_nan(lft):
			x = bor[L] + lft + m[L]
		elif not is_nan(rgt):
			x = size.x - bor[R] - rgt - m[R] - w
		else:
			x = _abs_free(justify if row else al, row and reverse, size.x, w, bor[L] + pad[L] + m[L])
		var y: float
		if not is_nan(top):
			y = bor[T] + top + m[T]
		elif not is_nan(bot):
			y = size.y - bor[B] - bot - m[B] - h
		else:
			y = _abs_free(al if row else justify, (not row) and reverse, size.y, h, bor[T] + pad[T] + m[T])
		_layout(child, Rect2(Vector2(x, y), Vector2(w, h)), cbw)


## Free-axis position of an absolute child with no offset on that axis.
static func _abs_free(mode: String, reverse: bool, outer: float, sz: float, lead: float) -> float:
	if mode == "center":
		return (outer - sz) / 2.0
	var at_end := mode == "flex-end"
	if reverse:
		at_end = not at_end
	return outer - sz if at_end else lead


## The flex algorithm proper: place `kids` inside `area` (positions are
## emitted relative to area's coordinate space) and return the used content
## extent. This one routine handles row/column, wrap, grow/shrink, justify
## and align.
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
	var gap_m := _gap(el, P_CGAP if row else P_RGAP, am)
	var gap_c := _gap(el, P_RGAP if row else P_CGAP, ac)
	var size_prop := P_W if row else P_H
	var cross_prop := P_H if row else P_W
	var min_main := P_MINW if row else P_MINH
	var max_main := P_MAXW if row else P_MAXH
	var min_cross := P_MINH if row else P_MINW
	var max_cross := P_MAXH if row else P_MAXW
	var asx: float = area.size.x
	# Margin edge indices along main/cross: start/end.
	var ms_i := L if row else T
	var me_i := R if row else B
	var cs_i := T if row else L
	var ce_i := B if row else R
	# Measure bounds (Yoga AtMost): the area less each item's margins; a
	# scroll container leaves its main axis unbounded.
	var sc := _str(el, "overflow", "visible") == "scroll"
	var bnd_x: float = -1.0 if (sc and row) else asx
	var bnd_y: float = -1.0 if (sc and not row) else area.size.y

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
		var nat := _measure(child, area.size, _stretch_hint(child, row, align_items, ac, m),
			-1.0 if bnd_x < 0.0 else maxf(0.0, bnd_x - m[L] - m[R]),
			-1.0 if bnd_y < 0.0 else maxf(0.0, bnd_y - m[T] - m[B]))
		var hyp: float
		var basis := _len(child, P_BASIS, am)
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
		it_grow[k] = maxf(0.0, _num(child, P_GROW, 0.0))
		it_shrink[k] = maxf(0.0, _num(child, P_SHRINK, 1.0))
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
			var car := _ratio(child)
			if explicit >= 0.0:
				nat = explicit
			elif car > 0.0:
				nat = it_main[k] / car if row else it_main[k] * car
			else:
				# For a row item the final main size is now known — measuring
				# with it lets wrapped text report the height it really needs.
				var mc: PackedFloat64Array = it_m[k]
				nat = _measure(
					child, area.size,
					it_main[k] if row else -1.0,
					-1.0 if bnd_x < 0.0 else maxf(0.0, bnd_x - mc[L] - mc[R]),
					-1.0 if bnd_y < 0.0 else maxf(0.0, bnd_y - mc[T] - mc[B])
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
		var nauto := 0
		for k in range(lo, hi):
			var ak: PackedByteArray = _rec(kids[k])[1]
			if ak[P_MAR + ms_i] == K_AUTOKW:
				nauto += 1
			if ak[P_MAR + me_i] == K_AUTOKW:
				nauto += 1
		if nauto > 0:
			var per := maxf(0.0, free) / nauto
			var cur := area.position[main]
			for k in range(lo, hi):
				var ak2: PackedByteArray = _rec(kids[k])[1]
				var mk0: PackedFloat64Array = it_m[k]
				if ak2[P_MAR + ms_i] == K_AUTOKW:
					cur += per
				it_pos[k] = cur + mk0[ms_i]
				cur += it_mmain[k] + it_main[k] + gap_m
				if ak2[P_MAR + me_i] == K_AUTOKW:
					cur += per
			justify = "__auto"
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
		if justify != "__auto":
			var cursor := area.position[main] + start
			for k in range(lo, hi):
				var mk: PackedFloat64Array = it_m[k]
				it_pos[k] = cursor + mk[ms_i]
				cursor += it_mmain[k] + it_main[k] + step
		else:
			justify = _enum(el, "justify-content", JUSTIFY, "flex-start")
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
			var ck: PackedByteArray = _rec(child)[1]
			var ca_s: bool = ck[P_MAR + cs_i] == K_AUTOKW
			var ca_e: bool = ck[P_MAR + ce_i] == K_AUTOKW
			if ca_s or ca_e:
				it_cross[k] = it_ncross[k]
				var mk3: PackedFloat64Array = it_m[k]
				if ca_s and ca_e:
					it_cpos[k] = lp + maxf(0.0, lc - it_cross[k] - mct) / 2.0 + mk3[cs_i]
				elif ca_s:
					it_cpos[k] = lp + maxf(0.0, lc - it_cross[k] - mct) + mk3[cs_i]
				else:
					it_cpos[k] = lp + mk3[cs_i]
				continue
			if al == "stretch" and _dim(child, cross_prop, ac) < 0.0 and _ratio(child) <= 0.0:
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
				# A scroll box keeps inside its line through the measure
				# bound (see _measure).
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
			var kd: PackedByteArray = _rec(kids[k])[1]
			if (kd[P_POS] != K_NONE or kd[P_POS + 1] != K_NONE
					or kd[P_POS + 2] != K_NONE or kd[P_POS + 3] != K_NONE):
				_layout(kids[k], Rect2(pos + _rel_offset(kids[k], area.size), size), asx)
			else:
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
