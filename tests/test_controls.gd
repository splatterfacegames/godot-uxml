extends RefCounted
## Control part trees, the default theme and per-control behavior
## (runtime/controls/). Structure and classes follow Unity 6000.3 as dumped
## by tools/unity-dump (bench/parity/unity/ctl-*.json).
##
## `h` is the SceneTree harness from run_tests.gd.

const FIXTURE := "res://tests/fixtures/controls"
const TMP := "user://godot_uxml_controls_tests"

var h = null


func _init(harness) -> void:
	h = harness


func _load(theme := UxmlTheme.DEFAULT) -> UxmlDocument:
	var doc := UxmlDocument.new()
	doc.theme_path = theme
	h.root.add_child(doc)
	doc.size = Vector2(500, 900)
	doc.load_document("Assets/UI/controls.uxml", FIXTURE)
	return doc


## A document from inline UXML/USS (written under user://).
func _doc(body: String, uss := "", theme := UxmlTheme.DEFAULT) -> UxmlDocument:
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
	doc.theme_path = theme
	h.root.add_child(doc)
	doc.size = Vector2(400, 600)
	doc.load_document("Assets/t.uxml", TMP)
	return doc


func _unload(doc: UxmlDocument) -> void:
	h.root.remove_child(doc)
	doc.queue_free()


func _flush(doc: UxmlDocument) -> void:
	doc._restyle_now()


func _part(doc: UxmlDocument, owner: String, role: String) -> UxmlElement:
	return UxmlParts.find_part(doc.get_element_model(owner), role)


func _val(doc: UxmlDocument, el: UxmlElement, prop: String) -> String:
	var e = doc._styles.get(el, {}).get(prop)
	return "" if e == null else String(e["value"])


func _states(doc: UxmlDocument, el: UxmlElement) -> Array:
	return doc._states.get(el, {}).keys()


## A real Enter keypress (ui_accept) on the focused control.
func _accept(c: Control) -> void:
	c.grab_focus()
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = KEY_ENTER
		ev.pressed = pressed
		Input.parse_input_event(ev)
	await h.process_frame
	await h.process_frame


func _classes(el: UxmlElement) -> Array:
	var out := el.class_list()
	for c in UssControls.implicit_classes_of(el.local):
		if not out.has(c):
			out.append(c)
	return out


# ---------------------------------------------------------------------------
# Part trees
# ---------------------------------------------------------------------------

func test_toggle_part_tree() -> void:
	var doc := _load()
	var t := doc.get_element_model("sound")
	var kids: Array = t.children
	h.eq(kids.size(), 2, "Toggle with a label: label + input")
	var label: UxmlElement = kids[0]
	var input: UxmlElement = kids[1]
	h.eq(label.local, "Label", "label part is a Label")
	h.check(_classes(label).has("unity-base-field__label") and _classes(label).has("unity-toggle__label"),
		"label classes")
	h.eq(label.get_attribute("text"), "Sound", "label text from the label attribute")
	h.check(_classes(input).has("unity-base-field__input") and _classes(input).has("unity-toggle__input"),
		"input classes")
	var check: UxmlElement = input.children[0]
	h.eq(check.get_attribute("name"), "unity-checkmark", "checkmark is named unity-checkmark")
	h.check(_classes(check).has("unity-toggle__checkmark"), "checkmark class")
	h.check(check.part_of == t and check.part_role == "checkmark", "part ownership")
	var music := doc.get_element_model("music")
	h.check(_classes(music).has("unity-base-field--no-label"), "no label: --no-label variant")
	var text := UxmlParts.find_part(music, "text")
	h.check(text != null and text.get_attribute("text") == "Music", "text part inside the input")
	h.check(text != null and text in UxmlParts.find_part(music, "input").children, "text sits in the input")
	_unload(doc)


func test_parts_stay_out_of_name_index() -> void:
	var doc := _load()
	h.check(doc.get_element("unity-checkmark") == null, "part names are not author-facing")
	h.check(doc.get_element("unity-content") == null, "#unity-content is not author-facing")
	h.check(doc.get_element("sound") is UxmlToggle, "control itself is indexed")
	_unload(doc)


