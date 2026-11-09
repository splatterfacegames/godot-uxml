class_name UxmlContainerBehaviors
extends RefCounted
## Behaviors of the container and collection controls (part trees in
## UxmlContainerParts): ScrollView, Scroller, ListView, TreeView,
## MultiColumnListView, MultiColumnTreeView, TabView, Tab,
## TwoPaneSplitView and IMGUIContainer.
##
## As every UxmlBehaviors.Behavior, these read input from the controls,
## write the model (attributes, inline styles, classes, pseudo-states) and
## let the incremental cascade and layout do the rest. Unity also changes
## these trees after a layout (Scroller visibility, dragger size, column
## widths, row positions): `after_layout()` runs after every layout of the
## document (UxmlDocument._after_layout).
##
## Scrolling follows Unity 6000.3: the scroll offset is a `translate` on
## #unity-content-container (paint-only, so a scroll restyles one element
## and skips the layout), and the Scroller draggers move by `translate`.

## The behavior for a container element, or null.
static func create(el: UxmlElement) -> UxmlBehaviors.Behavior:
	match el.local:
		"ScrollView":
			return ScrollViewBehavior.new()
		"Scroller":
			return ScrollerBehavior.new()
		"ListView", "TreeView", "MultiColumnListView", "MultiColumnTreeView":
			if el.part_of == null:
				return CollectionBehavior.new()
		"TabView":
			return TabViewBehavior.new()
		"Tab":
			return TabBehavior.new()
		"TwoPaneSplitView":
			return TwoPaneBehavior.new()
		"IMGUIContainer":
			return ImguiBehavior.new()
	return null


## Focus mode of a control and the base value the applier restores.
static func set_focus(c: Control, mode: int) -> void:
	if c == null:
		return
	c.focus_mode = mode
	c.set_meta("uxml_focus", mode)


static func set_mouse(c: Control, mode: int) -> void:
	if c == null:
		return
	c.mouse_filter = mode
	c.set_meta("uxml_mouse", mode)


# ---------------------------------------------------------------------------
# ScrollView
# ---------------------------------------------------------------------------

class ScrollViewBehavior extends UxmlBehaviors.Behavior:
	## The scroll offset changed (user input, script, view data).
	signal scrolled(offset: Vector2)

	var _vs: UxmlElement
	var _hs: UxmlElement
	var _vp: UxmlElement
	var _content: UxmlElement
	var _pending = null      # offset to apply once the range allows it
	var _touch := false      # a touch drag scrolls the content
	var _velocity := Vector2.ZERO  # px/s, of the touch drag and its inertia
	var _drag_t := 0             # ticks (usec) of the last drag event
	var _moving := false         # inertia or elastic spring-back runs
	var _last_sizes: Array = []  # sizes of the last after_layout update

	func setup() -> void:
		_vs = UxmlContainerParts.get_part(el, "vertical-scroller")
		_hs = UxmlContainerParts.get_part(el, "horizontal-scroller")
		_vp = UxmlContainerParts.get_part(el, "viewport")
		_content = UxmlContainerParts.get_part(el, "content")
		var c := control_of(el)
		if c != null:
			c.gui_input.connect(_on_input)
		for sc in [_vs, _hs]:
			var b = doc._behaviors.get(sc)
			if b != null:
				b.user_value.connect(_on_scroller.bind(sc == _vs))
		doc._post_layout.append(self)

	func native() -> Control:
		return doc._controls.get(el)

	## A changed attribute (mode, *-scroller-visibility) updates the
	## Scrollers after the next layout.
	func on_model_changed() -> void:
		_last_sizes = []

	func offset() -> Vector2:
		return UxmlContainerParts.scroll_offset(el)

	## Unity scrollOffset: clamped to the scroll range.
	func set_offset(off: Vector2) -> void:
		var before := offset()
		if UxmlContainerParts.set_scroll_offset(el, off):
			_sync_scrollers()
		if offset() != before:
			scrolled.emit(offset())

	## View data: keep the offset until a layout gives a range that holds it.
	func set_offset_pending(off: Vector2) -> void:
		_pending = off
		set_offset(off)

	func scroll_range() -> Vector2:
		return Vector2(maxf(0.0, _num(_hs, "high-value")), maxf(0.0, _num(_vs, "high-value")))

	func _num(sc: UxmlElement, n: String) -> float:
		if sc == null:
			return 0.0
		var v := UssValues.parse_number(UxmlParts._attr(sc, n, "0"))
		return 0.0 if is_nan(v) else v

	func _size_of(x: UxmlElement):
		var c: Control = doc._controls.get(x)
		return null if c == null else c.size

	func _rect_of(x: UxmlElement):
		var c: Control = doc._controls.get(x)
		return null if c == null or not c.visible else Rect2(c.position, c.size)

	## Unity contentContainer.boundingBox (the content and the children
	## that overflow it).
	func _bounds_of(x: UxmlElement):
		return UxmlContainerParts.bounding_size(x, _rect_of)

	func after_layout() -> void:
		var before := offset()
		# Scroller state depends only on the viewport, content and Scroller
		# sizes: skip the update when a layout left them unchanged (a scroll
		# that re-binds list rows lays out again).
		var key := [_size_of(_vp), _size_of(_content), _size_of(_vs), _size_of(_hs),
			_size_of(UxmlContainerParts.get_part(_vs, "drag-container")),
			_size_of(UxmlContainerParts.get_part(_hs, "drag-container"))]
		if key == _last_sizes and _pending == null:
			return
		_last_sizes = key
		# update_scroll_view also places the Scroller draggers.
		UxmlContainerParts.update_scroll_view(el, _size_of, _bounds_of)
		if _pending != null:
			var want: Vector2 = _pending
			UxmlContainerParts.set_scroll_offset(el, want)
			if offset().is_equal_approx(want):
				_pending = null
			_sync_scrollers()
		if offset() != before:
			scrolled.emit(offset())

	func _sync_scrollers() -> void:
		for sc in [_vs, _hs]:
			var b = doc._behaviors.get(sc)
			if b != null:
				b.refresh()

	## A Scroller moved by the user (buttons, track, dragger, keys).
	func _on_scroller(v: float, vertical: bool) -> void:
		_pending = null
		var off := offset()
		if vertical:
			off.y = v
		else:
			off.x = v
		set_offset(off)

	func _can_v() -> bool:
		return UxmlContainerParts.scroll_mode(el) != "horizontal" and scroll_range().y > 0.0

	func _can_h() -> bool:
		return UxmlContainerParts.scroll_mode(el) != "vertical" and scroll_range().x > 0.0

	## Unity ScrollView.OnScrollWheel: the event stops here when the offset
	## moved, or always with nested-interaction-kind="StopScrolling"; at a
	## bound it goes on to an outer ScrollView.
	func _on_input(ev: InputEvent) -> void:
		var mb := ev as InputEventMouseButton
		if mb != null and mb.pressed:
			var delta := Vector2.ZERO
			match mb.button_index:
				MOUSE_BUTTON_WHEEL_DOWN:
					delta.y = mb.factor if mb.factor > 0.0 else 1.0
				MOUSE_BUTTON_WHEEL_UP:
					delta.y = -(mb.factor if mb.factor > 0.0 else 1.0)
				MOUSE_BUTTON_WHEEL_RIGHT:
					delta.x = mb.factor if mb.factor > 0.0 else 1.0
				MOUSE_BUTTON_WHEEL_LEFT:
					delta.x = -(mb.factor if mb.factor > 0.0 else 1.0)
			if delta != Vector2.ZERO:
				wheel(delta)
				return
		var pg := ev as InputEventPanGesture
		if pg != null:
			wheel(pg.delta)
			return
		var st := ev as InputEventScreenTouch
		if st != null:
			_touch = st.pressed
			if st.pressed:
				_velocity = Vector2.ZERO
				_drag_t = Time.get_ticks_usec()
				_set_moving(false)
			else:
				release()
			return
		var sd := ev as InputEventScreenDrag
		if sd != null and _touch:
			touch_drag(sd.relative)
			native().accept_event()

	## One wheel event of `delta` units.
	func wheel(delta: Vector2) -> void:
		var can_v := _can_v()
		var can_h := _can_h()
		if not can_v and not can_h:
			return
		var before := offset()
		_pending = null
		set_offset(UxmlContainerParts.wheel_offset(el, delta, can_v, can_h))
		var stop := attr("nested-interaction-kind", "Default") == "StopScrolling"
		if stop or offset() != before:
			var c := native()
			if c != null and c.is_inside_tree():
				c.accept_event()

	## Touch scrolling (touch-scroll-type): Clamped keeps the offset in the
	## range, Elastic lets it go past by `elasticity` of the viewport and
	## springs back, Unrestricted does not clamp. The release keeps the
	## velocity, slowed by scroll-deceleration-rate per second.
	func touch_drag(rel: Vector2) -> void:
		var now := Time.get_ticks_usec()
		var dt := maxf(0.001, (now - _drag_t) / 1000000.0)
		_drag_t = now
		_velocity = _velocity.lerp(-rel / dt, 0.5)
		var off := offset() - rel
		var mode := attr("touch-scroll-type", "Clamped")
		var r := scroll_range()
		_pending = null
		if mode == "Unrestricted":
			UxmlContainerParts.set_scroll_offset(el, off, false)
			_sync_scrollers()
			scrolled.emit(offset())
			return
		if mode == "Elastic":
			var vsz = _size_of(_vp)
			var e := UssValues.parse_number(attr("elasticity", "0.1"))
			var m: Vector2 = (vsz if vsz != null else Vector2.ZERO) * (0.1 if is_nan(e) else e)
			off = Vector2(clampf(off.x, -m.x, r.x + m.x), clampf(off.y, -m.y, r.y + m.y))
			UxmlContainerParts.set_scroll_offset(el, off, false)
			_sync_scrollers()
			scrolled.emit(offset())
			return
		set_offset(off)

	## The end of a touch drag: the content keeps the drag velocity, slowed
	## by scroll-deceleration-rate (the part of the velocity kept after one
	## second, Unity's default 0.135); an Elastic view springs back into its
	## range in `elasticity` seconds.
	func release() -> void:
		var rate := UssValues.parse_number(attr("scroll-deceleration-rate", "0.135"))
		if is_nan(rate) or rate <= 0.0:
			_velocity = Vector2.ZERO
		_set_moving(true)

	func _set_moving(on: bool) -> void:
		var tree: SceneTree = doc.get_tree() if doc.is_inside_tree() else null
		if tree == null or _moving == on:
			_moving = on and tree != null
			return
		_moving = on
		if on:
			tree.process_frame.connect(_on_frame)
		else:
			tree.process_frame.disconnect(_on_frame)

	func _on_frame() -> void:
		step_inertia(doc.get_process_delta_time() if doc.get_process_delta_time() > 0.0 else 1.0 / 60.0)

	## One frame of inertia and spring-back (also called by tests).
	func step_inertia(dt: float) -> void:
		var rate := UssValues.parse_number(attr("scroll-deceleration-rate", "0.135"))
		if is_nan(rate) or rate < 0.0:
			rate = 0.135
		var mode := attr("touch-scroll-type", "Clamped")
		var r := scroll_range()
		var off := offset() + _velocity * dt
		_velocity *= pow(rate, dt)
		var inside := off.clamp(Vector2.ZERO, r)
		if mode == "Elastic" and inside != off:
			var e := UssValues.parse_number(attr("elasticity", "0.1"))
			var k := clampf(dt / maxf(0.01, 0.1 if is_nan(e) else e), 0.0, 1.0)
			off = off.lerp(inside, k)
			_velocity *= 0.5
		elif mode != "Unrestricted":
			if inside.x != off.x:
				_velocity.x = 0.0
			if inside.y != off.y:
				_velocity.y = 0.0
			off = inside
		UxmlContainerParts.set_scroll_offset(el, off, false)
		_sync_scrollers()
		scrolled.emit(offset())
		if _velocity.length() < 1.0 and (mode == "Unrestricted" or off.distance_to(off.clamp(Vector2.ZERO, r)) < 0.5):
			_velocity = Vector2.ZERO
			if mode == "Elastic":
				UxmlContainerParts.set_scroll_offset(el, off.clamp(Vector2.ZERO, r), false)
				_sync_scrollers()
			_set_moving(false)

	## Keyboard and controller: a focused ScrollView (focusable="true")
	## scrolls one wheel line per arrow and one viewport per page key.
	func key_scroll(ev: InputEvent) -> bool:
		var vsz = _size_of(_vp)
		var page: Vector2 = vsz if vsz != null else Vector2.ZERO
		var off := offset()
		var line := UxmlContainerParts.WHEEL_LINE
		if el.has_attribute("mouse-wheel-scroll-size"):
			line = UssValues.parse_number(attr("mouse-wheel-scroll-size"))
		if ev.is_action_pressed("ui_down"):
			off.y += line
		elif ev.is_action_pressed("ui_up"):
			off.y -= line
		elif ev.is_action_pressed("ui_page_down"):
			off.y += page.y
		elif ev.is_action_pressed("ui_page_up"):
			off.y -= page.y
		elif ev.is_action_pressed("ui_right") and _can_h():
			off.x += line
		elif ev.is_action_pressed("ui_left") and _can_h():
			off.x -= line
		else:
			return false
		if off.clamp(Vector2.ZERO, scroll_range()) == offset():
			return false  # at the bound: navigation goes on
		_pending = null
		set_offset(off)
		return true

	## Unity ScrollView.ScrollTo: the smallest scroll that shows `child`.
	func scroll_to(child: Control) -> void:
		var vpc: Control = doc._controls.get(_vp)
		var cc: Control = doc._controls.get(_content)
		if vpc == null or cc == null or child == null or not cc.is_ancestor_of(child):
			return
		var r := Rect2(cc.get_global_transform().affine_inverse() * child.global_position, child.size)
		var off := offset()
		var view := vpc.size
		if r.position.y < off.y:
			off.y = r.position.y
		elif r.end.y > off.y + view.y:
			off.y = minf(r.position.y, r.end.y - view.y)
		if r.position.x < off.x:
			off.x = r.position.x
		elif r.end.x > off.x + view.x:
			off.x = minf(r.position.x, r.end.x - view.x)
		_pending = null
		set_offset(off)

	func view_state() -> Dictionary:
		return {"scroll_offset": _pending if _pending != null else offset()}

	func restore_view_state(d: Dictionary) -> void:
		var off = d.get("scroll_offset")
		if off is Vector2:
			set_offset_pending(off)


