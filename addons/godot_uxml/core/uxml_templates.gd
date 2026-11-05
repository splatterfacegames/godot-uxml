class_name UxmlTemplates
extends RefCounted
## Expands UXML templates in a parsed tree, with Unity 6 semantics.
##
##   <ui:Template name="Row" src="row.uxml" />      (direct child of <UXML>;
##                                                  `path` is the old spelling)
##   <ui:Instance template="Row" name="r1" class="x">
##       <ui:AttributeOverrides element-name="title" text="Hi" />
##       <ui:Label text="content" />                (goes to content-container)
##       <ui:Label slot="footer" />                 (goes to slot-name="footer")
##   </ui:Instance>
##
## Expansion rewrites the tree in place. Each <Instance> becomes a
## `TemplateContainer` element (Unity's real type) that keeps every Instance
## attribute except `template` and holds deep clones of the template
## document's top-level elements; nested Instances expand recursively.
## <Template> and <AttributeOverrides> are instructions: they are removed from
## the tree. Template <Style> elements are cloned with the content: a root-level
## one is then a child of the TemplateContainer, so UxmlLoader scopes its sheet
## to the container; a nested one scopes to its cloned parent. `style_from`
## tells the loader which file such a cloned <Style src> is relative to.
##
## Every template file is read and parsed once per expansion (cache by
## resolved path). Clones get fresh ids; their source offsets point at the
## outermost <Instance> in the entry document, so layout and runtime
## diagnostics name a real location in the main file. Problems inside a
## template file (parse errors, unknown tags, a broken <Style>) are reported
## against that file once.
##
## Semantics ported from vendor/uxml-preview/src/template/expand.ts
## (Apache-2.0, see THIRD-PARTY-NOTICES.md). Unity deltas over that source:
## `content-container` and `slot`/`slot-name` placement are implemented,
## `path=` is accepted, and AttributeOverrides cannot set `name` or `class`
## (Unity ignores them like `style`).

## Instance nesting deeper than this is diagnosed instead of expanded.
const MAX_DEPTH := 32
## Attributes AttributeOverrides cannot change in Unity.
const IGNORED_OVERRIDES := ["style", "class", "name"]

var _resolver: UxmlResourceResolver
var _warnings: Array = []
var _next_id := 0
## resolved template path -> record {path, source, root, declarations} or null
var _cache: Dictionary = {}
## resolved paths of the templates on the current expansion path
var _stack: Array = []
## cloned element -> its offset in the file it was cloned from
var _orig: Dictionary = {}
## TemplateContainer -> element that receives its Instance children
var _content: Dictionary = {}
## TemplateContainer -> {slot name: element} of its template
var _slots: Dictionary = {}
## Diagnostic keys already reported (one report per declaration / location).
var _reported: Dictionary = {}

## Cloned <Style> element -> {path, source, offset} of the template file.
var style_from: Dictionary = {}
## Cloned element -> path of the template file it was authored in.
var element_paths: Dictionary = {}
## Every cloned element (the loader skips them in entry-file checks; the
## template file reports its own).
var clones: Dictionary = {}


## True when `root` uses any template syntax. A document without it skips
## expansion entirely and loads exactly as before.
static func has_template_syntax(root: UxmlElement) -> bool:
	for el in root.walk():
		var l: String = el.local
		if l == "Template" or l == "Instance" or l == "AttributeOverrides":
			return true
	return false


func _init(resolver: UxmlResourceResolver) -> void:
	_resolver = resolver


## Expand every template in `root` (parsed from `source` at `path`). Returns
## the diagnostics; `style_from`, `element_paths` and `clones` are filled.
func expand(root: UxmlElement, source: String, path: String) -> Array:
	for el in root.walk():
		_next_id = maxi(_next_id, el.id + 1)
	var entry := _record(root, source, path)
	_stack = [path]
	_expand_children(root, entry, null, 0)
	return _warnings


# ---------------------------------------------------------------------------
# Declarations and template files
# ---------------------------------------------------------------------------

