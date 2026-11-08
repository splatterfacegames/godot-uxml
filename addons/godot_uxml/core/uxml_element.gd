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
## Observable mutation (Slint-style reactive model): set_attribute() /
## remove_attribute() notify `changed` with this element, so a runtime that
## owns the tree restyles exactly the elements that changed instead of
## re-reading every attribute on every pass. Editing `attributes` directly
## still works for code that reads the model, but a running UxmlDocument
## only sees such edits after refresh().
var changed: Callable
## While `changed` runs: the name of the attribute that set_attribute or
## remove_attribute changed ("" otherwise).
var changed_attribute := ""
## Half-open span of the open tag in the UXML source, for diagnostics.
var open_tag_start: int = 0
var open_tag_end: int = 0
## End of the whole element (past the close tag, or past `/>`).
var source_end: int = 0
## Control parts (see UxmlControls): a part element is one Unity builds
## inside a control (a Toggle's label, input and checkmark, a Foldout's
## content, ...). `part_of` is the control element that owns the part,
## null for authored elements; `part_role` names the part's job inside the
## control ("label", "input", "checkmark", ...). Parts are ordinary
## elements for the cascade and layout, but they never enter the
## document's name index.
## (Held weakly: the owner holds its parts as children, so a strong
## back-reference would be a reference cycle.)
var part_of: UxmlElement:
	get:
		return null if _part_of == null else _part_of.get_ref()
	set(v):
		_part_of = null if v == null else weakref(v)
var part_role: String = ""
var _part_of: WeakRef = null


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


## Set the first attribute named `attr_name` (appended when absent) and
## notify `changed` if the value actually changed.
func set_attribute(attr_name: String, value: String) -> void:
	for attr in attributes:
		if attr["name"] == attr_name:
			if attr["value"] == value:
				return
			attr["value"] = value
			if changed.is_valid():
				changed_attribute = attr_name
				changed.call(self)
				changed_attribute = ""
			return
	attributes.append({"name": attr_name, "value": value, "offset": 0})
	if changed.is_valid():
		changed_attribute = attr_name
		changed.call(self)
		changed_attribute = ""


## Remove every attribute named `attr_name`; notifies `changed` if any was
## present.
func remove_attribute(attr_name: String) -> void:
	var kept: Array = []
	for attr in attributes:
		if attr["name"] != attr_name:
			kept.append(attr)
	if kept.size() == attributes.size():
		return
	attributes = kept
	if changed.is_valid():
		changed_attribute = attr_name
		changed.call(self)
		changed_attribute = ""


## The `class` attribute split on whitespace. Order preserved.
func class_list() -> Array:
	var raw = get_attribute("class")
	if raw == null:
		return []
	var text := String(raw)
	if text.contains("\t") or text.contains("\n") or text.contains("\r"):
		text = text.replace("\t", " ").replace("\n", " ").replace("\r", " ")
	return Array(text.split(" ", false))


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
