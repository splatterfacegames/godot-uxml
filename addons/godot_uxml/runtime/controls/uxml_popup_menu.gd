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
##
## A context menu (open_at, UxmlDocument.show_context_menu) is the same
## tree at a point, as wide as its widest item (Unity's GenericDropdownMenu
## shown with `anchored: false`), with Unity's separators
## (`.unity-base-dropdown__separator-container` >
## `.unity-base-dropdown__separator-line`) and disabled items
## (SetEnabled(false): `:disabled` and `.unity-disabled`). Its document has
## the theme of the owner document: the runtime theme, or the editor theme
## in the owner's skin.

## Emitted with the chosen item index; the menu closes after it.
signal chosen(index: int)

var _doc: UxmlDocument = null
var _count := 0
var _highlight := -1
## The item indices that can be highlighted and chosen, top to bottom.
var _ids := PackedInt32Array()


## Open a menu below `anchor` (the field input control) with `items`;
## `selected` is checked and highlighted.
## `owner` is the field's document: its author sheets style the menu, and
## url()s in them resolve against its project root.
static func open(anchor: Control, items: PackedStringArray, selected: int, theme_path: String,
		owner: UxmlDocument = null) -> UxmlPopupMenu:
	var m := UxmlPopupMenu.new()
	m.transparent_bg = true
	m.borderless = true
	m.wrap_controls = false
	anchor.add_child(m)
	m._build(anchor, items, selected, theme_path, owner)
	return m


## A context menu of `owner` with its top-left corner at `global_point`
## (global coordinates of `owner`'s canvas), kept inside the visible rect.
## `entries`: menu_entries() of the caller's items; `chosen` gives the
## index into the caller's items.
static func open_at(owner: UxmlDocument, global_point: Vector2, entries: Array) -> UxmlPopupMenu:
	var m := UxmlPopupMenu.new()
	m.transparent_bg = true
	m.borderless = true
	m.wrap_controls = false
	owner.add_child(m, false, Node.INTERNAL_MODE_BACK)
	m._build_at(owner, global_point, entries)
	return m


## Normalised context menu entries of `items` (Unity DropdownMenu): a
## String is an item ("-" is a separator); a Dictionary has `text` and
## optionally `checked` (DropdownMenuAction.Status.Checked), `disabled`
## (Status.Disabled), `hidden` (Status.Hidden: not shown, its index stays)
## and `separator`. Returns [{index, text, checked, disabled, separator}]
## for the shown entries; `index` is the index in `items`.
static func menu_entries(items) -> Array:
	var out: Array = []
	var i := -1
	for it in items:
		i += 1
		var e := {"index": i, "text": "", "checked": false, "disabled": false, "separator": false}
		if it is Dictionary:
			if bool(it.get("hidden", false)):
				continue
			e["text"] = String(it.get("text", ""))
			e["checked"] = bool(it.get("checked", false))
			e["disabled"] = bool(it.get("disabled", false))
			e["separator"] = bool(it.get("separator", false)) or e["text"] == "-"
		else:
			e["text"] = String(it)
			e["separator"] = e["text"] == "-"
		out.append(e)
	return out


## The context menu UXML: the GenericDropdownMenu tree of `entries`, the
## outer container as wide as its content.
static func context_uxml(entries: Array) -> String:
	var body := PackedStringArray()
	for e in entries:
		if e["separator"]:
			body.append('<ui:VisualElement class="unity-base-dropdown__separator-container" picking-mode="Ignore">'
				+ '<ui:VisualElement class="unity-base-dropdown__separator-line" picking-mode="Ignore" /></ui:VisualElement>')
			continue
		body.append(('<ui:VisualElement name="item-%d" class="unity-base-dropdown__item"%s>'
			+ '<ui:VisualElement class="unity-base-dropdown__item-content" picking-mode="Ignore">'
			+ '<ui:VisualElement class="unity-base-dropdown__checkmark" picking-mode="Ignore" />'
			+ '<ui:Label class="unity-base-dropdown__label" picking-mode="Ignore" text="%s" />'
			+ '</ui:VisualElement></ui:VisualElement>') % [int(e["index"]),
				' enabled="false"' if e["disabled"] else "", _xml(String(e["text"]))])
	return ('<ui:UXML xmlns:ui="UnityEngine.UIElements"><ui:VisualElement name="menu" class="unity-base-dropdown">'
		+ '<ui:VisualElement name="outer" class="unity-base-dropdown__container-outer" style="%s">'
		+ '<ui:ScrollView name="inner" class="unity-base-dropdown__container-inner" mode="VerticalAndHorizontal">%s</ui:ScrollView>'
		+ '</ui:VisualElement></ui:VisualElement></ui:UXML>') % [CONTEXT_OUTER, "".join(body)]


