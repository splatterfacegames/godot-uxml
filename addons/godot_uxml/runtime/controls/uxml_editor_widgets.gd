class_name UxmlEditorWidgets
extends RefCounted
## The Godot controls of the editor controls (UxmlEditorParts builds their
## parts) and the popups that Unity's editor opens from them:
##
##   ColorField      a ColorPicker in a PopupPanel; the eyedropper samples
##                   the viewport
##   CurveField      CurveView draws the Curve; CurveEditor edits it in a
##                   PopupPanel (Godot's Curve stands in for AnimationCurve)
##   GradientField   GradientView draws the Gradient; GradientEditor edits
##                   it (stops and a ColorPicker) in a PopupPanel
##   ObjectField     ObjectPicker: res:// files of the field type (and scene
##                   nodes for allow-scene-objects) in a PopupPanel, unless
##                   UxmlDocument.set_object_picker() gives a callback
##   mask fields, ToolbarMenu
##                   a Godot PopupMenu: Unity's editor opens these as native
##                   OS menus (GenericOSMenu)
##
## The field controls are UxmlPopupField boxes: focusable, and their input
## goes to the behavior (UxmlEditorBehaviors).


## The control of an editor control element, or null for a plain box.
static func create_control(el: UxmlElement, factory) -> Control:
	match el.local:
		"ToolbarButton", "BreadcrumbItem":
			var b := Button.new()
			b.text = factory._plain_text_attr(el)
			b.focus_mode = Control.FOCUS_ALL
			factory._text_element_attrs(el, b)
			return b
		"ToolbarToggle":
			var t := UxmlToggle.new()
			t.set_pressed_no_signal(factory._bool_attr(el, "value", false))
			return t
		"ColorField", "CurveField", "GradientField", "ObjectField", "ToolbarMenu":
			return UxmlPopupField.new()
	if UxmlEditorParts.POPUP.has(el.local):
		return UxmlPopupField.new()
	return null


## The control of a part that draws editor content (UxmlEditorParts.META_WIDGET).
static func part_control(el: UxmlElement) -> Control:
	match String(el.get_meta(UxmlEditorParts.META_WIDGET, "")):
		"curve":
			return CurveView.new()
		"gradient":
			return GradientView.new()
	return UxmlBox.new()


# ---------------------------------------------------------------------------
# Drawing parts
# ---------------------------------------------------------------------------

## The input of a CurveField: its box, then the curve as a polyline in
## --unity-curve-color, over the curve's value range (Unity draws the
## curve in the field's ranges; the default range is the curve's bounds).
class CurveView extends UxmlBox:
	var curve: Curve = null:
		set(v):
			if curve != null and curve.changed.is_connected(queue_redraw):
				curve.changed.disconnect(queue_redraw)
			curve = v
			if curve != null:
				curve.changed.connect(queue_redraw)
			queue_redraw()
	var color := Color(0, 1, 0):
		set(v):
			color = v
			queue_redraw()
	var ranges := Rect2()  # x: time range, y: value range; empty = curve bounds

	func _draw() -> void:
		super._draw()
		if curve == null or curve.point_count == 0 or size.x < 2.0 or size.y < 2.0:
			return
		var r := view_range(curve, ranges)
		var pts := PackedVector2Array()
		var n := maxi(2, int(size.x))
		for i in n + 1:
			var t := r.position.x + r.size.x * float(i) / float(n)
			var y := curve.sample_baked(t) if curve.bake_resolution > 0 else curve.sample(t)
			var py := (1.0 - (y - r.position.y) / r.size.y) * (size.y - 2.0) + 1.0
			pts.append(Vector2(float(i) / float(n) * size.x, py))
		draw_polyline(pts, color, 1.0, true)

	static func view_range(c: Curve, given: Rect2) -> Rect2:
		if given.size.x > 0.0 and given.size.y > 0.0:
			return given
		var lo := c.min_value
		var hi := c.max_value
		var x0 := c.min_domain
		var x1 := c.max_domain
		if hi - lo <= 0.0:
			hi = lo + 1.0
		if x1 - x0 <= 0.0:
			x1 = x0 + 1.0
		return Rect2(x0, lo, x1 - x0, hi - lo)


