extends RefCounted
## Editor controls (runtime/controls/uxml_editor_parts.gd,
## uxml_editor_behaviors.gd, uxml_editor_widgets.gd): part trees, the
## editor theme, values, menus and popups, PropertyField and
## InspectorElement. Expected values come from Unity 6000.3 in an editor
## panel (bench/parity/unity/ed-*.json).
##
## `h` is the SceneTree harness from run_tests.gd.

const TMP := "user://godot_uxml_editor_tests"
const NS := 'xmlns:ui="UnityEngine.UIElements" xmlns:uie="UnityEditor.UIElements"'

var h = null


func _init(harness) -> void:
	h = harness


func _doc(body: String, skin := "dark", mode := "auto") -> UxmlDocument:
	DirAccess.make_dir_recursive_absolute(TMP + "/Assets")
	var x := FileAccess.open(TMP + "/Assets/t.uxml", FileAccess.WRITE)
	x.store_string('<ui:UXML %s>%s</ui:UXML>' % [NS, body])
	x.close()
	var doc := UxmlDocument.new()
	doc.editor_skin = skin
	doc.editor_theme = mode
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


func _kinds(doc: UxmlDocument, kind: String) -> Array:
	var out := []
	for d in doc.diagnostics:
		if d["kind"] == kind:
			out.append(d)
	return out


func _accept(c: Control) -> void:
	var ev := InputEventAction.new()
	ev.action = "ui_accept"
	ev.pressed = true
	c._gui_input(ev)


func _popups(c: Control) -> Array:
	var out := []
	for k in c.get_children():
		if k is Window:
			out.append(k)
	return out


func _layout(doc: UxmlDocument) -> void:
	doc._restyle_now()
	await h.process_frame
	doc._restyle_now()


## The Unity project data of the dump project (layers, tags).
func _unity_layers() -> void:
	var layers: Array = []
	layers.resize(32)
	layers.fill("")
	layers[0] = "Default"
	layers[1] = "TransparentFX"
	layers[2] = "Ignore Raycast"
	layers[4] = "Water"
	layers[5] = "UI"
	UxmlDocument.set_layer_names(layers)
	UxmlDocument.set_rendering_layer_names(["Default"])
	UxmlDocument.set_tags(UxmlEditorParts.UNITY_TAGS)


func _reset_layers() -> void:
	UxmlDocument.set_layer_names([])
	UxmlDocument.set_rendering_layer_names([])
	UxmlDocument.set_tags([])


# ---------------------------------------------------------------------------
# Tags, diagnostics, theme selection
# ---------------------------------------------------------------------------

func test_editor_tags_are_known() -> void:
	var doc := _doc('<uie:ColorField /><uie:CurveField /><uie:GradientField /><uie:ObjectField />'
		+ '<uie:EnumFlagsField /><uie:MaskField choices="A,B" /><uie:LayerField /><uie:LayerMaskField />'
		+ '<uie:RenderingLayerMaskField /><uie:TagField />'
		+ '<uie:Toolbar><uie:ToolbarButton text="B" /><uie:ToolbarToggle text="T" /><uie:ToolbarMenu text="M" />'
		+ '<uie:ToolbarSpacer flex="true" /><uie:ToolbarBreadcrumbs /><uie:ToolbarSearchField />'
		+ '<uie:ToolbarPopupSearchField /></uie:Toolbar>'
		+ '<uie:PropertyField binding-path="x" /><uie:InspectorElement />')
	h.eq(_kinds(doc, "unsupported-control").size(), 0, "no unsupported-control for editor tags")
	h.eq(_kinds(doc, "unsupported-attribute").size(), 0, "editor attributes are known")
	for t in UxmlEditorParts.TAGS:
		h.check(UssControls.is_known_control(t), "%s is a known control" % t)
	_unload(doc)


