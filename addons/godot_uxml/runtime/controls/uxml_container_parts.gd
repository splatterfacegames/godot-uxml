class_name UxmlContainerParts
extends RefCounted
## Part trees of Unity's container and collection controls: ScrollView,
## Scroller, ListView, TreeView, MultiColumnListView, MultiColumnTreeView,
## TabView, Tab, TwoPaneSplitView and IMGUIContainer.
##
## The rules of UxmlParts apply (see docs/design.md, "Control parts"). The
## shapes, names and classes were measured in Unity 6000.3 with
## tools/unity-dump (bench/parity/unity/ctl-scroll*.json, ctl-list*.json,
## ctl-tree*.json, ctl-multicolumn-*.json, ctl-tab*.json, ctl-twopane.json,
## ctl-imgui.json).
##
## Unity changes some of these trees after layout: a ScrollView shows,
## hides, enables and sizes its Scrollers from the viewport and content
## sizes. `after_layout()` does the same on the model. The runtime calls it
## after each layout (UxmlContainerBehaviors), and bench/parity.gd calls it
## between layout passes, so both settle on the same tree.
##
## Collection views get their rows at load: a pool of row elements that
## covers the tallest viewport the document can get (`pool_height`). Rows
## past the item count are `display: none`. Unity creates
## floor(viewport / item height) + 2 rows; `trim_rows()` gives a model that
## count (bench/parity.gd).

const META_SCROLL := &"uxml_scroll_offset"   # ScrollView -> Vector2
const META_FACTOR := &"uxml_scroller_factor" # Scroller -> viewport/content ratio
const META_COLUMNS := &"uxml_columns"        # multi-column view -> Array
const META_SORT := &"uxml_sort_columns"      # multi-column view -> Array
const META_ROW := &"uxml_row"                # row element -> item index
const META_POOL := &"uxml_pool"              # collection view -> Array of rows

## Height that a collection row pool covers (the document sets the tallest
## viewport it can get before UxmlParts.expand).
static var pool_height := 1080.0

## Unity's default fixed-item-height for collection views.
const DEFAULT_ITEM_HEIGHT := 22.0
## Width of one TreeView indent level (Unity: .unity-tree-view__item-indent).
const TREE_INDENT := 30.0

const SCROLL_MODES := {"Vertical": "vertical", "Horizontal": "horizontal",
	"VerticalAndHorizontal": "vertical-horizontal"}


## The part of `owner` with `role` (UxmlParts.find_part), cached on the
## owner: part trees are fixed after load, and a ScrollView or collection
## view looks its parts up after every layout. The cache holds WeakRefs.
## A Tab's header stays its part after it moves into the TabView.
static func get_part(owner: UxmlElement, role: String) -> UxmlElement:
	if owner == null:
		return null
	var cache: Dictionary
	if owner.has_meta(&"uxml_part_cache"):
		cache = owner.get_meta(&"uxml_part_cache")
	else:
		# One walk indexes every part of the owner (first part per role).
		cache = {}
		for x in owner.walk():
			if x.part_of == owner and not cache.has(x.part_role):
				cache[x.part_role] = weakref(x)
		owner.set_meta(&"uxml_part_cache", cache)
	var w = cache.get(role)
	return null if w == null else (w as WeakRef).get_ref()


## The builder for `local`, or an invalid Callable.
static func builder(local: String) -> Callable:
	match local:
		"ScrollView":
			return _build_scroll_view
		"Scroller":
			return _build_scroller
		"ListView", "TreeView", "MultiColumnListView", "MultiColumnTreeView":
			return _build_collection
		"TabView":
			return _build_tab_view
		"Tab":
			return _build_tab
		"TwoPaneSplitView":
			return _build_two_pane
		"IMGUIContainer":
			return _build_imgui
	return Callable()


static func _attr(el: UxmlElement, n: String, d: String = "") -> String:
	return UxmlParts._attr(el, n, d)


static func _bool(el: UxmlElement, n: String, d: bool) -> bool:
	return UxmlParts._bool(el, n, d)


static func _num(el: UxmlElement, n: String, d: float) -> float:
	var v = el.get_attribute(n)
	if v == null:
		return d
	var x := UssValues.parse_number(String(v))
	return d if is_nan(x) else x


static func _part(owner: UxmlElement, local: String, role: String, part_name: String = "",
		classes: Array = [], text = null) -> UxmlElement:
	return UxmlParts.part(owner, local, role, part_name, classes, text)


## Set the inline style of a part (its whole `style` attribute).
static func set_style(el: UxmlElement, style: String) -> bool:
	var cur = el.get_attribute("style")
	if (cur == null and style.is_empty()) or (cur != null and String(cur) == style):
		return false
	if style.is_empty():
		el.remove_attribute("style")
	else:
		el.set_attribute("style", style)
	return true


static func _init_style(el: UxmlElement, style: String) -> void:
	if not style.is_empty():
		el.attributes.append({"name": "style", "value": style, "offset": 0})


## Format a length the way Unity's resolved values read (no trailing .0).
static func px(v: float) -> String:
	var r := snappedf(v, 0.001)
	if is_equal_approx(r, roundf(r)):
		return "%dpx" % int(roundf(r))
	return "%spx" % str(r)


# ---------------------------------------------------------------------------
# ScrollView
# ---------------------------------------------------------------------------

## ScrollView: content-and-vertical-scroll-container > (viewport > content
## container, vertical Scroller), then the horizontal Scroller. Author
## children go into #unity-content-container.
static func _build_scroll_view(el: UxmlElement) -> UxmlElement:
	var m := scroll_mode(el)
	UxmlParts._add_control_classes(el, ["unity-scroll-view--scroll", "unity-scroll-view--" + m])
	var cv := _part(el, "VisualElement", "content-and-vertical-scroll-container",
		"unity-content-and-vertical-scroll-container",
		["unity-scroll-view__content-and-vertical-scroll-container"])
	var vp := _part(el, "VisualElement", "viewport", "unity-content-viewport",
		["unity-scroll-view__content-viewport", "unity-scroll-view__content-viewport--" + m])
	var content := _part(el, "VisualElement", "content", "unity-content-container",
		["unity-scroll-view__content-container", "unity-scroll-view__content-container--" + m])
	vp.children.append(content)
	cv.children.append(vp)
	cv.children.append(_scroll_view_scroller(el, "vertical"))
	el.children.append(cv)
	el.children.append(_scroll_view_scroller(el, "horizontal"))
	el.set_meta(META_SCROLL, Vector2.ZERO)
	return content


## A ScrollView's Scroller: hidden and disabled until the first layout
## shows that the content overflows (Unity's constructor state).
static func _scroll_view_scroller(el: UxmlElement, dir: String) -> UxmlElement:
	var sc := _part(el, "Scroller", dir + "-scroller", "",
		["unity-scroll-view__%s-scroller" % dir])
	sc.attributes.append({"name": "direction", "value": dir.capitalize(), "offset": 0})
	sc.attributes.append({"name": "low-value", "value": "0", "offset": 0})
	sc.attributes.append({"name": "high-value", "value": "0", "offset": 0})
	sc.attributes.append({"name": "value", "value": "0", "offset": 0})
	sc.attributes.append({"name": "enabled", "value": "false", "offset": 0})
	_init_style(sc, "display: none;")
	UxmlParts.build(sc)
	UxmlParts._add_control_classes(sc, ["unity-disabled"])
	return sc