## The content of a GradientField: the gradient over the checker of its
## background part.
class GradientView extends UxmlBox:
	var gradient: Gradient = null:
		set(v):
			if gradient != null and gradient.changed.is_connected(_rebuild):
				gradient.changed.disconnect(_rebuild)
			gradient = v
			if gradient != null:
				gradient.changed.connect(_rebuild)
			_rebuild()
	var linear := false  # color-space="Linear": the preview shows sRGB colours
	var _tex: GradientTexture1D = null

	func _rebuild() -> void:
		if gradient == null:
			_tex = null
		else:
			if _tex == null:
				_tex = GradientTexture1D.new()
				_tex.width = 256
			var g := gradient
			if linear:
				g = gradient.duplicate()
				for i in g.get_point_count():
					g.set_color(i, g.get_color(i).linear_to_srgb())
			_tex.gradient = g
		queue_redraw()

	func _draw() -> void:
		super._draw()
		if _tex != null:
			draw_texture_rect(_tex, Rect2(Vector2.ZERO, size), false)


# ---------------------------------------------------------------------------
# Popups
# ---------------------------------------------------------------------------

## A PopupPanel below `anchor`, kept inside the viewport.
static func open_panel(anchor: Control, content: Control, min_size: Vector2) -> PopupPanel:
	var p := PopupPanel.new()
	p.add_child(content)
	anchor.add_child(p)
	var vp := anchor.get_viewport()
	var at: Vector2
	var bounds := Rect2()
	if vp.gui_embed_subwindows:
		at = anchor.get_global_transform_with_canvas().origin + Vector2(0, anchor.size.y)
		bounds = vp.get_visible_rect()
	else:
		at = anchor.get_screen_position() + Vector2(0, anchor.size.y)
		bounds = Rect2(DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen()))
	var sz := Vector2i(maxi(int(min_size.x), int(anchor.size.x)), int(min_size.y))
	if bounds.size != Vector2.ZERO:
		at.x = clampf(at.x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - sz.x))
		if at.y + sz.y > bounds.end.y:
			at.y = maxf(bounds.position.y, at.y - anchor.size.y - sz.y)
	p.popup_hide.connect(p.queue_free)
	p.popup(Rect2i(Vector2i(at), sz))
	return p


## A Godot PopupMenu below `anchor`. `items` holds [text, checked] pairs,
## a text "-" is a separator. `chosen` gets the item index.
static func open_menu(anchor: Control, items: Array, chosen: Callable, checkable := true) -> PopupMenu:
	var m := PopupMenu.new()
	for i in items.size():
		var it: Array = items[i]
		if String(it[0]) == "-":
			m.add_separator()
			continue
		if checkable:
			m.add_check_item(String(it[0]), i)
			m.set_item_checked(m.get_item_index(i), bool(it[1]))
		else:
			m.add_item(String(it[0]), i)
		if it.size() > 2 and bool(it[2]):
			m.set_item_disabled(m.get_item_index(i), true)
	anchor.add_child(m)
	m.id_pressed.connect(func(id): chosen.call(int(id)))
	m.popup_hide.connect(m.queue_free)
	var at: Vector2
	if anchor.get_viewport().gui_embed_subwindows:
		at = anchor.get_global_transform_with_canvas().origin + Vector2(0, anchor.size.y)
	else:
		at = anchor.get_screen_position() + Vector2(0, anchor.size.y)
	m.popup(Rect2i(Vector2i(at), Vector2i(int(anchor.size.x), 0)))
	return m


