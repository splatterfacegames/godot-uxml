class_name UxmlInputBehaviors
extends RefCounted
## Behaviors of the input controls (UxmlInputParts builds their parts):
##
##   SliderBehavior     Slider, SliderInt (Unity's BaseSlider, ClampedDragger,
##                      FieldMouseDragger on the label)
##   MinMaxBehavior     MinMaxSlider
##   TextFieldBehavior  TextField (text in a Godot LineEdit/TextEdit)
##   NumericBehavior    IntegerField, LongField, FloatField, DoubleField,
##                      UnsignedIntegerField, UnsignedLongField, Hash128Field
##   CompositeBehavior  Vector2/3/4(Int)Field, Rect(Int)Field, Bounds(Int)Field
##   PopupBehavior      DropdownField, EnumField (UxmlPopupMenu)
##
## The rules follow Unity 6000.3's source of these controls and the
## measured dumps (keyboard, pointer, focus classes, value types). A
## behavior writes the model (attributes, inline styles, control classes,
## pseudo-states) and the incremental cascade and layout do the rest, as
## for UxmlBehaviors.

const DRAG_NONE := 0
const DRAG_FREE := 1
const DRAG_LOW_TO_HIGH := 2
const DRAG_HIGH_TO_LOW := 3

## Unity's ScrollWaitDefinitions: first repeat, then every interval (ms).
const REPEAT_FIRST_MS := 250
const REPEAT_MS := 30

## Attributes checked by InputBehavior.validate().
const NUMBER_ATTRS := {
	"low-value": true, "high-value": true, "value": true, "page-size": true,
	"min-value": true, "max-value": true, "low-limit": true, "high-limit": true,
	"max-length": true, "index": true, "x": true, "y": true, "z": true, "w": true, "h": true,
	"cx": true, "cy": true, "cz": true, "ex": true, "ey": true, "ez": true,
	"px": true, "py": true, "pz": true, "sx": true, "sy": true, "sz": true,
}
## Controls whose `value` attribute is a number.
const NUMERIC_VALUE := {
	"Slider": true, "SliderInt": true, "IntegerField": true, "LongField": true,
	"FloatField": true, "DoubleField": true, "UnsignedIntegerField": true, "UnsignedLongField": true,
}
const BOOL_ATTRS := {
	"fill": true, "inverted": true, "show-input-field": true, "multiline": true,
	"password": true, "readonly": true, "is-delayed": true, "hide-placeholder-on-focus": true,
	"select-all-on-focus": true, "select-all-on-mouse-up": true,
	"select-word-by-double-click": true, "select-line-by-triple-click": true,
	"auto-correction": true, "hide-mobile-input": true, "include-obsolete-values": true,
	"support-expressions": true, "emoji-fallback-support": true,
}
const ENUM_ATTRS := {
	"direction": ["Horizontal", "Vertical"],
	"vertical-scroller-visibility": ["Auto", "AlwaysVisible", "Hidden"],
}


static func create(el: UxmlElement) -> UxmlBehaviors.Behavior:
	match el.local:
		"Slider", "SliderInt":
			return SliderBehavior.new()
		"MinMaxSlider":
			return MinMaxBehavior.new()
		"TextField":
			return TextFieldBehavior.new()
		"DropdownField", "EnumField":
			return PopupBehavior.new()
		"BoundsField", "BoundsIntField":
			return CompositeBehavior.new()
	if UxmlInputParts.NUMERIC.has(el.local):
		return NumericBehavior.new()
	if UxmlInputParts.COMPOSITE.has(el.local):
		return CompositeBehavior.new()
	return null


## Unity's BaseSlider.GetClosestPowerOfTen.
static func closest_power_of_ten(v: float) -> float:
	if v <= 0.0:
		return 1.0
	return pow(10.0, roundi(log(v) / log(10.0)))


## Unity's BaseSlider.RoundToMultipleOf (Mathf.Round: halves to even).
static func round_to_multiple(v: float, m: float) -> float:
	if m == 0.0:
		return v
	return UxmlNumeric.round_even(v / m) * m


## The local position of `ev` (in `from`'s space) in `to`'s space.
static func to_local(from: Control, to: Control, p: Vector2) -> Vector2:
	return to.get_global_transform().affine_inverse() * (from.get_global_transform() * p)


# ---------------------------------------------------------------------------

## Shared helpers of the input behaviors.
class InputBehavior extends UxmlBehaviors.Behavior:
	var _syncing := false

	func is_disabled() -> bool:
		if doc._v2 != null:
			return doc._v2.is_disabled(el)
		if doc._cascade == null:
			return false
		var ci = doc._cascade.index.get(el)
		return ci != null and ci < doc._dis.size() and doc._dis[ci] == 1

	var _parts := {}  # role -> part (part trees are fixed after load)

	func part(role: String) -> UxmlElement:
		return UxmlInputParts.part_cached(el, role, _parts)

	## Write an attribute without re-entering on_model_changed.
	func quiet_attr(n: String, v: String) -> void:
		if el.has_attribute(n) and attr(n) == v:
			return
		_syncing = true
		el.set_attribute(n, v)
		_syncing = false

	## The document signal (top-level controls only) and the binding
	## write-back signal.
	func emit_value(v: Variant) -> void:
		if el.part_of == null:
			doc.value_changed.emit(element_name(), v)
		ui_changed.emit()

	func size_of(x: UxmlElement) -> Vector2:
		var c := control_of(x)
		return Vector2.ZERO if c == null else c.size

	func style_of(x: UxmlElement) -> Dictionary:
		if doc._v2 != null:
			return doc._v2.computed_style(x)
		return doc._styles.get(x, {})

	func flag(n: String, d: bool) -> bool:
		return UxmlParts._bool(el, n, d)

	## An attribute value the control cannot read gives `unsupported-value`
	## (once per attribute) and the control uses Unity's default.
	func validate() -> void:
		if el.part_of != null:
			return
		for a in el.attributes:
			var n := String(a["name"])
			var v := String(a["value"])
			var problem := ""
			if UxmlInputBehaviors.NUMBER_ATTRS.has(n):
				if n == "value" and not UxmlInputBehaviors.NUMERIC_VALUE.has(el.local):
					continue
				if is_nan(UssValues.parse_number(v)):
					problem = '"%s" is not a number for %s; the default is used' % [v, n]
			elif UxmlInputBehaviors.BOOL_ATTRS.has(n):
				if not v.to_lower() in ["true", "false", "1", "0"]:
					problem = '"%s" is not a valid bool for %s; the default is used' % [v, n]
			elif UxmlInputBehaviors.ENUM_ATTRS.has(n):
				if not (UxmlInputBehaviors.ENUM_ATTRS[n] as Array).has(v):
					problem = '"%s" is not a valid %s; the default is used' % [v, n]
			if not problem.is_empty():
				warn(problem)

	func warn(msg: String) -> void:
		doc._rt_warnings.append(UxmlDiagnostic.make("unsupported-value", msg,
			doc._doc.source, el.open_tag_start, doc._doc.path))

	## Pointer input that arrives at a part (the drag container, the label)
	## goes to on_input in the control's space.
	func on_part_input(ev: InputEvent, from: Control) -> void:
		var c := native()
		if c == null or from == null:
			return
		if ev is InputEventMouse:
			on_input(ev.xformed_by(c.get_global_transform().affine_inverse() * from.get_global_transform()))

	func on_input(_ev: InputEvent) -> void:
		pass


# ---------------------------------------------------------------------------
# Slider, SliderInt
# ---------------------------------------------------------------------------