## {path, source, root, declarations: name -> {name, src, offset}}. Template
## declarations are read from the root's direct children only, as Unity's
## importer does; invalid or duplicate ones are diagnosed here.
func _record(root: UxmlElement, source: String, path: String) -> Dictionary:
	var rec := {"path": path, "source": source, "root": root, "declarations": {}}
	for child in root.children:
		if child.local != "Template":
			continue
		var name = child.get_attribute("name")
		var src = child.get_attribute("src")
		if src == null or String(src).is_empty():
			src = child.get_attribute("path")
		if name == null or String(name).is_empty():
			_warn("malformed", "<%s> has no name attribute; the declaration is ignored" % child.tag(),
				rec, child.open_tag_start)
			continue
		if src == null or String(src).is_empty():
			_warn("malformed", '<%s name="%s"> has no src attribute; the declaration is ignored' % [
				child.tag(), name], rec, child.open_tag_start)
			continue
		if rec["declarations"].has(String(name)):
			_warn("malformed", 'template name "%s" is declared more than once; the first declaration is used' % name,
				rec, child.open_tag_start)
			continue
		rec["declarations"][String(name)] = {
			"name": String(name), "src": String(src), "offset": child.open_tag_start,
		}
	return rec


## Load a declared template file once. Returns its record or null; the
## failure is diagnosed once per declaring file and declaration.
func _load(decl: Dictionary, from: Dictionary, at: int) -> Variant:
	# Unity UI Builder writes `src="project://database/Assets/x.uxml?fileID=…&guid=…#x"`;
	# the asset path is the part before the query.
	var src: String = decl["src"]
	var cut := src.find("?")
	if cut < 0:
		cut = src.find("#")
	var ref := src if cut < 0 else src.substr(0, cut)
	var res := _resolver.resolve_text(ref, from["path"])
	if not res["ok"]:
		var key := "unresolved:%s:%d" % [from["path"], decl["offset"]]
		if not _reported.has(key):
			_reported[key] = true
			var d: Dictionary = res["diagnostic"]
			var diag := UxmlDiagnostic.make(String(d.get("kind", "missing-file")),
				'<Template name="%s" src="%s"> could not be resolved: %s' % [
					decl["name"], src, d.get("message", "")],
				from["source"], at, from["path"])
			diag["template"] = decl["name"]
			_warnings.append(diag)
		return null
	var path: String = res["path"]
	if _cache.has(path):
		return _cache[path]
	var parsed := UxmlParser.new().parse(res["text"], path)
	_warnings.append_array(parsed["warnings"])
	var root: UxmlElement = parsed["root"]
	var rec := _record(root, res["text"], path)
	_cache[path] = rec
	_check_template_file(rec)
	return rec


## Diagnostics a template file owns: unknown tags and attributes, broken
## <Style> elements, misplaced template syntax. Reported against that file
## once, however many times the template is instantiated.
func _check_template_file(rec: Dictionary) -> void:
	var tmp := UxmlDocumentModel.new()
	tmp.root = rec["root"]
	tmp.source = rec["source"]
	tmp.path = rec["path"]
	for el in (rec["root"] as UxmlElement).walk():
		if el.local == "Style":
			var s = el.get_attribute("src")
			if s == null:
				_warn("malformed", "<Style> element is missing its src attribute", rec, el.open_tag_start)
			elif String(s).is_empty():
				_warn("malformed", '<Style src=""> is empty', rec, el.open_tag_start)
	UxmlLoader._report_unsupported_tags(tmp)
	_warnings.append_array(tmp.warnings)


# ---------------------------------------------------------------------------
# Expansion
# ---------------------------------------------------------------------------

## Expand the template syntax among `parent`'s children, which belong to the
## file `rec`. `anchor` is the entry-document <Instance> clones point at
## (null while still walking the entry document itself).
func _expand_children(parent: UxmlElement, rec: Dictionary, anchor: UxmlElement, depth: int) -> void:
	var kept: Array = []
	for child in parent.children:
		match child.local:
			"Template":
				if parent != rec["root"]:
					_warn("malformed", "<%s> must be a direct child of <UXML>; the declaration is ignored" % child.tag(),
						rec, _offset(child))
				continue
			"AttributeOverrides":
				_warn("malformed", "<%s> must be a child of an <Instance>; it is ignored" % child.tag(),
					rec, _offset(child))
				continue
			"Instance":
				_expand_instance(child, rec, anchor, depth)
			_:
				_expand_children(child, rec, anchor, depth)
		kept.append(child)
	parent.children = kept


