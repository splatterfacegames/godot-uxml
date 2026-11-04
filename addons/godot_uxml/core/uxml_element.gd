class_name UxmlElement
extends RefCounted
## One element in a parsed UXML tree.
##
## The parser produces these; the model holds only what the file said. Style
## resolution, layout and control instantiation all read this tree without
## mutating it.
##
## `attributes` is an Array of Dictionaries `{name, value, offset}` in source
## order. Values are XML-entity decoded by the parser (the addon does not
## re-serialize UXML, so decoded values are what every consumer wants).
## `offset` is the character offset of the attribute name in the UXML source
## (Godot `String` indices are character offsets, not byte offsets).

var id: int = -1
var prefix: String = ""
var local: String = ""
var attributes: Array = []
var children: Array = []
## Half-open span of the open tag in the UXML source, for diagnostics.
var open_tag_start: int = 0
var open_tag_end: int = 0
## End of the whole element (past the close tag, or past `/>`).
var source_end: int = 0


## Qualified tag exactly as written, e.g. `ui:Button`.
func tag() -> String:
	return local if prefix.is_empty() else prefix + ":" + local


## First attribute value named `attr_name`, or null when absent.
func get_attribute(attr_name: String) -> Variant:
	for attr in attributes:
		if attr["name"] == attr_name:
			return attr["value"]
	return null


func has_attribute(attr_name: String) -> bool:
	return get_attribute(attr_name) != null


## The `class` attribute split on whitespace. Order preserved.
func class_list() -> Array:
	var raw = get_attribute("class")
	if raw == null:
		return []
	var out := []
	var current := ""
	var text := String(raw)
	for i in text.length():
		var c := text.unicode_at(i)
		if c == 32 or c == 9 or c == 10 or c == 13:
			if not current.is_empty():
				out.append(current)
				current = ""
		else:
			current += text.substr(i, 1)
	if not current.is_empty():
		out.append(current)
	return out


## Depth-first search for the first element whose `name` attribute matches.
func find_by_name(element_name: String) -> UxmlElement:
	if get_attribute("name") == element_name:
		return self
	for child in children:
		var found: UxmlElement = child.find_by_name(element_name)
		if found != null:
			return found
	return null


## Depth-first enumeration of this element and all descendants.
func walk(out: Array = []) -> Array:
	out.append(self)
	for child in children:
		child.walk(out)
	return out