func test_foldout_content_container() -> void:
	var doc := _load()
	var fo := doc.get_element_model("details")
	var content := UxmlParts.content_container(fo)
	h.eq(content.get_attribute("name"), "unity-content", "Foldout content container is #unity-content")
	h.check(doc.get_element_model("details-child") in content.children, "author children go into #unity-content")
	var tg := UxmlParts.find_part(fo, "toggle")
	h.eq(tg.local, "Toggle", "Foldout holds a real Toggle part")
	h.check(_classes(tg).has("unity-foldout__toggle") and _classes(tg).has("unity-toggle"),
		"toggle part classes")
	var check := UxmlParts.find_part(tg, "checkmark")
	h.check(_classes(check).has("unity-foldout__checkmark"), "arrow carries unity-foldout__checkmark")
	var tx := UxmlParts.find_part(tg, "text")
	h.check(tx != null and tx.get_attribute("text") == "Details", "Foldout text on the toggle text part")
	h.check(_classes(fo).has("unity-foldout--depth-0"), "depth class")
	_unload(doc)


func test_popup_and_group_parts() -> void:
	var doc := _load()
	var pw := doc.get_element_model("popup")
	var content := UxmlParts.content_container(pw)
	h.eq(content.get_attribute("name"), "unity-content-container", "PopupWindow content container")
	h.check(doc.get_element_model("popup-child") in content.children, "popup children in its content")
	var gb := doc.get_element_model("group")
	var gl := UxmlParts.find_part(gb, "label")
	h.check(gl != null and _classes(gl).has("unity-group-box__label") and gl.get_attribute("text") == "Group",
		"GroupBox label part")
	h.check(doc.get_element_model("group-child") in gb.children, "GroupBox content container is itself")
	_unload(doc)


func test_helpbox_icon_variants() -> void:
	var doc := _load()
	var hb := doc.get_element_model("help")
	var icon := UxmlParts.find_part(hb, "icon")
	h.check(_classes(icon).has("unity-help-box__icon--warning"), "Warning icon class")
	var lbl := UxmlParts.find_part(hb, "label")
	h.eq(lbl.get_attribute("text"), "Careful", "HelpBox label text")
	hb.set_attribute("message-type", "None")
	_flush(doc)
	h.eq(_val(doc, icon, "display"), "none", "message-type None hides the icon")
	hb.set_attribute("message-type", "Error")
	_flush(doc)
	h.check(_classes(icon).has("unity-help-box__icon--error"), "message-type change swaps the icon class")
	h.check(_val(doc, icon, "display") != "none", "icon shows again")
	_unload(doc)


func test_progress_bar() -> void:
	var doc := _load()
	var pb := doc.get_element_model("progress")
	var prog := UxmlParts.find_part(pb, "progress")
	h.eq(_val(doc, prog, "right"), "60%", "value 40 of 0..100 leaves 60% on the right")
	var title := UxmlParts.find_part(pb, "title")
	h.eq(title.get_attribute("text"), "Loading", "title part")
	pb.set_attribute("value", "75")
	_flush(doc)
	h.eq(_val(doc, prog, "right"), "25%", "value change moves the progress")
	pb.set_attribute("title", "Almost")
	_flush(doc)
	h.eq((doc._controls[title] as Label).text, "Almost", "title change reaches the label")
	_unload(doc)