# ---------------------------------------------------------------------------
# Scroller
# ---------------------------------------------------------------------------

## Scroller: the low/high RepeatButtons step by the page size, a press on
## the track pages toward the pointer (repeating while held), the dragger
## follows the pointer, and the focused slider takes arrow, page, Home and
## End keys (controller d-pad through ui_*).
class ScrollerBehavior extends UxmlBehaviors.Behavior:
	## The value changed by user input.
	signal user_value(value: float)

	var _drag: UxmlElement
	var _dragger: UxmlElement
	var _slider: UxmlElement
	var _grab := -1.0          # pointer offset inside the dragger while dragging
	var _page_dir := 0.0
	var _timer: Timer = null

	func setup() -> void:
		_drag = UxmlContainerParts.get_part(el, "drag-container")
		_dragger = UxmlContainerParts.get_part(el, "dragger")
		_slider = UxmlContainerParts.get_part(el, "slider")
		for role in ["low-button", "high-button"]:
			var b := control_of(UxmlContainerParts.get_part(el, role)) as BaseButton
			if b != null:
				(b as UxmlRepeatButton).configure(250.0, 30.0)
				b.pressed.connect(step.bind(-1.0 if role == "low-button" else 1.0))
				UxmlContainerBehaviors.set_focus(b, Control.FOCUS_NONE)
		var dc := control_of(_drag)
		if dc != null:
			UxmlContainerBehaviors.set_mouse(dc, Control.MOUSE_FILTER_STOP)
			dc.gui_input.connect(_on_track_input)
		var sc := control_of(_slider)
		if sc != null:
			# Unity: the ScrollerSlider is focusable; it takes the keys.
			UxmlContainerBehaviors.set_focus(sc, Control.FOCUS_ALL)
			sc.gui_input.connect(_on_key)
			sc.focus_entered.connect(set_state.bind(_slider, "focus", true))
			sc.focus_exited.connect(set_state.bind(_slider, "focus", false))
		if el.part_of == null:
			doc._post_layout.append(self)

	func native() -> Control:
		return doc._controls.get(el)

	func value() -> float:
		return _n("value", 0.0)

	func _n(n: String, d: float) -> float:
		var v := UssValues.parse_number(attr(n, str(d)))
		return d if is_nan(v) else v

	func _lo() -> float:
		return _n("low-value", 0.0)

	func _hi() -> float:
		return _n("high-value", 0.0)

	## Unity Slider.pageSize: `*-page-size` of the owning ScrollView, else a
	## tenth of the dragger (Unity's k_ScrollPageOverlapFactor), else 20.
	func page() -> float:
		var owner := el.part_of
		if owner != null and owner.local == "ScrollView":
			var vertical := UxmlContainerParts.scroller_direction(el) == "vertical"
			var p := UssValues.parse_number(UxmlParts._attr(owner,
				"vertical-page-size" if vertical else "horizontal-page-size", "-1"))
			if not is_nan(p) and p >= 0.0:
				return p
			var g := control_of(_dragger)
			if g != null:
				return maxf(1.0, (g.size.y if vertical else g.size.x) * 0.1)
		return 20.0

	## Set the value (clamped to the range) from user input.
	func set_value_user(v: float) -> void:
		var lo := minf(_lo(), _hi())
		var hi := maxf(_lo(), _hi())
		v = clampf(v, lo, hi)
		if is_equal_approx(v, value()):
			return
		el.set_attribute("value", UxmlContainerParts._num_text(v))
		refresh()
		user_value.emit(v)
		if el.part_of == null:
			doc.value_changed.emit(element_name(), v)
			ui_changed.emit()

	func step(dir: float) -> void:
		var sign := 1.0 if _lo() <= _hi() else -1.0
		set_value_user(value() + dir * sign * page())

	func refresh() -> void:
		UxmlContainerParts.update_scroller(el, _size_of)

	func on_model_changed() -> void:
		refresh()

	func after_layout() -> void:
		refresh()

	func _size_of(x: UxmlElement):
		var c: Control = doc._controls.get(x)
		return null if c == null else c.size

	func _axis() -> int:
		return 0 if UxmlContainerParts.scroller_direction(el) == "horizontal" else 1

	func _on_track_input(ev: InputEvent) -> void:
		var dc := control_of(_drag)
		var gc := control_of(_dragger)
		if dc == null or gc == null:
			return
		var mb := ev as InputEventMouseButton
		var a := _axis()
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var p: float = mb.position[a]
				var g0 := _dragger_pos()
				var gs: float = gc.size[a]
				if gc.visible and p >= g0 and p <= g0 + gs:
					_grab = p - g0
				else:
					_page_dir = -1.0 if p < g0 else 1.0
					step(_page_dir)
					_start_repeat()
				set_state(el, "active", true)
			else:
				_grab = -1.0
				_page_dir = 0.0
				if _timer != null:
					_timer.stop()
				set_state(el, "active", false)
			dc.accept_event()
			return
		var mm := ev as InputEventMouseMotion
		if mm != null and _grab >= 0.0:
			var track: float = dc.size[a] - gc.size[a]
			if track > 0.0:
				var t := clampf((mm.position[a] - _grab) / track, 0.0, 1.0)
				set_value_user(_lo() + t * (_hi() - _lo()))
			dc.accept_event()

	## The dragger's offset along the track (its translate).
	func _dragger_pos() -> float:
		var gc := control_of(_dragger)
		if gc == null:
			return 0.0
		return gc.position[_axis()] + gc.offset_transform_position[_axis()]

	func _start_repeat() -> void:
		if _timer == null:
			_timer = Timer.new()
			_timer.one_shot = true
			_timer.timeout.connect(_on_repeat)
			var c := control_of(_drag)
			if c != null:
				c.add_child(_timer, false, Node.INTERNAL_MODE_BACK)
		if _timer.is_inside_tree():
			_timer.start(0.25)

	func _on_repeat() -> void:
		if _page_dir == 0.0:
			return
		step(_page_dir)
		_timer.start(0.03)

	func _on_key(ev: InputEvent) -> void:
		var vertical := _axis() == 1
		var dir := 0.0
		if ev.is_action_pressed("ui_down" if vertical else "ui_right"):
			dir = 1.0
		elif ev.is_action_pressed("ui_up" if vertical else "ui_left"):
			dir = -1.0
		elif ev.is_action_pressed("ui_page_down"):
			set_value_user(value() + (_hi() - _lo()) * 0.1)
		elif ev.is_action_pressed("ui_page_up"):
			set_value_user(value() - (_hi() - _lo()) * 0.1)
		elif ev is InputEventKey and ev.pressed and (ev as InputEventKey).keycode == KEY_HOME:
			set_value_user(_lo())
		elif ev is InputEventKey and ev.pressed and (ev as InputEventKey).keycode == KEY_END:
			set_value_user(_hi())
		else:
			return
		if dir != 0.0:
			step(dir)
		control_of(_slider).accept_event()

	func bind_write(prop: String, v: Variant) -> int:
		match prop:
			"value", "low-value", "high-value":
				return write_attr(prop, UxmlContainerParts._num_text(UxmlBinding._num(v)))
		return UNHANDLED

	func bind_read(prop: String) -> Array:
		if prop == "value":
			return [true, value()]
		return [false, null]


