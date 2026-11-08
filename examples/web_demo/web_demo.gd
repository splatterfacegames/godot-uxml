extends Control
## The web demo of godot-uxml (https://godot-uxml.splatterfacegames.com).
##
## Pick a document in the bar: godot-uxml reads the UXML and USS files and
## makes Godot controls. The panel on the right shows the source files and
## the signals of the document. In a browser the GDScript path runs (a web
## export has no GDExtension).
##
##   godot --path . res://examples/web_demo/web_demo.tscn

const DEMO := "res://examples/web_demo"
const SAMPLES := [
	{"title": "Settings screen", "root": DEMO, "path": "settings.uxml", "files": ["settings.uxml", "settings.uss"]},
	{"title": "ListView, 10,000 items", "root": DEMO, "path": "list.uxml", "files": ["list.uxml", "list_row.uxml", "list.uss"], "list": 10000},
	{"title": "examples/minimal", "root": "res://examples/minimal", "path": "ui.uxml", "files": ["ui.uxml", "ui.uss"]},
	{"title": "Runtime controls", "root": "res://tests/fixtures/controls", "path": "Assets/UI/controls.uxml", "files": ["Assets/UI/controls.uxml", "Assets/UI/controls.uss"]},
	{"title": "Options form", "root": "res://tests/fixtures/options", "path": "Assets/UI/Options.uxml", "files": ["Assets/UI/Options.uxml", "Assets/UI/Options.uss"]},
	{"title": "Editor controls, dark skin", "root": "res://tests/fixtures/editor", "path": "Assets/UI/editor.uxml", "files": ["Assets/UI/editor.uxml", "Assets/UI/editor.uss"], "skin": "dark"},
	{"title": "Editor controls, light skin", "root": "res://tests/fixtures/editor", "path": "Assets/UI/editor.uxml", "files": ["Assets/UI/editor.uxml", "Assets/UI/editor.uss"], "skin": "light"},
]
const NAMES := ["Iron sword", "Oak shield", "Health potion", "Mana potion", "Leather boots", "Silver ring", "Map fragment", "Torch"]
## Below this width the source panel starts closed.
const NARROW := 820.0

const BG := Color("#0d1014")
const PANEL := Color("#161b21")
const LINE := Color("#2a323c")
const INK := Color("#e6ebf0")
const MUTED := Color("#8b97a5")
const ACCENT := Color("#4fd1a5")

var doc: UxmlDocument
var _host: Control
var _side: TabContainer
var _sources: TabContainer
var _events: TextEdit
var _picker: OptionButton
var _info: Label
var _source_button: Button
var _current := -1


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	if OS.has_feature("web"):
		# The canvas has device pixels: draw at the CSS size.
		var ratio = JavaScriptBridge.eval("window.devicePixelRatio || 1", true)
		if ratio != null and float(ratio) > 1.0:
			get_window().content_scale_factor = float(ratio)
	theme = _make_theme()
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var column := VBoxContainer.new()
	column.set_anchors_preset(Control.PRESET_FULL_RECT)
	column.add_theme_constant_override("separation", 0)
	add_child(column)

	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", _box(PANEL, LINE, 0, Vector4(0, 0, 0, 1), 10, 6))
	column.add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	bar.add_child(row)
	_picker = OptionButton.new()
	_picker.tooltip_text = "The document to load"
	for s in SAMPLES:
		_picker.add_item(s["title"])
	_picker.item_selected.connect(show_sample)
	row.add_child(_picker)
	_info = Label.new()
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.add_theme_color_override("font_color", MUTED)
	_info.add_theme_font_size_override("font_size", 12)
	_info.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_info.clip_text = true
	row.add_child(_info)
	_source_button = Button.new()
	_source_button.text = "Source"
	_source_button.toggle_mode = true
	_source_button.toggled.connect(func(on): _side.visible = on)
	row.add_child(_source_button)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(split)
	_host = Control.new()
	_host.clip_contents = true
	_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_host.size_flags_stretch_ratio = 1.6
	split.add_child(_host)
	_side = TabContainer.new()
	_side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_side.custom_minimum_size.x = 280
	split.add_child(_side)
	_sources = TabContainer.new()
	_sources.name = "Files"
	_side.add_child(_sources)
	_events = _text_view("Signals")
	_events.placeholder_text = "Click a button or change a value: the signals of the document show here."
	_side.add_child(_events)

	var wide := get_viewport_rect().size.x >= NARROW
	_side.visible = wide
	_source_button.set_pressed_no_signal(wide)
	show_sample(0)