func test_editor_theme_selection() -> void:
	var doc := _doc('<uie:ColorField name="c" />')
	var origins := []
	for s in doc._doc.sheets:
		origins.append(String(s.get("origin", "")))
	h.check(origins.has(UxmlTheme.EDITOR) and origins.has(UxmlTheme.EDITOR_DARK), "auto: the editor sheets attach")
	h.check(not origins.has(UxmlTheme.DEFAULT), "the editor theme replaces the runtime theme")
	h.eq(UxmlTheme.editor_skin_of(doc._doc), "dark", "dark skin by default")
	_unload(doc)
	doc = _doc('<uie:ColorField name="c" />', "light")
	h.eq(UxmlTheme.editor_skin_of(doc._doc), "light", "light skin")
	var lab := UxmlParts.find_part(doc.get_element_model("c"), "label")
	h.check(lab == null, "no label part without a label")
	_unload(doc)
	# A runtime document compiles no editor rules.
	doc = _doc('<ui:Button name="b" text="B" />')
	h.eq(UxmlTheme.editor_skin_of(doc._doc), "", "runtime document: no editor theme")
	for s in doc._doc.sheets:
		h.check(not String(s.get("origin", "")).begins_with("res://addons/godot_uxml/themes/unity-editor"), "no editor sheet")
	_unload(doc)
	doc = _doc('<ui:Button name="b" text="B" />', "dark", "always")
	h.eq(UxmlTheme.editor_skin_of(doc._doc), "dark", "always: the editor theme for every document")
	h.eq(_val(doc, doc.get_element_model("b"), "background-color"), "rgb(88, 88, 88)", "editor Button colour (ed-runtime)")
	_unload(doc)
	doc = _doc('<uie:ColorField name="c" />', "dark", "never")
	h.eq(UxmlTheme.editor_skin_of(doc._doc), "", "never: the runtime theme")
	_unload(doc)


func test_editor_theme_values() -> void:
	# Measured: ed-runtime / ed-runtime-light (BaseField label, Label, font).
	var doc := _doc('<uie:ColorField name="c" label="Color" /><ui:Label name="l" text="x" />')
	var lab := _part(doc, "c", "label")
	h.eq(_val(doc, lab, "min-width"), "120px", "editor label min-width")
	h.eq(_val(doc, lab, "color"), "rgb(196, 196, 196)", "dark label colour")
	h.eq(_val(doc, doc.get_element_model("l"), "font-size"), "12px", "editor font size")
	_unload(doc)
	doc = _doc('<uie:ColorField name="c" label="Color" />', "light")
	h.eq(_val(doc, _part(doc, "c", "label"), "color"), "rgb(9, 9, 9)", "light label colour")
	_unload(doc)


# ---------------------------------------------------------------------------
# ColorField
# ---------------------------------------------------------------------------

func test_color_field_parts() -> void:
	var doc := _doc('<uie:ColorField name="c" label="Color" value="#FF000080" />'
		+ '<uie:ColorField name="h" hdr="true" show-alpha="false" show-eye-dropper="false" />')
	var c := doc.get_element_model("c")
	var input := _part(doc, "c", "input")
	h.eq(_sorted(_classes(input)), _sorted(["unity-base-field__input", "unity-color-field__input"]), "input classes")
	var names := []
	for k in _part(doc, "c", "color-container").children:
		names.append(String(k.get_attribute("name") if k.get_attribute("name") != null else ""))
	h.eq(names, ["unity-internal-color-field", "unity-gradient-container", "unity-alpha-gradient-container",
		"unity-hdr-label", "unity-mixed-value-label", "unity-alpha-progress"], "color container parts (ed-colorfield)")
	h.eq(String(_part(doc, "c", "color").get_attribute("style")), "background-color: rgba(255, 0, 0, 1);", "swatch is the opaque colour")
	h.eq(String(_part(doc, "c", "gradient-container").get_attribute("style")), UxmlParts.HIDDEN, "no HDR strips")
	var pb := _part(doc, "c", "alpha-progress")
	h.eq(String(pb.get_attribute("value")), "50.1961", "alpha bar value = alpha x 100")
	h.eq(String(_part(doc, "h", "hdr-label").get_attribute("style") if _part(doc, "h", "hdr-label").get_attribute("style") != null else ""), "", "hdr shows the HDR label")
	h.eq(String(_part(doc, "h", "alpha-progress").get_attribute("style")), UxmlParts.HIDDEN, "show-alpha=false hides the bar")
	h.eq(String(_part(doc, "h", "eyedropper").get_attribute("style")), UxmlParts.HIDDEN, "show-eye-dropper=false hides the dropper")
	h.eq(_sorted(_classes(c)), ["unity-base-field", "unity-color-field"], "ColorField classes")
	await _layout(doc)
	# Unity's alpha bar: right = floor(w - 2) - w' x alpha in px.
	var prog := UxmlParts.find_part(pb, "progress")
	h.check(String(prog.get_attribute("style")).ends_with("px;"), "alpha bar right in px after layout")
	_unload(doc)


