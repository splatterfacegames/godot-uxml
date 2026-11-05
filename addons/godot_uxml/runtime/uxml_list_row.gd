class_name UxmlListRow
extends RefCounted
## One pooled row of a virtualized ListView, handed to the game's bind
## callback: `bind.call(row, index)` fills it for item `index`.
##
##   doc.set_list_source("inventory", items.size(), func(row: UxmlListRow, i: int):
##       row.get_native("title").text = items[i].name
##       row.set_class("title", "title" + (" rare" if items[i].rare else "")))
##
## Rows are recycled: the same row is re-bound to different indices while
## scrolling, so bind must set every value it depends on.

## The item index currently bound (-1 when the slot is unused).
var index := -1
## The row's root element (a pooled copy of the item template).
var element: UxmlElement = null
var _doc: UxmlDocument = null
var _by_name := {}


func _init(doc: UxmlDocument, root: UxmlElement) -> void:
	_doc = doc
	element = root
	for el in root.walk():
		var n = el.get_attribute("name")
		if n != null and not _by_name.has(String(n)):
			_by_name[String(n)] = el


## The named element's outer control inside this row (or the row's own
## box for an empty name).
func get_element(element_name: String = "") -> Control:
	var el: UxmlElement = element if element_name.is_empty() else _by_name.get(element_name)
	return null if el == null else _doc._controls.get(el)


## The named element's interactive native control inside this row.
func get_native(element_name: String) -> Control:
	var el: UxmlElement = _by_name.get(element_name)
	return null if el == null else _doc._natives.get(el)


## The named element model inside this row.
func get_element_model(element_name: String) -> UxmlElement:
	return _by_name.get(element_name)


## Replace a row element's classes (restyles just that element).
func set_class(element_name: String, class_string: String) -> void:
	var el: UxmlElement = element if element_name.is_empty() else _by_name.get(element_name)
	if el != null:
		el.set_attribute("class", class_string)
