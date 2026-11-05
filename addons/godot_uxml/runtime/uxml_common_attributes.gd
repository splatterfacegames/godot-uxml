class_name UxmlCommonAttributes
extends RefCounted
## The VisualElement base attributes that act on the built control tree:
## `tabindex`, `picking-mode`, `language-direction`, `usage-hints` and
## `view-data-key`.
##
## One instance per UxmlDocument, kept across loads (the view-data store
## must survive load_document/reload). setup() runs once per load after the
## controls exist and before the first restyle; a document that uses none
## of these attributes is not touched.
##
##   tabindex            Unity focus ring order: tabindex > 0 first, in
##                       ascending order, then tabindex = 0 in tree order;
##                       tabindex < 0 leaves the Tab ring but the element
##                       stays focusable by pointer. Written as Godot
##                       focus_next/focus_previous chains, and Tab/Shift-Tab
##                       skip ring members that are hidden or disabled.
##   picking-mode        Position (default) | Ignore. Ignore sets
##                       mouse_filter IGNORE on the element's controls, so
##                       pointer events reach the controls under it and the
##                       element's children stay pickable, as in Unity.
##   language-direction  Inherit (default) | LTR | RTL. Sets text_direction
##                       on the element's text controls; Inherit takes the
##                       nearest ancestor's value.
##   usage-hints         Unity renderer performance hints. Validated, no
##                       effect.
##   view-data-key       Per-key view state: ScrollView and collection
##                       scroll offset and selection, TabView tab,
##                       TwoPaneSplitView pane size, column widths and
##                       sorting. get_view_data()/set_view_data(); the
##                       store is captured before a load and restored
##                       after it.

const USAGE_HINTS := ["None", "DynamicTransform", "GroupTransform", "MaskContainer",
	"DynamicColor", "DynamicPostProcessing", "LargePixelCoverage"]
const PICKING := ["Position", "Ignore"]
const DIRECTIONS := ["Inherit", "LTR", "RTL"]

var _doc: UxmlDocument = null
## Full hierarchical view-data key -> view state ({"scroll_offset":
## Vector2, ...}).
var _view_store: Dictionary = {}
var _keyed: Array = []          # elements with a view-data-key (this load)
var _ring: Array = []           # focus targets in Unity focus-ring order
var _ring_index: Dictionary = {}


func _init(doc: UxmlDocument) -> void:
	_doc = doc


func clear() -> void:
	_keyed.clear()
	_ring.clear()
	_ring_index.clear()


## Apply the attributes to the controls of the freshly built tree.
func setup() -> void:
	var any_tab := false
	var any_dir := false
	for el in _doc._controls:
		if el == _doc._doc.root:
			continue
		if el.has_attribute("tabindex"):
			any_tab = true
		if el.has_attribute("language-direction"):
			any_dir = true
		if el.has_attribute("picking-mode"):
			_apply_picking(el)
		if el.has_attribute("usage-hints"):
			_check_usage_hints(el)
		if el.has_attribute("view-data-key") and not String(el.get_attribute("view-data-key")).is_empty():
			_keyed.append(el)
	if any_dir:
		_apply_directions()
	if any_tab:
		rebuild_focus_ring()


# ---------------------------------------------------------------------------
# picking-mode
# ---------------------------------------------------------------------------

func _apply_picking(el: UxmlElement) -> void:
	var v := String(el.get_attribute("picking-mode")).strip_edges()
	var i := PICKING.find(v)
	if i < 0:
		_warn(el, 'picking-mode="%s" is not Position or Ignore; Position used' % v)
		return
	set_picking(el, i == 1)