## Turn `inst` into a TemplateContainer in place: clone the template, expand
## nested instances, apply AttributeOverrides, then place the Instance's own
## children (slot children into their slot, the rest into the
## content-container or the container itself).
func _expand_instance(inst: UxmlElement, rec: Dictionary, anchor: UxmlElement, depth: int) -> void:
	var at := _offset(inst)
	var here: UxmlElement = inst if anchor == null else anchor
	var template_name = inst.get_attribute("template")
	inst.local = "TemplateContainer"
	inst.remove_attribute("template")

	var overrides: Array = []
	var content: Array = []
	for child in inst.children:
		match child.local:
			"AttributeOverrides":
				overrides.append(child)
			"Template":
				_warn("malformed", "<%s> must be a direct child of <UXML>; the declaration is ignored" % child.tag(),
					rec, _offset(child))
			"Instance":
				_expand_instance(child, rec, anchor, depth)
				content.append(child)
			_:
				_expand_children(child, rec, anchor, depth)
				content.append(child)
	inst.children = []

	var tmpl = null
	if template_name == null or String(template_name).is_empty():
		_warn("malformed", "<Instance> has no template attribute; it stays an empty TemplateContainer", rec, at)
	elif not rec["declarations"].has(String(template_name)):
		_warn("template-not-declared",
			'<Instance template="%s"> names no <Template> declared in this file' % template_name, rec, at)
	elif depth >= MAX_DEPTH:
		_warn("template-depth-exceeded",
			'<Instance template="%s"> exceeds the template nesting limit of %d; it is not expanded' % [
				template_name, MAX_DEPTH], rec, at)
	else:
		var decl: Dictionary = rec["declarations"][String(template_name)]
		var loaded = _load(decl, rec, at)
		if loaded != null and _stack.has(loaded["path"]):
			var chain: Array = []
			for p in _stack.slice(_stack.find(loaded["path"])):
				chain.append(String(p).get_file())
			chain.append(String(loaded["path"]).get_file())
			_warn("template-cycle", '<Instance template="%s"> is part of a template cycle (%s); it is not expanded' % [
				template_name, " -> ".join(chain)], rec, at)
		else:
			tmpl = loaded

	if tmpl != null:
		_instantiate(inst, tmpl, here, depth)
		_apply_overrides(inst, overrides, rec)
	else:
		for o in overrides:
			_check_override(o, rec)

	# Instance children: slot children go to their slot, the rest to the
	# content container (followed through nested containers).
	var target := inst
	while _content.has(target):
		target = _content[target]
	var slots: Dictionary = _slots.get(inst, {})
	for child in content:
		var slot = child.get_attribute("slot")
		if slot != null and slots.has(String(slot)):
			(slots[String(slot)] as UxmlElement).children.append(child)
		else:
			target.children.append(child)
	_slots.erase(inst)


## Clone the template's visual content under `inst` and expand it.
func _instantiate(inst: UxmlElement, tmpl: Dictionary, anchor: UxmlElement, depth: int) -> void:
	var path: String = tmpl["path"]
	var clone_list: Array = []
	for child in (tmpl["root"] as UxmlElement).children:
		if child.local == "Template":
			continue
		clone_list.append(_clone(child, anchor, path))
	inst.children = clone_list

	# Slot and content-container definitions belong to this template only:
	# read them before nested instances add their own content.
	var slots := {}
	var container: UxmlElement = null
	for el in inst.walk():
		if el == inst:
			continue
		var sn = el.get_attribute("slot-name")
		if sn != null and not String(sn).is_empty() and not slots.has(String(sn)):
			slots[String(sn)] = el
		if el.has_attribute("content-container"):
			if container == null:
				container = el
			else:
				_warn("malformed", "more than one element has content-container; the first one in depth-first order is used",
					tmpl, _orig.get(el, 0))

	_stack.append(path)
	_expand_children(inst, tmpl, anchor, depth + 1)
	_stack.pop_back()
	if container != null:
		_content[inst] = container
	if not slots.is_empty():
		_slots[inst] = slots


