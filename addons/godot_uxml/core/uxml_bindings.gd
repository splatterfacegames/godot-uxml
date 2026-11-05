class_name UxmlBindings
extends RefCounted
## Model side of Unity runtime data binding: `<Bindings>` UxmlObjects and
## PropertyPath syntax.
##
## Unity UXML declares bindings as UxmlObject children of the bound element:
##
##   <ui:Label text="-">
##       <Bindings>
##           <ui:DataBinding property="text" data-source-path="player.name"
##               binding-mode="ToTarget" update-trigger="OnSourceChanged"/>
##       </Bindings>
##   </ui:Label>
##
## `<Bindings>` and its children are instructions, not visual elements.
## extract() removes them from the element tree before any sheet, cascade,
## layout or factory pass sees the tree, and records one descriptor per
## DataBinding in `UxmlDocumentModel.bindings` (element -> Array). The
## runtime (UxmlBinding) consumes the descriptors.

const BINDINGS_TAG := "Bindings"
const DATA_BINDING_TAG := "DataBinding"

## Unity BindingMode, in enum order.
const MODES := ["TwoWay", "ToSource", "ToTarget", "ToTargetOnce"]
## Unity BindingUpdateTrigger, in enum order.
const TRIGGERS := ["WhenDirty", "OnSourceChanged", "EveryUpdate"]

## Attributes a <DataBinding> accepts (Unity DataBinding.UxmlSerializedData).
const DATA_BINDING_ATTRIBUTES := {
	"property": true, "data-source": true, "data-source-path": true,
	"data-source-type": true, "binding-mode": true, "update-trigger": true,
	"source-to-ui-converters": true, "ui-to-source-converters": true,
}


static func is_binding_tag(local_name: String) -> bool:
	return local_name == BINDINGS_TAG or local_name == DATA_BINDING_TAG


## Remove every `<Bindings>` element (and any stray <DataBinding>) from
## `root`'s subtree and record the descriptors in `doc.bindings`. Returns
## the diagnostics. A document without binding syntax is not modified.
## `source`/`file` locate diagnostics; elements cloned from a template file
## report against the entry document, like other template diagnostics.
static func extract(doc: UxmlDocumentModel, root: UxmlElement = null) -> Array:
	var warnings: Array = []
	var start: UxmlElement = doc.root if root == null else root
	if start == null:
		return warnings
	var stack: Array = [start]
	while not stack.is_empty():
		var el: UxmlElement = stack.pop_back()
		if el.children.is_empty():
			continue
		var kept: Array = []
		var removed := false
		for child in el.children:
			if child.local == BINDINGS_TAG:
				removed = true
				if el == doc.root:
					warnings.append(_diag(doc, "malformed",
						"<Bindings> must be inside the element it binds; it is ignored",
						child.open_tag_start))
					continue
				for b in child.children:
					_read(doc, el, b, warnings)
				continue
			if child.local == DATA_BINDING_TAG:
				removed = true
				warnings.append(_diag(doc, "malformed",
					"<%s> must be inside a <Bindings> element; it is ignored" % child.tag(),
					child.open_tag_start))
				continue
			kept.append(child)
			stack.append(child)
		if removed:
			el.children = kept
	# Clones (pooled ListView rows, template instances) repeat one authored
	# binding: report each problem once.
	var seen := {}
	var unique: Array = []
	for d in warnings:
		var key := "%s|%s|%d" % [d["kind"], d["message"], d["offset"]]
		if not seen.has(key):
			seen[key] = true
			unique.append(d)
	return unique