## Picking for one element: ignore=true lets pointer events through.
func set_picking(el: UxmlElement, ignore: bool) -> void:
	var c: Control = _doc._controls.get(el)
	if c == null:
		return
	var parts: Array = [c]
	var native: Control = _doc._natives.get(el, c)
	if native != c:
		parts.append(native)
	for p in parts:
		if not p.has_meta("uxml_mouse_authored"):
			p.set_meta("uxml_mouse_authored", int(p.get_meta("uxml_mouse", p.mouse_filter)))
		var want: int = Control.MOUSE_FILTER_IGNORE if ignore else int(p.get_meta("uxml_mouse_authored"))
		# The applier restores mouse_filter from this meta whenever the
		# element is shown, and forces IGNORE while it is hidden.
		p.set_meta("uxml_mouse", want)
		if c.visible:
			p.mouse_filter = want


# ---------------------------------------------------------------------------
# usage-hints
# ---------------------------------------------------------------------------

func _check_usage_hints(el: UxmlElement) -> void:
	var raw := String(el.get_attribute("usage-hints"))
	for part in raw.replace("|", ",").replace(" ", ",").split(",", false):
		if not USAGE_HINTS.has(String(part).strip_edges()):
			_warn(el, 'usage-hints="%s": "%s" is not a UsageHints flag; the hint is ignored' % [raw, part])
			return


# ---------------------------------------------------------------------------
# language-direction
# ---------------------------------------------------------------------------

func _apply_directions() -> void:
	for el in _doc._controls:
		if el == _doc._doc.root:
			continue
		var d := effective_direction(el)
		if d != 0 or el.has_attribute("language-direction"):
			_set_direction(el, d)


## 0 = Inherit (no direction anywhere up the tree), 1 = LTR, 2 = RTL.
func effective_direction(el: UxmlElement) -> int:
	var cur: UxmlElement = el
	while cur != null:
		var v = cur.get_attribute("language-direction")
		if v != null:
			var i := DIRECTIONS.find(String(v).strip_edges())
			if i < 0:
				if cur == el:
					_warn(el, 'language-direction="%s" is not Inherit, LTR or RTL; Inherit used' % v)
			elif i > 0:
				return i
		cur = _doc._parents.get(cur)
	return 0


func _set_direction(el: UxmlElement, d: int) -> void:
	# Inherit with no direction above: Godot's default (AUTO, from the text).
	var td: int = [Control.TEXT_DIRECTION_AUTO, Control.TEXT_DIRECTION_LTR,
		Control.TEXT_DIRECTION_RTL][d]
	var c: Control = _doc._controls.get(el)
	if c == null:
		return
	for t in [c, _doc._natives.get(el, c)]:
		if t is Label or t is Button or t is LineEdit or t is TextEdit:
			t.text_direction = td
	if c is UxmlField and (c as UxmlField).caption != null:
		(c as UxmlField).caption.text_direction = td


## Re-apply directions after a runtime change of language-direction.
func refresh_directions() -> void:
	_apply_directions()


# ---------------------------------------------------------------------------
# tabindex: Unity's focus ring
# ---------------------------------------------------------------------------

## Parsed tabindex of `el` (0 when absent or invalid).
func tab_index(el: UxmlElement) -> int:
	var v = el.get_attribute("tabindex")
	if v == null:
		return 0
	var s := String(v).strip_edges()
	if not s.is_valid_int():
		_warn(el, 'tabindex="%s" is not an integer; 0 used' % v)
		return 0
	return int(s)


