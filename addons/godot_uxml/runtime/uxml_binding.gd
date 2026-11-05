class_name UxmlBinding
extends RefCounted
## Unity 6 runtime data binding for a UxmlDocument.
##
## Data sources. Any Godot Object, Dictionary or Array. A source is set on
## the document (the root of the hierarchy) or on an element, from code
## (UxmlDocument.set_data_source) or from the `data-source` attribute. The
## attribute names an asset: a key registered with
## UxmlDocument.register_data_source_asset(), a Godot resource (.tres/.res)
## or a .json file, resolved like every other UXML reference.
##
## Context. Unity's GetHierarchicalDataSourceContext: walk from the element
## up to the nearest element (self included) that has a data source;
## every `data-source-path` on the way, that element's own path included,
## is prefixed to the path. A DataBinding with its own `data-source` uses
## only its own path; otherwise its `data-source-path` is appended to the
## element's context path.
##
## Paths. Unity PropertyPath text: `a.b[2].c`, `map["key"]`. A name part
## reads an Object property, a Dictionary key or a built-in member (x, y,
## r, ...). A camelCase name that the source does not have falls back to
## its snake_case form, so `playerName` reads `player_name`.
##
## Update rules (Unity BindingUpdater.ShouldProcessBindingAtStage):
##   ToSource            never writes the UI.
##   EveryUpdate         writes the UI every frame.
##   dirty               writes the UI (a new binding is dirty; so is every
##                       binding whose context changed, and every binding
##                       passed to mark_binding_dirty()).
##   ToTargetOnce        otherwise never writes the UI again.
##   OnSourceChanged     writes the UI when the source reports a change:
##                       notify_changed(source, path), a `property_changed`
##                       signal (0 or 1 argument: the property path), a
##                       `changed` signal (Resource.emit_changed), or a
##                       new get_view_hash_code() value (polled each frame).
##   WhenDirty           writes the UI only when dirty.
## A change at path P updates the bindings whose path starts with P.
##
## Two-way. A user edit of `value` (and `text` of a TextField, `index` of a
## DropdownField) writes back to the source for TwoWay and ToSource
## bindings, then notifies the other bindings of that source. A focused
## text field is not overwritten from the source while the user types.
##
## Cost. A document without bindings creates no records and no per-frame
## work. The frame hook exists only while an EveryUpdate binding or a
## hash-polled source exists. An update touches only the bound elements.

const TWO_WAY := 0
const TO_SOURCE := 1
const TO_TARGET := 2
const TO_TARGET_ONCE := 3

const WHEN_DIRTY := 0
const ON_SOURCE_CHANGED := 1
const EVERY_UPDATE := 2

## DataBinding `property` spellings (Unity C# names and UXML attribute
## names) -> the canonical target this runtime writes.
const PROPERTIES := {
	"text": "text", "value": "value", "label": "label",
	"lowValue": "low-value", "low-value": "low-value",
	"highValue": "high-value", "high-value": "high-value",
	"choices": "choices", "index": "index", "tooltip": "tooltip",
	"enabled": "enabled", "enabledSelf": "enabled",
	"visible": "visible", "focusable": "focusable",
	"tabIndex": "tabindex", "tabindex": "tabindex",
	"pickingMode": "picking-mode", "picking-mode": "picking-mode",
	"languageDirection": "language-direction", "language-direction": "language-direction",
	"usageHints": "usage-hints", "usage-hints": "usage-hints",
	"image": "image", "sprite": "image", "texture": "image", "vectorImage": "image",
	"tintColor": "tint-color", "tint-color": "tint-color",
	"placeholderText": "placeholder-text", "placeholder-text": "placeholder-text",
	"textEdition.placeholder": "placeholder-text",
	"isReadOnly": "readonly", "readOnly": "readonly", "readonly": "readonly",
	"maxLength": "max-length", "max-length": "max-length",
	"itemsSource": "items-source",
	# Containers and collections (UxmlContainerBehaviors).
	"selectedIndex": "selected-index", "selected-index": "selected-index",
	"selectedIndices": "selected-indices",
	"selectedTabIndex": "selected-tab-index",
	"headerTitle": "header-title", "header-title": "header-title",
	"title": "title", "messageType": "message-type", "message-type": "message-type",
}

## Style properties that take a plain number (all other numbers get px).
const UNITLESS := {
	"opacity": true, "flex-grow": true, "flex-shrink": true, "aspect-ratio": true,
	"-unity-slice-left": true, "-unity-slice-right": true, "-unity-slice-top": true,
	"-unity-slice-bottom": true, "-unity-slice-scale": true, "scale": true,
}

## Converter groups: id -> Array of [Variant.Type or -1, Callable]. Global,
## like Unity's ConverterGroups registry.
static var _groups: Dictionary = {}
## Global converters: Array of [Variant.Type or -1, Callable].
static var _global: Array = []
## data-source asset key -> source object.
static var _assets: Dictionary = {}

var _doc: UxmlDocument = null
var _attrs: UxmlCommonAttributes = null

# Kept across loads.
var _root_source: Variant = null
var _named_sources: Dictionary = {}   # element name -> source
var _named_paths: Dictionary = {}     # element name -> path text

# Per load.
var _el_source: Dictionary = {}       # UxmlElement -> source
var _el_path: Dictionary = {}         # UxmlElement -> Array parts
var _el_type: Dictionary = {}         # UxmlElement -> String
var _ctx: Dictionary = {}             # UxmlElement -> [source, parts] (cache)
var _gen := 0                         # context generation (cache key)
var _recs: Array = []                 # every binding record
var _by_el: Dictionary = {}           # UxmlElement -> Array of records
var _every: Array = []                # EveryUpdate records
var _style_base: Dictionary = {}      # UxmlElement -> authored style text
var _style_over: Dictionary = {}      # UxmlElement -> {uss prop: text}
var _wired: Dictionary = {}           # UxmlElement -> true (write-back connected)
var _connected: Array = []            # [Object, signal, Callable]
var _watched: Dictionary = {}         # source Object -> true
var _hashes: Dictionary = {}          # source Object -> last view hash
var _auto_lists: Dictionary = {}      # ListView element -> {items, auto, user_bind}
var _warned: Dictionary = {}
var _pending := false                 # some record waits for a flush
var _queued := false
var _ticking := false
var _writing := false