func _clone(t: UxmlElement, anchor: UxmlElement, path: String) -> UxmlElement:
	var c := UxmlElement.new()
	c.id = _next_id
	_next_id += 1
	c.prefix = t.prefix
	c.local = t.local
	c.open_tag_start = anchor.open_tag_start
	c.open_tag_end = anchor.open_tag_end
	c.source_end = anchor.source_end
	var off := anchor.open_tag_start
	for a in t.attributes:
		c.attributes.append({"name": a["name"], "value": a["value"], "offset": off})
	_orig[c] = _offset(t)
	clones[c] = true
	element_paths[c] = path
	if t.local == "Style":
		var rec: Dictionary = _cache[path]
		style_from[c] = {"path": path, "source": rec["source"], "offset": _offset(t)}
	for ch in t.children:
		c.children.append(_clone(ch, anchor, path))
	return c


# ---------------------------------------------------------------------------
# AttributeOverrides
# ---------------------------------------------------------------------------

## Validate one AttributeOverrides element; returns its element-name or "".
func _check_override(o: UxmlElement, rec: Dictionary) -> String:
	var target = o.get_attribute("element-name")
	for attr_name in IGNORED_OVERRIDES:
		var v = o.get_attribute(attr_name)
		if v != null:
			_warn("override-ignored",
				'AttributeOverrides %s for element-name "%s" was ignored with value "%s"; Unity ignores %s AttributeOverrides' % [
					attr_name, "(missing)" if target == null else target, v, attr_name],
				rec, _offset(o))
	if target == null or String(target).is_empty():
		_warn("malformed", "<%s> has no element-name attribute; it is ignored" % o.tag(), rec, _offset(o))
		return ""
	return String(target)


## Set each override's attributes on every element named element-name inside
## the instance (nested templates included). Overrides run after the nested
## instances expanded, so an outer override wins over an inner one, as in
## Unity.
func _apply_overrides(inst: UxmlElement, overrides: Array, rec: Dictionary) -> void:
	if overrides.is_empty():
		return
	var inside: Array = inst.walk()
	inside.pop_front()
	for o in overrides:
		var want := _check_override(o, rec)
		if want.is_empty():
			continue
		var hit := false
		for el in inside:
			if el.local == "Style" or el.get_attribute("name") != want:
				continue
			hit = true
			for a in o.attributes:
				var n: String = a["name"]
				if n == "element-name" or IGNORED_OVERRIDES.has(n) or n.find(":") >= 0:
					continue
				_set_attr(el, n, a["value"], a["offset"] if not clones.has(o) else el.open_tag_start)
		if not hit:
			var names: Array = []
			for el in inside:
				var nm = el.get_attribute("name")
				if nm != null and el.local != "Style" and not names.has(String(nm)):
					names.append(String(nm))
			_warn("override-target-missing",
				'AttributeOverrides element-name "%s" matches no element in the instance; available names: %s' % [
					want, "(none)" if names.is_empty() else ", ".join(names)],
				rec, _offset(o))


static func _set_attr(el: UxmlElement, n: String, v: String, offset: int) -> void:
	for a in el.attributes:
		if a["name"] == n:
			a["value"] = v
			return
	el.attributes.append({"name": n, "value": v, "offset": offset})


# ---------------------------------------------------------------------------

## Offset of `el` in the file it came from (clones remember their original).
func _offset(el: UxmlElement) -> int:
	return _orig.get(el, el.open_tag_start)


func _warn(kind: String, message: String, rec: Dictionary, offset: int) -> void:
	var key := "%s:%s:%d:%s" % [kind, rec["path"], offset, message]
	if _reported.has(key):
		return
	_reported[key] = true
	_warnings.append(UxmlDiagnostic.make(kind, message, rec["source"], offset, rec["path"]))
