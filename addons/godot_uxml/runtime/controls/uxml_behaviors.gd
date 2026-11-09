class_name UxmlBehaviors
extends RefCounted
## Per-control behavior on top of the part trees (UxmlParts): value state,
## the pseudo-states Unity sets on parts, attribute changes after load, and
## the document signals.
##
## A behavior never draws and never lays out. It reads input from the
## control's runtime node (UxmlToggle, Button), writes the model (pseudo-
## states through UxmlDocument._set_state, attributes and inline styles
## through UxmlElement.set_attribute) and lets the incremental cascade and
## layout do the rest. Everything a behavior changes therefore restyles like
## an author change would.
##
## `doc` is the UxmlDocument (duck-typed to avoid a class cycle). Behaviors
## live for one load.

## Behaviors for every control element of a freshly built document:
## element -> Behavior.
static func attach_all(doc) -> Dictionary:
	var out := {}
	for el in doc._doc.root.walk():
		var b := _create(el)
		if b == null:
			continue
		b.doc = doc
		b.el = el
		out[el] = b
	# Setup can find the behaviors of other controls (a slider's input
	# field, a vector field's components, a ListView's ScrollView).
	doc._behaviors = out
	for el in out:
		out[el].setup()
	return out


static func _create(el: UxmlElement) -> Behavior:
	# Containers and collections live in uxml_container_behaviors.gd.
	var cb := UxmlContainerBehaviors.create(el)
	if cb != null:
		return cb
	match el.local:
		"Toggle", "RadioButton":
			return ToggleBehavior.new()
		"RadioButtonGroup":
			return RadioGroupBehavior.new()
		"ToggleButtonGroup":
			return ToggleButtonGroupBehavior.new()
		"Foldout":
			return FoldoutBehavior.new()
		"ProgressBar":
			return ProgressBarBehavior.new()
		"HelpBox":
			return HelpBoxBehavior.new()
		"GroupBox":
			return TextPartBehavior.new()
		"PopupWindow":
			return OwnTextBehavior.new()
	# Input controls: runtime/controls/uxml_input_behaviors.gd
	var ib := UxmlInputBehaviors.create(el)
	if ib != null:
		return ib
	# Editor controls: runtime/controls/uxml_editor_behaviors.gd
	return UxmlEditorBehaviors.create(el)


# ---------------------------------------------------------------------------

class Behavior extends RefCounted:
	## Emitted after a user edit changed the control's value (the same
	## moments as the document's value_changed). UxmlBinding writes TwoWay
	## and ToSource bindings back on this signal.
	signal ui_changed

	## bind_write() result for a property the behavior does not handle:
	## UxmlBinding then uses its generic targets (tooltip, enabled, ...).
	const UNHANDLED := -2

	var doc
	var el: UxmlElement

	func setup() -> void:
		pass

	## An attribute of `el` changed through set_attribute.
	func on_model_changed() -> void:
		pass

	## A change of attribute `n` that the document keeps out of the cascade
	## (set_field_value, set_field_placeholder), after bind_write made it.
	func on_quiet_change(_n: String) -> void:
		on_model_changed()

	## The control the document's get_native() returns.
	func native() -> Control:
		return doc._controls.get(el)

	func control_of(x: UxmlElement) -> Control:
		return null if x == null else doc._controls.get(x)

	func set_state(x: UxmlElement, state: String, on: bool) -> void:
		if x != null:
			doc._set_state(x, state, on)

	func element_name() -> String:
		return doc._el_names.get(el, "")

	func attr(n: String, d: String = "") -> String:
		var v = el.get_attribute(n)
		return d if v == null else String(v)

	## Data binding (UxmlBinding) write of the canonical property `prop`.
	## Returns UxmlBinding's codes: 0 unchanged, 1 written, 2 written and
	## the layout must run, -1 the control cannot take the property, or
	## UNHANDLED. A write goes through the model attribute, so the behavior
	## (on_model_changed), the cascade and the layout react as for an
	## author change.
	func bind_write(_prop: String, _v: Variant) -> int:
		return UNHANDLED

	## The current UI value of `prop` for a two-way binding: [ok, value].
	func bind_read(_prop: String) -> Array:
		return [false, null]

	## Write attribute `n` from a binding. Returns 0 when unchanged, else
	## `code`.
	func write_attr(n: String, s: String, code: int = 1) -> int:
		if el.has_attribute(n) and attr(n) == s:
			return 0
		el.set_attribute(n, s)
		return code

	## Keep a text part's `text` attribute and its control in step with the
	## owner attribute `source`. A part built for a bound attribute
	## (UxmlParts.META_LIVE) hides while the text is empty, and a BaseField
	## then has `unity-base-field--no-label`, as Unity has no part then.
	func sync_text(role: String, source: String) -> void:
		var p := UxmlParts.find_part(el, role)
		if p == null:
			return
		var t := attr(source)
		if p.get_attribute("text") == t:
			return
		p.attributes = p.attributes.duplicate(true)
		for a in p.attributes:
			if a["name"] == "text":
				a["value"] = t
		var c := control_of(p)
		if c != null:
			doc._set_control_text(c, t)
		if doc._v2 != null:
			doc._v2.part_text(p)  # runtime v2 draws the part's text
		if UxmlParts._live(el, source):
			var hidden := t.is_empty()
			if (p.get_attribute("style") == UxmlParts.HIDDEN) != hidden:
				if hidden:
					p.set_attribute("style", UxmlParts.HIDDEN)
				else:
					p.remove_attribute("style")
			if role == "label" and UxmlParts.find_part(el, "input") != null:
				UxmlParts.toggle_control_class(el, "unity-base-field--no-label", hidden)
		if c == null:
			doc.relayout()  # else _set_control_text lays out what the text can move