class SliderBehavior extends InputBehavior:
	var _value := 0.0
	var _pressed := false
	var _drag_dir := DRAG_NONE
	var _start := Vector2.ZERO        # pointer at press, drag container space
	var _last := Vector2.ZERO         # last pointer, drag container space
	var _drag_start := Rect2()        # dragger translate and size at drag start
	var _adjusted_page := 0.0
	var _repeat: Timer = null
	var _label_drag := false
	var _label_start := 0.0
	var _editing_text := false

	func integer() -> bool:
		return el.local == "SliderInt"

	func low_attr() -> String:
		return "low-value"

	func high_attr() -> String:
		return "high-value"

	func low() -> float:
		return UxmlInputParts.slider_values(el)[1]

	func high() -> float:
		return UxmlInputParts.slider_values(el)[2]

	func get_value() -> Variant:
		return int(_value) if integer() else _value

	func page_size() -> float:
		var p := UxmlInputParts.num(el, "page-size", 0.0)
		return float(roundi(p)) if integer() else p

	func inverted() -> bool:
		return flag("inverted", false)

	func vertical() -> bool:
		return UxmlInputParts.vertical(el)

	func setup() -> void:
		var c := doc._controls.get(el) as UxmlSlider
		if c == null:
			return
		c.behavior = self
		validate()
		_value = _clean(UxmlInputParts.slider_values(el)[0])
		c.focus_entered.connect(_on_focus.bind(true))
		c.focus_exited.connect(_on_focus.bind(false))
		doc._layout_hooks.append(_after_layout)
		# Unity: the ClampedDragger sits on the drag container and the
		# FieldMouseDragger on the label, so the pointer works whatever the
		# picking mode of the slider itself.
		for role in ["drag-container", "label"]:
			var pc := control_of(part(role))
			if pc != null:
				pc.gui_input.connect(on_part_input.bind(pc))
		var tf := part("text-field")
		if tf != null:
			var tb = doc._behaviors.get(tf)
			if tb != null:
				tb.ui_changed.connect(_on_text_field_changed)
				tb.editing.connect(_on_text_field_editing)

	func native() -> Control:
		return doc._controls.get(el)

	func _clean(v: float) -> float:
		return UxmlNumeric.round_even(v) if integer() else UxmlNumeric.f32_clean(v)

	func _clamp(v: float) -> float:
		var lo := low()
		var hi := high()
		return clampf(v, minf(lo, hi), maxf(lo, hi))

	## Set the value; true when it changed. Unity moves the dragger to the
	## value even when the value does not change (UUM-21303).
	func _set_value(v: float, notify: bool) -> bool:
		var nv := _clean(_clamp(v))
		if nv == _value:
			_update_dragger()
			return false
		_value = nv
		quiet_attr("value", str(int(nv)) if integer() else str(nv))
		_update_fill()
		_update_dragger()
		_update_text_field()
		if notify:
			emit_value(get_value())
			var c := native() as UxmlSlider
			if c != null:
				c.value_changed.emit(get_value())
		return true

	## UxmlSlider.value from code: Unity's value setter (notifies).
	func set_value_from_code(v: float) -> void:
		_set_value(v, true)

	func _update_fill() -> void:
		var f := part("fill")
		if f != null:
			var want := UxmlInputParts.fill_style(el)
			if not flag("fill", false):
				want = "display: none;"
			if f.get_attribute("style") != want:
				f.set_attribute("style", want)

	func _update_dragger() -> void:
		UxmlInputParts.layout_styles(el, size_of, style_of, _parts)

	func _after_layout() -> void:
		UxmlInputParts.layout_styles(el, size_of, style_of, _parts)

	func _update_text_field() -> void:
		var tf := part("text-field")
		if tf == null or _editing_text:
			return
		var tb = doc._behaviors.get(tf)
		if tb != null:
			tb.set_text_quiet(UxmlInputParts.slider_text(el))

	## The dragger's translate (inline style), in px.
	func _translate() -> Vector2:
		var d := part("dragger")
		if d == null:
			return Vector2.ZERO
		var st = d.get_attribute("style")
		if st == null:
			return Vector2.ZERO
		var s := String(st).trim_prefix("translate:").trim_suffix(";").strip_edges().split(" ", false)
		var out := Vector2.ZERO
		for k in mini(2, s.size()):
			var n := UssValues.parse_number(s[k].trim_suffix("px"))
			out[k] = 0.0 if is_nan(n) else n
		return out

	func _set_translate(p: Vector2) -> void:
		var tr := "translate: %s %s;" % [UxmlInputParts._px(p.x), UxmlInputParts._px(p.y)]
		for role in ["dragger", "dragger-border"]:
			var x := part(role)
			if x != null and x.get_attribute("style") != tr:
				x.set_attribute("style", tr)

	func _on_focus(on: bool) -> void:
		set_state(part("input"), "focus", on)
		var d := part("dragger")
		if d != null:
			UxmlParts.toggle_control_class(d, "unity-base-slider--movable", on)

	func _movable() -> bool:
		var d := part("dragger")
		return d != null and UxmlParts.control_classes(d).has("unity-base-slider--movable")

	# -- input --------------------------------------------------------------

	func on_input(ev: InputEvent) -> void:
		var c := native() as UxmlSlider
		if c == null or is_disabled():
			return
		var mb := ev as InputEventMouseButton
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press(c, mb)
			else:
				_release()
			return
		var mm := ev as InputEventMouseMotion
		if mm != null:
			if _label_drag:
				_label_move(mm)
				c.accept_event()
			elif _pressed:
				var dc := control_of(part("drag-container"))
				_last = UxmlInputBehaviors.to_local(c, dc, mm.position)
				if _drag_dir == DRAG_NONE:
					_drag_dir = DRAG_FREE
				if _drag_dir == DRAG_FREE:
					_on_drag()
				c.accept_event()
			return
		if _label_drag and ev.is_action_pressed("ui_cancel"):
			_label_drag = false
			_set_value(_label_start, true)
			c.accept_event()
			return
		if _key(ev):
			c.accept_event()

	func _press(c: UxmlSlider, mb: InputEventMouseButton) -> void:
		var label := part("label")
		var lc := control_of(label)
		if lc != null and lc.visible and Rect2(Vector2.ZERO, lc.size).has_point(UxmlInputBehaviors.to_local(c, lc, mb.position)):
			# FieldMouseDragger on the label.
			_label_drag = true
			_label_start = _value
			c.grab_focus()
			c.accept_event()
			return
		var dc := control_of(part("drag-container"))
		if dc == null:
			return
		var p := UxmlInputBehaviors.to_local(c, dc, mb.position)
		if not Rect2(Vector2.ZERO, dc.size).has_point(p):
			return
		c.grab_focus()
		c.accept_event()
		_pressed = true
		set_state(part("drag-container"), "active", true)
		_start = p
		_last = p
		_drag_dir = DRAG_NONE
		_on_click()
		if not is_zero_approx(page_size()):
			_start_repeat(c)

	func _release() -> void:
		if _label_drag:
			_label_drag = false
		if not _pressed:
			return
		_pressed = false
		set_state(part("drag-container"), "active", false)
		if _repeat != null:
			_repeat.stop()

	func _start_repeat(c: Control) -> void:
		if _repeat == null:
			_repeat = Timer.new()
			_repeat.one_shot = false
			c.add_child(_repeat)
			_repeat.timeout.connect(_on_repeat)
		_repeat.wait_time = REPEAT_FIRST_MS / 1000.0
		_repeat.start()

	func _on_repeat() -> void:
		if not _pressed:
			_repeat.stop()
			return
		_repeat.wait_time = REPEAT_MS / 1000.0
		var dc := control_of(part("drag-container"))
		if dc != null and Rect2(Vector2.ZERO, dc.size).has_point(_last):
			_on_click()

	## FieldMouseDragger: the label drags the value by the pointer delta.
	func _label_move(mm: InputEventMouseMotion) -> void:
		var speed := 4.0 if mm.shift_pressed else (0.25 if mm.alt_pressed else 1.0)
		var nice := UxmlInputBehaviors.nice_delta(mm.relative, speed)
		if integer():
			var sens: float = maxf(1.0, floorf(0.03 * absf(high() - low()) / 100.0))
			_set_value(_value + roundf(nice * sens), true)
		else:
			var sens2: float = absf(high() - low()) / 100.0 * 0.03
			_set_value(_value + nice * sens2, true)

	## SetSliderValueFromClick.
	func _on_click() -> void:
		if _drag_dir == DRAG_FREE:
			return
		var dc := control_of(part("drag-container"))
		var dg := control_of(part("dragger"))
		if dc == null or dg == null:
			return
		var horizontal := not vertical()
		if _drag_dir == DRAG_NONE:
			if is_zero_approx(page_size()):
				# Jump: the dragger centre goes to the pointer, then a free drag.
				var length := dc.size.x if horizontal else dc.size.y
				var dlen := dg.size.x if horizontal else dg.size.y
				var total := length - dlen
				var t := _translate()
				var target := (_start.x if horizontal else _start.y) - dlen / 2.0
				var pos := maxf(0.0, minf(target, total))
				var at := Vector2(pos, t.y) if horizontal else Vector2(t.x, pos)
				_set_translate(at)
				_drag_start = Rect2(at, dg.size)
				_drag_dir = DRAG_FREE
				_from_drag(length, dlen, pos)
				return
			_drag_start = Rect2(_translate(), dg.size)
		var t2 := _translate()
		if horizontal:
			_from_click(dc.size.x, dg.size.x, t2.x, _last.x)
		else:
			_from_click(dc.size.y, dg.size.y, t2.y, _last.y)

	## SetSliderValueFromDrag.
	func _on_drag() -> void:
		var dc := control_of(part("drag-container"))
		var dg := control_of(part("dragger"))
		if dc == null or dg == null:
			return
		var delta := _last - _start
		if not vertical():
			_from_drag(dc.size.x, dg.size.x, _drag_start.position.x + delta.x)
		else:
			_from_drag(dc.size.y, dg.size.y, _drag_start.position.y + delta.y)

	## ComputeValueAndDirectionFromDrag.
	func _from_drag(length: float, dlen: float, pos: float) -> void:
		var total := length - dlen
		if absf(total) < 1e-5:
			return
		var t := maxf(0.0, minf(pos, total)) / total
		_set_value(_lerp_dir(t), true)

	## ComputeValueAndDirectionFromClick (paging toward the pointer).
	func _from_click(length: float, dlen: float, pos: float, last: float) -> void:
		var total := length - dlen
		if absf(total) < 1e-5:
			return
		var decreasing := last < pos
		var increasing := last > pos + dlen
		var high_to_low := increasing if inverted() else decreasing
		var low_to_high := decreasing if inverted() else increasing
		if integer() and not is_zero_approx(page_size()):
			var step := int(page_size())
			var lo := low()
			var hi := high()
			if (lo > hi and not inverted()) or (lo < hi and inverted()) or (vertical() and not inverted()):
				step = -step
			if high_to_low and _drag_dir != DRAG_LOW_TO_HIGH:
				_drag_dir = DRAG_HIGH_TO_LOW
				_set_value(_value - step, true)
			elif low_to_high and _drag_dir != DRAG_HIGH_TO_LOW:
				_drag_dir = DRAG_LOW_TO_HIGH
				_set_value(_value + step, true)
			return
		_adjusted_page = _adjusted_page - page_size() if inverted() else _adjusted_page + page_size()
		if high_to_low and _drag_dir != DRAG_LOW_TO_HIGH:
			_drag_dir = DRAG_HIGH_TO_LOW
			_set_value(_lerp_dir(maxf(0.0, minf(pos - _adjusted_page, total)) / total), true)
		elif low_to_high and _drag_dir != DRAG_HIGH_TO_LOW:
			_drag_dir = DRAG_LOW_TO_HIGH
			_set_value(_lerp_dir(maxf(0.0, minf(pos + _adjusted_page, total)) / total), true)

	## SliderLerpDirectionalUnclamped + SliderLerpUnclamped.
	func _lerp_dir(position_t: float) -> float:
		var t := 1.0 - position_t if vertical() else position_t
		var a := low()
		var b := high()
		if inverted():
			var tmp := a
			a = b
			b = tmp
		var v := lerpf(a, b, t)
		if integer():
			return UxmlNumeric.round_even(v)
		# IMGUI's rounding from the range and the track length (Unity uses
		# the container width, also for vertical sliders).
		var dc := control_of(part("drag-container"))
		var dg := control_of(part("dragger"))
		var span := (dc.size.x - dg.size.x) if dc != null and dg != null else 0.0
		var min_diff := 0.0 if span == 0.0 else absf((high() - low()) / span)
		var dec := 0
		if min_diff != 0.0:
			dec = clampi(-floori(log(min_diff) / log(10.0)), 0, 15)
		return UxmlNumeric.round_away(v, dec)

	## Keyboard and controller: Home/End and PageUp/PageDown always, the
	## arrows while the dragger is movable (Unity's --movable class, set on
	## focus, toggled by ui_accept). True when the event was used.
	func _key(ev: InputEvent) -> bool:
		var horizontal := not vertical()
		var shift := ev is InputEventWithModifiers and (ev as InputEventWithModifiers).shift_pressed
		var k := ev as InputEventKey
		if k != null and k.pressed:
			var key := ""
			match k.keycode:
				KEY_HOME:
					key = ("highest" if inverted() else "lowest") if horizontal else ("lowest" if inverted() else "highest")
				KEY_END:
					key = ("lowest" if inverted() else "highest") if horizontal else ("highest" if inverted() else "lowest")
				KEY_PAGEUP:
					key = ("higher-page" if inverted() else "lower-page") if horizontal else ("lower-page" if inverted() else "higher-page")
				KEY_PAGEDOWN:
					key = ("lower-page" if inverted() else "higher-page") if horizontal else ("higher-page" if inverted() else "lower-page")
			if not key.is_empty():
				_from_key(key, shift)
				return true
		if ev.is_action_pressed("ui_accept") and not ev.is_echo():
			var d := part("dragger")
			if d != null:
				UxmlParts.toggle_control_class(d, "unity-base-slider--movable", not _movable())
			return true
		if not _movable():
			return false
		var lower := "ui_left" if horizontal else "ui_down"
		var higher := "ui_right" if horizontal else "ui_up"
		if ev.is_action_pressed(lower, true):
			_from_key("higher" if inverted() else "lower", shift)
			return true
		if ev.is_action_pressed(higher, true):
			_from_key("lower" if inverted() else "higher", shift)
			return true
		return false

	## ComputeValueFromKey.
	func _from_key(key: String, shift: bool) -> void:
		match key:
			"lowest":
				_set_value(low(), true)
				return
			"highest":
				_set_value(high(), true)
				return
		var page := key.ends_with("page")
		var delta := UxmlInputBehaviors.closest_power_of_ten(absf((high() - low()) * 0.01))
		if integer() and delta < 1.0:
			delta = 1.0
		if page:
			delta *= page_size()
		elif shift:
			delta *= 10.0
		if key.begins_with("lower"):
			delta = -delta
		var v := UxmlInputBehaviors.round_to_multiple(_value + delta * 0.5001, absf(delta))
		_set_value(UxmlNumeric.round_even(v) if integer() else v, true)

	# -- the optional input field ------------------------------------------

	func _on_text_field_editing(on: bool) -> void:
		_editing_text = on
		if not on:
			_update_text_field()

	## OnTextFieldValueChange: a parse failure counts as 0 (Unity).
	func _on_text_field_changed() -> void:
		var tf := part("text-field")
		var tb = doc._behaviors.get(tf)
		if tb == null:
			return
		var text: String = tb.text()
		var prev: String = tb.previous_text()
		var v := 0.0
		if integer():
			var r := UxmlNumeric._to_long(text, prev)
			v = float(clampi(r[1], UxmlNumeric.INT32_MIN, UxmlNumeric.INT32_MAX)) if r[0] else 0.0
		else:
			var r2 := UxmlNumeric._to_double(text, prev)
			v = UxmlNumeric.clamp_to_float(r2[1]) if r2[0] else 0.0
		_set_value(v, true)

	# -- model and binding --------------------------------------------------

	func on_model_changed() -> void:
		sync_text("label", "label")
		var d := part("drag-container")
		UxmlParts.toggle_control_class(el, "unity-base-slider--vertical", vertical())
		UxmlParts.toggle_control_class(el, "unity-base-slider--horizontal", not vertical())
		if _syncing:
			return
		var v := _clean(UxmlInputParts.slider_values(el)[0])
		var changed := v != _value
		_value = v
		_update_fill()
		_update_dragger()
		_update_text_field()
		if d == null:
			return
		if changed and el.part_of != null:
			ui_changed.emit()

	func bind_write(prop: String, v: Variant) -> int:
		match prop:
			"value":
				var f := _clean(_clamp(UxmlBinding._num(v)))
				if f == _value:
					return 0
				_set_value(f, false)
				return 1
			"low-value", "high-value", "page-size":
				return write_attr(prop, UxmlBinding._str(UxmlBinding._num(v)))
			"label":
				return write_attr("label", UxmlBinding._str(v), 2)
			"inverted", "fill", "show-input-field":
				return write_attr(prop, "true" if UxmlBinding._bool(v) else "false")
			"direction":
				var dir := "Vertical" if (v is int and v == 1) or UxmlBinding._str(v).to_lower() == "vertical" else "Horizontal"
				return write_attr("direction", dir, 2)
		return UNHANDLED

	func bind_read(prop: String) -> Array:
		if prop == "value":
			return [true, get_value()]
		return [false, null]


