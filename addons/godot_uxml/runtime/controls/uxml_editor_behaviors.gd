class_name UxmlEditorBehaviors
extends RefCounted
## Behaviors of the editor controls (UxmlEditorParts builds their parts,
## UxmlEditorWidgets holds their Godot controls and popups):
##
##   ColorBehavior        ColorField: Color value, ColorPicker, eyedropper
##   CurveBehavior        CurveField: Curve value, curve editor
##   GradientBehavior     GradientField: Gradient value, gradient editor
##   ObjectBehavior       ObjectField: Object value, object picker, drop
##   MaskBehavior         EnumFlagsField, MaskField, LayerMaskField,
##                        RenderingLayerMaskField: int mask, check menu
##   LayerBehavior        LayerField (int layer), TagField (String tag)
##   ToolbarButtonBehavior ToolbarButton, BreadcrumbItem: button_pressed
##   ToolbarMenuBehavior  ToolbarMenu: a menu of set_menu_items() entries
##   SpacerBehavior       ToolbarSpacer: `flex`
##   BreadcrumbsBehavior  ToolbarBreadcrumbs: push and pop items
##   SearchBehavior       ToolbarSearchField, ToolbarPopupSearchField
##   PropertyFieldBehavior PropertyField: the field of the bound property
##   InspectorBehavior    InspectorElement: one PropertyField per property
##
## A behavior writes the model and lets the cascade and the layout react,
## as the runtime control behaviors do (UxmlBehaviors).


static func create(el: UxmlElement) -> UxmlBehaviors.Behavior:
	match el.local:
		"ColorField":
			return ColorBehavior.new()
		"CurveField":
			return CurveBehavior.new()
		"GradientField":
			return GradientBehavior.new()
		"ObjectField":
			return ObjectBehavior.new()
		"EnumFlagsField", "MaskField", "LayerMaskField", "RenderingLayerMaskField":
			return MaskBehavior.new()
		"LayerField", "TagField":
			return LayerBehavior.new()
		"PopupField`1":
			return UxmlInputBehaviors.PopupBehavior.new()
		"ToolbarButton", "BreadcrumbItem":
			return ToolbarButtonBehavior.new()
		"ToolbarToggle":
			return UxmlBehaviors.ToggleBehavior.new()
		"ToolbarMenu":
			return ToolbarMenuBehavior.new()
		"ToolbarSpacer":
			return SpacerBehavior.new()
		"ToolbarBreadcrumbs":
			return BreadcrumbsBehavior.new()
		"ToolbarSearchField", "ToolbarPopupSearchField":
			return SearchBehavior.new()
		"PropertyField":
			return PropertyFieldBehavior.new()
		"InspectorElement":
			return InspectorBehavior.new()
	return null


## Add `sub` (a model subtree: parts with their own part trees) under
## `parent` after load: controls, signals, behaviors, and a rebuild of the
## cascade and the layout caches (UxmlDocument._structure_changed). Unity
## adds these elements at run time too (PropertyField at bind time,
## ToolbarBreadcrumbs.PushItem).
static func insert(doc, parent: UxmlElement, sub: UxmlElement, at: int = -1) -> void:
	if at < 0 or at >= parent.children.size():
		parent.children.append(sub)
		at = -1
	else:
		parent.children.insert(at, sub)
	var factory := UxmlControlFactory.new(doc._resolver, doc._doc.path, doc._doc.source, doc._rt_warnings)
	factory.element_paths = doc._doc.element_paths
	var c := factory.build(sub)
	var pc: Control = doc._controls.get(parent)
	if pc != null:
		pc.add_child(c)
		if at >= 0:
			pc.move_child(c, at)
	for e in factory.controls:
		doc._controls[e] = factory.controls[e]
		doc._el_of[factory.controls[e]] = e
	for e in factory.natives:
		doc._natives[e] = factory.natives[e]
	var on_changed: Callable = doc._on_model_changed
	for e in sub.walk():
		e.changed = on_changed
	for e in factory.controls:
		doc._wire(e, factory.controls[e])
	var made: Array = []
	for e in sub.walk():
		var b := UxmlBehaviors._create(e)
		if b == null:
			continue
		b.doc = doc
		b.el = e
		doc._behaviors[e] = b
		made.append(b)
	doc._structure_changed()
	for b in made:
		b.setup()