## Toggle and RadioButton. Unity sets :checked on the control element and
## on its input part (BaseBoolField's visual input), so theme and author
## rules can hang the check look off either.
class ToggleBehavior extends Behavior:
	var _syncing := false

	func setup() -> void:
		var t := doc._controls.get(el) as UxmlToggle
		if t == null:
			return
		_apply_checked(t.button_pressed)
		t.toggled.connect(_on_toggled)
		t.focus_entered.connect(_on_focus.bind(true))
		t.focus_exited.connect(_on_focus.bind(false))

	func _on_toggled(on: bool) -> void:
		_apply_checked(on)
		if on and el.local == "RadioButton":
			_exclusive()
		_syncing = true
		el.set_attribute("value", "true" if on else "false")
		_syncing = false
		if el.part_of == null:
			doc.value_changed.emit(element_name(), on)
			ui_changed.emit()

	func bind_write(prop: String, v: Variant) -> int:
		match prop:
			"value":
				var t := doc._controls.get(el) as UxmlToggle
				var on := UxmlBinding._bool(v)
				if t == null or t.button_pressed == on:
					return 0
				el.set_attribute("value", "true" if on else "false")
				return 1
			"label", "text":
				return write_attr(prop, UxmlBinding._str(v), 2)
		return UNHANDLED

	func bind_read(prop: String) -> Array:
		var t := doc._controls.get(el) as UxmlToggle
		if prop == "value" and t != null:
			return [true, t.button_pressed]
		return [false, null]

	func _apply_checked(on: bool) -> void:
		set_state(el, "checked", on)
		set_state(UxmlParts.find_part(el, "input"), "checked", on)
		var owner := el.part_of
		if owner != null and owner.local == "Foldout":
			set_state(owner, "checked", on)  # Unity: an open Foldout is :checked

	## Unity puts :focus on a focused BaseBoolField and on its input.
	func _on_focus(on: bool) -> void:
		set_state(UxmlParts.find_part(el, "input"), "focus", on)

	## A RadioButton outside a RadioButtonGroup shares a group with every
	## RadioButton under the same nearest GroupBox, or the whole document
	## (Unity's IGroupBox rule); switching one on switches the rest off.
	func _exclusive() -> void:
		var p = doc._parents.get(el)
		while p != null and not (p.local in ["GroupBox", "RadioButtonGroup"] and p.part_of == null):
			p = doc._parents.get(p)
		if p != null and p.local == "RadioButtonGroup":
			return  # the group behavior keeps it exclusive
		var scope: UxmlElement = p if p != null else doc._doc.root
		for x in scope.walk():
			if x == el or x.local != "RadioButton":
				continue
			# Radios inside a nested group box belong to that box.
			var q = doc._parents.get(x)
			var nested := false
			while q != null and q != scope:
				if q.local in ["GroupBox", "RadioButtonGroup"] and q.part_of == null:
					nested = true
					break
				q = doc._parents.get(q)
			if nested:
				continue
			var t := control_of(x) as UxmlToggle
			if t != null and t.button_pressed:
				t.button_pressed = false

	func on_model_changed() -> void:
		if _syncing:
			return
		var t := doc._controls.get(el) as UxmlToggle
		if t == null:
			return
		var v := attr("value", "false").to_lower()
		var on := v == "true" or v == "1"
		if on != t.button_pressed:
			t.button_pressed = on
		sync_text("label", "label")
		sync_text("text", "text")


