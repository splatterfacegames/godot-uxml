class_name UxmlLoader
extends RefCounted
## Assembles a UxmlDocumentModel: parses UXML, follows `<Style src>` and
## `@import` references through a UxmlResourceResolver, and reports every
## problem as a diagnostic instead of throwing.
##
## Import handling is depth-first in document order: an imported sheet's rules
## take the cascade position of the `@import` line itself, which is the order
## the author sees on the page. Sheets are deduplicated by resolved path — a
## diamond import loads once — and a true cycle is diagnosed as `import-cycle`
## rather than looping.

## Load a UXML file and its stylesheets. `path` accepts every form
## UxmlResourceResolver understands: project-relative ("Assets/UI/x.uxml"),
## res://, user:// or absolute, all contained inside `project_root`.
static func load_file(path: String, project_root: String = "res://") -> UxmlDocumentModel:
	var resolver := UxmlResourceResolver.new(project_root)
	return load_file_with_resolver(path, resolver)


static func load_file_with_resolver(path: String, resolver: UxmlResourceResolver) -> UxmlDocumentModel:
	var doc := UxmlDocumentModel.new()
	var res := resolver.resolve_text(path)
	if not res["ok"]:
		var diag: Dictionary = res["diagnostic"]
		diag["message"] = "could not load UXML document: %s" % diag["message"]
		doc.warnings.append(diag)
		doc.root = UxmlElement.new()
		return doc
	return load_source(res["text"], res["path"], resolver)


## Parse UXML text and resolve its stylesheets. `uxml_path` is the canonical
## path relative references (`<Style src>`, relative `@import`) resolve
## against. `uss` optionally supplies an extra top-level sheet scoped to the
## document root, the way the reference `parse(uxml, uss)` does.
static func load_source(
	source: String,
	uxml_path: String,
	resolver: UxmlResourceResolver,
	uss: String = ""
) -> UxmlDocumentModel:
	var doc := UxmlDocumentModel.new()
	doc.source = source
	doc.path = uxml_path

	var parsed := UxmlParser.new().parse(source, uxml_path)
	doc.root = parsed["root"]
	doc.warnings.append_array(parsed["warnings"])

	var loaded := {} ## resolved path -> sheet index
	var chain: Array = [] ## paths currently being loaded (cycle detection)

	for ref in _collect_style_refs(doc.root):
		if ref.has("problem"):
			doc.warnings.append(UxmlDiagnostic.make(
				"malformed", ref["problem"],
				doc.source, ref["element"].open_tag_start, doc.path
			))
			continue
		var res := resolver.resolve_text(ref["url"], uxml_path)
		if not res["ok"]:
			var diag := _rebase(res["diagnostic"], uxml_path)
			diag["message"] = '<Style src="%s"> could not be resolved: %s' % [ref["url"], diag["message"]]
			doc.warnings.append(diag)
			continue
		var sheet_index: int
		if loaded.has(res["path"]):
			sheet_index = loaded[res["path"]]
		else:
			sheet_index = _load_sheet(res["text"], res["path"], ref["scope"], doc, resolver, loaded, chain)
		doc.style_roots.append({"sheet": sheet_index, "scope": ref["scope"]})

	if not uss.is_empty():
		var sheet_index := _load_sheet(uss, "", doc.root, doc, resolver, loaded, chain)
		doc.style_roots.append({"sheet": sheet_index, "scope": doc.root})

	_report_unsupported_tags(doc)
	return doc


## `<Style src="...">` elements in document order; each scopes its sheet to
## the element that contains it. A <Style> with a missing or empty src is a
## broken reference: it yields a `problem` entry so the loader can diagnose
## it instead of silently skipping it.
static func _collect_style_refs(element: UxmlElement, out: Array = []) -> Array:
	for child in element.children:
		if child.local == "Style":
			var src = child.get_attribute("src")
			if src == null:
				out.append({
					"problem": "<Style> element is missing its src attribute",
					"element": child,
				})
			elif String(src).is_empty():
				out.append({
					"problem": '<Style src=""> is empty',
					"element": child,
				})
			else:
				out.append({"url": String(src), "scope": element})
		_collect_style_refs(child, out)
	return out