## The pointer delta of a label drag (NumericFieldDraggerUtility.NiceDelta):
## the larger axis decides the sign; Godot's y grows downward like Unity's.
static var _use_y := false


static func nice_delta(d: Vector2, acceleration: float) -> float:
	var dd := Vector2(d.x, -d.y)
	var m := maxf(absf(dd.x), absf(dd.y))
	if m > 0.0 and absf(absf(dd.x) - absf(dd.y)) / m > 0.1:
		_use_y = absf(dd.x) <= absf(dd.y)
	var s := signf(dd.y) if _use_y else signf(dd.x)
	if s == 0.0:
		s = 1.0
	return s * dd.length() * acceleration


# ---------------------------------------------------------------------------
# MinMaxSlider
# ---------------------------------------------------------------------------

class MinMaxBehavior extends InputBehavior:
	const NO_THUMB := 3
	const MIN_THUMB := 0
	const MAX_THUMB := 1
	const MIDDLE := 2

	var _v := Vector2.ZERO
	var _lo := 0.0
	var _hi := 10.0
	var _state := NO_THUMB
	var _pressed := false
	var _start := Vector2.ZERO
	var _start_value := Vector2.ZERO

	func low_attr() -> String:
		return "low-limit"

	func high_attr() -> String:
		return "high-limit"

	func low() -> float:
		return _lo

	func high() -> float:
		return _hi

	func get_value() -> Variant:
		return _v

	func set_value_from_code(v: Variant) -> void:
		if v is Vector2:
			_set_value(v, true)

	func setup() -> void:
		var c := doc._controls.get(el) as UxmlSlider
		if c == null:
			return
		c.behavior = self
		validate()
		_read()
		c.focus_entered.connect(_on_focus.bind(true))
		c.focus_exited.connect(_on_focus.bind(false))
		doc._layout_hooks.append(_after_layout)
		var ic := control_of(part("input"))
		if ic != null:
			ic.gui_input.connect(on_part_input.bind(ic))

	func native() -> Control:
		return doc._controls.get(el)

	func _read() -> void:
		var vals := UxmlInputParts.min_max_values(el)
		_v = Vector2(UxmlNumeric.f32_clean(vals[0]), UxmlNumeric.f32_clean(vals[1]))
		_lo = vals[2]
		_hi = vals[3]

	func _after_layout() -> void:
		UxmlInputParts.layout_styles(el, size_of, style_of, _parts)

	func _set_value(v: Vector2, notify: bool) -> void:
		var hi := _hi
		var lo := _lo
		var b := minf(v.y, hi)
		var nv := Vector2(clampf(v.x, lo, b), clampf(b, v.x, hi))
		nv = Vector2(UxmlNumeric.f32_clean(nv.x), UxmlNumeric.f32_clean(nv.y))
		if nv == _v:
			return
		_v = nv
		_syncing = true
		el.set_attribute("min-value", str(nv.x))
		el.set_attribute("max-value", str(nv.y))
		_syncing = false
		UxmlInputParts.layout_styles(el, size_of, style_of, _parts)
		if notify:
			emit_value(_v)
			var c := native() as UxmlSlider
			if c != null:
				c.value_changed.emit(_v)

	func _nav_state() -> int:
		var mn := part("thumb-min")
		var mx := part("thumb-max")
		var a := mn != null and UxmlParts.control_classes(mn).has("unity-min-max-slider--movable")
		var b := mx != null and UxmlParts.control_classes(mx).has("unity-min-max-slider--movable")
		if a:
			return MIDDLE if b else MIN_THUMB
		return MAX_THUMB if b else NO_THUMB

	func _set_nav_state(s: int) -> void:
		for pair in [["thumb-min", s == MIN_THUMB or s == MIDDLE], ["thumb-max", s == MAX_THUMB or s == MIDDLE],
				["dragger", s == MIDDLE]]:
			var x := part(pair[0])
			if x != null:
				UxmlParts.toggle_control_class(x, "unity-min-max-slider--movable", pair[1])

	func _on_focus(on: bool) -> void:
		set_state(part("input"), "focus", on)
		if on:
			if _nav_state() == NO_THUMB:
				_set_nav_state(MIN_THUMB)
		else:
			_set_nav_state(NO_THUMB)

	func _from_position(x: float) -> float:
		var w := size_of(part("input")).x
		var t := 0.0 if w == 0.0 else x / w
		return lerpf(_lo, _hi, t)

	func on_input(ev: InputEvent) -> void:
		var c := native() as UxmlSlider
		if c == null or is_disabled():
			return
		var input := control_of(part("input"))
		var mb := ev as InputEventMouseButton
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
			if not mb.pressed:
				_pressed = false
				return
			if input == null:
				return
			var p := UxmlInputBehaviors.to_local(c, input, mb.position)
			if not Rect2(Vector2.ZERO, input.size).has_point(p):
				return
			c.grab_focus()
			c.accept_event()
			_press(c, p)
			return
		var mm := ev as InputEventMouseMotion
		if mm != null and _pressed and input != null:
			var p2 := UxmlInputBehaviors.to_local(c, input, mm.position)
			_drag(_start.x, p2.x)
			c.accept_event()
			return
		if ev.is_action_pressed("ui_accept") and not ev.is_echo():
			var ns := _nav_state() + 1
			if ns > NO_THUMB:
				ns = MIN_THUMB
			_set_nav_state(ns)
			c.accept_event()
			return
		var s := _nav_state()
		if s == NO_THUMB:
			return
		var shift := ev is InputEventWithModifiers and (ev as InputEventWithModifiers).shift_pressed
		if ev.is_action_pressed("ui_left", true):
			_key(true, shift, s)
			c.accept_event()
		elif ev.is_action_pressed("ui_right", true):
			_key(false, shift, s)
			c.accept_event()

	## SetSliderValueFromClick.
	func _press(c: Control, p: Vector2) -> void:
		var input := control_of(part("input"))
		var dragger := control_of(part("dragger"))
		var mn := control_of(part("thumb-min"))
		var mx := control_of(part("thumb-max"))
		var gp := input.get_global_transform() * p
		if mn != null and mn.get_global_rect().has_point(gp):
			_state = MIN_THUMB
		elif mx != null and mx.get_global_rect().has_point(gp):
			_state = MAX_THUMB
		elif dragger != null and p.x > dragger.position.x and p.x < dragger.position.x + dragger.size.x:
			_state = MIDDLE
		else:
			_state = NO_THUMB
		if _state == NO_THUMB:
			var nv := _from_position(p.x)
			if dragger != null and p.x < dragger.position.x:
				_state = MIN_THUMB
				_set_value(Vector2(nv, _v.y), true)
			else:
				_state = MAX_THUMB
				_set_value(Vector2(_v.x, nv), true)
		_set_nav_state(_state)
		_start_value = _v
		_start = p
		_pressed = true

	## ComputeValueFromDraggingThumb.
	func _drag(from_x: float, to_x: float) -> void:
		var d := _from_position(to_x) - _from_position(from_x)
		_set_nav_state(_state)
		match _state:
			MIDDLE:
				var nv := _start_value + Vector2(d, d)
				var span := _start_value.y - _start_value.x
				if nv.x < _lo:
					nv = Vector2(_lo, _lo + span)
				elif nv.y > _hi:
					nv = Vector2(_hi - span, _hi)
				_set_value(nv, true)
			MIN_THUMB:
				_set_value(Vector2(clampf(_start_value.x + d, _lo, _v.y), _v.y), true)
			MAX_THUMB:
				_set_value(Vector2(_v.x, clampf(_start_value.y + d, _v.x, _hi)), true)

	## ComputeValueFromKey.
	func _key(left: bool, shift: bool, s: int) -> void:
		var delta := UxmlInputBehaviors.closest_power_of_ten(absf((_hi - _lo) * 0.01))
		if shift:
			delta *= 10.0
		if left:
			delta = -delta
		match s:
			MIN_THUMB:
				var t := clampf(UxmlInputBehaviors.round_to_multiple(_v.x + delta * 0.5001, absf(delta)), _lo, _v.y)
				_set_value(Vector2(t, _v.y), true)
			MAX_THUMB:
				var t2 := clampf(UxmlInputBehaviors.round_to_multiple(_v.y + delta * 0.5001, absf(delta)), _v.x, _hi)
				_set_value(Vector2(_v.x, t2), true)
			MIDDLE:
				var span := _v.y - _v.x
				if delta > 0.0:
					var t3 := clampf(UxmlInputBehaviors.round_to_multiple(_v.y + delta * 0.5001, absf(delta)), _v.x, _hi)
					_set_value(Vector2(t3 - span, t3), true)
				else:
					var t4 := clampf(UxmlInputBehaviors.round_to_multiple(_v.x + delta * 0.5001, absf(delta)), _lo, _v.y)
					_set_value(Vector2(t4, t4 + span), true)

	func on_model_changed() -> void:
		sync_text("label", "label")
		if _syncing:
			return
		_read()
		UxmlInputParts.layout_styles(el, size_of, style_of, _parts)

	func bind_write(prop: String, v: Variant) -> int:
		match prop:
			"value":
				if not v is Vector2 and not v is Vector2i:
					return -1
				var nv := Vector2(v)
				if nv == _v:
					return 0
				_set_value(nv, false)
				return 1
			"min-value", "max-value", "low-limit", "high-limit":
				return write_attr(prop, UxmlBinding._str(UxmlBinding._num(v)))
			"label":
				return write_attr("label", UxmlBinding._str(v), 2)
		return UNHANDLED

	func bind_read(prop: String) -> Array:
		match prop:
			"value":
				return [true, _v]
			"min-value":
				return [true, _v.x]
			"max-value":
				return [true, _v.y]
		return [false, null]