static func scroll_mode(el: UxmlElement) -> String:
	return SCROLL_MODES.get(_attr(el, "mode", "Vertical"), "vertical")


## "Auto", "AlwaysVisible" or "Hidden" for one axis. The Unity 2021
## `show-*-scroller` bools map to AlwaysVisible/Auto.
static func scroller_visibility(el: UxmlElement, dir: String) -> String:
	var v = el.get_attribute(dir + "-scroller-visibility")
	if v != null and String(v) in ["Auto", "AlwaysVisible", "Hidden"]:
		return String(v)
	if _bool(el, "show-%s-scroller" % dir, false):
		return "AlwaysVisible"
	return "Auto"


## Scroll distance of one wheel unit (one notch) when the ScrollView has
## no `mouse-wheel-scroll-size`: Unity's runtime theme line height,
## measured in ctl-scrollview-wheel (2 units scroll 72px).
const WHEEL_LINE := 36.0


## The offset after a wheel event of `delta` units (Unity
## ScrollView.OnScrollWheel): vertical scroll when the mode allows it, else
## the vertical wheel scrolls horizontally. Not clamped.
static func wheel_offset(el: UxmlElement, delta: Vector2, can_v: bool, can_h: bool) -> Vector2:
	var step := WHEEL_LINE
	if el.has_attribute("mouse-wheel-scroll-size"):
		step = _num(el, "mouse-wheel-scroll-size", WHEEL_LINE)
	var off := scroll_offset(el)
	if can_v:
		off.y += delta.y * step
	if can_h:
		off.x += (delta.y if not can_v and is_zero_approx(delta.x) else delta.x) * step
	return off


static func scroll_offset(el: UxmlElement) -> Vector2:
	return el.get_meta(META_SCROLL, Vector2.ZERO)


## The ScrollView's offset. Clamped to the scroll range of the last
## after_layout() (Unity's Scroller clamps its value). Returns true when
## the model changed.
static func set_scroll_offset(el: UxmlElement, off: Vector2, clamp_range: bool = true) -> bool:
	var vs := get_part(el, "vertical-scroller")
	var hs := get_part(el, "horizontal-scroller")
	if clamp_range:
		off = Vector2(_clamp_to(hs, off.x), _clamp_to(vs, off.y))
	el.set_meta(META_SCROLL, off)
	var changed := false
	if hs != null:
		changed = _write_value(hs, off.x) or changed
	if vs != null:
		changed = _write_value(vs, off.y) or changed
	var content := get_part(el, "content")
	if content != null:
		content.set_meta(&"uxml_translate", -off)
		changed = set_style(content, content_style(content)) or changed
	return changed


## The inline style of a ScrollView content container: the list height of
## a collection view, then the scroll translate.
static func content_style(content: UxmlElement) -> String:
	var out := ""
	var h: float = content.get_meta(&"uxml_height", -1.0)
	if h >= 0.0:
		out = "height: %s;" % px(h)
	var p: float = content.get_meta(&"uxml_padding", 0.0)
	if p > 0.0:
		out = (out + " padding-top: %s;" % px(p)).strip_edges()
	# Runtime v2 keeps the scroll offset out of the cascade (a position
	# offset of the table, V2ScrollViewBehavior).
	var t := "" if content.has_meta(&"uxml_translate_native") else _translate_style(content.get_meta(&"uxml_translate", Vector2.ZERO))
	if not t.is_empty():
		out = (out + " " + t).strip_edges()
	return out


static func _translate_style(t: Vector2) -> String:
	if t == Vector2.ZERO:
		return ""
	return "translate: %s %s;" % [px(t.x), px(t.y)]


static func _clamp_to(sc: UxmlElement, v: float) -> float:
	if sc == null:
		return v
	var lo := _num(sc, "low-value", 0.0)
	var hi := _num(sc, "high-value", 0.0)
	return clampf(v, minf(lo, hi), maxf(lo, maxf(hi, lo)))


static func _write_value(sc: UxmlElement, v: float) -> bool:
	var s := _num_text(v)
	if _attr(sc, "value") == s:
		return false
	sc.set_attribute("value", s)
	return true


static func _num_text(v: float) -> String:
	var r := snappedf(v, 0.0001)
	if is_equal_approx(r, roundf(r)):
		return str(int(roundf(r)))
	return str(r)


## Unity ScrollView.UpdateScrollers, run after a layout: show or hide each
## Scroller (`*-scroller-visibility`), enable it when the content
## overflows, set its range to the scrollable size and its dragger to the
## visible fraction, and keep the offset inside the new range. The
## horizontal Scroller leaves room for the vertical one. `size_of(el)`
## returns the laid-out size of an element (null for no layout).
## `bounds_of(content)`, when valid, returns the size of the content's
## bounding box (Unity `contentContainer.boundingBox`, see bounding_size);
## else the content size is used. Returns true when the model changed (the
## caller lays out again).
static func update_scroll_view(el: UxmlElement, size_of: Callable, bounds_of: Callable = Callable()) -> bool:
	var vp := get_part(el, "viewport")
	var content := get_part(el, "content")
	var vs := get_part(el, "vertical-scroller")
	var hs := get_part(el, "horizontal-scroller")
	if vp == null or content == null or vs == null or hs == null:
		return false
	var vsz = size_of.call(vp)
	var csz = size_of.call(content)
	if vsz == null or csz == null:
		return false
	var vpv: Vector2 = vsz
	var cs: Vector2 = csz
	if bounds_of.is_valid():
		var bb = bounds_of.call(content)
		if bb != null:
			cs = bb
	var scroll_w := cs.x - vpv.x
	var scroll_h := cs.y - vpv.y
	var vvis := scroller_visibility(el, "vertical")
	var hvis := scroller_visibility(el, "horizontal")
	var need_v := vvis == "AlwaysVisible" or (vvis == "Auto" and scroll_h > 0.001)
	var need_h := hvis == "AlwaysVisible" or (hvis == "Auto" and scroll_w > 0.001)
	var show_v := need_v and vvis != "Hidden"
	var show_h := need_h and hvis != "Hidden"
	var changed := false
	changed = _set_scroller_state(vs, show_v, scroll_h > 0.0, scroll_h,
		vpv.y / cs.y if cs.y > 0.0 else 1.0) or changed
	changed = _set_scroller_state(hs, show_h, scroll_w > 0.0, scroll_w,
		vpv.x / cs.x if cs.x > 0.0 else 1.0) or changed
	# Both shown: the horizontal Scroller stops where the vertical one starts.
	var margin := 0.0
	if show_v and show_h:
		var vss = size_of.call(vs)
		margin = 0.0 if vss == null else (vss as Vector2).x
	var hstyle := "" if show_h else "display: none;"
	if show_h and margin > 0.0:
		hstyle = "margin-right: %s;" % px(margin)
	changed = set_style(hs, hstyle) or changed
	changed = set_style(vs, "" if show_v else "display: none;") or changed
	changed = set_scroll_offset(el, scroll_offset(el)) or changed
	for sc in [vs, hs]:
		changed = update_scroller(sc, size_of) or changed
	return changed