func test_radio_group_choices() -> void:
	var doc := _load()
	var rg := doc.get_element_model("quality")
	var choices := UxmlParts.find_part(rg, "choices")
	h.eq(choices.get_attribute("name"), "choicesContentContainer", "choices live in #choicesContentContainer")
	h.eq(UxmlParts.content_container(rg).get_attribute("name"), "contentContainer",
		"authored radios go into #contentContainer")
	var radios: Array = choices.children.filter(func(x): return x.local == "RadioButton")
	h.eq(radios.size(), 3, "choices become three RadioButtons")
	var on: Array = radios.map(func(x): return (doc._controls[x] as UxmlToggle).button_pressed)
	h.eq(on, [false, true, false], "value=1 selects the second choice")
	var got := []
	doc.value_changed.connect(func(n, v): got.append([n, v]))
	(doc._controls[radios[2]] as UxmlToggle)._activate()
	_flush(doc)
	on = radios.map(func(x): return (doc._controls[x] as UxmlToggle).button_pressed)
	h.eq(on, [false, false, true], "activating another choice switches the group")
	h.check(got.has(["quality", 2]), "value_changed(quality, 2)")
	h.check(_states(doc, radios[2]).has("checked"), "selected radio is :checked")
	h.check(not _states(doc, radios[1]).has("checked"), "previous radio lost :checked")
	_unload(doc)


func test_toggle_button_group() -> void:
	var doc := _load()
	var a := doc.get_element_model("mode-a")
	var b := doc.get_element_model("mode-b")
	h.check(_classes(a).has("unity-button-group__button--left"), "first button is --left")
	h.check(_classes(b).has("unity-button-group__button--mid"), "middle button is --mid")
	h.check(_states(doc, a).has("checked"), "first option selected without allow-empty-selection")
	var got := []
	doc.value_changed.connect(func(n, v): got.append([n, v]))
	(doc.get_native("mode-b") as Button).pressed.emit()
	_flush(doc)
	h.check(_states(doc, b).has("checked") and not _states(doc, a).has("checked"),
		"single selection moves to the pressed button")
	h.check(got.has(["mode", [1]]), "value_changed(mode, [1])")
	doc.set_class("mode-b", "extra")
	_flush(doc)
	h.check(_classes(b).has("unity-button-group__button--mid") and _classes(b).has("extra"),
		"set_class keeps the control's classes")
	_unload(doc)


# ---------------------------------------------------------------------------
# Cascade through parts
# ---------------------------------------------------------------------------

func test_author_selectors_reach_parts() -> void:
	var doc := _doc(
		'<ui:VisualElement class="hot"><ui:Toggle name="t" label="L" value="true" /></ui:VisualElement>'
		+ '<ui:Foldout name="f" text="F"><ui:Label name="in" text="x" /></ui:Foldout>',
		""".unity-toggle__checkmark { width: 21px; }
Toggle > .unity-toggle__input { margin-left: 7px; }
.hot { --c: rgb(1, 2, 3); }
.unity-base-field__label { color: var(--c); }
.unity-toggle:checked > .unity-toggle__input > .unity-toggle__checkmark { height: 13px; }
.unity-foldout > #unity-content { margin-left: 30px; }
#unity-checkmark.unity-toggle__checkmark { border-left-width: 2px; }
""")
	_flush(doc)
	var check := _part(doc, "t", "checkmark")
	h.eq(_val(doc, check, "width"), "21px", "class selector reaches the checkmark")
	h.eq(_val(doc, _part(doc, "t", "input"), "margin-left"), "7px", "child combinator through parts")
	h.eq(_val(doc, _part(doc, "t", "label"), "color"), "rgb(1, 2, 3)", "var() reaches the label part")
	h.eq(_val(doc, check, "height"), "13px", ":checked on the Toggle reaches its parts' selectors")
	h.eq(_val(doc, check, "border-left-width"), "2px", "#unity-checkmark name selector")
	h.eq(_val(doc, _part(doc, "f", "content"), "margin-left"), "30px", "#unity-content child selector")
	(doc.get_native("t") as UxmlToggle).button_pressed = false
	_flush(doc)
	h.check(_val(doc, check, "height") != "13px", "unchecking drops the :checked rule")
	_unload(doc)


