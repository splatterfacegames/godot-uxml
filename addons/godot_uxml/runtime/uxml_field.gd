class_name UxmlField
extends UxmlBox
## The labeled-field wrapper: a caption Label on the left and the native
## field control filling the rest — the shape Unity's BaseField<T> has.
##
## Slider, SliderInt, TextField and DropdownField elements map to one of
## these. `get_element(name)` on the document returns this wrapper (the
## element's box); the interactive control is `field` — reach it through
## `UxmlDocument.get_native(name)` or `field_node()`.
##
## Deliberately not a Container: the flex layout positions every UXML child
## explicitly and a Container would also arrange (and fight over) any UXML
## children the element happens to have. The two internal parts are
## positioned manually in _relayout() — USS on the field element controls
## the whole wrapper's box; the label/field split is fixed chrome.

const SEPARATION := 4.0

var caption: Label = null
var field: Control = null

## The element's own padding+border insets, resolved by the flex layout
## (px AND % already collapsed). The internal caption/field chrome lives
## inside the authored content box — it must not start at the wrapper's
## border-box origin and paint over the element's padding.
var inset_start := Vector2.ZERO
var inset_end := Vector2.ZERO


## Called by the document after each layout pass with the element's
## resolved content insets.
func set_content_insets(start: Vector2, end: Vector2) -> void:
	if inset_start == start and inset_end == end:
		return
	inset_start = start
	inset_end = end
	_relayout()


func _init(p_field: Control = null, p_caption_text: String = "") -> void:
	if p_field != null:
		_setup(p_field, p_caption_text)


func _setup(p_field: Control, caption_text: String) -> void:
	field = p_field
	caption = Label.new()
	caption.text = caption_text
	caption.visible = not caption_text.is_empty()
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(caption)
	add_child(field)
	_update_min_size()
	_relayout()


## The interactive control inside the wrapper (HSlider, LineEdit, TextEdit,
## OptionButton).
func field_node() -> Control:
	return field


func caption_node() -> Label:
	return caption


## USS font/color applied to the wrapper also reaches the caption so it does
## not keep the theme default while the field is styled. Overrides are
## removed again when the corresponding property leaves the computed style,
## so leaving a state restores the caption's theme defaults exactly.
func apply_caption_style(font: Font, font_size: int, color: Color, has_color: bool) -> void:
	var bulk := UxmlStyleApplier.BULK_THEME_OVERRIDES
	if bulk:
		caption.begin_bulk_theme_override()  # one theme notification, not three
	if font != null:
		caption.add_theme_font_override("font", font)
	elif caption.has_theme_font_override("font"):
		caption.remove_theme_font_override("font")
	if font_size > 0:
		caption.add_theme_font_size_override("font_size", font_size)
	elif caption.has_theme_font_size_override("font_size"):
		caption.remove_theme_font_size_override("font_size")
	if has_color:
		caption.add_theme_color_override("font_color", color)
	elif caption.has_theme_color_override("font_color"):
		caption.remove_theme_color_override("font_color")
	if bulk:
		caption.end_bulk_theme_override()
	_update_min_size()
	_relayout()


func _update_min_size() -> void:
	var m := Vector2.ZERO
	if caption != null and caption.visible:
		m = caption.get_combined_minimum_size()
		m.x += SEPARATION
	if field != null:
		var f := field.get_combined_minimum_size()
		m.x += f.x
		m.y = maxf(m.y, f.y)
	# Intrinsic measure only — kept out of custom_minimum_size so the
	# authored/shrunken box size is never floored by the chrome inside.
	natural_size = m


func _relayout() -> void:
	if caption == null or field == null:
		return
	# The internal chrome lives inside the content box: inset_start is the
	# padding+border top-left, and the far edges end inset_end short of the
	# wrapper's border box.
	var content := Rect2(
		inset_start,
		Vector2(
			maxf(0.0, size.x - inset_start.x - inset_end.x),
			maxf(0.0, size.y - inset_start.y - inset_end.y)
		)
	)
	var x := 0.0
	if caption.visible:
		var w := caption.get_combined_minimum_size().x + SEPARATION
		caption.position = content.position
		caption.size = Vector2(w - SEPARATION, content.size.y)
		x = w
	field.position = content.position + Vector2(x, 0)
	field.size = Vector2(maxf(0.0, content.size.x - x), content.size.y)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_relayout()