## The outer container of a context menu: as wide as its content, at the
## point (no gap below a field).
const CONTEXT_OUTER := "align-self: flex-start; margin-top: 0;"


func _build_at(owner: UxmlDocument, global_point: Vector2, entries: Array) -> void:
	_doc = UxmlDocument.new()
	_doc.auto_load = false
	_doc.theme_path = owner.theme_path
	var skin := UxmlTheme.editor_skin_of(owner._doc)
	_doc.editor_theme = "always" if not skin.is_empty() else "never"
	_doc.editor_skin = skin if not skin.is_empty() else "dark"
	if owner._doc != null:
		_doc.shared_sheets = owner._doc
		_doc.project_root = owner._effective_root
	_doc.size = Vector2(4000.0, 4000.0)
	add_child(_doc)
	_doc.load_source(context_uxml(entries))
	for e in entries:
		if e["separator"]:
			continue
		var i: int = e["index"]
		_count = maxi(_count, i + 1)
		var c := _doc.get_element("item-%d" % i)
		if c == null:
			continue
		if e["checked"]:
			_doc.set_element_state("item-%d" % i, "checked", true)
		if not e["disabled"]:
			_ids.append(i)
			c.gui_input.connect(_on_item_input.bind(i))
			c.mouse_entered.connect(_set_highlight.bind(i, false))
	_doc._restyle_now()
	var outer := _doc.get_element("outer")
	var w := 20.0 if outer == null else outer.position.x + outer.size.x
	var h := 0.0 if outer == null else outer.position.y + outer.size.y
	var vp := owner.get_viewport()
	var top_left: Vector2
	var bounds := Rect2()
	var local := owner.get_global_transform().affine_inverse() * global_point
	if vp.gui_embed_subwindows:
		top_left = owner.get_global_transform_with_canvas() * local
		bounds = vp.get_visible_rect()
	else:
		top_left = owner.get_screen_transform() * local
		bounds = Rect2(DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen()))
	if bounds.size != Vector2.ZERO and h > bounds.size.y and outer != null:
		# Taller than the visible rect: the outer container gets the room
		# as max-height and the ScrollView scrolls (Unity's
		# EnsureVisibilityInParent).
		_doc.get_element_model("outer").set_attribute("style",
			CONTEXT_OUTER + " max-height: %spx;" % maxf(bounds.size.y - outer.position.y - 2.0, 20.0))
		_doc._restyle_now()
		h = outer.position.y + outer.size.y
	size = Vector2i(ceili(w + 2.0), ceili(h + 2.0))
	_doc.size = Vector2(size)
	var pos := top_left
	if bounds.size != Vector2.ZERO:
		# Unity's EnsureVisibilityInParent: the menu moves left and up to
		# stay inside.
		pos.x = clampf(pos.x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - size.x))
		pos.y = clampf(pos.y, bounds.position.y, maxf(bounds.position.y, bounds.end.y - size.y))
	window_input.connect(_on_window_input)
	popup_hide.connect(_on_hide)
	popup(Rect2i(Vector2i(pos), size))


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
		owner: UxmlDocument = null) -> void:
	_count = items.size()
	_ids = PackedInt32Array(range(_count))
	var width := maxf(anchor.size.x, 20.0)
	_doc = UxmlDocument.new()
	_doc.auto_load = false
	_doc.theme_path = theme_path
	if owner != null:
		_doc.shared_sheets = owner._doc
		_doc.project_root = owner._effective_root
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
		_step(1)
	elif ev.is_action_pressed("ui_up", true):
		_step(-1)
	elif ev.is_action_pressed("ui_accept") and not ev.is_echo():
		if _highlight >= 0:
			_choose(_highlight)
	elif ev.is_action_pressed("ui_cancel"):
		hide()
	else:
		return
	set_input_as_handled()


## Move the highlight to the next (`d` 1) or the previous (-1) item that
## can be chosen (separators and disabled items are skipped); without a
## highlight, to the first.
func _step(d: int) -> void:
	if _ids.is_empty():
		return
	var at := _ids.find(_highlight)
	at = 0 if at < 0 else clampi(at + d, 0, _ids.size() - 1)
	_set_highlight(_ids[at], true)


func _choose(i: int) -> void:
	chosen.emit(i)
	hide()


func _on_hide() -> void:
	queue_free()


## The menu document (for tests and custom styling).
func document() -> UxmlDocument:
	return _doc