## Remove `sub` (added by insert) from the model and the scene.
static func remove(doc, sub: UxmlElement) -> void:
	var parent = doc._parents.get(sub)
	if parent != null:
		(parent as UxmlElement).children.erase(sub)
	var top: Control = doc._controls.get(sub)
	for e in sub.walk():
		var c: Control = doc._controls.get(e)
		if c != null:
			doc._el_of.erase(c)
		doc._controls.erase(e)
		doc._natives.erase(e)
		doc._behaviors.erase(e)
		doc._states.erase(e)
		doc._binding.remove_binding(e, "")
	if top != null:
		if top.get_parent() != null:
			top.get_parent().remove_child(top)
		top.queue_free()
	doc._structure_changed()


# ---------------------------------------------------------------------------

## Shared helpers: focus on the input part, the popup anchor, validation.
class EditorBehavior extends UxmlInputBehaviors.InputBehavior:
	var _popup: Window = null

	func setup() -> void:
		var c := doc._controls.get(el) as UxmlPopupField
		if c != null:
			c.behavior = self
			c.focus_entered.connect(_on_focus.bind(true))
			c.focus_exited.connect(_on_focus.bind(false))
		validate_editor()

	func native() -> Control:
		return doc._controls.get(el)

	## Unity puts :focus on the input of a focused field.
	func _on_focus(on: bool) -> void:
		set_state(part("input"), "focus", on)

	func anchor() -> Control:
		var a := control_of(part("input"))
		return a if a != null else native()

	## A part control under the global point `gp`.
	func hit(role: String, gp: Vector2) -> bool:
		var c := control_of(part(role))
		return c != null and c.is_visible_in_tree() and c.get_global_rect().has_point(gp)

	## Opening input: a left press or `ui_accept`. Returns the global point
	## of a press (Vector2.INF for a key), or null.
	func opening(ev: InputEvent) -> Variant:
		var c := native()
		if c == null or is_disabled():
			return null
		var mb := ev as InputEventMouseButton
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			c.grab_focus()
			c.accept_event()
			return c.get_global_transform() * mb.position
		if ev.is_action_pressed("ui_accept") and not ev.is_echo():
			c.accept_event()
			return Vector2.INF
		return null

	func popup_open() -> bool:
		return _popup != null and is_instance_valid(_popup) and _popup.visible

	func track(p: Window) -> void:
		_popup = p
		set_state(el, "active", true)
		p.popup_hide.connect(func():
			set_state(el, "active", false)
			var c := native()
			if c != null and c.is_inside_tree():
				c.grab_focus())

	## Booleans of the editor attributes give `unsupported-value` when they
	## are not bools.
	func validate_editor() -> void:
		if el.part_of != null:
			return
		for n in ["show-alpha", "hdr", "show-eye-dropper", "allow-scene-objects", "flex"]:
			var v = el.get_attribute(n)
			if v != null and not String(v).to_lower() in ["true", "false", "1", "0"]:
				warn('"%s" is not a valid bool for %s; the default is used' % [v, n])

	func label_write(prop: String, v: Variant) -> int:
		if prop == "label":
			return write_attr("label", UxmlBinding._str(v), 2)
		return UNHANDLED

	func on_model_changed() -> void:
		sync_text("label", "label")


# ---------------------------------------------------------------------------
# ColorField
# ---------------------------------------------------------------------------

class ColorBehavior extends EditorBehavior:
	var _value := Color(0, 0, 0, 0)

	func setup() -> void:
		super.setup()
		_value = UxmlEditorParts.color_value(el)
		doc._layout_hooks.append(_after_layout)

	## Unity's alpha bar width from the laid-out bar.
	func _after_layout() -> void:
		UxmlEditorParts.color_alpha_layout(el, func(x: UxmlElement):
			var c := control_of(x)
			return null if c == null else c.size)

	func on_input(ev: InputEvent) -> void:
		var at = opening(ev)
		if at == null:
			return
		if at != Vector2.INF and hit("eyedropper", at):
			UxmlEditorWidgets.start_eyedropper(native(), func(c: Color): set_value(Color(c.r, c.g, c.b, _value.a), true))
			return
		if popup_open():
			return
		track(UxmlEditorWidgets.open_color_picker(anchor(), _value, flag("show-alpha", true), flag("hdr", false),
			func(c: Color): set_value(c, true)))

	func get_value() -> Color:
		return _value

	func set_value(c: Color, notify: bool) -> bool:
		if not flag("show-alpha", true):
			c.a = _value.a if notify else c.a
		if not flag("hdr", false):
			c = c.clamp()
		if c == _value:
			return false
		_value = c
		quiet_attr("value", UxmlEditorParts.color_text(c))
		UxmlEditorParts.color_styles(el, c)
		if notify:
			emit_value(c)
		return true

	func on_model_changed() -> void:
		super.on_model_changed()
		if _syncing:
			return
		var c := UxmlEditorParts.color_value(el)
		_value = c
		UxmlEditorParts.color_styles(el, c)

	func bind_write(prop: String, v: Variant) -> int:
		match prop:
			"value":
				var c := v as Color if v is Color else UssValues.parse_color(UxmlBinding._str(v)).get("color", Color(0, 0, 0, 0))
				return 1 if set_value(c, false) else 0
			"show-alpha", "hdr", "show-eye-dropper":
				return write_attr(prop, "true" if UxmlBinding._bool(v) else "false")
		return label_write(prop, v)

	func bind_read(prop: String) -> Array:
		if prop == "value":
			return [true, _value]
		return [false, null]


