class_name UxmlClip
extends RefCounted
## Clips a control's children to a rectangle inside its own box: the USS
## padding box or content box (-unity-overflow-clip-box) of an element with
## overflow: hidden.
##
## Control.clip_contents clips at the border box, and it also clips the
## control's own drawing, so the border would be lost if the control's clip
## rect were simply made smaller. Instead the children's canvas items are
## parented (at the RenderingServer level) to one extra clipping canvas
## item whose rect is the inset box. The control's own background and
## border still draw on its own canvas item, unclipped by the inset.
##
## Godot re-parents a child's canvas item when the child enters the tree,
## so the clip follows child_entered_tree; resized updates the rect.

var host: Control
var item: RID
## Inset from the border box: left, top, right, bottom.
var inset := Vector4.ZERO


func _init(p_host: Control) -> void:
	host = p_host
	item = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(item, host.get_canvas_item())
	RenderingServer.canvas_item_set_clip(item, true)
	host.child_entered_tree.connect(_on_child)
	host.resized.connect(_update_rect)
	for ch in host.get_children():
		_on_child(ch)
	_update_rect()


func set_inset(v: Vector4) -> void:
	if v == inset:
		return
	inset = v
	_update_rect()


func _update_rect() -> void:
	var r := Rect2(
		Vector2(inset.x, inset.y),
		Vector2(
			maxf(0.0, host.size.x - inset.x - inset.z),
			maxf(0.0, host.size.y - inset.y - inset.w)))
	RenderingServer.canvas_item_set_custom_rect(item, true, r)


func _on_child(ch: Node) -> void:
	var ci := ch as CanvasItem
	if ci != null and not ci.top_level:
		RenderingServer.canvas_item_set_parent(_item_of(ci), item)


## The canvas item that hangs from the host for child `ci`: the canvas group
## item of a filtered child (UxmlFilter), else the child's own item.
static func _item_of(ci: CanvasItem) -> RID:
	if ci.has_meta(&"uxml_filter"):
		var f = ci.get_meta(&"uxml_filter")
		if f != null and f.group_item().is_valid():
			return f.group_item()
	return ci.get_canvas_item()


## Puts the children back under the host's own canvas item and frees the
## clip item.
func detach() -> void:
	if not item.is_valid():
		return
	if is_instance_valid(host):
		if host.child_entered_tree.is_connected(_on_child):
			host.child_entered_tree.disconnect(_on_child)
		if host.resized.is_connected(_update_rect):
			host.resized.disconnect(_update_rect)
		for ch in host.get_children():
			var ci := ch as CanvasItem
			if ci != null and not ci.top_level and ci.is_inside_tree():
				RenderingServer.canvas_item_set_parent(_item_of(ci), host.get_canvas_item())
	RenderingServer.free_rid(item)
	item = RID()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and item.is_valid():
		RenderingServer.free_rid(item)
