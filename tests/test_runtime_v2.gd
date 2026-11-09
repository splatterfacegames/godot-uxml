extends RefCounted
## Runtime v2 interactive widgets (docs/design.md, "Runtime v2"; phase 2 of
## docs/roadmap.md): the interaction Control of each focusable or
## interactive element, pointer input from the core's hit test, keyboard
## and controller focus, the document signals, the field API and the
## pseudo-states. Equivalence with runtime v1 (styles, geometry, pixels)
## is bench/equiv_v2.gd's; these tests drive the widgets.
##
## `h` is the SceneTree harness from run_tests.gd.

const TMP := "user://godot_uxml_v2_tests"

var h = null


func _init(harness) -> void:
	h = harness


func _native() -> bool:
	return ClassDB.class_exists("UxmlRuntimeV2") and UssCascade.use_native


func _doc(body: String, uss := "", size := Vector2(480, 400)) -> UxmlDocument:
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
	doc.runtime = 2
	h.root.add_child(doc)
	doc.size = size
	doc.load_document("Assets/t.uxml", TMP)
	return doc


func _unload(doc: UxmlDocument) -> void:
	h.root.remove_child(doc)
	doc.queue_free()


func _center(doc: UxmlDocument, el: UxmlElement) -> Vector2:
	return doc.get_element_rect(el).get_center()


## A left click at `p` (document coordinates) through the root box, the
## path of the pointer on runtime v2.
func _click(doc: UxmlDocument, p: Vector2) -> void:
	_move(doc, p)
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = p
		doc._root_box.gui_input.emit(ev)
	doc._restyle_now()