# ---------------------------------------------------------------------------
# CurveField, GradientField
# ---------------------------------------------------------------------------

class CurveBehavior extends EditorBehavior:
	var _value: Curve = null

	func setup() -> void:
		super.setup()
		var init = (el.get_meta(&"uxml_initial_value") if el.has_meta(&"uxml_initial_value") else null)
		_value = init as Curve
		_view()
		doc._layout_hooks.append(_after_layout)

	func _view() -> void:
		var v := control_of(part("input")) as UxmlEditorWidgets.CurveView
		if v != null:
			v.curve = _value

	## --unity-curve-color of the input after each restyle.
	func _after_layout() -> void:
		var v := control_of(part("input")) as UxmlEditorWidgets.CurveView
		if v == null:
			return
		var e = style_of(part("input")).get("--unity-curve-color")
		if e != null:
			var r := UssValues.parse_color(String(e["value"]))
			if r["ok"] and r["color"] != v.color:
				v.color = r["color"]

	func on_input(ev: InputEvent) -> void:
		var at = opening(ev)
		if at == null or popup_open():
			return
		var edit := (_value.duplicate() as Curve) if _value != null else Curve.new()
		var ed := UxmlEditorWidgets.CurveEditor.new()
		ed.curve = edit
		var cv := control_of(part("input")) as UxmlEditorWidgets.CurveView
		if cv != null:
			ed.color = cv.color
		ed.edited = func():
			_value = edit
			_view()
			emit_value(edit)
		track(UxmlEditorWidgets.open_panel(anchor(), ed, Vector2(340, 220)))

	func bind_write(prop: String, v: Variant) -> int:
		if prop == "value":
			if v != null and not v is Curve:
				return -1
			if is_same(v, _value):
				return 0
			_value = v
			_view()
			return 1
		return label_write(prop, v)

	func bind_read(prop: String) -> Array:
		if prop == "value":
			return [true, _value]
		return [false, null]


class GradientBehavior extends EditorBehavior:
	var _value: Gradient = null

	func setup() -> void:
		super.setup()
		_value = (el.get_meta(&"uxml_initial_value") if el.has_meta(&"uxml_initial_value") else null) as Gradient
		if _value == null:
			# Unity's default: white to white.
			_value = Gradient.new()
			_value.set_color(0, Color.WHITE)
			_value.set_color(1, Color.WHITE)
		_view()

	func _view() -> void:
		var v := control_of(part("content")) as UxmlEditorWidgets.GradientView
		if v != null:
			v.linear = attr("color-space").to_lower() == "linear"
			v.gradient = _value

	func on_input(ev: InputEvent) -> void:
		var at = opening(ev)
		if at == null or popup_open():
			return
		var edit := _value.duplicate() as Gradient
		var ed := UxmlEditorWidgets.GradientEditor.new()
		ed.gradient = edit
		ed.hdr = flag("hdr", false)
		ed.edited = func():
			_value = edit
			_view()
			emit_value(edit)
		track(UxmlEditorWidgets.open_panel(anchor(), ed, Vector2(340, 520)))

	func on_model_changed() -> void:
		super.on_model_changed()
		_view()

	func bind_write(prop: String, v: Variant) -> int:
		if prop == "value":
			if v != null and not v is Gradient:
				return -1
			if is_same(v, _value):
				return 0
			_value = v
			_view()
			return 1
		return label_write(prop, v)

	func bind_read(prop: String) -> Array:
		if prop == "value":
			return [true, _value]
		return [false, null]


# ---------------------------------------------------------------------------
# ObjectField
# ---------------------------------------------------------------------------

