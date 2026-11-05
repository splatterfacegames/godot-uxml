class_name UxmlSlider
extends UxmlBox
## The control of a Slider, SliderInt or MinMaxSlider element. Its parts
## (label, drag container, tracker, dragger, ...) are child controls the
## flex layout places; this control paints the element's own box, takes
## the focus and passes pointer and key input to the behavior
## (UxmlInputBehaviors.SliderBehavior / MinMaxBehavior), which does what
## Unity's BaseSlider and ClampedDragger do.
##
## The value API follows Godot's Range for code written against the old
## HSlider mapping: `value`, `min_value`, `max_value`, `value_changed`.
## Setting `value` from code goes through the behavior, so the parts, the
## model attribute and the document signals follow.

## Emitted after the value changed (user input or code).
signal value_changed(value)

## The behavior that owns the value (set by the behavior at setup).
var behavior = null


func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	# Unity: the slider itself does not pick (PickingMode.Ignore); its drag
	# container does. Parts pass the pointer up to here.
	mouse_filter = Control.MOUSE_FILTER_PASS


var value: float:
	get:
		return 0.0 if behavior == null else float(behavior.get_value())
	set(v):
		if behavior != null:
			behavior.set_value_from_code(v)

var min_value: float:
	get:
		return 0.0 if behavior == null else float(behavior.low())
	set(v):
		if behavior != null:
			behavior.el.set_attribute(behavior.low_attr(), str(v))

var max_value: float:
	get:
		return 0.0 if behavior == null else float(behavior.high())
	set(v):
		if behavior != null:
			behavior.el.set_attribute(behavior.high_attr(), str(v))


func _gui_input(ev: InputEvent) -> void:
	if behavior != null:
		behavior.on_input(ev)