## Unity VisualElement.boundingBox of `content`, as a size: the content box
## and the boxes of its children (margins excluded, translate ignored).
## Unity also takes the boxes of deeper descendants that overflow their
## parents; godot-uxml stops at the children, so a scroll after each
## layout does not walk the whole content. `rect_of(el)` returns the
## laid-out rect relative to the parent (null: not laid out).
static func bounding_size(content: UxmlElement, rect_of: Callable) -> Variant:
	var r = rect_of.call(content)
	if r == null:
		return null
	var bb := Rect2(Vector2.ZERO, (r as Rect2).size)
	for c in content.children:
		var cr = rect_of.call(c)
		if cr != null:
			bb = bb.merge(cr)
	return bb.size


static func _set_scroller_state(sc: UxmlElement, _shown: bool, enabled: bool, high: float, factor: float) -> bool:
	var changed := false
	if _attr(sc, "high-value") != _num_text(high):
		sc.set_attribute("high-value", _num_text(high))
		changed = true
	if _attr(sc, "low-value") != "0":
		sc.set_attribute("low-value", "0")
		changed = true
	var en := "true" if enabled else "false"
	if _attr(sc, "enabled", "true") != en:
		sc.set_attribute("enabled", en)
		changed = true
	if UxmlParts.control_classes(sc).has("unity-disabled") == enabled:
		UxmlParts.toggle_control_class(sc, "unity-disabled", not enabled)
		changed = true
	var old: float = sc.get_meta(META_FACTOR, -1.0)
	if not is_equal_approx(old, factor):
		sc.set_meta(META_FACTOR, factor)
		changed = true
	return changed


# ---------------------------------------------------------------------------
# Scroller
# ---------------------------------------------------------------------------

## Scroller: low RepeatButton, high RepeatButton, then a ScrollerSlider
## (BaseSlider parts: input > drag container > tracker, dragger border,
## dragger).
static func _build_scroller(el: UxmlElement) -> UxmlElement:
	var dir := scroller_direction(el)
	UxmlParts._add_control_classes(el, ["unity-scroller--" + dir])
	el.children.append(_part(el, "RepeatButton", "low-button", "unity-low-button",
		["unity-scroller__low-button"], ""))
	el.children.append(_part(el, "RepeatButton", "high-button", "unity-high-button",
		["unity-scroller__high-button"], ""))
	var slider := _part(el, "ScrollerSlider", "slider", "unity-slider",
		["unity-base-field", "unity-base-field--no-label", "unity-base-slider",
		"unity-base-slider--" + dir, "unity-slider", "unity-scroller__slider"])
	var input := _part(el, "VisualElement", "input", "",
		["unity-base-field__input", "unity-base-slider__input", "unity-slider__input"])
	var drag := _part(el, "VisualElement", "drag-container", "unity-drag-container",
		["unity-base-slider__drag-container"])
	drag.children.append(_part(el, "VisualElement", "tracker", "unity-tracker",
		["unity-base-slider__tracker"]))
	drag.children.append(_part(el, "VisualElement", "dragger-border", "unity-dragger-border",
		["unity-base-slider__dragger-border"]))
	drag.children.append(_part(el, "VisualElement", "dragger", "unity-dragger",
		["unity-base-slider__dragger"]))
	input.children.append(drag)
	slider.children.append(input)
	el.children.append(slider)
	return el


static func scroller_direction(el: UxmlElement) -> String:
	return "horizontal" if _attr(el, "direction", "Vertical") == "Horizontal" else "vertical"


## Unity BaseSlider.SliderNormalizeValue: 1 for an empty range.
static func normalized(v: float, lo: float, hi: float) -> float:
	if is_equal_approx(hi, lo):
		return 1.0
	return clampf((v - lo) / (hi - lo), 0.0, 1.0)


## Place the dragger (Unity BaseSlider.AdjustDragElement and
## UpdateDragElementPosition): a ScrollView sets the visible fraction
## (META_FACTOR); a fraction below 1 sizes the dragger to that part of the
## track, a fraction of 1 or more hides it. The dragger moves by
## `translate`, as in Unity. Returns true when the model changed.
static func update_scroller(sc: UxmlElement, size_of: Callable) -> bool:
	var drag := get_part(sc, "drag-container")
	var dragger := get_part(sc, "dragger")
	var border := get_part(sc, "dragger-border")
	if drag == null or dragger == null:
		return false
	var dsz = size_of.call(drag)
	var gsz = size_of.call(dragger)
	if dsz == null:
		return false
	var horizontal := scroller_direction(sc) == "horizontal"
	var axis := 0 if horizontal else 1
	var track: float = (dsz as Vector2)[axis]
	var factor: float = sc.get_meta(META_FACTOR, -1.0)
	var style := ""
	var size := 0.0 if gsz == null else (gsz as Vector2)[axis]
	var hidden := false
	if factor >= 0.0:
		if factor < 1.0:
			# Mathf.Round: halves to even.
			size = _round_half_even(track * factor)
			style += "%s: %s; " % ["width" if horizontal else "height", px(size)]
		else:
			hidden = true
	var lo := _num(sc, "low-value", 0.0)
	var hi := _num(sc, "high-value", 0.0)
	var v := _num(sc, "value", 0.0)
	var pos := normalized(v, lo, hi) * (track - size)
	var t := Vector2(pos, 0.0) if horizontal else Vector2(0.0, pos)
	var tstyle := _translate_style(t)
	dragger.set_meta(&"uxml_translate", t)
	if border != null:
		border.set_meta(&"uxml_translate", t)
	if dragger.has_meta(&"uxml_translate_native"):
		tstyle = ""
	var changed := false
	if hidden:
		style += "visibility: hidden; "
	style += tstyle
	changed = set_style(dragger, style.strip_edges()) or changed
	if border != null:
		changed = set_style(border, (("visibility: hidden; " if hidden else "") + tstyle).strip_edges()) or changed
	return changed


static func _round_half_even(x: float) -> float:
	var r := roundf(x)
	if is_equal_approx(absf(x - floorf(x)), 0.5):
		r = floorf(x) if int(floorf(x)) % 2 == 0 else ceilf(x)
	return r


# ---------------------------------------------------------------------------
# Collection views: ListView, TreeView, MultiColumnListView/TreeView
# ---------------------------------------------------------------------------

static func is_collection(local: String) -> bool:
	return local in ["ListView", "TreeView", "MultiColumnListView", "MultiColumnTreeView"]


static func is_tree(el: UxmlElement) -> bool:
	return el.local == "TreeView" or el.local == "MultiColumnTreeView"


static func is_multi_column(el: UxmlElement) -> bool:
	return el.local == "MultiColumnListView" or el.local == "MultiColumnTreeView"


