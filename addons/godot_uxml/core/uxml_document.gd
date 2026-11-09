class_name UxmlDocumentModel
extends RefCounted
## The semantic document: a parsed UXML tree plus every stylesheet it pulls in.
##
## This is the input the style resolver consumes. It deliberately holds only
## what the files said — computed styles are produced per resolve() call and
## never stored here.
##
## Sheets are flat in load order; `style_roots` records which subtree each
## entry sheet is attached to (`<Style src>` scopes to its parent element).
## A rule only applies to elements inside its sheet's scope.

var source: String = ""
## Canonical path the document was loaded from ("" for load_source callers).
var path: String = ""
var root: UxmlElement = null
## Array of {index: int, source: String, origin: String, items: Array,
##           scope: UxmlElement}.
var sheets: Array = []
## Array of {sheet: int, scope: UxmlElement}.
var style_roots: Array = []
## Array of diagnostic Dictionaries (see UxmlDiagnostic).
var warnings: Array = []
## Elements cloned from a template file -> that file's path. Relative
## references in their attributes (image, item-template) resolve against it.
## Empty for a document without templates.
var element_paths: Dictionary = {}
## Cloned element -> the TemplateContainer (the expanded <Instance>) whose
## expansion made it (see instance_of). Empty without templates.
var element_instances: Dictionary = {}
## Cloned element -> the String index of its open tag `<` in its template
## file (see source_offset_of). Empty without templates.
var template_offsets: Dictionary = {}
## Element -> Array of DataBinding descriptors read from its <Bindings>
## child (see UxmlBindings). The <Bindings> elements themselves are no
## longer in the tree. Empty for a document without bindings.
var bindings: Dictionary = {}
## Runtime v2's element table (UxmlNativeModel, phase 5), when the document
## was parsed into it (UxmlLoader.load_source with `table`) or adopted
## (adopt_objects): `root` and every other element are handles made on
## request (handle), their children when first read. Null for a model of
## runtime v1 and the GDScript path, which keep their objects.
var table: Object = null
## Row -> the handle made for it (kept for the model's life: metas and
## `changed` live on the object).
var _handles: Array = []
var _self_ref: WeakRef = null
## Called with each handle made (the runtime that owns the model sets the
## handle's `changed`).
var on_handle: Callable
static var _dbg_handles = null


## The element of row i of `table` (made now if it is not yet).
func handle(i: int) -> UxmlElement:
	if table == null or i < 0:
		return null
	if i < _handles.size():
		var h = _handles[i]
		if h != null:
			return h
	else:
		_handles.resize(table.size())
	var f: Array = table.fill(i)
	if f.is_empty():
		return null
	if _dbg_handles != null:
		var st := get_stack()
		var key := ""
		for k in range(1, mini(st.size(), 14)):
			if st[k]["function"] in ["walk", "_fill_children", "@children_getter"]: continue
			key += "%s:%d<" % [st[k]["function"], st[k]["line"]]
		_dbg_handles[key] = int(_dbg_handles.get(key, 0)) + 1
	var e := UxmlElement.new()
	e.id = f[0]
	e.prefix = f[1]
	e.local = f[2]
	e.attributes = f[3]
	e.open_tag_start = f[4]
	e.open_tag_end = f[5]
	e.source_end = f[6]
	e.part_role = f[8]
	e._ix = i
	_handles[i] = e
	if f[9] > 0:
		if _self_ref == null:
			_self_ref = weakref(self)
		e._m = _self_ref
	table.bind_handle(i, e.get_instance_id())
	var po: int = f[7]
	if po >= 0:
		e.part_of = handle(po)
	var lp: int = f[10]
	if lp >= 0:
		e.set_meta(&"uxml_logical_parent", weakref(handle(lp)))
	if on_handle.is_valid():
		on_handle.call(e)
	return e


## The row of `el` in `table`, or -1 (not a handle of this model).
func row_of(el: UxmlElement) -> int:
	if el == null or table == null:
		return -1
	var i := el._ix
	if i >= 0 and i < _handles.size() and _handles[i] == el:
		return i
	return -1


