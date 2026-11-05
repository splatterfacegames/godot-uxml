extends RefCounted
## Input controls (runtime/controls/uxml_input_parts.gd and
## uxml_input_behaviors.gd): part trees, theme, keyboard, controller and
## pointer input, values, data binding. Expected values come from Unity
## 6000.3 (bench/parity/unity/ctl-slider*.json, ctl-textfield*,
## ctl-numeric*, ctl-dropdown*, ctl-minmaxslider, ctl-focus-minmax and
## bench/parity/probes/numeric.json).
##
## `h` is the SceneTree harness from run_tests.gd.

const TMP := "user://godot_uxml_inputs_tests"

var h = null


func _init(harness) -> void:
	h = harness


func _doc(body: String, uss := "") -> UxmlDocument:
	DirAccess.make_dir_recursive_absolute(TMP + "/Assets")
	var style := ""
	if not uss.is_empty():
		var f := FileAccess.open(TMP + "/Assets/t.uss", FileAccess.WRITE)
		f.store_string(uss)
		f.close()
		style = '<Style src="t.uss" />'
	var x := FileAccess.open(TMP + "/Assets/t.uxml", FileAccess.WRITE)
	x.store_string('<ui:UXML xmlns:ui="UnityEngine.UIElements">%s%s</ui:UXML>' % [style, body])
	x.close()
	var doc := UxmlDocument.new()
	h.root.add_child(doc)
	doc.size = Vector2(400, 600)
	doc.load_document("Assets/t.uxml", TMP)
	return doc


func _unload(doc: UxmlDocument) -> void:
	h.root.remove_child(doc)
	doc.queue_free()


func _part(doc: UxmlDocument, owner: String, role: String) -> UxmlElement:
	return UxmlParts.find_part(doc.get_element_model(owner), role)


func _val(doc: UxmlDocument, el: UxmlElement, prop: String) -> String:
	var e = doc._styles.get(el, {}).get(prop)
	return "" if e == null else String(e["value"])


func _classes(el: UxmlElement) -> Array:
	var out := []
	for c in el.class_list():
		out.append(c)
	for c in UssControls.implicit_classes_of(el.local):
		if not out.has(c):
			out.append(c)
	out.sort()
	return out


func _sorted(a: Array) -> Array:
	var b := a.duplicate()
	b.sort()
	return b


func _action(c: Control, action: String, shift := false) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	c._gui_input(ev)
	if shift:
		pass


func _key(c: Control, keycode: int, shift := false) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = true
	ev.shift_pressed = shift
	c._gui_input(ev)


## A real key press through Input, delivered to the focused control.
func _press_key(keycode: int) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = keycode
		ev.physical_keycode = keycode
		ev.pressed = pressed
		Input.parse_input_event(ev)
	await h.process_frame
	await h.process_frame


