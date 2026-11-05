class_name UxmlPopupField
extends UxmlBox
## The control of a DropdownField or EnumField element: it paints the
## element's box, takes the focus and opens the menu on a left press or on
## `ui_accept` (Enter, Space, Joypad A), as Unity's BasePopupField does.
## The behavior (UxmlInputBehaviors.PopupBehavior) owns the choices and
## the selection.
##
## For code written against the old OptionButton mapping: `selected`,
## `item_count`, `get_item_text()`, `select()` and `item_selected(index)`.

signal item_selected(index: int)

var behavior = null


func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP


var selected: int:
	get:
		return -1 if behavior == null else int(behavior.index())

var item_count: int:
	get:
		return 0 if behavior == null else behavior.items().size()


func get_item_text(i: int) -> String:
	var items: PackedStringArray = PackedStringArray() if behavior == null else behavior.items()
	return items[i] if i >= 0 and i < items.size() else ""


## Select item `i` from code (no menu; emits item_selected like a user
## choice).
func select(i: int) -> void:
	if behavior != null:
		behavior.choose(i, true)


func _gui_input(ev: InputEvent) -> void:
	if behavior != null:
		behavior.on_input(ev)
