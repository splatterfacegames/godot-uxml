extends RefCounted
## Milestone 2 runtime tests: UxmlDocument as a real Control — native tree,
## pseudo-states, keyboard/controller/mouse input, signals, reload.
##
## Mouse-dependent checks run only with a real DisplayServer (headless
## Godot does not synthesize hover); keyboard and joypad work everywhere.
## `h` is the SceneTree harness from run_tests.gd.
##
## These documents run without the default theme (theme_path = ""): the
## checks pin authored-USS geometry and runtime mechanics, and the theme's
## own geometry is covered by tests/test_controls.gd and bench/parity.gd.

const FIXTURE := "res://tests/fixtures/runtime"

var h = null


func _init(harness) -> void:
	h = harness


func _load() -> UxmlDocument:
	var doc := UxmlDocument.new()
	doc.theme_path = ""  # geometry below is authored USS only (see header)
	h.root.add_child(doc)
	doc.size = Vector2(400, 600)
	doc.load_document("Assets/UI/runtime.uxml", FIXTURE)
	return doc


func _load_review() -> UxmlDocument:
	var doc := UxmlDocument.new()
	doc.theme_path = ""  # geometry below is authored USS only (see header)
	h.root.add_child(doc)
	doc.size = Vector2(400, 600)
	doc.load_document("Assets/UI/review.uxml", FIXTURE)
	return doc


func _unload(doc: UxmlDocument) -> void:
	h.root.remove_child(doc)
	doc.queue_free()


func _warn_kinds(doc: UxmlDocument) -> Array:
	var out: Array = []
	for d in doc.diagnostics:
		out.append(d["kind"])
	return out


## Press and release: navigation triggers on the press, control activation
## (Button action_mode release) on the release — send both, like a real tap.
func _send_key(code: Key, shift := false) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.shift_pressed = shift
		ev.pressed = pressed
		Input.parse_input_event(ev)


## A real character keypress: keycode + unicode, like the OS delivers.
func _send_char(ch: String) -> void:
	var ev := InputEventKey.new()
	ev.keycode = OS.find_keycode_from_string(ch)
	ev.unicode = ch.unicode_at(0)
	ev.pressed = true
	Input.parse_input_event(ev)
	var rel := InputEventKey.new()
	rel.keycode = ev.keycode
	rel.pressed = false
	Input.parse_input_event(rel)


func _send_joy_button(btn: JoyButton) -> void:
	for pressed in [true, false]:
		var ev := InputEventJoypadButton.new()
		ev.button_index = btn
		ev.pressed = pressed
		Input.parse_input_event(ev)


