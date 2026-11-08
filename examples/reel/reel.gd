extends Control
## The announcement reel of godot-uxml: a fixed timeline, recorded frame by
## frame with Godot's Movie Maker (no screen capture, no real-time clock).
##
##   -- --reel=intro  the Unity/godot-uxml comparison, the settings screen
##                    driven by pointer input, a scroll of a 10,000-item
##                    ListView (9.4 s)
##   -- --reel=end    the end card (2.6 s)
##
## Record with tools/record_reel.sh (1920x1080, 60 fps). The UI draws at a
## content scale of 2: the layout units below are 960x540.
##
##   godot --path . res://examples/reel/reel.tscn -- --reel=intro

const DEMO := "res://examples/web_demo"
const CASE_IMG := "res://site/public/img/%s-ed-propertyfield.png"
const NAMES := ["Iron sword", "Oak shield", "Health potion", "Mana potion", "Leather boots", "Silver ring", "Map fragment", "Torch"]
const W := 960.0
const H := 540.0
const BAND := 76.0

# The palette of godot-uxml.splatterfacegames.com.
const PAPER := Color("#eef1f4")
const SHEET := Color("#f8fafb")
const INK := Color("#15191e")
const INK_2 := Color("#47505b")
const INK_3 := Color("#6b7480")
const RULE := Color("#cfd5dc")
const GODOT := Color("#478cbf")
const GODOT_DEEP := Color("#2c6a99")
const UNITY := Color("#3c3c3c")

const LENGTH := {"intro": 9.4, "end": 2.6}
## Segment starts in the intro.
const T_LIVE := 3.4
const T_LIST := 7.3

var reel := "intro"
var t := 0.0
var _frame := 0

var _font: Font
var _bold: FontVariation
var _caption: Label
var _sub: Label
var _band: ColorRect
var _fade: ColorRect
var _cursor: Control
var _stage: Control

# Hook
var _hook: Control
var _wipe: Control
var _unity_tag: Label
var _godot_tag: Label
var _split := 1.0

# Live UI
var _live: Control
var _doc: UxmlDocument
var _list_doc: UxmlDocument
var _pointer := Vector2(W + 40, H + 40)
var _buttons := 0
var _done := {}

# End card
var _end: Control


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--reel="):
			reel = a.substr(7)
	var w := get_window()
	w.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	w.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	w.content_scale_size = Vector2i(1920, 1080)
	w.content_scale_factor = 2.0
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_font = UxmlTheme.default_font()
	_bold = FontVariation.new()
	_bold.base_font = _font
	_bold.variation_embolden = 0.55

	var bg := ColorRect.new()
	bg.color = PAPER
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_stage = Control.new()
	_stage.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_stage)
	if reel == "end":
		_build_end()
	else:
		_build_hook()
		_build_live()
		_build_band()
		_cursor = _Cursor.new()
		_cursor.z_index = 100
		add_child(_cursor)
	_fade = ColorRect.new()
	_fade.color = INK
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade)
	_step(0.0)


## Real mouse input does not reach the reel: only the events it makes.
func _input(event: InputEvent) -> void:
	if event is InputEventMouse and not event.has_meta("reel"):
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	# Movie Maker runs at a fixed frame rate: count frames, not seconds.
	_frame += 1
	t = _frame / 60.0
	_step(t)
	if t >= LENGTH.get(reel, 0.0):
		get_tree().quit()


func _step(time: float) -> void:
	if reel == "end":
		_run_end(time)
	else:
		_run_intro(time)


# ---------------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------------

func _label(text: String, size: int, color: Color, font: Font = null) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font if font != null else _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _build_band() -> void:
	_band = ColorRect.new()
	_band.color = INK
	_band.position = Vector2.ZERO
	_band.size = Vector2(W, BAND)
	_band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_band)
	var accent := ColorRect.new()
	accent.color = GODOT
	accent.position = Vector2(0, BAND - 3)
	accent.size = Vector2(W, 3)
	_band.add_child(accent)
	_caption = _label("", 31, PAPER, _bold)
	_caption.position = Vector2(32, 9)
	_band.add_child(_caption)
	_sub = _label("", 17, Color("#aab4c0"))
	_sub.position = Vector2(33, 47)
	_band.add_child(_sub)


func _texture(side: String) -> Texture2D:
	var img := Image.load_from_file(ProjectSettings.globalize_path(CASE_IMG % side))
	return ImageTexture.create_from_image(img)