class ObjectBehavior extends EditorBehavior:
	var _value: Variant = null

	func setup() -> void:
		super.setup()
		_value = (el.get_meta(&"uxml_initial_value") if el.has_meta(&"uxml_initial_value") else null)
		var c := native()
		if c != null:
			c.set_drag_forwarding(Callable(), _can_drop, _drop)
		_show()

	## A value of the field type; a Node only with allow-scene-objects.
	func accepts(v: Variant) -> bool:
		if v == null:
			return true
		if not v is Object or not is_instance_valid(v):
			return false
		if v is Node and not flag("allow-scene-objects", true):
			return false
		return (v as Object).is_class(UxmlEditorParts.godot_class(el))

	func _dropped(data: Variant) -> Variant:
		if data is Object:
			return data
		if data is Dictionary:
			var d: Dictionary = data
			if d.get("resource") is Resource:
				return d["resource"]
			if d.get("files") is PackedStringArray and not (d["files"] as PackedStringArray).is_empty():
				return ResourceLoader.load((d["files"] as PackedStringArray)[0])
		return null

	func _can_drop(_p: Vector2, data: Variant) -> bool:
		if is_disabled():
			return false
		var v = _dropped(data)
		return v != null and accepts(v)

	func _drop(_p: Vector2, data: Variant) -> void:
		set_value(_dropped(data), true)

	func on_input(ev: InputEvent) -> void:
		var at = opening(ev)
		if at == null:
			return
		var picker: Callable = UxmlEditorBehaviors.object_picker
		if picker.is_valid():
			picker.call({"element": element_name(), "type": UxmlEditorParts.godot_class(el),
				"allow_scene_objects": flag("allow-scene-objects", true), "value": _value,
				"set_value": func(v): set_value(v, true)})
			return
		if popup_open():
			return
		var p := UxmlEditorWidgets.ObjectPicker.new()
		p.type = UxmlEditorParts.godot_class(el)
		p.allow_scene = flag("allow-scene-objects", true)
		var panel: PopupPanel
		p.chosen = func(v):
			set_value(v, true)
			if panel != null:
				panel.hide()
		panel = UxmlEditorWidgets.open_panel(anchor(), p, Vector2(300, 320))
		track(panel)

	func get_value() -> Variant:
		return _value

	func set_value(v: Variant, notify: bool) -> bool:
		if not accepts(v):
			return false
		if is_same(v, _value) or (v == null and _value == null):
			return false
		_value = v
		_show()
		if notify:
			emit_value(v)
		return true

	func _show() -> void:
		var changed := UxmlEditorParts.object_display(el, _value)
		var lc := control_of(part("display-label"))
		if lc != null:
			doc._set_control_text(lc, UxmlEditorParts.object_label(el, _value))
		var icon := doc._natives.get(part("icon")) as TextureRect
		if icon != null:
			icon.texture = _icon(_value)
		if changed:
			doc.relayout()

	## The icon of a value: the texture itself, or the Godot editor icon of
	## its class inside the editor.
	func _icon(v: Variant) -> Texture2D:
		if v is Texture2D:
			return v
		if v is Object and Engine.is_editor_hint() and Engine.has_singleton("EditorInterface"):
			var ei = Engine.get_singleton("EditorInterface")
			var th: Theme = ei.get_editor_theme()
			if th != null and th.has_icon((v as Object).get_class(), "EditorIcons"):
				return th.get_icon((v as Object).get_class(), "EditorIcons")
		return null

	func on_model_changed() -> void:
		super.on_model_changed()
		_show()

	func bind_write(prop: String, v: Variant) -> int:
		match prop:
			"value":
				if not accepts(v):
					return -1
				return 2 if set_value(v, false) else 0
			"allow-scene-objects":
				return write_attr(prop, "true" if UxmlBinding._bool(v) else "false")
		return label_write(prop, v)

	func bind_read(prop: String) -> Array:
		if prop == "value":
			return [true, _value]
		return [false, null]


## UxmlDocument.set_object_picker(): replaces the built-in object picker.
static var object_picker := Callable()


# ---------------------------------------------------------------------------
# Mask and layer fields
# ---------------------------------------------------------------------------