static func _read(doc: UxmlDocumentModel, owner: UxmlElement, b: UxmlElement, warnings: Array) -> void:
	if b.local != DATA_BINDING_TAG:
		warnings.append(_diag(doc, "unsupported-feature",
			"<%s> is a binding type defined in C#; only <DataBinding> is supported, so it is ignored" % b.tag(),
			b.open_tag_start))
		return
	for a in b.attributes:
		var an: String = a["name"]
		if an.find(":") >= 0 or DATA_BINDING_ATTRIBUTES.has(an):
			continue
		warnings.append(_diag(doc, "unsupported-attribute",
			'<%s> attribute "%s" is not a DataBinding attribute; it has no effect' % [b.tag(), an],
			a["offset"]))
	var prop = b.get_attribute("property")
	if prop == null or String(prop).strip_edges().is_empty():
		warnings.append(_diag(doc, "malformed",
			"<%s> has no property attribute; the binding is ignored" % b.tag(), b.open_tag_start))
		return
	var mode := 0
	var mv = b.get_attribute("binding-mode")
	if mv != null:
		mode = MODES.find(String(mv).strip_edges())
		if mode < 0:
			warnings.append(_diag(doc, "unsupported-value",
				'binding-mode="%s" is not a BindingMode; TwoWay used' % mv, b.open_tag_start))
			mode = 0
	var trigger := 1
	var tv = b.get_attribute("update-trigger")
	if tv != null:
		trigger = TRIGGERS.find(String(tv).strip_edges())
		if trigger < 0:
			warnings.append(_diag(doc, "unsupported-value",
				'update-trigger="%s" is not a BindingUpdateTrigger; OnSourceChanged used' % tv,
				b.open_tag_start))
			trigger = 1
	var path_text := String(b.get_attribute("data-source-path")) if b.has_attribute("data-source-path") else ""
	var parsed := parse_path(path_text)
	if parsed == null:
		warnings.append(_diag(doc, "unsupported-value",
			'data-source-path="%s" is not a valid property path; the binding is ignored' % path_text,
			b.open_tag_start))
		return
	var desc := {
		"property": String(prop).strip_edges(),
		"path": path_text,
		"parts": parsed,
		"data_source": b.get_attribute("data-source"),
		"data_source_type": b.get_attribute("data-source-type"),
		"mode": mode,
		"trigger": trigger,
		"to_ui": split_list(b.get_attribute("source-to-ui-converters")),
		"to_source": split_list(b.get_attribute("ui-to-source-converters")),
		"offset": b.open_tag_start,
	}
	var list: Array = doc.bindings.get(owner, [])
	list.append(desc)
	doc.bindings[owner] = list


## Unity UxmlUtility.ParseStringListAttribute: comma separated, trimmed,
## empty entries dropped.
static func split_list(v) -> Array:
	var out: Array = []
	if v == null:
		return out
	for part in String(v).split(","):
		var s := String(part).strip_edges()
		if not s.is_empty():
			out.append(s)
	return out


## Parse a Unity PropertyPath: `a.b[2].c`, `items[0]`, `[3]`, `map["key"]`
## or `map[key]`. Returns an Array of parts (String = name or key,
## int = index), [] for the empty path, or null when the text is not a
## path. A dictionary key is a String part, so `map["key"]` and `map.key`
## address the same entry.
static func parse_path(text: String) -> Variant:
	var s := text.strip_edges()
	var parts: Array = []
	var i := 0
	var n := s.length()
	var name := ""
	var expect_name := false  # after a "."
	while i < n:
		var c := s[i]
		if c == ".":
			if name.is_empty() and (parts.is_empty() or expect_name):
				return null
			if not name.is_empty():
				parts.append(name)
				name = ""
			expect_name = true
			i += 1
			continue
		if c == "[":
			if not name.is_empty():
				parts.append(name)
				name = ""
			elif expect_name:
				return null
			var close := s.find("]", i + 1)
			if close < 0:
				return null
			var inner := s.substr(i + 1, close - i - 1).strip_edges()
			if inner.is_empty():
				return null
			if inner.length() >= 2 and (inner[0] == '"' or inner[0] == "'") and inner[inner.length() - 1] == inner[0]:
				parts.append(inner.substr(1, inner.length() - 2))
			elif inner.is_valid_int():
				var idx := int(inner)
				if idx < 0:
					return null
				parts.append(idx)
			else:
				parts.append(inner)
			i = close + 1
			expect_name = false
			if i < n and s[i] != "." and s[i] != "[":
				return null
			continue
		if c == "]" or c == " " or c == "\t":
			return null
		name += c
		expect_name = false
		i += 1
	if expect_name:
		return null
	if not name.is_empty():
		parts.append(name)
	return parts


## Text form of parsed parts (the inverse of parse_path).
static func path_to_string(parts: Array) -> String:
	var out := ""
	for p in parts:
		if p is int:
			out += "[%d]" % p
		elif out.is_empty():
			out = String(p)
		else:
			out += "." + String(p)
	return out


static func _diag(doc: UxmlDocumentModel, kind: String, message: String, offset: int) -> Dictionary:
	return UxmlDiagnostic.make(kind, message, doc.source, offset, doc.path)
