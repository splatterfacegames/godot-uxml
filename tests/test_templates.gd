extends RefCounted
## UXML templates: <Template>/<Instance>/<AttributeOverrides>,
## content-container, slots, template style scoping, diagnostics, and the
## runtime view of an expanded tree. `h` is the SceneTree harness from
## run_tests.gd.

const ROOT := "res://tests/fixtures/templates"

var h = null


func _init(harness) -> void:
	h = harness


func _main() -> UxmlDocumentModel:
	return UxmlLoader.load_file("Assets/UI/Main.uxml", ROOT)


func _named(doc: UxmlDocumentModel, n: String) -> Array:
	var out: Array = []
	for el in doc.root.walk():
		if el.get_attribute("name") == n:
			out.append(el)
	return out


func _parent_of(doc: UxmlDocumentModel, target: UxmlElement) -> UxmlElement:
	for el in doc.root.walk():
		if el.children.has(target):
			return el
	return null


func _of_kind(doc: UxmlDocumentModel, kind: String) -> Array:
	var out: Array = []
	for d in doc.warnings:
		if d["kind"] == kind:
			out.append(d)
	return out


func _style(doc: UxmlDocumentModel, el: UxmlElement, prop: String) -> Variant:
	var res := UssStyleResolver.resolve(doc, {})
	var e = res["styles"].get(el, {}).get(prop)
	return null if e == null else String(e["value"])


## 1-based line of the first occurrence of `needle` in `source`.
func _line(source: String, needle: String) -> int:
	var at := source.find(needle)
	return UxmlDiagnostic.line_col(source, at).x if at >= 0 else -1


func _inline(body: String, files: Dictionary, root_name: String) -> UxmlDocumentModel:
	var root := "user://godot_uxml_templates/%s" % root_name
	DirAccess.make_dir_recursive_absolute(root)
	for p in files:
		var f := FileAccess.open(root + "/" + p, FileAccess.WRITE)
		f.store_string('<ui:UXML xmlns:ui="UnityEngine.UIElements">%s</ui:UXML>' % files[p])
		f.close()
	var src := '<ui:UXML xmlns:ui="UnityEngine.UIElements">%s</ui:UXML>' % body
	return UxmlLoader.load_source(src, root + "/main.uxml", UxmlResourceResolver.new(root))


# ---------------------------------------------------------------------------

func test_instance_becomes_template_container() -> void:
	var doc := _main()
	var row_a: UxmlElement = _named(doc, "row-a")[0]
	h.eq(row_a.local, "TemplateContainer", "Instance becomes a TemplateContainer")
	h.eq(row_a.get_attribute("template"), null, "template attribute is dropped")
	h.eq(row_a.get_attribute("class"), "instance-a", "other Instance attributes stay")
	h.eq(row_a.children.size(), 2, "template <Style> clone + visual root child")
	h.eq(row_a.children[1].get_attribute("name"), "row", "template content is cloned")
	h.eq(row_a.children[1].children[0].get_attribute("name"), "title", "deep clone")
	var instructions := 0
	for el in doc.root.walk():
		if el.local in ["Template", "Instance", "AttributeOverrides"]:
			instructions += 1
	h.eq(instructions, 0, "Template/Instance/AttributeOverrides leave the tree")
	h.eq(_of_kind(doc, "unsupported-feature").size(), 0, "templates are no longer unsupported")
	h.eq(_of_kind(doc, "unsupported-control").size(), 0, "TemplateContainer is a known control")
	h.check(UssControls.is_known_control("TemplateContainer"), "TemplateContainer known")
	# Two instances of one template are independent copies.
	var titles := _named(doc, "title")
	h.eq(titles.size(), 3, "row-a, row-b and the nested card-row each get a title")
	h.check(titles[0] != titles[1], "each instance owns its clone")