## The menu entries of a popup field, the selection and the shown text.
class PopupEditorBehavior extends EditorBehavior:
	func on_input(ev: InputEvent) -> void:
		var at = opening(ev)
		if at == null or popup_open():
			return
		var items := menu_items()
		var m := UxmlEditorWidgets.open_menu(anchor(), items, func(i): chosen(i, true))
		track(m)

	func menu_items() -> Array:
		return []

	func chosen(_i: int, _notify: bool) -> void:
		pass

	func show_text(t: String) -> void:
		var tp := part("text")
		if tp == null or tp.get_attribute("text") == t:
			return
		UxmlEditorParts._set_attr_quiet(tp, "text", t)
		var c := control_of(tp)
		if c != null:
			doc._set_control_text(c, t)
		doc.relayout()


## EnumFlagsField, MaskField, LayerMaskField, RenderingLayerMaskField: the
## value is an int mask. The menu has Nothing, Everything, then one checked
## item per entry, as Unity's mask menu.
class MaskBehavior extends PopupEditorBehavior:
	var _value := 0
	var _entries: Array = []

	func setup() -> void:
		super.setup()
		_entries = UxmlEditorParts.choices(el)
		_value = UxmlEditorParts.mask_value(el)

	func get_value() -> int:
		return _value

	## Entries with one bit or composite masks; 0-valued entries are the
	## Nothing item.
	func _listed() -> Array:
		var out: Array = []
		for k in _entries.size():
			if int(_entries[k][1]) != 0:
				out.append(k)
		return out

	func menu_items() -> Array:
		var full := UxmlEditorParts.full_mask(_entries)
		var items: Array = [["Nothing", _value == 0], ["Everything", _value == -1 or (full != 0 and (_value & full) == full)]]
		for k in _listed():
			var m := int(_entries[k][1])
			items.append([String(_entries[k][0]), _value != 0 and (_value == -1 or (_value & m) == m)])
		return items

	func chosen(i: int, notify: bool) -> void:
		var full := UxmlEditorParts.full_mask(_entries)
		var v := _value
		if i == 0:
			v = 0
		elif i == 1:
			v = full if el.local == "EnumFlagsField" else -1
		else:
			var k: int = _listed()[i - 2]
			var m := int(_entries[k][1])
			if v == -1:
				v = full
			v = v & ~m if (v & m) == m else v | m
		set_value(UxmlEditorParts.normalize_mask(el, v, _entries), notify)

	func set_value(v: int, notify: bool) -> bool:
		if v == _value:
			return false
		_value = v
		quiet_attr("value", str(v))
		show_text(UxmlEditorParts.mask_text(el, v))
		if notify:
			emit_value(v)
		return true

	func on_model_changed() -> void:
		super.on_model_changed()
		if _syncing:
			return
		_entries = UxmlEditorParts.choices(el)
		var v := UxmlEditorParts.mask_value(el)
		_value = v
		show_text(UxmlEditorParts.mask_text(el, v))

	func bind_write(prop: String, v: Variant) -> int:
		match prop:
			"value":
				return 2 if set_value(UxmlEditorParts.normalize_mask(el, int(UxmlBinding._num(v)), _entries), false) else 0
			"choices", "choices-masks":
				var s := ""
				if v is Array or v is PackedStringArray or v is PackedInt32Array:
					var parts := PackedStringArray()
					for x in v:
						parts.append(UxmlBinding._str(x))
					s = ",".join(parts)
				else:
					s = UxmlBinding._str(v)
				return write_attr(prop, s, 2)
		return label_write(prop, v)

	func bind_read(prop: String) -> Array:
		if prop == "value":
			return [true, _value]
		return [false, null]


## LayerField (the value is a layer index) and TagField (a tag name).
class LayerBehavior extends PopupEditorBehavior:
	var _value: Variant = 0
	var _entries: Array = []

	func is_tag() -> bool:
		return el.local == "TagField"

	func setup() -> void:
		super.setup()
		_entries = UxmlEditorParts.choices(el)
		_value = attr("value", "Untagged") if is_tag() else UxmlEditorParts.layer_value(el)

	func get_value() -> Variant:
		return _value

	func menu_items() -> Array:
		var items: Array = []
		for e in _entries:
			var on: bool = String(e[0]) == String(_value) if is_tag() else int(e[1]) == (1 << int(_value))
			items.append([String(e[0]), on])
		return items

	func chosen(i: int, notify: bool) -> void:
		if i < 0 or i >= _entries.size():
			return
		var v: Variant = String(_entries[i][0]) if is_tag() else int(log(float(int(_entries[i][1]))) / log(2.0) + 0.5)
		set_value(v, notify)

	func set_value(v: Variant, notify: bool) -> bool:
		if v == _value:
			return false
		_value = v
		quiet_attr("value", str(v))
		show_text(String(v) if is_tag() else UxmlEditorParts.popup_text(el))
		if notify:
			emit_value(v)
		return true

	func on_model_changed() -> void:
		super.on_model_changed()
		if _syncing:
			return
		_entries = UxmlEditorParts.choices(el)
		_value = attr("value", "Untagged") if is_tag() else UxmlEditorParts.layer_value(el)
		show_text(UxmlEditorParts.popup_text(el))

	func bind_write(prop: String, v: Variant) -> int:
		if prop == "value":
			var nv: Variant = UxmlBinding._str(v) if is_tag() else clampi(int(UxmlBinding._num(v)), 0, 31)
			return 2 if set_value(nv, false) else 0
		return label_write(prop, v)

	func bind_read(prop: String) -> Array:
		if prop == "value":
			return [true, _value]
		return [false, null]