## virtualization-method="DynamicHeight": rows take the height of their
## content (CollectionBehavior measures them).
static func is_dynamic(el: UxmlElement) -> bool:
	return _attr(el, "virtualization-method", "FixedHeight") == "DynamicHeight"


static func item_height(el: UxmlElement) -> float:
	var h := _num(el, "fixed-item-height", DEFAULT_ITEM_HEIGHT)
	return DEFAULT_ITEM_HEIGHT if h <= 0.0 else h


## The collection view: [foldout header], ScrollView (rows go into its
## content container), [add/remove footer], [size field]. A multi-column
## view puts its column header into the ScrollView ahead of the content.
static func _build_collection(el: UxmlElement) -> UxmlElement:
	var multi := is_multi_column(el)
	if multi and not el.has_meta(META_COLUMNS):
		read_columns(el)
	var header := _bool(el, "show-foldout-header", false) and not is_tree(el)
	var footer := _bool(el, "show-add-remove-footer", false) and not is_tree(el)
	var host := el
	if header:
		UxmlParts._add_control_classes(el, ["unity-list-view--with-header"])
		var fold := _part(el, "Foldout", "foldout-header", "unity-list-view__foldout-header",
			["unity-list-view__foldout-header"])
		fold.attributes.append({"name": "text", "value": _attr(el, "header-title"), "offset": 0})
		fold.attributes.append({"name": "value", "value": "true", "offset": 0})
		fold.set_meta(&"uxml_foldout_depth", 0)
		UxmlParts.build(fold)
		el.children.append(fold)
		host = get_part(fold, "content")
	if footer:
		UxmlParts._add_control_classes(el, ["unity-list-view--with-footer"])
	var sv := _part(el, "ScrollView", "scroll-view", "", ["unity-collection-view__scroll-view"])
	if _bool(el, "horizontal-scrolling", false) or multi:
		sv.attributes.append({"name": "mode", "value": "VerticalAndHorizontal" if _bool(el, "horizontal-scrolling", false) else "Vertical", "offset": 0})
	UxmlParts.build(sv)
	if _bool(el, "show-border", false):
		UxmlParts._add_control_classes(sv, ["unity-collection-view--with-border"])
	if footer:
		UxmlParts._add_control_classes(sv, ["unity-list-view__scroll-view--with-footer"])
	host.children.append(sv)
	if multi:
		sv.children.insert(0, _column_header(el))
	var content := get_part(sv, "content")
	if footer:
		var ft := _part(el, "VisualElement", "footer", "unity-list-view__footer", ["unity-list-view__footer"])
		ft.children.append(_part(el, "Button", "add-button", "unity-list-view__add-button", [], "+"))
		ft.children.append(_part(el, "Button", "remove-button", "unity-list-view__remove-button", [], "-"))
		host.children.append(ft)
	if header and _bool(el, "show-bound-collection-size", true):
		var cls := ["unity-list-view__size-field", "unity-list-view__size-field--with-header"]
		if footer:
			cls.append("unity-list-view__size-field--with-footer")
		var sf := _part(el, "TextField", "size-field", "unity-list-view__size-field", cls)
		sf.attributes.append({"name": "value", "value": "0", "offset": 0})
		UxmlParts.build(sf)
		el.children.append(sf)
	# Rows. The pool covers the tallest viewport; rows past the item count
	# are hidden.
	var h := item_height(el)
	var pool := clampi(int(floor(pool_height / h)) + 2, 2, 1000)
	var rows: Array = []
	for k in pool:
		var row := make_row(el, k)
		content.children.append(row)
		rows.append(row)
	el.set_meta(META_POOL, rows)
	return content


## One pooled row of a collection view, hidden until an item is bound.
static func make_row(el: UxmlElement, slot: int) -> UxmlElement:
	var h := -1.0 if is_dynamic(el) else item_height(el)
	var row: UxmlElement
	var item_classes := ["unity-collection-view__item"]
	if is_tree(el):
		var multi := is_multi_column(el)
		if multi:
			row = _part(el, "VisualElement", "item", "unity-multi-column-view__row-container",
				["unity-multi-column-view__row-container"] + item_classes + ["unity-tree-view__item"])
			_cells(el, row)
		else:
			row = _part(el, "VisualElement", "item", "unity-tree-view__item", ["unity-tree-view__item"] + item_classes)
		# A multi-column tree keeps the tree parts in its first cell.
		var tree_host := row
		if multi and not row.children.is_empty():
			tree_host = row.children[0]
			# Measured: the first cell lays the tree parts out in a row.
			tree_host.set_meta(&"uxml_base_style", "flex-direction: row;")
			_init_style(tree_host, "flex-direction: row;")
		var indent := _part(el, "VisualElement", "item-indent", "unity-tree-view__item-indent")
		_init_style(indent, "width: 0px;")
		var tree_parts: Array = [indent]
		var tg := _part(el, "Toggle", "item-toggle", "unity-tree-view__item-toggle",
			["unity-foldout__toggle", "unity-tree-view__item-toggle"])
		tg.attributes.append({"name": "value", "value": "false", "offset": 0})
		UxmlParts.build(tg)
		var inp := get_part(tg, "input")
		if inp != null:
			UxmlParts._append_class(inp, "unity-foldout__input")
		var ck := get_part(tg, "checkmark")
		if ck != null:
			UxmlParts._append_class(ck, "unity-foldout__checkmark")
		tree_parts.append(tg)
		var holder := _part(el, "VisualElement", "item-content", "unity-tree-view__item-content",
			["unity-tree-view__item-content"])
		tree_parts.append(holder)
		if multi:
			# The first cell's made cell moves into the item content.
			var made: Array = tree_host.children.duplicate()
			tree_host.children = tree_parts
			for m in made:
				holder.children.append(m)
		else:
			row.children.append_array(tree_parts)
			holder.children.append(_made_item(el, false))
	elif is_multi_column(el):
		row = _part(el, "VisualElement", "item", "unity-multi-column-view__row-container",
			["unity-multi-column-view__row-container"] + item_classes + ["unity-list-view__item"])
		_cells(el, row)
	elif _bool(el, "reorderable", false) and _attr(el, "reorder-mode", "Simple") == "Animated":
		row = _part(el, "VisualElement", "item", "unity-list-view__reorderable-item",
			["unity-list-view__reorderable-item"] + item_classes + ["unity-list-view__item"])
		var handle := _part(el, "VisualElement", "reorderable-handle", "unity-list-view__reorderable-handle",
			["unity-list-view__reorderable-handle"])
		for b in 2:
			handle.children.append(_part(el, "VisualElement", "reorderable-handle-bar",
				"unity-list-view__reorderable-handle-bar", ["unity-list-view__reorderable-handle-bar"]))
		row.children.append(handle)
		var c := _part(el, "VisualElement", "reorderable-item-container",
			"unity-list-view__reorderable-item__container", ["unity-list-view__reorderable-item__container"])
		c.children.append(_made_item(el, false))
		row.children.append(c)
	else:
		row = _made_item(el, true)
	row.part_role = "item"
	row.set_meta(META_ROW, -1)
	_init_style(row, row_style(h, false))
	return row