func test_color_field_value() -> void:
	var doc := _doc('<uie:ColorField name="c" value="#00FF00" />')
	var got := []
	doc.value_changed.connect(func(n, v): got.append([n, v]))
	var b = doc._behaviors[doc.get_element_model("c")]
	h.eq(b.bind_read("value"), [true, Color(0, 1, 0, 1)], "value from the attribute")
	b.set_value(Color(0, 0, 1, 1), true)
	h.eq(got, [["c", Color(0, 0, 1, 1)]], "value_changed sends the Color")
	h.eq(String(_part(doc, "c", "color").get_attribute("style")), "background-color: rgba(0, 0, 255, 1);", "swatch follows")
	h.eq(b.bind_write("value", Color(1, 1, 1, 1)), 1, "binding writes the value")
	h.eq(b.bind_read("value")[1], Color(1, 1, 1, 1), "binding value")
	# A non-HDR field clamps.
	b.set_value(Color(2, 0, 0, 1), true)
	h.eq(b.get_value(), Color(1, 0, 0, 1), "LDR value clamps to 1")
	# The picker opens on ui_accept.
	var c := doc.get_native("c")
	_accept(c)
	await h.process_frame
	var pops := _popups(doc.get_native("c")) + _popups(doc.get_element("c").get_child(0) if doc.get_element("c").get_child_count() > 0 else doc.get_native("c"))
	var found := false
	for x in doc.get_native("c").find_children("*", "ColorPicker", true, false):
		found = true
	for x in doc.find_children("*", "ColorPicker", true, false):
		found = true
	h.check(found or pops.size() > 0, "ui_accept opens a ColorPicker popup")
	h.check(doc._states.get(doc.get_element_model("c"), {}).has("active"), "field is :active while the picker is open")
	_unload(doc)


# ---------------------------------------------------------------------------
# CurveField, GradientField
# ---------------------------------------------------------------------------

class CurveSource extends Object:
	signal property_changed(path)
	var curve: Curve = Curve.new()
	var gradient: Gradient = Gradient.new()


func test_curve_and_gradient_fields() -> void:
	var doc := _doc('<uie:CurveField name="cu" label="Curve" binding-path="curve" />'
		+ '<uie:GradientField name="g" label="Gradient" binding-path="gradient" color-space="Linear" />')
	var src := CurveSource.new()
	src.curve.add_point(Vector2(0, 0))
	src.curve.add_point(Vector2(1, 1))
	doc.set_data_source(src)
	doc.update_bindings()
	var cv := doc._controls.get(_part(doc, "cu", "input")) as UxmlEditorWidgets.CurveView
	h.check(cv != null, "the CurveField input is a CurveView")
	h.check(cv != null and cv.curve == src.curve, "the bound Curve reaches the view")
	await _layout(doc)
	h.eq(cv.color if cv != null else Color(), Color(0, 1, 0), "--unity-curve-color (ed-curve-gradient)")
	var gv := doc._controls.get(_part(doc, "g", "content")) as UxmlEditorWidgets.GradientView
	h.check(gv != null and gv.gradient == src.gradient, "the bound Gradient reaches the view")
	h.check(gv != null and gv.linear, "color-space Linear")
	# The curve editor edits a copy and writes it back through the binding.
	var b = doc._behaviors[doc.get_element_model("cu")]
	_accept(doc.get_native("cu"))
	await h.process_frame
	var eds := doc.find_children("*", "", true, false).filter(func(n): return n is UxmlEditorWidgets.CurveEditor)
	h.eq(eds.size(), 1, "ui_accept opens the curve editor")
	if eds.size() == 1:
		var ed: UxmlEditorWidgets.CurveEditor = eds[0]
		ed.curve.add_point(Vector2(0.5, 0.25))
		ed._changed()
		h.check(src.curve == ed.curve, "the edited curve goes to the source (TwoWay)")
		h.eq(src.curve.point_count, 3, "edited curve has the new point")
	h.check(b != null, "behavior")
	src.free()
	_unload(doc)


# ---------------------------------------------------------------------------
# ObjectField
# ---------------------------------------------------------------------------