# ---------------------------------------------------------------------------
# Toolbar
# ---------------------------------------------------------------------------

## ToolbarButton, BreadcrumbItem: the document button_pressed signal and
## :active while pressed, as for a Button.
class ToolbarButtonBehavior extends UxmlBehaviors.Behavior:
	var clicked := Callable()  # BreadcrumbItem: the PushItem callback

	func setup() -> void:
		var b := native() as BaseButton
		if b == null:
			return
		b.pressed.connect(_on_pressed)
		b.button_down.connect(func(): set_state(el, "active", true))
		b.button_up.connect(func(): set_state(el, "active", false))

	func _on_pressed() -> void:
		if clicked.is_valid():
			clicked.call()
		if el.part_of == null:
			doc.button_pressed.emit(element_name())

	func on_model_changed() -> void:
		var b := native() as Button
		if b != null and b.text != attr("text"):
			doc._set_control_text(b, attr("text"))

	func bind_write(prop: String, v: Variant) -> int:
		if prop == "text":
			return write_attr("text", UxmlBinding._str(v), 2)
		return UNHANDLED


## ToolbarMenu: a left press or `ui_accept` opens a menu of the entries
## that UxmlDocument.set_menu_items() gives (Unity's ToolbarMenu.menu).
class ToolbarMenuBehavior extends EditorBehavior:
	var items: Array = []         # [text, checked, disabled]; "-" separates
	var on_chosen := Callable()

	func _on_focus(_on: bool) -> void:
		pass

	func on_input(ev: InputEvent) -> void:
		var at = opening(ev)
		if at == null or popup_open() or items.is_empty():
			return
		var checkable := false
		for it in items:
			checkable = checkable or bool(it[1])
		track(UxmlEditorWidgets.open_menu(native(), items, func(i):
			if on_chosen.is_valid():
				on_chosen.call(i, String(items[i][0])), checkable))

	func on_model_changed() -> void:
		var tp := part("text")
		if tp != null and tp.get_attribute("text") != attr("text"):
			UxmlEditorParts._set_attr_quiet(tp, "text", attr("text"))
			var c := control_of(tp)
			if c != null:
				doc._set_control_text(c, attr("text"))
			doc.relayout()

	func bind_write(prop: String, v: Variant) -> int:
		if prop == "text":
			return write_attr("text", UxmlBinding._str(v), 2)
		return UNHANDLED


## ToolbarSpacer: `flex` (attribute, binding or code) toggles
## unity-toolbar-spacer--flexible.
class SpacerBehavior extends UxmlBehaviors.Behavior:
	func on_model_changed() -> void:
		UxmlParts.toggle_control_class(el, "unity-toolbar-spacer--flexible", UxmlParts._bool(el, "flex", false))

	func bind_write(prop: String, v: Variant) -> int:
		if prop == "flex":
			return write_attr("flex", "true" if UxmlBinding._bool(v) else "false", 2)
		return UNHANDLED


## ToolbarBreadcrumbs: push_item() adds a BreadcrumbItem (the first gets
## __first-item), pop_item() removes the last (Unity's PushItem, PopItem).
class BreadcrumbsBehavior extends UxmlBehaviors.Behavior:
	func push_item(text: String, clicked: Callable = Callable()) -> void:
		var item := UxmlEditorParts.breadcrumb_item(el, text)
		UxmlEditorBehaviors.insert(doc, el, item)
		var b = doc._behaviors.get(item)
		if b != null:
			b.clicked = clicked
		doc.relayout()

	func pop_item() -> void:
		var items := _items()
		if items.is_empty():
			return
		var last: UxmlElement = items[items.size() - 1]
		UxmlEditorBehaviors.remove(doc, last)
		doc.relayout()

	func _items() -> Array:
		var out: Array = []
		for c in el.children:
			if c.part_of == el and c.part_role == "item":
				out.append(c)
		return out

	func item_count() -> int:
		return _items().size()