## Unity's makeItem: an instance of `item-template` (a TemplateContainer),
## else a Label. `as_row`: the made item is the row (gets the item classes).
static func _made_item(el: UxmlElement, as_row: bool) -> UxmlElement:
	var template: Array = el.get_meta(&"uxml_item_template", [])
	var it: UxmlElement
	if el.has_meta(&"uxml_item_template"):
		it = _part(el, "TemplateContainer", "made-item")
		for t in template:
			it.children.append(clone(t, el))
	else:
		it = _part(el, "Label", "made-item", "", [], "")
	if as_row:
		var cls := ["unity-collection-view__item", "unity-list-view__item"]
		UxmlParts._append_class(it, " ".join(cls))
	return it


## Deep copy of a template element; diagnostics point at `at`.
static func clone(t: UxmlElement, at: UxmlElement) -> UxmlElement:
	var c := UxmlElement.new()
	c.prefix = t.prefix
	c.local = t.local
	c.open_tag_start = at.open_tag_start
	c.open_tag_end = at.open_tag_end
	c.source_end = at.source_end
	for a in t.attributes:
		c.attributes.append({"name": a["name"], "value": a["value"], "offset": 0})
	for ch in t.children:
		c.children.append(clone(ch, at))
	return c


## The inline style of a row: the item height (none for DynamicHeight,
## h < 0) and `display: none` for an unused row.
static func row_style(h: float, visible: bool) -> String:
	if h < 0.0:
		return "" if visible else "display: none;"
	return "height: %s;%s" % [px(h), "" if visible else " display: none;"]


## The rows of a collection view in slot order.
static func rows_of(el: UxmlElement) -> Array:
	return el.get_meta(META_POOL, [])


## The element a bind callback fills: the made item of a row (the row
## itself for a plain ListView).
static func item_of(row: UxmlElement) -> UxmlElement:
	if row.local == "TemplateContainer" or row.local == "Label":
		return row
	for x in row.walk():
		if x.part_role == "made-item":
			return x
	return row


## Keep `n` rows (Unity creates floor(viewport / item height) + 2 rows);
## the rest leave the model. For bench/parity.gd, before the controls exist.
static func trim_rows(el: UxmlElement, n: int) -> void:
	var rows := rows_of(el)
	if rows.size() <= n:
		return
	var content := rows[0] as UxmlElement
	var parent: UxmlElement = null
	for x in el.walk():
		if x.children.has(content):
			parent = x
			break
	for k in range(n, rows.size()):
		if parent != null:
			parent.children.erase(rows[k])
	el.set_meta(META_POOL, rows.slice(0, n))


# ---- Columns ---------------------------------------------------------------

## Take the <Columns> and <SortColumnDescriptions> UxmlObjects out of a
## multi-column view and keep them as META_COLUMNS / META_SORT.
static func read_columns(el: UxmlElement) -> void:
	var cols: Array = []
	var sorts: Array = []
	var kept: Array = []
	for c in el.children:
		if c.local == "Columns":
			for col in c.children:
				if col.local == "Column":
					cols.append(_column_desc(col, cols.size()))
		elif c.local == "SortColumnDescriptions":
			for sd in c.children:
				if sd.local == "SortColumnDescription":
					sorts.append({
						"column_name": _attr(sd, "column-name"),
						"column_index": int(_num(sd, "column-index", -1.0)),
						"direction": _attr(sd, "direction", "Ascending"),
					})
		else:
			kept.append(c)
	el.children = kept
	el.set_meta(META_COLUMNS, cols)
	el.set_meta(META_SORT, sorts)


static func _column_desc(col: UxmlElement, index: int) -> Dictionary:
	var w = col.get_attribute("width")
	return {
		"index": index,
		"name": _attr(col, "name"),
		"title": _attr(col, "title"),
		"width": -1.0 if w == null else _num(col, "width", -1.0),
		"min_width": _num(col, "min-width", 35.0),
		"max_width": _num(col, "max-width", 8388608.0),
		"stretchable": _bool(col, "stretchable", false),
		"sortable": _bool(col, "sortable", true),
		"resizable": _bool(col, "resizable", true),
		"optional": _bool(col, "optional", true),
		"visible": _bool(col, "visible", true),
		"cell_template": _attr(col, "cell-template"),
		"header_template": _attr(col, "header-template"),
		"icon": _attr(col, "icon"),
	}


static func columns_of(el: UxmlElement) -> Array:
	return el.get_meta(META_COLUMNS, [])


## Resolved widths of the visible columns (Unity MultiColumnController):
## fixed widths first, the rest shared by the stretchable columns, each
## clamped to its min/max. `total` is the header width.
static func column_widths(el: UxmlElement, total: float) -> Array:
	var cols := columns_of(el)
	var out: Array = []
	var fixed := 0.0
	var stretch := 0
	for c in cols:
		if not c["visible"]:
			out.append(0.0)
			continue
		var w: float = c["width"]
		if c.has("user_width"):
			w = c["user_width"]
		if w < 0.0 and not c["stretchable"]:
			w = c["min_width"]
		if c["stretchable"] and not c.has("user_width") and w < 0.0:
			out.append(-1.0)
			stretch += 1
			continue
		w = clampf(w, c["min_width"], c["max_width"])
		out.append(w)
		fixed += w
	if stretch > 0:
		var share := maxf(0.0, total - fixed) / stretch
		for k in out.size():
			if out[k] < 0.0:
				var c: Dictionary = cols[k]
				out[k] = clampf(share, c["min_width"], c["max_width"])
	return out