func test_clones_get_fresh_ids_and_entry_offsets() -> void:
	var doc := _main()
	var ids := {}
	var dup := false
	for el in doc.root.walk():
		if ids.has(el.id):
			dup = true
		ids[el.id] = true
	h.eq(dup, false, "every element id is unique after expansion")
	var at := doc.source.find('<ui:Instance template="Row" name="row-a"')
	var title: UxmlElement = _named(doc, "title")[0]
	h.eq(title.open_tag_start, at, "clone offsets point at the entry <Instance>")
	for a in title.attributes:
		h.check(int(a["offset"]) >= at and int(a["offset"]) < doc.source.length(),
			"clone attribute %s offset is inside the entry file" % a["name"])
	h.check(doc.path_of(title).ends_with("components/Row.uxml"), "clone remembers its file")
	h.eq(doc.path_of(_named(doc, "outside")[0]), doc.path, "entry elements belong to the entry file")


func test_template_styles_scoped_and_loaded_once() -> void:
	var doc := _main()
	var row_a: UxmlElement = _named(doc, "row-a")[0]
	var title: UxmlElement = _named(doc, "title")[0]
	h.eq(_style(doc, title, "font-size"), "30px", "template root sheet applies inside the instance")
	h.check(_style(doc, _named(doc, "outside")[0], "font-size") != "30px",
		"template root sheet does not leak outside the instance")
	h.eq(_style(doc, row_a, "flex-direction"), "row", ":root in a template sheet is the TemplateContainer")
	h.eq(_style(doc, row_a, "height"), "40px", "entry sheet styles the TemplateContainer")
	var row_sheets := 0
	var row_index := -1
	for sh in doc.sheets:
		if String(sh["origin"]).ends_with("components/row.uss"):
			row_sheets += 1
			row_index = sh["index"]
	h.eq(row_sheets, 1, "a template sheet loads once")
	var scopes: Array = []
	for sr in doc.style_roots:
		if sr["sheet"] == row_index:
			scopes.append(sr["scope"])
	h.eq(scopes.size(), 3, "one scope per Row instance (row-a, row-b, card-row)")
	h.check(scopes.has(row_a), "scope is the instance's TemplateContainer")
	# A nested <Style> scopes to its cloned parent.
	h.eq(_style(doc, _named(doc, "body-label")[0], "-unity-font-style"), "bold", "nested template sheet applies")
	h.eq(_style(doc, _named(doc, "card-content")[0], "-unity-font-style"), "bold",
		"content placed in the content-container is inside that sheet's scope")
	h.eq(_style(doc, _named(doc, "card-slotted")[0], "-unity-font-style"), null,
		"nested template sheet stays inside its element")


func test_attribute_overrides() -> void:
	var doc := _main()
	var titles := _named(doc, "title")
	h.eq(titles[0].get_attribute("text"), "Alpha", "override sets text in row-a")
	h.eq(titles[0].get_attribute("tooltip"), "first", "override adds a missing attribute")
	h.eq(titles[1].get_attribute("text"), "Beta", "row-b has its own override")
	h.eq(titles[1].get_attribute("tooltip"), null, "row-a's override does not reach row-b")
	h.eq(titles[1].get_attribute("style"), null, "style override is ignored")
	h.eq(titles[1].get_attribute("class"), null, "class override is ignored")
	var ignored := _of_kind(doc, "override-ignored")
	h.eq(ignored.size(), 2, "style and class overrides are diagnosed")
	h.check(ignored.size() > 0 and String(ignored[0]["message"]).find("Unity ignores") >= 0,
		"the message says Unity ignores them")
	var missing := _of_kind(doc, "override-target-missing")
	h.eq(missing.size(), 1, "missing override target is diagnosed")
	if missing.size() == 1:
		h.eq(missing[0]["file"], doc.path, "missing target reported in the entry file")
		h.eq(missing[0]["line"], _line(doc.source, 'element-name="no-such-element"'), "at the AttributeOverrides line")
		h.check(String(missing[0]["message"]).find("title") >= 0, "message lists the available names")
	# Nested: the outer instance's override beats the inner template's.
	h.eq(titles[2].get_attribute("text"), "Outer", "shallowest override wins")
	h.eq(titles[2].get_attribute("tooltip"), "inner", "inner override still applies where the outer is silent")