func _init(doc: UxmlDocument, attrs: UxmlCommonAttributes) -> void:
	_doc = doc
	_attrs = attrs


# ---------------------------------------------------------------------------
# Global registries
# ---------------------------------------------------------------------------

## Add a converter to group `group_id`. `converter.call(value)` returns the
## converted value. `source_type` limits it to values of one Variant.Type
## (-1 = any). A binding names groups in `source-to-ui-converters` /
## `ui-to-source-converters`; later groups override earlier ones for the
## same source type, as Unity's ConverterGroup registry does.
static func register_converter(group_id: String, converter: Callable, source_type: int = -1) -> void:
	var list: Array = _groups.get(group_id, [])
	list.append([source_type, converter])
	_groups[group_id] = list


static func unregister_converter_group(group_id: String) -> void:
	_groups.erase(group_id)


## A converter every binding uses when no named group converts the value.
static func register_global_converter(converter: Callable, source_type: int = -1) -> void:
	_global.append([source_type, converter])


static func clear_converters() -> void:
	_groups.clear()
	_global.clear()


## Map a `data-source` attribute value (or the path it resolves to) to a
## source object.
static func register_data_source_asset(key: String, source: Variant) -> void:
	if source == null:
		_assets.erase(key)
	else:
		_assets[key] = source


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func clear() -> void:
	_disconnect_sources()
	_set_ticking(false)
	_el_source.clear()
	_el_path.clear()
	_el_type.clear()
	_ctx.clear()
	_gen += 1
	_recs.clear()
	_by_el.clear()
	_every.clear()
	_style_base.clear()
	_style_over.clear()
	_wired.clear()
	_auto_lists.clear()
	_warned.clear()
	_pending = false


## Read the binding attributes and <Bindings> of the freshly built tree and
## write the initial values. Runs before the first restyle of a load.
func setup() -> void:
	var model: UxmlDocumentModel = _doc._doc
	for el in model.root.walk():
		if el.attributes.is_empty() and not model.bindings.has(el):
			continue
		var ds = el.get_attribute("data-source")
		if ds != null and not String(ds).is_empty():
			var src = _resolve_asset(String(ds), el)
			if src != null:
				_el_source[el] = src
		var dp = el.get_attribute("data-source-path")
		if dp != null:
			var parts = UxmlBindings.parse_path(String(dp))
			if parts == null:
				_warn(el, "unsupported-value",
					'data-source-path="%s" is not a valid property path; it is ignored' % dp)
			elif not (parts as Array).is_empty():
				_el_path[el] = parts
		var dt = el.get_attribute("data-source-type")
		if dt != null:
			_el_type[el] = String(dt)
		var bp = el.get_attribute("binding-path")
		if bp != null and not String(bp).strip_edges().is_empty():
			_add_binding_path(el, String(bp))
		for desc in model.bindings.get(el, []):
			_add(el, desc, "uxml")
	for n in _named_sources:
		var el: UxmlElement = _doc._by_name.get(n)
		if el != null:
			_el_source[el] = _named_sources[n]
	for n in _named_paths:
		var el: UxmlElement = _doc._by_name.get(n)
		if el != null:
			var parts = UxmlBindings.parse_path(_named_paths[n])
			if parts != null:
				_el_path[el] = parts
	if _recs.is_empty():
		return
	_refresh_sources()
	flush()


func has_bindings() -> bool:
	return not _recs.is_empty()


## The document left (false) or entered (true) the scene tree: frame
## polling pauses while the document is out of the tree.
func set_active(on: bool) -> void:
	if on:
		_set_ticking(not _every.is_empty() or not _hashes.is_empty())
	else:
		_set_ticking(false)


# ---------------------------------------------------------------------------
# Data sources and paths
# ---------------------------------------------------------------------------

## The element a public API argument names: null/"" = the document root,
## a String = an element name, a UxmlElement, or one of its Controls.
func element_of(target: Variant) -> UxmlElement:
	if _doc._doc == null:
		return null
	if target == null or (target is String and target.is_empty()) or (target is StringName and String(target).is_empty()):
		return _doc._doc.root
	if target is UxmlElement:
		return target
	if target is String or target is StringName:
		return _doc._by_name.get(String(target))
	if target is Control:
		var el = _doc._el_of.get(target)
		if el != null:
			return el
		for e in _doc._natives:
			if _doc._natives[e] == target:
				return e
	return null


func set_data_source(source: Variant, target: Variant) -> void:
	var by_name := target is String or target is StringName
	var is_root := target == null or (by_name and String(target).is_empty())
	if is_root:
		_root_source = source
	elif by_name:
		if source == null:
			_named_sources.erase(String(target))
		else:
			_named_sources[String(target)] = source
	var el := element_of(target)
	if el == null:
		return
	if not is_root:
		if source == null:
			_el_source.erase(el)
		else:
			_el_source[el] = source
	_context_changed(el)


func get_data_source(target: Variant) -> Variant:
	var el := element_of(target)
	if el == null:
		return _root_source if target == null else null
	if _doc._doc != null and el == _doc._doc.root:
		return _root_source
	return _el_source.get(el)


func set_data_source_path(path: String, target: Variant) -> bool:
	var parts = UxmlBindings.parse_path(path)
	if parts == null:
		return false
	if target is String or target is StringName:
		_named_paths[String(target)] = path
	var el := element_of(target)
	if el == null:
		return true
	if (parts as Array).is_empty():
		_el_path.erase(el)
	else:
		_el_path[el] = parts
	_context_changed(el)
	return true


func get_data_source_path(target: Variant) -> String:
	var el := element_of(target)
	return "" if el == null else UxmlBindings.path_to_string(_el_path.get(el, []))


## The nearest data-source-type at or above the element ("" if none).
## Unity uses the type for authoring only; so does this runtime.
func get_data_source_type(target: Variant) -> String:
	var cur := element_of(target)
	while cur != null:
		if _el_type.has(cur):
			return _el_type[cur]
		cur = _doc._parents.get(cur)
	return ""


## {source, path} the element's hierarchy resolves to.
func get_context(target: Variant) -> Dictionary:
	var el := element_of(target)
	if el == null:
		return {"source": null, "path": ""}
	var h := _hier(el)
	return {"source": h[0], "path": UxmlBindings.path_to_string(h[1])}


