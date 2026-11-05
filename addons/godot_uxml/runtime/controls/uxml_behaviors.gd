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
	for el in out:
		out[el].setup()
	return out


static func _create(el: UxmlElement) -> Behavior:
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
	return null


# ---------------------------------------------------------------------------

class Behavior extends RefCounted:
	var doc
	var el: UxmlElement

	func setup() -> void:
		pass

	## An attribute of `el` changed through set_attribute.
	func on_model_changed() -> void:
		pass

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

	## Keep a text part's `text` attribute and its Label in step with the
	## owner attribute `source`.
	func sync_text(role: String, source: String) -> void:
		var p := UxmlParts.find_part(el, role)
		if p == null:
			return
		var t := attr(source)
		var lbl := control_of(p) as Label
		if p.get_attribute("text") != t:
			p.attributes = p.attributes.duplicate(true)
			for a in p.attributes:
				if a["name"] == "text":
					a["value"] = t
			if lbl != null:
				lbl.text = t
			doc.relayout()


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


## Controls whose only live attribute is a label text (GroupBox).
class TextPartBehavior extends Behavior:
	func on_model_changed() -> void:
		sync_text("label", "text")


## Controls that draw their own `text` (PopupWindow).
class OwnTextBehavior extends Behavior:
	func on_model_changed() -> void:
		var l := doc._controls.get(el) as Label
		if l != null and l.text != attr("text"):
			l.text = attr("text")
			doc.relayout()
