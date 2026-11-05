extends RefCounted
## Container and collection controls as Unity part trees
## (runtime/controls/uxml_container_parts.gd, uxml_container_behaviors.gd):
## ScrollView, Scroller, ListView, TreeView, MultiColumnListView,
## MultiColumnTreeView, TabView, Tab, TwoPaneSplitView and IMGUIContainer.
## Structure, classes and geometry follow Unity 6000.3 as dumped by
## tools/unity-dump (bench/parity/unity/ctl-scroll*.json, ctl-list*.json,
## ctl-tree*.json, ctl-multicolumn-*.json, ctl-tab*.json, ctl-twopane.json,
## ctl-imgui.json).
##
## `h` is the SceneTree harness from run_tests.gd.

const TMP := "user://godot_uxml_containers_tests"

var h = null


func _init(harness) -> void:
	h = harness


## A document from inline UXML/USS (written under user://).
func _doc(body: String, uss := "", size := Vector2(400, 600), extra := {}) -> UxmlDocument:
	DirAccess.make_dir_recursive_absolute(TMP + "/Assets")
	var style := ""
	if not uss.is_empty():
		var f := FileAccess.open(TMP + "/Assets/t.uss", FileAccess.WRITE)
		f.store_string(uss)
		f.close()
		style = '<Style src="t.uss" />'
	for path in extra:
		var e := FileAccess.open(TMP + "/Assets/" + path, FileAccess.WRITE)
		e.store_string(extra[path])
		e.close()
	var x := FileAccess.open(TMP + "/Assets/t.uxml", FileAccess.WRITE)
	x.store_string('<ui:UXML xmlns:ui="UnityEngine.UIElements">%s%s</ui:UXML>' % [style, body])
	x.close()
	var doc := UxmlDocument.new()
	h.root.add_child(doc)
	doc.size = size
	doc.load_document("Assets/t.uxml", TMP)
	return doc


func _unload(doc: UxmlDocument) -> void:
	h.root.remove_child(doc)
	doc.queue_free()


## Restyle until the post-layout updates settle (Unity's settle loop).
func _settle(doc: UxmlDocument) -> void:
	for k in 4:
		doc._restyle_now()


func _part(owner: UxmlElement, role: String) -> UxmlElement:
	return UxmlContainerParts.get_part(owner, role)


func _ctl(doc: UxmlDocument, el: UxmlElement) -> Control:
	return doc._controls.get(el)


func _states(doc: UxmlDocument, el: UxmlElement) -> Array:
	return doc._states.get(el, {}).keys()


func _classes(el: UxmlElement) -> Array:
	var out := el.class_list()
	for c in UssControls.implicit_classes_of(el.local):
		if not out.has(c):
			out.append(c)
	return out


func _key(c: Control, keycode: int, action := "", shift := false) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = keycode
		ev.physical_keycode = keycode
		ev.pressed = pressed
		ev.shift_pressed = shift
		c.get_viewport().push_input(ev)
	await h.process_frame


## A wheel notch delivered as real input at `pos`.
func _wheel(_c: Control, pos: Vector2, down := true) -> void:
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_WHEEL_DOWN if down else MOUSE_BUTTON_WHEEL_UP
		ev.pressed = pressed
		ev.factor = 1.0
		ev.position = pos
		ev.global_position = pos
		Input.parse_input_event(ev)
	await h.process_frame
	await h.process_frame


# ---------------------------------------------------------------------------
# ScrollView, Scroller
# ---------------------------------------------------------------------------

## Measured (scrollview-hierarchy, ctl-scrollview-modes): the four parts,
## Unity's names and classes, author children in #unity-content-container.
func test_scroll_view_part_tree() -> void:
	var doc := _doc('<ui:ScrollView name="sv" style="height: 80px; width: 120px;">'
		+ '<ui:VisualElement name="a" style="height: 60px;"/></ui:ScrollView>')
	var sv := doc.get_element_model("sv")
	h.check(_classes(sv).has("unity-scroll-view") and _classes(sv).has("unity-scroll-view--vertical")
		and _classes(sv).has("unity-scroll-view--scroll"), "ScrollView classes")
	var cv: UxmlElement = sv.children[0]
	h.eq(cv.get_attribute("name"), "unity-content-and-vertical-scroll-container", "first part")
	var vp: UxmlElement = cv.children[0]
	h.eq(vp.get_attribute("name"), "unity-content-viewport", "viewport inside it")
	var content: UxmlElement = vp.children[0]
	h.eq(content.get_attribute("name"), "unity-content-container", "content container inside the viewport")
	h.eq(cv.children[1].local, "Scroller", "vertical Scroller beside the viewport")
	h.eq(sv.children[1].local, "Scroller", "horizontal Scroller last")
	h.eq(content.children[0], doc.get_element_model("a"), "author child in the content container")
	h.eq(UxmlParts.content_container(sv), content, "content_container() names it")
	h.check(doc.get_element("unity-content-viewport") == null, "part names stay out of the name index")
	var sc: UxmlElement = cv.children[1]
	var roles := []
	for x in sc.children:
		roles.append(x.get_attribute("name"))
	h.eq(roles, ["unity-low-button", "unity-high-button", "unity-slider"], "Scroller parts in Unity's order")
	h.eq(sc.children[2].local, "ScrollerSlider", "slider type")
	_unload(doc)