func test_theme_layer() -> void:
	var doc := _doc('<ui:Button name="plain" text="a" /><ui:Button name="typed" text="b" class="t" />'
		+ '<ui:Button name="classed" text="c" class="flat" />',
		"""Button.t { margin: 0; }
.flat { margin-left: 9px; }
""")
	_flush(doc)
	var plain := doc.get_element_model("plain")
	h.eq(_val(doc, plain, "margin-left"), "4px", "theme gives .unity-button margin 2px 4px (Unity 6000.3)")
	h.eq(_val(doc, plain, "margin-top"), "2px", "theme margin-top")
	h.eq(_val(doc, doc.get_element_model("typed"), "margin-left"), "0", "author rule beats the theme")
	var lone := _doc('<ui:Button name="b" text="a" />', "Button { margin: 0; }")
	_flush(lone)
	h.eq(_val(lone, lone.get_element_model("b"), "margin-left"), "0",
		"a lower-specificity author rule still beats the theme (Unity ranks theme rules last)")
	_unload(lone)
	h.eq(_val(doc, doc.get_element_model("classed"), "margin-left"), "9px", "equal-specificity author rule wins")
	_unload(doc)
	var off := _doc('<ui:Button name="plain" text="a" />', "", "")
	_flush(off)
	h.eq(_val(off, off.get_element_model("plain"), "margin-left"), "", "theme_path \"\" disables the theme")
	_unload(off)
	DirAccess.make_dir_recursive_absolute(TMP)
	var f := FileAccess.open(TMP + "/alt-theme.uss", FileAccess.WRITE)
	f.store_string(".unity-button { margin-left: 11px; }\n")
	f.close()
	UxmlTheme.clear_cache()
	var alt := _doc('<ui:Button name="plain" text="a" />', "", TMP + "/alt-theme.uss")
	_flush(alt)
	h.eq(_val(alt, alt.get_element_model("plain"), "margin-left"), "11px", "theme_path replaces the theme")
	_unload(alt)


# ---------------------------------------------------------------------------
# Behavior
# ---------------------------------------------------------------------------

func test_toggle_keyboard_and_signals() -> void:
	var doc := _load()
	var t := doc.get_native("sound") as UxmlToggle
	h.check(t != null and t.button_pressed, "get_native returns the UxmlToggle; value=true")
	var el := doc.get_element_model("sound")
	h.check(_states(doc, el).has("checked"), "value=true sets :checked on the Toggle")
	h.check(_states(doc, UxmlParts.find_part(el, "input")).has("checked"), "and on its input part")
	var got := []
	doc.value_changed.connect(func(n, v): got.append([n, v]))
	await _accept(t)
	_flush(doc)
	h.check(not t.button_pressed, "ui_accept toggles off")
	h.check(got.has(["sound", false]), "value_changed(sound, false)")
	h.check(not _states(doc, el).has("checked"), ":checked cleared")
	h.eq(el.get_attribute("value"), "false", "model value follows")
	doc.set_enabled("sound", false)
	_flush(doc)
	await _accept(t)
	h.check(not t.button_pressed, "disabled toggle ignores ui_accept")
	doc.set_enabled("sound", true)
	_flush(doc)
	el.set_attribute("value", "true")
	_flush(doc)
	h.check(t.button_pressed, "model value=true checks the toggle")
	el.set_attribute("label", "Audio")
	_flush(doc)
	var lbl := UxmlParts.find_part(el, "label")
	h.eq((doc._controls[lbl] as Label).text, "Audio", "label attribute reaches the label part")
	_unload(doc)


func test_toggle_focus_and_parts_input() -> void:
	var doc := _load()
	var t := doc.get_native("sound") as UxmlToggle
	h.eq(t.focus_mode, Control.FOCUS_ALL, "Toggle takes focus")
	var el := doc.get_element_model("sound")
	var check: Control = doc._controls[UxmlParts.find_part(el, "checkmark")]
	h.eq(check.focus_mode, Control.FOCUS_NONE, "parts never take focus")
	h.eq(check.mouse_filter, Control.MOUSE_FILTER_IGNORE, "checkmark is not picked")
	var input: Control = doc._controls[UxmlParts.find_part(el, "input")]
	h.eq(input.mouse_filter, Control.MOUSE_FILTER_PASS, "input passes the mouse to the Toggle")
	_unload(doc)