# ---------------------------------------------------------------------------
# TextField and the numeric fields
# ---------------------------------------------------------------------------

## The editor (LineEdit/TextEdit) side shared by TextField and the numeric
## fields: focus, placeholder, Escape, Enter, delayed commits, the
## selection attributes.
class TextBehavior extends InputBehavior:
	## Emitted when the editor starts (true) or stops (false) editing (focus).
	signal editing(on: bool)

	var _ed: Control = null
	var _original := ""          # text at focus (Unity's originalText)
	var _previous := ""          # text before the last change
	var _focused := false
	var _restoring := false
	var _label_drag := false
	var _drag_start: Variant = null

	func setup() -> void:
		_ed = control_of(part("editor"))
		if _ed == null:
			return
		if _ed is LineEdit:
			var le := _ed as LineEdit
			le.text_changed.connect(_on_text_changed)
			le.text_submitted.connect(_on_submitted)
		else:
			(_ed as TextEdit).text_changed.connect(func(): _on_text_changed((_ed as TextEdit).text))
		_ed.focus_entered.connect(_on_focus.bind(true))
		_ed.focus_exited.connect(_on_focus.bind(false))
		_ed.gui_input.connect(_on_editor_input)
		var lc := control_of(part("label"))
		if lc != null:
			lc.gui_input.connect(_on_label_input.bind(lc))
		validate()
		_previous = text()
		_placeholder()

	func text() -> String:
		return "" if _ed == null else String(_ed.get("text"))

	func previous_text() -> String:
		return _previous

	## Replace the shown text without user-edit side effects.
	func set_text_quiet(t: String) -> void:
		if _ed == null or text() == t:
			return
		_restoring = true
		if _ed is LineEdit:
			var le := _ed as LineEdit
			var caret := le.caret_column
			le.text = t
			le.caret_column = mini(caret, t.length())
		else:
			_ed.set("text", t)
		_restoring = false
		_previous = t
		_sync_editor_attr(t)
		_placeholder()

	func _sync_editor_attr(t: String) -> void:
		var ed := part("editor")
		if ed != null and ed.get_attribute("text") != t:
			ed.attributes = ed.attributes.duplicate(true)
			for a in ed.attributes:
				if a["name"] == "text":
					a["value"] = t

	func delayed() -> bool:
		return flag("is-delayed", false)

	## Unity's showPlaceholderText: a placeholder, no text, and not hidden
	## by hide-placeholder-on-focus while focused.
	func _placeholder() -> void:
		var ph := attr("placeholder-text")
		var hide_now := flag("hide-placeholder-on-focus", false) and _focused
		var show := not ph.is_empty() and text().is_empty() and not hide_now
		var input := part("input")
		if input != null:
			UxmlParts.toggle_control_class(input, "unity-base-text-field__input--placeholder", show)
		if _ed != null:
			if not _ph_listed and not ph.is_empty() and _ed is LineEdit:
				_ph_listed = true
				doc._placeholder_fields.append(self)
			if _ph_listed and not hide_now and not ph.is_empty() and doc._applier != null \
					and not _ph_position().is_empty():
				# R30: the elided text is written once (each write of the
				# LineEdit's placeholder shapes it).
				_ph_shown = ""
				_ph_memo = []
				elide_placeholder(true)
				return
			_ed.set("placeholder_text", "" if hide_now else ph)
			_ph_shown = ""
			if _ph_listed:
				elide_placeholder()

	var _ph_listed := false
	## The elided placeholder on the LineEdit ("": the whole text).
	var _ph_shown := ""
	var _ph_memo: Array = []

	## `text-overflow: ellipsis` on the field, its input or its editor part
	## elides the placeholder to the width of the LineEdit, at the
	## `-unity-text-overflow-position` of that element, and the whole text is
	## the tooltip while it shows (TextElement.ElideText of a Label). Runs after
	## every placement and placeholder change (UxmlDocument._update_elision).
	##
	## `fresh`: the placeholder changed and the LineEdit still shows the old
	## one (_placeholder writes the elided text only).
	func elide_placeholder(fresh := false) -> void:
		var le := _ed as LineEdit
		if le == null or doc._applier == null:
			return
		var ph := attr("placeholder-text")
		var pos := _ph_position()
		if pos.is_empty() or (le.placeholder_text.is_empty() and not fresh):
			if not _ph_shown.is_empty():
				_ph_shown = ""
				_ph_memo = []
				if not le.placeholder_text.is_empty():
					le.placeholder_text = ph
				doc._applier._elided_tooltip(le, false, ph)
			return
		var fs := le.get_theme_font_size(&"font_size")
		var font := le.get_theme_font(&"font")
		var sb := le.get_theme_stylebox(&"normal")
		var memo := [ph, le.size.x, pos, fs, font, sb, text().is_empty()]
		if memo == _ph_memo:
			return
		_ph_memo = memo
		var width: float = le.size.x - (0.0 if sb == null else sb.get_minimum_size().x)
		var shown := ph if font == null else UxmlStyleApplier.elide_text(ph, width, pos, font, fs)
		_ph_shown = "" if shown == ph else shown
		if le.placeholder_text != shown:
			le.placeholder_text = shown
		doc._applier._elided_tooltip(le, not _ph_shown.is_empty() and text().is_empty(), ph)

	## The overflow position of the first of the field, its input and its
	## editor with `text-overflow: ellipsis`, else "".
	func _ph_position() -> String:
		for x in [el, part("input"), part("editor")]:
			if x == null:
				continue
			var st: Dictionary = style_of(x)
			var e = st.get("text-overflow")
			if e != null and String(e["value"]) == "ellipsis":
				var p = st.get("-unity-text-overflow-position")
				var v := "end" if p == null else String(p["value"])
				return v if v == "start" or v == "middle" else "end"
		return ""

	func _on_focus(on: bool) -> void:
		_focused = on
		if on:
			_original = text()
			_previous = _original
			on_edit_start()
		else:
			commit_on_blur()
		_placeholder()
		editing.emit(on)

	func _on_editor_input(ev: InputEvent) -> void:
		var mb := ev as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and mb.double_click:
			# Godot selects the word on a double click and the line on a
			# triple click; the Unity attributes can turn that off.
			if not flag("select-word-by-double-click", true) or not flag("select-line-by-triple-click", true):
				_ed.call_deferred("deselect")
		if ev.is_action_pressed("ui_cancel") and _focused:
			# Escape: RestoreValueAndText.
			restore()
		if _ed is TextEdit and ev is InputEventKey and (ev as InputEventKey).pressed \
				and (ev as InputEventKey).keycode == KEY_ENTER and (ev as InputEventKey).shift_pressed:
			# Multiline: Shift+Enter commits, as Enter does on one line.
			_ed.accept_event()
			commit_on_blur()

	func _on_text_changed(t: String) -> void:
		if _restoring:
			return
		var clean := sanitize(t)
		if clean != t:
			set_text_quiet(clean)
			t = clean
		_sync_editor_attr(t)
		on_edit(t)
		_previous = t
		_placeholder()

	func _on_submitted(_t: String) -> void:
		commit_on_blur()

	## The pointer on a label with a dragger (FieldMouseDragger); `ev` is
	## in the space of the label control `fc`.
	func _on_label_input(ev: InputEvent, fc: Control) -> void:
		var mb := ev as InputEventMouseButton
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed and label_drags() and not is_disabled():
				if Rect2(Vector2.ZERO, fc.size).has_point(mb.position):
					_label_drag = true
					_drag_start = drag_start()
					fc.accept_event()
			elif not mb.pressed and _label_drag:
				_label_drag = false
				drag_end()
				fc.accept_event()
			return
		var mm := ev as InputEventMouseMotion
		if mm != null and _label_drag:
			var speed := 4.0 if mm.shift_pressed else (0.25 if mm.alt_pressed else 1.0)
			drag_by(mm.relative, speed, _drag_start)
			fc.accept_event()
		elif _label_drag and ev.is_action_pressed("ui_cancel"):
			_label_drag = false
			drag_cancel(_drag_start)
			fc.accept_event()

	# Overridden by the subclasses.
	func sanitize(t: String) -> String:
		return t

	func on_edit_start() -> void:
		pass

	func on_edit(_t: String) -> void:
		pass

	func commit_on_blur() -> void:
		pass

	func restore() -> void:
		pass

	func label_drags() -> bool:
		return false

	func drag_start() -> Variant:
		return null

	func drag_by(_d: Vector2, _speed: float, _start_v: Variant) -> void:
		pass

	func drag_end() -> void:
		pass

	func drag_cancel(_start_v: Variant) -> void:
		pass

	func on_model_changed() -> void:
		sync_text("label", "label")
		if _ed != null:
			UxmlTextInput.configure(_ed, el)
			# readonly after load: editable follows unless the field is
			# disabled (the applier then restores the authored state).
			_ed.set("editable", bool(_ed.get_meta("uxml_editable", true)) and not is_disabled())
		_placeholder()

	func native() -> Control:
		return _ed if _ed != null else doc._controls.get(el)

	func bind_write_common(prop: String, v: Variant) -> int:
		match prop:
			"label":
				return write_attr("label", UxmlBinding._str(v), 2)
			"placeholder-text":
				return write_attr("placeholder-text", UxmlBinding._str(v))
			"readonly":
				return write_attr("readonly", "true" if UxmlBinding._bool(v) else "false")
			"max-length":
				return write_attr("max-length", str(int(UxmlBinding._num(v))))
			"is-delayed", "password", "multiline", "hide-placeholder-on-focus":
				return write_attr(prop, "true" if UxmlBinding._bool(v) else "false")
			"mask-character":
				return write_attr("mask-character", UxmlBinding._str(v))
		return UNHANDLED