func test_object_field() -> void:
	var doc := _doc('<uie:ObjectField name="o" label="Texture" type="UnityEngine.Texture2D, UnityEngine.CoreModule" />'
		+ '<uie:ObjectField name="any" />')
	var lab := _part(doc, "o", "display-label")
	h.eq(String(lab.get_attribute("text")), "None (Texture 2D)", "null label (ed-objectfield)")
	h.check(UxmlParts.control_classes(lab).has("unity-object-field-display__label--value-null"), "--value-null")
	h.eq(String(_part(doc, "any", "display-label").get_attribute("text")), "None (Object)", "Object type")
	h.eq(UxmlEditorParts.godot_class(doc.get_element_model("o")), "Texture2D", "Unity Texture2D maps to Godot Texture2D")
	h.eq(UxmlEditorParts.godot_class(doc.get_element_model("any")), "Resource", "Unity Object maps to Resource")
	var b = doc._behaviors[doc.get_element_model("o")]
	var got := []
	doc.value_changed.connect(func(n, v): got.append(n))
	var tex := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	tex.resource_name = "tile"
	h.check(b.set_value(tex, true), "a Texture2D is accepted")
	h.eq(String(lab.get_attribute("text")), "tile", "label shows the resource name")
	h.check(not UxmlParts.control_classes(lab).has("unity-object-field-display__label--value-null"), "--value-null removed")
	h.eq(got, ["o"], "value_changed")
	h.check(not b.set_value(Curve.new(), true), "a Curve is rejected by a Texture2D field")
	h.check(b._can_drop(Vector2.ZERO, {"resource": tex}), "drop of a matching resource")
	h.check(not b._can_drop(Vector2.ZERO, {"resource": Curve.new()}), "drop of another type")
	# The picker callback replaces the built-in picker.
	var asked := []
	UxmlDocument.set_object_picker(func(ctx):
		asked.append(ctx["type"])
		ctx["set_value"].call(null))
	_accept(doc.get_native("o"))
	h.eq(asked, ["Texture2D"], "set_object_picker gets the Godot type")
	h.eq(String(lab.get_attribute("text")), "None (Texture 2D)", "picker callback sets the value")
	UxmlDocument.set_object_picker(Callable())
	# The built-in picker lists res:// files of the type.
	var files := UxmlEditorWidgets.ObjectPicker.resource_files("Texture2D")
	h.check(files.size() > 0 and files[0].begins_with("res://"), "res:// textures for the picker")
	var gds := UxmlEditorWidgets.ObjectPicker.resource_files("Script")
	h.check(gds.has("res://tests/test_editor.gd"), "scripts for a Script field")
	_unload(doc)


# ---------------------------------------------------------------------------
# Mask, enum flags, layer and tag fields
# ---------------------------------------------------------------------------

func test_mask_field() -> void:
	var doc := _doc('<uie:MaskField name="m" label="Mask" choices="One,Two,Three" value="5" />'
		+ '<uie:MaskField name="n" choices="One,Two,Three" value="0" />'
		+ '<uie:MaskField name="e" choices="One,Two,Three" value="7" />'
		+ '<uie:MaskField name="k" choices="Low,High" choices-masks="1,8" value="8" />')
	h.eq(String(_part(doc, "m", "text").get_attribute("text")), "One, Three", "two entries (ed-masks)")
	h.eq(String(_part(doc, "n", "text").get_attribute("text")), "Nothing", "0 is Nothing")
	h.eq(String(_part(doc, "e", "text").get_attribute("text")), "Everything", "a full mask is Everything")
	h.eq(doc._behaviors[doc.get_element_model("e")].get_value(), -1, "a full mask is stored as -1")
	h.eq(String(_part(doc, "k", "text").get_attribute("text")), "High", "choices-masks")
	var b = doc._behaviors[doc.get_element_model("m")]
	var items: Array = b.menu_items()
	h.eq(items[0], ["Nothing", false], "menu: Nothing")
	h.eq(items[1], ["Everything", false], "menu: Everything")
	h.eq(items[2], ["One", true], "menu: checked entry")
	h.eq(items[3], ["Two", false], "menu: unchecked entry")
	var got := []
	doc.value_changed.connect(func(n, v): got.append([n, v]))
	b.chosen(3, true)  # Two
	h.eq(b.get_value(), -1, "One + Two + Three = Everything")
	b.chosen(0, true)  # Nothing
	h.eq(b.get_value(), 0, "Nothing")
	b.chosen(2, true)
	h.eq(got.back(), ["m", 1], "value_changed sends the int mask")
	# The menu is a Godot PopupMenu (Unity's editor uses an OS menu).
	_accept(doc.get_native("m"))
	await h.process_frame
	var menus := doc.find_children("*", "PopupMenu", true, false)
	h.eq(menus.size(), 1, "ui_accept opens a PopupMenu")
	if menus.size() == 1:
		var pm: PopupMenu = menus[0]
		h.eq(pm.item_count, 5, "Nothing, Everything, three entries")
		h.check(pm.is_item_checked(2), "checked entry")
		pm.hide()
	h.eq(b.bind_write("value", 2), 2, "binding writes the mask")
	h.eq(String(_part(doc, "m", "text").get_attribute("text")), "Two", "text follows")
	_unload(doc)