## A ColorPicker for a ColorField: `edit_alpha` follows show-alpha, `hdr`
## allows values above 1 (raw mode). `changed` gets each new colour.
static func open_color_picker(anchor: Control, c: Color, show_alpha: bool, hdr: bool, changed: Callable) -> PopupPanel:
	var cp := ColorPicker.new()
	cp.edit_alpha = show_alpha
	if hdr:
		cp.color_mode = ColorPicker.MODE_RAW
	cp.color = c
	cp.color_changed.connect(func(col): changed.call(col))
	return open_panel(anchor, cp, Vector2(300, 480))


## Unity's eyedropper: the next left press in the viewport samples the
## colour under the pointer; Escape or a right press cancels.
class Eyedropper extends Control:
	var picked: Callable

	func _init() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_CROSS
		top_level = true
		z_index = 4096

	func _ready() -> void:
		var vp := get_viewport()
		position = Vector2.ZERO
		size = vp.get_visible_rect().size

	func _gui_input(ev: InputEvent) -> void:
		var mb := ev as InputEventMouseButton
		if mb != null and mb.pressed:
			accept_event()
			if mb.button_index == MOUSE_BUTTON_LEFT:
				var img := get_viewport().get_texture().get_image()
				var p := Vector2i(get_global_mouse_position())
				if img != null and Rect2i(Vector2i.ZERO, img.get_size()).has_point(p):
					picked.call(img.get_pixelv(p))
			queue_free()

	func _unhandled_key_input(ev: InputEvent) -> void:
		if ev.is_action_pressed("ui_cancel"):
			queue_free()


static func start_eyedropper(host: Control, picked: Callable) -> void:
	var e := Eyedropper.new()
	e.picked = picked
	host.get_tree().root.add_child(e)


## The curve editor popup: drag a point, double-click to add one,
## right-click to remove one. Unity's CurveEditorWindow stands behind the
## field; Godot has no runtime curve editor, so this one is minimal.
class CurveEditor extends Control:
	var curve: Curve
	var color := Color(0, 1, 0)
	var edited: Callable
	var _drag := -1

	func _init() -> void:
		custom_minimum_size = Vector2(320, 200)
		focus_mode = Control.FOCUS_ALL

	func _range() -> Rect2:
		return CurveView.view_range(curve, Rect2())

	func _to_view(p: Vector2) -> Vector2:
		var r := _range()
		return Vector2((p.x - r.position.x) / r.size.x * size.x,
			(1.0 - (p.y - r.position.y) / r.size.y) * size.y)

	func _to_curve(v: Vector2) -> Vector2:
		var r := _range()
		return Vector2(r.position.x + v.x / maxf(size.x, 1.0) * r.size.x,
			r.position.y + (1.0 - v.y / maxf(size.y, 1.0)) * r.size.y)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.22, 0.22, 0.22))
		if curve == null:
			return
		var pts := PackedVector2Array()
		var n := maxi(2, int(size.x))
		var r := _range()
		for i in n + 1:
			var t := r.position.x + r.size.x * float(i) / float(n)
			pts.append(_to_view(Vector2(t, curve.sample(t))))
		draw_polyline(pts, color, 1.5, true)
		for i in curve.point_count:
			draw_circle(_to_view(curve.get_point_position(i)), 4.0, Color.WHITE)

	func _hit(p: Vector2) -> int:
		for i in curve.point_count:
			if _to_view(curve.get_point_position(i)).distance_to(p) <= 6.0:
				return i
		return -1

	func _gui_input(ev: InputEvent) -> void:
		if curve == null:
			return
		var mb := ev as InputEventMouseButton
		if mb != null and mb.pressed:
			var i := _hit(mb.position)
			if mb.button_index == MOUSE_BUTTON_RIGHT and i >= 0:
				curve.remove_point(i)
				_changed()
			elif mb.button_index == MOUSE_BUTTON_LEFT and mb.double_click and i < 0:
				var c := _to_curve(mb.position)
				curve.add_point(Vector2(c.x, c.y))
				_changed()
			elif mb.button_index == MOUSE_BUTTON_LEFT:
				_drag = i
			accept_event()
		elif mb != null and not mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_drag = -1
		var mm := ev as InputEventMouseMotion
		if mm != null and _drag >= 0:
			var c2 := _to_curve(mm.position)
			var r := _range()
			c2.x = clampf(c2.x, r.position.x, r.end.x)
			c2.y = clampf(c2.y, r.position.y, r.end.y)
			_drag = curve.set_point_offset(_drag, c2.x)
			curve.set_point_value(_drag, c2.y)
			_changed()
			accept_event()

	func _changed() -> void:
		queue_redraw()
		if edited.is_valid():
			edited.call()