## TextField: the value is the text. Not delayed: every edit is a value
## change (Unity's UpdateValueFromText on each key); delayed: Enter or the
## end of editing.
class TextFieldBehavior extends TextBehavior:
	var _value := ""
	var _sv: UxmlElement = null  # the inner ScrollView of a multiline field

	func setup() -> void:
		super.setup()
		_value = text()
		_sv = UxmlParts.find_part(el, "scroll-view")
		if _sv != null and _ed is TextEdit:
			(_ed as TextEdit).caret_changed.connect(_follow_caret)

	## Unity TextInputBase.UpdateScrollOffset: the inner ScrollView scrolls
	## so that the caret stays in the viewport.
	func _follow_caret() -> void:
		var b = doc._behaviors.get(_sv)
		var vp := control_of(UxmlContainerParts.get_part(_sv, "viewport"))
		if b == null or vp == null or not (_ed is TextEdit):
			return
		var te := _ed as TextEdit
		var lh := float(te.get_line_height())
		var p := te.get_caret_draw_pos()
		var top := te.position + Vector2(p.x, p.y - lh)
		var off: Vector2 = b.offset()
		var vs := vp.size
		if top.y < off.y:
			off.y = top.y
		elif top.y + lh > off.y + vs.y:
			off.y = top.y + lh - vs.y
		if top.x < off.x:
			off.x = top.x
		elif top.x + 1.0 > off.x + vs.x:
			off.x = top.x + 1.0 - vs.x
		b.set_offset(off)

	func _commit(t: String) -> void:
		if t == _value:
			return
		_value = t
		quiet_attr("value", t)
		emit_value(t)

	func sanitize(t: String) -> String:
		if _ed is TextEdit:
			var ml := int(UxmlInputParts.num(el, "max-length", -1.0))
			if ml >= 0 and t.length() > ml:
				return t.substr(0, ml)
		return t

	func on_edit(t: String) -> void:
		if not delayed():
			_commit(t)

	func commit_on_blur() -> void:
		_commit(text())

	func restore() -> void:
		set_text_quiet(_original)
		_commit(_original)

	func on_model_changed() -> void:
		super.on_model_changed()
		if _syncing:
			return
		var t := UxmlInputParts.text_value(el)
		if t != _value:
			_value = t
			if not _focused:
				set_text_quiet(t)

	## set_field_value wrote the text, the value and the placeholder state;
	## set_field_placeholder changes only the placeholder.
	func on_quiet_change(n: String) -> void:
		if n == "value":
			return
		if n == "placeholder-text":
			_placeholder()
			return
		on_model_changed()

	func bind_write(prop: String, v: Variant) -> int:
		match prop:
			"value", "text":
				var s := UxmlBinding._str(v)
				if s == _value and s == text():
					return 0
				_value = s
				quiet_attr("value", s)
				set_text_quiet(s)
				return 1
		return bind_write_common(prop, v)

	func bind_read(prop: String) -> Array:
		if prop == "value" or prop == "text":
			return [true, _value]
		return [false, null]