func _build_hook() -> void:
	_hook = Control.new()
	_hook.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stage.add_child(_hook)
	# 1.5 layout units per image pixel: 3 frame pixels, nearest filter.
	var frame := Vector2(600, 360)
	var at := Vector2((W - frame.x) * 0.5, BAND + 46)
	var shadow := ColorRect.new()
	shadow.color = RULE
	shadow.position = at - Vector2(1, 1)
	shadow.size = frame + Vector2(2, 2)
	_hook.add_child(shadow)
	var unity := TextureRect.new()
	unity.texture = _texture("unity")
	unity.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	unity.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	unity.position = at
	unity.size = frame
	_hook.add_child(unity)
	# godot-uxml's render, clipped to the right of the line.
	_wipe = Control.new()
	_wipe.clip_contents = true
	_wipe.position = at
	_wipe.size = frame
	_hook.add_child(_wipe)
	var godot := TextureRect.new()
	godot.texture = _texture("godot")
	godot.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	godot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	godot.size = frame
	godot.name = "Godot"
	_wipe.add_child(godot)
	var line := ColorRect.new()
	line.name = "Line"
	line.color = GODOT
	line.size = Vector2(2, frame.y + 16)
	_hook.add_child(line)
	_unity_tag = _tag("Unity 6000.3", UNITY)
	_hook.add_child(_unity_tag)
	_godot_tag = _tag("godot-uxml", GODOT_DEEP)
	_hook.add_child(_godot_tag)
	var note := _label("Test case ed-propertyfield: Unity's render and godot-uxml's render of the same UXML", 15, INK_2)
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.position = Vector2(0, at.y + frame.y + 10)
	note.size = Vector2(W, 20)
	_hook.add_child(note)


func _tag(text: String, color: Color) -> Label:
	var l := _label(text, 14, Color.WHITE, _bold)
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(3)
	box.content_margin_left = 8
	box.content_margin_right = 8
	box.content_margin_top = 2
	box.content_margin_bottom = 3
	l.add_theme_stylebox_override("normal", box)
	return l


func _build_live() -> void:
	_live = Control.new()
	_live.set_anchors_preset(Control.PRESET_FULL_RECT)
	_live.visible = false
	_stage.add_child(_live)
	var host := Control.new()
	host.clip_contents = true
	# The 16px top padding of the screen goes under the caption band: the
	# Audio tab needs the height.
	host.position = Vector2(0, BAND - 16)
	host.size = Vector2(W, H - BAND + 16)
	_live.add_child(host)
	_doc = _load(host, "settings.uxml")
	_doc.button_pressed.connect(func(n): if n == "apply": _doc.set_text("status", "Applied"))
	_doc.value_changed.connect(func(n, v): _doc.set_text("status", "%s = %s" % [n, str(v)]))
	_list_doc = _load(host, "list.uxml")
	_list_doc.set_list_source("items", 10000, _bind_row)
	_list_doc.visible = false


func _load(host: Control, file: String) -> UxmlDocument:
	var doc := UxmlDocument.new()
	doc.auto_load = false
	doc.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(doc)
	var err := doc.load_document(file, DEMO)
	if err != OK or not doc.diagnostics.is_empty():
		push_warning("reel: %s: %s, %d diagnostics" % [file, error_string(err), doc.diagnostics.size()])
	return doc


func _bind_row(row: UxmlListRow, i: int) -> void:
	(row.get_native("index") as Label).text = "#%d" % i
	(row.get_native("name") as Label).text = "%s %d" % [NAMES[i % NAMES.size()], i / NAMES.size() + 1]
	(row.get_native("value") as Label).text = "%d g" % ((i * 7919) % 1000 + 1)


func _build_end() -> void:
	_end = VBoxContainer.new()
	_end.set_anchors_preset(Control.PRESET_FULL_RECT)
	_end.alignment = BoxContainer.ALIGNMENT_CENTER
	_end.add_theme_constant_override("separation", 10)
	_stage.add_child(_end)
	var mark := TextureRect.new()
	var svg := Image.new()
	svg.load_svg_from_buffer(FileAccess.get_file_as_bytes("res://site/public/mark.svg"), 3.0)
	mark.texture = ImageTexture.create_from_image(svg)
	mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mark.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	mark.custom_minimum_size = Vector2(0, 64)
	_end.add_child(mark)
	var title := _label("godot-uxml + UXML Editor", 50, INK, _bold)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end.add_child(title)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 8)
	_end.add_child(gap)
	for url in ["godot-uxml.splatterfacegames.com", "uxml-editor.splatterfacegames.com"]:
		var l := _label(url, 28, GODOT_DEEP)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_end.add_child(l)
	var gap2 := Control.new()
	gap2.custom_minimum_size = Vector2(0, 10)
	_end.add_child(gap2)
	var tail := _label("Open source  ·  Apache-2.0  ·  Runs in your browser", 22, INK_2)
	tail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end.add_child(tail)