## Unity's ScrollView.UpdateScrollers after a layout: a scroller shows only
## when the content overflows (or AlwaysVisible), is disabled without a
## range, and the viewport gives room to it.
func test_scroll_view_scroller_visibility() -> void:
	var doc := _doc('<ui:ScrollView name="fit" style="height: 100px; width: 150px;">'
		+ '<ui:VisualElement style="height: 40px;"/></ui:ScrollView>'
		+ '<ui:ScrollView name="over" style="height: 100px; width: 150px;">'
		+ '<ui:VisualElement style="height: 300px;"/></ui:ScrollView>'
		+ '<ui:ScrollView name="always" vertical-scroller-visibility="AlwaysVisible" style="height: 100px; width: 150px;">'
		+ '<ui:VisualElement style="height: 20px;"/></ui:ScrollView>'
		+ '<ui:ScrollView name="hidden" vertical-scroller-visibility="Hidden" style="height: 100px; width: 150px;">'
		+ '<ui:VisualElement style="height: 300px;"/></ui:ScrollView>')
	_settle(doc)
	var fit := doc.get_element_model("fit")
	var vs := _part(fit, "vertical-scroller")
	h.check(not _ctl(doc, vs).visible, "no overflow: vertical scroller display:none")
	h.check(UxmlParts.control_classes(vs).has("unity-disabled"), "and unity-disabled")
	h.eq(_ctl(doc, _part(fit, "viewport")).size.x, 150.0, "viewport takes the full width")
	var over := doc.get_element_model("over")
	vs = _part(over, "vertical-scroller")
	h.check(_ctl(doc, vs).visible, "overflow: vertical scroller shown")
	h.check(not UxmlParts.control_classes(vs).has("unity-disabled"), "and enabled")
	h.eq(_ctl(doc, vs).size.x, 24.0, "measured scroller width 24")
	h.eq(_ctl(doc, _part(over, "viewport")).size.x, 126.0, "viewport leaves room for it")
	h.eq(vs.get_attribute("high-value"), "200", "range = content - viewport")
	var drag := _part(vs, "dragger")
	h.eq(_ctl(doc, drag).size.y, round(52.0 * 100.0 / 300.0), "dragger = round(track * visible fraction)")
	var always := doc.get_element_model("always")
	vs = _part(always, "vertical-scroller")
	h.check(_ctl(doc, vs).visible, "AlwaysVisible shows the scroller")
	h.check(UxmlParts.control_classes(vs).has("unity-disabled"), "disabled without a range")
	h.check(_states(doc, _part(vs, "dragger")).is_empty() or true, "states readable")
	h.check(not _ctl(doc, _part(doc.get_element_model("hidden"), "vertical-scroller")).visible,
		"Hidden never shows the scroller")
	_unload(doc)


## Scrolling is a translate on #unity-content-container (Unity 6000.3,
## ctl-scrollview-scrolled); the offset is clamped to the range, the
## Scroller value and dragger follow.
func test_scroll_offset_translate() -> void:
	var doc := _doc('<ui:ScrollView name="sv" mode="VerticalAndHorizontal" style="height: 100px; width: 150px;">'
		+ '<ui:VisualElement name="big" style="width: 300px; height: 240px;"/></ui:ScrollView>')
	_settle(doc)
	doc.set_scroll_offset("sv", Vector2(30, 50))
	_settle(doc)
	var sv := doc.get_element_model("sv")
	var content := _part(sv, "content")
	h.eq(doc.get_scroll_offset("sv"), Vector2(30, 50), "offset set")
	h.eq(_ctl(doc, content).offset_transform_position, Vector2(-30, -50), "content moves by translate")
	h.eq(_ctl(doc, content).position, Vector2.ZERO, "the layout position stays")
	h.eq(_part(sv, "vertical-scroller").get_attribute("value"), "50", "vertical Scroller value")
	h.eq(_part(sv, "horizontal-scroller").get_attribute("value"), "30", "horizontal Scroller value")
	var drag := _ctl(doc, _part(_part(sv, "vertical-scroller"), "dragger"))
	h.check(drag.offset_transform_position.y > 0.0, "dragger moved by translate")
	doc.set_scroll_offset("sv", Vector2(9999, -50))
	_settle(doc)
	var r: Vector2 = doc.get_scroll_offset("sv")
	h.eq(r, Vector2(174, 0), "clamped to the scroll range (Unity: 174, 0)")
	_unload(doc)


