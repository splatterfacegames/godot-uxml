class_name UxmlPopupMenu
extends Popup
## The menu of a DropdownField or EnumField: Unity's GenericDropdownMenu
## look in a Godot Popup.
##
## The menu is a UXML document of its own, styled by the default theme with
## Unity's dropdown classes (measured: ctl-dropdown-open,
## ctl-dropdown-menu-hover):
##
##   .unity-base-dropdown__container-outer (width of the field input)
##     > ScrollView.unity-base-dropdown__container-inner (VerticalAndHorizontal)
##       > (ScrollView parts) > content container
##         > .unity-base-dropdown__item (:checked on the selected item)
##           > .unity-base-dropdown__item-content
##             > .unity-base-dropdown__checkmark, Label.unity-base-dropdown__label
##
## Unity attaches the menu to the root of the document, so the author
## sheets of the field's document style the menu too
## (UxmlDocument.shared_sheets). Unity's GenericDropdownMenu limits the
## outer container to the space below the field (or above it, when that
## space is larger): a long menu gets `max-height` and its ScrollView
## scrolls (wheel, Scroller, and the highlight scrolls into view).
##
## Input: a click on an item chooses it; `ui_up`/`ui_down` move the
## highlight (`:hover`), `ui_accept` chooses the highlighted item,
## `ui_cancel` or a click outside closes the menu.

## Emitted with the chosen item index; the menu closes after it.
signal chosen(index: int)

var _doc: UxmlDocument = null
var _count := 0
var _highlight := -1


## Open a menu below `anchor` (the field input control) with `items`;
## `selected` is checked and highlighted.
## `owner` is the model of the field's document: its author sheets style
## the menu.
static func open(anchor: Control, items: PackedStringArray, selected: int, theme_path: String,
		owner: UxmlDocumentModel = null) -> UxmlPopupMenu:
	var m := UxmlPopupMenu.new()
	m.transparent_bg = true
	m.borderless = true
	m.wrap_controls = false
	anchor.add_child(m)
	m._build(anchor, items, selected, theme_path, owner)
	return m


## The menu UXML: Unity's GenericDropdownMenu tree for `items`.
static func menu_uxml(items: PackedStringArray, width: float) -> String:
	var body := PackedStringArray()
	for i in items.size():
		body.append(('<ui:VisualElement name="item-%d" class="unity-base-dropdown__item">'
			+ '<ui:VisualElement class="unity-base-dropdown__item-content" picking-mode="Ignore">'
			+ '<ui:VisualElement class="unity-base-dropdown__checkmark" picking-mode="Ignore" />'
			+ '<ui:Label class="unity-base-dropdown__label" picking-mode="Ignore" text="%s" />'
			+ '</ui:VisualElement></ui:VisualElement>') % [i, _xml(items[i])])
	return ('<ui:UXML xmlns:ui="UnityEngine.UIElements"><ui:VisualElement name="menu" class="unity-base-dropdown">'
		+ '<ui:VisualElement name="outer" class="unity-base-dropdown__container-outer" style="width: %spx;">'
		+ '<ui:ScrollView name="inner" class="unity-base-dropdown__container-inner" mode="VerticalAndHorizontal">%s</ui:ScrollView>'
		+ '</ui:VisualElement></ui:VisualElement></ui:UXML>') % [width, "".join(body)]


func _build(anchor: Control, items: PackedStringArray, selected: int, theme_path: String,
		owner: UxmlDocumentModel = null) -> void:
	_count = items.size()
	var width := maxf(anchor.size.x, 20.0)
	_doc = UxmlDocument.new()
	_doc.auto_load = false
	_doc.theme_path = theme_path
	_doc.shared_sheets = owner
	_doc.size = Vector2(width + 8.0, 4000.0)
	add_child(_doc)
	_doc.load_source(menu_uxml(items, width))
	_doc._restyle_now()
	for i in _count:
		var c := _doc.get_element("item-%d" % i)
		if c != null:
			c.gui_input.connect(_on_item_input.bind(i))
			c.mouse_entered.connect(_set_highlight.bind(i, false))
	if selected >= 0 and selected < _count:
		_doc.set_element_state("item-%d" % selected, "checked", true)
	var outer := _doc.get_element("outer")
	var h := 0.0 if outer == null else outer.position.y + outer.size.y
	var vp := anchor.get_viewport()
	var top_left: Vector2
	var bounds := Rect2()
	if vp.gui_embed_subwindows:
		# Embedded: viewport coordinates, kept inside the visible rect; the
		# menu opens above the field when it does not fit below (Unity's
		# EnsureVisibilityInParent).
		var xf := anchor.get_global_transform_with_canvas()
		top_left = xf.origin
		bounds = vp.get_visible_rect()
	else:
		top_left = anchor.get_screen_position()
		bounds = Rect2(DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen()))
	var below := top_left + Vector2(0.0, anchor.size.y)
	var pos := below
	var above := false
	if bounds.size != Vector2.ZERO:
		# Unity's EnsureVisibilityInParent: a menu taller than the space
		# below opens above when that space is larger; the outer container
		# gets the space as max-height and the ScrollView scrolls.
		var space_below := bounds.end.y - below.y
		var space_above := top_left.y - bounds.position.y
		if h > space_below:
			above = space_above > space_below
			var room := maxf(space_above if above else space_below, 0.0)
			if h > room and outer != null:
				var oel := _doc.get_element_model("outer")
				var st := "width: %spx; max-height: %spx;" % [width, maxf(room - outer.position.y - 2.0, 20.0)]
				oel.set_attribute("style", st)
				_doc._restyle_now()
				h = outer.position.y + outer.size.y
	size = Vector2i(ceili(width + 2.0), ceili(h + 2.0))
	_doc.size = Vector2(size)
	if bounds.size != Vector2.ZERO:
		if above:
			pos.y = top_left.y - size.y
		pos.x = clampf(pos.x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - size.x))
		pos.y = clampf(pos.y, bounds.position.y, maxf(bounds.position.y, bounds.end.y - size.y))
	window_input.connect(_on_window_input)
	popup_hide.connect(_on_hide)
	popup(Rect2i(Vector2i(pos), size))
	_set_highlight(selected, true)


static func _xml(s: String) -> String:
	return s.xml_escape(true)


func _set_highlight(i: int, keyboard: bool) -> void:
	if _doc == null:
		return
	if _highlight >= 0 and _highlight != i:
		_doc.set_element_state("item-%d" % _highlight, "hover", false)
	_highlight = i
	if keyboard and i >= 0 and i < _count:
		_doc.set_element_state("item-%d" % i, "hover", true)
		_doc.scroll_to("inner", "item-%d" % i)


func _on_item_input(ev: InputEvent, i: int) -> void:
	var mb := ev as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
		_choose(i)


func _on_window_input(ev: InputEvent) -> void:
	if ev.is_action_pressed("ui_down", true):
		_set_highlight(clampi(_highlight + 1, 0, _count - 1), true)
	elif ev.is_action_pressed("ui_up", true):
		_set_highlight(clampi(_highlight - 1, 0, _count - 1), true)
	elif ev.is_action_pressed("ui_accept") and not ev.is_echo():
		if _highlight >= 0:
			_choose(_highlight)
	elif ev.is_action_pressed("ui_cancel"):
		hide()
	else:
		return
	set_input_as_handled()


func _choose(i: int) -> void:
	chosen.emit(i)
	hide()


func _on_hide() -> void:
	queue_free()


## The menu document (for tests and custom styling).
func document() -> UxmlDocument:
	return _doc