## ToolbarSearchField, ToolbarPopupSearchField: the value is the text of
## the TextField part. The cancel button clears it; --off hides it while
## the text is empty. The popup variant's search button opens the menu of
## set_menu_items().
class SearchBehavior extends UxmlBehaviors.Behavior:
	var items: Array = []
	var on_chosen := Callable()
	var _value := ""

	func setup() -> void:
		_value = ""  # Unity 6000.3 reads no UXML value (UxmlEditorParts)
		var tb = doc._behaviors.get(UxmlParts.find_part(el, "text-field"))
		if tb != null:
			tb.ui_changed.connect(_on_text)
		var cancel := control_of(UxmlParts.find_part(el, "cancel-button")) as BaseButton
		if cancel != null:
			cancel.pressed.connect(func(): set_value("", true))
		var search := control_of(UxmlParts.find_part(el, "search-button")) as BaseButton
		if search != null:
			search.pressed.connect(_on_search)

	func native() -> Control:
		var tf := UxmlParts.find_part(el, "text-field")
		var n: Control = doc._natives.get(tf) if tf != null else null
		return n if n != null else doc._controls.get(el)

	func _on_text() -> void:
		var tb = doc._behaviors.get(UxmlParts.find_part(el, "text-field"))
		if tb == null:
			return
		var t := String(tb.bind_read("value")[1])
		_apply_text(t, true, false)

	func _on_search() -> void:
		if el.local != "ToolbarPopupSearchField" or items.is_empty():
			return
		var anchor := control_of(UxmlParts.find_part(el, "search-button"))
		UxmlEditorWidgets.open_menu(anchor if anchor != null else doc._controls.get(el), items, func(i):
			if on_chosen.is_valid():
				on_chosen.call(i, String(items[i][0])), false)

	func set_value(t: String, notify: bool) -> bool:
		return _apply_text(t, notify, true)

	func _apply_text(t: String, notify: bool, to_field: bool) -> bool:
		if t == _value:
			return false
		_value = t
		if to_field:
			var tb = doc._behaviors.get(UxmlParts.find_part(el, "text-field"))
			if tb != null:
				tb.bind_write("value", t)
		var cancel := UxmlParts.find_part(el, "cancel-button")
		if cancel != null:
			UxmlParts.toggle_control_class(cancel, "unity-search-field-base__cancel-button--off", t.is_empty())
		var en := el.get_attribute("value")
		if en == null or String(en) != t:
			var b := el.changed
			el.changed = Callable()
			el.set_attribute("value", t)
			el.changed = b
		if notify:
			if el.part_of == null:
				doc.value_changed.emit(element_name(), t)
			ui_changed.emit()
		return true

	func on_model_changed() -> void:
		set_value(attr("value"), false)

	func bind_write(prop: String, v: Variant) -> int:
		if prop == "value" or prop == "text":
			return 1 if set_value(UxmlBinding._str(v), false) else 0
		return UNHANDLED

	func bind_read(prop: String) -> Array:
		if prop == "value" or prop == "text":
			return [true, _value]
		return [false, null]


# ---------------------------------------------------------------------------
# PropertyField, InspectorElement
# ---------------------------------------------------------------------------