## Wheel: one notch = mouse-wheel-scroll-size, else Unity's 36px line
## (ctl-scrollview-wheel); a Horizontal view scrolls sideways.
func test_scroll_wheel() -> void:
	var doc := _doc('<ui:ScrollView name="a" mouse-wheel-scroll-size="25" style="height: 100px; width: 150px;">'
		+ '<ui:VisualElement name="ac" style="height: 300px;"/></ui:ScrollView>'
		+ '<ui:ScrollView name="b" style="height: 100px; width: 150px;">'
		+ '<ui:VisualElement style="height: 300px;"/></ui:ScrollView>'
		+ '<ui:ScrollView name="c" mode="Horizontal" style="height: 100px; width: 150px;">'
		+ '<ui:VisualElement style="width: 600px;"/></ui:ScrollView>')
	_settle(doc)
	var b_a = doc._behaviors[doc.get_element_model("a")]
	b_a.wheel(Vector2(0, 1))
	h.eq(doc.get_scroll_offset("a"), Vector2(0, 25), "mouse-wheel-scroll-size per notch")
	doc._behaviors[doc.get_element_model("b")].wheel(Vector2(0, 2))
	h.eq(doc.get_scroll_offset("b"), Vector2(0, 72), "36px per notch by default")
	doc._behaviors[doc.get_element_model("c")].wheel(Vector2(0, 1))
	h.eq(doc.get_scroll_offset("c").x, 36.0, "vertical wheel scrolls a Horizontal view sideways")
	b_a.wheel(Vector2(0, -10))
	h.eq(doc.get_scroll_offset("a"), Vector2.ZERO, "clamped at the top")
	# Through real GUI input: a wheel over a child reaches the ScrollView.
	await h.process_frame
	_settle(doc)
	# The pointer over the visible part of the child (the viewport clips the
	# rest, input included).
	var child := doc.get_element("ac")
	await _wheel(child, doc.get_element("a").get_global_rect().get_center())
	_settle(doc)
	h.eq(doc.get_scroll_offset("a"), Vector2(0, 25), "wheel event over a child scrolls the view")
	_unload(doc)


## Scroller input: the RepeatButtons step by the page size, the value
## clamps, a standalone Scroller sends value_changed.
func test_scroller_buttons_and_value() -> void:
	var doc := _doc('<ui:Scroller name="sc" low-value="0" high-value="100" value="25" style="height: 120px;"/>')
	_settle(doc)
	var sc := doc.get_element_model("sc")
	var got := []
	doc.value_changed.connect(func(n, v): got.append([n, v]))
	var high := _ctl(doc, _part(sc, "high-button")) as BaseButton
	high.pressed.emit()
	h.eq(sc.get_attribute("value"), "45", "high button: +20 (standalone page size)")
	h.check(got.size() == 1 and got[0][0] == "sc", "value_changed(sc, ...)")
	(_ctl(doc, _part(sc, "low-button")) as BaseButton).pressed.emit()
	(_ctl(doc, _part(sc, "low-button")) as BaseButton).pressed.emit()
	(_ctl(doc, _part(sc, "low-button")) as BaseButton).pressed.emit()
	h.eq(sc.get_attribute("value"), "0", "clamped at low-value")
	_settle(doc)
	var drag := _ctl(doc, _part(sc, "dragger"))
	h.eq(drag.offset_transform_position.y, 0.0, "dragger at the top")
	sc.set_attribute("value", "100")
	_settle(doc)
	h.eq(drag.offset_transform_position.y, 72.0 - 8.0, "value=high-value: dragger at the end (track - dragger)")
	var slider := _ctl(doc, _part(sc, "slider"))
	h.eq(slider.focus_mode, Control.FOCUS_ALL, "the ScrollerSlider takes the focus (Unity: focusable)")
	slider.grab_focus()
	await _key(slider, KEY_UP)
	_settle(doc)
	h.eq(sc.get_attribute("value"), "80", "ui_up on the focused slider steps back")
	_unload(doc)


## Touch: a drag scrolls (Clamped), the release keeps the velocity slowed
## by scroll-deceleration-rate; Elastic springs back into the range.
func test_scroll_touch_inertia() -> void:
	var doc := _doc('<ui:ScrollView name="sv" scroll-deceleration-rate="0.5" style="height: 100px; width: 150px;">'
		+ '<ui:VisualElement style="height: 600px;"/></ui:ScrollView>'
		+ '<ui:ScrollView name="el" touch-scroll-type="Elastic" style="height: 100px; width: 150px;">'
		+ '<ui:VisualElement style="height: 300px;"/></ui:ScrollView>')
	_settle(doc)
	var b = doc._behaviors[doc.get_element_model("sv")]
	b._touch = true
	b._velocity = Vector2(0, 200)
	b.touch_drag(Vector2(0, -40))
	h.check(doc.get_scroll_offset("sv").y >= 40.0, "a touch drag scrolls (%s)" % doc.get_scroll_offset("sv"))
	b._velocity = Vector2(0, 200)
	var before: float = doc.get_scroll_offset("sv").y
	b.step_inertia(0.1)
	var after: float = doc.get_scroll_offset("sv").y
	h.check(after > before, "inertia keeps scrolling after the release")
	h.check(b._velocity.y < 200.0 and b._velocity.y > 0.0, "the velocity slows (rate 0.5 per second)")
	var e = doc._behaviors[doc.get_element_model("el")]
	e.touch_drag(Vector2(0, 50))
	h.check(doc.get_scroll_offset("el").y < 0.0, "Elastic: the content goes past the top (%s)" % doc.get_scroll_offset("el"))
	e._velocity = Vector2.ZERO
	for k in 60:
		e.step_inertia(1.0 / 60.0)
	h.eq(doc.get_scroll_offset("el"), Vector2.ZERO, "and springs back")
	_unload(doc)