func _move(doc: UxmlDocument, p: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = p
	doc._root_box.gui_input.emit(ev)


func _press_key(keycode: int) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = keycode
		ev.physical_keycode = keycode
		ev.pressed = pressed
		Input.parse_input_event(ev)
	await h.process_frame
	await h.process_frame


const WIDGETS := '''
<ui:VisualElement name="col">
  <ui:Button name="b" text="Go" />
  <ui:Toggle name="t" label="Sound" />
  <ui:Slider name="s" low-value="0" high-value="100" value="25" style="width: 300px;" />
  <ui:DropdownField name="dd" label="Quality" choices="Low,Medium,High" index="1" />
  <ui:TextField name="tf" label="Name" value="abc" />
  <ui:VisualElement name="fv" focusable="true" style="height: 20px;" tooltip="a tip" />
</ui:VisualElement>'''


func test_widgets_load_on_runtime_v2() -> void:
	if not _native():
		return
	var doc := _doc(WIDGETS)
	h.eq(doc.get_runtime(), 2, "Button, Toggle, Slider, DropdownField, TextField load on v2 (%s)" % doc.runtime_fallback)
	h.check(doc.get_native("b") is Button, "get_native of a Button is its interaction Button")
	h.check(doc.get_element("b") == doc.get_native("b"), "get_element of a Button is the same Control")
	h.check(doc.get_native("t") is UxmlToggle, "get_native of a Toggle is a UxmlToggle")
	h.check(doc.get_native("s") is UxmlSlider, "get_native of a Slider is a UxmlSlider")
	h.check(doc.get_native("dd") is UxmlPopupField, "get_native of a DropdownField is a UxmlPopupField")
	h.check(doc.get_native("tf") is LineEdit, "get_native of a TextField is its LineEdit")
	h.check(doc.get_native("fv") != null, "a focusable VisualElement has an interaction Control")
	h.check(doc.get_native("col") == null, "a VisualElement drawn by the core has no Control")
	var b := doc.get_native("b")
	h.eq(b.get_rect(), doc.get_element_rect(doc.get_element_model("b")), "the interaction Control is at the element's rect")
	h.eq(doc.get_control_for(doc.get_element_model("t")), doc.get_native("t"), "get_control_for gives the interaction Control")
	h.eq(doc.get_native_for(doc.get_element_model("tf")), doc.get_native("tf"), "get_native_for a TextField gives its editor")
	_unload(doc)


func test_button_click_emits_signals() -> void:
	if not _native():
		return
	var doc := _doc(WIDGETS)
	var got := []
	doc.button_pressed.connect(func(n): got.append(n))
	var direct := [0]
	(doc.get_native("b") as Button).pressed.connect(func(): direct[0] += 1)
	_click(doc, _center(doc, doc.get_element_model("b")))
	h.eq(got, ["b"], "a click on the Button emits button_pressed(name)")
	h.eq(direct[0], 1, "and the Button's own pressed signal")
	h.check(doc.get_native("b").has_focus(), "a click focuses the Button")
	h.check((doc._states.get(doc.get_element_model("b"), {}) as Dictionary).has("focus"), ":focus follows the Button's focus")
	_unload(doc)


func test_toggle_click_sets_value_and_checked() -> void:
	if not _native():
		return
	var doc := _doc(WIDGETS)
	var vals := []
	doc.value_changed.connect(func(n, v): vals.append([n, v]))
	var t := doc.get_element_model("t")
	_click(doc, _center(doc, t))
	h.eq(vals, [["t", true]], "a click on the Toggle emits value_changed(name, true)")
	h.eq(doc.get_field_value("t"), true, "get_field_value reads the Toggle")
	h.check((doc._states.get(t, {}) as Dictionary).has("checked"), "the Toggle is :checked")
	var cm := UxmlParts.find_part(t, "checkmark")
	h.check(doc.get_computed_style_for(cm).has("background-image"), "the theme's :checked rule shows the checkmark")
	doc.set_field_value("t", false)
	doc._restyle_now()
	h.eq(doc.get_field_value("t"), false, "set_field_value turns it off")
	h.check(not (doc._states.get(t, {}) as Dictionary).has("checked"), "and :checked off")
	_unload(doc)


func test_slider_pointer_keys_and_dragger() -> void:
	if not _native():
		return
	var doc := _doc(WIDGETS)
	var s := doc.get_element_model("s")
	var dc := UxmlParts.find_part(s, "drag-container")
	var dg := UxmlParts.find_part(s, "dragger")
	var r := doc.get_element_rect(dc)
	var before := doc.get_element_rect(dg).position.x
	var vals := []
	doc.value_changed.connect(func(n, v): vals.append([n, v]))
	# Page size 0: the dragger jumps to the pointer.
	_click(doc, Vector2(r.position.x + r.size.x * 0.75, r.get_center().y))
	var v: float = doc.get_field_value("s")
	h.check(v > 60.0 and v < 90.0, "a click at three quarters of the track sets about 75 (%s)" % v)
	h.check(not vals.is_empty() and vals[-1][0] == "s", "value_changed for the Slider")
	h.check(doc.get_element_rect(dg).position.x > before, "the dragger moved right")
	h.check(doc.get_native("s").has_focus(), "the click focused the Slider")
	doc.set_field_value("s", 10.0)
	doc._restyle_now()
	h.eq(doc.get_field_value("s"), 10.0, "set_field_value sets the value")
	await _press_key(KEY_END)
	h.eq(doc.get_field_value("s"), 100.0, "End goes to the high value through the focused Control")
	_unload(doc)


func test_dropdown_value_and_text() -> void:
	if not _native():
		return
	var doc := _doc(WIDGETS)
	var dd := doc.get_element_model("dd")
	var text := UxmlParts.find_part(dd, "text")
	h.eq(doc.get_field_value("dd"), "Medium", "the index attribute selects a choice")
	h.eq(String(doc._v2.rt.call("get_text", doc._v2.index_of(text))), "Medium", "the core draws the choice")
	doc.set_field_value("dd", "High")
	doc._restyle_now()
	h.eq(String(doc._v2.rt.call("get_text", doc._v2.index_of(text))), "High", "set_field_value shows the new choice")
	var vals := []
	doc.value_changed.connect(func(n, v): vals.append([n, v]))
	(doc.get_native("dd") as UxmlPopupField).select(0)
	h.eq(vals, [["dd", "Low"]], "select() emits value_changed")
	_unload(doc)


func test_text_field_editor_is_a_line_edit() -> void:
	if not _native():
		return
	var doc := _doc(WIDGETS)
	var le := doc.get_native("tf") as LineEdit
	h.eq(le.text, "abc", "the editor has the value")
	var ed := UxmlParts.find_part(doc.get_element_model("tf"), "editor")
	# It sits in a Control at its field's place (as v1's in its field's).
	var er := Rect2((le.get_parent() as Control).position + le.position, le.size)
	h.eq(er, doc.get_element_rect(ed), "the LineEdit is at the editor part's rect")
	var vals := []
	doc.value_changed.connect(func(n, v): vals.append([n, v]))
	le.grab_focus()
	le.text = "abcd"
	le.text_changed.emit("abcd")
	h.eq(vals, [["tf", "abcd"]], "an edit emits value_changed")
	h.eq(doc.get_field_value("tf"), "abcd", "get_field_value reads it")
	h.check((doc._states.get(doc.get_element_model("tf"), {}) as Dictionary).has("focus"), "the field is :focus while its editor has the focus")
	h.check(doc.set_field_placeholder("tf", "type"), "set_field_placeholder")
	h.eq(le.placeholder_text, "type", "the placeholder reaches the LineEdit")
	_unload(doc)


func test_set_enabled_disables_the_control() -> void:
	if not _native():
		return
	var doc := _doc(WIDGETS)
	var got := []
	doc.button_pressed.connect(func(n): got.append(n))
	doc.set_enabled("b", false)
	doc._restyle_now()
	var b := doc.get_native("b") as Button
	h.check(b.disabled, "set_enabled(false) disables the Button")
	h.eq(b.focus_mode, Control.FOCUS_NONE, "and takes it out of the focus chain")
	h.check(doc._v2.is_disabled(doc.get_element_model("b")), "the Button is :disabled")
	_click(doc, _center(doc, doc.get_element_model("b")))
	h.eq(got, [], "a disabled Button does not emit")
	doc.set_enabled("b", true)
	doc._restyle_now()
	h.check(not b.disabled and b.focus_mode == Control.FOCUS_ALL, "set_enabled(true) restores it")
	_unload(doc)


func test_tab_moves_focus_in_document_order() -> void:
	if not _native():
		return
	var doc := _doc(WIDGETS)
	await h.process_frame
	doc.get_native("b").grab_focus()
	await _press_key(KEY_TAB)
	h.check(doc.get_native("t").has_focus(), "Tab goes from the Button to the Toggle")
	await _press_key(KEY_SPACE)
	h.eq(doc.get_field_value("t"), true, "Space (ui_accept) toggles the focused Toggle")
	await _press_key(KEY_TAB)
	h.check(doc.get_native("s").has_focus(), "then the Slider")
	doc.get_native("b").release_focus()
	_unload(doc)


func test_tooltip_follows_the_pointer() -> void:
	if not _native():
		return
	var doc := _doc(WIDGETS)
	_move(doc, _center(doc, doc.get_element_model("fv")))
	h.eq(doc._root_box.tooltip_text, "a tip", "the element under the pointer gives the tooltip")
	_move(doc, _center(doc, doc.get_element_model("b")))
	h.eq(doc._root_box.tooltip_text, "", "none elsewhere")
	_unload(doc)


func test_scroll_view_wheel_and_focus_scroll() -> void:
	if not _native():
		return
	var rows := ""
	for i in 30:
		rows += '<ui:VisualElement name="r%d" focusable="true" style="height: 30px;" />' % i
	var doc := _doc('<ui:ScrollView name="sv" style="height: 200px; width: 200px;">%s</ui:ScrollView>' % rows)
	h.eq(doc.get_runtime(), 2, "a ScrollView loads on v2 (%s)" % doc.runtime_fallback)
	var p := _center(doc, doc.get_element_model("sv"))
	_move(doc, p)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_DOWN
	ev.pressed = true
	ev.position = p
	ev.factor = 1.0
	doc._root_box.gui_input.emit(ev)
	doc._restyle_now()
	h.check(doc.get_scroll_offset("sv").y > 0.0, "the wheel scrolls (%s)" % doc.get_scroll_offset("sv"))
	var r0y := doc.get_element_rect(doc.get_element_model("r0")).position.y
	h.check(r0y < 0.0, "the content moved up (%s)" % r0y)
	doc.set_scroll_offset("sv", Vector2.ZERO)
	doc._restyle_now()
	doc.scroll_to("sv", "r20")
	doc._restyle_now()
	var off := doc.get_scroll_offset("sv")
	h.check(off.y > 400.0, "scroll_to shows a row below the viewport (%s)" % off)
	h.check(not doc.get_native("r0").visible, "a row scrolled out has its Control hidden")
	_unload(doc)


func test_panel_scaling_on_runtime_v2() -> void:
	if not _native():
		return
	DirAccess.make_dir_recursive_absolute(TMP + "/Assets")
	var x := FileAccess.open(TMP + "/Assets/s.uxml", FileAccess.WRITE)
	x.store_string('<ui:UXML xmlns:ui="UnityEngine.UIElements">%s</ui:UXML>' % WIDGETS)
	x.close()
	var doc := UxmlDocument.new()
	doc.runtime = 2
	var ps := UxmlPanelSettings.new()
	ps.scale_mode = UxmlPanelSettings.ScaleMode.CONSTANT_PIXEL_SIZE
	ps.scale = 2.0
	doc.panel_settings = ps
	h.root.add_child(doc)
	doc.size = Vector2(640, 480)
	doc.load_document("Assets/s.uxml", TMP)
	h.eq(doc.get_runtime(), 2, "a scaled document loads on v2 (%s)" % doc.runtime_fallback)
	h.eq(doc.get_pixels_per_point(), 2.0, "two pixels per point")
	h.eq(doc.get_panel_size(), Vector2(320, 240), "the panel in points")
	var b := doc.get_element_model("b")
	var r := doc.get_element_rect(b)
	var rp := doc.get_element_rect(b, doc.get_document_model().root)
	h.eq(r.size, rp.size * 2.0, "get_element_rect without a space is in document pixels (%s, %s)" % [r, rp])
	h.eq(r.position, doc.panel_to_document(rp.position), "and at the panel point's place")
	h.eq(doc.element_at(r.get_center()), b, "element_at takes document pixels")
	var got := []
	doc.button_pressed.connect(func(n): got.append(n))
	_click(doc, doc.document_to_panel(r.get_center()))
	h.eq(got, ["b"], "a click on the scaled Button presses it")
	var w := (doc.get_native("s") as Control).size.x
	h.eq(w, 300.0, "an interaction Control is sized in points (%s)" % w)
	ps.scale = 1.0
	doc._restyle_now()
	h.eq(doc.get_runtime(), 2, "a new scale keeps the document on v2 (%s)" % doc.runtime_fallback)
	h.eq(doc.get_pixels_per_point(), 1.0, "one pixel per point")
	h.eq(doc.get_element_rect(b), doc.get_element_rect(b, doc.get_document_model().root), "at one pixel per point the rect is the panel rect")
	_unload(doc)


func test_list_view_on_runtime_v2() -> void:
	if not _native():
		return
	var doc := _doc('<ui:ListView name="lv" fixed-item-height="20" selection-type="Single" style="height: 200px;" />')
	h.eq(doc.get_runtime(), 2, "a FixedHeight ListView loads on v2 (%s)" % doc.runtime_fallback)
	doc.set_list_source("lv", 1000, func(row: UxmlListRow, i: int): row.set_text("", "Item %d" % i))
	doc._restyle_now()
	var rows: Array = doc.get_list_rows("lv")
	h.check(rows.size() >= 10 and rows.size() <= 13, "the rows of the viewport are in use (%d)" % rows.size())
	var r0: UxmlListRow = rows[0]
	h.eq(doc._v2.rt.call("get_text", doc._v2.index_of(r0.element)), "Item 0", "a row is bound through set_text")
	doc.set_scroll_offset("lv", Vector2(0, 100))
	doc._restyle_now()
	var shown := {}
	for r in rows:
		shown[(r as UxmlListRow).index] = true
	h.check(shown.has(5) and shown.has(14) and not shown.has(0), "a scroll of five rows rebinds the rows (%s)" % [shown.keys()])
	var r5: UxmlListRow = null
	for r in rows:
		if (r as UxmlListRow).index == 7:
			r5 = r
	var rr := doc.get_element_rect(r5.element)
	var top := doc.get_element_rect(doc.get_element_model("lv")).position.y
	h.eq(rr.position.y - top, 7 * 20.0 - 100.0, "item 7 is drawn at its place under the scroll (%s)" % rr)
	h.eq(doc.element_at(rr.get_center(), false, true), r5.element, "the hit test finds its row")
	var got := []
	doc.selection_changed.connect(func(n, ix): got.append(ix))
	_click(doc, rr.get_center())
	h.eq(got, [[7]], "a click selects the item")
	_unload(doc)


func test_tabindex_focus_ring_on_runtime_v2() -> void:
	if not _native():
		return
	var doc := _doc('<ui:Button name="a" text="a"/><ui:Button name="b" text="b" tabindex="2"/>'
		+ '<ui:Button name="c" text="c" tabindex="-1"/><ui:Button name="d" text="d" tabindex="1"/>'
		+ '<ui:Button name="e" text="e"/><ui:VisualElement name="f" tabindex="3"/>')
	h.eq(doc.get_runtime(), 2, "tabindex loads on v2 (%s)" % doc.runtime_fallback)
	var names: Array = []
	for t in doc.get_focus_ring():
		names.append(doc._el_names.get(doc._el_of.get(t)))
	h.eq(names, ["d", "b", "a", "e"], "positive tabindex first, then 0 in tree order; negative and unfocusable left out")
	h.eq((doc.get_native("c") as Control).focus_mode, Control.FOCUS_CLICK, "negative tabindex: focusable by pointer only")
	h.eq(doc.get_native("d").get_node(doc.get_native("d").focus_next), doc.get_native("b"), "focus_next chain")
	doc.get_element_model("e").set_attribute("tabindex", "5")
	doc._restyle_now()
	names = []
	for t in doc.get_focus_ring():
		names.append(doc._el_names.get(doc._el_of.get(t)))
	h.eq(names, ["d", "b", "e", "a"], "a tabindex change rebuilds the ring")
	_unload(doc)


func test_editor_clipped_by_overflow_hidden() -> void:
	if not _native():
		return
	var doc := _doc('<ui:VisualElement name="box" style="overflow: hidden; width: 120px; margin-top: 50px; flex-direction: row;">'
		+ '<ui:TextField name="tf" value="abc" style="width: 300px; flex-shrink: 0;" /></ui:VisualElement>')
	h.eq(doc.get_runtime(), 2, "loads on v2 (%s)" % doc.runtime_fallback)
	var le := doc.get_native("tf") as Control
	var wrap := le.get_parent() as Control
	var box := doc.get_element_rect(doc.get_element_model("box"))
	h.check(wrap.clip_contents, "the editor's Control clips it")
	var wr := Rect2(wrap.position, wrap.size)
	h.check(box.encloses(wr), "to the part of it inside the box (%s in %s)" % [wr, box])
	var ed := UxmlParts.find_part(doc.get_element_model("tf"), "editor")
	h.eq(Rect2(wrap.position + le.position, le.size), doc.get_element_rect(ed), "the editor keeps its rect")
	_unload(doc)