static func _load_sheet(
	text: String,
	origin: String,
	scope: UxmlElement,
	doc: UxmlDocumentModel,
	resolver: UxmlResourceResolver,
	loaded: Dictionary,
	chain: Array
) -> int:
	var index := doc.sheets.size()
	var parsed := UssParser.new().parse(text, origin)
	doc.sheets.append({
		"index": index,
		"source": text,
		"origin": origin,
		"items": parsed["items"],
		"scope": scope,
	})
	doc.warnings.append_array(parsed["warnings"])
	if not origin.is_empty():
		loaded[origin] = index
	chain.append(origin)

	for item in parsed["items"]:
		# At-rules the grammar does not support (@media, @supports, @charset,
		# ...) reach here as tagged `unknown` items. Diagnose them explicitly;
		# their contents were already skipped by the parser and never apply.
		if item["kind"] == "unknown" and item.has("at_rule"):
			doc.warnings.append(UxmlDiagnostic.make(
				"unsupported-feature",
				'@%s rules are not supported; the at-rule and its contents are ignored' % item["at_rule"],
				text, item["span"]["start"], origin
			))
			continue
		if item["kind"] != "import":
			continue
		var res := resolver.resolve_text(item["url"], origin)
		if not res["ok"]:
			var diag := _rebase(res["diagnostic"], origin, text, item["span"]["start"])
			diag["message"] = '@import "%s" could not be resolved: %s' % [item["url"], diag["message"]]
			doc.warnings.append(diag)
			continue
		if loaded.has(res["path"]):
			if chain.has(res["path"]):
				doc.warnings.append(UxmlDiagnostic.make(
					"import-cycle",
					'@import "%s" is part of a stylesheet cycle; the first load is kept' % item["url"],
					text,
					item["span"]["start"],
					origin
				))
			item["resolved_sheet"] = loaded[res["path"]]
			continue
		item["resolved_sheet"] = _load_sheet(
			res["text"], res["path"], scope, doc, resolver, loaded, chain
		)

	chain.pop_back()
	return index


## Copy a resolver diagnostic and attach the file/position it came from.
static func _rebase(diag: Dictionary, file: String, source: String = "", offset: int = 0) -> Dictionary:
	var out := diag.duplicate()
	out["file"] = file
	if not source.is_empty():
		var lc := UxmlDiagnostic.line_col(source, offset)
		out["offset"] = offset
		out["line"] = lc.x
		out["column"] = lc.y
	return out


static func _report_unsupported_tags(doc: UxmlDocumentModel) -> void:
	var seen := {}
	var seen_attrs := {}
	for element in doc.root.walk():
		# Attributes outside the grammar the addon consumes warn once per
		# name — the value stays in the model, it just has no effect.
		# Namespace declarations and namespaced attributes are exempt.
		for attr in element.attributes:
			var attr_name: String = attr["name"]
			if attr_name.find(":") >= 0 or UssControls.KNOWN_ATTRIBUTES.has(attr_name):
				continue
			if seen_attrs.has(attr_name):
				continue
			seen_attrs[attr_name] = true
			doc.warnings.append(UxmlDiagnostic.make(
				"unsupported-attribute",
				'<%s> attribute "%s" is not used by godot-uxml; it is preserved but has no effect' % [
					element.tag(), attr_name,
				],
				doc.source, attr["offset"], doc.path
			))
		if UssControls.is_known_control(element.local):
			continue
		if UssControls.UNSUPPORTED_FEATURE_TAGS.has(element.local):
			doc.warnings.append(UxmlDiagnostic.make(
				"unsupported-feature",
				"<%s>: %s; the element is kept but not interpreted" % [
					element.tag(), UssControls.UNSUPPORTED_FEATURE_TAGS[element.local],
				],
				doc.source, element.open_tag_start, doc.path
			))
			continue
		# One warning per tag keeps output readable on a file full of them.
		if seen.has(element.local):
			continue
		seen[element.local] = true
		doc.warnings.append(UxmlDiagnostic.make(
			"unsupported-control",
			'<%s> has no Godot control mapping; it becomes a plain container and its children are preserved' % element.tag(),
			doc.source, element.open_tag_start, doc.path
		))