# ---------------------------------------------------------------------------
# Timeline
# ---------------------------------------------------------------------------

## [time, value] pairs, eased between (as the Typesetter reel).
static func key(keys: Array, time: float) -> float:
	for i in keys.size() - 1:
		var a: Array = keys[i]
		var b: Array = keys[i + 1]
		if time <= b[0]:
			var k := clampf((time - a[0]) / maxf(b[0] - a[0], 1e-4), 0.0, 1.0)
			return lerpf(a[1], b[1], k * k * (3.0 - 2.0 * k))
	return keys[-1][1]


static func key2(keys: Array, time: float) -> Vector2:
	var xs := keys.map(func(k): return [k[0], k[1].x])
	var ys := keys.map(func(k): return [k[0], k[1].y])
	return Vector2(key(xs, time), key(ys, time))


func _run_intro(time: float) -> void:
	_fade.modulate.a = key([[0.0, 1.0], [0.25, 0.0], [T_LIVE - 0.2, 0.0], [T_LIVE, 1.0], [T_LIVE + 0.25, 0.0], [9.1, 0.0], [9.4, 1.0]], time)
	if time < T_LIVE:
		_run_hook(time)
	else:
		_hook.visible = false
		_live.visible = true
		_run_live(time)


func _run_hook(time: float) -> void:
	_caption.text = "Unity UI Toolkit files → native Godot controls"
	_sub.text = "Matches Unity 6000.3 in 177 of 178 test cases. 99.8% of box pixels are exact."
	_cursor.visible = false
	# Unity's render first, then the line moves across and back to the middle.
	_split = key([[0.0, 1.0], [0.5, 1.0], [1.5, 0.0], [1.9, 0.0], [2.7, 0.5], [3.4, 0.5]], time)
	var frame := Vector2(600, 360)
	var at := Vector2((W - 600) * 0.5 + frame.x * _split, _wipe.position.y)
	_wipe.position.x = (W - 600) * 0.5 + frame.x * _split
	_wipe.size.x = frame.x * (1.0 - _split)
	(_wipe.get_node("Godot") as Control).position.x = -frame.x * _split
	var line := _hook.get_node("Line") as Control
	line.position = Vector2(at.x - 1, at.y - 8)
	_unity_tag.position = Vector2((W - 600) * 0.5, at.y - 28)
	_unity_tag.modulate.a = clampf(_split * 4.0, 0.0, 1.0)
	_godot_tag.position = Vector2((W + 600) * 0.5 - _godot_tag.size.x, at.y - 28)
	_godot_tag.modulate.a = clampf((1.0 - _split) * 4.0, 0.0, 1.0)


## Pointer path: [time, target] in layout units. A target is a position or
## a Callable, measured when the pointer starts to move to it (the screen is
## then in its state of that time: the tab is open, the value is set).
const PATH := [
	[0.0, "start"], [0.15, "start"],
	[0.75, "frame-limit"], [0.85, "frame-limit"], [1.55, "frame-limit-end"], [1.7, "frame-limit-end"],
	[2.1, "vsync"], [2.3, "vsync"],
	[2.75, "tab-profile"], [3.05, "tab-profile"],
	[3.5, "apply"], [3.95, "apply"],
]
## Pointer buttons: [time, kind].
const CLICKS := [[0.9, "down"], [1.6, "up"], [2.2, "click"], [2.85, "click"], [3.6, "click"]]
var _resolved := {}