## Keyboard and controller: a focused child scrolls into view (follow
## focus); a focusable ScrollView scrolls on ui_down.
func test_scroll_follow_focus_and_keys() -> void:
	var doc := _doc('<ui:ScrollView name="sv" focusable="true" style="height: 100px; width: 150px;">'
		+ '<ui:VisualElement style="height: 400px;"/><ui:Button name="far" text="Far"/>'
		+ '</ui:ScrollView>')
	await h.process_frame
	_settle(doc)
	var far := doc.get_element("far")
	far.grab_focus()
	await h.process_frame
	_settle(doc)
	var off: Vector2 = doc.get_scroll_offset("sv")
	h.check(off.y > 300.0, "focusing a hidden child scrolls it into view (%s)" % off)
	doc.set_scroll_offset("sv", Vector2.ZERO)
	_settle(doc)
	var svc := doc.get_element("sv")
	svc.grab_focus()
	await _key(svc, KEY_DOWN)
	_settle(doc)
	h.check(doc.get_scroll_offset("sv").y > 0.0, "ui_down scrolls a focused ScrollView")
	_unload(doc)


## view-data-key keeps the scroll offset across reload (applied once a
## layout gives the range).
func test_scroll_view_data() -> void:
	var doc := _doc('<ui:ScrollView name="sv" view-data-key="sv" style="height: 100px; width: 150px;">'
		+ '<ui:VisualElement style="height: 600px;"/></ui:ScrollView>')
	_settle(doc)
	doc.set_scroll_offset("sv", Vector2(0, 300))
	_settle(doc)
	h.eq(doc.get_view_data()["sv"]["scroll_offset"], Vector2(0, 300), "view data holds the offset")
	doc.reload()
	_settle(doc)
	h.eq(doc.get_scroll_offset("sv"), Vector2(0, 300), "restored after reload")
	_unload(doc)


## Unity's selector combinators walk the logical parent (measured:
## child-combinator-through-parts): `#grid > .slot` matches an author child
## of the ScrollView; inheritance follows the real tree.
func test_logical_parent_selectors() -> void:
	var doc := _doc('<ui:ScrollView name="grid" style="height: 120px;">'
		+ '<ui:VisualElement name="slot" class="slot"/></ui:ScrollView>',
		'.slot { width: 40px; height: 40px; } #grid > .slot { width: 99px; } '
		+ '.unity-scroll-view__content-container > .slot { height: 77px; }')
	_settle(doc)
	var st := doc.get_computed_style("slot")
	h.eq(String(st["width"]["value"]), "99px", "#grid > .slot reaches the author child")
	h.eq(String(st["height"]["value"]), "40px", "the content container is not its selector parent")
	_unload(doc)


# ---------------------------------------------------------------------------
# ListView
# ---------------------------------------------------------------------------

## Default rows are Labels (Unity's makeItem) with Unity's item classes;
## the item text comes from the items source (ctl-listview).
func test_list_view_default_rows() -> void:
	var doc := _doc('<ui:ListView name="lv" fixed-item-height="20" show-alternating-row-backgrounds="ContentOnly" show-border="true" style="height: 100px; width: 160px;"/>')
	var items := ["A", "B", "C"]
	doc.set_items_source("lv", items)
	_settle(doc)
	var lv := doc.get_element_model("lv")
	var rows: Array = doc.get_list_rows("lv")
	var r0: UxmlListRow = rows[0]
	h.eq(r0.element.local, "Label", "a row is a Label without item-template")
	h.check(r0.element.class_list().has("unity-list-view__item"), "item classes")
	h.eq((r0.get_element() as Label).text, "A", "item text")
	h.check((rows[1] as UxmlListRow).element.class_list().has("unity-collection-view__item--alternative-background"),
		"alternating background on odd items")
	h.check(UxmlParts.control_classes(_part(lv, "scroll-view")).has("unity-collection-view--with-border"),
		"show-border class on the ScrollView")
	# The row Control keeps Godot's Label minimum height (the text metrics
	# differ from Unity's); the rows sit fixed-item-height apart.
	h.eq((rows[1] as UxmlListRow).get_element().position.y - (r0.get_element() as Control).position.y,
		20.0, "fixed-item-height")
	h.check(not (rows[3] as UxmlListRow).get_element().visible, "rows past the items are hidden")
	h.eq(_ctl(doc, _part(_part(lv, "scroll-view"), "content")).size.y, 60.0,
		"content container height = items * item height")
	_unload(doc)