func _send_mouse_motion(to: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = to
	ev.global_position = to
	Input.parse_input_event(ev)


func _send_mouse_button(idx: MouseButton, pressed: bool, at: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = idx
	ev.pressed = pressed
	ev.position = at
	ev.global_position = at
	Input.parse_input_event(ev)


func _style(el_name: String, doc: UxmlDocument) -> Dictionary:
	return doc.get_computed_style(el_name)


func _style_has(doc: UxmlDocument, el_name: String, prop: String, want: String) -> bool:
	var e = _style(el_name, doc).get(prop)
	return e != null and String(e["value"]).to_lower() == want.to_lower()


## The open dropdown menu under `n`, or null.
func _find_menu(n: Node) -> UxmlPopupMenu:
	for ch in n.get_children(true):
		if ch is UxmlPopupMenu:
			return ch
		var m := _find_menu(ch)
		if m != null:
			return m
	return null


func _focus_owner() -> Control:
	return h.root.gui_get_focus_owner()


# Native tree, attribute wiring, name lookup, duplicate policy, resources.
func test_load_builds_native_controls() -> void:
	var doc := _load()
	await h.process_frame
	h.check(doc.get_element("play") is Button, "play is a native Button")
	h.eq((doc.get_element("play") as Button).text, "Play", "play text wired")
	h.check(doc.get_element("title") is Label, "title is a Label")
	h.eq((doc.get_element("title") as Label).text, "Settings", "title text")
	h.check(doc.get_element("mute") is UxmlToggle, "mute is a UxmlToggle (Unity part tree)")
	h.eq((doc.get_element("mute") as UxmlToggle).button_pressed, true, "mute value=true")

	# Slider, TextField and DropdownField are Unity part trees (the old
	# HSlider / OptionButton / UxmlField mappings are gone): the slider and
	# the dropdown are their own focusable controls, a text field's native
	# is the LineEdit in its text element part.
	var vol := doc.get_native("vol")
	h.check(vol is UxmlSlider, "vol native is the UxmlSlider (got %s)" % vol)
	if vol is UxmlSlider:
		h.eq(vol.min_value, 0.0, "vol low-value")
		h.eq(vol.max_value, 10.0, "vol high-value")
		h.eq(vol.value, 4.0, "vol value")
	h.eq(doc.get_element("vol"), vol, "the slider element is its own control")

	var lives := doc.get_native("lives")
	h.check(lives is UxmlSlider and typeof(lives.behavior.get_value()) == TYPE_INT, "lives is an int slider")

	var player := doc.get_native("player")
	h.check(player is LineEdit, "player native is LineEdit")
	if player is LineEdit:
		h.eq(player.text, "Ada", "player value")
		h.eq(player.placeholder_text, "type here", "placeholder")

	var level := doc.get_native("level")
	h.check(level is UxmlPopupField, "level native is the UxmlPopupField")
	if level is UxmlPopupField:
		h.eq(level.item_count, 3, "level has 3 choices")
		# Unity 6000.3 maps the UXML `value` of a DropdownField to a
		# placeholder property: it selects nothing (ctl-dropdown dump).
		h.eq(level.selected, -1, "value=Normal selects nothing, as in Unity")

	var icon := doc.get_native("icon")
	h.check(icon is TextureRect, "icon native is TextureRect")
	h.check(icon != null and icon.texture != null, "icon.png resolved relative to UXML")

	# Updated with unity/controls-containers: a ScrollView is Unity's part
	# tree, not a Godot ScrollContainer; get_native returns its own box.
	h.eq(doc.get_native("scroller"), doc.get_element("scroller"), "ScrollView native is its own box")
	h.check(doc.get_element("scroller") is UxmlBox, "scroller outer is a UxmlBox")
	h.check(doc.get_element("deep-button") is Button, "scroll children are native")

	# Unknown tag falls back to a container that keeps its children.
	h.check(doc.get_element("odd") is UxmlBox, "MysteryWidget -> UxmlBox fallback")
	h.check(doc.get_element("odd-child") is Label, "fallback keeps children")

	# Name lookup policy: unmatched -> null, duplicates -> first wins + diag.
	h.eq(doc.get_element("missing"), null, "unmatched name returns null")
	h.eq((doc.get_element("dup") as Button).text, "A", "duplicate name returns first")
	h.check(_warn_kinds(doc).has("duplicate-name"), "duplicate name diagnosed")
	h.check(_warn_kinds(doc).has("unsupported-control"), "unknown tag diagnosed")
	_unload(doc)


# The .screen box and its children get real geometry from flex layout.
func test_document_layout_geometry() -> void:
	var doc := _load()
	await h.process_frame
	var screen := doc.get_element("screen")
	h.check(screen.size.x >= 399.0 and screen.size.y >= 599.0,
		"screen box fills 400x600 (got %s)" % screen.size)
	var play := doc.get_element("play")
	h.check(play.size.y >= 29.0 and play.size.y <= 31.0,
		"play height from USS ~30 (got %s)" % play.size.y)
	var title := doc.get_element("title")
	h.check(play.position.y > title.position.y, "play below title in column")
	h.check(play.position.x >= 7.0, "play offset by screen padding")
	var scroller := doc.get_element("scroller")
	h.check(absf(scroller.size.y - 150.0) < 1.0,
		"scroller viewport is the authored 150 (got %s)" % scroller.size.y)
	_unload(doc)


# ScrollView: content is taller than the viewport and wheel/keys scroll it.
# Updated with unity/controls-containers: the ScrollView is Unity's part
# tree (no ScrollContainer). Scrolling is a translate on
# #unity-content-container; the wheel and, for a focusable view, ui_down
# scroll it.
func test_scroll_view() -> void:
	var doc := _load()
	await h.process_frame
	await h.process_frame
	var sv := doc.get_element_model("scroller")
	var content := UxmlParts.content_container(sv)
	var cc: Control = doc._controls[content]
	h.check(cc != null, "content container control exists")
	h.check(cc.size.y >= 399.0, "content keeps its ~400 height (got %s)" % cc.size.y)
	var vs: UxmlElement = UxmlContainerParts.get_part(sv, "vertical-scroller")
	h.check(float(vs.get_attribute("high-value")) > 1.0,
		"positive scroll range (%s)" % vs.get_attribute("high-value"))

	var at := doc.get_element("scroller").get_global_rect().get_center()
	_send_mouse_button(MOUSE_BUTTON_WHEEL_DOWN, true, at)
	await h.process_frame
	doc._restyle_now()
	var v: Vector2 = doc.get_scroll_offset("scroller")
	h.check(v.y > 0, "wheel scrolls content (v=%s)" % v)
	h.eq(cc.offset_transform_position, -v, "content moves by translate")
	await h.process_frame
	h.eq(doc.get_scroll_offset("scroller"), v, "scroll position survives an idle frame")

	# Keyboard scroll while a focusable ScrollView has the focus.
	var box := doc.get_element("scroller")
	box.focus_mode = Control.FOCUS_ALL
	box.grab_focus()
	var before: Vector2 = doc.get_scroll_offset("scroller")
	_send_key(KEY_DOWN)
	await h.process_frame
	h.check(doc.get_scroll_offset("scroller").y > before.y, "ui_down scrolls a focused ScrollView")
	_unload(doc)


# Keyboard/controller navigation: authored Tab order, arrows, joypad,
# sliders consuming arrows, disabled/hidden skipped.
func test_keyboard_and_controller_nav() -> void:
	var doc := _load()
	await h.process_frame

	(doc.get_element("play") as Button).grab_focus()
	await h.process_frame
	h.eq(_focus_owner(), doc.get_element("play"), "play takes focus")

	_send_key(KEY_TAB)
	await h.process_frame
	h.eq(_focus_owner(), doc.get_element("dup"), "Tab -> first dup (authored order)")
	_send_key(KEY_TAB)
	await h.process_frame
	var owner := _focus_owner()
	h.check(owner is Button and owner.text == "B", "Tab -> second dup")
	_send_key(KEY_TAB, true)
	await h.process_frame
	h.eq(_focus_owner(), doc.get_element("dup"), "Shift-Tab back to first dup")

	# Directional nav moves spatially.
	(doc.get_element("play") as Button).grab_focus()
	_send_key(KEY_DOWN)
	await h.process_frame
	h.check(_focus_owner() != null and _focus_owner() != doc.get_element("play"),
		"ui_down moves focus spatially")

	# Sliders consume arrows: value changes, focus stays (a focused slider
	# is movable, Unity's --movable dragger).
	var vol: UxmlSlider = doc.get_native("vol")
	vol.grab_focus()
	var v0 := vol.value
	_send_key(KEY_RIGHT)
	await h.process_frame
	h.check(vol.value > v0, "ui_right raises slider value (%s -> %s)" % [v0, vol.value])
	h.eq(_focus_owner(), vol, "slider keeps focus after arrow")

	# Joypad button maps to ui_accept and activates the focused button.
	var pressed_count := [0]
	doc.button_pressed.connect(func(_n): pressed_count[0] += 1)
	(doc.get_element("play") as Button).grab_focus()
	await h.process_frame
	_send_joy_button(JOY_BUTTON_A)
	await h.process_frame
	await h.process_frame
	h.check(pressed_count[0] >= 1, "joypad A emits button_pressed")

	# Joypad d-pad navigates like arrows.
	_send_joy_button(JOY_BUTTON_DPAD_DOWN)
	await h.process_frame
	h.check(_focus_owner() != doc.get_element("play"), "joypad d-pad moves focus")

	# Disabled/hidden/display:none controls are skipped: tab through the
	# whole tree and assert they never hold focus.
	(doc.get_element("play") as Button).grab_focus()
	var skip: Array = [
		doc.get_element("disabled-button"),
		doc.get_element("hidden-button"),
		doc.get_element("ghost-button"),
	]
	var skipped_hit := false
	for i in 20:
		_send_key(KEY_TAB)
		await h.process_frame
		if skip.has(_focus_owner()):
			skipped_hit = true
			break
	h.check(not skipped_hit, "disabled/hidden controls never take focus")
	_unload(doc)


# Focus styling comes from real focus_entered/focus_exited.
func test_focus_state_styling() -> void:
	var doc := _load()
	await h.process_frame
	var play := doc.get_element("play") as Button
	h.check(not _style_has(doc, "play", "border-top-width", "2px"),
		"no focus border before focus")
	play.grab_focus()
	await h.process_frame
	await h.process_frame
	h.check(_style_has(doc, "play", "border-top-width", "2px"),
		":focus styles applied after focus_entered")
	h.check(play.has_theme_stylebox_override("normal"),
		"focus stylebox override applied to the native")
	_focus_owner().release_focus()
	await h.process_frame
	await h.process_frame
	h.check(not _style_has(doc, "play", "border-top-width", "2px"),
		":focus styles cleared after focus_exited")
	_unload(doc)


# Mouse state machine: base -> hover -> active -> base; click emits once.
func test_mouse_states_and_click() -> void:
	if not h.has_display():
		h.check(true, "headless: synthetic hover needs a window (display run covers)")
		return
	var doc := _load()
	await h.process_frame
	var play := doc.get_element("play") as Button
	var center := play.get_global_rect().get_center()

	var presses := [0]
	doc.button_pressed.connect(func(n): presses[0] += (1 if n == "play" else 0))
	play.pressed.connect(func(): presses[0] += 100)  # native signal too

	h.check(not _style_has(doc, "play", "background-color", "#00ff00"),
		"base state before hover")
	_send_mouse_motion(center)
	await h.process_frame
	await h.process_frame
	h.check(_style_has(doc, "play", "background-color", "#00ff00"),
		":hover applied on real mouse motion")
	h.eq(h.root.gui_get_hovered_control(), play, "viewport hover is the button")

	_send_mouse_button(MOUSE_BUTTON_LEFT, true, center)
	await h.process_frame
	await h.process_frame
	h.check(_style_has(doc, "play", "background-color", "#ff0000"),
		":active applied while held")
	_send_mouse_button(MOUSE_BUTTON_LEFT, false, center)
	await h.process_frame
	await h.process_frame
	h.eq(presses[0], 101, "click emitted exactly once (doc 1 + native 100)")

	_send_mouse_motion(center + Vector2(0, 120))
	await h.process_frame
	await h.process_frame
	h.check(not _style_has(doc, "play", "background-color", "#00ff00"),
		"leaving restores base style")
	_unload(doc)


# Value semantics: one value_changed per real edit, typed per control kind.
func test_value_changed_semantics() -> void:
	var doc := _load()
	await h.process_frame
	var events := [[]]
	doc.value_changed.connect(func(n, v): events[0].append([n, v]))

	var vol: UxmlSlider = doc.get_native("vol")
	vol.value = 7.0
	await h.process_frame
	var vol_events: Array = events[0].filter(func(e): return e[0] == "vol")
	h.eq(vol_events.size(), 1, "one value_changed per slider edit")
	h.eq(vol_events[0][1], 7.0, "slider value payload")

	var lives: UxmlSlider = doc.get_native("lives")
	lives.value = 3.7
	await h.process_frame
	var int_events: Array = events[0].filter(func(e): return e[0] == "lives")
	h.eq(int_events.size(), 1, "one SliderInt event")
	h.eq(int_events[0][1], 4, "SliderInt rounds to int")

	var mute: UxmlToggle = doc.get_native("mute")
	mute.button_pressed = false
	await h.process_frame
	var t_events: Array = events[0].filter(func(e): return e[0] == "mute")
	h.eq(t_events.size(), 1, "one toggle event")
	h.eq(t_events[0][1], false, "toggle emits bool")

	# Real keyboard entry: focus the field and send an actual key event —
	# the text changes through LineEdit's own input path, not a spoofed
	# signal. grab_focus leaves the caret at 0, so move it to the end;
	# text_changed is emitted deferred, so two frames before counting.
	var player: LineEdit = doc.get_native("player")
	player.grab_focus()
	await h.process_frame
	# Unity's select-all-on-focus (default true) selects the text on focus;
	# clear it so the key appends.
	player.deselect()
	player.caret_column = player.text.length()
	await h.process_frame
	_send_char("X")
	await h.process_frame
	await h.process_frame
	var s_events: Array = events[0].filter(func(e): return e[0] == "player")
	h.eq(s_events.size(), 1, "exactly one text event per real edit")
	if s_events.size() == 1:
		h.eq(s_events[0][1], "AdaX", "real key input appends and emits")

	# Real dropdown selection: focus, open the menu with ui_accept,
	# navigate, accept — one value_changed. The menu (UxmlPopupMenu) starts
	# without a highlight because nothing is selected; Up highlights the
	# first item.
	var level: UxmlPopupField = doc.get_native("level")
	level.grab_focus()
	await h.process_frame
	_send_key(KEY_ENTER)
	await h.process_frame
	await h.process_frame
	var menu := _find_menu(level)
	h.check(menu != null and menu.visible, "ui_accept opens the dropdown menu")
	_send_key(KEY_UP)
	await h.process_frame
	_send_key(KEY_ENTER)
	await h.process_frame
	await h.process_frame
	var d_events: Array = events[0].filter(func(e): return e[0] == "level")
	h.eq(d_events.size(), 1, "exactly one dropdown event per real selection")
	if d_events.size() == 1:
		h.eq(d_events[0][1], "Easy", "dropdown emits the selected choice text")
	_unload(doc)


# set_enabled re-resolves :disabled for the whole subtree.
func test_set_enabled_subtree() -> void:
	var doc := _load()
	await h.process_frame
	var dis_btn := doc.get_element("disabled-button") as Button
	h.check(dis_btn.disabled, "enabled=false subtree is disabled natively")
	h.check(_style_has(doc, "disabled-button", "color", "#888888"),
		":disabled style resolves through inherited disabled")

	doc.set_enabled("disabled-area", true)
	await h.process_frame
	await h.process_frame
	h.check(not dis_btn.disabled, "set_enabled(true) re-enables subtree")
	h.check(not _style_has(doc, "disabled-button", "color", "#888888"),
		":disabled style cleared")

	doc.set_enabled("disabled-area", false)
	await h.process_frame
	await h.process_frame
	h.check(dis_btn.disabled, "set_enabled(false) disables again")

	# :checked resolves from the initial value and clears on toggle.
	var mute: UxmlToggle = doc.get_native("mute")
	h.check(mute.button_pressed, "mute starts checked")
	h.check(_style_has(doc, "mute", "border-top-width", "3px"),
		":checked style applied from initial value")
	mute.button_pressed = false
	await h.process_frame
	await h.process_frame
	h.check(not _style_has(doc, "mute", "border-top-width", "3px"),
		":checked style clears on toggle off")
	_unload(doc)


# visibility/display semantics against the real tree.
func test_display_and_visibility() -> void:
	var doc := _load()
	await h.process_frame
	var hidden := doc.get_element("hidden-button") as Button
	var hidden_area := doc.get_element("off-area")
	h.check(not hidden_area.visible, "display:none subtree not visible")
	h.eq(hidden.focus_mode, Control.FOCUS_NONE, "display:none cannot focus")

	var ghost := doc.get_element("ghost")
	h.check(not ghost.visible, "visibility:hidden not visible")
	h.check(ghost.size.y >= 39.0, "hidden element keeps its layout box")
	var ghost_btn := doc.get_element("ghost-button") as Button
	h.eq(ghost_btn.focus_mode, Control.FOCUS_NONE, "hidden control cannot focus")
	h.eq(ghost_btn.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"hidden control ignores mouse")
	_unload(doc)


# Malformed/missing documents fail explicitly; reload frees the old tree.
func test_reload_and_failure() -> void:
	var doc := _load()
	await h.process_frame
	var first := doc.get_element("play")

	doc.load_document("Assets/UI/runtime.uxml", FIXTURE)
	await h.process_frame
	var second := doc.get_element("play")
	h.check(second != null and second != first, "reload builds a fresh tree")
	h.check(not is_instance_valid(first) or first.is_queued_for_deletion(),
		"old tree freed")

	var presses := [0]
	doc.button_pressed.connect(func(_n): presses[0] += 1)
	(second as Button).pressed.emit()
	await h.process_frame
	h.eq(presses[0], 1, "no duplicate signal wiring after reload")

	var err := doc.load_document("Assets/UI/does-not-exist.uxml", FIXTURE)
	h.check(err != OK, "missing document reports failure")
	h.check(doc.diagnostics.size() > 0, "missing document leaves diagnostics")
	h.eq(doc.get_element("play"), null, "no stale tree after failed load")
	h.eq(doc._root_box.get_child_count(), 0, "nothing rendered after failed load")

	# Malformed but readable UXML: the tolerant parser keeps what it read,
	# the load succeeds with diagnostics — ERR_FILE_CANT_OPEN is only for
	# files that cannot be read at all.
	err = doc.load_document("Assets/UI/broken.uxml", FIXTURE)
	h.eq(err, OK, "malformed readable doc loads tolerantly")
	h.check(_warn_kinds(doc).has("malformed"), "malformed structure diagnosed")
	h.check(doc.get_element("kept") != null, "readable portion renders")
	_unload(doc)


# A hundred loads must not grow node/object counts without bound.
func test_repeated_loads_do_not_leak() -> void:
	var doc := _load()
	for i in 5:
		doc.load_document("Assets/UI/runtime.uxml", FIXTURE)
		await h.process_frame
	var before := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	for i in 95:
		doc.load_document("Assets/UI/runtime.uxml", FIXTURE)
		if i % 10 == 0:
			await h.process_frame
	for i in 3:
		await h.process_frame
	var after := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	h.check(after - before < 200,
		"100 loads: node count stable (%s -> %s)" % [before, after])
	_unload(doc)


# Invalid attribute values warn without crashing.
func test_invalid_attributes_warn() -> void:
	var doc := UxmlDocument.new()
	doc.theme_path = ""  # geometry below is authored USS only (see header)
	h.root.add_child(doc)
	doc.size = Vector2(400, 600)
	doc.load_document("Assets/UI/bad.uxml", FIXTURE)
	await h.process_frame
	var kinds := _warn_kinds(doc)
	h.check(kinds.count("unsupported-value") >= 3,
		"invalid values diagnosed (got %s)" % [kinds])
	var s: UxmlSlider = doc.get_native("s")
	h.check(s != null and s.min_value == 0.0, "bad low-value falls back to 0")
	var d: UxmlPopupField = doc.get_native("d")
	h.check(d == null or d.selected < d.item_count, "out-of-range index safe")
	_unload(doc)


# InputMap: default Godot mapping covers keyboard+controller.
func test_input_map_coverage() -> void:
	for action in ["ui_up", "ui_down", "ui_left", "ui_right", "ui_accept", "ui_focus_next"]:
		h.check(InputMap.has_action(action), "%s exists" % action)
	var joy := 0
	for ev in InputMap.action_get_events("ui_accept"):
		if ev is InputEventJoypadButton or ev is InputEventJoypadMotion:
			joy += 1
	h.check(joy >= 1, "ui_accept has a joypad binding")
	joy = 0
	for ev in InputMap.action_get_events("ui_down"):
		if ev is InputEventJoypadButton or ev is InputEventJoypadMotion:
			joy += 1
	h.check(joy >= 1, "ui_down has a joypad binding")


# ---------------------------------------------------------------------------
# Review-return coverage
# ---------------------------------------------------------------------------

# Explicit dimensions shrink on real native controls too — a native
# minimum size must not override the authored flex result.
func test_native_geometry_shrink_and_clamp() -> void:
	var doc := _load_review()
	await h.process_frame
	var s1 := doc.get_element("s1")
	var s2 := doc.get_element("s2")
	h.check(absf(s1.size.x - 150.0) < 1.0,
		"explicit 200 shrank to ~150 natively (got %s)" % s1.size.x)
	h.check(absf(s2.size.x - 150.0) < 1.0,
		"second explicit-200 shrank too (got %s)" % s2.size.x)
	h.check(absf(s2.position.x - 150.0) < 1.0,
		"position follows the shrunk size")
	var maxh := doc.get_element("maxh")
	h.check(absf(maxh.size.y - 30.0) < 1.0,
		"max-height caps row stretch natively (got %s)" % maxh.size.y)
	var maxw := doc.get_element("maxw")
	h.check(absf(maxw.size.x - 40.0) < 1.0,
		"max-width caps column stretch natively (got %s)" % maxw.size.x)
	_unload(doc)


# focusable applies to the real focus target: the inner native for wrapped
# controls, never an extra wrapper tab stop.
func test_focusable_targets_native() -> void:
	var doc := _load_review()
	await h.process_frame
	var nf_wrap := doc.get_element("nofocus")
	var nf_native := doc.get_native("nofocus")
	h.eq(nf_wrap.focus_mode, Control.FOCUS_NONE, "focusable=false wrapper off")
	h.eq(nf_native.focus_mode, Control.FOCUS_NONE, "focusable=false native off")

	var yf_wrap := doc.get_element("yesfocus")
	var yf_native := doc.get_native("yesfocus")
	h.eq(yf_native.focus_mode, Control.FOCUS_ALL, "focusable=true native on")
	# A Slider is a part tree now: the element control itself takes the
	# focus (Unity's Slider is the focusable element), so the element and
	# the native are one stop. A TextField keeps a wrapper box.
	h.eq(yf_wrap, yf_native, "focusable=true: the slider is one focus stop")
	h.eq(doc.get_element("focusfield").focus_mode, Control.FOCUS_NONE, "a text field box is no extra stop")

	# Tab reaches the native; :focus resolves on the element for each
	# wrapped control kind.
	yf_native.grab_focus()
	await h.process_frame
	h.eq(_focus_owner(), yf_native, "wrapped slider native takes focus")
	await h.process_frame
	h.check(_style_has(doc, "yesfocus", "border-top-width", "4px"),
		":focus styles resolve for wrapped Slider")
	_send_key(KEY_TAB)
	await h.process_frame
	await h.process_frame
	h.eq(_focus_owner(), doc.get_native("focusfield"), "Tab -> TextField native")
	h.check(_style_has(doc, "focusfield", "border-top-width", "4px"),
		":focus styles resolve for wrapped TextField")
	_send_key(KEY_TAB)
	await h.process_frame
	await h.process_frame
	h.eq(_focus_owner(), doc.get_native("focusdd"), "Tab -> DropdownField native")
	h.check(_style_has(doc, "focusdd", "border-top-width", "4px"),
		":focus styles resolve for wrapped DropdownField")
	_send_key(KEY_TAB, true)
	await h.process_frame
	h.eq(_focus_owner(), doc.get_native("focusfield"), "Shift-Tab returns")

	# The unfocusable slider never receives Tab focus across the whole ring.
	yf_native.grab_focus()
	var hit := false
	for i in 15:
		_send_key(KEY_TAB)
		await h.process_frame
		var o := _focus_owner()
		if o == nf_native or o == nf_wrap:
			hit = true
			break
	h.check(not hit, "focusable=false skipped by Tab navigation")
	_unload(doc)


# readonly survives the initial apply and every later restyle — including
# disable/re-enable — and a real keypress cannot edit the field.
func test_readonly_preserved() -> void:
	var doc := _load_review()
	await h.process_frame
	var le: LineEdit = doc.get_native("readonlyf")
	h.eq(le.editable, false, "readonly loads non-editable")

	doc.set_element_state("readonlyf", "hover", true)
	await h.process_frame
	await h.process_frame
	h.eq(le.editable, false, "readonly survives hover restyle")
	doc.set_element_state("readonlyf", "hover", false)
	await h.process_frame
	await h.process_frame
	h.eq(le.editable, false, "readonly survives hover clear")

	doc.set_enabled("readonlyf", false)
	await h.process_frame
	await h.process_frame
	h.eq(le.editable, false, "still non-editable while disabled")
	doc.set_enabled("readonlyf", true)
	await h.process_frame
	await h.process_frame
	h.eq(le.editable, false, "re-enable does not clear readonly")

	le.grab_focus()
	await h.process_frame
	_send_char("Z")
	await h.process_frame
	h.eq(le.text, "fixed", "real keypress cannot edit readonly")

	var te: TextEdit = doc.get_native("mlro")
	h.eq(te.editable, false, "multiline readonly preserved")

	# An editable control takes the same real input.
	var ed: LineEdit = doc.get_native("editablef")
	ed.grab_focus()
	await h.process_frame
	ed.deselect()  # Unity's select-all-on-focus selected the text
	ed.caret_column = ed.text.length()
	_send_char("K")
	await h.process_frame
	await h.process_frame
	h.eq(ed.text, "openK", "editable field accepts real input")
	_unload(doc)


# Leaving a state removes its overrides — caption, alignment, wrap — and
# repeated restyles never nest FontVariations.
func test_style_restoration_and_font_stability() -> void:
	var doc := _load_review()
	await h.process_frame

	# The caption is the label part of the TextField (a Label control).
	var cap: Label = doc._controls[UxmlParts.find_part(doc.get_element_model("caprestore"), "label")]
	doc.set_element_state("caprestore", "hover", true)
	await h.process_frame
	await h.process_frame
	h.check(cap.has_theme_color_override("font_color"), "hover sets caption color")
	h.check(cap.has_theme_font_size_override("font_size"), "hover sets caption size")
	doc.set_element_state("caprestore", "hover", false)
	await h.process_frame
	await h.process_frame
	h.check(not cap.has_theme_color_override("font_color"),
		"caption color override removed")
	h.check(not cap.has_theme_font_size_override("font_size"),
		"caption font-size override removed")

	# The hover color is absent until the state exists.
	var btn := doc.get_element("hoverfont") as Button
	h.check(not _style_has(doc, "hoverfont", "color", "#123456"),
		"base style before hover")

	# 100 state transitions: the variation base must stay the unstyled
	# theme font, never a previous FontVariation.
	for i in 100:
		doc.set_element_state("hoverfont", "hover", i % 2 == 0)
		await h.process_frame
	var f := btn.get_theme_font("font")
	h.check(f is FontVariation, "bold style produces FontVariation")
	var depth := 0
	var base := f
	while base is FontVariation:
		base = base.base_font
		depth += 1
	h.eq(depth, 1, "no nested FontVariation chain after 100 restyles (depth %s)" % depth)
	_unload(doc)


# An inherited url() resolves against the stylesheet that declared it —
# UXML in Assets/UI, sheet in Assets/Styles, font inside the sheet's dir.
func test_inherited_asset_origin() -> void:
	var doc := UxmlDocument.new()
	doc.theme_path = ""  # geometry below is authored USS only (see header)
	h.root.add_child(doc)
	doc.size = Vector2(400, 300)
	doc.load_document("Assets/UI/panel.uxml", "res://tests/fixtures/origin")
	await h.process_frame
	h.check(not _warn_kinds(doc).has("missing-file"),
		"inherited font resolved from the declaring sheet (kinds %s)" % [_warn_kinds(doc)])
	var lbl := doc.get_element("inheritor") as Label
	h.check(lbl != null and lbl.has_theme_font_override("font"),
		"inherited font applies to the descendant")
	var deep := doc.get_element("deep") as Label
	h.check(deep != null and deep.has_theme_font_override("font"),
		"multi-hop inheritance keeps the sheet origin")
	_unload(doc)


# reload() keeps the effective root of the last successful load.
func test_reload_preserves_effective_root() -> void:
	var doc := UxmlDocument.new()
	doc.theme_path = ""  # geometry below is authored USS only (see header)
	h.root.add_child(doc)
	doc.size = Vector2(400, 600)
	h.eq(doc.load_document("Assets/UI/runtime.uxml", FIXTURE), OK,
		"load with explicit non-default root")
	# Poison the exported default: if reload() consulted project_root the
	# document could not resolve at all.
	doc.project_root = "res://nonexistent-root"
	h.eq(doc.reload(), OK, "reload uses the effective root")
	h.check(doc.get_element("play") != null, "elements present after reload")
	var icon := doc.get_native("icon") as TextureRect
	h.check(icon != null and icon.texture != null, "assets resolve after reload")
	_unload(doc)


# Runtime diagnostics dedupe across restyles and resizes; a missing
# resource is attempted once, not once per state transition.
func test_diagnostics_dedupe() -> void:
	var doc := _load_review()
	await h.process_frame
	var n0 := doc.diagnostics.size()
	h.check(_warn_kinds(doc).has("missing-file"), "missing background diagnosed")
	for i in 10:
		doc.set_element_state("missingbg", "hover", i % 2 == 0)
		doc.size = Vector2(400.0 + i, 600.0)
		await h.process_frame
	await h.process_frame
	h.eq(doc.diagnostics.size(), n0,
		"10 restyles add no diagnostics (was %s, now %s)" % [n0, doc.diagnostics.size()])
	_unload(doc)


# DropdownField: `index` selects positionally. Unity 6000.3 maps the UXML
# `value` attribute to a placeholder property, so `value` selects nothing
# (measured: ctl-dropdown); the runtime value setter (binding, code)
# still selects by choice text.
func test_dropdown_value_vs_index() -> void:
	var doc := _load_review()
	await h.process_frame
	var res: UxmlPopupField = doc.get_native("res")
	h.eq(res.selected, -1, "value=1080 in UXML selects nothing, as in Unity")
	res.behavior.bind_write("value", "1080")
	h.eq(res.selected, 1, "a runtime value selects the choice TEXT, not index 1080")
	var idx: UxmlPopupField = doc.get_native("byindex")
	h.eq(idx.get_item_text(idx.selected), "720", "index=0 selects positionally")
	_unload(doc)


# Authored padding+border inset the internal chrome: field caption/native
# start inside the content box; native text gets stylebox content margins;
# an Image's texture rect insets inside its box.
func test_field_content_insets() -> void:
	var doc := _load_review()
	await h.process_frame
	# The fields are part trees: the label part and the input part sit in
	# the field's content box, so padding insets them like any children.
	for n in ["padded", "padslider", "paddd"]:
		var model := doc.get_element_model(n)
		var cap: Control = doc._controls[UxmlParts.find_part(model, "label")]
		var inp: Control = doc._controls[UxmlParts.find_part(model, "input")]
		h.check(cap.position.x >= 11.5 and cap.position.y >= 5.5,
			"%s label inset by padding (pos %s)" % [n, cap.position])
		# Without the theme a field is a column (Unity's row direction is a
		# theme rule), so the input starts at the content box too.
		h.check(inp.position.x >= 11.5 and inp.position.y >= cap.position.y,
			"%s input inside the content box (pos %s)" % [n, inp.position])

	var lbl := doc.get_element("padlabel") as Label
	var sb: StyleBox = lbl.get_theme_stylebox("normal")
	h.check(sb != null and sb.content_margin_left >= 11.5,
		"label text margin from authored padding")

	var tr := doc.get_native("padimg") as TextureRect
	h.check(tr.offset_left >= 9.5 and tr.offset_top >= 9.5,
		"image texture inset inside its box (off %s,%s)" % [tr.offset_left, tr.offset_top])
	_unload(doc)


# A checked toggle carries the :checked stylebox on the real skin, and
# unchecking restores the un-bordered base skin.
func test_checked_skin_restores() -> void:
	var doc := _load()
	await h.process_frame
	var mute: UxmlToggle = doc.get_native("mute")
	# The Toggle paints its own USS box (UxmlBox.box_style).
	var sb0 := mute.box_style as StyleBoxFlat
	h.check(sb0 != null and sb0.border_width_top >= 3,
		"checked applies the :checked box")
	mute.button_pressed = false
	await h.process_frame
	await h.process_frame
	var sb1 := mute.box_style as StyleBoxFlat
	var still := sb1 != null and sb1.border_width_top >= 3
	h.check(not still, "unchecked removes the :checked border skin")
	mute.button_pressed = true
	await h.process_frame
	await h.process_frame
	var sb2 := mute.box_style as StyleBoxFlat
	h.check(sb2 != null and sb2.border_width_top >= 3,
		"re-checked restores the :checked skin")
	_unload(doc)


# focusable=true on UNWRAPPED elements: real Tab reaches the control
# itself — there is no wrapper that could add a stray tab stop, and the
# authored attribute must not be re-clamped by the applier.
func test_focusable_unwrapped_tab() -> void:
	var doc := _load_review()
	await h.process_frame
	var ve := doc.get_element("focusve")
	var lbl := doc.get_element("focuslabel") as Label
	h.eq(ve.focus_mode, Control.FOCUS_ALL, "focusable=true on plain VisualElement")
	h.eq(lbl.focus_mode, Control.FOCUS_ALL, "focusable=true on plain Label")
	h.eq(doc.get_element("unfocuslabel").focus_mode, Control.FOCUS_NONE,
		"default Label stays unfocusable")

	ve.grab_focus()
	await h.process_frame
	h.eq(_focus_owner(), ve, "plain VisualElement takes real focus")
	await h.process_frame
	h.check(_style_has(doc, "focusve", "border-top-width", "4px"),
		":focus style resolves for unwrapped VisualElement")

	_send_key(KEY_TAB)
	await h.process_frame
	await h.process_frame
	h.eq(_focus_owner(), lbl, "Tab reaches the focusable Label itself")
	h.check(_style_has(doc, "focuslabel", "border-top-width", "4px"),
		":focus style resolves for unwrapped Label")
	h.check(not _style_has(doc, "focusve", "border-top-width", "4px"),
		"previous element loses :focus")

	_send_key(KEY_TAB, true)
	await h.process_frame
	h.eq(_focus_owner(), ve, "Shift-Tab returns to the VisualElement")
	_unload(doc)


# Percentage padding resolves against the containing block width for the
# box layout — the SAME resolved insets must reach native text margins,
# and must re-resolve on resize.
func test_percent_padding_native_text() -> void:
	var doc := _load_review()
	await h.process_frame
	await h.process_frame
	# doc 400 wide -> .screen 400 -> .pctrow 200 -> padding-left 10% = 20,
	# padding-top 5% = 10 (percent edges use the cb WIDTH on every side).
	for n in ["pctlabel", "pctbtn"]:
		var c := doc.get_element(n)
		h.check(c.has_theme_stylebox_override("normal"),
			"%s has a stylebox to carry margins" % n)
		var sb: StyleBox = c.get_theme_stylebox("normal")
		if sb != null:
			h.check(absf(sb.content_margin_left - 20.0) < 1.0,
				"%s left margin = resolved 10%% of 200 (got %s)" % [n, sb.content_margin_left])
			# The row is shrunk below the Button's text and padding, so the
			# Button's vertical margins are fitted to its box (Unity draws
			# the text over the box; UxmlStyleApplier.fit_button): only the
			# Label keeps the resolved top padding as its margin.
			if not c.has_meta(&"uxml_bfit"):
				h.check(absf(sb.content_margin_top - 10.0) < 1.0,
					"%s top margin = resolved 5%% of 200 (got %s)" % [n, sb.content_margin_top])
			else:
				h.check(sb.content_margin_top < 10.0 and absf(c.size.y - c.get_minimum_size().y) < 0.5,
					"%s fitted: a top margin under the resolved 10 (got %s), the box at its text and margins" % [n, sb.content_margin_top])

	doc.size = Vector2(800, 600)
	await h.process_frame
	await h.process_frame
	var sb2: StyleBox = doc.get_element("pctlabel").get_theme_stylebox("normal")
	h.check(sb2 != null and absf(sb2.content_margin_left - 40.0) < 1.0,
		"resize re-resolves percent margins to 10%% of 400 (got %s)" % [
			null if sb2 == null else sb2.content_margin_left])
	_unload(doc)


# url() font -> no-url bold -> normal: the variation must base on the real
# theme font captured before any override — never on the earlier url()
# font — and clearing the style restores that theme font exactly.
func test_font_source_transitions() -> void:
	var doc := _load_review()
	await h.process_frame
	await h.process_frame
	var btn := doc.get_element("fontswap") as Button
	h.check(btn.has_meta("uxml_base_font_set"), "base font captured at first apply")
	var theme_font: Font = btn.get_meta("uxml_base_font")
	h.check(theme_font != null, "captured base is a real theme font")

	var f1 := btn.get_theme_font("font")
	h.check(f1 != null and not (f1 is FontVariation),
		"url() font applied as a plain override")
	h.check(f1 != theme_font, "url() font is not the theme font")

	doc.set_class("fontswap", "fontbold")
	await h.process_frame
	await h.process_frame
	var f2 := btn.get_theme_font("font")
	h.check(f2 is FontVariation, "bold without url produces a FontVariation")
	if f2 is FontVariation:
		h.eq(f2.base_font, theme_font,
			"variation bases on theme font, not the earlier url() font")

	doc.set_class("fontswap", "")
	await h.process_frame
	await h.process_frame
	h.check(not btn.has_theme_font_override("font"),
		"font override fully removed")
	h.eq(btn.get_theme_font("font"), theme_font, "theme font restored")

	# Repeat the whole cycle: the base is still the theme font, still one
	# variation deep — no stale fontA and no nesting.
	doc.set_class("fontswap", "fonturl")
	await h.process_frame
	await h.process_frame
	doc.set_class("fontswap", "fontbold")
	await h.process_frame
	await h.process_frame
	var f3 := btn.get_theme_font("font")
	h.check(f3 is FontVariation and f3.base_font == theme_font,
		"second cycle still bases on the theme font")
	_unload(doc)


# -unity-text-align and white-space must restore the recorded defaults
# when the state carrying them ends — the same restoration the
# caption/stylebox paths already have.
func test_align_wrap_reset() -> void:
	var doc := _load_review()
	await h.process_frame
	var lbl := doc.get_element("alignreset") as Label
	var h0: int = lbl.horizontal_alignment
	var w0: int = lbl.autowrap_mode

	doc.set_element_state("alignreset", "hover", true)
	await h.process_frame
	await h.process_frame
	h.eq(lbl.horizontal_alignment, HORIZONTAL_ALIGNMENT_RIGHT,
		"hover applies middle-right horizontal alignment")
	h.eq(lbl.autowrap_mode, TextServer.AUTOWRAP_OFF,
		"hover nowrap disables autowrap")

	doc.set_element_state("alignreset", "hover", false)
	await h.process_frame
	await h.process_frame
	h.eq(lbl.horizontal_alignment, h0, "alignment restored on state clear")
	h.eq(lbl.autowrap_mode, w0, "autowrap restored on state clear")
	_unload(doc)


# Authored dims smaller than the native/chrome minimum: Yoga semantics
# keep the authored box — the native content simply overflows inside it.
func test_small_authored_native_geometry() -> void:
	var doc := _load_review()
	await h.process_frame
	await h.process_frame
	var img := doc.get_element("smallimg")
	h.check(img.size.x <= 4.5 and img.size.y <= 4.5,
		"authored 4px Image not clamped to texture min (got %s)" % img.size)
	var tr := doc.get_native("smallimg") as TextureRect
	h.check(tr != null and tr.size.x <= 4.5,
		"inner texture tracks the authored box")
	var fld := doc.get_element("smallsl")
	h.check(fld.size.x <= 4.5 and fld.size.y <= 4.5,
		"authored 4px field not clamped to caption+native min (got %s)" % fld.size)
	_unload(doc)


# The border box never shrinks below the resolved padding+border total —
# a flex item's CONTENT may reach 0 but the insets are a real floor on
# real native controls too (Yoga: 20px row, w80 child, 24+4 insets -> 28).
func test_padding_border_floor_native() -> void:
	var doc := _load_review()
	await h.process_frame
	await h.process_frame
	var a := doc.get_element("padfloor")
	h.check(absf(a.size.x - 28.0) < 1.0,
		"shrink stops at pad+border floor 28, not 20 (got %s)" % a.size.x)
	_unload(doc)


# A texture stylebox carries inherited content_margin_* — USS padding
# must inset native text through it, NOT through texture_margin (which is
# nine-patch source slicing). The margins meta keeps the intrinsic
# measure from counting the resolved padding twice.
func test_texture_stylebox_percent_insets() -> void:
	var doc := _load_review()
	await h.process_frame
	await h.process_frame
	var btn := doc.get_element("bgbtn") as Button
	var sb := btn.get_theme_stylebox("normal")
	# The theme's fill and border with the image between them, as Unity
	# draws a Button with a background image: a UxmlBoxStyle and its image.
	var img: StyleBox = (sb as UxmlBoxStyle).image if sb is UxmlBoxStyle else sb
	h.check(img is StyleBoxTexture, "background-image produces a texture stylebox")
	h.check(absf(sb.content_margin_left - 20.0) < 1.0,
		"resolved percent padding lands on content_margin (got %s)" % sb.content_margin_left)
	h.check(absf((img as StyleBoxTexture).texture_margin_left) < 0.01,
		"texture_margin nine-patch slicing untouched (got %s)" % (img as StyleBoxTexture).texture_margin_left)
	h.check(sb.has_meta("uxml_margins"),
		"margins meta present so measure does not double-count insets")

	var flat := doc.get_element("pctbtn")
	h.check(absf(btn.size.x - flat.size.x) < 1.5,
		"same authored insets -> same auto width, no double count (%s vs %s)"
			% [btn.size.x, flat.size.x])

	doc.size = Vector2(800, 600)
	await h.process_frame
	await h.process_frame
	var sb2 := btn.get_theme_stylebox("normal")
	h.check((sb2 is StyleBoxTexture or (sb2 is UxmlBoxStyle and (sb2 as UxmlBoxStyle).image is StyleBoxTexture))
		and absf(sb2.content_margin_left - 40.0) < 1.0,
		"resize re-resolves texture stylebox content margins")
	_unload(doc)


# Virtualized ListView: a fixed pool of template rows covers the viewport;
# scrolling re-binds them to item indices instead of creating nodes.
func test_list_view_virtualization() -> void:
	var doc := UxmlDocument.new()
	doc.theme_path = ""  # geometry below is authored USS only (see header)
	h.root.add_child(doc)
	doc.size = Vector2(400, 600)
	doc.load_document("Assets/UI/list.uxml", FIXTURE)
	var bound := {}
	doc.set_list_source("items", 10000, func(row: UxmlListRow, i: int):
		bound[i] = true
		(row.get_native("title") as Label).text = "Item %d" % i
		(row.get_native("value") as Label).text = str(i * 2))
	await h.process_frame
	await h.process_frame
	var rows: Array = doc.get_list_rows("items")
	# Updated with unity/fidelity: the rows in use follow the viewport as in
	# Unity's FixedHeight Resize, floor(viewport / item height) + 2.
	var lsv: UxmlElement = UxmlContainerParts.get_part(doc.get_element_model("items"), "scroll-view")
	var lvp: Control = doc._controls[UxmlContainerParts.get_part(lsv, "viewport")]
	h.eq(rows.size(), int(floor(lvp.size.y / 24.0)) + 2,
		"rows cover the viewport, not the item count (%d rows)" % rows.size())
	h.eq(_warn_kinds(doc).has("unsupported-control"), false, "ListView is a known control")
	h.eq(_warn_kinds(doc).has("duplicate-name"), false, "pooled rows do not report duplicate names")
	var r0: UxmlListRow = rows[0]
	h.eq(r0.index, 0, "slot 0 shows item 0")
	h.eq((r0.get_native("title") as Label).text, "Item 0", "bind filled row 0")
	h.check(bound.size() <= rows.size(), "only visible rows were bound (%d)" % bound.size())
	# Updated with unity/controls-containers: the ListView is Unity's part
	# tree (a ScrollView inside); its content container is as tall as every
	# item, and scrolling is the ScrollView offset.
	var sv: UxmlElement = UxmlContainerParts.get_part(doc.get_element_model("items"), "scroll-view")
	var content: Control = doc._controls[UxmlContainerParts.get_part(sv, "content")]
	h.check(absf(content.size.y - 10000 * 24.0) < 1.0,
		"content is as tall as every item (%s)" % content.size.y)
	var y0: float = (r0.get_element() as Control).position.y
	# Scroll to item 100.
	doc.set_scroll_offset("items", Vector2(0, 2400))
	await h.process_frame
	await h.process_frame
	# Rows recycle Unity-style: item i lives in slot i % pool, so rows still
	# in view keep their items and only scrolled-out rows are re-bound.
	var shown := {}
	var r100: UxmlListRow = null
	for r in rows:
		var rr: UxmlListRow = r
		if rr.index >= 0:
			shown[rr.index] = true
		if rr.index == 100:
			r100 = rr
	h.check(r100 != null, "after scrolling, a row shows item 100")
	h.check(shown.has(100) and shown.has(100 + rows.size() - 1) and not shown.has(99),
		"the pool covers items 100.. contiguously")
	if r100 != null:
		h.eq((r100.get_native("title") as Label).text, "Item 100", "item 100 bound into its row")
		h.check(absf((r100.get_element() as Control).position.y - (y0 + 2400.0)) < 0.5,
			"row placed at its item's position (%s)" % (r100.get_element() as Control).position.y)
	h.check(r0.element.class_list().has("unity-collection-view__item"),
		"rows carry Unity's item class")
	# (Updated with unity/controls-containers: the pool size follows Unity's
	# floor(height / item height) + 2, so look the odd item up by index.)
	var odd: UxmlListRow = null
	var even: UxmlListRow = null
	for r in rows:
		var rr: UxmlListRow = r
		if rr.index >= 0 and rr.index % 2 == 1 and odd == null:
			odd = rr
		elif rr.index >= 0 and rr.index % 2 == 0 and even == null:
			even = rr
	h.check(odd != null and odd.element.class_list().has("unity-collection-view__item--alternative-background"),
		"odd items get the alternating-row class")
	h.check(even != null and not even.element.class_list().has("unity-collection-view__item--alternative-background"),
		"even items do not")
	# Fewer items than slots: the rest are display:none.
	doc.set_list_source("items", 3, func(row: UxmlListRow, i: int):
		(row.get_native("title") as Label).text = "Few %d" % i)
	await h.process_frame
	await h.process_frame
	h.eq((rows[0] as UxmlListRow).index, 0, "short list starts at item 0")
	h.eq((rows[5].get_element() as Control).visible, false, "unused slots are hidden")
	h.eq((rows[2].get_element() as Control).visible, true, "used slots are visible")
	_unload(doc)



## A layout hook whose writes change the sizes it reads alternates between
## two results (a MinMaxSlider's dragger given the min thumb's class, the max
## thumb without its own): each write queued a deferred restyle that the
## message queue ran in the same flush, forever, until the call queue
## overflowed and the process crashed (bench/equiv_v2.gd, ctl-hover-minmax).
## The restyles queued in one frame are bounded; the rest run one per frame.
func test_alternating_layout_hook_is_bounded_per_frame() -> void:
	var dir := UxmlBenchDir.of("godot_uxml_runtime_tests") + "/hook"
	DirAccess.make_dir_recursive_absolute(dir + "/Assets")
	var f := FileAccess.open(dir + "/Assets/mm.uxml", FileAccess.WRITE)
	f.store_string('<ui:UXML xmlns:ui="UnityEngine.UIElements"><ui:MinMaxSlider name="h" label="Hover" min-value="2" max-value="6" low-limit="0" high-limit="10" /></ui:UXML>')
	f.close()
	var doc := UxmlDocument.new()
	h.root.add_child(doc)
	doc.size = Vector2(640, 480)
	doc.load_document("Assets/mm.uxml", dir)
	await h.process_frame
	var mm := doc.get_element_model("h")
	var dragger := UxmlParts.find_part(mm, "dragger")
	var thumb := UxmlParts.find_part(mm, "thumb-max")
	var label := UxmlParts.find_part(mm, "label")
	label.set_attribute("class", "unity-base-field__label unity-min-max-slider__label unity-min-max-slider__max-thumb")
	await h.process_frame
	dragger.set_attribute("class", "unity-min-max-slider__dragger unity-min-max-slider__min-thumb")
	await h.process_frame
	thumb.set_attribute("class", "")
	for k in 4:
		await h.process_frame
	h.check(doc._rq_count <= UxmlDocument._MAX_RESTYLES_PER_FRAME + 1, "restyles queued in a frame stay bounded (%d)" % doc._rq_count)
	h.check(is_instance_valid(doc) and doc.get_element_model("h") != null, "the document survives the alternating hook")
	h.root.remove_child(doc)
	doc.queue_free()