func test_enum_flags_field() -> void:
	UxmlDocument.register_enum("TestFlags", {"None": 0, "Alpha": 1, "Beta": 2, "Gamma": 4, "AlphaBeta": 3})
	var doc := _doc('<uie:EnumFlagsField name="f" type="TestFlags, Assembly" value="Alpha, Gamma" />'
		+ '<uie:EnumFlagsField name="z" type="TestFlags" value="None" />'
		+ '<uie:EnumFlagsField name="ab" type="TestFlags" value="Alpha, Beta" />')
	h.eq(String(_part(doc, "f", "text").get_attribute("text")), "Alpha, Gamma", "flag names (ed-masks)")
	h.eq(String(_part(doc, "z", "text").get_attribute("text")), "None", "the 0 entry")
	h.eq(String(_part(doc, "ab", "text").get_attribute("text")), "Alpha Beta", "an exact composite entry")
	var b = doc._behaviors[doc.get_element_model("f")]
	h.eq(b.get_value(), 5, "value")
	b.chosen(1, true)
	h.eq(b.get_value(), 7, "Everything sets every flag")
	UxmlDocument.unregister_enum("TestFlags")
	_unload(doc)


func test_layer_and_tag_fields() -> void:
	_unity_layers()
	var doc := _doc('<uie:LayerField name="l" value="4" /><uie:LayerMaskField name="lm" value="3" />'
		+ '<uie:RenderingLayerMaskField name="r" /><uie:TagField name="t" value="Player" />')
	h.eq(String(_part(doc, "l", "text").get_attribute("text")), "Water", "layer 4 (ed-masks)")
	h.eq(String(_part(doc, "lm", "text").get_attribute("text")), "Default, TransparentFX", "layer mask")
	h.eq(String(_part(doc, "r", "text").get_attribute("text")), "Everything", "rendering layers: Everything by default")
	h.check(_part(doc, "r", "help-box") != null, "RenderingLayerMaskField warning HelpBox part")
	h.eq(String(_part(doc, "t", "text").get_attribute("text")), "Player", "tag")
	var lb = doc._behaviors[doc.get_element_model("l")]
	h.eq(lb.menu_items().size(), 5, "LayerField lists the named layers")
	lb.chosen(0, true)
	h.eq(lb.get_value(), 0, "Default is layer 0")
	var tb = doc._behaviors[doc.get_element_model("t")]
	tb.chosen(3, true)
	h.eq(tb.get_value(), "EditorOnly", "tag chosen")
	_unload(doc)
	# Godot's project settings: named 3D physics layers, else "Layer N".
	_reset_layers()
	var names := UxmlEditorParts.layer_names()
	h.eq(names.size(), 32, "32 layers")
	var tags := UxmlEditorParts.tags()
	h.eq(tags[0], "Untagged", "tags start with Untagged")
	ProjectSettings.set_setting("layer_names/3d_physics/layer_2", "Enemies")
	h.eq(UxmlEditorParts.layer_names()[1], "Enemies", "3D physics layer names")
	ProjectSettings.set_setting("layer_names/3d_physics/layer_2", "")


# ---------------------------------------------------------------------------
# Toolbar
# ---------------------------------------------------------------------------