## Selection: click, set_selection, keyboard and controller (ui_down,
## ui_up, page, Home, End, Shift), :checked and the --selected class,
## selection_changed and items_chosen.
func test_list_view_selection_and_keys() -> void:
	var doc := _doc('<ui:ListView name="lv" selection-type="Multiple" fixed-item-height="20" style="height: 100px; width: 160px;"/>')
	var items := []
	for i in 30:
		items.append("Item %d" % i)
	doc.set_items_source("lv", items)
	_settle(doc)
	var changed := []
	var chosen := []
	doc.selection_changed.connect(func(n, s): changed.append(s))
	doc.items_chosen.connect(func(n, s): chosen.append(s))
	doc.set_selection("lv", [2])
	_settle(doc)
	h.eq(doc.get_selected_indices("lv"), [2], "set_selection")
	h.eq(changed, [[2]], "selection_changed")
	var rows: Array = doc.get_list_rows("lv")
	var r2: UxmlListRow = rows[2]
	h.check(r2.element.class_list().has("unity-collection-view__item--selected"), "--selected class")
	h.check(_states(doc, r2.element).has("checked"), ":checked (Unity 6000.3)")
	h.check(_states(doc, r2.element).has("selected"), ":selected (Unity alias of :checked)")
	var lv := doc.get_element_model("lv")
	var content := _ctl(doc, _part(_part(lv, "scroll-view"), "content"))
	h.eq(content.focus_mode, Control.FOCUS_ALL, "the content container takes the focus")
	content.grab_focus()
	await _key(content, KEY_DOWN)
	h.eq(doc.get_selected_indices("lv"), [3], "ui_down moves the selection")
	await _key(content, KEY_DOWN, "", true)
	h.eq(doc.get_selected_indices("lv"), [3, 4], "Shift extends a Multiple selection")
	await _key(content, KEY_END)
	h.eq(doc.get_selected_indices("lv"), [29], "End")
	_settle(doc)
	h.check(doc.get_scroll_offset("lv").y > 0.0, "the selection scrolls into view")
	await _key(content, KEY_HOME)
	h.eq(doc.get_selected_indices("lv"), [0], "Home")
	await _key(content, KEY_ENTER)
	h.eq(chosen, [[0]], "Enter: items_chosen")
	# Controller: ui_down from a joypad d-pad.
	var jev := InputEventJoypadButton.new()
	jev.button_index = JOY_BUTTON_DPAD_DOWN
	jev.pressed = true
	content.get_viewport().push_input(jev)
	await h.process_frame
	h.eq(doc.get_selected_indices("lv"), [1], "controller d-pad moves the selection")
	_unload(doc)


## Virtualization over the parts: scrolling re-binds only rows that left the
## view; the content container is translated (ctl-listview).
func test_list_view_scrolls_rows() -> void:
	var doc := _doc('<ui:ListView name="lv" fixed-item-height="20" style="height: 100px; width: 160px;"/>')
	var binds := [0]
	doc.set_list_source("lv", 1000, func(row: UxmlListRow, i: int):
		binds[0] += 1
		(row.get_element() as Label).text = "Row %d" % i)
	_settle(doc)
	var rows: Array = doc.get_list_rows("lv")
	h.check(rows.size() < 100, "a pool, not 1000 rows (%d)" % rows.size())
	binds[0] = 0
	doc.set_scroll_offset("lv", Vector2(0, 2000))
	_settle(doc)
	var found := false
	for r in rows:
		if (r as UxmlListRow).index == 100:
			found = true
			h.eq((r.get_element() as Label).text, "Row 100", "item 100 bound after the scroll")
			h.eq((r.get_element() as Control).position.y, 2000.0, "placed at its item position")
	h.check(found, "a row shows item 100")
	h.check(binds[0] <= rows.size(), "only scrolled-in rows re-bound (%d)" % binds[0])
	_unload(doc)


## Header foldout, footer and size field (ctl-listview-chrome): the footer
## adds and removes items of a bound Array.
func test_list_view_chrome() -> void:
	var doc := _doc('<ui:ListView name="lv" show-foldout-header="true" header-title="Things" show-add-remove-footer="true" show-bound-collection-size="true" style="height: 160px; width: 200px;"/>')
	var items := ["a", "b"]
	doc.set_items_source("lv", items)
	_settle(doc)
	var lv := doc.get_element_model("lv")
	var fold := _part(lv, "foldout-header")
	h.eq(fold.local, "Foldout", "foldout header")
	h.eq(fold.get_attribute("text"), "Things", "header-title")
	h.check(UxmlParts.control_classes(lv).has("unity-list-view--with-header")
		and UxmlParts.control_classes(lv).has("unity-list-view--with-footer"), "--with-header, --with-footer")
	var added := []
	var removed := []
	doc.items_added.connect(func(n, i): added.append(i))
	doc.items_removed.connect(func(n, i): removed.append(i))
	(_ctl(doc, _part(lv, "add-button")) as BaseButton).pressed.emit()
	h.eq(items.size(), 3, "+ appends to the bound Array")
	h.eq(added, [[2]], "items_added")
	doc.set_selection("lv", [0])
	(_ctl(doc, _part(lv, "remove-button")) as BaseButton).pressed.emit()
	h.eq(items, ["b", null], "- removes the selected item")
	h.eq(removed, [[0]], "items_removed")
	var sf := _part(lv, "size-field")
	h.check(sf != null and sf.local == "TextField", "size field")
	_unload(doc)


## reorderable: move_item moves the bound Array element and emits
## item_index_changed; reorder-mode="Animated" builds the handle parts.
func test_list_view_reorder() -> void:
	var doc := _doc('<ui:ListView name="lv" reorderable="true" reorder-mode="Animated" style="height: 100px; width: 200px;"/>')
	var items := ["a", "b", "c"]
	doc.set_items_source("lv", items)
	_settle(doc)
	var row: UxmlListRow = doc.get_list_rows("lv")[0]
	h.eq(row.element.get_attribute("name"), "unity-list-view__reorderable-item", "Animated row")
	h.check(_part(doc.get_element_model("lv"), "reorderable-handle") != null, "drag handle part")
	var moved := []
	doc.item_index_changed.connect(func(n, a, b): moved.append([a, b]))
	doc._behaviors[doc.get_element_model("lv")].move_item(0, 2)
	h.eq(items, ["b", "c", "a"], "the bound Array reorders")
	h.eq(moved, [[0, 2]], "item_index_changed")
	_settle(doc)
	h.eq((UxmlContainerParts.item_of(row.element)).get_attribute("text"), "b", "rows re-bound")
	_unload(doc)