## PropertyField: the first value of its binding (binding-path, or a
## DataBinding of `value`) builds the field for the property type
## (UxmlEditorParts.field_for), as Unity builds it at bind time from the
## SerializedProperty. Later values and user edits go through the field's
## behavior; the PropertyField sends value_changed with its own name.
class PropertyFieldBehavior extends UxmlBehaviors.Behavior:
	var _info: Dictionary = {}
	var _field: UxmlElement = null
	var _fb = null
	var _value: Variant = null

	func setup() -> void:
		for c in el.children:
			if c.part_of == el and c.part_role == "field":
				_field = c
		if _field != null:
			_hook_field()

	## UxmlBinding: the holder object and the property name of the bound
	## path (the property hint chooses the field).
	func bind_source_info(source: Variant, parts: Array) -> void:
		if parts.is_empty() or not _info.is_empty():
			return
		var holder = source
		for k in parts.size() - 1:
			holder = UxmlBinding.get_value(holder, [parts[k]])[1] if holder != null else null
		var key := String(parts[parts.size() - 1])
		_info = {"name": key}
		if holder is Object:
			for p in (holder as Object).get_property_list():
				if String(p["name"]) == key or String(p["name"]) == UxmlBinding._snake(key):
					_info = p.duplicate()
					break

	func native() -> Control:
		if _fb != null:
			return _fb.native()
		return doc._controls.get(el)

	func _hook_field() -> void:
		_fb = doc._behaviors.get(_field)
		if _fb != null:
			_fb.ui_changed.connect(_on_field_changed)

	func _on_field_changed() -> void:
		var r: Array = _fb.bind_read("value")
		if not r[0]:
			return
		_value = _from_field(r[1])
		if el.part_of == null or el.part_role == "property":
			doc.value_changed.emit(element_name() if el.part_of == null else String(_info.get("name", "")), _value)
		ui_changed.emit()

	## Field values that differ from the property type: an enum PopupField
	## gives the index; the property holds the enum value.
	func _from_field(v: Variant) -> Variant:
		if _field.local == "PopupField`1" and int(_info.get("type", 0)) == TYPE_INT:
			var e := UxmlEditorParts._hint_enum(String(_info.get("hint_string", "")))
			var i := (e[2] as PackedStringArray).find(String(v))
			return (e[1] as Array)[i] if i >= 0 else 0
		if _field.local == "PopupField`1":
			return v
		return v

	func _to_field(v: Variant) -> Array:
		if _field.local == "PopupField`1":
			if int(_info.get("type", 0)) == TYPE_INT:
				var e := UxmlEditorParts._hint_enum(String(_info.get("hint_string", "")))
				var i := (e[1] as Array).find(int(v))
				return ["index", i]
			return ["value", UxmlBinding._str(v)]
		return ["value", v]

	func bind_write(prop: String, v: Variant) -> int:
		if prop == "label":
			if _field != null and _fb != null:
				_fb.bind_write("label", v)
			return write_attr("label", UxmlBinding._str(v), 2)
		if prop != "value":
			return UNHANDLED
		if _field == null:
			if _info.is_empty():
				_info = {"name": attr("binding-path"), "type": typeof(v)}
			if not _info.has("type"):
				_info["type"] = typeof(v)
			_value = v
			_field = UxmlEditorParts.property_field_content(el, _info, v, false)
			UxmlEditorBehaviors.insert(doc, el, _field)
			_hook_field()
			return 2
		_value = v
		if _fb == null:
			return 0
		var w := _to_field(v)
		return _fb.bind_write(w[0], w[1])

	func bind_read(prop: String) -> Array:
		if prop == "value" and _fb != null:
			var r: Array = _fb.bind_read("value")
			if r[0]:
				return [true, _from_field(r[1])]
		return [false, null]


## InspectorElement: its data source (the hierarchy context, as for any
## binding) gives one PropertyField per editor property of the Object
## (UxmlEditorParts.inspector_properties), each bound TwoWay to its
## property. Unity builds the default inspector from the SerializedObject.
class InspectorBehavior extends UxmlBehaviors.Behavior:
	var _obj: Object = null
	var _fields: Array = []

	func setup() -> void:
		doc._binding.add_binding(el, "value", "", {"mode": UxmlBinding.TO_TARGET})
		doc._layout_hooks.append(_after_layout)

	func bind_write(prop: String, v: Variant) -> int:
		if prop != "value":
			return UNHANDLED
		if not v is Object:
			return -1
		if is_same(v, _obj):
			return 0
		_obj = v
		for f in _fields:
			UxmlEditorBehaviors.remove(doc, f)
		_fields = []
		var content := UxmlParts.content_container(el)
		var made := UxmlEditorParts.inspector_content(el, _obj)
		for pf in made:
			content.children.erase(pf)
		for pf in made:
			UxmlEditorBehaviors.insert(doc, content, pf)
			_fields.append(pf)
			var info: Dictionary = pf.get_meta(&"uxml_property", {})
			if not info.get("_script", false):
				var b = doc._behaviors.get(pf)
				if b != null:
					b._info = info.duplicate()
				doc._binding.add_binding(pf, "value", String(info["name"]), {"data_source": _obj})
		return 2

	## Unity's label alignment of the inspector fields.
	func _after_layout() -> void:
		var rect_of := func(x: UxmlElement):
			var c: Control = doc._controls.get(x)
			return null if c == null else c.get_global_rect()
		var style_of := func(x: UxmlElement) -> Dictionary:
			return doc._styles.get(x, {})
		UxmlEditorParts.align_labels(el, rect_of, style_of)

	func bind_read(_prop: String) -> Array:
		return [false, null]