## The header of a multi-column view: header container >
## MultiColumnCollectionHeader > (column container > one column per Column,
## resize handle container > one handle per Column).
static func _column_header(el: UxmlElement) -> UxmlElement:
	var hc := _part(el, "VisualElement", "header-container", "unity-multi-column-view__header-container",
		["unity-multi-column-view__header-container"])
	var header := _part(el, "MultiColumnCollectionHeader", "header", "", ["unity-multi-column-header"])
	var cc := _part(el, "VisualElement", "column-container", "", ["unity-multi-column-header__column-container"])
	var rc := _part(el, "VisualElement", "resize-handle-container", "",
		["unity-multi-column-header__resize-handle-container"])
	var sortable := _attr(el, "sorting-mode", "None") != "None" or _bool(el, "sorting-enabled", false)
	for c in columns_of(el):
		if c["stretchable"] and cc.get_attribute("style") == null:
			# Unity grows the column container when a column stretches
			# (measured: ctl-multicolumn-listview).
			cc.attributes.append({"name": "style", "value": "flex-grow: 1;", "offset": 0})
	for c in columns_of(el):
		var col := _part(el, "MultiColumnHeaderColumn", "header-column", c["name"],
			["unity-multi-column-header__column"] + (["unity-multi-column-header__column--sortable"] if sortable and c["sortable"] else []))
		col.set_meta(&"uxml_column", c["index"])
		var ind := _part(el, "MultiColumnHeaderColumnSortIndicator", "sort-indicator", "",
			["unity-multi-column-header__column__sort-indicator"])
		ind.children.append(_part(el, "VisualElement", "sort-arrow", "",
			["unity-multi-column-header__column__sort-indicator__arrow"]))
		ind.children.append(_part(el, "Label", "sort-index", "",
			["unity-multi-column-header__column__sort-indicator__index-label"], ""))
		col.children.append(ind)
		var ccont := _part(el, "VisualElement", "column-content-container", "",
			["unity-multi-column-header__column__content-container"])
		var htpl: Array = el.get_meta(&"uxml_header_template_%d" % c["index"], [])
		if not htpl.is_empty():
			# Column header-template: its instance replaces the default
			# content (icon and title).
			var hti := _part(el, "TemplateContainer", "column-content", "",
				["unity-multi-column-header__column__content"])
			for t in htpl:
				hti.children.append(clone(t, el))
			ccont.children.append(hti)
		else:
			var dc := _part(el, "VisualElement", "column-content", "",
				["unity-multi-column-header__column__default-content", "unity-multi-column-header__column__content"]
				+ (["unity-multi-column-header__column__content--has-title"] if not String(c["title"]).is_empty() else []))
			var icon := _part(el, "MultiColumnHeaderColumnIcon", "column-icon",
				"unity-multi-column-header-column-icon", ["unity-image", "unity-multi-column-header__column__icon"])
			if not String(c["icon"]).is_empty():
				# Column icon: the theme hides an empty icon.
				icon.attributes.append({"name": "image", "value": c["icon"], "offset": 0})
				_init_style(icon, "visibility: visible;")
			dc.children.append(icon)
			dc.children.append(_part(el, "Label", "column-title", "unity-multi-column-header-column-title",
				["unity-multi-column-header__column__title"], c["title"]))
			ccont.children.append(dc)
		col.children.append(ccont)
		cc.children.append(col)
		var hnd := _part(el, "MultiColumnHeaderColumnResizeHandle", "resize-handle", "",
			["unity-multi-column-header__column-resize-handle"])
		hnd.set_meta(&"uxml_column", c["index"])
		hnd.children.append(_part(el, "VisualElement", "resize-drag-area", "",
			["unity-multi-column-header__column-resize-handle__drag-area"]))
		rc.children.append(hnd)
	header.children.append(cc)
	header.children.append(rc)
	hc.children.append(header)
	return hc


## One cell per column in a multi-column row; each cell holds the made
## cell (cell-template instance, else a Label).
static func _cells(el: UxmlElement, row: UxmlElement) -> void:
	for c in columns_of(el):
		var cell := _part(el, "VisualElement", "cell", "", ["unity-multi-column-view__cell"])
		cell.set_meta(&"uxml_column", c["index"])
		var tpl: Array = el.get_meta(&"uxml_cell_template_%d" % c["index"], [])
		if not tpl.is_empty():
			var it := _part(el, "TemplateContainer", "made-cell")
			for t in tpl:
				it.children.append(clone(t, el))
			cell.children.append(it)
		else:
			cell.children.append(_part(el, "Label", "made-cell", "", ["unity-multi-column-view__cell__label"], ""))
		row.children.append(cell)


## Header column and cell widths for `total` header width. Returns true
## when the model changed.
static func update_columns(el: UxmlElement, total: float) -> bool:
	var widths := column_widths(el, total)
	var changed := false
	var cols := columns_of(el)
	for x in el.walk():
		if x.part_of != el or not x.has_meta(&"uxml_column"):
			continue
		var i: int = x.get_meta(&"uxml_column")
		if i < 0 or i >= widths.size():
			continue
		var w: float = widths[i]
		var vis: bool = cols[i]["visible"]
		match x.part_role:
			"header-column", "cell":
				var base: String = x.get_meta(&"uxml_base_style", "")
				changed = set_style(x, (base + " " + (("width: %s;" % px(w)) if vis else "display: none;")).strip_edges()) or changed
			"resize-handle":
				var left := 0.0
				for k in i + 1:
					left += widths[k]
				var last := i == widths.size() - 1
				changed = set_style(x, ("left: %s;" % px(left)) if (vis and not last and cols[i]["resizable"]) else "display: none;") or changed
	return changed


# ---------------------------------------------------------------------------
# TabView, Tab
# ---------------------------------------------------------------------------

## TabView: content viewport (header container + next/previous
## RepeatButtons), then the content container that holds the Tabs. A Tab's
## header moves into the header container; the Tab keeps its content.
static func _build_tab_view(el: UxmlElement) -> UxmlElement:
	if _bool(el, "reorderable", false):
		UxmlParts._add_control_classes(el, ["unity-tab-view__reorderable"])
	var vp := _part(el, "VisualElement", "content-viewport", "", ["unity-tab-view__content-viewport"])
	var hc := _part(el, "VisualElement", "header-container", "unity-tab-view__header-container",
		["unity-tab-view__header-container"])
	vp.children.append(hc)
	var nx := _part(el, "RepeatButton", "next-button", "", ["unity-tab-view__next-button"], "")
	var pv := _part(el, "RepeatButton", "previous-button", "", ["unity-tab-view__previous-button"], "")
	_init_style(nx, "display: none;")
	_init_style(pv, "display: none;")
	vp.children.append(nx)
	vp.children.append(pv)
	el.children.append(vp)
	var content := _part(el, "TabViewContentContainer", "content", "unity-tab-view__content-container",
		["unity-tab-view__content-container"])
	el.children.append(content)
	return content


## Tab: header (image, label, underline, [close button]) and the content
## container. Inside a TabView the header lives in the TabView's header
## container (move_tab_headers).
static func _build_tab(el: UxmlElement) -> UxmlElement:
	var header := _part(el, "VisualElement", "header", "unity-tab__header", ["unity-tab__header"])
	var closeable := _bool(el, "closeable", false)
	if closeable:
		UxmlParts._append_class(header, "unity-tab__header__closeable")
	var img := _part(el, "Image", "header-image", "unity-tab__header-image",
		["unity-tab__header-image"] + ([] if el.has_attribute("icon-image") else ["unity-tab__header-image--empty"]))
	if el.has_attribute("icon-image"):
		img.attributes.append({"name": "image", "value": _attr(el, "icon-image"), "offset": 0})
	header.children.append(img)
	header.children.append(_part(el, "Label", "header-label", "unity-tab__header-label",
		["unity-tab__header-label"], _attr(el, "label")))
	header.children.append(_part(el, "VisualElement", "header-underline", "unity-tab__header-underline",
		["unity-tab__header-underline"]))
	if closeable:
		header.children.append(_part(el, "VisualElement", "close-button", "unity-tab__close-button",
			["unity-tab__close-button"]))
	el.children.append(header)
	var content := _part(el, "VisualElement", "content", "unity-tab__content-container",
		["unity-tab__content-container"])
	el.children.append(content)
	return content