## The numeric fields: the text is typed (only the allowed characters),
## evaluated with Unity's expression rules (UxmlNumeric) on each edit or,
## delayed, on Enter / end of editing; the text then shows the value as the
## field formats it. The label drags the value (not for Hash128Field).
class NumericBehavior extends TextBehavior:
	var _value: Variant = 0
	var _original_value: Variant = 0

	func setup() -> void:
		super.setup()
		_value = UxmlNumeric.parse_attr(el.local, attr("value"))
		if el.local == "FloatField":
			_value = UxmlNumeric.f32_clean(_value)
		_update_dragger_class()

	func get_value() -> Variant:
		return _value

	func _clean(v: Variant) -> Variant:
		return UxmlNumeric.f32_clean(v) if el.local == "FloatField" else v

	func _commit(v: Variant, notify := true) -> void:
		v = _clean(v)
		if typeof(v) == typeof(_value) and v == _value:
			return
		if v is float and _value is float and is_nan(v) and is_nan(_value):
			return
		_value = v
		quiet_attr("value", UxmlNumeric.format(el.local, v))
		if notify:
			emit_value(v)

	func _eval(t: String) -> Variant:
		return UxmlNumeric.evaluate(el.local, t, _original, _value)

	func sanitize(t: String) -> String:
		var allowed := UxmlNumeric.allowed(el.local)
		if el.local == "Hash128Field":
			allowed = UxmlNumeric.ALLOWED_HASH
		if allowed.is_empty():
			return t
		var out := ""
		for i in t.length():
			if allowed.contains(t[i]):
				out += t[i]
		return out

	func on_edit_start() -> void:
		_original_value = _value

	func on_edit(t: String) -> void:
		if not delayed():
			_commit(_eval(t))

	## Unity: an empty text shows the value again; else the text is
	## evaluated and then shows the value as formatted.
	func commit_on_blur() -> void:
		var t := text()
		if not t.is_empty():
			_commit(_eval(t))
		set_text_quiet(UxmlNumeric.format(el.local, _value))
		_original = text()

	func restore() -> void:
		set_text_quiet(_original)
		_commit(_original_value)

	func label_drags() -> bool:
		var spec: Array = UxmlInputParts.NUMERIC.get(el.local, ["", "", false])
		return spec[2] and not flag("readonly", false)

	func drag_start() -> Variant:
		return _value

	## ApplyInputDeviceDelta of the numeric inputs.
	func drag_by(d: Vector2, speed: float, start_v: Variant) -> void:
		var nice := UxmlInputBehaviors.nice_delta(d, speed)
		var cur: Variant = _eval(text())
		match el.local:
			"FloatField", "DoubleField":
				var sv := float(start_v)
				var sens := 0.0 if (is_inf(sv) or is_nan(sv)) else maxf(1.0, sqrt(absf(sv))) * 0.03
				var v := float(cur) + nice * sens
				v = UxmlNumeric.round_min_diff(v, sens)
				_set_dragged(UxmlNumeric.clamp_to_float(v) if el.local == "FloatField" else v)
			_:
				var sens2 := maxf(1.0, sqrt(absf(float(start_v))) * 0.03)
				if el.local in ["IntegerField", "LongField", "UnsignedIntegerField"]:
					sens2 = float(int(sens2))
				var step := int(roundf(nice * sens2))
				var n := int(cur) + step
				match el.local:
					"IntegerField":
						n = clampi(n, UxmlNumeric.INT32_MIN, UxmlNumeric.INT32_MAX)
					"UnsignedIntegerField":
						n = clampi(n, 0, UxmlNumeric.UINT32_MAX)
					"UnsignedLongField":
						if int(cur) >= 0 and n < 0 and step < 0:
							n = 0
				_set_dragged(n)

	func _set_dragged(v: Variant) -> void:
		if delayed():
			set_text_quiet(UxmlNumeric.format(el.local, _clean(v)))
		else:
			_commit(v)
			set_text_quiet(UxmlNumeric.format(el.local, _value))

	func drag_end() -> void:
		if delayed():
			_commit(_eval(text()))

	func drag_cancel(start_v: Variant) -> void:
		_commit(start_v)
		set_text_quiet(UxmlNumeric.format(el.local, _value))

	func _update_dragger_class() -> void:
		var label := part("label")
		var spec: Array = UxmlInputParts.NUMERIC.get(el.local, ["", "", false])
		if label != null and spec[2]:
			UxmlParts.toggle_control_class(label, "unity-base-field__label--with-dragger", not flag("readonly", false))

	func on_model_changed() -> void:
		super.on_model_changed()
		_update_dragger_class()
		if _syncing:
			return
		var v: Variant = _clean(UxmlNumeric.parse_attr(el.local, attr("value")))
		if typeof(v) != typeof(_value) or v != _value:
			_value = v
			if not _focused:
				set_text_quiet(UxmlNumeric.format(el.local, v))
			if el.part_of != null:
				ui_changed.emit()

	## Set the value from the owner (a composite field): no document signal.
	func set_value_quiet(v: Variant) -> void:
		v = _clean(_coerce(v))
		_value = v
		quiet_attr("value", UxmlNumeric.format(el.local, v))
		if not _focused:
			set_text_quiet(UxmlNumeric.format(el.local, v))

	func _coerce(v: Variant) -> Variant:
		match UxmlNumeric.KIND.get(el.local, ""):
			"float", "double":
				return float(UxmlBinding._num(v)) if not v is String else UxmlNumeric.parse_attr(el.local, v)
			"hash":
				return UxmlNumeric.hash_parse(UxmlBinding._str(v))
		if v is String:
			return UxmlNumeric.parse_attr(el.local, v)
		return UxmlNumeric.parse_attr(el.local, UxmlBinding._str(UxmlBinding._num(v)) if not v is int else str(v)) if not v is int else _clamp_int(v)

	func _clamp_int(n: int) -> int:
		match el.local:
			"IntegerField":
				return clampi(n, UxmlNumeric.INT32_MIN, UxmlNumeric.INT32_MAX)
			"UnsignedIntegerField":
				return clampi(n, 0, UxmlNumeric.UINT32_MAX)
		return n

	func bind_write(prop: String, v: Variant) -> int:
		match prop:
			"value":
				var nv: Variant = _clean(_coerce(v))
				if typeof(nv) == typeof(_value) and nv == _value:
					return 0
				set_value_quiet(nv)
				return 1
		return bind_write_common(prop, v)

	func bind_read(prop: String) -> Array:
		if prop == "value":
			return [true, _value]
		if prop == "text":
			return [true, text()]
		return [false, null]