# ---------------------------------------------------------------------------
# Collection views
# ---------------------------------------------------------------------------

## ListView, TreeView, MultiColumnListView, MultiColumnTreeView: fixed
## height virtualization over the pooled rows, selection (mouse, keyboard,
## controller), item activation, the add/remove footer, the size field,
## reordering, tree expansion, column sorting and resizing.
class CollectionBehavior extends UxmlBehaviors.Behavior:
	var _rows: Array = []          # UxmlListRow per pool slot
	var _row_ctl: Array = []       # row Control per pool slot
	var _base := PackedFloat64Array()  # y of each slot's Control at the last layout
	var _sv: UxmlElement
	var _content: UxmlElement
	var _info: Dictionary          # doc._lists[el]: {rows, h, count, bind, first}
	var _selection: Array = []     # selected item indices, in selection order
	var _anchor := -1              # shift-selection anchor
	var _items = null              # bound collection (itemsSource), or null
	# Trees: roots, open ids, the flattened visible items.
	var _roots: Array = []
	var _expanded: Dictionary = {}
	var _flat: Array = []
	# Multi-column: column -> Callable(cell: Control, index) and comparisons.
	var _cell_binds: Dictionary = {}
	var _comparisons: Dictionary = {}
	var _sort: Array = []          # [{column, direction}]
	# Reordering.
	var _drag_from := -1
	var _drag_start := Vector2.ZERO
	var _dragging := false
	var _defer_click := -1         # a press on a multiple selection selects on release
	var _dnd_cb: Dictionary = {}   # set_drag_and_drop callbacks
	var _pending_sel = null        # a bound selection that waits for items
	var _resize_col := -1
	var _resize_x := 0.0
	var _resize_w := 0.0
	# Rows in use: Unity's floor(viewport / item height) + 2 (FixedHeight)
	# or ceil(viewport / expected height) + 2 (DynamicHeight); the other
	# pooled rows stay hidden and unbound.
	var _active := 0
	# virtualization-method="DynamicHeight": measured item heights, the
	# smallest measured height (Unity's m_MinimumItemHeight).
	var _dynamic := false
	var _heights: Dictionary = {}
	var _min_h := -1.0
	var _scroll_target := -1   # scroll_to_item waits for measured heights

	func setup() -> void:
		_sv = UxmlContainerParts.get_part(el, "scroll-view")
		_content = UxmlContainerParts.get_part(_sv, "content") if _sv != null else null
		var h := UxmlContainerParts.item_height(el)
		var tree := UxmlContainerParts.is_tree(el)
		for row in UxmlContainerParts.rows_of(el):
			var r := UxmlListRow.new(doc, row)
			_rows.append(r)
			# Rows are parts: the factory already lets them pass the mouse.
			var c := control_of(row)
			_row_ctl.append(c)
			_base.append(0.0)
			# A row of a fixed height lays out alone (UxmlDocument._local_root).
			doc._layout_roots[row] = true
			if c != null:
				c.gui_input.connect(_on_row_input.bind(r))
			if not tree:
				continue
			for x in row.walk():
				if x.part_role == "item-toggle":
					var t := control_of(x) as UxmlToggle
					if t != null:
						UxmlContainerBehaviors.set_focus(t, Control.FOCUS_NONE)
						t.toggled.connect(_on_toggle.bind(r))
		_info = {"rows": _rows, "h": h, "count": 0, "bind": Callable(), "first": 0}
		_dynamic = UxmlContainerParts.is_dynamic(el)
		_active = _rows.size()
		doc._lists[el] = _info
		_selection = []
		for s in _initial_sort():
			_sort.append(s)
		var cc := control_of(_content)
		if cc != null:
			# Unity: the scroll view's content container takes the focus.
			UxmlContainerBehaviors.set_focus(cc, Control.FOCUS_ALL)
			cc.gui_input.connect(_on_key)
			cc.focus_entered.connect(set_state.bind(_content, "focus", true))
			cc.focus_exited.connect(set_state.bind(_content, "focus", false))
		var svb = doc._behaviors.get(_sv)
		if svb != null:
			svb.scrolled.connect(func(_o): refresh(false))
		for role in ["add-button", "remove-button"]:
			var b := control_of(UxmlContainerParts.get_part(el, role)) as BaseButton
			if b != null:
				b.pressed.connect(_on_add if role == "add-button" else _on_remove)
		var sf := UxmlContainerParts.get_part(el, "size-field")
		if sf != null:
			var le := doc._natives.get(sf) as LineEdit
			if le != null:
				le.text_submitted.connect(_on_size_submitted)
		for x in el.walk():
			if x.part_of != el:
				continue
			if x.part_role == "header-column":
				var hc := control_of(x)
				if hc != null:
					hc.gui_input.connect(_on_header_input.bind(int(x.get_meta(&"uxml_column"))))
			elif x.part_role == "resize-drag-area":
				var ra := control_of(x)
				if ra != null:
					UxmlContainerBehaviors.set_mouse(ra, Control.MOUSE_FILTER_STOP)
					ra.mouse_default_cursor_shape = Control.CURSOR_HSIZE
					ra.gui_input.connect(_on_resize_input.bind(_handle_column(x)))
		doc._post_layout.append(self)
		_update_size_field()

	func _handle_column(area: UxmlElement) -> int:
		var p = doc._parent_el(area)
		return -1 if p == null else int(p.get_meta(&"uxml_column", -1))

	func _initial_sort() -> Array:
		var out: Array = []
		var cols := UxmlContainerParts.columns_of(el)
		for s in el.get_meta(UxmlContainerParts.META_SORT, []):
			var ci: int = s["column_index"]
			if ci < 0:
				for c in cols:
					if c["name"] == s["column_name"]:
						ci = c["index"]
			if ci >= 0:
				out.append({"column": ci, "direction": s["direction"]})
		return out

	func native() -> Control:
		return doc._controls.get(el)

	func count() -> int:
		return int(_info["count"])

	func item_height() -> float:
		return float(_info["h"])

	## The rows in use (get_list_rows).
	func active_rows() -> Array:
		return _rows.slice(0, _active)

	# ---- DynamicHeight ----------------------------------------------------

	## Unity's defaultExpectedHeight: the smallest measured item height when
	## it is below fixed-item-height, else fixed-item-height (22 without).
	func expected_height() -> float:
		return _min_h if _min_h > 0.0 else item_height()

	## Height of item `i`: measured, else expected (DynamicHeight).
	func height_of(i: int) -> float:
		if not _dynamic:
			return item_height()
		return float(_heights.get(i, expected_height()))

	## Content offset of the top of item `i`.
	func item_top(i: int) -> float:
		if not _dynamic:
			return i * item_height()
		var exp_h := expected_height()
		var out := i * exp_h
		for k in _heights:
			if int(k) < i:
				out += float(_heights[k]) - exp_h
		return out

	## Unity GetExpectedContentHeight.
	func content_extent() -> float:
		return item_top(count())

	## The item at content offset `y` (clamped to the items).
	func index_at(y: float) -> int:
		var n := count()
		if n == 0:
			return 0
		if not _dynamic:
			return clampi(int(floor(y / item_height())), 0, n - 1)
		var top := 0.0
		for i in n:
			var hh := height_of(i)
			if top + hh > y:
				return i
			top += hh
		return n - 1

	## Rows Unity keeps for the current viewport (all rows before a layout).
	func _rows_for_viewport() -> int:
		var vh := _viewport_h()
		if vh <= 0.0:
			return _rows.size()
		var want: int
		if _dynamic:
			want = int(ceil(vh / expected_height())) + 2
		else:
			want = int(floor(vh / item_height())) + 2
		return clampi(want, 1, _rows.size())

	# ---- data ---------------------------------------------------------

	## set_list_source: `n` items, `bind.call(row: UxmlListRow, index)`.
	func set_source(n: int, bind: Callable) -> void:
		_forget_heights()
		_info["count"] = maxi(0, n)
		_info["bind"] = bind
		_clamp_selection()
		refresh(true)
		_update_size_field()
		_apply_pending_selection()

	## A selection written (binding, view data) before the items existed.
	func _apply_pending_selection() -> void:
		if _pending_sel == null:
			return
		var want: Array = _pending_sel
		for i in want:
			if int(i) >= count():
				return
		_pending_sel = null
		set_selection(want, false)

	## Tree data: roots are Dictionaries {id, data, children}.
	func set_tree(roots: Array, bind: Callable) -> void:
		_roots = roots
		if UxmlParts._bool(el, "auto-expand", false):
			_expanded = UxmlContainerParts.tree_ids(roots)
		_reflatten()
		set_source(_flat.size(), bind)

	func _reflatten() -> void:
		_flat = UxmlContainerParts.flatten_tree(_roots, _expanded)
		_info["count"] = _flat.size()

	## The tree item at a visible index: {id, data, depth, children,
	## expanded, item}.
	func tree_item(index: int) -> Dictionary:
		return _flat[index] if index >= 0 and index < _flat.size() else {}

	func set_expanded(id: Variant, on: bool, all_children: bool = false) -> void:
		var ids := {}
		ids[id] = true
		if all_children:
			var sub := _find_item(_roots, id)
			if not sub.is_empty():
				UxmlContainerParts.tree_ids(sub.get("children", []), ids)
		var changed := false
		for k in ids:
			if on and not _expanded.has(k):
				_expanded[k] = true
				changed = true
			elif not on and _expanded.has(k):
				_expanded.erase(k)
				changed = true
		if not changed:
			return
		var sel_ids: Array = []
		for i in _selection:
			sel_ids.append(tree_item(i).get("id"))
		_reflatten()
		_selection = []
		for k in _flat.size():
			if sel_ids.has(_flat[k]["id"]):
				_selection.append(k)
		refresh(true)
		doc.item_expanded_changed.emit(element_name(), id, on)

	func _find_item(items: Array, id: Variant) -> Dictionary:
		for it in items:
			if it is Dictionary:
				if it.get("id") == id:
					return it
				var r := _find_item(it.get("children", []), id)
				if not r.is_empty():
					return r
		return {}

	## The bound itemsSource (data binding or set_items_source).
	func set_items(items: Variant) -> void:
		_items = items

	func refresh(rebind_all: bool) -> void:
		_active = _rows_for_viewport()
		var pool := _active
		var n := count()
		var h := item_height()
		var off := Vector2.ZERO
		var svb = doc._behaviors.get(_sv)
		if svb != null:
			off = svb.offset()
		var first: int
		if _dynamic:
			first = clampi(index_at(off.y), 0, maxi(0, n - pool))
		else:
			first = clampi(int(floor(off.y / h)), 0, maxi(0, n - pool))
		_info["first"] = first
		var bind: Callable = _info["bind"]
		var rebound: Array = []
		if _dynamic:
			# Rows lay out in item order below a padding as tall as the items
			# above the first row (Unity's contentPadding); the content is
			# as tall as the expected content height.
			UxmlContainerParts.content_extent(el, content_extent() if n > 0 else -1.0, item_top(first))
		else:
			UxmlContainerParts.content_height(el, n)
		for k in _rows.size():
			var row: UxmlListRow = _rows[k]
			if k >= pool:
				if row.index != -1:
					row.index = -1
					UxmlContainerParts.bind_row(el, row.element, -1, false)
					rebound.append(row.element)
				continue
			var idx := (first + k) if _dynamic else (first + posmod(k - first, pool))
			if idx >= n:
				if row.index != -1:
					row.index = -1
					UxmlContainerParts.bind_row(el, row.element, -1, false)
				continue
			if row.index != idx or rebind_all:
				row.index = idx
				UxmlContainerParts.bind_row(el, row.element, idx, _selection.has(idx),
					_flat[idx] if idx < _flat.size() else {})
				_set_row_states(row)
				_bind_row(row, idx, bind)
				rebound.append(row.element)
		if not rebound.is_empty():
			# Unity binds a row without a layout of the panel: a row of a fixed
			# height lays out alone, else the document lays out.
			doc._layout_rows(rebound)
		_place()

	func _bind_row(row: UxmlListRow, idx: int, bind: Callable) -> void:
		# Unity's default bindItem first (the item text in a Label); a bind
		# callable (data binding's AutoAssign, set_list_source) runs after.
		if _items != null and idx < (_items as Variant).size():
			_default_bind(row, idx)
		if bind.is_valid():
			bind.call(row, idx)
		elif _items == null and not _flat.is_empty():
			UxmlContainerParts.bind_text(row.element, str(_flat[idx]["data"]))
			_text_controls(row)
		if not _cell_binds.is_empty():
			for x in row.element.walk():
				if x.part_role == "cell":
					var ci := int(x.get_meta(&"uxml_column"))
					var cb: Callable = _cell_binds.get(ci, Callable())
					if cb.is_valid() and not x.children.is_empty():
						cb.call(control_of(x.children[0]), idx)

	## Unity's default bindItem: the item's ToString in the Label.
	func _default_bind(row: UxmlListRow, idx: int) -> void:
		var item = _items[idx]
		if row.element.local == "Label" or UxmlContainerParts.item_of(row.element).local == "Label" \
				or UxmlContainerParts.is_multi_column(el):
			UxmlContainerParts.bind_text(row.element, UxmlBinding._str(item))
			_text_controls(row)

	func _text_controls(row: UxmlListRow) -> void:
		for x in row.element.walk():
			if x.local == "Label":
				var c := control_of(x)
				if c != null and c.get("text") != UxmlParts._attr(x, "text"):
					doc._set_control_text(c, UxmlParts._attr(x, "text"))

	func _set_row_states(row: UxmlListRow) -> void:
		var sel := row.index >= 0 and _selection.has(row.index)
		# Unity 6000.3 marks a selected item :checked; :selected is Unity's
		# alias of :checked.
		set_state(row.element, "checked", sel)
		set_state(row.element, "selected", sel)
		if not UxmlContainerParts.is_tree(el):
			return
		for x in row.element.walk():
			if x.part_role == "item-toggle":
				var t := control_of(x) as UxmlToggle
				var open := row.index >= 0 and row.index < _flat.size() and bool(_flat[row.index]["expanded"])
				if t != null and t.button_pressed != open:
					t.set_pressed_no_signal(open)
				set_state(x, "checked", open)
				set_state(UxmlContainerParts.get_part(x, "input"), "checked", open)

	## Slot k is laid out at k * h; the control moves to its item's place.
	## DynamicHeight rows lay out in item order (no move).
	func _place() -> void:
		if _dynamic:
			return
		var h := item_height()
		for k in _rows.size():
			var c: Control = _row_ctl[k]
			if c == null:
				continue
			var idx: int = (_rows[k] as UxmlListRow).index
			var want := 0 if idx < 0 else idx - k
			var y: float = _base[k] + want * h
			if c.position.y != y:
				c.position.y = y

	## A placement without a layout (a paint-only restyle, a layout of rows
	## alone) put the placed rows back at their slots.
	func place_rows() -> void:
		_place()

	func after_layout() -> void:
		# A layout put every row back at its slot.
		for k in _rows.size():
			var c: Control = _row_ctl[k]
			if c != null:
				_base[k] = c.position.y
		_place()
		if _dynamic and (_measure_rows() or _follow_target()):
			return
		if _rows_for_viewport() != _active:
			# The viewport changed: Unity's Resize adds or releases rows.
			refresh(false)
			return
		if UxmlContainerParts.is_multi_column(el):
			var hc := control_of(UxmlContainerParts.get_part(el, "header"))
			if hc != null:
				UxmlContainerParts.update_columns(el, hc.size.x)

	## DynamicHeight: register the laid-out height of each bound row
	## (Unity UpdateRegisteredHeight). When a height changes, the content
	## height and the padding follow, and the scroll offset moves so that
	## the first visible item stays where it is on screen. Returns true when
	## it changed the model.
	func _measure_rows() -> bool:
		var svb = doc._behaviors.get(_sv)
		var off: Vector2 = Vector2.ZERO if svb == null else svb.offset()
		var anchor := index_at(off.y)
		var anchor_delta := off.y - item_top(anchor)
		var changed := false
		for k in _active:
			var row: UxmlListRow = _rows[k]
			var c: Control = _row_ctl[k]
			if row.index < 0 or c == null or not c.visible:
				continue
			var hh := c.size.y
			if hh <= 0.0:
				continue
			if hh < expected_height() and not is_equal_approx(hh, _min_h):
				_min_h = hh
				changed = true
			var old = _heights.get(row.index)
			if old == null or not is_equal_approx(float(old), hh):
				_heights[row.index] = hh
				changed = true
		if not changed:
			return false
		if svb != null and anchor > 0:
			var want := Vector2(off.x, item_top(anchor) + anchor_delta)
			if not want.is_equal_approx(off):
				svb.set_offset_pending(want)
		refresh(false)
		return true

	## DynamicHeight scroll_to_item: the target offset uses expected heights
	## until the rows around the item are measured; the scroll follows the
	## measured heights until it holds (Unity schedules ScrollToItem again
	## after the layout). Returns true when it changed the model.
	func _follow_target() -> bool:
		if _scroll_target < 0:
			return false
		var i := _scroll_target
		var svb = doc._behaviors.get(_sv)
		if svb == null or i >= count():
			_scroll_target = -1
			return false
		var off: Vector2 = svb.offset()
		var want := _offset_showing(i, off)
		if want.is_equal_approx(off):
			_scroll_target = -1
			return false
		svb.set_offset_pending(want)
		refresh(false)
		return true

	## The smallest scroll from `off` that shows item `i`.
	func _offset_showing(i: int, off: Vector2) -> Vector2:
		var top := item_top(i)
		var bottom := top + height_of(i)
		var vh := _viewport_h()
		if top < off.y:
			off.y = top
		elif bottom > off.y + vh:
			off.y = bottom - vh
		return off

	## Item heights change with the items: a new source forgets them.
	func _forget_heights() -> void:
		_heights.clear()
		_min_h = -1.0

	# ---- selection -------------------------------------------------------

	func selection_mode() -> String:
		return attr("selection-type", "Single")

	func selected() -> Array:
		return _selection.duplicate()

	## Unity SetSelection; emits selection_changed when it changed.
	func set_selection(indices: Array, notify: bool = true) -> void:
		var mode := selection_mode()
		var want: Array = []
		if mode != "None":
			for i in indices:
				var k := int(i)
				if k >= 0 and k < count() and not want.has(k):
					want.append(k)
			if mode == "Single" and want.size() > 1:
				want = [want[-1]]
		if want == _selection:
			return
		_selection = want
		for row in _rows:
			if (row as UxmlListRow).index >= 0:
				UxmlContainerParts.bind_row(el, row.element, row.index, _selection.has(row.index),
					_flat[row.index] if row.index < _flat.size() else {})
				_set_row_states(row)
		if notify:
			doc.selection_changed.emit(element_name(), selected())
			ui_changed.emit()

	func _clamp_selection() -> void:
		var keep: Array = []
		for i in _selection:
			if i < count():
				keep.append(i)
		_selection = keep

	func _on_row_input(ev: InputEvent, row: UxmlListRow) -> void:
		var mb := ev as InputEventMouseButton
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed and row.index >= 0:
				var cc := control_of(_content)
				if cc != null and cc.focus_mode != Control.FOCUS_NONE:
					cc.grab_focus()
				var ctrl := mb.ctrl_pressed or mb.meta_pressed
				# Unity: a plain press on an item of a multiple selection
				# keeps the selection until the release, so that the drag
				# takes every selected item.
				if _selection.size() > 1 and _selection.has(row.index) and not mb.shift_pressed \
						and not ctrl and _can_try_drag():
					_defer_click = row.index
				else:
					_defer_click = -1
					_click_select(row.index, mb.shift_pressed, ctrl)
				if mb.double_click:
					doc.items_chosen.emit(element_name(), [row.index])
				_drag_from = row.index
				_drag_start = mb.global_position
				_dragging = false
			elif not mb.pressed:
				if _dragging:
					doc._dnd_finish(self, mb.global_position, mb.canceled)
				elif _defer_click >= 0 and not mb.canceled:
					_click_select(_defer_click, false, false)
				drag_reset()
			return
		var mm := ev as InputEventMouseMotion
		if mm == null or _drag_from < 0 or (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			return
		if _dragging:
			doc._dnd_update(mm.global_position)
		elif mm.global_position.distance_to(_drag_start) > DRAG_START_DISTANCE and _can_try_drag():
			if doc._dnd_begin(self, _drag_from, mm.global_position):
				_dragging = true
				_defer_click = -1
			else:
				_drag_from = -1  # asked once per press, as Unity

	## Move item `from` to index `to` (reorderable): the bound Array moves
	## its element; item_index_changed tells the game.
	func move_item(from: int, to: int) -> void:
		if from < 0 or to < 0 or from == to or from >= count() or to >= count():
			return
		var was := _selection.has(from)
		_move_one(from, to)
		if was:
			set_selection([to], false)
		refresh(true)

	func _move_one(from: int, to: int) -> void:
		if _items is Array:
			var it = (_items as Array)[from]
			(_items as Array).remove_at(from)
			(_items as Array).insert(to, it)
		doc.item_index_changed.emit(element_name(), from, to)

	# ---- drag and drop (UxmlDocument.set_drag_and_drop) -------------------

	## Unity ListViewDragger: the pointer moves this far before a drag
	## starts; the edge bands of an item that drop between items; the edge
	## bands of the viewport that scroll it, and by how much.
	const DRAG_START_DISTANCE := 5.0
	const BETWEEN_ITEMS_BAND := 5.0
	const AUTO_SCROLL_BAND := 5.0
	const AUTO_SCROLL_STEP := 20.0

	func set_drag_callbacks(callbacks: Dictionary) -> void:
		_dnd_cb = callbacks.duplicate()

	func drag_callback(key: String) -> Callable:
		return _dnd_cb.get(key, Callable())

	func _reorderable() -> bool:
		return UxmlParts._bool(el, "reorderable", false)

	## A drag can start: can_start_drag decides, else `reorderable`.
	func _can_try_drag() -> bool:
		return _dnd_cb.has("can_start_drag") or _reorderable()

	## The press ended or the document ended the drag.
	func drag_reset() -> void:
		_drag_from = -1
		_dragging = false
		_defer_click = -1

	## The item id of visible index `i` (a tree item's id, else the index).
	func item_id(i: int) -> Variant:
		if UxmlContainerParts.is_tree(el):
			return _flat[i]["id"] if i >= 0 and i < _flat.size() else null
		return i

	## The items a drag from item `i` takes: the selection (in item order)
	## when `i` is selected, else `i`.
	func drag_indices(i: int) -> Array:
		if not _selection.has(i):
			return [i]
		var out := _selection.duplicate()
		out.sort()
		return out

	## Unity canStartDrag (or the reorderable default).
	func can_start_drag(args: Dictionary) -> bool:
		var cb := drag_callback("can_start_drag")
		if cb.is_valid():
			return bool(cb.call(args))
		return _reorderable()

	func viewport_control() -> Control:
		return control_of(UxmlContainerParts.get_part(_sv, "viewport")) if _sv != null else null

	static func _holds(c: Control, gp: Vector2) -> bool:
		return Rect2(Vector2.ZERO, c.size).has_point(c.get_global_transform().affine_inverse() * gp)

	## The bound, drawn row whose box holds the global point `gp` inside
	## the viewport, or null.
	func row_at(gp: Vector2) -> UxmlListRow:
		var vp := viewport_control()
		if vp != null and (not vp.is_visible_in_tree() or not _holds(vp, gp)):
			return null
		for k in _active:
			var row: UxmlListRow = _rows[k]
			var c: Control = _row_ctl[k]
			if row.index >= 0 and c != null and c.is_visible_in_tree() and _holds(c, gp):
				return row
		return null

	## The row bound to item `i`, drawn, or null.
	func row_of(i: int) -> UxmlListRow:
		if i < 0:
			return null
		for k in _active:
			var row: UxmlListRow = _rows[k]
			var c: Control = _row_ctl[k]
			if row.index == i and c != null and c.is_visible_in_tree():
				return row
		return null

	## The global bounding box of the row of item `i`, or Rect2().
	func item_rect(i: int) -> Rect2:
		var row := row_of(i)
		if row == null:
			return Rect2()
		var c: Control = control_of(row.element)
		return UxmlDocument.xform_rect(c.get_global_transform(), Rect2(Vector2.ZERO, c.size))

	## Unity HandleDragAndDropArgs for the global point `gp` (Unity
	## ListViewDragger.TryGetDragPosition): the edge bands of an item drop
	## between items, the rest drops over the item; outside the items the
	## drop goes to the end (or the start, above the viewport). A tree
	## gives the parent id (null: the roots) and the child index (-1: the
	## end) of the drop.
	func drop_args(gp: Vector2) -> Dictionary:
		var n := count()
		var out := {"element_name": element_name(), "element": el, "position": gp, "index": -1,
			"insert_at_index": n, "parent_id": null, "child_index": -1,
			"drop_position": UxmlDocument.DragPosition.OUTSIDE_ITEMS}
		var row := row_at(gp)
		var tree := UxmlContainerParts.is_tree(el)
		if row == null:
			var vp := viewport_control()
			if vp != null and (vp.get_global_transform().affine_inverse() * gp).y < 0.0:
				out["insert_at_index"] = 0
				if tree:
					out["child_index"] = 0
			return out
		var c: Control = control_of(row.element)
		var ly := (c.get_global_transform().affine_inverse() * gp).y
		var i := row.index
		out["index"] = i
		if c.size.y - ly < BETWEEN_ITEMS_BAND:
			out["insert_at_index"] = i + 1
			out["drop_position"] = UxmlDocument.DragPosition.BETWEEN_ITEMS
		elif ly > BETWEEN_ITEMS_BAND:
			out["insert_at_index"] = i
			out["drop_position"] = UxmlDocument.DragPosition.OVER_ITEM
		else:
			out["insert_at_index"] = i
			out["drop_position"] = UxmlDocument.DragPosition.BETWEEN_ITEMS
		if not tree:
			return out
		if out["drop_position"] == UxmlDocument.DragPosition.OVER_ITEM:
			out["parent_id"] = item_id(i)
			return out
		var k: int = out["insert_at_index"]
		if k < n:
			var p := _parent_index(k)
			out["parent_id"] = null if p < 0 else item_id(p)
			out["child_index"] = _sibling_index(k, p)
		return out

	## The visible index of the parent of visible tree item `k`, or -1.
	func _parent_index(k: int) -> int:
		var d := int(_flat[k]["depth"])
		var j := k - 1
		while j >= 0 and int(_flat[j]["depth"]) >= d:
			j -= 1
		return j

	## The index of visible tree item `k` among the children of `p`.
	func _sibling_index(k: int, p: int) -> int:
		var d := int(_flat[k]["depth"])
		var out := 0
		for j in range(p + 1, k):
			if int(_flat[j]["depth"]) == d:
				out += 1
		return out

	## Unity dragAndDropUpdate (or the reorderable default).
	func drag_update(args: Dictionary) -> int:
		var cb := drag_callback("drag_and_drop_update")
		if cb.is_valid():
			return _mode(cb.call(args))
		return _default_mode(args)

	## Unity handleDrop (or the reorderable default).
	func drop(args: Dictionary) -> int:
		var cb := drag_callback("handle_drop")
		if cb.is_valid():
			return _mode(cb.call(args))
		var mode := _default_mode(args)
		if mode != UxmlDocument.DragVisualMode.MOVE:
			return mode
		if UxmlContainerParts.is_tree(el):
			_drop_tree(args)
		else:
			_drop_list(args)
		return mode

	static func _mode(v: Variant) -> int:
		return int(v) if v is int else UxmlDocument.DragVisualMode.NONE

	## Unity's reorderable controllers: only items of this view move, when
	## `reorderable`; a list does not drop over an item; a tree item does
	## not go into itself or below itself.
	func _default_mode(args: Dictionary) -> int:
		if not _reorderable() or args.get("source_element") != el:
			return UxmlDocument.DragVisualMode.REJECTED
		if not UxmlContainerParts.is_tree(el):
			if args["drop_position"] == UxmlDocument.DragPosition.OVER_ITEM:
				return UxmlDocument.DragVisualMode.REJECTED
			return UxmlDocument.DragVisualMode.MOVE
		var dragged := {}
		for i in args["indices"]:
			dragged[int(i)] = true
		var p := -1
		if args["drop_position"] == UxmlDocument.DragPosition.OVER_ITEM:
			p = int(args["index"])
		elif int(args["insert_at_index"]) < count():
			p = _parent_index(int(args["insert_at_index"]))
		while p >= 0:
			if dragged.has(p):
				return UxmlDocument.DragVisualMode.REJECTED
			p = _parent_index(p)
		return UxmlDocument.DragVisualMode.MOVE

	## Unity ListViewReorderableDragAndDropController.OnDrop: the dragged
	## items move, in order, to the insert index; item_index_changed for
	## every move; the moved items stay selected.
	func _drop_list(args: Dictionary) -> void:
		var sorted: Array = args["indices"].duplicate()
		sorted.sort()
		var insert := int(args["insert_at_index"])
		var insert_shift := 0
		var src_shift := 0
		var before := 0
		for i in sorted:
			if int(i) < insert:
				before += 1
		for k in range(sorted.size() - 1, -1, -1):
			var index := int(sorted[k])
			var to := insert - insert_shift
			if index >= insert:
				index += src_shift
				src_shift += 1
			elif index < to:
				insert_shift += 1
				to -= 1
			if index != to and index < count() and to < count():
				_move_one(index, to)
		var start := insert - before
		set_selection(range(start, start + sorted.size()), false)
		refresh(true)

	## Unity TreeViewReorderableDragAndDropController.OnDrop: the dragged
	## items (not those whose parent also moves) go, in order, under the
	## drop parent at the child index; item_index_changed(id, parent id)
	## for every move; the parent opens; the moved items stay selected.
	func _drop_tree(args: Dictionary) -> void:
		var pid = args["parent_id"]
		var kids: Array = _roots
		if pid != null:
			var pn := _find_item(_roots, pid)
			if pn.is_empty():
				return
			if not pn.get("children") is Array:
				pn["children"] = []
			kids = pn["children"]
		var at := int(args["child_index"])
		var dragged := {}
		for i in args["indices"]:
			dragged[int(i)] = true
		var moved: Array = []
		for i in args["indices"]:
			var p := _parent_index(int(i))
			var nested := false
			while p >= 0 and not nested:
				nested = dragged.has(p)
				p = _parent_index(p)
			if nested:
				continue
			var id = item_id(int(i))
			var loc := _locate(_roots, id)
			if loc.is_empty():
				continue
			var list: Array = loc[0]
			var node = list[loc[1]]
			if is_same(list, kids) and at >= 0 and int(loc[1]) < at:
				at -= 1
			list.remove_at(loc[1])
			if at < 0 or at > kids.size():
				kids.append(node)
			else:
				kids.insert(at, node)
				at += 1
			moved.append(id)
		if pid != null:
			_expanded[pid] = true
		_reflatten()
		var sel: Array = []
		for k in _flat.size():
			if moved.has(_flat[k]["id"]):
				sel.append(k)
		set_selection(sel, false)
		refresh(true)
		for id in moved:
			doc.item_index_changed.emit(element_name(), id, pid)

	## [the Array that holds tree item `id`, its index there], or [].
	func _locate(items: Array, id: Variant) -> Array:
		for k in items.size():
			var it = items[k]
			if it is Dictionary:
				if it.get("id") == id:
					return [items, k]
				var kids = it.get("children")
				if kids is Array:
					var r := _locate(kids, id)
					if not r.is_empty():
						return r
		return []

	## Unity ListViewDragger auto-scroll: a pointer in the edge band of the
	## viewport scrolls it.
	func auto_scroll(gp: Vector2) -> void:
		var vp := viewport_control()
		var svb = doc._behaviors.get(_sv)
		if vp == null or svb == null:
			return
		var ly := (vp.get_global_transform().affine_inverse() * gp).y
		var d := 0.0
		if ly >= 0.0 and ly < AUTO_SCROLL_BAND:
			d = -AUTO_SCROLL_STEP
		elif ly <= vp.size.y and ly > vp.size.y - AUTO_SCROLL_BAND:
			d = AUTO_SCROLL_STEP
		if d != 0.0:
			svb.set_offset(svb.offset() + Vector2(0.0, d))

	func _click_select(i: int, shift: bool, ctrl: bool) -> void:
		var mode := selection_mode()
		if mode == "None":
			return
		if mode == "Multiple" and shift and _anchor >= 0:
			var out: Array = []
			for k in range(mini(_anchor, i), maxi(_anchor, i) + 1):
				out.append(k)
			set_selection(out)
			return
		if mode == "Multiple" and ctrl:
			var out := _selection.duplicate()
			if out.has(i):
				out.erase(i)
			else:
				out.append(i)
			_anchor = i
			set_selection(out)
			return
		_anchor = i
		set_selection([i])

	## Unity's collection keys (KeyboardNavigationManipulator): arrows and
	## the controller d-pad move the selection, Page Up/Down by a page,
	## Home/End to the ends, Shift extends a Multiple selection, Enter or
	## the controller A button chooses the selected items; a TreeView opens
	## and closes items with Right and Left.
	func _on_key(ev: InputEvent) -> void:
		if _dragging and ev is InputEventKey and ev.is_pressed() and (ev as InputEventKey).keycode == KEY_ESCAPE:
			doc.cancel_drag()
			control_of(_content).accept_event()
			return
		if not ev.is_pressed() or count() == 0:
			return
		var cur: int = _selection[-1] if not _selection.is_empty() else -1
		var page := maxi(1, int(floor(_viewport_h() / expected_height())))
		var to := -2
		if ev.is_action_pressed("ui_down"):
			to = cur + 1
		elif ev.is_action_pressed("ui_up"):
			to = maxi(0, cur - 1) if cur >= 0 else 0
		elif ev.is_action_pressed("ui_page_down"):
			to = cur + page
		elif ev.is_action_pressed("ui_page_up"):
			to = cur - page
		elif ev is InputEventKey and (ev as InputEventKey).keycode == KEY_HOME:
			to = 0
		elif ev is InputEventKey and (ev as InputEventKey).keycode == KEY_END:
			to = count() - 1
		elif ev.is_action_pressed("ui_accept"):
			if not _selection.is_empty():
				doc.items_chosen.emit(element_name(), selected())
			control_of(_content).accept_event()
			return
		elif UxmlContainerParts.is_tree(el) and cur >= 0 and (ev.is_action_pressed("ui_right") or ev.is_action_pressed("ui_left")):
			var f := tree_item(cur)
			var right := ev.is_action_pressed("ui_right")
			if int(f.get("children", 0)) > 0 and bool(f["expanded"]) != right:
				set_expanded(f["id"], right)
			control_of(_content).accept_event()
			return
		else:
			return
		to = clampi(to, 0, count() - 1)
		var shift := ev is InputEventKey and (ev as InputEventKey).shift_pressed
		if shift and selection_mode() == "Multiple":
			if _anchor < 0:
				_anchor = maxi(cur, 0)
			var out: Array = []
			for k in range(mini(_anchor, to), maxi(_anchor, to) + 1):
				out.append(k)
			set_selection(out)
		else:
			_anchor = to
			set_selection([to])
		scroll_to_item(to)
		control_of(_content).accept_event()

	func _viewport_h() -> float:
		var vp := control_of(UxmlContainerParts.get_part(_sv, "viewport")) if _sv != null else null
		return 0.0 if vp == null else vp.size.y

	## Unity ScrollToItem: the smallest scroll that shows item `i`.
	func scroll_to_item(i: int) -> void:
		var svb = doc._behaviors.get(_sv)
		if svb == null or i < 0:
			return
		var off := _offset_showing(i, svb.offset())
		if _dynamic:
			_scroll_target = i
			svb.set_offset_pending(off)
			refresh(false)
		else:
			svb.set_offset(off)

	# ---- footer, size field ----------------------------------------------

	## Unity's footer: + adds an item at the end, - removes the selected
	## items (or the last one). A bound Array changes; else the item count.
	func _on_add() -> void:
		if not UxmlParts._bool(el, "allow-add", true):
			return
		var n := count()
		if _items is Array:
			(_items as Array).append(null)
		_info["count"] = n + 1
		refresh(true)
		_update_size_field()
		doc.items_added.emit(element_name(), [n])

	func _on_remove() -> void:
		if not UxmlParts._bool(el, "allow-remove", true) or count() == 0:
			return
		var gone: Array = _selection.duplicate() if not _selection.is_empty() else [count() - 1]
		gone.sort()
		gone.reverse()
		if _items is Array:
			for i in gone:
				(_items as Array).remove_at(i)
		_info["count"] = count() - gone.size()
		_selection = []
		refresh(true)
		_update_size_field()
		gone.reverse()
		doc.items_removed.emit(element_name(), gone)

	func _update_size_field() -> void:
		var sf := UxmlContainerParts.get_part(el, "size-field")
		if sf == null:
			return
		var le := doc._natives.get(sf) as LineEdit
		if le != null and le.text != str(count()):
			le.text = str(count())

	func _on_size_submitted(t: String) -> void:
		var n := int(t)
		if n < 0 or n == count():
			_update_size_field()
			return
		var old := count()
		if _items is Array:
			(_items as Array).resize(n)
		_info["count"] = n
		_clamp_selection()
		refresh(true)
		if n > old:
			doc.items_added.emit(element_name(), range(old, n))
		else:
			doc.items_removed.emit(element_name(), range(n, old))

	# ---- trees ---------------------------------------------------------------

	func _on_toggle(on: bool, row: UxmlListRow) -> void:
		var f := tree_item(row.index)
		if f.is_empty():
			return
		set_expanded(f["id"], on)

	# ---- columns ---------------------------------------------------------------

	func set_cell_bind(column: int, bind: Callable) -> void:
		_cell_binds[column] = bind
		refresh(true)

	func set_comparison(column: int, cmp: Callable) -> void:
		_comparisons[column] = cmp

	func sort_descriptions() -> Array:
		var out: Array = []
		var cols := UxmlContainerParts.columns_of(el)
		for s in _sort:
			out.append({"column_name": cols[s["column"]]["name"], "column_index": s["column"],
				"direction": s["direction"]})
		return out

	## A click on a sortable header column: ascending, then descending
	## (Unity MultiColumnCollectionHeader). Shift adds a column.
	func _on_header_input(ev: InputEvent, column: int) -> void:
		var mb := ev as InputEventMouseButton
		if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if attr("sorting-mode", "None") == "None" and not UxmlParts._bool(el, "sorting-enabled", false):
			return
		var cols := UxmlContainerParts.columns_of(el)
		if column < 0 or column >= cols.size() or not cols[column]["sortable"]:
			return
		var dir := "Ascending"
		for s in _sort:
			if s["column"] == column:
				dir = "Descending" if s["direction"] == "Ascending" else "Ascending"
		if not mb.shift_pressed:
			_sort = []
		else:
			for s in _sort.duplicate():
				if s["column"] == column:
					_sort.erase(s)
		_sort.append({"column": column, "direction": dir})
		_sort_header_classes()
		doc.column_sorting_changed.emit(element_name(), sort_descriptions())
		if attr("sorting-mode", "None") == "Default":
			_sort_items()

	func _sort_header_classes() -> void:
		for x in el.walk():
			if x.part_of != el or x.part_role != "header-column":
				continue
			var ci := int(x.get_meta(&"uxml_column"))
			var dir := ""
			for s in _sort:
				if s["column"] == ci:
					dir = s["direction"]
			UxmlParts.toggle_control_class(x, "unity-multi-column-header__column--sorted-ascending", dir == "Ascending")
			UxmlParts.toggle_control_class(x, "unity-multi-column-header__column--sorted-descending", dir == "Descending")

	## sorting-mode="Default": sort the bound Array by the column comparison
	## (set_column_comparison), else by the item's text.
	func _sort_items() -> void:
		if not _items is Array:
			return
		var arr: Array = _items
		var keys := _sort.duplicate()
		arr.sort_custom(func(a, b) -> bool:
			for s in keys:
				var cmp: Callable = _comparisons.get(s["column"], Callable())
				var r := 0
				if cmp.is_valid():
					r = int(cmp.call(a, b))
				else:
					var sa := UxmlBinding._str(a)
					var sb := UxmlBinding._str(b)
					r = -1 if sa < sb else (1 if sa > sb else 0)
				if s["direction"] == "Descending":
					r = -r
				if r != 0:
					return r < 0
			return false)
		refresh(true)

	## Drag a resize handle: the column's width follows the pointer,
	## clamped to min-width and max-width.
	func _on_resize_input(ev: InputEvent, column: int) -> void:
		var cols := UxmlContainerParts.columns_of(el)
		if column < 0 or column >= cols.size() or not cols[column]["resizable"]:
			return
		var mb := ev as InputEventMouseButton
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var hc := control_of(UxmlContainerParts.get_part(el, "header"))
				var widths := UxmlContainerParts.column_widths(el, 0.0 if hc == null else hc.size.x)
				_resize_col = column
				_resize_x = mb.global_position.x
				_resize_w = widths[column]
			else:
				_resize_col = -1
			return
		var mm := ev as InputEventMouseMotion
		if mm != null and _resize_col == column:
			set_column_width(column, _resize_w + mm.global_position.x - _resize_x)

	func set_column_width(column: int, w: float) -> void:
		var cols := UxmlContainerParts.columns_of(el)
		if column < 0 or column >= cols.size():
			return
		var c: Dictionary = cols[column]
		c["user_width"] = clampf(w, c["min_width"], c["max_width"])
		var hc := control_of(UxmlContainerParts.get_part(el, "header"))
		if hc != null and UxmlContainerParts.update_columns(el, hc.size.x):
			doc.relayout()

	# ---- binding, view data ----------------------------------------------------

	func bind_write(prop: String, v: Variant) -> int:
		match prop:
			"selected-index":
				var i := int(UxmlBinding._num(v))
				_pending_sel = [i] if i >= 0 else []
				set_selection(_pending_sel, false)
				return 1
			"selected-indices":
				if v is Array or v is PackedInt32Array or v is PackedInt64Array:
					_pending_sel = Array(v)
					set_selection(_pending_sel, false)
					return 1
				return -1
			"header-title":
				var f := UxmlContainerParts.get_part(el, "foldout-header")
				if f != null:
					f.set_attribute("text", UxmlBinding._str(v))
					return 2
				return write_attr("header-title", UxmlBinding._str(v))
		return UNHANDLED

	func bind_read(prop: String) -> Array:
		match prop:
			"selected-index":
				return [true, _selection[-1] if not _selection.is_empty() else -1]
			"selected-indices":
				return [true, selected()]
		return [false, null]

	func view_state() -> Dictionary:
		var out := {"selected_indices": selected()}
		var svb = doc._behaviors.get(_sv)
		if svb != null:
			out.merge(svb.view_state())
		if UxmlContainerParts.is_multi_column(el):
			var widths := {}
			for c in UxmlContainerParts.columns_of(el):
				if c.has("user_width"):
					widths[c["name"]] = c["user_width"]
			out["column_widths"] = widths
			out["sort"] = sort_descriptions()
		return out

	func restore_view_state(d: Dictionary) -> void:
		var svb = doc._behaviors.get(_sv)
		if svb != null:
			svb.restore_view_state(d)
		var sel = d.get("selected_indices")
		if sel is Array:
			_pending_sel = sel
			set_selection(sel, false)
			_apply_pending_selection()
		var widths = d.get("column_widths")
		if widths is Dictionary:
			for c in UxmlContainerParts.columns_of(el):
				if widths.has(c["name"]):
					c["user_width"] = float(widths[c["name"]])


# ---------------------------------------------------------------------------
# TabView, Tab
# ---------------------------------------------------------------------------

## TabView: a click (or ui_accept on a focused header) selects a Tab; the
## close button of a closeable Tab closes it; with `reorderable` a drag of
## a header moves its Tab (tab_reordered). `value_changed` sends the
## selected index (Unity selectedTabIndex).
class TabViewBehavior extends UxmlBehaviors.Behavior:
	var _tabs: Array = []
	var _index := -1
	var _closed: Dictionary = {}   # Tab element -> true
	var _drag_tab: UxmlElement = null
	var _drag_x := 0.0
	var _dragging := false

	func setup() -> void:
		_tabs = UxmlContainerParts.tabs_of(el)
		for k in _tabs.size():
			var tab: UxmlElement = _tabs[k]
			var header := UxmlContainerParts.get_part(tab, "header")
			var hc := control_of(header)
			if hc != null:
				# Not focusable in Unity; focusable here so a controller can
				# reach the tabs.
				UxmlContainerBehaviors.set_focus(hc, Control.FOCUS_ALL)
				UxmlContainerBehaviors.set_mouse(hc, Control.MOUSE_FILTER_STOP)
				hc.gui_input.connect(_on_header_input.bind(tab))
				hc.focus_entered.connect(set_state.bind(header, "focus", true))
				hc.focus_exited.connect(set_state.bind(header, "focus", false))
			var cb := control_of(UxmlContainerParts.get_part(tab, "close-button"))
			if cb != null:
				UxmlContainerBehaviors.set_mouse(cb, Control.MOUSE_FILTER_STOP)
				cb.gui_input.connect(_on_close_input.bind(tab))
		select(0, false)

	func native() -> Control:
		return doc._controls.get(el)

	func selected_index() -> int:
		return _index

	func select(i: int, notify: bool = true) -> void:
		if i < 0 or i >= _tabs.size() or _closed.has(_tabs[i]) or i == _index:
			return
		_index = i
		UxmlContainerParts.select_tab_model(el, i)
		for k in _tabs.size():
			var on := k == i
			set_state(_tabs[k], "checked", on)
			set_state(UxmlContainerParts.get_part(_tabs[k], "header"), "checked", on)
		if notify:
			doc.value_changed.emit(element_name(), i)
			ui_changed.emit()

	func close(i: int) -> void:
		if i < 0 or i >= _tabs.size() or _closed.has(_tabs[i]):
			return
		var tab: UxmlElement = _tabs[i]
		_closed[tab] = true
		UxmlContainerParts.set_style(UxmlContainerParts.get_part(tab, "header"), "display: none;")
		UxmlContainerParts.set_style(tab, "display: none;")
		doc.tab_closed.emit(element_name(), i)
		if _index == i:
			_index = -1
			for k in _tabs.size():
				if not _closed.has(_tabs[k]):
					select(k)
					break

	func _on_header_input(ev: InputEvent, tab: UxmlElement) -> void:
		var i := _tabs.find(tab)
		var mb := ev as InputEventMouseButton
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				select(i)
				_drag_tab = tab
				_drag_x = mb.global_position.x
				_dragging = false
			else:
				if _dragging and _drag_tab != null:
					_drop(mb.global_position.x)
				_drag_tab = null
				_dragging = false
			return
		var mm := ev as InputEventMouseMotion
		if mm != null and _drag_tab != null and UxmlParts._bool(el, "reorderable", false):
			if absf(mm.global_position.x - _drag_x) > 5.0:
				_dragging = true
			return
		if ev.is_action_pressed("ui_accept"):
			select(i)
			control_of(UxmlContainerParts.get_part(tab, "header")).accept_event()

	func _on_close_input(ev: InputEvent, tab: UxmlElement) -> void:
		var mb := ev as InputEventMouseButton
		if mb != null and not mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			close(_tabs.find(tab))

	## The header under the pointer takes the dragged Tab's place.
	func _drop(x: float) -> void:
		var from := _tabs.find(_drag_tab)
		var to := from
		for k in _tabs.size():
			var hc := control_of(UxmlContainerParts.get_part(_tabs[k], "header"))
			if hc != null and hc.is_visible_in_tree():
				var r := hc.get_global_rect()
				if x >= r.position.x and x < r.end.x:
					to = k
		move_tab(from, to)

	## Move the Tab at `from` to index `to` (Unity's reorderable TabView):
	## its header moves in the header container and the Tab in the content
	## container; the selection follows the Tab. Emits tab_reordered.
	func move_tab(from: int, to: int) -> void:
		if from < 0 or to < 0 or from >= _tabs.size() or to >= _tabs.size() or from == to:
			return
		var tab: UxmlElement = _tabs[from]
		var selected: UxmlElement = _tabs[_index] if _index >= 0 else null
		var hc := UxmlContainerParts.get_part(el, "header-container")
		var content := UxmlContainerParts.get_part(el, "content")
		var header := UxmlContainerParts.get_part(tab, "header")
		var target: UxmlElement = _tabs[to]
		_move_child(hc, header, UxmlContainerParts.get_part(target, "header"), to > from)
		_move_child(content, tab, target, to > from)
		_tabs.remove_at(from)
		_tabs.insert(to, tab)
		_index = _tabs.find(selected) if selected != null else -1
		doc._structure_changed()
		doc.tab_reordered.emit(element_name(), from, to)

	## Move `child` of `parent` before (or after) `anchor`, in the model and
	## in the Godot node order.
	func _move_child(parent: UxmlElement, child: UxmlElement, anchor: UxmlElement, after: bool) -> void:
		parent.children.erase(child)
		var at := parent.children.find(anchor) + (1 if after else 0)
		parent.children.insert(at, child)
		var k := 0
		for c in parent.children:
			var ctl := control_of(c)
			if ctl != null and ctl.get_parent() != null:
				ctl.get_parent().move_child(ctl, k)
				k += 1

	func bind_write(prop: String, v: Variant) -> int:
		if prop == "selected-tab-index" or prop == "value":
			select(int(UxmlBinding._num(v)), false)
			return 1
		return UNHANDLED

	func bind_read(prop: String) -> Array:
		if prop == "selected-tab-index" or prop == "value":
			return [true, _index]
		return [false, null]

	func view_state() -> Dictionary:
		return {"selected_tab_index": _index}

	func tab_order() -> Array:
		var out: Array = []
		for t in _tabs:
			out.append(doc._name_of(t))
		return out

	func restore_view_state(d: Dictionary) -> void:
		if d.has("selected_tab_index"):
			select(int(d["selected_tab_index"]), false)


## Tab: its `label` and `icon-image` reach the header parts.
class TabBehavior extends UxmlBehaviors.Behavior:
	func setup() -> void:
		var header := UxmlContainerParts.get_part(el, "header")
		if header != null and el.children.has(header):
			# A Tab outside a TabView: the underline follows the Tab width.
			doc._post_layout.append(self)

	func after_layout() -> void:
		UxmlContainerParts.update_lone_tab(el, func(x: UxmlElement):
			var c: Control = doc._controls.get(x)
			return null if c == null else c.size)

	func on_model_changed() -> void:
		# Inside a TabView the header moved; the part cache still finds it.
		var lbl := UxmlContainerParts.get_part(el, "header-label")
		if lbl != null and UxmlParts._attr(lbl, "text") != attr("label"):
			lbl.attributes = lbl.attributes.duplicate(true)
			for a in lbl.attributes:
				if a["name"] == "text":
					a["value"] = attr("label")
			var c := control_of(lbl)
			if c != null:
				doc._set_control_text(c, attr("label"))

	func bind_write(prop: String, v: Variant) -> int:
		if prop == "label":
			return write_attr("label", UxmlBinding._str(v), 2)
		return UNHANDLED


# ---------------------------------------------------------------------------
# TwoPaneSplitView
# ---------------------------------------------------------------------------

## TwoPaneSplitView: dragging the dragline resizes the fixed pane, kept
## between 0 and the view size.
class TwoPaneBehavior extends UxmlBehaviors.Behavior:
	var _dim := 0.0
	var _dragging := false
	var _start := 0.0
	var _start_dim := 0.0

	var _margins := 0.0

	func setup() -> void:
		_dim = UssValues.parse_number(attr("fixed-pane-initial-dimension", "100"))
		if is_nan(_dim):
			_dim = 100.0
		# The anchor sits past the fixed pane's margins: known after the
		# cascade (after_layout).
		doc._post_layout.append(self)
		var dl := control_of(UxmlContainerParts.get_part(el, "dragline"))
		if dl != null:
			UxmlContainerBehaviors.set_mouse(dl, Control.MOUSE_FILTER_STOP)
			dl.mouse_default_cursor_shape = (Control.CURSOR_VSIZE if _vertical() else Control.CURSOR_HSIZE)
			dl.gui_input.connect(_on_input)

	func native() -> Control:
		return doc._controls.get(el)

	func _vertical() -> bool:
		return UxmlContainerParts.two_pane_orientation(el) == "vertical"

	func dimension() -> float:
		return _dim

	func set_dimension(d: float) -> void:
		var c := native()
		var limit := INF
		if c != null and c.size != Vector2.ZERO:
			limit = (c.size.y if _vertical() else c.size.x) - 1.0
		_dim = clampf(d, 0.0, maxf(0.0, limit))
		if UxmlContainerParts.two_pane_style(el, _dim, _margins):
			doc.relayout()

	func after_layout() -> void:
		var m := UxmlContainerParts.two_pane_margins(el, func(x: UxmlElement) -> Dictionary:
			return doc._styles.get(x, {}))
		if m != _margins:
			_margins = m
			if UxmlContainerParts.two_pane_style(el, _dim, _margins):
				doc.relayout()

	func _on_input(ev: InputEvent) -> void:
		var a := 1 if _vertical() else 0
		var mb := ev as InputEventMouseButton
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
			var ended: bool = _dragging and not mb.pressed and _dim != _start_dim
			_dragging = mb.pressed
			_start = mb.global_position[a]
			if ended:
				doc.split_changed.emit(element_name(), _dim)
			_start_dim = _dim
			set_state(UxmlContainerParts.get_part(el, "dragline"), "active", mb.pressed)
			return
		var mm := ev as InputEventMouseMotion
		if mm != null and _dragging:
			var d := mm.global_position[a] - _start
			var fixed1 := int(UssValues.parse_number(attr("fixed-pane-index", "0"))) == 1
			set_dimension(_start_dim + (-d if fixed1 else d))

	func view_state() -> Dictionary:
		return {"fixed_pane_dimension": _dim}

	func restore_view_state(d: Dictionary) -> void:
		if d.has("fixed_pane_dimension"):
			set_dimension(float(d["fixed_pane_dimension"]))


# ---------------------------------------------------------------------------
# IMGUIContainer
# ---------------------------------------------------------------------------

## IMGUIContainer: Unity's onGUIHandler is C# IMGUI code. The element hosts
## a Godot draw callback instead (UxmlDocument.set_imgui_handler).
class ImguiBehavior extends UxmlBehaviors.Behavior:
	func native() -> Control:
		return doc._controls.get(el)