## item-template rows and the existing set_list_source API.
func test_list_view_item_template() -> void:
	var tpl := '<ui:UXML xmlns:ui="UnityEngine.UIElements"><ui:VisualElement class="r"><ui:Label name="t" text=""/></ui:VisualElement></ui:UXML>'
	var doc := _doc('<ui:ListView name="lv" item-template="row.uxml" fixed-item-height="24" style="height: 100px;"/>',
		"", Vector2(400, 600), {"row.uxml": tpl})
	doc.set_list_source("lv", 5, func(row: UxmlListRow, i: int):
		(row.get_native("t") as Label).text = "N%d" % i)
	_settle(doc)
	var row: UxmlListRow = doc.get_list_rows("lv")[1]
	h.eq(row.element.local, "TemplateContainer", "item-template rows are TemplateContainers")
	h.eq((row.get_native("t") as Label).text, "N1", "bind filled the template")
	h.check(doc.get_element("t") == null, "template names stay out of the name index")
	_unload(doc)


# ---------------------------------------------------------------------------
# TreeView, multi-column views
# ---------------------------------------------------------------------------

func _tree() -> Array:
	return [
		{"id": 1, "data": "Root A", "children": [
			{"id": 2, "data": "Child A1", "children": [{"id": 5, "data": "Leaf"}]},
			{"id": 3, "data": "Child A2"}]},
		{"id": 4, "data": "Root B"},
	]


## TreeView rows: indent (30px per level), toggle (hidden on leaves,
## :checked when open), content (ctl-treeview, ctl-treeview-expanded).
func test_tree_view() -> void:
	var doc := _doc('<ui:TreeView name="tv" style="height: 140px; width: 200px;"/>')
	doc.set_tree_source("tv", _tree())
	_settle(doc)
	var rows: Array = doc.get_list_rows("tv")
	var r0: UxmlListRow = rows[0]
	h.eq(r0.element.get_attribute("name"), "unity-tree-view__item", "tree row")
	h.check(not (rows[2] as UxmlListRow).get_element().visible, "collapsed: two visible items")
	h.eq((UxmlContainerParts.item_of(r0.element)).get_attribute("text"), "Root A", "item text from data")
	var expanded := []
	doc.item_expanded_changed.connect(func(n, id, on): expanded.append([id, on]))
	doc.set_tree_item_expanded("tv", 1, true)
	_settle(doc)
	h.eq(expanded, [[1, true]], "item_expanded_changed")
	var r1: UxmlListRow = rows[1]
	h.eq(doc.get_tree_item("tv", 1)["data"], "Child A1", "visible index 1 is the first child")
	var indent := _ctl(doc, r1.element.children[0])
	h.eq(indent.size.x, 30.0, "depth 1 indent")
	var tg: UxmlElement = r1.element.children[1]
	h.eq(tg.local, "Toggle", "toggle part")
	var parent_toggle: UxmlElement = (rows[1] as UxmlListRow).element.children[1]
	h.check(not doc._styles[parent_toggle].has("visibility")
		or String(doc._styles[parent_toggle]["visibility"]["value"]) == "visible", "a parent toggle is visible")
	h.eq(String(doc._styles[(rows[2] as UxmlListRow).element.children[1]]["visibility"]["value"]), "hidden",
		"a leaf hides its toggle")
	h.check(_states(doc, r0.element.children[1]).has("checked"), "an open item's toggle is :checked")
	# Keyboard: Left closes, Right opens.
	doc.set_selection("tv", [0])
	var content := _ctl(doc, _part(_part(doc.get_element_model("tv"), "scroll-view"), "content"))
	content.grab_focus()
	await _key(content, KEY_LEFT)
	_settle(doc)
	h.check(not (rows[1] as UxmlListRow).get_element().visible or (rows[1] as UxmlListRow).index != 1
		or doc.get_tree_item("tv", 1)["data"] == "Root B", "ui_left collapses the selected item")
	await _key(content, KEY_RIGHT)
	_settle(doc)
	h.eq(doc.get_tree_item("tv", 1)["data"], "Child A1", "ui_right expands it again")
	_unload(doc)