## Move the header of every Tab of a TabView into the header container
## (Unity's TabView.OnElementAdded). Run after the Tabs are built.
static func move_tab_headers(view: UxmlElement) -> void:
	var hc := get_part(view, "header-container")
	var content := get_part(view, "content")
	if hc == null or content == null:
		return
	var reorder := _bool(view, "reorderable", false)
	var k := 0
	for tab in content.children:
		if tab.local != "Tab":
			continue
		var header := get_part(tab, "header")
		if header == null:
			continue
		# Cache the header parts: find_part cannot reach them after the move.
		for role in ["header-image", "header-label", "header-underline", "close-button"]:
			get_part(tab, role)
		tab.children.erase(header)
		if reorder:
			var handle := _part(tab, "VisualElement", "reorderable-handle", "unity-tab__reorderable-handle",
				["unity-tab__reorderable-handle"])
			handle.children.append(_part(tab, "VisualElement", "reorderable-handle-bar",
				"unity-tab__reorderable-handle-bar", ["unity-tab__reorderable-handle-bar", "unity-tab__reorderable-handle-bar--left"]))
			handle.children.append(_part(tab, "VisualElement", "reorderable-handle-bar",
				"unity-tab__reorderable-handle-bar", ["unity-tab__reorderable-handle-bar"]))
			header.children.insert(0, handle)
			var cache: Dictionary = tab.get_meta(&"uxml_part_cache", {})
			cache["reorderable-handle"] = weakref(handle)
			tab.set_meta(&"uxml_part_cache", cache)
		hc.children.append(header)
		tab.set_meta(&"uxml_tab_index", k)
		k += 1


## Selected tab `index` of a TabView: its header and Tab are :checked
## (states, set by the behavior), the other Tabs are `display: none`.
static func select_tab_model(view: UxmlElement, index: int) -> bool:
	var content := get_part(view, "content")
	if content == null:
		return false
	var changed := false
	var k := 0
	for tab in content.children:
		if tab.local != "Tab":
			continue
		changed = set_style(tab, "" if k == index else "display: none;") or changed
		k += 1
	return changed


static func tabs_of(view: UxmlElement) -> Array:
	var out: Array = []
	var content := get_part(view, "content")
	if content != null:
		for tab in content.children:
			if tab.local == "Tab":
				out.append(tab)
	return out


# ---------------------------------------------------------------------------
# TwoPaneSplitView
# ---------------------------------------------------------------------------

## TwoPaneSplitView: #unity-content-container (the panes), then the
## dragline anchor with the dragline (the splitter). The fixed pane gets
## `fixed-pane-initial-dimension`, the other pane grows.
static func _build_two_pane(el: UxmlElement) -> UxmlElement:
	var o := two_pane_orientation(el)
	var content := _part(el, "VisualElement", "content", "unity-content-container",
		["unity-two-pane-split-view__content-container", "unity-two-pane-split-view--" + o])
	el.children.append(content)
	var anchor := _part(el, "VisualElement", "dragline-anchor", "unity-dragline-anchor",
		["unity-two-pane-split-view__dragline-anchor", "unity-two-pane-split-view__dragline-anchor--" + o])
	anchor.children.append(_part(el, "VisualElement", "dragline", "unity-dragline",
		["unity-two-pane-split-view__dragline", "unity-two-pane-split-view__dragline--" + o]))
	el.children.append(anchor)
	return content


## The fixed pane's margin total on the split axis, from its computed
## style (`style_of.call(el) -> Dictionary`), on the pixel grid.
static func two_pane_margins(el: UxmlElement, style_of: Callable) -> float:
	var content := get_part(el, "content")
	if content == null:
		return 0.0
	var panes: Array = []
	for c in content.children:
		if not UssControls.is_non_visual(c.local):
			panes.append(c)
	if panes.size() < 2:
		return 0.0
	var fixed: UxmlElement = panes[clampi(int(_num(el, "fixed-pane-index", 0.0)), 0, 1)]
	var st: Dictionary = style_of.call(fixed)
	var vertical := two_pane_orientation(el) == "vertical"
	var total := 0.0
	for prop in (["margin-top", "margin-bottom"] if vertical else ["margin-left", "margin-right"]):
		total += UxmlFlexLayout.grid_box(UxmlInputParts.style_px(st, prop), false)
	return total


static func two_pane_orientation(el: UxmlElement) -> String:
	return "vertical" if _attr(el, "orientation", "Horizontal") == "Vertical" else "horizontal"


## Pane and splitter styles for fixed pane dimension `dim` (Unity
## TwoPaneSplitView.Init and the dragline manipulator). `margins` is the
## fixed pane's margin total on the split axis: Unity places the dragline
## anchor past the pane's margins (PostDisplaySetup; measured: ctl-more-2).
static func two_pane_style(el: UxmlElement, dim: float, margins: float = 0.0) -> bool:
	var content := get_part(el, "content")
	var anchor := get_part(el, "dragline-anchor")
	if content == null:
		return false
	var panes: Array = []
	for c in content.children:
		if not UssControls.is_non_visual(c.local):
			panes.append(c)
	var vertical := two_pane_orientation(el) == "vertical"
	var fixed_i := clampi(int(_num(el, "fixed-pane-index", 0.0)), 0, 1)
	var changed := false
	if panes.size() >= 2:
		# Measured (ctl-twopane): the second pane starts 1px after the
		# first, past the dragline anchor.
		var shift := ("top: 1px;" if vertical else "left: 1px;")
		var fixed: UxmlElement = panes[fixed_i]
		var flex: UxmlElement = panes[1 - fixed_i]
		changed = _pane_style(fixed, "flex-grow: 0; flex-shrink: 0; flex-basis: auto; %s: %s;%s" % [
			"height" if vertical else "width", px(dim), (" " + shift) if fixed_i == 1 else ""]) or changed
		changed = _pane_style(flex, "flex-grow: 1; flex-shrink: 0; flex-basis: 0px;%s" % [
			(" " + shift) if fixed_i == 0 else ""]) or changed
	if anchor != null:
		var pos := dim if fixed_i == 0 else -1.0
		var style := ""
		if fixed_i == 0:
			style = "%s: %s;" % ["top" if vertical else "left", px(pos + margins)]
		else:
			style = "%s: %s;" % ["bottom" if vertical else "right", px(dim + margins)]
		changed = set_style(anchor, style) or changed
	return changed


## A pane's inline style: the split view's sizing after the author's own
## inline style (kept in meta at the first call).
static func _pane_style(pane: UxmlElement, ours: String) -> bool:
	if not pane.has_meta(&"uxml_pane_style"):
		var a = pane.get_attribute("style")
		pane.set_meta(&"uxml_pane_style", "" if a == null else String(a))
	var base: String = String(pane.get_meta(&"uxml_pane_style")).strip_edges()
	if not base.is_empty() and not base.ends_with(";"):
		base += ";"
	return set_style(pane, (base + " " + ours).strip_edges())


# ---------------------------------------------------------------------------
# IMGUIContainer
# ---------------------------------------------------------------------------

## IMGUIContainer: no parts. The runtime hosts a Godot draw callback in it
## (UxmlImguiBox).
static func _build_imgui(el: UxmlElement) -> UxmlElement:
	return el


# ---------------------------------------------------------------------------
# After layout (runtime and bench/parity.gd)
# ---------------------------------------------------------------------------

