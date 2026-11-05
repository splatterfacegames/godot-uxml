class_name UxmlImguiBox
extends UxmlBox
## The control of an IMGUIContainer. Unity runs C# IMGUI code
## (onGUIHandler) in the element; Godot cannot run that code, so the
## element hosts a Godot callback instead (UxmlDocument.set_imgui_handler):
##
##   draw.call(box: UxmlImguiBox, rect: Rect2)   in _draw, after the USS
##       background; draw with box.draw_* inside `rect` (the content box)
##   input.call(box: UxmlImguiBox, event: InputEvent)   from gui_input
##
## Unity's IMGUIContainer is focusable, so this box takes the focus too.

var on_draw: Callable
var on_input: Callable
## Content box inside the padding and border (set after each layout).
var content_rect := Rect2()


func _init() -> void:
	focus_mode = Control.FOCUS_ALL


func _draw() -> void:
	super._draw()
	if on_draw.is_valid():
		on_draw.call(self, content_rect if content_rect.size != Vector2.ZERO else Rect2(Vector2.ZERO, size))


func _gui_input(event: InputEvent) -> void:
	if on_input.is_valid():
		on_input.call(self, event)