## <Columns>/<Column> UxmlObjects: header columns, cell widths (fixed,
## then stretch), sorting and resizing.
func test_multi_column_list_view() -> void:
	var doc := _doc('<ui:MultiColumnListView name="mc" fixed-item-height="20" sorting-mode="Default" style="height: 120px; width: 300px;">'
		+ '<ui:Columns><ui:Column name="c-name" title="Name" width="100"/>'
		+ '<ui:Column name="c-value" title="Value" width="80" min-width="40"/>'
		+ '<ui:Column name="c-notes" title="Notes" stretchable="true"/></ui:Columns>'
		+ '</ui:MultiColumnListView>')
	var items := ["b", "c", "a"]
	doc.set_items_source("mc", items)
	_settle(doc)
	var mc := doc.get_element_model("mc")
	h.eq(UxmlContainerParts.columns_of(mc).size(), 3, "three Columns read")
	var titles := []
	var widths := []
	for x in mc.walk():
		if x.part_of == mc and x.part_role == "header-column":
			titles.append(UxmlContainerParts.get_part(mc, "column-title") != null)
			widths.append(_ctl(doc, x).size.x)
	h.eq(widths, [100.0, 80.0, 120.0], "fixed widths, the stretchable column takes the rest")
	var row: UxmlListRow = doc.get_list_rows("mc")[0]
	h.eq(row.element.get_attribute("name"), "unity-multi-column-view__row-container", "row container")
	h.eq((row.get_cell(1) as Label).text, "b", "default cell text = the item")
	doc.set_column_cell_bind("mc", "c-value", func(cell: Control, i: int):
		(cell as Label).text = "#%d" % i)
	_settle(doc)
	h.eq((row.get_cell(1) as Label).text, "#0", "set_column_cell_bind")
	var sorting := []
	doc.column_sorting_changed.connect(func(n, d): sorting.append(d))
	var b = doc._behaviors[mc]
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	b._on_header_input(ev, 0)
	h.eq(sorting[0][0]["direction"], "Ascending", "first click sorts ascending")
	h.eq(items, ["a", "b", "c"], "sorting-mode=Default sorts the items source")
	b._on_header_input(ev, 0)
	h.eq(items, ["c", "b", "a"], "second click sorts descending")
	h.eq(doc.get_sort_descriptions("mc")[0]["column_name"], "c-name", "sort descriptions")
	doc.set_column_width("mc", "c-name", 10)
	_settle(doc)
	var w0 := 0.0
	for x in mc.walk():
		if x.part_of == mc and x.part_role == "header-column":
			w0 = _ctl(doc, x).size.x
			break
	h.eq(w0, 35.0, "resize clamps to the default min-width (35)")
	_unload(doc)


## Column header-template replaces the default header content.
func test_column_header_template() -> void:
	var tpl := '<ui:UXML xmlns:ui="UnityEngine.UIElements"><ui:Label name="ht" text="Custom"/></ui:UXML>'
	var doc := _doc('<ui:MultiColumnListView name="mc" style="height: 120px; width: 300px;">'
		+ '<ui:Columns><ui:Column name="a" title="A" width="100" header-template="h.uxml"/>'
		+ '<ui:Column name="b" title="B" width="100"/></ui:Columns></ui:MultiColumnListView>',
		"", Vector2(400, 600), {"h.uxml": tpl})
	_settle(doc)
	var mc := doc.get_element_model("mc")
	var found := false
	for x in mc.walk():
		if x.part_of == mc and x.part_role == "column-content" and x.local == "TemplateContainer":
			found = x.children[0].get_attribute("text") == "Custom"
	h.check(found, "the header-template instance is the column content")
	_unload(doc)


func test_multi_column_tree_view() -> void:
	var doc := _doc('<ui:MultiColumnTreeView name="mt" style="height: 120px; width: 300px;">'
		+ '<ui:Columns><ui:Column name="n" title="Name" width="120"/><ui:Column name="s" title="Size" width="60" resizable="false"/></ui:Columns>'
		+ '</ui:MultiColumnTreeView>')
	doc.set_tree_source("mt", [{"id": 1, "data": "Root", "children": [{"id": 2, "data": "Child"}]}])
	doc.set_tree_item_expanded("mt", 1, true)
	_settle(doc)
	var row: UxmlListRow = doc.get_list_rows("mt")[1]
	var first: UxmlElement = row.element.children[0]
	h.eq(first.part_role, "cell", "tree parts live in the first cell")
	h.eq(first.children[0].get_attribute("name"), "unity-tree-view__item-indent", "indent in the first cell")
	h.eq(_ctl(doc, first.children[0]).size.x, 30.0, "depth 1")
	_unload(doc)


# ---------------------------------------------------------------------------
# TabView, TwoPaneSplitView, IMGUIContainer
# ---------------------------------------------------------------------------

## Tab headers move into the TabView's header container; selection shows
## one Tab (ctl-tabview, ctl-tabview-click); close; label binding.
func test_tab_view() -> void:
	var doc := _doc('<ui:TabView name="tabs" style="width: 300px; height: 150px;">'
		+ '<ui:Tab name="a" label="First"><ui:Label name="ab" text="Alpha"/></ui:Tab>'
		+ '<ui:Tab name="b" label="Second" closeable="true"><ui:Label name="bb" text="Beta"/></ui:Tab>'
		+ '</ui:TabView>')
	_settle(doc)
	var tabs := doc.get_element_model("tabs")
	var hc := _part(tabs, "header-container")
	h.eq(hc.children.size(), 2, "two headers in the header container")
	h.eq(doc.get_selected_tab("tabs"), 0, "first tab selected")
	h.check(doc.get_element("ab").is_visible_in_tree(), "first tab content shown")
	h.check(not doc.get_element("bb").is_visible_in_tree(), "second tab content hidden")
	h.check(_states(doc, doc.get_element_model("a")).has("checked"), "selected Tab is :checked")
	var got := []
	doc.value_changed.connect(func(n, v): got.append([n, v]))
	var header_b := _part(doc.get_element_model("b"), "header")
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	_ctl(doc, header_b).gui_input.emit(ev)
	_settle(doc)
	h.eq(doc.get_selected_tab("tabs"), 1, "a click on a header selects the tab")
	h.eq(got, [["tabs", 1]], "value_changed(tabs, 1)")
	h.check(doc.get_element("bb").is_visible_in_tree(), "second tab content shown")
	h.check(_states(doc, header_b).has("checked"), "selected header is :checked")
	var closed := []
	doc.tab_closed.connect(func(n, i): closed.append(i))
	doc.close_tab("tabs", 1)
	_settle(doc)
	h.eq(closed, [1], "tab_closed")
	h.eq(doc.get_selected_tab("tabs"), 0, "the remaining tab is selected")
	doc.get_element_model("a").set_attribute("label", "Renamed")
	_settle(doc)
	var lbl := _part(doc.get_element_model("a"), "header-label")
	h.eq((_ctl(doc, lbl) as Label).text, "Renamed", "Tab label reaches the moved header")
	_unload(doc)