func _mouse(c: Control, pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	c._gui_input(ev)


func _motion(c: Control, pos: Vector2, rel := Vector2.ZERO) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.relative = rel
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	c._gui_input(ev)


## Position of `x`'s centre in `c`'s local space.
func _center_in(c: Control, x: Control) -> Vector2:
	return c.get_global_transform().affine_inverse() * (x.get_global_transform() * (x.size / 2.0))


# ---------------------------------------------------------------------------
# Numeric rules
# ---------------------------------------------------------------------------

func test_numeric_rules_match_unity_probe() -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://bench/parity/probes/numeric.json"))
	var bad := 0
	var n := 0
	for r in d["rows"]:
		var t: String = r["type"]
		var txt := ""
		if r.has("input"):
			var cur = UxmlNumeric.parse_attr(t, r["initial"])
			txt = UxmlNumeric.format(t, UxmlNumeric.evaluate(t, r["input"], r["initial"], cur))
		else:
			var f := String(r["format"])
			var v: Variant = int(f) if t == "IntegerField" else (NAN if f == "NaN" else (INF if f == "Infinity" else (-INF if f == "-Infinity" else f.to_float())))
			if t == "FloatField":
				v = UxmlNumeric.to_f32(v)
			txt = UxmlNumeric.format(t, v)
		n += 1
		if txt != String(r["text"]):
			bad += 1
			print("  numeric mismatch: %s %s -> %s (Unity %s)" % [t, r.get("input", r.get("format")), txt, r["text"]])
	h.eq(bad, 0, "all %d Unity probe rows (parse, expressions, format)" % n)
	h.check(n > 400, "probe rows read")
	# Typed values.
	h.eq(UxmlNumeric.evaluate("IntegerField", "2*3", "10", 10), 6, "2*3 on an IntegerField")
	h.eq(UxmlNumeric.evaluate("FloatField", "+=1", "1.5", 1.5), 2.5, "+= uses the text before the edit")
	h.eq(UxmlNumeric.format("UnsignedLongField", UxmlNumeric.parse_attr("UnsignedLongField", "18446744073709551615")),
		"18446744073709551615", "UnsignedLongField keeps 64 bits")
	h.eq(UxmlNumeric.f32_clean(5.1), 5.1, "a float value reads as its shortest decimal form")


# ---------------------------------------------------------------------------
# Slider, SliderInt
# ---------------------------------------------------------------------------

func test_slider_part_tree() -> void:
	var doc := _doc('<ui:Slider name="s" label="Vol" low-value="0" high-value="10" value="3" fill="true" show-input-field="true" />'
		+ '<ui:SliderInt name="v" direction="Vertical" low-value="0" high-value="10" value="2" style="height: 100px;" />')
	var el := doc.get_element_model("s")
	h.eq(_classes(el), _sorted(["unity-base-field", "unity-base-slider", "unity-base-slider--horizontal", "unity-slider"]), "Slider classes")
	var label := _part(doc, "s", "label")
	h.eq(_classes(label), _sorted(["unity-text-element", "unity-label", "unity-base-field__label", "unity-base-slider__label",
		"unity-base-field__label--with-dragger", "unity-slider__label"]), "label classes (label dragger)")
	var input := _part(doc, "s", "input")
	h.eq(input.children.size(), 2, "input: drag container + text field")
	var drag := _part(doc, "s", "drag-container")
	h.eq(drag.get_attribute("name"), "unity-drag-container", "drag container name")
	var names := []
	for c in drag.children:
		names.append(c.get_attribute("name"))
	h.eq(names, ["unity-tracker", "unity-dragger-border", "unity-dragger"], "drag container parts (Unity order)")
	var fill := _part(doc, "s", "fill")
	h.check(fill != null and fill.get_attribute("name") == "unity-fill", "fill part")
	h.eq(_part(doc, "s", "tracker").children.has(fill), true, "fill inside the tracker")
	h.eq(String(fill.get_attribute("style")), "top: 0px; bottom: 0px; left: 0px; right: 70%;", "fill: the unfilled share as right %")
	var tf := _part(doc, "s", "text-field")
	h.eq(tf.local, "TextField", "show-input-field adds a TextField part")
	h.eq(tf.get_attribute("name"), "unity-text-field", "text field name")
	h.check(tf.class_list().has("unity-base-slider__text-field"), "text field class")
	var v := doc.get_element_model("v")
	h.check(v.class_list().has("unity-base-slider--vertical") and not v.class_list().has("unity-base-slider--horizontal"),
		"direction=Vertical: --vertical class")
	h.eq(UxmlParts.find_part(v, "label"), null, "no label part without a label")
	h.check(v.class_list().has("unity-base-field--no-label"), "--no-label")
	# Theme.
	h.eq(_val(doc, _part(doc, "s", "tracker"), "height"), "6px", "tracker height")
	h.eq(_val(doc, _part(doc, "s", "dragger"), "width"), "8px", "dragger width")
	h.eq(_val(doc, _part(doc, "s", "dragger-border"), "display"), "none", "dragger border hidden")
	h.eq(_val(doc, UxmlParts.find_part(v, "dragger"), "height"), "8px", "vertical dragger height")
	_unload(doc)


func test_slider_dragger_follows_value_and_layout() -> void:
	var doc := _doc('<ui:Slider name="s" low-value="0" high-value="10" value="3" />')
	await h.process_frame
	var dc := doc._controls[_part(doc, "s", "drag-container")] as Control
	var dg := _part(doc, "s", "dragger")
	var want := 0.3 * (dc.size.x - 8.0)
	var style := String(dg.get_attribute("style"))
	h.check(style.begins_with("translate: "), "the dragger is placed with translate (Unity: style.translate)")
	var x := style.trim_prefix("translate: ").split(" ")[0].trim_suffix("px").to_float()
	h.check(absf(x - want) < 0.01, "translate = value share of (container - dragger): %s vs %s" % [x, want])
	h.eq(_part(doc, "s", "dragger-border").get_attribute("style"), dg.get_attribute("style"), "the dragger border moves too")
	# A wider document moves the dragger after the layout.
	doc.size = Vector2(800, 600)
	await h.process_frame
	await h.process_frame
	var x2 := String(dg.get_attribute("style")).trim_prefix("translate: ").split(" ")[0].trim_suffix("px").to_float()
	h.check(absf(x2 - 0.3 * (dc.size.x - 8.0)) < 0.01 and x2 > x, "layout change moves the dragger")
	_unload(doc)


func test_slider_keyboard_matches_unity() -> void:
	# Expected values: bench/parity/unity/ctl-slider-keys.json.
	var doc := _doc('<ui:Slider name="a" low-value="0" high-value="10" value="5" />'
		+ '<ui:Slider name="b" low-value="0" high-value="1" value="0.33" />'
		+ '<ui:SliderInt name="c" low-value="0" high-value="1000" value="500" />'
		+ '<ui:Slider name="d" low-value="0" high-value="10" value="5" inverted="true" />'
		+ '<ui:Slider name="e" direction="Vertical" low-value="0" high-value="10" value="5" style="height: 60px;" />'
		+ '<ui:Slider name="f" low-value="0" high-value="100" value="50" page-size="3" />')
	await h.process_frame
	var events := []
	doc.value_changed.connect(func(n, v): events.append([n, v]))
	var a: UxmlSlider = doc.get_native("a")
	a.grab_focus()
	await h.process_frame
	h.check(UxmlParts.control_classes(_part(doc, "a", "dragger")).has("unity-base-slider--movable"), "focus: dragger --movable")
	h.check(doc._states.get(_part(doc, "a", "input"), {}).has("focus"), "focus on the input part too")
	_action(a, "ui_right")
	h.eq(a.value, 5.1, "Right: 5 -> 5.1 (1/100 of the range, power of ten)")
	_action(a, "ui_left")
	_action(a, "ui_left")
	h.eq(a.value, 4.9, "Left twice")
	var b: UxmlSlider = doc.get_native("b")
	b.grab_focus()
	_action(b, "ui_right")
	h.eq(b.value, 0.34, "0.33 -> 0.34")
	var c: UxmlSlider = doc.get_native("c")
	c.grab_focus()
	_action(c, "ui_right")
	h.eq(c.value, 510.0, "SliderInt 500 -> 510")
	h.eq(typeof(doc.get_native("c").behavior.get_value()), TYPE_INT, "SliderInt value is an int")
	var d: UxmlSlider = doc.get_native("d")
	d.grab_focus()
	_action(d, "ui_right")
	h.eq(d.value, 4.9, "inverted: Right lowers the value")
	var e: UxmlSlider = doc.get_native("e")
	e.grab_focus()
	_action(e, "ui_up")
	h.eq(e.value, 5.1, "vertical: Up raises the value")
	_key(e, KEY_HOME)
	h.eq(e.value, 10.0, "vertical: Home -> highest")
	_key(a, KEY_END)
	h.eq(a.value, 10.0, "End -> highest")
	var f: UxmlSlider = doc.get_native("f")
	f.grab_focus()
	_key(f, KEY_PAGEDOWN)
	h.eq(f.value, 51.0, "PageDown: page-size x 1/100 of the range (Unity: 50 -> 51)")
	# ui_accept toggles --movable; arrows then pass to focus navigation.
	a.grab_focus()
	_action(a, "ui_accept")
	h.check(not UxmlParts.control_classes(_part(doc, "a", "dragger")).has("unity-base-slider--movable"), "submit clears --movable")
	var before := a.value
	_action(a, "ui_left")
	h.eq(a.value, before, "not movable: arrows do not change the value")
	h.check(events.size() >= 8, "value_changed per change")
	h.eq(typeof(events[0][1]), TYPE_FLOAT, "Slider value_changed sends a float")
	_unload(doc)


func test_slider_controller_and_real_keys() -> void:
	var doc := _doc('<ui:Slider name="a" low-value="0" high-value="10" value="5" />')
	await h.process_frame
	var a: UxmlSlider = doc.get_native("a")
	a.grab_focus()
	await h.process_frame
	await _press_key(KEY_RIGHT)
	h.eq(a.value, 5.1, "a real Right key press")
	h.eq(a.get_viewport().gui_get_focus_owner(), a, "focus stays on the slider")
	for pressed in [true, false]:
		var j := InputEventJoypadButton.new()
		j.button_index = JOY_BUTTON_DPAD_RIGHT
		j.pressed = pressed
		Input.parse_input_event(j)
	await h.process_frame
	await h.process_frame
	h.eq(a.value, 5.2, "joypad d-pad right")
	_unload(doc)


func test_slider_pointer() -> void:
	# Click jumps the dragger centre to the pointer (page-size 0), then drags.
	var doc := _doc('<ui:Slider name="s" low-value="0" high-value="10" value="5" />'
		+ '<ui:SliderInt name="p" low-value="0" high-value="10" value="5" page-size="2" />')
	await h.process_frame
	var s: UxmlSlider = doc.get_native("s")
	var dc := doc._controls[_part(doc, "s", "drag-container")] as Control
	var origin := s.get_global_transform().affine_inverse() * dc.get_global_position()
	_mouse(s, origin + Vector2(4.0 + 0.2 * (dc.size.x - 8.0), dc.size.y / 2.0), true)
	h.check(absf(s.value - 2.0) < 0.05, "click at 20%% of the track: value 2 (got %s)" % s.value)
	h.check(s.value != roundf(s.value) or absf(s.value - 2.0) < 0.05, "continuous value")
	h.check(doc._states.get(_part(doc, "s", "drag-container"), {}).has("active"), "drag container :active while pressed")
	_motion(s, origin + Vector2(4.0 + 0.55 * (dc.size.x - 8.0), dc.size.y / 2.0))
	h.check(absf(s.value - 5.5) < 0.05, "drag to 55%%: value 5.5, not snapped to 1 (got %s)" % s.value)
	_mouse(s, origin + Vector2(4.0 + 0.55 * (dc.size.x - 8.0), dc.size.y / 2.0), false)
	h.check(not doc._states.get(_part(doc, "s", "drag-container"), {}).has("active"), ":active cleared on release")
	# SliderInt with page-size pages toward the pointer.
	var p: UxmlSlider = doc.get_native("p")
	var pc := doc._controls[_part(doc, "p", "drag-container")] as Control
	var po := p.get_global_transform().affine_inverse() * pc.get_global_position()
	_mouse(p, po + Vector2(pc.size.x - 2.0, pc.size.y / 2.0), true)
	h.eq(p.value, 7.0, "page-size 2: one page toward the click (Unity: 5 -> 7)")
	_mouse(p, po + Vector2(pc.size.x - 2.0, pc.size.y / 2.0), false)
	_unload(doc)


func test_slider_label_drag_and_input_field() -> void:
	var doc := _doc('<ui:Slider name="s" label="L" low-value="0" high-value="100" value="50" show-input-field="true" />')
	await h.process_frame
	var s: UxmlSlider = doc.get_native("s")
	var lc := doc._controls[_part(doc, "s", "label")] as Control
	var at := _center_in(s, lc)
	_mouse(s, at, true)
	_motion(s, at + Vector2(10, 0), Vector2(10, 0))
	h.check(absf(s.value - 50.3) < 0.001, "label drag: +10px x range/100 x 0.03 (got %s)" % s.value)
	_mouse(s, at + Vector2(10, 0), false)
	var tf := _part(doc, "s", "text-field")
	var tb = doc._behaviors[tf]
	h.eq(tb.text(), "50.3", "input field shows the value (g7)")
	var le := doc._controls[UxmlParts.find_part(tf, "editor")] as LineEdit
	le.grab_focus()
	le.text = "2*10"
	le.text_changed.emit("2*10")
	h.eq(s.value, 20.0, "typing an expression sets the slider")
	_unload(doc)


func test_slider_value_attribute_and_get_native() -> void:
	var doc := _doc('<ui:Slider name="s" low-value="0" high-value="1" value="0.25" />')
	await h.process_frame
	var s := doc.get_native("s")
	h.check(s is UxmlSlider, "get_native returns the slider control")
	h.eq((s as UxmlSlider).value, 0.25, "a float Slider keeps 0.25 (no step 1)")
	doc.get_element_model("s").set_attribute("value", "0.75")
	h.eq((s as UxmlSlider).value, 0.75, "the value attribute after load")
	(s as UxmlSlider).value = 2.0
	h.eq((s as UxmlSlider).value, 1.0, "values clamp to the range")
	_unload(doc)


# ---------------------------------------------------------------------------
# MinMaxSlider
# ---------------------------------------------------------------------------

func test_min_max_slider() -> void:
	var doc := _doc('<ui:MinMaxSlider name="m" label="R" min-value="2" max-value="6" low-limit="0" high-limit="10" />')
	await h.process_frame
	var el := doc.get_element_model("m")
	var names := []
	for x in UxmlParts.find_part(el, "dragger").children:
		names.append(x.get_attribute("name"))
	h.eq(names, ["unity-thumb-min", "unity-thumb-max"], "thumb parts")
	var dg := UxmlParts.find_part(el, "dragger")
	h.check(String(dg.get_attribute("style")).begins_with("left: "), "dragger box from the layout")
	var events := []
	doc.value_changed.connect(func(n, v): events.append(v))
	var c: UxmlSlider = doc.get_native("m")
	c.grab_focus()
	h.check(UxmlParts.control_classes(UxmlParts.find_part(el, "thumb-min")).has("unity-min-max-slider--movable"),
		"focus: the min thumb is movable (ctl-focus-minmax)")
	_action(c, "ui_right")
	h.eq(events.back(), Vector2(2.1, 6.0), "Right moves the min thumb by 1/100 of the range")
	_action(c, "ui_accept")
	_action(c, "ui_accept")
	_action(c, "ui_left")
	h.eq(events.back(), Vector2(2.0, 5.9), "middle state moves both thumbs")
	h.eq(typeof(events.back()), TYPE_VECTOR2, "value_changed sends a Vector2")
	_unload(doc)


# ---------------------------------------------------------------------------
# TextField
# ---------------------------------------------------------------------------

func test_text_field_part_tree_and_theme() -> void:
	var doc := _doc('<ui:TextField name="t" label="Name" value="Ada" />'
		+ '<ui:TextField name="p" label="Hint" placeholder-text="Type here" />'
		+ '<ui:TextField name="m" multiline="true" value="a&#10;b" />')
	await h.process_frame
	var input := _part(doc, "t", "input")
	h.eq(input.local, "TextInput", "the input part is a TextInput")
	h.eq(input.get_attribute("name"), "unity-text-input", "input name")
	h.eq(_classes(input), _sorted(["unity-base-text-field__input", "unity-base-text-field__input--single-line",
		"unity-base-field__input", "unity-text-field__input"]), "input classes")
	var ed := _part(doc, "t", "editor")
	h.eq(_classes(ed), _sorted(["unity-text-element", "unity-text-element__selectable",
		"unity-text-element--inner-input-field-component"]), "text element classes")
	h.check(doc.get_native("t") is LineEdit, "get_native: the LineEdit")
	h.eq((doc.get_native("t") as LineEdit).text, "Ada", "value")
	h.check(_part(doc, "p", "input").class_list().has("unity-base-text-field__input--placeholder"), "--placeholder class")
	h.eq(_val(doc, _part(doc, "p", "input"), "color"), "rgb(88, 88, 88)", "placeholder colour")
	h.check(doc.get_native("m") is TextEdit, "multiline: TextEdit")
	h.check(_part(doc, "m", "multiline-container") != null, "multiline container part")
	# Caret and selection colours from the custom properties.
	var le := doc.get_native("t") as LineEdit
	h.eq(le.get_theme_color("caret_color"), Color(0, 0, 0), "--unity-cursor-color")
	h.check(le.get_theme_color("selection_color").is_equal_approx(Color(61 / 255.0, 128 / 255.0, 223 / 255.0, 0.65)),
		"--unity-selection-color")
	_unload(doc)


func test_text_field_custom_colours_follow_the_cascade() -> void:
	var doc := _doc('<ui:TextField name="t" class="x" value="a" />',
		'.x { --unity-cursor-color: rgb(255, 0, 0); --unity-selection-color: rgb(0, 255, 0); }'
		+ ' .x .unity-text-element { color: rgb(0, 0, 255); }')
	await h.process_frame
	var le := doc.get_native("t") as LineEdit
	h.eq(le.get_theme_color("caret_color"), Color(1, 0, 0), "author cursor colour")
	h.eq(le.get_theme_color("selection_color"), Color(0, 1, 0), "author selection colour")
	h.eq(le.get_theme_color("font_color"), Color(0, 0, 1), "text colour on the text element")
	_unload(doc)


func test_text_field_editing() -> void:
	var doc := _doc('<ui:TextField name="t" value="ab" max-length="5" />'
		+ '<ui:TextField name="d" value="x" is-delayed="true" />'
		+ '<ui:TextField name="pw" value="secret" password="true" mask-character="#" />'
		+ '<ui:TextField name="ro" value="fixed" readonly="true" />'
		+ '<ui:TextField name="h" placeholder-text="hint" hide-placeholder-on-focus="true" />')
	await h.process_frame
	var events := []
	doc.value_changed.connect(func(n, v): events.append([n, v]))
	var t := doc.get_native("t") as LineEdit
	h.eq(t.max_length, 5, "max-length")
	t.grab_focus()
	t.text = "abc"
	t.text_changed.emit("abc")
	h.eq(events, [["t", "abc"]], "not delayed: every edit is a value change")
	h.eq(doc.get_element_model("t").get_attribute("value"), "abc", "the value attribute follows")
	var d := doc.get_native("d") as LineEdit
	d.grab_focus()
	d.text = "xy"
	d.text_changed.emit("xy")
	h.eq(events.size(), 1, "delayed: no change while typing")
	d.text_submitted.emit("xy")
	h.eq(events.back(), ["d", "xy"], "delayed: Enter commits")
	var pw := doc.get_native("pw") as LineEdit
	h.check(pw.secret and pw.secret_character == "#", "password + mask-character")
	h.eq((doc.get_native("ro") as LineEdit).editable, false, "readonly")
	var hh := doc.get_native("h") as LineEdit
	h.eq(hh.placeholder_text, "hint", "placeholder")
	hh.grab_focus()
	await h.process_frame
	h.eq(hh.placeholder_text, "", "hide-placeholder-on-focus")
	h.check(not _part(doc, "h", "input").class_list().has("unity-base-text-field__input--placeholder"),
		"placeholder class off while hidden")
	h.check(doc._states.get(doc.get_element_model("h"), {}).has("focus"), ":focus on the TextField")
	h.check(doc._states.get(_part(doc, "h", "editor"), {}).has("focus"), ":focus on the text element")
	_unload(doc)


func test_text_field_escape_restores() -> void:
	var doc := _doc('<ui:TextField name="t" value="ab" />')
	await h.process_frame
	var t := doc.get_native("t") as LineEdit
	t.grab_focus()
	await h.process_frame
	t.text = "zz"
	t.text_changed.emit("zz")
	var ev := InputEventAction.new()
	ev.action = "ui_cancel"
	ev.pressed = true
	t.gui_input.emit(ev)
	h.eq(t.text, "ab", "Escape restores the text before the edit")
	h.eq(doc._behaviors[doc.get_element_model("t")].bind_read("value")[1], "ab", "and the value")
	_unload(doc)


# ---------------------------------------------------------------------------
# Numeric fields
# ---------------------------------------------------------------------------

func test_numeric_fields() -> void:
	var doc := _doc('<ui:IntegerField name="i" label="I" value="10" />'
		+ '<ui:FloatField name="f" label="F" value="1.5" />'
		+ '<ui:DoubleField name="d" value="0.1" />'
		+ '<ui:UnsignedIntegerField name="u" value="7" />'
		+ '<ui:LongField name="l" value="-9000000000" />'
		+ '<ui:UnsignedLongField name="ul" value="18000000000000000000" />'
		+ '<ui:Hash128Field name="hh" label="H" value="abc" />'
		+ '<ui:IntegerField name="ro" label="R" value="1" readonly="true" />')
	await h.process_frame
	var input := _part(doc, "i", "input")
	h.eq(input.local, "IntegerInput", "IntegerField input type")
	h.check(_part(doc, "i", "label").class_list().has("unity-base-field__label--with-dragger"), "label dragger class")
	h.check(not _part(doc, "hh", "label").class_list().has("unity-base-field__label--with-dragger"), "Hash128Field: no dragger")
	h.check(not _part(doc, "ro", "label").class_list().has("unity-base-field__label--with-dragger"), "readonly: no dragger")
	h.eq((doc.get_native("hh") as LineEdit).text, "ab000000000000000000000000000000", "Hash128 parse (Unity)")
	h.eq((doc.get_native("ul") as LineEdit).text, "18000000000000000000", "UnsignedLongField text")
	h.eq((doc.get_native("i") as LineEdit).max_length, 1000, "numeric fields default to 1000 characters")
	var events := []
	doc.value_changed.connect(func(n, v): events.append([n, v, typeof(v)]))
	var i := doc.get_native("i") as LineEdit
	i.grab_focus()
	await h.process_frame
	i.text = "2*3b"
	i.text_changed.emit("2*3b")
	h.eq(i.text, "2*3", "characters outside the allowed set are dropped")
	h.eq(events.back(), ["i", 6, TYPE_INT], "the value follows the expression while typing")
	i.release_focus()
	await h.process_frame
	h.eq(i.text, "6", "end of editing shows the formatted value")
	var f := doc.get_native("f") as LineEdit
	f.grab_focus()
	await h.process_frame
	f.text = "+=1"
	f.text_changed.emit("+=1")
	f.text_submitted.emit("+=1")
	h.eq(f.text, "2.5", "+=1 on 1.5")
	h.eq(events.back()[2], TYPE_FLOAT, "FloatField value is a float")
	var u := doc.get_native("u") as LineEdit
	u.grab_focus()
	u.text = "-5"
	u.text_changed.emit("-5")
	u.release_focus()
	await h.process_frame
	h.eq(u.text, "0", "UnsignedIntegerField clamps -5 to 0")
	# Label drag (FieldMouseDragger): +10px with sensitivity max(1, sqrt(10)*0.03) = 1.
	# The label part takes the pointer (Unity's FieldMouseDragger zone).
	var lc := doc._controls[_part(doc, "i", "label")] as Control
	var at := lc.size / 2.0
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = at
	lc.gui_input.emit(press)
	var mm := InputEventMouseMotion.new()
	mm.position = at + Vector2(10, 0)
	mm.relative = Vector2(10, 0)
	lc.gui_input.emit(mm)
	h.eq(i.text, "16", "label drag adds round(10 x 1)")
	_unload(doc)


# ---------------------------------------------------------------------------
# Composite fields
# ---------------------------------------------------------------------------

func test_composite_fields() -> void:
	var doc := _doc('<ui:Vector3Field name="v" label="V" x="1" y="2" z="3" />'
		+ '<ui:RectIntField name="r" x="1" y="2" w="3" h="4" />'
		+ '<ui:BoundsField name="b" cx="1" cy="2" cz="3" ex="4" ey="5" ez="6" />')
	await h.process_frame
	var v := doc.get_element_model("v")
	var input := UxmlParts.find_part(v, "input")
	var names := []
	for c in input.children:
		names.append(c.get_attribute("name"))
	h.eq(names, ["unity-x-input", "unity-y-input", "unity-z-input"], "Vector3Field sub-fields")
	h.check(input.children[0].class_list().has("unity-composite-field__field--first"), "--first")
	h.eq(UxmlParts.find_part(input.children[0], "label").get_attribute("text"), "X", "sub-field labels")
	var r := doc.get_element_model("r")
	h.eq(UxmlParts.find_part(r, "group-1").children[0].get_attribute("name"), "unity-width-input", "RectIntField second line")
	var bb = doc._behaviors[doc.get_element_model("b")]
	h.eq(bb.get_value(), AABB(Vector3(-1, -0.5, 0), Vector3(4, 5, 6)), "BoundsField: ex..ez are the size (Unity)")
	h.eq(doc._behaviors[r].get_value(), Rect2i(1, 2, 3, 4), "RectIntField value")
	var events := []
	doc.value_changed.connect(func(n, val): events.append([n, val]))
	var y := doc._controls[UxmlParts.find_part(input.children[1], "editor")] as LineEdit
	y.grab_focus()
	y.text = "7"
	y.text_changed.emit("7")
	h.eq(events.back(), ["v", Vector3(1, 7, 3)], "a sub-field edit sends the composite value")
	h.eq(events.size(), 1, "one signal per edit, from the composite only")
	_unload(doc)


# ---------------------------------------------------------------------------
# DropdownField, EnumField
# ---------------------------------------------------------------------------

func test_dropdown_field() -> void:
	var doc := _doc('<ui:DropdownField name="d" label="Q" choices="Low,Medium,High" index="1" />'
		+ '<ui:DropdownField name="v" label="V" choices="Low,Medium,High" value="High" />')
	await h.process_frame
	var input := _part(doc, "d", "input")
	h.eq(_classes(input), _sorted(["unity-base-field__input", "unity-base-popup-field__input", "unity-popup-field__input"]), "input classes")
	h.eq(_part(doc, "d", "text").local, "PopupTextElement", "text part type")
	h.eq(_part(doc, "d", "text").get_attribute("text"), "Medium", "index selects")
	h.eq(_part(doc, "v", "text").get_attribute("text"), "", "Unity 6000.3 ignores the value attribute (ctl-dropdown)")
	var pf := doc.get_native("d") as UxmlPopupField
	h.eq(pf.selected, 1, "selected index")
	var events := []
	doc.value_changed.connect(func(n, val): events.append([n, val]))
	pf.grab_focus()
	await h.process_frame
	h.check(doc._states.get(input, {}).has("focus"), ":focus on the input part")
	_action(pf, "ui_accept")
	await h.process_frame
	var menu: UxmlPopupMenu = null
	for ch in doc.get_element("d").get_children(true):
		if ch is UxmlPopupMenu:
			menu = ch
	if menu == null:
		for ch in input_ctl(doc, "d").get_children(true):
			if ch is UxmlPopupMenu:
				menu = ch
	h.check(menu != null, "ui_accept opens the menu")
	h.check(doc._states.get(doc.get_element_model("d"), {}).has("active"), "the field is :active while open")
	if menu != null:
		var md := menu.document()
		h.check(md.get_element("item-1") != null, "menu items")
		h.check(md._states.get(md.get_element_model("item-1"), {}).has("checked"), "selected item :checked")
		h.eq(md.get_computed_style("item-1").get("background-color", {}).get("value"), "rgb(0, 106, 166)",
			"highlighted item look (ctl-dropdown-menu-hover)")
		var down := InputEventAction.new()
		down.action = "ui_down"
		down.pressed = true
		menu.window_input.emit(down)
		var acc := InputEventAction.new()
		acc.action = "ui_accept"
		acc.pressed = true
		menu.window_input.emit(acc)
		h.eq(events.back(), ["d", "High"], "Down + accept chooses the next item")
	h.eq(pf.selected, 2, "selection")
	_unload(doc)


func input_ctl(doc: UxmlDocument, n: String) -> Control:
	return doc._controls[_part(doc, n, "input")]


func test_enum_field() -> void:
	UxmlDocument.register_enum("Game.Difficulty", {"Easy": 0, "NormalMode": 1, "Hard": 2, "Legacy": 3}, ["Legacy"])
	var doc := _doc('<ui:EnumField name="e" label="D" type="Game.Difficulty, Assembly-CSharp" value="Hard" />'
		+ '<ui:EnumField name="f" type="Difficulty" />'
		+ '<ui:EnumField name="o" type="Game.Difficulty" value="Legacy" include-obsolete-values="true" />')
	await h.process_frame
	h.eq(_part(doc, "e", "text").get_attribute("text"), "Hard", "registered enum value")
	h.eq(_part(doc, "f", "text").get_attribute("text"), "Easy", "no value: the first entry")
	var be = doc._behaviors[doc.get_element_model("e")]
	h.eq(be.items(), PackedStringArray(["Easy", "Normal Mode", "Hard"]), "nicified names; obsolete hidden")
	h.eq(doc._behaviors[doc.get_element_model("o")].items().size(), 4, "include-obsolete-values")
	h.eq(be.get_value(), 2, "value is the enum int")
	var events := []
	doc.value_changed.connect(func(n, v): events.append([n, v]))
	be.choose(1, true)
	h.eq(events.back(), ["e", 1], "value_changed sends the int")
	h.eq(_classes(_part(doc, "e", "input")), _sorted(["unity-base-field__input", "unity-enum-field__input"]), "EnumField input classes")
	_unload(doc)
	UxmlDocument.unregister_enum("Game.Difficulty")


class EnumSource extends Object:
	enum Mode { EASY, MEDIUM = 5, HARD }
	@export var mode: Mode = Mode.MEDIUM


func test_enum_field_from_binding_hint() -> void:
	var src := EnumSource.new()
	var doc := _doc('<ui:EnumField name="e" type="Unknown"><Bindings><ui:DataBinding property="value" data-source-path="mode" binding-mode="TwoWay" /></Bindings></ui:EnumField>')
	doc.set_data_source(src)
	doc.update_bindings()
	await h.process_frame
	var be = doc._behaviors[doc.get_element_model("e")]
	# Godot writes the enum hint with capitalized names.
	h.eq(be.items(), PackedStringArray(["Easy", "Medium", "Hard"]), "entries from the property's enum hint")
	h.eq(_part(doc, "e", "text").get_attribute("text"), "Medium", "bound value shown")
	be.choose(2, true)
	h.eq(src.mode, EnumSource.Mode.HARD, "two-way: the choice writes the int")
	_unload(doc)
	src.free()


# ---------------------------------------------------------------------------
# Data binding, transitions
# ---------------------------------------------------------------------------

func test_bindings_two_way() -> void:
	var data := {"vol": 2.5, "name": "Ada", "count": 3, "pick": "B", "pos": Vector3(1, 2, 3), "range": Vector2(1, 4)}
	var doc := _doc('<ui:Slider name="s" low-value="0" high-value="10" binding-path="vol" />'
		+ '<ui:TextField name="t" binding-path="name" />'
		+ '<ui:IntegerField name="i" binding-path="count" />'
		+ '<ui:DropdownField name="d" choices="A,B,C" binding-path="pick" />'
		+ '<ui:Vector3Field name="v" binding-path="pos" />'
		+ '<ui:MinMaxSlider name="m" low-limit="0" high-limit="10" binding-path="range" />')
	doc.set_data_source(data)
	doc.update_bindings()
	await h.process_frame
	h.eq((doc.get_native("s") as UxmlSlider).value, 2.5, "source -> Slider (continuous)")
	h.eq((doc.get_native("t") as LineEdit).text, "Ada", "source -> TextField")
	h.eq((doc.get_native("i") as LineEdit).text, "3", "source -> IntegerField")
	h.eq((doc.get_native("d") as UxmlPopupField).selected, 1, "source -> DropdownField value")
	h.eq(doc._behaviors[doc.get_element_model("v")].get_value(), Vector3(1, 2, 3), "source -> Vector3Field")
	h.eq(doc._behaviors[doc.get_element_model("m")].get_value(), Vector2(1, 4), "source -> MinMaxSlider")
	(doc.get_native("s") as UxmlSlider).value = 7.5
	h.eq(data["vol"], 7.5, "Slider -> source")
	var t := doc.get_native("t") as LineEdit
	t.text = "Bob"
	t.text_changed.emit("Bob")
	h.eq(data["name"], "Bob", "TextField -> source")
	(doc.get_native("d") as UxmlPopupField).select(2)
	h.eq(data["pick"], "C", "DropdownField -> source")
	var i := doc.get_native("i") as LineEdit
	i.text = "4+4"
	i.text_changed.emit("4+4")
	h.eq(data["count"], 8, "IntegerField -> source (an int)")
	_unload(doc)


func test_transitions_on_slider_parts() -> void:
	var doc := _doc('<ui:Slider name="s" low-value="0" high-value="10" value="0" />',
		'.unity-base-slider__dragger { transition: translate 0.5s linear; }')
	doc.transitions_manual = true
	await h.process_frame
	await h.process_frame
	(doc.get_native("s") as UxmlSlider).value = 10.0
	doc._restyle_now()
	h.check(doc.has_running_transitions(), "a dragger translate change runs the author transition")
	doc.advance_transitions(1.0)
	h.check(not doc.has_running_transitions(), "and ends")
	_unload(doc)


func test_disabled_input_controls() -> void:
	var doc := _doc('<ui:Slider name="s" low-value="0" high-value="10" value="5" enabled="false" fill="true" />'
		+ '<ui:TextField name="t" value="a" enabled="false" />')
	await h.process_frame
	var s: UxmlSlider = doc.get_native("s")
	_action(s, "ui_right")
	h.eq(s.value, 5.0, "a disabled slider ignores input")
	h.eq(_val(doc, _part(doc, "s", "fill"), "background-color"), "rgb(50, 50, 50)", "disabled fill (ctl-slider-states)")
	h.eq(_val(doc, _part(doc, "t", "input"), "background-color"), "rgb(209, 209, 209)", "disabled text input")
	h.eq((doc.get_native("t") as LineEdit).editable, false, "disabled editor is not editable")
	_unload(doc)