func _run_live(time: float) -> void:
	var lt := time - T_LIVE
	if time < T_LIST:
		_caption.text = "Every element is a Godot control"
		_sub.text = "settings.uxml + settings.uss. Hover, tabs, sliders and toggles work."
		_cursor.visible = true
		var keys: Array = []
		for i in PATH.size():
			# Measure a target when the pointer leaves the previous point.
			if i == 0 or lt >= PATH[i - 1][0] or _resolved.has(i):
				if not _resolved.has(i):
					_resolved[i] = _target(String(PATH[i][1]))
				keys.append([PATH[i][0], _resolved[i]])
		var p: Vector2 = key2(keys, lt) if keys.size() > 1 else keys[0][1]
		_move(p)
		_cursor.position = p
		for c in CLICKS:
			if lt >= c[0] and not _done.has(c[0]):
				_done[c[0]] = true
				_button(p, c[1])
		(_cursor as _Cursor).pressed = _buttons != 0
		_cursor.queue_redraw()
	else:
		_caption.text = "ListView with 10,000 items"
		_sub.text = "Godot makes only the rows in view. A scroll binds them again."
		_cursor.visible = false
		_doc.visible = false
		_list_doc.visible = true
		var lt2 := time - T_LIST
		var total := 10000.0 * 28.0
		var y := key([[0.0, 0.0], [0.2, 0.0], [1.6, total], [2.1, total]], lt2)
		_list_doc.set_scroll_offset("items", Vector2(0, y))


func _target(what: String) -> Vector2:
	match what:
		"start":
			return Vector2(W + 30, H - 40)
		"tab-profile":
			return _part_rect("tabs", "unity-tab__header", 2).get_center()
		"frame-limit":
			return _part_rect("frame-limit", "unity-base-slider__dragger").get_center()
		"frame-limit-end":
			var r := _part_rect("frame-limit", "unity-base-slider__tracker")
			return Vector2(r.position.x + r.size.x * 0.52, _resolved_point("frame-limit").y)
		"vsync":
			return _part_rect("vsync", "unity-toggle__checkmark").get_center()
		"apply":
			return _doc.get_element("apply").get_global_rect().get_center()
	return Vector2(W * 0.5, H * 0.5)


func _resolved_point(what: String) -> Vector2:
	for i in PATH.size():
		if PATH[i][1] == what and _resolved.has(i):
			return _resolved[i]
	return Vector2.ZERO


## The rectangle of the `index`th part with class `cls` under element `name`.
func _part_rect(name: String, cls: String, index := 0) -> Rect2:
	var found: Array = []
	var stack: Array = [_doc.get_element_model(name)]
	while not stack.is_empty():
		var el: UxmlElement = stack.pop_front()
		if el == null:
			continue
		if cls in el.class_list():
			found.append(el)
		stack.append_array(el.children)
	if found.size() <= index:
		push_warning("reel: no %s in %s" % [cls, name])
		return Rect2(W * 0.5, H * 0.5, 0, 0)
	var c := _doc.get_control_for(found[index])
	return c.get_global_rect() if c != null else Rect2(W * 0.5, H * 0.5, 0, 0)


func _move(p: Vector2) -> void:
	if p.is_equal_approx(_pointer):
		return
	var e := InputEventMouseMotion.new()
	e.position = p
	e.global_position = p
	e.relative = p - _pointer
	e.button_mask = _buttons
	e.set_meta("reel", true)
	_pointer = p
	get_viewport().push_input(e, true)


func _button(p: Vector2, kind: String) -> void:
	for pressed in ([true, false] if kind == "click" else [kind == "down"]):
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		_buttons = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		e.button_mask = _buttons
		e.position = p
		e.global_position = p
		e.set_meta("reel", true)
		get_viewport().push_input(e, true)


func _run_end(time: float) -> void:
	_fade.modulate.a = key([[0.0, 1.0], [0.3, 0.0], [2.6, 0.0]], time)
	_end.modulate.a = 1.0


## The pointer of the reel (the OS cursor is not in a Movie Maker frame).
class _Cursor:
	extends Control
	var pressed := false

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var s := 1.15
		var pts := PackedVector2Array([Vector2(0, 0), Vector2(0, 17), Vector2(4.5, 13), Vector2(7.5, 20), Vector2(10, 19), Vector2(7, 12.5), Vector2(12.5, 12.5)])
		for i in pts.size():
			pts[i] *= s
		if pressed:
			draw_circle(Vector2.ZERO, 14, Color(0.28, 0.55, 0.75, 0.35))
		draw_colored_polygon(pts, Color.BLACK)
		var closed := pts.duplicate()
		closed.append(pts[0])
		draw_polyline(closed, Color.WHITE, 1.5, true)
