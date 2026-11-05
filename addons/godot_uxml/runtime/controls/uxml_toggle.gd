class_name UxmlToggle
extends UxmlBox
## The interactive box of a Toggle or RadioButton (also a Foldout's toggle
## part). Its parts (label, input, checkmark, text) are child controls the
## flex layout places; this control only paints the element's own box and
## turns input into value changes, as Unity's BaseBoolField does:
##
##   * a left click (press and release inside) toggles the value;
##   * `ui_accept` (Enter, Space, Joypad A) toggles it while focused;
##   * a RadioButton (`radio = true`) only switches on — its group switches
##     the others off.
##
## The value API matches Godot's CheckBox so code written against the old
## mapping keeps working: `button_pressed`, `toggled(on)`,
## `set_pressed_no_signal()`, `disabled`.

signal toggled(toggled_on: bool)
## Emitted on every press that reached the value logic (also when a radio
## button is already on).
signal pressed

var radio := false
var disabled := false:
	set(v):
		disabled = v
		if v:
			_down = false

var button_pressed := false:
	set(v):
		if v == button_pressed:
			return
		button_pressed = v
		toggled.emit(v)

var _down := false


func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP


func set_pressed_no_signal(on: bool) -> void:
	if on == button_pressed:
		return
	# Bypass the setter's signal.
	set_block_signals(true)
	button_pressed = on
	set_block_signals(false)


func _activate() -> void:
	if disabled:
		return
	pressed.emit()
	if radio:
		button_pressed = true
	else:
		button_pressed = not button_pressed


func _gui_input(ev: InputEvent) -> void:
	if disabled:
		return
	var mb := ev as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_down = true
			accept_event()
		elif _down:
			_down = false
			accept_event()
			if Rect2(Vector2.ZERO, size).has_point(mb.position):
				_activate()
		return
	if ev.is_action_pressed("ui_accept") and not ev.is_echo():
		accept_event()
		_activate()
