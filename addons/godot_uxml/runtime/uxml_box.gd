class_name UxmlBox
extends Control
## The plain-element box: what a UXML VisualElement (or an unmapped tag)
## becomes on screen.
##
## A VisualElement has no behavior — Unity paints it as a styled rectangle —
## so this is a real Control that draws the background/border/radius the USS
## cascade computed, and nothing else. It is NOT a Container: the flex
## layout positions every child explicitly, and a Container would fight it.
##
## UxmlBox is also the host for wrapped natives: Image puts a full-rect
## TextureRect inside one (so `background-color` behind an image works), and
## ScrollView puts its ScrollContainer inside one.

## Intrinsic content size used by the flex measure (Image: texture size;
## UxmlField: caption + field chrome). Kept OUT of custom_minimum_size on
## purpose: Control.size clamps to the combined minimum, which would floor
## the laid-out box — Yoga semantics let authored dims and shrink go below
## the intrinsic size instead.
var natural_size := Vector2.ZERO


## The stylebox drawn behind the element, or null for no background.
var box_style: StyleBox = null:
	set(v):
		box_style = v
		queue_redraw()

## Optional texture painted across the whole rect (USS background-image on a
## container). Element images use a TextureRect child instead.
var box_texture: Texture2D = null:
	set(v):
		box_texture = v
		queue_redraw()

## 9-sliced and/or tinted background image (USS -unity-slice-* /
## -unity-background-image-tint-color). Drawn instead of box_texture.
var box_texture_style: StyleBox = null:
	set(v):
		box_texture_style = v
		queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	if box_style != null:
		draw_style_box(box_style, rect)
	if box_texture_style != null:
		draw_style_box(box_texture_style, rect)
	elif box_texture != null:
		draw_texture_rect(box_texture, rect, false)