## The handle of row i if it is made, else null (nothing is made).
func made(i: int) -> UxmlElement:
	return _handles[i] if i >= 0 and i < _handles.size() else null


## Makes `el` (an object not yet in the table, a part) the handle of row i.
func adopt(i: int, el: UxmlElement) -> void:
	if i >= _handles.size():
		_handles.resize(table.size())
	_handles[i] = el
	el._ix = i
	table.bind_handle(i, el.get_instance_id())
	if on_handle.is_valid():
		on_handle.call(el)


## `el` is the handle of row i, already bound in the table (sync_entries).
func _adopt_row(i: int, el: UxmlElement) -> void:
	if i >= _handles.size():
		_handles.resize(table.size())
	_handles[i] = el
	el._ix = i
	if on_handle.is_valid():
		on_handle.call(el)


## The new rows of the handles after table.finalize() (`map`: old -> new).
func remap(map: PackedInt32Array) -> void:
	var nh: Array = []
	nh.resize(table.size())
	for old in _handles.size():
		var h = _handles[old]
		if h == null:
			continue
		var ni: int = map[old] if old < map.size() else -1
		h._ix = ni
		if ni >= 0:
			nh[ni] = h
	_handles = nh


## Every element of a model of objects into a new table, the objects its
## handles (a template expansion, a document loaded by another path).
func adopt_objects() -> void:
	if root == null:
		return
	table = ClassDB.instantiate("UxmlNativeModel")
	_handles = []
	_adopt_tree(root, -1)
	var lp_meta := &"uxml_logical_parent"
	for i in _handles.size():
		var el: UxmlElement = _handles[i]
		if el.has_meta(lp_meta):
			var lp = (el.get_meta(lp_meta) as WeakRef).get_ref()
			if lp != null:
				table.set_logical_parent(i, row_of(lp))


func _adopt_tree(el: UxmlElement, owner: int) -> int:
	var i: int = table.add_row(el.id, el.prefix, el.local, el.attributes,
		PackedInt32Array([el.open_tag_start, el.open_tag_end, el.source_end]), -1, el.part_role)
	_handles.resize(i + 1)
	_handles[i] = el
	el._ix = i
	table.bind_handle(i, el.get_instance_id())
	var kids := PackedInt32Array()
	for c in el.children:
		kids.append(_adopt_tree(c, i))
	table.set_children(i, kids)
	return i


## Leaves the table: every element is made (the objects stay the model),
## for the steps and runtimes that work on objects (runtime v1, templates).
func drop_table() -> void:
	if table == null:
		return
	if root != null:
		root.walk()
	table = null
	_handles = []


## After adopt_objects / parts: the part owners of the rows (their handles'
## part_of), set once the rows exist.
func sync_parts() -> void:
	for i in _handles.size():
		var el = _handles[i]
		if el != null and el._part_of != null:
			table.set_part(i, row_of(el.part_of), el.part_role)


## The file `element`'s attributes were authored in.
func path_of(element: UxmlElement) -> String:
	return element_paths.get(element, path)


## The String index of the `<` of `element`'s open tag in the source text
## of path_of(element): `open_tag_start` for an element of the entry file,
## the offset in the template file for a template clone. A control part
## has the offset of its control element.
func source_offset_of(element: UxmlElement) -> int:
	while element.part_of != null:
		element = element.part_of
	return template_offsets.get(element, element.open_tag_start)


## The TemplateContainer (the expanded <Instance>) whose template expansion
## made `element`, or null for an element authored in the entry file. For
## nested templates this is the innermost instance; call again on the
## result to reach the instance in the entry file. A control part answers
## for its control element.
func instance_of(element: UxmlElement) -> UxmlElement:
	if element == null:
		return null
	while element.part_of != null:
		element = element.part_of
	return element_instances.get(element)


func find_by_name(element_name: String) -> UxmlElement:
	return root.find_by_name(element_name) if root != null else null