## Rebuild the Tab ring from the current tabindex attributes.
func rebuild_focus_ring() -> void:
	for t in _ring:
		if is_instance_valid(t) and t.gui_input.is_connected(_on_ring_input):
			t.gui_input.disconnect(_on_ring_input)
	_ring.clear()
	_ring_index.clear()
	var records: Array = []  # [tabindex, tree order, target]
	var order := 0
	for el in _doc._doc.root.walk():
		var c: Control = _doc._controls.get(el)
		if c == null or el == _doc._doc.root:
			continue
		var target: Control = _doc._natives.get(el, c)
		var ti := tab_index(el)
		if not target.has_meta("uxml_focus_authored"):
			target.set_meta("uxml_focus_authored", int(target.get_meta("uxml_focus", target.focus_mode)))
		var authored: int = target.get_meta("uxml_focus_authored")
		if authored == Control.FOCUS_NONE:
			continue  # not focusable: tabindex has no effect
		# tabindex < 0: still focusable by pointer, never by Tab.
		var want: int = Control.FOCUS_CLICK if ti < 0 else authored
		if int(target.get_meta("uxml_focus", target.focus_mode)) != want:
			target.set_meta("uxml_focus", want)
			if target.focus_mode != Control.FOCUS_NONE:
				target.focus_mode = want
		if ti < 0 or want != Control.FOCUS_ALL:
			continue
		records.append([ti, order, target])
		order += 1
	records.sort_custom(func(a, b):
		if a[0] == b[0]:
			return a[1] < b[1]
		if a[0] == 0:
			return false
		if b[0] == 0:
			return true
		return a[0] < b[0])
	for r in records:
		_ring_index[r[2]] = _ring.size()
		_ring.append(r[2])
	var n := _ring.size()
	for i in n:
		var t: Control = _ring[i]
		t.focus_next = t.get_path_to(_ring[(i + 1) % n])
		t.focus_previous = t.get_path_to(_ring[(i - 1 + n) % n])
		t.gui_input.connect(_on_ring_input.bind(t))


## The focus targets in Tab order (for tests and tools).
func focus_ring() -> Array:
	return _ring.duplicate()


func _on_ring_input(ev: InputEvent, from: Control) -> void:
	var dir := 0
	if ev.is_action_pressed("ui_focus_next", true, true):
		dir = 1
	elif ev.is_action_pressed("ui_focus_prev", true, true):
		dir = -1
	if dir == 0:
		return
	var i: int = _ring_index.get(from, -1)
	if i < 0:
		return
	var n := _ring.size()
	for step in range(1, n + 1):
		var t: Control = _ring[(i + dir * step + n * n) % n]
		if t == from:
			break
		if t.is_visible_in_tree() and t.focus_mode == Control.FOCUS_ALL:
			t.grab_focus()
			from.accept_event()
			return


# ---------------------------------------------------------------------------
# view-data-key
# ---------------------------------------------------------------------------

## Unity's full hierarchical key: the view-data-keys of the element and
## its ancestors, root first, joined with "__".
func full_key(el: UxmlElement) -> String:
	var keys: PackedStringArray = []
	var cur: UxmlElement = el
	while cur != null:
		var k = cur.get_attribute("view-data-key")
		if k != null and not String(k).is_empty():
			keys.append(String(k))
		cur = _doc._parents.get(cur)
	keys.reverse()
	return "__".join(keys)


## Record the live view state of the current tree into the store: the
## view_state() of each keyed control behavior (ScrollView and collection
## scroll offset and selection, TabView tab, TwoPaneSplitView pane size,
## column widths and sorting).
func capture_view_data() -> void:
	for el in _keyed:
		var b = _doc._behaviors.get(el)
		if b == null or not b.has_method("view_state"):
			continue
		var st: Dictionary = b.view_state()
		if not st.is_empty():
			_view_store[full_key(el)] = st


func get_view_data() -> Dictionary:
	capture_view_data()
	return _view_store.duplicate(true)


func set_view_data(data: Dictionary) -> void:
	_view_store = data.duplicate(true)
	restore_view_data()


## Push the stored view state onto the current tree. A scroll offset waits
## for a layout whose scroll range holds it (ScrollViewBehavior), until the
## user scrolls.
func restore_view_data() -> void:
	for el in _keyed:
		var key := full_key(el)
		if not _view_store.has(key):
			continue
		var entry = _view_store[key]
		if not entry is Dictionary:
			continue
		var b = _doc._behaviors.get(el)
		if b != null and b.has_method("restore_view_state"):
			b.restore_view_state(entry)


func _warn(el: UxmlElement, message: String) -> void:
	_doc._rt_warnings.append(UxmlDiagnostic.make("unsupported-value", message,
		_doc._doc.source, el.open_tag_start, _doc._doc.path))