func show_sample(index: int) -> void:
	_current = index
	_picker.select(index)
	var s: Dictionary = SAMPLES[index]
	if doc != null:
		doc.queue_free()
	doc = UxmlDocument.new()
	doc.auto_load = false
	if s.has("skin"):
		doc.editor_theme = "always"
		doc.editor_skin = s["skin"]
	doc.set_anchors_preset(Control.PRESET_FULL_RECT)
	_host.add_child(doc)
	var t0 := Time.get_ticks_usec()
	var err := doc.load_document(s["path"], s["root"])
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	if s.has("list"):
		var n: int = s["list"]
		doc.set_list_source("items", n, _bind_row)
	doc.button_pressed.connect(_on_button)
	doc.value_changed.connect(_on_value)
	_events.text = ""
	_log("loaded %s: %s" % [s["path"], "OK" if err == OK else error_string(err)])
	for d in doc.diagnostics:
		_log(UxmlDiagnostic.format(d))
		print("web demo: ", UxmlDiagnostic.format(d))
	var core := "native core" if ClassDB.class_exists("UxmlNativeCascade") else "GDScript path"
	_info.text = "%s  |  load %.0f ms  |  %d diagnostics" % [core, ms, doc.diagnostics.size()]
	print("web demo: loaded %s (%s, %.0f ms, %d diagnostics)" % [s["path"], core, ms, doc.diagnostics.size()])
	for c in _sources.get_children():
		_sources.remove_child(c)
		c.queue_free()
	for f in s["files"]:
		var view := _text_view("file")
		view.text = FileAccess.get_file_as_string(String(s["root"]) + "/" + String(f))
		_sources.add_child(view)
		_sources.set_tab_title(_sources.get_tab_count() - 1, String(f).get_file())


func _bind_row(row: UxmlListRow, i: int) -> void:
	(row.get_native("index") as Label).text = "#%d" % i
	(row.get_native("name") as Label).text = "%s %d" % [NAMES[i % NAMES.size()], i / NAMES.size() + 1]
	(row.get_native("value") as Label).text = "%d g" % ((i * 7919) % 1000 + 1)


func _on_button(element_name) -> void:
	_log("button_pressed(\"%s\")" % element_name)
	if _current != 0:
		return
	match String(element_name):
		"apply":
			doc.set_text("status", "Applied")
		"reset":
			show_sample(0)


func _on_value(element_name, value) -> void:
	_log("value_changed(\"%s\", %s)" % [element_name, var_to_str(value)])
	if _current == 0 and doc.get_element("status") != null:
		doc.set_text("status", "%s = %s" % [element_name, str(value)])


func _log(line: String) -> void:
	_events.text += line + "\n"
	_events.scroll_vertical = _events.get_line_count()


func _text_view(title: String) -> TextEdit:
	var t := TextEdit.new()
	t.name = title
	t.editable = false
	t.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	t.add_theme_font_size_override("font_size", 12)
	t.add_theme_color_override("font_readonly_color", INK)
	t.add_theme_stylebox_override("read_only", _box(BG, BG, 0, Vector4.ZERO, 10, 8))
	return t


func _box(fill: Color, border: Color, radius: int, widths: Vector4, mx: int, my: int) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = fill
	b.border_color = border
	b.border_width_left = int(widths.x)
	b.border_width_top = int(widths.y)
	b.border_width_right = int(widths.z)
	b.border_width_bottom = int(widths.w)
	b.set_corner_radius_all(radius)
	b.content_margin_left = mx
	b.content_margin_right = mx
	b.content_margin_top = my
	b.content_margin_bottom = my
	return b


func _make_theme() -> Theme:
	var th := Theme.new()
	th.default_font_size = 14
	for type in ["Button", "OptionButton"]:
		th.set_stylebox("normal", type, _box(Color("#20262e"), LINE, 6, Vector4.ONE, 12, 6))
		th.set_stylebox("hover", type, _box(Color("#28303a"), ACCENT, 6, Vector4.ONE, 12, 6))
		th.set_stylebox("pressed", type, _box(Color("#1b3a31"), ACCENT, 6, Vector4.ONE, 12, 6))
		th.set_stylebox("focus", type, StyleBoxEmpty.new())
		th.set_color("font_color", type, INK)
		th.set_color("font_pressed_color", type, ACCENT)
	th.set_stylebox("panel", "TabContainer", _box(BG, LINE, 0, Vector4(1, 0, 0, 0), 0, 0))
	th.set_stylebox("tab_selected", "TabContainer", _box(BG, ACCENT, 0, Vector4(0, 0, 0, 2), 12, 6))
	th.set_stylebox("tab_unselected", "TabContainer", _box(PANEL, LINE, 0, Vector4(0, 0, 0, 1), 12, 6))
	th.set_stylebox("tab_hovered", "TabContainer", _box(PANEL, MUTED, 0, Vector4(0, 0, 0, 1), 12, 6))
	th.set_stylebox("tabbar_background", "TabContainer", _box(PANEL, LINE, 0, Vector4(1, 0, 0, 1), 0, 0))
	th.set_color("font_selected_color", "TabContainer", INK)
	th.set_color("font_unselected_color", "TabContainer", MUTED)
	th.set_font_size("font_size", "TabContainer", 12)
	th.set_stylebox("panel", "PopupMenu", _box(PANEL, LINE, 6, Vector4.ONE, 6, 6))
	th.set_stylebox("hover", "PopupMenu", _box(Color("#1b3a31"), Color("#1b3a31"), 4, Vector4.ZERO, 6, 2))
	th.set_color("font_color", "PopupMenu", INK)
	th.set_color("font_hover_color", "PopupMenu", INK)
	return th