func _hier(el: UxmlElement) -> Array:
	var cached = _ctx.get(el)
	if cached != null:
		return cached
	var parts: Array = []
	var cur: UxmlElement = el
	var root: UxmlElement = _doc._doc.root
	var out: Array = [null, parts]
	while cur != null:
		var p = _el_path.get(cur)
		if p != null:
			parts = (p as Array) + parts
		if _el_source.has(cur):
			out = [_el_source[cur], parts]
			break
		if cur == root:
			out = [_root_source, parts]
			break
		cur = _doc._parents.get(cur)
		out = [null, parts]
	_ctx[el] = out
	return out


func _context(rec: Dictionary) -> Array:
	if rec["gen"] == _gen:
		return rec["ctx"]
	var out: Array
	if rec["own"]:
		out = [rec["source"], rec["parts"]]
	else:
		var h := _hier(rec["el"])
		out = [h[0], (h[1] as Array) + (rec["parts"] as Array)]
	rec["ctx"] = out
	rec["gen"] = _gen
	return out


## A data source or path changed at `el`: every binding inside its subtree
## is dirty (Unity marks bindings dirty when their context changes).
func _context_changed(el: UxmlElement) -> void:
	_ctx.clear()
	_gen += 1
	if _recs.is_empty():
		return
	for sub in el.walk():
		for rec in _by_el.get(sub, []):
			rec["dirty"] = true
			_pending = true
	_refresh_sources()
	_queue()


func _resolve_asset(text: String, el: UxmlElement) -> Variant:
	if _assets.has(text):
		return _assets[text]
	var cut := text.find("?")
	var frag := text.find("#")
	if frag >= 0 and (cut < 0 or frag < cut):
		cut = frag
	var bare := text if cut < 0 else text.substr(0, cut)
	if _assets.has(bare):
		return _assets[bare]
	if bare.begins_with("project://database/") and _assets.has(bare.substr(19)):
		return _assets[bare.substr(19)]
	var r := _doc._resolver.resolve(text, _doc._doc.path_of(el))
	if r["ok"]:
		var path: String = r["path"]
		if _assets.has(path):
			return _assets[path]
		if path.get_extension().to_lower() == "json" and FileAccess.file_exists(path):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
			if parsed != null:
				return parsed
		elif ResourceLoader.exists(path):
			var res := ResourceLoader.load(path)
			if res != null:
				return res
	_warn(el, "missing-file",
		'data-source "%s" is not a registered asset, a Godot resource or a JSON file; register it with register_data_source_asset()' % text)
	return null


# ---------------------------------------------------------------------------
# Bindings
# ---------------------------------------------------------------------------

## Unity SetBinding: add or replace the binding of `property` on the element.
## `options`: mode / trigger (int or Unity name), data_source,
## to_ui / to_source (Arrays of converter group ids).
func add_binding(target: Variant, property: String, path: String, options: Dictionary) -> bool:
	var el := element_of(target)
	if el == null or _doc._doc == null:
		return false
	var parts = UxmlBindings.parse_path(path)
	if parts == null:
		_warn(el, "unsupported-value", 'binding path "%s" is not a valid property path' % path)
		return false
	var desc := {
		"property": property, "path": path, "parts": parts,
		"data_source": null, "data_source_object": options.get("data_source"),
		"mode": _enum(options.get("mode", TWO_WAY), UxmlBindings.MODES, TWO_WAY),
		"trigger": _enum(options.get("trigger", ON_SOURCE_CHANGED), UxmlBindings.TRIGGERS, ON_SOURCE_CHANGED),
		"to_ui": options.get("to_ui", []), "to_source": options.get("to_source", []),
		"offset": el.open_tag_start,
	}
	var rec = _add(el, desc, "code")
	if rec == null:
		return false
	_refresh_sources()
	_queue()
	return true


## Unity ClearBinding. "" removes every binding of the element.
func remove_binding(target: Variant, property: String) -> void:
	var el := element_of(target)
	if el == null:
		return
	var canon := _canonical(property) if not property.is_empty() else ""
	var kept: Array = []
	for rec in _by_el.get(el, []):
		if canon.is_empty() or rec["prop"] == canon:
			_recs.erase(rec)
			_every.erase(rec)
		else:
			kept.append(rec)
	if kept.is_empty():
		_by_el.erase(el)
	else:
		_by_el[el] = kept
	_refresh_sources()


## The element's bindings as {property, path, mode, trigger} Dictionaries.
func get_bindings(target: Variant) -> Array:
	var out: Array = []
	var el := element_of(target)
	for rec in _by_el.get(el, []):
		out.append({"property": rec["raw"], "path": rec["path"],
			"mode": UxmlBindings.MODES[rec["mode"]],
			"trigger": UxmlBindings.TRIGGERS[rec["trigger"]],
			"origin": rec["origin"]})
	return out


func _enum(v: Variant, names: Array, fallback: int) -> int:
	if v is int:
		return v if v >= 0 and v < names.size() else fallback
	var i := names.find(String(v))
	return i if i >= 0 else fallback


func _canonical(prop: String) -> String:
	var p := prop.strip_edges()
	if PROPERTIES.has(p):
		return PROPERTIES[p]
	if p.begins_with("style."):
		return "style:" + uss_name(p.substr(6))
	return ""


## Unity IStyle C# name (backgroundColor, unityFontStyleAndWeight) or USS
## name (background-color) -> USS property name.
static func uss_name(n: String) -> String:
	if n.find("-") >= 0 or n == n.to_lower():
		return n
	if n == "unityFontStyleAndWeight":
		return "-unity-font-style"
	var unity := n.begins_with("unity")
	var rest := n.substr(5) if unity else n
	var out := ""
	for i in rest.length():
		var ch := rest[i]
		if ch != ch.to_lower():
			if not out.is_empty():
				out += "-"
			out += ch.to_lower()
		else:
			out += ch
	return "-unity-" + out if unity else out