func test_toolbar_controls() -> void:
	var doc := _doc('<uie:Toolbar name="tb"><uie:ToolbarButton name="b" text="Button" />'
		+ '<uie:ToolbarToggle name="t" text="Toggle" /><uie:ToolbarMenu name="m" text="Menu" />'
		+ '<uie:ToolbarSpacer name="s" /><uie:ToolbarSpacer name="f" flex="true" /></uie:Toolbar>')
	h.eq(_sorted(_classes(doc.get_element_model("b"))), ["unity-text-element", "unity-toolbar-button"], "ToolbarButton has no unity-button")
	h.check(doc.get_native("b") is Button, "ToolbarButton is a Button")
	var pressed := []
	doc.button_pressed.connect(func(n): pressed.append(n))
	(doc.get_native("b") as Button).pressed.emit()
	h.eq(pressed, ["b"], "button_pressed")
	var vals := []
	doc.value_changed.connect(func(n, v): vals.append([n, v]))
	(doc.get_native("t") as UxmlToggle).button_pressed = true
	h.eq(vals, [["t", true]], "ToolbarToggle value_changed")
	h.check(doc._states.get(doc.get_element_model("t"), {}).has("checked"), "checked ToolbarToggle is :checked")
	h.check(UxmlParts.control_classes(doc.get_element_model("f")).has("unity-toolbar-spacer--flexible"), "flex=true")
	h.check(not UxmlParts.control_classes(doc.get_element_model("s")).has("unity-toolbar-spacer--flexible"), "no flex")
	doc.get_element_model("s").set_attribute("flex", "true")
	h.check(UxmlParts.control_classes(doc.get_element_model("s")).has("unity-toolbar-spacer--flexible"), "flex after load")
	h.eq(String(_part(doc, "m", "text").get_attribute("text")), "Menu", "ToolbarMenu text part")
	var chosen := []
	doc.set_menu_items("m", ["Open", {"text": "Close", "checked": true}, "-", "Quit"], func(i, t): chosen.append([i, t]))
	_accept(doc.get_native("m"))
	await h.process_frame
	var menus := doc.find_children("*", "PopupMenu", true, false)
	h.eq(menus.size(), 1, "ToolbarMenu opens a PopupMenu")
	if menus.size() == 1:
		var pm: PopupMenu = menus[0]
		pm.id_pressed.emit(3)
		h.eq(chosen, [[3, "Quit"]], "menu callback gets the index and text")
		pm.hide()
	await _layout(doc)
	h.eq(_val(doc, doc.get_element_model("tb"), "height"), "21px", "toolbar height (ed-toolbar)")
	h.eq(_val(doc, doc.get_element_model("s"), "width"), "6px", "spacer width")
	_unload(doc)


func test_toolbar_breadcrumbs() -> void:
	var doc := _doc('<uie:Toolbar><uie:ToolbarBreadcrumbs name="bc" /></uie:Toolbar>')
	var clicked := []
	doc.push_breadcrumb("bc", "Root", func(): clicked.append("Root"))
	doc.push_breadcrumb("bc", "Child")
	var bc := doc.get_element_model("bc")
	var items := bc.children.filter(func(c): return c.part_role == "item")
	h.eq(items.size(), 2, "two items")
	h.check(UxmlParts.control_classes(items[0]).has("unity-toolbar-breadcrumbs__first-item"), "first item class")
	h.check(not UxmlParts.control_classes(items[1]).has("unity-toolbar-breadcrumbs__first-item"), "second item")
	var btn := doc._controls.get(items[0]) as Button
	h.check(btn != null, "an item is a Button")
	if btn != null:
		btn.pressed.emit()
	h.eq(clicked, ["Root"], "item callback")
	doc.pop_breadcrumb("bc")
	h.eq(bc.children.filter(func(c): return c.part_role == "item").size(), 1, "pop removes the last")
	await _layout(doc)
	h.check(doc._controls.get(items[0]) != null, "first item keeps its control")
	_unload(doc)