func test_content_container_and_slots() -> void:
	var doc := _main()
	var content: UxmlElement = _named(doc, "card-content")[0]
	var slotted: UxmlElement = _named(doc, "card-slotted")[0]
	h.eq(_parent_of(doc, content).get_attribute("name"), "card-body", "Instance children go to the content-container")
	var body: UxmlElement = _named(doc, "card-body")[0]
	h.eq(body.children.back(), content, "after the template's own children")
	h.eq(_parent_of(doc, slotted).get_attribute("name"), "card-header", "slot child goes to its slot-name element")
	# No content-container: children are appended to the TemplateContainer.
	var d := _inline('<ui:Template name="T" src="t.uxml" /><ui:Instance template="T" name="inst"><ui:Label name="extra" /></ui:Instance>',
		{"t.uxml": '<ui:VisualElement name="t-root" />'}, "plain")
	var inst: UxmlElement = _named(d, "inst")[0]
	h.eq(inst.children.size(), 2, "template child plus instance child")
	h.eq(inst.children[0].get_attribute("name"), "t-root", "template content first")
	h.eq(inst.children[1].get_attribute("name"), "extra", "instance child appended to the container")
	h.eq(d.warnings.size(), 0, "clean template use has no diagnostics")


func test_unresolved_and_undeclared() -> void:
	var doc := _main()
	var unresolved: Array = []
	for w in doc.warnings:
		if String(w["message"]).find('<Template name="Gone"') >= 0:
			unresolved.append(w)
	h.eq(unresolved.size(), 1, "unresolved src is diagnosed once per declaration")
	if unresolved.size() == 1:
		h.eq(unresolved[0]["kind"], "missing-file", "resolver kind is kept")
		h.eq(unresolved[0]["file"], doc.path, "reported in the entry file")
		h.eq(unresolved[0]["line"], _line(doc.source, 'name="gone-a"'), "at the Instance line")
		h.check(int(unresolved[0]["column"]) > 1, "with a column")
	var gone: UxmlElement = _named(doc, "gone-b")[0]
	h.eq(gone.local, "TemplateContainer", "an unresolved instance stays an empty container")
	h.eq(gone.children.size(), 0, "with no content")
	var und := _of_kind(doc, "template-not-declared")
	h.eq(und.size(), 1, "undeclared template name is diagnosed")
	if und.size() == 1:
		h.eq(und[0]["file"], doc.path, "in the entry file")
		h.eq(und[0]["line"], _line(doc.source, 'template="Undeclared"'), "at the Instance line")


func test_template_file_diagnostics_name_that_file() -> void:
	var doc := _main()
	var in_broken: Array = []
	for w in doc.warnings:
		if String(w["file"]).ends_with("components/Broken.uxml"):
			in_broken.append(w)
	var kinds: Array = []
	for w in in_broken:
		kinds.append(w["kind"])
	h.check(kinds.has("malformed"), "template parse errors are reported against the template file")
	h.check(kinds.has("unsupported-attribute"), "template attribute checks name the template file")
	var style_problem := false
	for w in in_broken:
		if String(w["message"]).find("<Style> element is missing its src") >= 0:
			style_problem = true
			h.eq(w["line"], 4, "a broken template <Style> keeps its own line")
	h.check(style_problem, "a broken template <Style> is reported against the template file")
	var in_main := 0
	for w in doc.warnings:
		if String(w["message"]).find("<Style> element is missing") >= 0 and w["file"] == doc.path:
			in_main += 1
	h.eq(in_main, 0, "the cloned <Style> is not reported again in the entry file")