# ---------------------------------------------------------------------------
# Composite fields
# ---------------------------------------------------------------------------

## Vector2/3/4(Int)Field, Rect(Int)Field, Bounds(Int)Field: the value is
## composed from the sub-fields (their own NumericBehaviors or, for the
## bounds fields, two vector fields). Value types: Vector2, Vector2i,
## Vector3, Vector3i, Vector4, Rect2, Rect2i, and AABB for the bounds
## fields (BoundsField: position = center - extents, size = 2 * extents;
## BoundsIntField: position and size).
class CompositeBehavior extends InputBehavior:
	var _subs: Array = []   # [attr or prefix, element]

	func setup() -> void:
		validate()
		if UxmlInputParts.BOUNDS.has(el.local):
			for sub in UxmlInputParts.BOUNDS[el.local][2]:
				_subs.append([sub[0], part("field-" + String(sub[0]))])
		else:
			for g in UxmlInputParts.COMPOSITE[el.local][2]:
				for f in g:
					_subs.append([f[0], part("field-" + String(f[0]))])
		for s in _subs:
			var b = doc._behaviors.get(s[1])
			if b != null:
				b.ui_changed.connect(_on_sub_changed)

	func native() -> Control:
		if _subs.is_empty():
			return doc._controls.get(el)
		var b = doc._behaviors.get(_subs[0][1])
		return b.native() if b != null else doc._controls.get(el)

	func _sub(i: int):
		return doc._behaviors.get(_subs[i][1])

	func _comp(i: int) -> Variant:
		var b = _sub(i)
		return 0 if b == null else b.get_value()

	func get_value() -> Variant:
		match el.local:
			"Vector2Field":
				return Vector2(_comp(0), _comp(1))
			"Vector2IntField":
				return Vector2i(_comp(0), _comp(1))
			"Vector3Field":
				return Vector3(_comp(0), _comp(1), _comp(2))
			"Vector3IntField":
				return Vector3i(_comp(0), _comp(1), _comp(2))
			"Vector4Field":
				return Vector4(_comp(0), _comp(1), _comp(2), _comp(3))
			"RectField":
				return Rect2(_comp(0), _comp(1), _comp(2), _comp(3))
			"RectIntField":
				return Rect2i(_comp(0), _comp(1), _comp(2), _comp(3))
			"BoundsField":
				var c: Vector3 = _comp(0)
				var e: Vector3 = _comp(1)
				return AABB(c - e, e * 2.0)
			"BoundsIntField":
				var p: Vector3i = _comp(0)
				var s: Vector3i = _comp(1)
				return AABB(Vector3(p), Vector3(s))
		return null

	## The components of `v` in sub-field order, or null for a wrong type.
	func _split(v: Variant) -> Variant:
		match el.local:
			"Vector2Field", "Vector2IntField":
				if v is Vector2 or v is Vector2i:
					return [v.x, v.y]
			"Vector3Field", "Vector3IntField":
				if v is Vector3 or v is Vector3i:
					return [v.x, v.y, v.z]
			"Vector4Field":
				if v is Vector4 or v is Vector4i or v is Quaternion:
					return [v.x, v.y, v.z, v.w]
				if v is Color:
					return [v.r, v.g, v.b, v.a]
			"RectField", "RectIntField":
				if v is Rect2 or v is Rect2i:
					return [v.position.x, v.position.y, v.size.x, v.size.y]
			"BoundsField":
				if v is AABB:
					var e: Vector3 = (v as AABB).size * 0.5
					return [(v as AABB).position + e, e]
			"BoundsIntField":
				if v is AABB:
					return [Vector3i((v as AABB).position), Vector3i((v as AABB).size)]
		return null

	func _on_sub_changed() -> void:
		var v: Variant = get_value()
		_syncing = true
		for i in _subs.size():
			if UxmlInputParts.COMPOSITE.has(el.local):
				el.set_attribute(_subs[i][0], UxmlNumeric.format_g(float(_comp(i)), 15, true))
		_syncing = false
		emit_value(v)

	func set_value_quiet(v: Variant) -> bool:
		var parts = _split(v)
		if parts == null:
			return false
		for i in mini(_subs.size(), (parts as Array).size()):
			var b = _sub(i)
			if b != null:
				b.set_value_quiet(parts[i])
		return true

	func on_model_changed() -> void:
		sync_text("label", "label")
		if _syncing or not UxmlInputParts.COMPOSITE.has(el.local):
			return
		for i in _subs.size():
			var b = _sub(i)
			if b != null and el.has_attribute(_subs[i][0]):
				b.set_value_quiet(attr(_subs[i][0]))

	func bind_write(prop: String, v: Variant) -> int:
		match prop:
			"value":
				if v == get_value():
					return 0
				return 1 if set_value_quiet(v) else -1
			"label":
				return write_attr("label", UxmlBinding._str(v), 2)
		return UNHANDLED

	func bind_read(prop: String) -> Array:
		if prop == "value":
			return [true, get_value()]
		return [false, null]


# ---------------------------------------------------------------------------
# DropdownField, EnumField
# ---------------------------------------------------------------------------