func test_search_fields() -> void:
	var doc := _doc('<uie:Toolbar><uie:ToolbarSearchField name="s" value="abc" />'
		+ '<uie:ToolbarPopupSearchField name="p" /></uie:Toolbar>')
	var s := doc.get_element_model("s")
	var cancel := UxmlParts.find_part(s, "cancel-button")
	h.check(UxmlParts.control_classes(cancel).has("unity-search-field-base__cancel-button--off"),
		"Unity 6000.3 reads no UXML value: --off (ed-toolbar-states)")
	var b = doc._behaviors[s]
	var got := []
	doc.value_changed.connect(func(n, v): got.append([n, v]))
	h.eq(b.bind_write("value", "find"), 1, "binding sets the text")
	h.check(not UxmlParts.control_classes(cancel).has("unity-search-field-base__cancel-button--off"), "cancel shows")
	var le := doc.get_native("s") as LineEdit
	h.check(le != null and le.text == "find", "the LineEdit shows the text")
	if le != null:
		le.text_changed.emit("found")
		le.text = "found"
		le.text_changed.emit("found")
	h.eq(got.back() if not got.is_empty() else null, ["s", "found"], "typing sends value_changed")
	(doc._controls.get(cancel) as BaseButton).pressed.emit()
	h.eq(b.bind_read("value"), [true, ""], "cancel clears")
	h.check(UxmlParts.control_classes(cancel).has("unity-search-field-base__cancel-button--off"), "--off again")
	var p := doc.get_element_model("p")
	h.check(p.class_list().has("unity-search-field-base--popup") or UssControls.implicit_classes_of("ToolbarPopupSearchField").has("unity-search-field-base--popup"), "popup class")
	var chosen := []
	doc.set_menu_items("p", ["Name", "Type"], func(i, t): chosen.append(t))
	(doc._controls.get(UxmlParts.find_part(p, "search-button")) as BaseButton).pressed.emit()
	await h.process_frame
	var menus := doc.find_children("*", "PopupMenu", true, false)
	h.eq(menus.size(), 1, "the popup search button opens the menu")
	if menus.size() == 1:
		(menus[0] as PopupMenu).id_pressed.emit(1)
		(menus[0] as PopupMenu).hide()
	h.eq(chosen, ["Type"], "search menu callback")
	_unload(doc)


# ---------------------------------------------------------------------------
# PropertyField, InspectorElement
# ---------------------------------------------------------------------------

class Target extends Object:
	signal property_changed(path)
	enum Mode { First, SecondValue, Third }
	@export var intValue: int = 42
	@export var move_speed: float = 1.5
	@export var title: String = "hello"
	@export var active: bool = true
	@export var tint: Color = Color(1, 0.5, 0, 1)
	@export var offset: Vector2 = Vector2(1, 2)
	@export var mode: Mode = Mode.SecondValue
	@export_flags("Alpha", "Beta", "Gamma") var flags: int = 5
	@export_range(0, 10) var level: int = 3
	@export var texture: Texture2D


func test_property_field() -> void:
	var doc := _doc('<uie:PropertyField name="i" binding-path="intValue" />'
		+ '<uie:PropertyField name="f" binding-path="move_speed" label="Custom" />'
		+ '<uie:PropertyField name="s" binding-path="title" />'
		+ '<uie:PropertyField name="b" binding-path="active" />'
		+ '<uie:PropertyField name="c" binding-path="tint" />'
		+ '<uie:PropertyField name="v" binding-path="offset" />'
		+ '<uie:PropertyField name="e" binding-path="mode" />'
		+ '<uie:PropertyField name="fl" binding-path="flags" />'
		+ '<uie:PropertyField name="r" binding-path="level" />'
		+ '<uie:PropertyField name="t" binding-path="texture" />')
	h.eq(doc.get_element_model("i").children.size(), 0, "no field before the bind (as Unity)")
	var src := Target.new()
	doc.set_data_source(src)
	doc.update_bindings()
	var expect := {"i": "IntegerField", "f": "FloatField", "s": "TextField", "b": "Toggle", "c": "ColorField",
		"v": "Vector2Field", "e": "PopupField`1", "fl": "EnumFlagsField", "r": "SliderInt", "t": "ObjectField"}
	for n in expect:
		var pf := doc.get_element_model(n)
		var field: UxmlElement = pf.children[0] if pf.children.size() > 0 else null
		h.eq(field.local if field != null else "", expect[n], "PropertyField %s builds %s" % [n, expect[n]])
	var fi: UxmlElement = doc.get_element_model("i").children[0]
	h.eq(String(fi.get_attribute("name")), "unity-input-intValue", "field name (ed-propertyfield)")
	h.eq(String(fi.get_attribute("label")), "Int Value", "nicified label")
	h.eq(String(doc.get_element_model("f").children[0].get_attribute("label")), "Custom", "label attribute")
	h.eq(String(doc.get_element_model("s").children[0].get_attribute("label")), "Title", "snake/plain label")
	h.check(UxmlParts.control_classes(fi).has("unity-base-field__aligned"), "__aligned")
	h.check(UxmlParts.find_part(fi, "label").class_list().has("unity-property-field__label"), "label class")
	h.check(UxmlParts.find_part(fi, "input").class_list().has("unity-property-field__input"), "input class")
	h.eq(String(UxmlParts.find_part(doc.get_element_model("e").children[0], "text").get_attribute("text")),
		"Second Value", "enum shows the nicified name")
	h.eq(String(UxmlParts.find_part(doc.get_element_model("fl").children[0], "text").get_attribute("text")),
		"Alpha, Gamma", "flags text")
	# Edits write back (TwoWay) and send value_changed with the PropertyField name.
	var got := []
	doc.value_changed.connect(func(n, v): got.append([n, v]))
	var fb = doc._behaviors[fi]
	var le := doc._natives.get(fi) as LineEdit
	if le != null:
		le.text = "7"
		le.text_changed.emit("7")
	h.eq(src.intValue, 7, "the edit writes the source")
	h.check(got.has(["i", 7]), "value_changed from the PropertyField")
	src.intValue = 9
	doc.notify_changed(src, "intValue")
	doc.update_bindings()
	h.eq(fb.bind_read("value"), [true, 9], "source change reaches the field")
	var eb = doc._behaviors[doc.get_element_model("e").children[0]]
	eb.choose(2, true)
	h.eq(src.mode, Target.Mode.Third, "enum edit writes the enum value")
	await _layout(doc)
	src.free()
	_unload(doc)