## Unity's post-layout updates on the model for every ScrollView, Scroller
## and multi-column header under `root`. Returns true when the model
## changed (lay out again).
static func after_layout(root: UxmlElement, size_of: Callable, bounds_of: Callable = Callable()) -> bool:
	var changed := false
	for el in root.walk():
		match el.local:
			"ScrollView":
				changed = update_scroll_view(el, size_of, bounds_of) or changed
			"Scroller":
				if el.part_of == null or el.part_of.local != "ScrollView":
					changed = update_scroller(el, size_of) or changed
			"Tab":
				changed = update_lone_tab(el, size_of) or changed
			"MultiColumnListView", "MultiColumnTreeView":
				var hc := get_part(el, "header")
				if hc != null:
					var s = size_of.call(hc)
					if s != null:
						changed = update_columns(el, (s as Vector2).x) or changed
	return changed


## A Tab outside a TabView keeps its header. Unity lays the underline of
## that header out as wide as the Tab, not as the header (measured:
## ctl-tabview, a 400px underline under an 81px header): the underline
## gets the width of the Tab. Returns true when the model changed.
static func update_lone_tab(el: UxmlElement, size_of: Callable) -> bool:
	var header := get_part(el, "header")
	if header == null or not el.children.has(header):
		return false
	var ul := get_part(el, "header-underline")
	var sz = size_of.call(el)
	if ul == null or sz == null:
		return false
	return set_style(ul, "width: %s;" % px((sz as Vector2).x))


## Before UxmlParts.expand moves author children: the Column UxmlObjects
## of the multi-column views leave the tree (META_COLUMNS).
static func before_expand(doc: UxmlDocumentModel) -> void:
	for el in doc.root.walk():
		if is_multi_column(el) and not el.has_meta(META_COLUMNS):
			read_columns(el)


## Steps of UxmlParts.expand that need every part tree built: Tab headers
## move into their TabView, split views style their panes.
static func after_expand(doc: UxmlDocumentModel) -> void:
	var views: Array = []
	for el in doc.root.walk():
		if el.local == "TabView" or el.local == "TwoPaneSplitView":
			views.append(el)
	for el in views:
		if el.local == "TabView":
			move_tab_headers(el)
			select_tab_model(el, 0)
		else:
			two_pane_style(el, _num(el, "fixed-pane-initial-dimension", 100.0))


# ---------------------------------------------------------------------------
# Rows: item data on the model (shared by the runtime and bench/parity.gd)
# ---------------------------------------------------------------------------

## Visible items of a tree, depth first: [{id, data, depth, children,
## expanded}]. `roots` are Dictionaries {id, data, children: Array}; an
## item without an id gets its position in the walk. `expanded` holds the
## ids of the open items.
static func flatten_tree(roots: Array, expanded: Dictionary) -> Array:
	var out: Array = []
	_flatten(roots, 0, expanded, out)
	return out


static func _flatten(items: Array, depth: int, expanded: Dictionary, out: Array) -> void:
	for it in items:
		var d: Dictionary = it if it is Dictionary else {"data": it}
		var kids: Array = d.get("children", [])
		var id = d.get("id", out.size())
		var open := expanded.has(id)
		out.append({"id": id, "data": d.get("data"), "depth": depth,
			"children": kids.size(), "expanded": open, "item": d})
		if open and not kids.is_empty():
			_flatten(kids, depth + 1, expanded, out)


## Every id of a tree (Unity ExpandAll).
static func tree_ids(roots: Array, out: Dictionary = {}) -> Dictionary:
	for it in roots:
		if it is Dictionary:
			out[it.get("id", out.size())] = true
			tree_ids(it.get("children", []), out)
	return out


## Show or hide a row and set the classes and tree parts of item `index`
## (-1 hides the row). `info`: {depth, children, expanded} for tree rows.
## The made item's content is the bind callback's job.
static func bind_row(el: UxmlElement, row: UxmlElement, index: int, selected: bool, info: Dictionary = {}) -> bool:
	var h := -1.0 if is_dynamic(el) else item_height(el)
	var changed := false
	row.set_meta(META_ROW, index)
	changed = set_style(row, row_style(h, index >= 0)) or changed
	if index < 0:
		return changed
	var cc := UxmlParts.control_classes(row).duplicate()
	var want := cc.duplicate()
	for c in ["unity-collection-view__item--selected", "unity-collection-view__item--alternative-background"]:
		if want.has(c):
			want.remove_at(want.find(c))
	if selected:
		want.append("unity-collection-view__item--selected")
	if _attr(el, "show-alternating-row-backgrounds", "None") in ["ContentOnly", "All"] and index % 2 == 1:
		want.append("unity-collection-view__item--alternative-background")
	if want != cc:
		UxmlParts.set_control_classes(row, want)
		changed = true
	if is_tree(el):
		var depth := int(info.get("depth", 0))
		var host := row
		if is_multi_column(el) and not row.children.is_empty():
			host = row.children[0]
		for x in host.children:
			if x.part_role == "item-indent":
				changed = set_style(x, "width: %s;" % px(depth * TREE_INDENT)) or changed
				var has := UxmlParts.control_classes(x).has("unity-tree-view__item-indent")
				if has != (depth > 0):
					UxmlParts.toggle_control_class(x, "unity-tree-view__item-indent", depth > 0)
					changed = true
			elif x.part_role == "item-toggle":
				var leaf := int(info.get("children", 0)) == 0
				changed = set_style(x, "visibility: hidden;" if leaf else "") or changed
				var v := "true" if info.get("expanded", false) else "false"
				if _attr(x, "value") != v:
					x.set_attribute("value", v)
					changed = true
	return changed


## The default bind (Unity's when no bindItem is given): the item's text in
## the made Label (every cell Label of a multi-column row).
static func bind_text(row: UxmlElement, text: String) -> bool:
	var changed := false
	for x in row.walk():
		if (x.part_role == "made-item" or x.part_role == "made-cell") and x.local == "Label":
			if _attr(x, "text") != text:
				x.set_attribute("text", text)
				changed = true
		elif x == row and x.local == "Label" and _attr(x, "text") != text:
			x.set_attribute("text", text)
			changed = true
	return changed


## The content container's height for `count` items (Unity's fixed-height
## virtualization sets it inline).
## DynamicHeight: the content container is `height` high (-1: auto) with a
## top padding of `padding` (Unity's contentHeight and contentPadding).
static func content_extent(el: UxmlElement, height: float, padding: float) -> bool:
	var sv := get_part(el, "scroll-view")
	var content: UxmlElement = null if sv == null else get_part(sv, "content")
	if content == null:
		return false
	content.set_meta(&"uxml_height", height)
	content.set_meta(&"uxml_padding", padding)
	return set_style(content, content_style(content))


static func content_height(el: UxmlElement, count: int) -> bool:
	var sv := get_part(el, "scroll-view")
	if sv == null:
		return false
	var content := get_part(sv, "content")
	if content == null:
		return false
	content.set_meta(&"uxml_height", count * item_height(el) if count > 0 else -1.0)
	return set_style(content, content_style(content))