func _add(el: UxmlElement, desc: Dictionary, origin: String) -> Variant:
	var canon := _canonical(String(desc["property"]))
	if canon.is_empty():
		_warn(el, "binding-failed", 'DataBinding property "%s" is not a bindable property of <%s>; the binding is ignored' % [desc["property"], el.tag()], desc.get("offset", el.open_tag_start))
		return null
	var own := false
	var source = desc.get("data_source_object")
	if source != null:
		own = true
	elif desc.get("data_source") != null and not String(desc["data_source"]).is_empty():
		source = _resolve_asset(String(desc["data_source"]), el)
		own = source != null
	var rec := {
		"el": el, "prop": canon, "raw": String(desc["property"]),
		"own": own, "source": source,
		"parts": desc["parts"], "path": desc["path"],
		"mode": desc["mode"], "trigger": desc["trigger"],
		"to_ui": desc["to_ui"], "to_source": desc["to_source"],
		"origin": origin, "dirty": true, "pending": false,
		"has_last": false, "last": null, "gen": -1, "ctx": [],
	}
	# Unity SetBinding replaces the binding with the same id.
	var list: Array = _by_el.get(el, [])
	for old in list.duplicate():
		if old["prop"] == canon:
			list.erase(old)
			_recs.erase(old)
			_every.erase(old)
	list.append(rec)
	_by_el[el] = list
	_recs.append(rec)
	if rec["trigger"] == EVERY_UPDATE and rec["mode"] != TO_SOURCE:
		_every.append(rec)
	if rec["mode"] == TWO_WAY or rec["mode"] == TO_SOURCE:
		_wire_write_back(el)
	_pending = true
	return rec


## binding-path: Unity's SerializedObject binding of a BindableElement.
## Here it is a TwoWay, OnSourceChanged binding of the element's value
## (text for Label/Button/TextElement, itemsSource for ListView) to that
## path, relative to the element's data source context.
func _add_binding_path(el: UxmlElement, path: String) -> void:
	var prop := "value"
	match el.local:
		"Label", "Button", "TextElement", "RepeatButton", "PopupWindow":
			prop = "text"
		"ListView":
			prop = "itemsSource"
		"VisualElement", "TemplateContainer", "ScrollView", "Image", "Box", "HelpBox":
			_warn(el, "binding-failed", '<%s> is not a BindableElement; binding-path="%s" has no effect' % [el.tag(), path])
			return
	var parts = UxmlBindings.parse_path(path)
	if parts == null:
		_warn(el, "unsupported-value", 'binding-path="%s" is not a valid property path; it is ignored' % path)
		return
	_add(el, {"property": prop, "path": path, "parts": parts, "data_source": null,
		"mode": TWO_WAY, "trigger": ON_SOURCE_CHANGED, "to_ui": [], "to_source": [],
		"offset": el.open_tag_start}, "binding-path")


# ---------------------------------------------------------------------------
# Change notification and updates
# ---------------------------------------------------------------------------

## The source (null = every source) changed at `path` ("" = anywhere):
## OnSourceChanged bindings whose path starts with `path` update.
func notify_changed(source: Variant, path: String) -> void:
	var changed = UxmlBindings.parse_path(path)
	if changed == null:
		changed = []
	var hit := false
	for rec in _recs:
		if rec["trigger"] != ON_SOURCE_CHANGED or rec["mode"] == TO_SOURCE or rec["mode"] == TO_TARGET_ONCE:
			continue
		var ctx := _context(rec)
		if source != null and not _same_source(ctx[0], source):
			continue
		if not _is_prefix(changed, ctx[1]):
			continue
		rec["pending"] = true
		hit = true
	if hit:
		_pending = true
		_queue()


## Unity Binding.MarkDirty: the bindings of `property` ("" = all) on the
## element update on the next flush, whatever their trigger.
func mark_dirty(target: Variant, property: String) -> void:
	var el := element_of(target)
	if el == null:
		return
	var canon := _canonical(property) if not property.is_empty() else ""
	for rec in _by_el.get(el, []):
		if canon.is_empty() or rec["prop"] == canon:
			rec["dirty"] = true
			_pending = true
	_queue()