## RadioButtonGroup: exactly one of its radio buttons is on; `value` is its
## index, -1 for none.
class RadioGroupBehavior extends Behavior:
	var _radios: Array = []
	var _busy := false

	func setup() -> void:
		for role in ["choices", "container"]:
			var box := UxmlParts.find_part(el, role)
			if box == null:
				continue
			for x in box.children:
				if x.local == "RadioButton":
					_radios.append(x)
		var idx := int(UssValues.parse_number(attr("value", "-1")))
		for i in _radios.size():
			var t := control_of(_radios[i]) as UxmlToggle
			if t == null:
				continue
			if idx >= 0:
				t.button_pressed = i == idx
			t.toggled.connect(_on_radio.bind(i))

	func native() -> Control:
		return doc._controls.get(el)

	func _on_radio(on: bool, i: int) -> void:
		if _busy or not on:
			return
		_busy = true
		for k in _radios.size():
			if k != i:
				var t := control_of(_radios[k]) as UxmlToggle
				if t != null and t.button_pressed:
					t.button_pressed = false
		_busy = false
		el.set_attribute("value", str(i))
		doc.value_changed.emit(element_name(), i)
		ui_changed.emit()

	## `value` after load (script or binding) selects that radio; -1 none.
	func on_model_changed() -> void:
		sync_text("label", "label")
		if _busy:
			return
		var idx := int(UssValues.parse_number(attr("value", "-1")))
		_busy = true
		for k in _radios.size():
			var t := control_of(_radios[k]) as UxmlToggle
			if t != null and t.button_pressed != (k == idx):
				t.button_pressed = k == idx
		_busy = false

	func bind_write(prop: String, v: Variant) -> int:
		match prop:
			"value":
				return write_attr("value", str(int(UxmlBinding._num(v))))
			"label":
				return write_attr("label", UxmlBinding._str(v), 2)
			"choices":
				return -1  # the radio buttons are parts, fixed at load
		return UNHANDLED

	func bind_read(prop: String) -> Array:
		if prop == "value":
			return [true, int(UssValues.parse_number(attr("value", "-1")))]
		return [false, null]


## ToggleButtonGroup: the authored Buttons in its container are its
## options; selected ones get :checked. Without allow-empty-selection one
## option is always selected (the first, until clicked otherwise).
class ToggleButtonGroupBehavior extends Behavior:
	var _buttons: Array = []
	var _selected: Array = []

	func setup() -> void:
		var content := UxmlParts.content_container(el)
		for x in content.children:
			if x.local == "Button":
				_buttons.append(x)
		var n := _buttons.size()
		for i in n:
			_selected.append(false)
			var b := control_of(_buttons[i]) as BaseButton
			if b != null:
				b.pressed.connect(_on_pressed.bind(i))
		if n > 0 and not _allow_empty():
			_select(0, true)

	func _allow_empty() -> bool:
		return attr("allow-empty-selection", "false").to_lower() == "true"

	func _multi() -> bool:
		return attr("is-multiple-selection", "false").to_lower() == "true"

	func _select(i: int, on: bool) -> void:
		_selected[i] = on
		set_state(_buttons[i], "checked", on)

	func _on_pressed(i: int) -> void:
		var before: Array = _selected.duplicate()
		if _multi():
			var count := 0
			for s in _selected:
				count += 1 if s else 0
			if _selected[i] and count == 1 and not _allow_empty():
				return
			_select(i, not _selected[i])
		else:
			if _selected[i]:
				if _allow_empty():
					_select(i, false)
			else:
				for k in _selected.size():
					if _selected[k]:
						_select(k, false)
				_select(i, true)
		if before != _selected:
			doc.value_changed.emit(element_name(), selected_indices())
			ui_changed.emit()

	## Binding `value`: an Array of selected indices, or one index.
	func bind_write(prop: String, v: Variant) -> int:
		if prop == "label":
			return write_attr("label", UxmlBinding._str(v), 2)
		if prop != "value":
			return UNHANDLED
		var want: Array = []
		if v is Array or v is PackedInt32Array or v is PackedInt64Array:
			for x in v:
				want.append(int(x))
		elif v is int or v is float:
			want.append(int(v))
		else:
			return -1
		var changed := false
		for k in _selected.size():
			var on := want.has(k)
			if _selected[k] != on:
				_select(k, on)
				changed = true
		return 1 if changed else 0

	func bind_read(prop: String) -> Array:
		if prop == "value":
			return [true, selected_indices()]
		return [false, null]

	func on_model_changed() -> void:
		sync_text("label", "label")

	func selected_indices() -> Array:
		var out := []
		for k in _selected.size():
			if _selected[k]:
				out.append(k)
		return out