func test_foldout_collapses() -> void:
	var doc := _load()
	await h.process_frame
	var child: Control = doc.get_element("details-child")
	h.check(child.visible, "open Foldout shows its content")
	var tg := doc.get_native("details") as UxmlToggle
	h.check(tg != null and tg.button_pressed, "get_native(Foldout) is its toggle, on")
	var got := []
	doc.value_changed.connect(func(n, v): got.append([n, v]))
	await _accept(tg)
	_flush(doc)
	h.check(not child.visible, "collapsing hides the content")
	h.check(got.has(["details", false]), "value_changed(details, false)")
	var content := UxmlParts.content_container(doc.get_element_model("details"))
	h.eq(_val(doc, content, "display"), "none", "#unity-content display: none")
	doc.get_element_model("details").set_attribute("value", "true")
	_flush(doc)
	h.check(child.visible, "value=true opens it again")
	_unload(doc)


func test_button_and_repeat_button() -> void:
	var doc := _load()
	h.check(doc.get_native("play") is Button, "Button stays a native Button")
	var rb := doc.get_native("repeat") as UxmlRepeatButton
	h.check(rb != null, "RepeatButton is a UxmlRepeatButton")
	h.eq(rb.delay_ms, 200.0, "delay attribute")
	h.eq(rb.interval_ms, 50.0, "interval attribute")
	h.eq(rb.action_mode, BaseButton.ACTION_MODE_BUTTON_PRESS, "repeating button fires on press")
	var count := [0]
	doc.button_pressed.connect(func(n): if n == "repeat": count[0] += 1)
	rb.button_down.emit()
	rb.pressed.emit()
	# Held: the timer repeats after delay, then every interval.
	rb.set_pressed_no_signal(true)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 450:
		await h.process_frame
	h.check(count[0] >= 3, "held RepeatButton fires again (%d presses)" % count[0])
	rb.button_up.emit()
	_unload(doc)


func test_basic_elements_classes() -> void:
	var doc := _load()
	h.check(_classes(doc.get_element_model("title")).has("unity-label"), "Label class")
	h.check(_classes(doc.get_element_model("te")).has("unity-text-element"), "TextElement class")
	h.check(doc.get_element("te") is Label, "TextElement renders as a Label")
	h.check(_classes(doc.get_element_model("box")).has("unity-box"), "Box class")
	h.check(doc.get_element("tc") is UxmlBox, "TemplateContainer is a plain box")
	var kinds := []
	for d in doc.diagnostics:
		if d["kind"] == "unsupported-control":
			kinds.append(d["message"])
	h.eq(kinds, [], "no unsupported-control diagnostics for the controls in scope")
	_unload(doc)


func test_reload_stable_with_parts() -> void:
	var doc := _load()
	var n0 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	for i in 5:
		doc.reload()
		await h.process_frame
	var n1 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	h.check(absf(n1 - n0) < 1.0, "reloads keep the node count flat (%d -> %d)" % [n0, n1])
	_unload(doc)