class Small extends Object:
	signal property_changed(path)
	@export var count: int = 3
	@export var title: String = "Hi"
	@export var active: bool = false


func test_inspector_element() -> void:
	var doc := _doc('<uie:InspectorElement name="insp" />')
	doc.size = Vector2(450, 300)
	var insp := doc.get_element_model("insp")
	h.check(UxmlParts.control_classes(insp).has("unity-inspector-element--uie"), "inspector classes")
	var obj := Small.new()
	doc.set_data_source(obj, "insp")
	doc.update_bindings()
	var content := UxmlParts.content_container(insp)
	var names := []
	for pf in content.children:
		names.append(String(pf.get_attribute("name")))
	# A scripted object lists its script first (Unity's m_Script).
	h.eq(names, ["PropertyField:m_Script", "PropertyField:count", "PropertyField:title", "PropertyField:active"],
		"one PropertyField per property")
	var count_field: UxmlElement = content.children[1].children[0]
	h.check(UxmlParts.control_classes(count_field).has("unity-base-field__inspector-field"), "inspector field class")
	h.check(UxmlParts.control_classes(content.children[1]).has("unity-property-field__inspector-property"), "inspector property class")
	await _layout(doc)
	await _layout(doc)
	var lab := UxmlParts.find_part(count_field, "label")
	# BaseField.AlignLabel at 450px: (450 + 1) x 0.45 - (37 + 3) = 162.95.
	h.eq(String(lab.get_attribute("style")), "min-width: 120px; width: 162.95px;", "label alignment (ed-inspector)")
	var tb = doc._behaviors[count_field]
	tb.bind_write("value", 5)
	var le := doc._natives.get(count_field) as LineEdit
	if le != null:
		le.text = "11"
		le.text_changed.emit("11")
	h.eq(obj.count, 11, "inspector edit writes the object")
	obj.free()
	_unload(doc)


func test_inspector_script_field() -> void:
	var doc := _doc('<uie:InspectorElement name="insp" />')
	var res := load("res://tests/fixtures/editor/inspected.gd").new() as Resource
	doc.set_data_source(res, "insp")
	doc.update_bindings()
	var content := UxmlParts.content_container(doc.get_element_model("insp"))
	var first: UxmlElement = content.children[0]
	h.eq(String(first.get_attribute("name")), "PropertyField:m_Script", "the script field first, as Unity's m_Script")
	h.check(UxmlParts.control_classes(first).has("unity-disabled"), "script field disabled")
	h.eq(String(UxmlParts.find_part(first.children[0], "display-label").get_attribute("text")), "inspected",
		"script field shows the script name")
	_unload(doc)