## The gradient editor popup: the gradient bar with one handle per stop
## (drag to move, double-click to add, right-click to remove) and a
## ColorPicker for the selected stop.
class GradientEditor extends VBoxContainer:
	var gradient: Gradient
	var edited: Callable
	var hdr := false
	var _bar: Control
	var _picker: ColorPicker
	var _sel := 0
	var _drag := false

	func _init() -> void:
		custom_minimum_size = Vector2(320, 0)

	func _ready() -> void:
		_bar = Control.new()
		_bar.custom_minimum_size = Vector2(300, 36)
		_bar.draw.connect(_draw_bar)
		_bar.gui_input.connect(_bar_input)
		add_child(_bar)
		_picker = ColorPicker.new()
		if hdr:
			_picker.color_mode = ColorPicker.MODE_RAW
		_picker.color_changed.connect(_on_color)
		add_child(_picker)
		_select(0)

	func _select(i: int) -> void:
		if gradient == null or gradient.get_point_count() == 0:
			return
		_sel = clampi(i, 0, gradient.get_point_count() - 1)
		_picker.color = gradient.get_color(_sel)
		_bar.queue_redraw()

	func _draw_bar() -> void:
		var w := _bar.size.x
		var h := _bar.size.y - 10.0
		if gradient == null:
			return
		var t := GradientTexture1D.new()
		t.gradient = gradient
		_bar.draw_texture_rect(t, Rect2(0, 0, w, h), false)
		for i in gradient.get_point_count():
			var x := gradient.get_offset(i) * w
			var col := Color.WHITE if i == _sel else Color(0.6, 0.6, 0.6)
			_bar.draw_colored_polygon(PackedVector2Array([Vector2(x, h), Vector2(x - 5, h + 9), Vector2(x + 5, h + 9)]), col)

	func _hit(x: float) -> int:
		for i in gradient.get_point_count():
			if absf(gradient.get_offset(i) * _bar.size.x - x) <= 6.0:
				return i
		return -1

	func _bar_input(ev: InputEvent) -> void:
		if gradient == null:
			return
		var mb := ev as InputEventMouseButton
		if mb != null and mb.pressed:
			var i := _hit(mb.position.x)
			var off := clampf(mb.position.x / maxf(_bar.size.x, 1.0), 0.0, 1.0)
			if mb.button_index == MOUSE_BUTTON_RIGHT and i >= 0 and gradient.get_point_count() > 1:
				gradient.remove_point(i)
				_select(0)
				_changed()
			elif mb.button_index == MOUSE_BUTTON_LEFT and i < 0 and mb.double_click:
				gradient.add_point(off, gradient.sample(off))
				_select(_hit(mb.position.x))
				_changed()
			elif mb.button_index == MOUSE_BUTTON_LEFT and i >= 0:
				_select(i)
				_drag = true
		elif mb != null and not mb.pressed:
			_drag = false
		var mm := ev as InputEventMouseMotion
		if mm != null and _drag:
			gradient.set_offset(_sel, clampf(mm.position.x / maxf(_bar.size.x, 1.0), 0.0, 1.0))
			_changed()

	func _on_color(c: Color) -> void:
		if gradient != null and _sel < gradient.get_point_count():
			gradient.set_color(_sel, c)
			_changed()

	func _changed() -> void:
		_bar.queue_redraw()
		if edited.is_valid():
			edited.call()