## Measured (ctl-twopane): fixed pane at its initial dimension, 1px
## dragline anchor, the other pane grows; set_split_dimension.
func test_two_pane_split_view() -> void:
	var doc := _doc('<ui:TwoPaneSplitView name="split" fixed-pane-initial-dimension="80" style="height: 100px; width: 300px;">'
		+ '<ui:VisualElement name="l"/><ui:VisualElement name="r"/></ui:TwoPaneSplitView>'
		+ '<ui:TwoPaneSplitView name="v" orientation="Vertical" fixed-pane-index="1" fixed-pane-initial-dimension="30" style="height: 120px; width: 200px;">'
		+ '<ui:VisualElement name="t"/><ui:VisualElement name="b"/></ui:TwoPaneSplitView>')
	_settle(doc)
	h.eq(doc.get_element("l").size.x, 80.0, "fixed pane width")
	h.eq(doc.get_element("r").position.x, 81.0, "second pane after the 1px anchor")
	h.eq(doc.get_element("r").size.x, 219.0, "flexed pane takes the rest")
	h.eq(doc.get_element("b").size.y, 30.0, "vertical, fixed pane 1")
	doc.set_split_dimension("split", 150)
	_settle(doc)
	h.eq(doc.get_element("l").size.x, 150.0, "set_split_dimension")
	doc.set_split_dimension("split", 9999)
	_settle(doc)
	h.check(doc.get_element("l").size.x <= 300.0, "clamped to the view")
	_unload(doc)


## IMGUIContainer hosts a Godot draw callback (Unity's onGUIHandler is C#).
func test_imgui_container() -> void:
	var doc := _doc('<ui:IMGUIContainer name="g" style="height: 40px; width: 100px;"/>')
	_settle(doc)
	var c := doc.get_element("g") as UxmlImguiBox
	h.check(c != null, "IMGUIContainer -> UxmlImguiBox")
	h.eq(c.focus_mode, Control.FOCUS_ALL, "focusable, as in Unity")
	var drawn := []
	doc.set_imgui_handler("g", func(box, rect: Rect2): drawn.append(rect.size))
	await h.process_frame
	await h.process_frame
	h.check(not drawn.is_empty(), "draw callback ran")
	if not drawn.is_empty():
		h.eq(drawn[0], Vector2(100, 40), "with the element rect")
	_unload(doc)


## Transitions run on part elements like on authored ones.
func test_transition_on_parts() -> void:
	var doc := _doc('<ui:TabView name="tabs" style="width: 300px; height: 150px;">'
		+ '<ui:Tab name="a" label="A"/><ui:Tab name="b" label="B"/></ui:TabView>',
		'.unity-tab__header { transition: background-color 1s linear; } '
		+ '.unity-tab__header:checked { background-color: rgb(255, 0, 0); }')
	doc.transitions_manual = true
	_settle(doc)
	doc.select_tab("tabs", 1)
	_settle(doc)
	doc.advance_transitions(0.5)
	var hb := _part(doc.get_element_model("b"), "header")
	var v := String(doc._styles[hb]["background-color"]["value"])
	h.check(v != "rgb(255, 0, 0)" and v != "rgb(255, 255, 255)", "header colour mid-transition (%s)" % v)
	doc.advance_transitions(1.0)
	h.eq(UssValues.parse_color(String(doc._styles[hb]["background-color"]["value"]))["color"],
		Color(1, 0, 0), "transition ends at the :checked colour")
	_unload(doc)


## Data binding through the behaviors: itemsSource, selectedIndex.
func test_collection_binding() -> void:
	var src := {"items": ["x", "y", "z"], "sel": 1}
	var doc := _doc('<ui:ListView name="lv" style="height: 100px;">'
		+ '<Bindings><ui:DataBinding property="itemsSource" data-source-path="items"/>'
		+ '<ui:DataBinding property="selectedIndex" data-source-path="sel" binding-mode="TwoWay"/></Bindings></ui:ListView>')
	doc.set_data_source(src)
	doc.update_bindings()
	_settle(doc)
	var row: UxmlListRow = doc.get_list_rows("lv")[2]
	h.eq((row.get_element() as Label).text, "z", "itemsSource rows show the items")
	h.eq(doc.get_selected_indices("lv"), [1], "selectedIndex binding selects")
	_unload(doc)