func test_focus_and_disabled_classes() -> void:
	var doc := _load()
	var t := doc.get_native("sound") as UxmlToggle
	var el := doc.get_element_model("sound")
	var input := UxmlParts.find_part(el, "input")
	t.grab_focus()
	await h.process_frame
	_flush(doc)
	h.check(_states(doc, el).has("focus"), "focused Toggle is :focus")
	h.check(_states(doc, input).has("focus"), "and its input part (Unity puts :focus on both)")
	var check := UxmlParts.find_part(el, "checkmark")
	# The fixture's `.unity-toggle__checkmark { border-color: var(--accent) }`
	# is an author rule: it beats the theme's :focus border, as in Unity.
	h.eq(_val(doc, check, "border-top-color"), "rgb(40, 120, 220)", "author border beats the theme focus rule")
	t.release_focus()
	await h.process_frame
	_flush(doc)
	h.check(not _states(doc, input).has("focus"), "focus leaves the input too")
	doc.set_enabled("play", false)
	_flush(doc)
	h.check(_classes(doc.get_element_model("play")).has("unity-disabled"), "set_enabled(false) adds unity-disabled")
	h.eq(_val(doc, doc.get_element_model("play"), "background-color"), "rgb(149, 149, 149)", "theme :disabled look")
	doc.set_enabled("play", true)
	_flush(doc)
	h.check(not _classes(doc.get_element_model("play")).has("unity-disabled"), "set_enabled(true) removes it")
	_unload(doc)
	var d2 := _doc('<ui:VisualElement name="p" enabled="false"><ui:Button name="b" text="x" /></ui:VisualElement>')
	_flush(d2)
	h.check(_classes(d2.get_element_model("p")).has("unity-disabled"), "enabled=false adds unity-disabled")
	h.check(not _classes(d2.get_element_model("b")).has("unity-disabled"), "only on the element itself")
	_unload(d2)


func test_popup_window_draws_title() -> void:
	var doc := _load()
	var pw := doc.get_element("popup") as Label
	h.check(pw != null and pw.text == "Popup", "PopupWindow draws its own title")
	doc.get_element_model("popup").set_attribute("text", "Renamed")
	_flush(doc)
	h.eq(pw.text, "Renamed", "text attribute change reaches the title")
	_unload(doc)


func test_loose_radio_buttons_are_exclusive() -> void:
	var doc := _doc('<ui:RadioButton name="a" text="A" value="true" /><ui:RadioButton name="b" text="B" />'
		+ '<ui:GroupBox><ui:RadioButton name="c" text="C" value="true" /></ui:GroupBox>')
	await h.process_frame
	var a := doc.get_native("a") as UxmlToggle
	var b := doc.get_native("b") as UxmlToggle
	var c := doc.get_native("c") as UxmlToggle
	b._activate()
	_flush(doc)
	h.check(b.button_pressed and not a.button_pressed, "switching one loose radio on switches the other off")
	h.check(c.button_pressed, "a radio inside a GroupBox is its own group")
	_unload(doc)


func _mouse(pos: Vector2, button := -1, pressed := false) -> void:
	var ev: InputEvent
	if button < 0:
		var m := InputEventMouseMotion.new()
		m.position = pos
		m.global_position = pos
		ev = m
	else:
		var b := InputEventMouseButton.new()
		b.button_index = button
		b.pressed = pressed
		b.position = pos
		b.global_position = pos
		ev = b
	Input.parse_input_event(ev)
	await h.process_frame
	await h.process_frame


## Unity's placement, measured (ctl-pressed-toggle, ctl-foldout-click):
## :hover on the picked element and its ancestors, :active only on the
## pressed control, a click toggles.
func test_toggle_mouse_states() -> void:
	if not h.has_display():
		h.check(true, "headless: synthetic mouse needs a window (display run covers)")
		return
	var doc := _load()
	await h.process_frame
	var el := doc.get_element_model("sound")
	var input := UxmlParts.find_part(el, "input")
	var check := UxmlParts.find_part(el, "checkmark")
	var t := doc.get_native("sound") as UxmlToggle
	var at: Vector2 = (doc._controls[check] as Control).get_global_rect().get_center()
	await _mouse(at)
	_flush(doc)
	h.check(_states(doc, el).has("hover"), "pointer over the checkmark: Toggle is :hover")
	h.check(_states(doc, input).has("hover"), "and its input (the picked part)")
	h.check(not _states(doc, check).has("hover"), "the checkmark ignores the pointer, as in Unity")
	var was := t.button_pressed
	await _mouse(at, MOUSE_BUTTON_LEFT, true)
	_flush(doc)
	h.check(_states(doc, el).has("active"), "press: Toggle is :active")
	h.check(not _states(doc, input).has("active"), "parts do not take :active")
	await _mouse(at, MOUSE_BUTTON_LEFT, false)
	_flush(doc)
	h.check(t.button_pressed != was, "a click toggles")
	h.check(not _states(doc, el).has("active"), "release clears :active")
	await _mouse(Vector2(-50, -50))
	_unload(doc)


