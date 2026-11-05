class_name UxmlRepeatButton
extends Button
## A Unity RepeatButton: `pressed` fires when the button goes down, then —
## while it stays held — again after `delay` ms and every `interval` ms, as
## Unity's repeating Clickable does. With both at 0 it fires once per press.
## Keyboard and controller activation (`ui_accept`) fire once.

var delay_ms := 0.0
var interval_ms := 0.0
var _timer: Timer = null
var _held := false


func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	button_down.connect(_on_down)
	button_up.connect(_stop)


## Unity's Clickable fires a repeating button on press and a plain one on
## release.
func configure(p_delay_ms: float, p_interval_ms: float) -> void:
	delay_ms = maxf(0.0, p_delay_ms)
	interval_ms = maxf(0.0, p_interval_ms)
	action_mode = (BaseButton.ACTION_MODE_BUTTON_PRESS if delay_ms > 0.0 or interval_ms > 0.0
		else BaseButton.ACTION_MODE_BUTTON_RELEASE)


func _on_down() -> void:
	if delay_ms <= 0.0 and interval_ms <= 0.0:
		return
	if _timer == null:
		_timer = Timer.new()
		_timer.one_shot = true
		_timer.timeout.connect(_on_timer)
		add_child(_timer, false, Node.INTERNAL_MODE_BACK)
	_held = true
	var first := delay_ms if delay_ms > 0.0 else interval_ms
	_timer.start(maxf(first, 1.0) / 1000.0)


func _on_timer() -> void:
	if disabled or not _held:
		return
	pressed.emit()
	if interval_ms > 0.0:
		_timer.start(maxf(interval_ms, 1.0) / 1000.0)


func _stop() -> void:
	_held = false
	if _timer != null:
		_timer.stop()