static func _same_source(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is Object or a is Dictionary or a is Array:
		return is_same(a, b)
	return a == b


## Unity IsPrefix: an empty change or an empty binding path always matches.
static func _is_prefix(prefix: Array, path: Array) -> bool:
	if prefix.is_empty() or path.is_empty():
		return true
	if path.size() < prefix.size():
		return false
	for i in prefix.size():
		if typeof(prefix[i]) != typeof(path[i]) or prefix[i] != path[i]:
			return false
	return true


func _queue() -> void:
	if _queued:
		return
	_queued = true
	flush.call_deferred()


## Run every pending UI update now (UxmlDocument.update_bindings()).
func flush() -> void:
	_queued = false
	if _doc._doc == null:
		return
	var relayout := false
	_writing = true
	if _pending:
		_pending = false
		for rec in _recs.duplicate():
			var run := false
			if rec["mode"] != TO_SOURCE:
				if rec["dirty"] or rec["trigger"] == EVERY_UPDATE:
					run = true
				elif rec["pending"] and rec["mode"] != TO_TARGET_ONCE and rec["trigger"] == ON_SOURCE_CHANGED:
					run = true
			rec["dirty"] = false
			rec["pending"] = false
			if run and _update_ui(rec):
				relayout = true
	else:
		for rec in _every:
			if _update_ui(rec):
				relayout = true
	_writing = false
	if relayout:
		_doc.relayout()


func _on_tick() -> void:
	for src in _hashes.keys():
		if not is_instance_valid(src):
			_hashes.erase(src)
			continue
		var h = src.call("get_view_hash_code")
		if h != _hashes[src]:
			_hashes[src] = h
			notify_changed(src, "")
	flush()


func _set_ticking(on: bool) -> void:
	if on == _ticking:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	_ticking = on
	if on:
		tree.process_frame.connect(_on_tick)
	elif tree.process_frame.is_connected(_on_tick):
		tree.process_frame.disconnect(_on_tick)


## Connect change signals of the Object sources OnSourceChanged bindings
## use, and start or stop the frame hook.
func _refresh_sources() -> void:
	var want := {}
	for rec in _recs:
		if rec["trigger"] != ON_SOURCE_CHANGED or rec["mode"] == TO_SOURCE:
			continue
		var src = _context(rec)[0]
		if src is Object and is_instance_valid(src):
			want[src] = true
	for src in want:
		if _watched.has(src):
			continue
		_watched[src] = true
		var sigs := {}
		for s in (src as Object).get_signal_list():
			sigs[s["name"]] = (s["args"] as Array).size()
		if sigs.get("property_changed", -1) == 1:
			_connect(src, "property_changed", _on_source_property.bind(src))
		elif sigs.get("property_changed", -1) == 0:
			_connect(src, "property_changed", _on_source_changed.bind(src))
		if sigs.get("changed", -1) == 0:
			_connect(src, "changed", _on_source_changed.bind(src))
		if (src as Object).has_method("get_view_hash_code"):
			_hashes[src] = src.call("get_view_hash_code")
	_set_ticking(not _every.is_empty() or not _hashes.is_empty())


func _connect(src: Object, sig: String, c: Callable) -> void:
	src.connect(sig, c)
	_connected.append([src, sig, c])


func _disconnect_sources() -> void:
	for e in _connected:
		if is_instance_valid(e[0]) and (e[0] as Object).is_connected(e[1], e[2]):
			(e[0] as Object).disconnect(e[1], e[2])
	_connected.clear()
	_watched.clear()
	_hashes.clear()


func _on_source_property(property: Variant, src: Object) -> void:
	notify_changed(src, String(property))


func _on_source_changed(src: Object) -> void:
	notify_changed(src, "")


# ---------------------------------------------------------------------------
# Source -> UI
# ---------------------------------------------------------------------------

## Returns true when the write can change a measure (relayout needed).
func _update_ui(rec: Dictionary) -> bool:
	var ctx := _context(rec)
	var src = ctx[0]
	if src == null:
		return false  # no data source yet: the binding waits, as in Unity
	var r := get_value(src, ctx[1])
	if not r[0]:
		_warn(rec["el"], "binding-failed", 'binding "%s": path "%s" does not resolve on the data source' % [rec["raw"], UxmlBindings.path_to_string(ctx[1])])
		return false
	var v = convert_value(rec["to_ui"], r[1], rec["el"])
	if rec["has_last"] and _same_value(rec["last"], v):
		return false
	var el: UxmlElement = rec["el"]
	var c: Control = _doc._controls.get(el)
	var native: Control = _doc._natives.get(el, c)
	# Unity DataBinding.UpdateUI: a focused text input is not overwritten.
	if (rec["prop"] == "value" or rec["prop"] == "text") and (native is LineEdit or native is TextEdit) and native.has_focus():
		return false
	var res := _write(rec, v)
	if res > 0:
		rec["last"] = v.duplicate() if (v is Array or v is Dictionary) else v
		rec["has_last"] = true
	elif res < 0:
		_warn(el, "binding-failed", 'binding "%s" cannot set <%s>.%s' % [rec["raw"], el.tag(), rec["raw"]])
	return res == 2


static func _same_value(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is Object:
		return is_same(a, b)
	return a == b


## Apply converter groups (then global converters) to a value.
func convert_value(groups: Array, v: Variant, el: UxmlElement = null) -> Variant:
	if groups.is_empty() and _global.is_empty():
		return v
	var t := typeof(v)
	var chosen := Callable()
	for g in groups:
		var entries = _groups.get(g)
		if entries == null:
			if el != null:
				_warn(el, "binding-failed", 'converter group "%s" is not registered; the value is not converted' % g)
			continue
		var exact := Callable()
		var any := Callable()
		for e in entries:
			if e[0] == t:
				exact = e[1]
			elif e[0] == -1:
				any = e[1]
		if exact.is_valid():
			chosen = exact
		elif any.is_valid():
			chosen = any
	if not chosen.is_valid():
		for e in _global:
			if e[0] == t or e[0] == -1:
				chosen = e[1]
	return chosen.call(v) if chosen.is_valid() else v


## 0 = nothing changed, 1 = written, 2 = written and the layout must run,
## -1 = the element cannot take the property.
func _write(rec: Dictionary, v: Variant) -> int:
	var el: UxmlElement = rec["el"]
	var prop: String = rec["prop"]
	if prop.begins_with("style:"):
		set_style(el, prop.substr(6), style_text(prop.substr(6), v))
		return 1
	var c: Control = _doc._controls.get(el)
	if c == null:
		return -1
	# Controls built as part trees (Toggle, Foldout, ProgressBar, ...) take
	# their values through their behavior (runtime/controls/).
	var beh = _doc._behaviors.get(el)
	if beh != null:
		var r: int = beh.bind_write(prop, v)
		if r != UxmlBehaviors.Behavior.UNHANDLED:
			return r
	var native: Control = _doc._natives.get(el, c)
	match prop:
		"text":
			var s := _str(v)
			if native is LineEdit or native is TextEdit:
				_set_edit_text(native, s)
				el.set_attribute("value", s)
				return 1
			if native is Label or native is Button or native is RichTextLabel:
				if _shown_text(native) == s:
					return 0
				var shown := s
				if native is Button and _rich_enabled(el):
					var pr := UxmlRichText.parse(s)
					if pr["rich"]:
						shown = pr["plain"]  # Buttons draw plain text
				_doc._set_control_text(native, shown)
				el.set_attribute("text", s)
				return 2
			return -1
		"value":
			return _write_value(el, c, native, v)
		"label":
			var s := _str(v)
			if c is UxmlField:
				var cap: Label = (c as UxmlField).caption
				if cap.text == s:
					return 0
				cap.text = s
				cap.visible = not s.is_empty()
				(c as UxmlField)._update_min_size()
				(c as UxmlField)._relayout()
			else:
				return -1
			el.set_attribute("label", s)
			return 2
		"low-value", "high-value":
			if not native is Range:
				return -1
			var f := _num(v)
			if prop == "low-value":
				native.min_value = f
			else:
				native.max_value = f
			el.set_attribute(prop, _str(v))
			return 1
		"choices":
			if not native is OptionButton:
				return -1
			var ob: OptionButton = native
			var items: Array = []
			if v is String:
				for part in (v as String).split(","):
					items.append(String(part).strip_edges())
			elif v is Array or v is PackedStringArray:
				for it in v:
					items.append(_str(it))
			else:
				return -1
			var keep := ob.get_item_text(ob.selected) if ob.selected >= 0 else ""
			ob.clear()
			for it in items:
				ob.add_item(it)
			var at := items.find(keep)
			if at >= 0:
				ob.select(at)
			el.set_attribute("choices", ",".join(PackedStringArray(items)))
			return 2
		"index":
			if not native is OptionButton:
				return -1
			var i := int(_num(v))
			(native as OptionButton).select(i if i >= 0 and i < native.item_count else -1)
			el.set_attribute("index", str(i))
			return 1
		"tooltip":
			c.tooltip_text = _str(v)
			el.set_attribute("tooltip", _str(v))
			return 1
		"enabled":
			# As set_enabled: the runtime override plus Unity's
			# `unity-disabled` class on the element itself.
			_doc._disabled_rt[el] = not _bool(v)
			UxmlParts.toggle_control_class(el, "unity-disabled", not _bool(v))
			_doc._queue_restyle()
			return 1
		"visible":
			set_style(el, "visibility", "visible" if _bool(v) else "hidden")
			return 1
		"focusable":
			var on := _bool(v)
			var mode := Control.FOCUS_ALL if on else Control.FOCUS_NONE
			native.set_meta("uxml_focus", mode)
			native.set_meta("uxml_focus_authored", mode)
			if native.visible:
				native.focus_mode = mode
			el.set_attribute("focusable", "true" if on else "false")
			if _attrs != null:
				_attrs.rebuild_focus_ring()
			return 1
		"tabindex":
			el.set_attribute("tabindex", str(int(_num(v))))
			if _attrs != null:
				_attrs.rebuild_focus_ring()
			return 1
		"picking-mode":
			var ignore: bool = (v is int and v == 1) or _str(v) == "Ignore"
			el.set_attribute("picking-mode", "Ignore" if ignore else "Position")
			if _attrs != null:
				_attrs.set_picking(el, ignore)
			return 1
		"language-direction":
			var names := UxmlCommonAttributes.DIRECTIONS
			var d: String = _str(v) if not v is int else (names[v] if v >= 0 and v < 3 else "Inherit")
			el.set_attribute("language-direction", d)
			if _attrs != null:
				_attrs.refresh_directions()
			return 1
		"usage-hints":
			return 1
		"image":
			if not native is TextureRect:
				return -1
			var tex: Texture2D = v as Texture2D
			native.texture = tex
			if c is UxmlBox:
				(c as UxmlBox).natural_size = Vector2.ZERO if tex == null else tex.get_size()
			return 2
		"tint-color":
			if not native is CanvasItem:
				return -1
			native.self_modulate = v if v is Color else Color.from_string(_str(v), Color.WHITE)
			return 1
		"placeholder-text":
			if native is LineEdit or native is TextEdit:
				native.placeholder_text = _str(v)
				el.set_attribute("placeholder-text", _str(v))
				return 1
			return -1
		"readonly":
			if native is LineEdit or native is TextEdit:
				native.set_meta("uxml_editable", not _bool(v))
				native.editable = not _bool(v)
				el.set_attribute("readonly", "true" if _bool(v) else "false")
				return 1
			return -1
		"max-length":
			if native is LineEdit:
				native.max_length = int(_num(v))
				el.set_attribute("max-length", str(int(_num(v))))
				return 1
			return -1
		"items-source":
			return _write_items(el, v)
	return -1


func _write_value(el: UxmlElement, _c: Control, native: Control, v: Variant) -> int:
	if native is Range and not native is ScrollBar:
		var f := _num(v)
		if el.local == "SliderInt":
			f = roundf(f)
		if is_equal_approx(native.value, f):
			return 0
		native.value = f
		el.set_attribute("value", str(int(f)) if el.local == "SliderInt" else str(f))
		return 1
	if native is LineEdit or native is TextEdit:
		_set_edit_text(native, _str(v))
		el.set_attribute("value", _str(v))
		return 1
	if native is OptionButton:
		var ob: OptionButton = native
		var s := _str(v)
		var at := -1
		for i in ob.item_count:
			if ob.get_item_text(i) == s:
				at = i
				break
		ob.select(at)
		if at < 0:
			ob.text = s  # Unity shows a value that is not in choices
		el.set_attribute("value", s)
		return 1
	return -1


## The authored text of a text control (before elision and rich text).
static func _shown_text(c: Control) -> String:
	if c is RichTextLabel:
		return String(c.get_meta("uxml_rich_src", ""))
	if c.has_meta("uxml_full_text"):
		return String(c.get_meta("uxml_full_text"))
	return String(c.get("text"))


static func _rich_enabled(el: UxmlElement) -> bool:
	var v = el.get_attribute("enable-rich-text")
	return v == null or String(v).to_lower() in ["true", "1"]


func _set_edit_text(native: Control, s: String) -> void:
	if native.text == s:
		return
	if native is LineEdit:
		var caret: int = (native as LineEdit).caret_column
		native.text = s
		(native as LineEdit).caret_column = mini(caret, s.length())
	else:
		native.text = s


## ListView itemsSource: the item count follows the bound collection; with
## binding-source-selection-mode="AutoAssign" each row gets the collection
## as data source and `[index]` as data source path (Unity
## BaseListViewController.BindItem).
func _write_items(el: UxmlElement, v: Variant) -> int:
	if not _doc._lists.has(el):
		return -1
	var items: Variant = v
	if v == null:
		items = []
	elif not (v is Array or (typeof(v) >= TYPE_PACKED_BYTE_ARRAY and typeof(v) <= TYPE_PACKED_VECTOR4_ARRAY)):
		return -1
	var info: Dictionary = _doc._lists[el]
	var mode = el.get_attribute("binding-source-selection-mode")
	var auto := mode != null and String(mode) == "AutoAssign"
	var prev: Dictionary = _auto_lists.get(el, {})
	var user_bind: Callable = prev.get("user_bind", Callable())
	var cur_bind: Callable = info["bind"]
	if cur_bind.is_valid() and not (prev.has("bind") and cur_bind == prev["bind"]):
		user_bind = cur_bind
	var bind := _bind_row.bind(el)
	_auto_lists[el] = {"items": items, "auto": auto, "user_bind": user_bind, "bind": bind}
	var lb = _doc._behaviors.get(el)
	if lb != null and lb.has_method("set_source"):
		lb.set_items(items)
		lb.set_source((items as Variant).size(), bind)
		return 1
	info["count"] = (items as Variant).size()
	info["bind"] = bind
	_doc._list_refresh(el, true)
	return 1


func _bind_row(row: UxmlListRow, index: int, list_el: UxmlElement) -> void:
	var st: Dictionary = _auto_lists.get(list_el, {})
	if st.get("auto", false):
		_el_source[row.element] = st["items"]
		_el_path[row.element] = [index]
		_ctx.clear()
		_gen += 1
		var was := _writing
		_writing = true
		for sub in row.element.walk():
			for rec in _by_el.get(sub, []):
				rec["dirty"] = false
				if rec["mode"] != TO_SOURCE:
					_update_ui(rec)
		_writing = was
	var ub: Callable = st.get("user_bind", Callable())
	if ub.is_valid():
		ub.call(row, index)


## A USS property override from a style.* binding. "" removes it.
func set_style(el: UxmlElement, prop: String, text: String) -> void:
	if not _style_base.has(el):
		var b = el.get_attribute("style")
		_style_base[el] = "" if b == null else String(b)
	var over: Dictionary = _style_over.get(el, {})
	if text.is_empty():
		over.erase(prop)
	else:
		over[prop] = text
	_style_over[el] = over
	var out := String(_style_base[el]).strip_edges()
	for p in over:
		if not out.is_empty() and not out.ends_with(";"):
			out += ";"
		if not out.is_empty():
			out += " "
		out += "%s: %s;" % [p, over[p]]
	if out.is_empty():
		el.remove_attribute("style")
	else:
		el.set_attribute("style", out)


## USS text for a source value bound to a style property.
static func style_text(prop: String, v: Variant) -> String:
	if v == null:
		return ""
	match typeof(v):
		TYPE_STRING, TYPE_STRING_NAME:
			return String(v)
		TYPE_BOOL:
			if prop == "display":
				return "flex" if v else "none"
			if prop == "visibility":
				return "visible" if v else "hidden"
			return "1" if v else "0"
		TYPE_INT, TYPE_FLOAT:
			if prop == "display":
				return "none" if int(v) == 1 else "flex"
			if prop == "visibility":
				return "hidden" if int(v) == 1 else "visible"
			if prop == "rotate":
				return "%sdeg" % _fmt(v)
			if UNITLESS.has(prop):
				return _fmt(v)
			return "%spx" % _fmt(v)
		TYPE_COLOR:
			var c: Color = v
			return "rgba(%d, %d, %d, %s)" % [roundi(c.r * 255.0), roundi(c.g * 255.0), roundi(c.b * 255.0), _fmt(c.a)]
		TYPE_VECTOR2, TYPE_VECTOR2I:
			if prop == "scale":
				return "%s %s" % [_fmt(v.x), _fmt(v.y)]
			return "%spx %spx" % [_fmt(v.x), _fmt(v.y)]
		TYPE_OBJECT:
			if v is Resource and not (v as Resource).resource_path.is_empty():
				return 'url("%s")' % (v as Resource).resource_path
	return String(str(v))


static func _fmt(f: Variant) -> String:
	var x := float(f)
	if is_equal_approx(x, roundf(x)):
		return str(int(roundf(x)))
	return str(snappedf(x, 0.0001))


## Text of a value the way C# ToString() writes it: an integral float
## has no ".0" (JSON numbers are floats).
static func _str(v: Variant) -> String:
	if v == null:
		return ""
	if v is float and is_finite(v) and v == roundf(v) and absf(v) < 1e15:
		return str(int(v))
	return str(v)


static func _num(v: Variant) -> float:
	if v is int or v is float:
		return float(v)
	if v is bool:
		return 1.0 if v else 0.0
	var s := str(v)
	return s.to_float() if s.is_valid_float() else 0.0


static func _bool(v: Variant) -> bool:
	if v is bool:
		return v
	if v is String or v is StringName:
		return String(v).to_lower() == "true" or String(v) == "1"
	if v is int or v is float:
		return v != 0
	return v != null


# ---------------------------------------------------------------------------
# UI -> source
# ---------------------------------------------------------------------------

func _wire_write_back(el: UxmlElement) -> void:
	if _wired.has(el):
		return
	var c: Control = _doc._controls.get(el)
	if c == null:
		return
	var native: Control = _doc._natives.get(el, c)
	_wired[el] = true
	var beh = _doc._behaviors.get(el)
	if beh != null:
		beh.ui_changed.connect(func(): _on_ui_changed(el))
	elif native is Range:
		native.value_changed.connect(func(_v): _on_ui_changed(el))
	elif native is LineEdit:
		native.text_changed.connect(func(_t): _on_ui_changed(el))
	elif native is TextEdit:
		native.text_changed.connect(func(): _on_ui_changed(el))
	elif native is OptionButton:
		native.item_selected.connect(func(_i): _on_ui_changed(el))


## The current UI value of a binding target, [ok, value].
func _read_ui(rec: Dictionary) -> Array:
	var el: UxmlElement = rec["el"]
	var c: Control = _doc._controls.get(el)
	if c == null:
		return [false, null]
	var beh = _doc._behaviors.get(el)
	if beh != null:
		return beh.bind_read(rec["prop"])
	var native: Control = _doc._natives.get(el, c)
	match rec["prop"]:
		"value":
			if native is Range:
				return [true, int(native.value) if el.local == "SliderInt" else float(native.value)]
			if native is LineEdit or native is TextEdit:
				return [true, native.text]
			if native is OptionButton:
				var ob: OptionButton = native
				return [true, ob.get_item_text(ob.selected) if ob.selected >= 0 else ""]
		"text":
			if native is LineEdit or native is TextEdit:
				return [true, native.text]
		"index":
			if native is OptionButton:
				return [true, (native as OptionButton).selected]
	return [false, null]


func _on_ui_changed(el: UxmlElement) -> void:
	if _writing:
		return
	for rec in _by_el.get(el, []):
		if rec["mode"] != TWO_WAY and rec["mode"] != TO_SOURCE:
			continue
		var r := _read_ui(rec)
		if not r[0]:
			continue
		var ctx := _context(rec)
		var src = ctx[0]
		if src == null:
			continue
		var parts: Array = ctx[1]
		if parts.is_empty():
			_warn(el, "binding-failed", 'binding "%s" has an empty path; the data source itself cannot be replaced' % rec["raw"])
			continue
		var v = convert_value(rec["to_source"], r[1], el)
		var res := set_value(src, parts, v)
		if not res[0]:
			_warn(el, "binding-failed", 'binding "%s": path "%s" cannot be written on the data source' % [rec["raw"], UxmlBindings.path_to_string(parts)])
			continue
		var changed_src = src
		if res[1] != null:
			# The source itself is a value type (a Vector2 or a packed
			# array): store the copy back where it came from.
			_store_root_copy(rec, res[1])
			changed_src = res[1]
		rec["last"] = r[1]
		rec["has_last"] = true
		# Other bindings of the same data refresh (Unity tracks the change
		# through the source's version).
		notify_changed(changed_src, UxmlBindings.path_to_string(parts))


func _store_root_copy(rec: Dictionary, copy: Variant) -> void:
	var cur: UxmlElement = rec["el"]
	while cur != null:
		if _el_source.has(cur):
			_el_source[cur] = copy
			_ctx.clear()
			_gen += 1
			return
		cur = _doc._parents.get(cur)
	_root_source = copy
	_ctx.clear()
	_gen += 1


# ---------------------------------------------------------------------------
# Property paths on Godot values
# ---------------------------------------------------------------------------

const _MEMBERS := {
	TYPE_VECTOR2: ["x", "y"], TYPE_VECTOR2I: ["x", "y"],
	TYPE_VECTOR3: ["x", "y", "z"], TYPE_VECTOR3I: ["x", "y", "z"],
	TYPE_VECTOR4: ["x", "y", "z", "w"], TYPE_VECTOR4I: ["x", "y", "z", "w"],
	TYPE_COLOR: ["r", "g", "b", "a", "r8", "g8", "b8", "a8", "h", "s", "v"],
	TYPE_RECT2: ["position", "size", "end"], TYPE_RECT2I: ["position", "size", "end"],
	TYPE_QUATERNION: ["x", "y", "z", "w"],
	TYPE_PLANE: ["normal", "d", "x", "y", "z"],
	TYPE_AABB: ["position", "size", "end"],
}


static func _is_indexable(v: Variant) -> bool:
	var t := typeof(v)
	return t == TYPE_ARRAY or (t >= TYPE_PACKED_BYTE_ARRAY and t <= TYPE_PACKED_VECTOR4_ARRAY)


static func _is_reference(v: Variant) -> bool:
	var t := typeof(v)
	return t == TYPE_OBJECT or t == TYPE_DICTIONARY or t == TYPE_ARRAY


## camelCase -> snake_case ("playerName" -> "player_name").
static func _snake(n: String) -> String:
	var out := ""
	for i in n.length():
		var ch := n[i]
		if ch != ch.to_lower() and i > 0:
			out += "_" + ch.to_lower()
		else:
			out += ch.to_lower()
	return out


## [ok, value, key actually used].
static func _get_part(cur: Variant, p: Variant) -> Array:
	if p is int:
		if _is_indexable(cur):
			if p < cur.size():
				return [true, cur[p], p]
			return [false, null, p]
		if cur is Dictionary and (cur as Dictionary).has(p):
			return [true, cur[p], p]
		return [false, null, p]
	var key := String(p)
	if cur is Dictionary:
		var d: Dictionary = cur
		if d.has(key):
			return [true, d[key], key]
		if d.has(StringName(key)):
			return [true, d[StringName(key)], StringName(key)]
		var sk := _snake(key)
		if sk != key and d.has(sk):
			return [true, d[sk], sk]
		return [false, null, key]
	if cur is Object:
		if cur == null or not is_instance_valid(cur):
			return [false, null, key]
		var o: Object = cur
		if key in o:
			return [true, o.get(key), key]
		var sk := _snake(key)
		if sk != key and sk in o:
			return [true, o.get(sk), sk]
		return [false, null, key]
	var members = _MEMBERS.get(typeof(cur))
	if members != null and (members as Array).has(key):
		return [true, cur[key], key]
	return [false, null, key]


## Read `parts` from `source`: [ok, value].
static func get_value(source: Variant, parts: Array) -> Array:
	var cur: Variant = source
	for p in parts:
		var r := _get_part(cur, p)
		if not r[0]:
			return [false, null]
		cur = r[1]
	return [true, cur]


## [ok, new container or null]. A value-type container comes back as a
## modified copy; a reference container is changed in place (null).
static func _set_part(cur: Variant, p: Variant, v: Variant) -> Array:
	var r := _get_part(cur, p)
	if not r[0]:
		return [false, null]
	var key = r[2]
	var old = r[1]
	if old != null and typeof(old) != typeof(v) and typeof(old) != TYPE_OBJECT and v != null:
		v = type_convert(v, typeof(old))
	if cur is Object:
		(cur as Object).set(key, v)
		return [true, null]
	if cur is Dictionary or cur is Array:
		cur[key] = v
		return [true, null]
	var copy = cur
	copy[key] = v
	return [true, copy]


## Write `v` at `parts` inside `source`: [ok, replacement source or null].
## Value-type parts on the way (Vector2, Color, packed arrays) are copied,
## changed and stored back into their container.
static func set_value(source: Variant, parts: Array, v: Variant) -> Array:
	if parts.is_empty():
		return [false, null]
	if parts.size() == 1:
		return _set_part(source, parts[0], v)
	var r := _get_part(source, parts[0])
	if not r[0]:
		return [false, null]
	var child = r[1]
	var inner := set_value(child, parts.slice(1), v)
	if not inner[0]:
		return [false, null]
	if inner[1] == null:
		return [true, null]
	return _set_part(source, parts[0], inner[1])


func _warn(el: UxmlElement, kind: String, message: String, offset: int = -1) -> void:
	var key := "%s|%s" % [el.get_instance_id(), message]
	if _warned.has(key) or _doc._doc == null:
		return
	_warned[key] = true
	var d := UxmlDiagnostic.make(kind, message, _doc._doc.source,
		el.open_tag_start if offset < 0 else offset, _doc._doc.path)
	_doc._rt_warnings.append(d)
	_doc.diagnostics.append(d)