func test_template_cycles_terminate() -> void:
	var doc := UxmlLoader.load_file("Assets/UI/cycle/Cycle.uxml", ROOT)
	var cycles := _of_kind(doc, "template-cycle")
	h.eq(cycles.size(), 2, "A -> B -> A and Self -> Self are both diagnosed")
	var files: Array = []
	for c in cycles:
		files.append(String(c["file"]).get_file())
	h.check(files.has("B.uxml"), "the A/B cycle is reported at the Instance in B.uxml")
	h.check(files.has("Self.uxml"), "self-reference is reported in Self.uxml")
	h.eq(_named(doc, "in-a").size(), 1, "A expands once")
	h.eq(_named(doc, "in-b").size(), 1, "B expands once")
	h.eq(_named(doc, "b-to-a")[0].children.size(), 0, "the cyclic instance stays empty")


func test_template_depth_limit() -> void:
	for last in [31, 32]:
		var files := {}
		for i in last:
			files["%d.uxml" % i] = '<ui:Template name="T" src="%d.uxml" /><ui:Instance template="T" />' % (i + 1)
		files["%d.uxml" % last] = '<ui:VisualElement name="leaf" />'
		var d := _inline('<ui:Template name="T" src="0.uxml" /><ui:Instance template="T" />',
			files, "depth%d" % last)
		var kinds: Array = []
		for w in d.warnings:
			kinds.append(w["kind"])
		if last == 31:
			h.eq(kinds.has("template-depth-exceeded"), false, "32 nested instances expand")
			h.eq(_named(d, "leaf").size(), 1, "the leaf at depth 32 is present")
		else:
			h.eq(kinds.has("template-depth-exceeded"), true, "the 33rd nested instance is diagnosed")
			h.eq(kinds.has("template-cycle"), false, "depth is not called a cycle")
			h.eq(_named(d, "leaf").size(), 0, "nothing past the limit expands")


func test_misplaced_template_syntax() -> void:
	var d := _inline(
		'<ui:VisualElement><ui:Template name="T" src="t.uxml" /></ui:VisualElement>'
		+ '<ui:AttributeOverrides element-name="x" text="y" />'
		+ '<ui:Instance name="no-template" />',
		{"t.uxml": '<ui:VisualElement />'}, "misplaced")
	var malformed := 0
	for w in d.warnings:
		if w["kind"] == "malformed":
			malformed += 1
	h.eq(malformed, 3, "nested <Template>, stray <AttributeOverrides>, <Instance> without template")
	for el in d.root.walk():
		h.check(not (el.local in ["Template", "AttributeOverrides"]), "%s removed" % el.local)


func test_documents_without_templates_unchanged() -> void:
	var doc := UxmlLoader.load_file("Assets/UI/Menu.uxml", "res://tests/fixtures/menu")
	h.eq(doc.element_paths.size(), 0, "no template, no clones")
	h.eq(UxmlTemplates.has_template_syntax(doc.root), false, "fast path: nothing to expand")


func test_runtime_reaches_names_inside_instances() -> void:
	var ui := UxmlDocument.new()
	h.root.add_child(ui)
	ui.size = Vector2(400, 600)
	ui.load_document("Assets/UI/Main.uxml", ROOT)
	await h.process_frame
	var title := ui.get_element("title") as Label
	h.check(title != null, "get_element finds a name inside an instance")
	if title != null:
		h.eq(title.text, "Alpha", "first instance wins, with its override applied")
	var row_a := ui.get_element("row-a")
	h.check(row_a is UxmlBox, "TemplateContainer is a plain UxmlBox")
	if row_a != null:
		h.check(absf(row_a.size.y - 40.0) < 0.5, "entry USS lays out the container (%s)" % row_a.size.y)
	var content := ui.get_element("card-content")
	h.check(content != null and content.get_parent() == ui.get_element("card-body"),
		"content-container placement reaches the control tree")
	var dup := 0
	for d in ui.diagnostics:
		if d["kind"] == "duplicate-name":
			dup += 1
			h.eq(d["file"], ui._doc.path, "duplicate-name points into the entry file")
	h.check(dup >= 2, "repeated instance names are diagnosed (%d)" % dup)
	h.root.remove_child(ui)
	ui.queue_free()
