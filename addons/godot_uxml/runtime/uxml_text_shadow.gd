class_name UxmlTextShadow
extends RefCounted
## A blurred `text-shadow` on a Label. Godot draws a sharp font shadow, so a
## shadow with a blur radius draws as a copy of the Label: the copy has the
## shadow color and offset, and draws inside a canvas group whose material
## is UxmlFilter's Gaussian blur. The group is a child canvas item of the
## Label that draws behind the Label (draw_behind_parent), so the text stays
## on top. The copy follows the Label's text, size and text layout on every
## redraw of the Label.
##
## Cost: one extra Label and one canvas group per Label with a blurred
## shadow; nothing for other Labels.

var label: Control
var copy: Label
var item: RID
var enabled := true
var _mat: ShaderMaterial
var _offset := Vector2.ZERO
var _color := Color(0, 0, 0, 0)
var _empty := StyleBoxEmpty.new()


func _init(p_label: Control) -> void:
	label = p_label
	copy = Label.new()
	copy.name = "uxml-text-shadow"
	copy.mouse_filter = Control.MOUSE_FILTER_IGNORE
	copy.focus_mode = Control.FOCUS_NONE
	copy.add_theme_stylebox_override("normal", _empty)
	copy.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0))
	copy.add_theme_constant_override("outline_size", 0)
	label.add_child(copy, false, Node.INTERNAL_MODE_FRONT)
	item = RenderingServer.canvas_item_create()
	_mat = ShaderMaterial.new()
	_mat.shader = UxmlFilter.shader()
	RenderingServer.canvas_item_set_material(item, _mat.get_rid())
	copy.tree_entered.connect(_attach)
	label.draw.connect(sync)
	_attach()


func _attach() -> void:
	if not enabled or not label.is_inside_tree():
		return
	RenderingServer.canvas_item_set_parent(item, label.get_canvas_item())
	RenderingServer.canvas_item_set_draw_behind_parent(item, true)
	RenderingServer.canvas_item_set_parent(copy.get_canvas_item(), item)


## Shadow color, offset (px) and Gaussian sigma (px).
func set_shadow(color: Color, offset: Vector2, sigma: float) -> void:
	_color = color
	_offset = offset
	var kernel := ceilf(3.0 * sigma + 1.0)
	var step := UxmlFilter.blur_step(kernel)
	_mat.set_shader_parameter("op_count", 0)
	_mat.set_shader_parameter("pre_count", 0)
	_mat.set_shader_parameter("sigma", sigma)
	_mat.set_shader_parameter("kernel", kernel)
	_mat.set_shader_parameter("tap_step", step)
	_mat.set_shader_parameter("lod", log(step) / log(2.0) if step > 1.0 else 0.0)
	RenderingServer.canvas_item_set_canvas_group_mode(
		item, RenderingServer.CANVAS_GROUP_MODE_TRANSPARENT, kernel + 2.0, true, kernel, step > 1.0)
	sync()


## Copies the Label's text and text layout to the shadow copy.
func sync() -> void:
	if not enabled or not is_instance_valid(label):
		return
	var c := copy
	if c.text != label.text:
		c.text = label.text
	c.horizontal_alignment = label.horizontal_alignment
	c.vertical_alignment = label.vertical_alignment
	c.autowrap_mode = label.autowrap_mode
	c.autowrap_trim_flags = label.autowrap_trim_flags
	c.clip_text = label.clip_text
	c.text_overrun_behavior = label.text_overrun_behavior
	c.text_direction = label.text_direction
	c.visible_characters = label.visible_characters
	var font := label.get_theme_font("font")
	if c.get_theme_font("font") != font:
		c.add_theme_font_override("font", font)
	var fs := label.get_theme_font_size("font_size")
	if c.get_theme_font_size("font_size") != fs:
		c.add_theme_font_size_override("font_size", fs)
	var ls := label.get_theme_constant("line_spacing")
	if c.get_theme_constant("line_spacing") != ls:
		c.add_theme_constant_override("line_spacing", ls)
	if c.get_theme_color("font_color") != _color:
		c.add_theme_color_override("font_color", _color)
	var sb := label.get_theme_stylebox("normal")
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		var m := 0.0 if sb == null else sb.get_content_margin(side)
		if _empty.get_content_margin(side) != m:
			_empty.set_content_margin(side, m)
	if label.label_settings != null:
		var s: LabelSettings = label.label_settings
		var cs: LabelSettings = c.label_settings
		if cs == null or cs.font != s.font or cs.font_size != s.font_size \
				or cs.line_spacing != s.line_spacing or cs.paragraph_spacing != s.paragraph_spacing \
				or cs.font_color != _color:
			cs = LabelSettings.new()
			cs.font = s.font
			cs.font_size = s.font_size
			cs.line_spacing = s.line_spacing
			cs.paragraph_spacing = s.paragraph_spacing
			cs.font_color = _color
			c.label_settings = cs
	elif c.label_settings != null:
		c.label_settings = null
	if c.position != _offset:
		c.position = _offset
	if c.size != label.size:
		c.size = label.size


func set_enabled(on: bool) -> void:
	if on == enabled:
		return
	enabled = on
	copy.visible = on
	if on:
		_attach()
		sync()


## Removes the copy and frees the group item.
func detach() -> void:
	if is_instance_valid(label):
		if label.draw.is_connected(sync):
			label.draw.disconnect(sync)
	if is_instance_valid(copy):
		copy.queue_free()
		if copy.get_parent() != null:
			copy.get_parent().remove_child(copy)
	if item.is_valid():
		RenderingServer.free_rid(item)
		item = RID()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and item.is_valid():
		RenderingServer.free_rid(item)