## Foldout: its Toggle part opens and closes `#unity-content`.
class FoldoutBehavior extends Behavior:
	var _toggle: UxmlElement
	var _content: UxmlElement
	var _syncing := false

	func setup() -> void:
		_toggle = UxmlParts.find_part(el, "toggle")
		_content = UxmlParts.find_part(el, "content")
		var t := control_of(_toggle) as UxmlToggle
		if t != null:
			t.toggled.connect(_on_toggled)

	func native() -> Control:
		var t := control_of(_toggle)
		return t if t != null else doc._controls.get(el)

	func _on_toggled(on: bool) -> void:
		if _content != null:
			_content.set_attribute("style", "" if on else "display: none;")
		_syncing = true
		el.set_attribute("value", "true" if on else "false")
		_syncing = false
		doc.value_changed.emit(element_name(), on)
		ui_changed.emit()

	func bind_write(prop: String, v: Variant) -> int:
		match prop:
			"value":
				var t := control_of(_toggle) as UxmlToggle
				var on := UxmlBinding._bool(v)
				if t == null or t.button_pressed == on:
					return 0
				el.set_attribute("value", "true" if on else "false")
				return 2
			"text":
				return write_attr("text", UxmlBinding._str(v), 2)
		return UNHANDLED

	func bind_read(prop: String) -> Array:
		var t := control_of(_toggle) as UxmlToggle
		if prop == "value" and t != null:
			return [true, t.button_pressed]
		return [false, null]

	func on_model_changed() -> void:
		if _syncing:
			return
		var v := attr("value", "true").to_lower()
		var on := not (v == "false" or v == "0")
		var t := control_of(_toggle) as UxmlToggle
		if t != null and t.button_pressed != on:
			t.button_pressed = on
		if _toggle != null and _toggle.get_attribute("text") != attr("text"):
			_toggle.set_attribute("text", attr("text"))


## ProgressBar: value/range/title attributes drive the progress part and
## the title label.
class ProgressBarBehavior extends Behavior:
	func on_model_changed() -> void:
		var p := UxmlParts.find_part(el, "progress")
		if p != null:
			UxmlParts.progress_style(el, p)
		sync_text("title", "title")

	func bind_write(prop: String, v: Variant) -> int:
		match prop:
			"value", "low-value", "high-value":
				return write_attr(prop, UxmlBinding._str(UxmlBinding._num(v)))
			"title":
				return write_attr("title", UxmlBinding._str(v), 2)
		return UNHANDLED

	func bind_read(prop: String) -> Array:
		if prop == "value":
			return [true, UssValues.parse_number(attr("value", "0"))]
		return [false, null]


## HelpBox: message-type picks the icon variant; text the label.
class HelpBoxBehavior extends Behavior:
	var _warned := false

	func on_model_changed() -> void:
		var icon := UxmlParts.find_part(el, "icon")
		if icon != null:
			var before: Array = icon.attributes.duplicate(true)
			UxmlParts.help_box_icon(el, icon)
			if before != icon.attributes and icon.changed.is_valid():
				icon.changed.call(icon)
		elif attr("message-type", "None").to_lower() in ["info", "warning", "error"] and not _warned:
			# Loaded as None: as in Unity the icon is not in the tree, and
			# godot-uxml fixes the part tree at load.
			_warned = true
			doc._rt_warnings.append(UxmlDiagnostic.make("unsupported-value",
				"HelpBox message-type changed from None after load; reload to show the icon",
				doc._doc.source, el.open_tag_start, doc._doc.path))
		sync_text("label", "text")

	func bind_write(prop: String, v: Variant) -> int:
		match prop:
			"text":
				return write_attr("text", UxmlBinding._str(v), 2)
			"message-type":
				var names := ["None", "Info", "Warning", "Error"]
				var s: String = names[int(v)] if (v is int and v >= 0 and v < 4) else UxmlBinding._str(v)
				return write_attr("message-type", s)
		return UNHANDLED


## Controls whose only live attribute is a label text (GroupBox).
class TextPartBehavior extends Behavior:
	func on_model_changed() -> void:
		sync_text("label", "text")

	func bind_write(prop: String, v: Variant) -> int:
		if prop == "text":
			return write_attr("text", UxmlBinding._str(v), 2)
		return UNHANDLED


## Controls that draw their own `text` (PopupWindow).
class OwnTextBehavior extends Behavior:
	func on_model_changed() -> void:
		var l := doc._controls.get(el) as Label
		if l != null and l.text != attr("text"):
			doc._set_control_text(l, attr("text"))

	func bind_write(prop: String, v: Variant) -> int:
		if prop == "text":
			return write_attr("text", UxmlBinding._str(v), 2)
		return UNHANDLED