## Unity's disabled look: `unity-disabled` (on the element itself) resolves
## opacity 0.5; the subtree is :disabled but does not get its own 0.5, so
## it dims once through the painted opacity of the element.
func test_disabled_opacity() -> void:
	var doc := _doc('<ui:VisualElement name="p" enabled="false"><ui:Button name="inner" text="in" /></ui:VisualElement>'
		+ '<ui:Button name="b" text="b" /><ui:Toggle name="t" label="T" />')
	_flush(doc)
	var p := doc.get_element_model("p")
	var inner := doc.get_element_model("inner")
	h.eq(_val(doc, p, "opacity"), "0.5", "enabled=false: opacity 0.5 on the element")
	h.eq(_val(doc, inner, "opacity"), "", "no own opacity on the disabled subtree")
	h.check((doc.get_native("inner") as Button).disabled, "the subtree is disabled")
	h.eq(doc.get_element("p").modulate.a, 0.5, "painted on the element's control")
	h.eq(doc.get_element("inner").modulate.a, 1.0, "the child control keeps its own alpha (it dims with the parent)")
	doc.set_enabled("b", false)
	doc.set_enabled("t", false)
	_flush(doc)
	h.eq(doc.get_element("b").modulate.a, 0.5, "set_enabled(false) dims the Button")
	h.eq(doc.get_element("t").modulate.a, 0.5, "set_enabled(false) dims the Toggle")
	h.eq(_val(doc, _part(doc, "t", "input"), "opacity"), "", "parts of a disabled control keep opacity 1")
	doc.set_enabled("b", true)
	_flush(doc)
	h.eq(doc.get_element("b").modulate.a, 1.0, "set_enabled(true) restores")
	var none := _doc('<ui:Button name="b" text="b" enabled="false" />', "", "")
	_flush(none)
	h.eq(none.get_element("b").modulate.a, 1.0, "no theme: no disabled opacity")
	_unload(none)
	_unload(doc)


## Unity rich text in control text: a text part (Toggle label and text,
## GroupBox label) with tags is a RichTextLabel like an authored Label; a
## Button draws plain text (tags removed, one diagnostic).
func test_rich_text_in_control_parts() -> void:
	var doc := _doc('<ui:Toggle name="t" label="&lt;b&gt;Bold&lt;/b&gt; label" text="&lt;i&gt;it&lt;/i&gt;" />'
		+ '<ui:GroupBox name="g" text="&lt;color=red&gt;G&lt;/color&gt;" />'
		+ '<ui:Button name="b" text="&lt;b&gt;Go&lt;/b&gt;" />')
	await h.process_frame
	var lbl = doc._controls[_part(doc, "t", "label")]
	h.check(lbl is RichTextLabel, "Toggle label part with tags is a RichTextLabel")
	h.eq((lbl as RichTextLabel).get_parsed_text(), "Bold label", "the label part renders the styled runs")
	h.eq(lbl.mouse_filter, Control.MOUSE_FILTER_PASS, "the label part passes the mouse to the Toggle")
	h.check(doc._controls[_part(doc, "t", "text")] is RichTextLabel, "Toggle text part with tags")
	h.check(doc._controls[_part(doc, "g", "label")] is RichTextLabel, "GroupBox label part with tags")
	h.eq((doc.get_native("b") as Button).text, "Go", "Button text without tags")
	var n := 0
	for d in doc.diagnostics:
		if String(d["message"]).find("rich text tags on a Button") >= 0:
			n += 1
	h.eq(n, 1, "one diagnostic for the Button tags")
	h.check(doc.get_element("t").size.x > 0.0 and lbl.size.x > 0.0, "rich label parts lay out")
	_unload(doc)