## The object picker: "None" and the res:// files whose resource type is
## `type` (ResourceLoader's recognized extensions), plus the nodes of the
## current scene of that class for `allow_scene`. A filter line narrows
## the list. `chosen` gets the Resource or Node (null for None).
class ObjectPicker extends VBoxContainer:
	var type := "Resource"
	var allow_scene := false
	var chosen: Callable
	var _filter: LineEdit
	var _list: ItemList
	var _entries: Array = []   # [label, path or Node or null]

	func _ready() -> void:
		custom_minimum_size = Vector2(300, 320)
		_filter = LineEdit.new()
		_filter.placeholder_text = "Search"
		_filter.text_changed.connect(func(_t): _fill())
		add_child(_filter)
		_list = ItemList.new()
		_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_list.item_activated.connect(_pick)
		_list.item_clicked.connect(func(i, _p, b): if b == MOUSE_BUTTON_LEFT: _pick(i))
		add_child(_list)
		_entries = [["None", null]]
		for f in ObjectPicker.resource_files(type):
			_entries.append([f.get_file(), f])
		if allow_scene and ClassDB.is_parent_class(type, "Node") and is_inside_tree():
			var scene := get_tree().current_scene
			if scene != null:
				for n in [scene] + scene.find_children("*", type, true, false):
					if (n as Node).is_class(type):
						_entries.append([String((n as Node).name), n])
		_fill()
		_filter.grab_focus.call_deferred()

	func _fill() -> void:
		_list.clear()
		var f := _filter.text.to_lower()
		for i in _entries.size():
			if i == 0 or f.is_empty() or String(_entries[i][0]).to_lower().contains(f):
				var k := _list.add_item(String(_entries[i][0]))
				_list.set_item_metadata(k, i)

	func _pick(k: int) -> void:
		var e: Array = _entries[int(_list.get_item_metadata(k))]
		var v = e[1]
		if v is String:
			v = ResourceLoader.load(v)
		chosen.call(v)

	## Every res:// file of resource type `t`, sorted: files with an
	## extension the loader reads as `t`, and imported files whose .import
	## file names a resource type of class `t` (outside the editor the
	## importers are not registered, so the .import file is the source).
	static func resource_files(t: String) -> PackedStringArray:
		var cls := t if ClassDB.class_exists(t) else "Resource"
		var exts := {}
		for e in ResourceLoader.get_recognized_extensions_for_type(cls):
			exts[String(e).to_lower()] = true
		var found := {}
		_walk("res://", cls, exts, found)
		var out := PackedStringArray(found.keys())
		out.sort()
		return out

	static func _walk(dir: String, cls: String, exts: Dictionary, out: Dictionary) -> void:
		var d := DirAccess.open(dir)
		if d == null:
			return
		for f in d.get_files():
			var path := dir.path_join(f)
			if f.ends_with(".import"):
				var src := path.trim_suffix(".import")
				if not out.has(src) and _import_type_is(path, cls):
					out[src] = true
				continue
			if f.ends_with(".remap"):
				path = path.trim_suffix(".remap")
				f = f.trim_suffix(".remap")
			var ext := f.get_extension().to_lower()
			if ext != "uid" and exts.has(ext):
				out[path] = true
		for sub in d.get_directories():
			if sub.begins_with("."):
				continue
			_walk(dir.path_join(sub), cls, exts, out)

	## The `type="..."` of an .import file's [remap] section is class `cls`.
	static func _import_type_is(path: String, cls: String) -> bool:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			return false
		while not f.eof_reached():
			var line := f.get_line().strip_edges()
			if line.begins_with("type="):
				var ty := line.substr(5).strip_edges().trim_prefix("\"").trim_suffix("\"")
				return ty == cls or (ClassDB.class_exists(ty) and ClassDB.is_parent_class(ty, cls))
		return false