## DropdownField: `choices` and `index`; the value is the choice text (a
## value set from code or a binding that is not a choice is shown with
## index -1, as in Unity). EnumField: the entries of the registered enum
## (UxmlDocument.register_enum) or of the bound property's enum hint; the
## value is the enum's int. The menu is UxmlPopupMenu; the field is
## :active while the menu is open.
class PopupBehavior extends InputBehavior:
	var _choices := PackedStringArray()
	var _index := -1
	var _value: Variant = null
	var _enum := {}          # EnumField: {names, values, labels, obsolete}
	var _shown: Array = []   # EnumField: entry indices shown in the menu
	var _menu: UxmlPopupMenu = null

	func is_enum() -> bool:
		return el.local == "EnumField"

	func setup() -> void:
		var c := doc._controls.get(el) as UxmlPopupField
		if c == null:
			return
		c.behavior = self
		validate()
		c.focus_entered.connect(_on_focus.bind(true))
		c.focus_exited.connect(_on_focus.bind(false))
		if not is_enum() and el.has_attribute("index") and UxmlInputParts.dropdown_index(el) < 0 \
				and int(UxmlInputParts.num(el, "index", -1.0)) != -1:
			warn('index="%s" is out of range for %d choices; nothing is selected' % [attr("index"), UxmlInputParts.choices_of(el).size()])
		if is_enum():
			_enum = UxmlInputParts.enum_info(attr("type"))
			_rebuild_enum()
			_index = UxmlInputParts.enum_index(_enum, attr("value"))
			_value = null if _index < 0 else (_enum["values"] as Array)[_index]
		else:
			_choices = UxmlInputParts.choices_of(el)
			_index = UxmlInputParts.dropdown_index(el)
			_value = null if _index < 0 else _choices[_index]

	func native() -> Control:
		return doc._controls.get(el)

	func _rebuild_enum() -> void:
		_shown = []
		if _enum.is_empty():
			return
		var include := flag("include-obsolete-values", false)
		var names: PackedStringArray = _enum["names"]
		for i in names.size():
			if include or not (_enum["obsolete"] as Dictionary).has(names[i]):
				_shown.append(i)

	## The menu items.
	func items() -> PackedStringArray:
		if not is_enum():
			return _choices
		var out := PackedStringArray()
		for i in _shown:
			out.append(String(_enum["labels"][i]))
		return out

	## The selected menu item, or -1.
	func index() -> int:
		return _shown.find(_index) if is_enum() else _index

	func get_value() -> Variant:
		return _value

	func _on_focus(on: bool) -> void:
		set_state(part("input"), "focus", on)

	func on_input(ev: InputEvent) -> void:
		var c := native() as UxmlPopupField
		if c == null or is_disabled():
			return
		var mb := ev as InputEventMouseButton
		if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			c.grab_focus()
			c.accept_event()
			open_menu()
			return
		if ev.is_action_pressed("ui_accept") and not ev.is_echo():
			c.accept_event()
			open_menu()

	func open_menu() -> void:
		if _menu != null and is_instance_valid(_menu):
			return
		var anchor := control_of(part("input"))
		if anchor == null:
			anchor = native()
		_menu = UxmlPopupMenu.open(anchor, items(), index(), doc.theme_path, doc)
		_menu.chosen.connect(choose.bind(true))
		_menu.popup_hide.connect(_on_menu_closed)
		set_state(el, "active", true)

	func _on_menu_closed() -> void:
		_menu = null
		set_state(el, "active", false)
		var c := native()
		if c != null and c.is_inside_tree():
			c.grab_focus()

	## Select menu item `i` (a user choice when `notify`).
	func choose(i: int, notify: bool) -> void:
		if is_enum():
			if i < 0 or i >= _shown.size():
				return
			var entry: int = _shown[i]
			if entry == _index:
				return
			_index = entry
			_value = (_enum["values"] as Array)[entry]
			_show(String(_enum["labels"][entry]))
			quiet_attr("value", String(_enum["names"][entry]))
		else:
			if i < 0 or i >= _choices.size() or i == _index:
				return
			_index = i
			_value = _choices[i]
			_show(_choices[i])
			quiet_attr("index", str(i))
		if notify:
			emit_value(_value)
			var c := native() as UxmlPopupField
			if c != null:
				c.item_selected.emit(index())

	func _show(t: String) -> void:
		var tp := part("text")
		if tp == null:
			return
		if tp.get_attribute("text") != t:
			tp.attributes = tp.attributes.duplicate(true)
			var found := false
			for a in tp.attributes:
				if a["name"] == "text":
					a["value"] = t
					found = true
			if not found:
				tp.attributes.append({"name": "text", "value": t, "offset": 0})
			var c := control_of(tp)
			if c != null:
				doc._set_control_text(c, t)
			if doc._v2 != null:
				doc._v2.part_text(tp)  # runtime v2 draws the part's text
			doc.relayout()

	## A Dropdown value that is a choice selects it; any other value is shown
	## with index -1 (Unity's DropdownField.value setter).
	func _set_dropdown_value(s: String) -> bool:
		var i := _choices.find(s)
		if s == String(_value if _value != null else "") and i == _index:
			return false
		_index = i
		_value = s
		_show(s)
		return true

	## EnumField: the value by int or by name.
	func _set_enum_value(v: Variant) -> bool:
		if _enum.is_empty():
			return false
		var i := -1
		if v is int or v is float:
			i = (_enum["values"] as Array).find(int(v))
		else:
			i = UxmlInputParts.enum_index(_enum, UxmlBinding._str(v))
		if i < 0 or i == _index:
			return false
		_index = i
		_value = (_enum["values"] as Array)[i]
		_show(String(_enum["labels"][i]))
		return true

	## A binding to an Object property with an enum hint gives the entries
	## when no enum is registered for `type` (UxmlBinding calls this).
	func bind_source_info(source: Variant, parts: Array) -> void:
		if not is_enum() or not _enum.is_empty() or parts.is_empty():
			return
		var holder = source
		for k in parts.size() - 1:
			holder = UxmlBinding.get_value(holder, [parts[k]])[1] if holder != null else null
		if not holder is Object:
			return
		var key := String(parts[parts.size() - 1])
		for p in (holder as Object).get_property_list():
			if (String(p["name"]) == key or String(p["name"]) == UxmlBinding._snake(key)) and p["hint"] == PROPERTY_HINT_ENUM:
				var names := PackedStringArray()
				var values: Array = []
				var next := 0
				for item in String(p["hint_string"]).split(","):
					var kv := String(item).split(":")
					names.append(kv[0].strip_edges())
					next = int(kv[1]) if kv.size() > 1 else next
					values.append(next)
					next += 1
				var d := {}
				for k2 in names.size():
					d[names[k2]] = values[k2]
				UxmlInputParts.register_enum("__bound__", d)
				_enum = UxmlInputParts.enum_info("__bound__")
				UxmlInputParts.unregister_enum("__bound__")
				_rebuild_enum()
				return

	func on_model_changed() -> void:
		sync_text("label", "label")
		if _syncing:
			return
		if is_enum():
			_rebuild_enum()
			if el.has_attribute("value"):
				_set_enum_value(attr("value"))
			return
		var ch := UxmlInputParts.choices_of(el)
		if ch != _choices:
			_choices = ch
			if _value != null:
				_index = _choices.find(String(_value))
		var i := UxmlInputParts.dropdown_index(el)
		if el.has_attribute("index") and i != _index and i >= 0:
			choose(i, false)

	func bind_write(prop: String, v: Variant) -> int:
		match prop:
			"value":
				if is_enum():
					return 1 if _set_enum_value(v) else 0
				return 2 if _set_dropdown_value(UxmlBinding._str(v)) else 0
			"index":
				var i := int(UxmlBinding._num(v))
				if i == index():
					return 0
				if i < 0 or i >= items().size():
					_index = -1
					_value = null
					_show("")
					return 2
				choose(i, false)
				return 2
			"choices":
				if is_enum():
					return -1
				var list := PackedStringArray()
				if v is String:
					for c in (v as String).split(","):
						list.append(String(c).strip_edges())
				elif v is Array or v is PackedStringArray:
					for c in v:
						list.append(UxmlBinding._str(c))
				else:
					return -1
				_choices = list
				_syncing = true
				el.set_attribute("choices", ",".join(list))
				_syncing = false
				_index = -1 if _value == null else _choices.find(String(_value))
				return 2
			"label":
				return write_attr("label", UxmlBinding._str(v), 2)
		return UNHANDLED

	func bind_read(prop: String) -> Array:
		match prop:
			"value":
				return [true, _value]
			"index":
				return [true, index()]
		return [false, null]
