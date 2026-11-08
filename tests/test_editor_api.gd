extends RefCounted
## The tool APIs an editor uses (docs/design.md, "Editor APIs"): loads with
## a caller resolver, element handles, the source offset contract, partial
## reloads, cascade provenance, forced pseudo-states, transition snapshot
## and seek, the hit test, the element catalog, template instances, end
## offsets and severities on diagnostics, drag and drop of collection items,
## element rectangles in another element's space, text and display updates
## without a needless layout, context menus, stylesheet reloads that follow
## the edit, field values without a restyle, runtime classes, the end and the
## preview of transitions, the public helpers, placeholder elision and the
## split view signal. Scenarios that read cascade, layout or
## runtime state run on the native and the GDScript paths, and the two
## traces must be equal.

const ROOT := "user://uxml_editor_api_tests"

var h = null


func _init(harness) -> void:
	h = harness


## A resolver that reads open buffers before files (an editor's unsaved
## text), keyed by canonical path.
class MemResolver extends UxmlResourceResolver:
	var files := {}
	var reads: Array = []

	func _init(root: String) -> void:
		super(root)

	func put(path: String, text: String) -> void:
		files[UxmlResourceResolver.collapse_path(path)] = text

	func resolve_text(reference: String, from: String = "") -> Dictionary:
		var r := resolve(reference, from)
		if r["ok"]:
			var k := UxmlResourceResolver.collapse_path(String(r["path"]))
			reads.append(k)
			if files.has(k):
				return {"ok": true, "path": r["path"], "text": files[k], "diagnostic": {}}
		return super(reference, from)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


const UXML_HEAD := '<ui:UXML xmlns:ui="UnityEngine.UIElements" xmlns:uie="UnityEditor.UIElements">'


## A document of `body` and `uss` written under ROOT/`tag`, loaded from file.
func _mk(tag: String, body: String, uss: String, size := Vector2(400, 300)) -> UxmlDocument:
	var dir := "%s/%s" % [ROOT, tag]
	_write(dir + "/Assets/UI/t.uss", uss)
	_write(dir + "/Assets/UI/t.uxml", UXML_HEAD + '<Style src="t.uss" />%s</ui:UXML>' % body)
	var doc := UxmlDocument.new()
	doc.transitions_manual = true
	h.root.add_child(doc)
	doc.size = size
	doc.load_document("Assets/UI/t.uxml", dir)
	return doc


func _unload(doc: UxmlDocument) -> void:
	if doc.get_parent() != null:
		doc.get_parent().remove_child(doc)
	doc.free()


## Runs `body.call() -> Array` on the native path and on the GDScript path
## (cascade, layout and parsers); the two traces must be equal.
func _both(body: Callable, what: String) -> Array:
	var native_ok := ClassDB.class_exists("UxmlNativeCascade")
	var saved := [UssCascade.use_native, UxmlDocument.use_native_layout,
		UxmlParser.use_native, UssParser.use_native]
	var traces: Array = []
	for native in ([true, false] if native_ok else [false]):
		UssCascade.use_native = native
		UxmlDocument.use_native_layout = native
		UxmlParser.use_native = native
		UssParser.use_native = native
		traces.append(await body.call())
	UssCascade.use_native = saved[0]
	UxmlDocument.use_native_layout = saved[1]
	UxmlParser.use_native = saved[2]
	UssParser.use_native = saved[3]
	if traces.size() == 2:
		_same(traces[1], traces[0], "%s: the GDScript trace equals the native trace" % what)
	return traces[0]


func _same(a: Array, b: Array, msg: String) -> void:
	if a == b:
		h.check(true, msg)
		return
	var k := 0
	while k < mini(a.size(), b.size()) and str(a[k]) == str(b[k]):
		k += 1
	h.check(false, "%s -- %d vs %d entries, first difference at %d:\n  %s\n  %s" % [
		msg, a.size(), b.size(), k, a[k] if k < a.size() else "<end>",
		b[k] if k < b.size() else "<end>"])


## Text of a value with element objects replaced by their tag and offset
## (each load has its own element objects).
static func _txt(v) -> String:
	if v is UxmlElement:
		return "<%s@%d>" % [v.tag(), v.open_tag_start]
	if v is Dictionary:
		var parts: PackedStringArray = []
		for k in v:
			parts.append("%s: %s" % [k, _txt(v[k])])
		return "{" + ", ".join(parts) + "}"
	if v is Array:
		var parts2: PackedStringArray = []
		for x in v:
			parts2.append(_txt(x))
		return "[" + ", ".join(parts2) + "]"
	return str(v)


## The first authored element named `n` (template clones repeat names).
static func _el(doc: UxmlDocument, n: String) -> UxmlElement:
	for el in doc.get_document_model().root.walk():
		if el.part_of == null and el.get_attribute("name") == n:
			return el
	return null


## Run restyles until the post-layout updates (scrollers, pending scroll
## offsets) have landed.
static func _settle(doc: UxmlDocument) -> void:
	for k in 4:
		doc.relayout()
		doc._restyle_now()


## Sheet indices depend on load order (a reload appends new imports).
static func _no_sheet(t: String) -> String:
	return RegEx.create_from_string("sheet: [0-9]+").sub(t, "sheet: #", true)


func _diag_set(doc: UxmlDocument) -> Array:
	var out: Array = []
	for d in doc.diagnostics:
		out.append("%s|%s|%s|%d" % [d.get("kind", ""), d.get("file", ""), d.get("message", ""), int(d.get("offset", -1))])
	out.sort()
	return out


# ---------------------------------------------------------------------------
# R1: loads with a caller resolver
# ---------------------------------------------------------------------------

func test_load_source_reads_through_the_resolver() -> void:
	var dir := ROOT + "/r1"
	DirAccess.make_dir_recursive_absolute(dir + "/Assets/UI")
	var res := MemResolver.new(dir)
	res.put(dir + "/Assets/UI/a.uss", '@import "b.uss"; .x { color: rgb(255, 0, 0); }')
	res.put(dir + "/Assets/UI/b.uss", '.x { width: 33px; }')
	var doc := UxmlDocument.new()
	h.root.add_child(doc)
	doc.size = Vector2(200, 100)
	var src := UXML_HEAD + '<Style src="a.uss" /><ui:Label name="l" class="x" text="t" /></ui:UXML>'
	h.eq(doc.load_source(src, dir + "/Assets/UI/v.uxml", "", res), OK, "load_source with a resolver")
	h.eq(String(doc.get_computed_style("l")["color"]["value"]), "rgb(255, 0, 0)", "the <Style> sheet comes from the resolver")
	h.eq(String(doc.get_computed_style("l")["width"]["value"]), "33px", "the @import comes from the resolver")
	h.check(res.reads.has(UxmlResourceResolver.collapse_path(dir + "/Assets/UI/b.uss")), "the resolver read the import")
	# reload() keeps the resolver: an edited buffer shows.
	res.put(dir + "/Assets/UI/a.uss", '.x { color: rgb(0, 0, 255); }')
	h.eq(doc.reload(), OK, "reload of a source load")
	h.eq(String(doc.get_computed_style("l")["color"]["value"]), "rgb(0, 0, 255)", "reload reads through the same resolver")
	# The entry text itself can come from the resolver too.
	res.put(dir + "/Assets/UI/v.uxml", src.replace('text="t"', 'text="from buffer"'))
	h.eq(doc.reload(), OK, "reload rereads the virtual path through the resolver")
	h.eq(String(_el(doc, "l").get_attribute("text")), "from buffer", "the entry text of the resolver wins over the old text")
	_unload(doc)


func test_load_document_with_resolver_and_default() -> void:
	var dir := ROOT + "/r1b"
	DirAccess.make_dir_recursive_absolute(dir + "/Assets/UI")
	var res := MemResolver.new(dir)
	res.put(dir + "/Assets/UI/only.uxml", UXML_HEAD + '<ui:Label name="m" style="height: 12px;" /></ui:UXML>')
	var doc := UxmlDocument.new()
	h.root.add_child(doc)
	h.eq(doc.load_document("Assets/UI/only.uxml", "", res), OK, "a document that exists only in the resolver loads")
	h.eq(String(doc.get_computed_style("m")["height"]["value"]), "12px", "its style applies")
	h.eq(doc.reload(), OK, "reload keeps the resolver of load_document")
	h.check(doc.get_element("m") != null, "the element is back after reload")
	# Without a resolver nothing changes: the file must exist.
	h.eq(doc.load_document("Assets/UI/only.uxml", dir), ERR_FILE_CANT_OPEN, "without the resolver the file is missing")
	# A source load without a resolver reloads its own text.
	h.eq(doc.load_source(UXML_HEAD + '<ui:Label name="s" /></ui:UXML>'), OK, "plain load_source")
	h.eq(doc.reload(), OK, "reload of a plain load_source loads the same text again")
	h.check(doc.get_element("s") != null, "the element of the text is back")
	_unload(doc)


# ---------------------------------------------------------------------------
# R2: element handles
# ---------------------------------------------------------------------------

func test_element_handles() -> void:
	var body := func():
		var doc := _mk("r2", '<ui:VisualElement name="box"><ui:Label text="anon" /><ui:TextField label="L" />'
			+ '<ui:Toggle text="tog" /></ui:VisualElement>', ".l { color: red; }")
		var model := doc.get_document_model()
		var out: Array = []
		h.check(model != null and model.root != null, "get_document_model")
		var box := _el(doc, "box")
		var anon: UxmlElement = box.children[0]
		var tf: UxmlElement = box.children[1]
		var tog: UxmlElement = box.children[2]
		h.eq(doc.get_control_for(box), doc.get_element("box"), "get_control_for equals get_element for a named element")
		var lc := doc.get_control_for(anon)
		h.check(lc is Label, "an element without a name has its control")
		h.eq(doc.get_element_for(lc), anon, "get_element_for inverts get_control_for")
		var nat := doc.get_native_for(tf)
		h.check(nat is LineEdit, "get_native_for gives the interactive native of a TextField")
		var back := doc.get_element_for(nat)
		h.check(back != null, "a native maps back to an element")
		var top := back
		while top != null and top.part_of != null:
			top = top.part_of
		h.eq(top, tf, "the element of a native is the TextField or one of its parts")
		h.eq(doc.get_parent_element(anon), box, "get_parent_element")
		h.eq(doc.get_parent_element(model.root), null, "the root has no parent")
		h.eq(doc.get_computed_style_for(box), doc.get_computed_style("box"), "get_computed_style_for")
		doc.set_element_state_for(anon, "hover", true)
		doc._restyle_now()
		h.check(doc._states.get(anon, {}).has("hover"), "set_element_state_for sets the state")
		h.check(doc.get_element_for(doc.get_native_for(tog)) != null, "a Toggle's native maps back")
		var stray := Control.new()  # freed below: an unparented Control is never freed for us
		h.eq(doc.get_element_for(stray), null, "a control outside the document")
		stray.free()
		out.append(_txt(doc.get_computed_style_for(anon)))
		out.append(doc.get_control_for(tf).size)
		# An element of an earlier load is not of this document.
		doc.reload()
		h.eq(doc.get_control_for(anon), null, "an element of an earlier load has no control")
		h.eq(doc.get_computed_style_for(anon), {}, "nor a computed style")
		_unload(doc)
		return out
	var trace := await _both(body, "element handles")
	h.check(not trace.is_empty(), "handles traced")


# ---------------------------------------------------------------------------
# R3: source offsets
# ---------------------------------------------------------------------------

## Every .uxml file under `dir`.
static func _uxml_files(dir: String, out: Array) -> Array:
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".uxml"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		_uxml_files(dir.path_join(sub), out)
	return out


static func _offsets(root: UxmlElement) -> Array:
	var out: Array = []
	for el in root.walk():
		var attrs: Array = []
		for a in el.attributes:
			attrs.append([a["name"], a["offset"]])
		out.append([el.tag(), el.open_tag_start, el.open_tag_end, el.source_end, attrs])
	return out


func test_source_offset_contract() -> void:
	var files := _uxml_files("res://tests/fixtures", [])
	_uxml_files("res://bench/parity/cases", files)
	h.check(files.size() > 100, "the contract is checked on %d fixtures" % files.size())
	var native_ok := ClassDB.class_exists("UxmlNativeParser")
	var saved: bool = UxmlParser.use_native
	var bad := []
	var bad_agree := []
	for f in files:
		var text := FileAccess.get_file_as_string(f)
		UxmlParser.use_native = false
		var gd: UxmlElement = UxmlParser.new().parse(text, f)["root"]
		if native_ok:
			UxmlParser.use_native = true
			var nat: UxmlElement = UxmlParser.new().parse(text, f)["root"]
			if _offsets(nat) != _offsets(gd):
				bad_agree.append(f)
		for el: UxmlElement in gd.walk():
			if el == gd and el.local.is_empty():
				continue  # recovery root of a document without <UXML>
			var s := el.open_tag_start
			var ok := text.substr(s, 1) == "<" and text.substr(s + 1, el.tag().length()) == el.tag()
			var close := text.substr(el.open_tag_end - 1, 1)
			ok = ok and el.open_tag_end > s and (close == ">" or el.open_tag_end == text.length())
			ok = ok and el.source_end >= el.open_tag_end and el.source_end <= text.length()
			for a in el.attributes:
				var an: String = a["name"]
				if text.substr(int(a["offset"]), an.length()) != an:
					ok = false
			if not ok:
				bad.append("%s %s@%d" % [f.get_file(), el.tag(), s])
				break
	UxmlParser.use_native = saved
	h.eq(bad, [], "open_tag_start is the `<` of the tag, open_tag_end past `>`, attribute offsets at the name")
	h.eq(bad_agree, [], "the native and the GDScript parser give the same offsets")


func test_runtime_offsets_and_template_offsets() -> void:
	var doc := UxmlDocument.new()
	h.root.add_child(doc)
	doc.load_document("Assets/UI/Main.uxml", "res://tests/fixtures/templates")
	var model := doc.get_document_model()
	var raw: UxmlElement = UxmlParser.new().parse(model.source, model.path)["root"]
	var raw_offs := {}
	for el in raw.walk():
		raw_offs[el.open_tag_start] = el.tag()
	var mism := 0
	var outside := _el(doc, "outside")
	h.eq(raw_offs.get(outside.open_tag_start), outside.tag(), "an authored element keeps the parser offset at runtime")
	for el in model.root.walk():
		if el.part_of != null or model.element_paths.has(el) or el.local == "TemplateContainer":
			continue
		if raw_offs.get(el.open_tag_start) != el.tag():
			mism += 1
	h.eq(mism, 0, "every authored entry-file element keeps its offset")
	# Template clones: path_of gives the template file, source_offset_of the
	# offset in it; instance_of the TemplateContainer.
	var row_a := _el(doc, "row-a")
	h.eq(row_a.local, "TemplateContainer", "an Instance becomes a TemplateContainer")
	h.eq(model.instance_of(row_a), null, "an entry-file instance has no instance")
	var row: UxmlElement = row_a.children.filter(func(c): return c.get_attribute("name") == "row")[0]
	h.eq(model.instance_of(row), row_a, "a clone's instance is its TemplateContainer")
	h.check(model.path_of(row).ends_with("components/Row.uxml"), "path_of a clone is the template file")
	var rsrc := FileAccess.get_file_as_string(model.path_of(row))
	var ro := model.source_offset_of(row)
	h.eq(rsrc.substr(ro, 15), '<ui:VisualEleme', "source_offset_of a clone is its `<` in the template file")
	h.eq(row.open_tag_start, row_a.open_tag_start, "a clone's open_tag_start is the entry-file instance's")
	var title: UxmlElement = row.children[0]
	h.eq(model.instance_of(title), row_a, "a nested clone answers its instance")
	# Nested template: Row inside Card.
	var card_a := _el(doc, "card-a")
	var card_row: UxmlElement = null
	for el in card_a.walk():
		if el.get_attribute("name") == "card-row":
			card_row = el
	h.eq(model.instance_of(card_row), card_a, "the inner Instance is a clone of the outer template")
	var inner_title: UxmlElement = null
	for el in card_row.walk():
		if el.get_attribute("name") == "title":
			inner_title = el
	h.eq(model.instance_of(inner_title), card_row, "the innermost instance first")
	h.eq(model.instance_of(model.instance_of(inner_title)), card_a, "and the entry-file instance next")
	var content := _el(doc, "card-content")
	h.eq(model.instance_of(content), null, "an Instance child authored in the entry file has no instance")
	_unload(doc)


# ---------------------------------------------------------------------------
# R4: partial reload
# ---------------------------------------------------------------------------

const R4_BODY := '<ui:VisualElement name="root-box" class="a"><ui:Label name="lab" class="t" text="hi" />'\
	+ '<ui:Button name="btn" text="b" /><ui:ScrollView name="sv" style="height: 50px;">'\
	+ '<ui:VisualElement style="height: 400px;" /></ui:ScrollView></ui:VisualElement>'
const R4_USS := '.a { padding: 4px; background-color: rgb(10, 20, 30); } .t { color: rgb(200, 0, 0); font-size: 13px; }'\
	+ ' .b { width: 77px; } #btn:hover { color: rgb(0, 200, 0); }'


func test_reload_stylesheet() -> void:
	var body := func():
		var doc := _mk("r4s", R4_BODY, R4_USS)
		var out: Array = []
		var origin := String(doc.get_computed_style("lab")["color"]["origin"]["file"])
		var lab_ctl := doc.get_element("lab")
		h.eq(doc.reload_stylesheet("nope.uss", ""), ERR_DOES_NOT_EXIST, "an unknown origin")
		h.eq(doc.reload_stylesheet(UxmlTheme.DEFAULT, ""), ERR_DOES_NOT_EXIST, "a theme sheet is not reloadable")
		var uss2 := R4_USS.replace("rgb(200, 0, 0)", "rgb(1, 2, 3)") + ' @import "extra.uss"; .t { width: 10em; }'
		_write(ROOT + "/r4s/Assets/UI/extra.uss", ".a { margin-left: 9px; }")
		h.eq(doc.reload_stylesheet(origin, uss2), OK, "reload_stylesheet")
		h.eq(doc.get_element("lab"), lab_ctl, "the controls stay")
		out.append(_no_sheet(_txt(doc.get_computed_style("lab"))))
		out.append(_no_sheet(_txt(doc.get_computed_style("root-box"))))
		out.append(_diag_set(doc))
		# Equal to a fresh load of the new text.
		_write(ROOT + "/r4s/Assets/UI/t.uss", uss2)
		var fresh := UxmlDocument.new()
		h.root.add_child(fresh)
		fresh.size = doc.size
		fresh.load_document("Assets/UI/t.uxml", ROOT + "/r4s")
		_settle(fresh)
		_settle(doc)
		h.eq(_no_sheet(_txt(doc.get_computed_style("root-box"))), _no_sheet(_txt(fresh.get_computed_style("root-box"))), "the computed style equals a fresh load")
		h.eq(_diag_set(doc), _diag_set(fresh), "the diagnostics equal a fresh load")
		var tp = load("res://tests/test_parking.gd")
		_same(tp.snapshot(doc, true), tp.snapshot(fresh, true), "the drawn controls equal a fresh load")
		_unload(fresh)
		# An invalid unit fails the sheet; fixing it brings the rules back.
		h.check(String(doc.get_computed_style("lab").get("color", {}).get("value", "")) != "rgb(1, 2, 3)",
			"a sheet with an unsupported unit has no rules")
		h.eq(doc.reload_stylesheet(origin, uss2.replace("10em", "10px")), OK, "reload the fixed sheet")
		h.eq(String(doc.get_computed_style("lab")["color"]["value"]), "rgb(1, 2, 3)", "the fixed sheet applies")
		var malformed := 0
		for d in doc.diagnostics:
			if d["kind"] == "malformed" and String(d["message"]).contains("10em"):
				malformed += 1
		h.eq(malformed, 0, "the diagnostic of the old text is gone")
		out.append(_txt(doc.get_computed_style("lab")))
		_unload(doc)
		return out
	await _both(body, "reload_stylesheet")


func test_replace_source_in_place() -> void:
	var body := func():
		var doc := _mk("r4r", R4_BODY, R4_USS)
		var out: Array = []
		var model := doc.get_document_model()
		var lab := _el(doc, "lab")
		var btn := _el(doc, "btn")
		var lab_ctl := doc.get_control_for(lab)
		doc.set_forced_states(btn, PackedStringArray(["hover"]))
		_settle(doc)
		doc.set_scroll_offset("sv", Vector2(0, 30))
		_settle(doc)
		var old_text := model.source
		var new_text := old_text.replace('class="t"', 'class="t b"  style="font-size: 20px;" ')\
			.replace("<ui:Button", "<!-- a comment -->\n  <ui:Button")
		h.eq(doc.replace_source(new_text), OK, "replace_source")
		h.eq(doc.get_last_replace_mode(), "in-place", "class, style, comments and whitespace edit in place")
		h.eq(doc.get_document_model(), model, "the model stays")
		h.eq(doc.get_control_for(lab), lab_ctl, "the controls stay")
		h.eq(doc.get_forced_states(btn), PackedStringArray(["hover"]), "forced states stay")
		h.eq(doc.get_scroll_offset("sv"), Vector2(0, 30), "the scroll offset stays")
		h.eq(model.source, new_text, "the model has the new text")
		var raw: UxmlElement = UxmlParser.new().parse(new_text, model.path)["root"]
		var want := {}
		for el in raw.walk():
			want[el.get_attribute("name")] = [el.open_tag_start, el.open_tag_end, el.source_end]
		h.eq([btn.open_tag_start, btn.open_tag_end, btn.source_end], want["btn"], "element offsets move to the new text")
		h.eq(new_text.substr(btn.attributes[0]["offset"], 4), "name", "attribute offsets move too")
		h.eq(String(lab.get_attribute("style")), "font-size: 20px;", "the style attribute changed")
		out.append(_txt(doc.get_computed_style("lab")))
		out.append(doc.get_control_for(lab).size)
		# Equal to a fresh load of the new text (forced state and scroll too).
		_write(ROOT + "/r4r/Assets/UI/t.uxml", new_text)
		var fresh := UxmlDocument.new()
		fresh.transitions_manual = true
		h.root.add_child(fresh)
		fresh.size = doc.size
		fresh.load_document("Assets/UI/t.uxml", ROOT + "/r4r")
		fresh.set_forced_states(_el(fresh, "btn"), PackedStringArray(["hover"]))
		_settle(fresh)
		fresh.set_scroll_offset("sv", Vector2(0, 30))
		_settle(fresh)
		_settle(doc)
		var tp = load("res://tests/test_parking.gd")
		_same(tp.snapshot(doc, true), tp.snapshot(fresh, true), "in place draws as a fresh load")
		h.eq(_diag_set(doc), _diag_set(fresh), "in place has the diagnostics of a fresh load")
		for n in ["root-box", "lab", "btn", "sv"]:
			h.eq(_txt(doc.get_computed_style(n)), _txt(fresh.get_computed_style(n)), "computed style of %s" % n)
		_unload(fresh)
		# A structural edit loads again, keeping state by tree position.
		var grown := new_text.replace('<ui:Button name="btn"', '<ui:Label text="new" /><ui:Button name="btn"')
		h.eq(doc.replace_source(grown), OK, "a structural edit")
		h.eq(doc.get_last_replace_mode(), "reload", "an added element loads again")
		_settle(doc)
		var btn2 := _el(doc, "btn")
		h.check(btn2 != btn, "new elements")
		h.eq(doc.get_forced_states(btn2), PackedStringArray(["hover"]), "forced state follows the name")
		h.eq(doc.get_scroll_offset("sv"), Vector2(0, 30), "the ScrollView kept its offset (by name)")
		var spacer: UxmlElement = _el(doc, "root-box").children[1]
		h.eq(spacer.local, "Label", "the new unnamed Label")
		doc.set_forced_states(spacer, PackedStringArray(["hover"]))
		var renamed := grown.replace('name="lab"', 'name="lab2"')
		h.eq(doc.replace_source(renamed), OK, "a renamed element")
		h.eq(doc.get_last_replace_mode(), "reload", "a name edit loads again")
		h.eq(doc.get_forced_states(_el(doc, "btn")), PackedStringArray(["hover"]), "forced state kept by name")
		h.eq(doc.get_forced_states(_el(doc, "root-box").children[1]), PackedStringArray(["hover"]),
			"an unnamed element keeps its state by tree position")
		out.append(_txt(doc.get_computed_style("btn")))
		# A runtime-changed class cannot be edited in place.
		doc.set_class("lab2", "zzz")
		doc._restyle_now()
		h.eq(doc.replace_source(renamed.replace('class="t b"', 'class="t"')), OK, "class edit over a runtime class")
		h.eq(doc.get_last_replace_mode(), "reload", "a class the runtime changed loads again")
		_unload(doc)
		return out
	await _both(body, "replace_source")


func test_replace_source_keeps_transitions_and_focus() -> void:
	var body := func():
		var doc := _mk("r4t", '<ui:Button name="b" class="k" text="x" /><ui:Button name="c" text="y" />',
			".k { width: 100px; transition: width 1s linear; } .k:hover { width: 200px; }")
		var out: Array = []
		var b := _el(doc, "b")
		doc.set_forced_states(b, PackedStringArray(["hover"]))
		doc._restyle_now()
		doc.advance_transitions(0.5)
		out.append(_txt(doc.get_computed_style("b")["width"]))
		var c := doc.get_control_for(_el(doc, "c"))
		c.grab_focus()
		var text := doc.get_document_model().source.replace('text="y"', 'text="y"   ')
		h.eq(doc.replace_source(text.replace('class="k"', 'class="k" style="height: 20px;"')), OK, "in-place edit")
		h.eq(doc.get_last_replace_mode(), "in-place", "an inline style edit")
		h.check(doc.has_running_transitions(), "the running transition stays")
		h.eq(String(doc.get_computed_style("b")["width"]["value"]), "150px", "at its value")
		doc.advance_transitions(0.25)
		h.eq(String(doc.get_computed_style("b")["width"]["value"]), "175px", "and keeps running")
		h.check(c.has_focus(), "the focus stays")
		# A full reload moves the focus to the same position.
		var grown := doc.get_document_model().source.replace("</ui:UXML>", '<ui:Label text="z" /></ui:UXML>')
		h.eq(doc.replace_source(grown), OK, "a structural edit")
		h.eq(doc.get_last_replace_mode(), "reload", "loads again")
		var c2 := doc.get_control_for(_el(doc, "c"))
		h.check(c2 != c and c2.has_focus(), "the focus moves to the element at the same position")
		out.append(_txt(doc.get_computed_style("b")["width"]))
		_unload(doc)
		return out
	await _both(body, "replace_source transitions")


# ---------------------------------------------------------------------------
# R5: provenance
# ---------------------------------------------------------------------------

func test_explain_style() -> void:
	var body := func():
		var uss := ':root { --accent: rgb(1, 1, 1); } .p { color: rgb(9, 9, 9); }'\
			+ ' .a { margin: 5px; color: var(--accent); --accent: rgb(2, 2, 2); }'\
			+ ' .a.b { margin-top: 7px; } Label { margin-top: 1px; } #n:hover { margin-top: 11px; }'\
			+ ' .c { color: var(--missing); } .d { width: 10px; } .d.e { width: initial; }'\
			+ ' .f { font-size: 20px; } .g { font-size: 50%; }'
		var doc := _mk("r5", '<ui:VisualElement class="p f"><ui:Label name="n" class="a b" style="margin-left: 3px;" text="x" />'
			+ '<ui:Label name="m" class="c" text="y" /><ui:VisualElement name="w" class="d e" />'
			+ '<ui:Label name="g" class="g" text="z" /></ui:VisualElement>', uss)
		var out: Array = []
		var n := _el(doc, "n")
		var ex := doc.explain_style(n, "margin-top")
		out.append(_txt(ex))
		h.eq(ex.size(), 4, "four declarations set margin-top on n: %s" % _txt(ex))
		h.eq(ex[0]["value"], "7px", "the winner first")
		h.eq(ex[0]["status"], "winner", "its status")
		h.eq(ex[0]["specificity"], Vector3i(0, 2, 0), "two classes")
		h.eq(ex[1]["property"], "margin", "a longhand from a shorthand names the shorthand")
		h.eq(ex[1]["value"], "5px", "with the longhand value")
		h.eq(ex[1]["status"], "overridden", "overridden")
		h.eq(ex[2]["specificity"], Vector3i(0, 0, 1), "a type selector")
		h.eq([ex[3]["rank"], ex[3]["property"]], ["theme", "margin"], "the default theme ranks last")
		h.eq(ex[0]["origin"], doc.get_computed_style_for(n)["margin-top"]["origin"], "the winner origin is the computed origin")
		var hov := doc.explain_style(n, "margin-top", {"hover": true})
		h.eq(hov[0]["value"], "11px", "a query-only :hover")
		h.eq(hov[0]["origin"].get("states"), ["hover"], "the origin lists the states")
		h.eq(hov[0]["specificity"], Vector3i(1, 1, 0), "#n:hover")
		h.eq(String(doc.get_computed_style_for(n)["margin-top"]["value"]), "7px", "the query does not change the document")
		var inl := doc.explain_style(n, "margin-left")
		h.eq(inl[0]["rank"], "inline", "the style attribute ranks inline")
		h.eq(inl[0]["origin"], {"kind": "inline", "decl_index": 0}, "inline origin")
		var col := doc.explain_style(n, "color")
		h.eq(col[0]["value"], "rgb(2, 2, 2)", "var() substituted with the element's own custom property")
		h.eq(col[0]["declared"], "var(--accent)", "the declaration as written")
		var mc := doc.explain_style(_el(doc, "m"), "color")
		h.eq(mc[0]["status"], "dropped", "an unresolved var()")
		h.eq(mc[mc.size() - 1]["rank"], "inherited", "the value comes from the parent")
		h.eq(mc[mc.size() - 1]["winner"], true, "which is the winner")
		h.eq(_txt(mc[mc.size() - 1]["origin"]), _txt(doc.get_computed_style_for(_el(doc, "m"))["color"]["origin"]),
			"the inherited origin is the computed origin")
		var wv := doc.explain_style(_el(doc, "w"), "width")
		h.eq(wv[0]["status"], "keyword", "width: initial")
		h.eq(wv[wv.size() - 1]["rank"], "default", "falls back to the initial value")
		h.eq(wv[wv.size() - 1]["value"], "auto", "the initial width")
		var gf := doc.explain_style(_el(doc, "g"), "font-size")
		h.eq(gf[0]["value"], String(doc.get_computed_style_for(_el(doc, "g"))["font-size"]["value"]), "a percentage font-size gives the computed px")
		h.eq(doc.explain_style(n, "--accent")[0]["value"], "rgb(2, 2, 2)", "custom properties")
		out.append(_txt(mc))
		out.append(_txt(gf))
		_unload(doc)
		return out
	await _both(body, "explain_style")


## For every element and every computed property of a document, the
## explain winner gives the computed value and origin.
func test_explain_agrees_with_the_cascade() -> void:
	var body := func():
		var out: Array = []
		for pair in [["res://tests/fixtures/options", "Assets/UI/Options.uxml"],
				["res://tests/fixtures/controls", "Assets/UI/controls.uxml"],
				["res://tests/fixtures/editor", "Assets/UI/editor.uxml"]]:
			var doc := UxmlDocument.new()
			h.root.add_child(doc)
			doc.size = Vector2(800, 600)
			doc.load_document(pair[1], pair[0])
			var checked := 0
			var bad: Array = []
			for el in doc.get_document_model().root.walk():
				var st := doc.get_computed_style_for(el)
				for prop in st:
					var ex := doc.explain_style(el, prop)
					var w = null
					for e in ex:
						if e["winner"]:
							w = e
							break
					checked += 1
					if w == null or String(w["value"]) != String(st[prop]["value"]) \
							or _txt(w["origin"]) != _txt(st[prop]["origin"]):
						if bad.size() < 5:
							bad.append("%s %s: %s vs %s" % [el.tag(), prop, _txt(st[prop]), _txt(ex)])
			h.eq(bad, [], "%s: explain agrees with the computed style (%d properties)" % [pair[1], checked])
			out.append(checked)
			_unload(doc)
		return out
	await _both(body, "explain vs cascade")


# ---------------------------------------------------------------------------
# R6: forced states
# ---------------------------------------------------------------------------

func test_forced_states() -> void:
	var body := func():
		var doc := _mk("r6", '<ui:Button name="b" class="k" text="x" /><ui:VisualElement name="p"><ui:Button name="q" text="q" /></ui:VisualElement>',
			".k { color: rgb(1, 1, 1); } .k:hover { color: rgb(2, 2, 2); } .k:active { color: rgb(3, 3, 3); }"
			+ " .k:focus { color: rgb(4, 4, 4); } Button:disabled { color: rgb(5, 5, 5); }")
		var out: Array = []
		var b := _el(doc, "b")
		doc.set_forced_states(b, PackedStringArray(["hover"]))
		doc._restyle_now()
		h.eq(String(doc.get_computed_style("b")["color"]["value"]), "rgb(2, 2, 2)", "forced :hover")
		var c := doc.get_control_for(b)
		c.mouse_entered.emit()
		c.mouse_exited.emit()
		doc._restyle_now()
		h.eq(String(doc.get_computed_style("b")["color"]["value"]), "rgb(2, 2, 2)", "a real mouse_exited does not clear it")
		doc.set_forced_states(b, PackedStringArray(["hover", "active", "bogus"]))
		doc._restyle_now()
		h.eq(doc.get_forced_states(b), PackedStringArray(["hover", "active"]), "unknown states are dropped")
		h.eq(String(doc.get_computed_style("b")["color"]["value"]), "rgb(3, 3, 3)", "forced :active")
		out.append(_txt(doc.get_computed_style("b")))
		doc.set_forced_states(_el(doc, "p"), PackedStringArray(["disabled"]))
		doc._restyle_now()
		h.eq(String(doc.get_computed_style("q")["color"]["value"]), "rgb(5, 5, 5)", "forced :disabled descends")
		h.check(doc.get_native_for(_el(doc, "q")).disabled, "and disables the controls")
		doc.clear_forced_states()
		doc._restyle_now()
		h.eq(doc.get_forced_states(b), PackedStringArray(), "cleared")
		h.eq(String(doc.get_computed_style("b")["color"]["value"]), "rgb(1, 1, 1)", "back to the plain state")
		h.check(not doc.get_native_for(_el(doc, "q")).disabled, "enabled again")
		out.append(_txt(doc.get_computed_style("q")))
		_unload(doc)
		return out
	await _both(body, "forced states")


# ---------------------------------------------------------------------------
# R7: transition snapshot and seek
# ---------------------------------------------------------------------------

func test_transition_snapshot_and_seek() -> void:
	var body := func():
		var doc := _mk("r7", '<ui:VisualElement name="v" class="k" />',
			".k { width: 100px; transition: width 2s linear 1s, opacity 1s ease-in; opacity: 1; }"
			+ " .k:hover { width: 300px; opacity: 0.5; }")
		var out: Array = []
		var ends: Array = []
		doc.transition_end.connect(func(_n, p, _t): ends.append(p))
		var v := _el(doc, "v")
		h.eq(doc.get_transitions(), [], "nothing runs")
		doc.set_forced_states(v, PackedStringArray(["hover"]))
		var ts := doc.get_transitions()
		h.eq(ts.size(), 2, "two transitions after the state change")
		var w = ts.filter(func(t): return t["property"] == "width")[0]
		h.eq(w["element"], v, "the element")
		h.eq([w["from"], w["to"], w["delay"], w["duration"], w["easing"]], ["100px", "300px", 1.0, 2.0, "linear"], "width track")
		h.eq(w["elapsed"], 0.0, "just started")
		doc.seek_transitions(2.0)
		h.eq(String(doc.get_computed_style("v")["width"]["value"]), "200px", "seek 2s: 1s into a 2s track after the 1s delay")
		doc.seek_transitions(0.5)
		h.eq(String(doc.get_computed_style("v")["width"]["value"]), "100px", "seek inside the delay: the start value")
		doc.seek_transitions(10.0)
		h.eq(String(doc.get_computed_style("v")["width"]["value"]), "300px", "seek past the end: the end value")
		h.eq(String(doc.get_computed_style("v")["opacity"]["value"]), "0.5", "every transition moves")
		h.check(doc.has_running_transitions(), "still running")
		h.eq(ends, [], "no transition_end from a seek")
		doc.seek_transitions(1.5)
		h.eq(String(doc.get_computed_style("v")["width"]["value"]), "150px", "seek back")
		out.append(_txt(doc.get_transitions()))
		doc.advance_transitions(5.0)
		h.check(not doc.has_running_transitions(), "playback ends the transitions")
		ends.sort()
		h.eq(ends, ["opacity", "width"], "transition_end when playback passes the end")
		out.append(_txt(doc.get_computed_style("v")))
		_unload(doc)
		return out
	await _both(body, "transitions")


# ---------------------------------------------------------------------------
# R8: hit test
# ---------------------------------------------------------------------------

func test_element_at() -> void:
	var body := func():
		var doc := _mk("r8", '<ui:VisualElement name="a" style="position: absolute; left: 10px; top: 10px; width: 100px; height: 100px;">'
			+ '<ui:VisualElement name="a1" style="width: 50px; height: 50px;" /></ui:VisualElement>'
			+ '<ui:VisualElement name="rot" style="position: absolute; left: 200px; top: 10px; width: 100px; height: 20px; rotate: 90deg;" />'
			+ '<ui:VisualElement name="clip" style="position: absolute; left: 10px; top: 150px; width: 50px; height: 50px; overflow: hidden;">'
			+ '<ui:VisualElement name="wide" style="width: 200px; height: 20px; flex-shrink: 0;" /></ui:VisualElement>'
			+ '<ui:VisualElement name="ign" picking-mode="Ignore" style="position: absolute; left: 300px; top: 150px; width: 50px; height: 50px;">'
			+ '<ui:VisualElement name="ign-child" style="width: 10px; height: 10px;" /></ui:VisualElement>'
			+ '<ui:Toggle name="tog" text="t" style="position: absolute; left: 10px; top: 250px;" />'
			+ '<ui:VisualElement name="hid" style="position: absolute; left: 300px; top: 250px; width: 40px; height: 40px; visibility: hidden;" />',
			"", Vector2(400, 300))
		var out: Array = []
		var nm := func(p: Vector2, rp: bool, parts: bool):
			var el = doc.element_at(p, rp, parts)
			return "" if el == null else String(el.get_attribute("name")) if el.has_attribute("name") else el.local
		h.eq(nm.call(Vector2(20, 20), false, false), "a1", "the deepest element")
		h.eq(nm.call(Vector2(90, 90), false, false), "a", "its parent outside it")
		h.eq(nm.call(Vector2(395, 5), false, false), "", "only the root: null")
		# rot: 100x20 at (200,10), rotated 90deg about its center (250, 20):
		# it covers x 240..260, y -30..70.
		h.eq(nm.call(Vector2(250, 60), false, false), "rot", "a rotated element hits where it is drawn")
		h.eq(nm.call(Vector2(210, 20), false, false), "", "not where it would be without the rotation")
		h.eq(nm.call(Vector2(20, 160), false, false), "wide", "a child inside the clip")
		h.eq(nm.call(Vector2(150, 160), false, false), "", "a child outside an overflow: hidden parent is not hit")
		h.eq(nm.call(Vector2(305, 155), false, false), "ign-child", "the child of an Ignore element")
		h.eq(nm.call(Vector2(340, 190), false, false), "ign", "picking-mode is not respected by default")
		h.eq(nm.call(Vector2(340, 190), true, false), "", "picking-mode=Ignore with respect_picking")
		h.eq(nm.call(Vector2(320, 270), false, false), "", "visibility: hidden is not hit")
		var tc := doc.get_control_for(_el(doc, "tog"))
		var tp := tc.size / 2.0 + tc.position
		h.eq(nm.call(tp, false, false), "tog", "a part hit gives the control")
		var part = doc.element_at(tp, false, true)
		h.check(part != null and part.part_of != null, "include_parts gives the part")
		out.append(nm.call(Vector2(250, 60), false, false))
		out.append(_txt(part))
		_unload(doc)
		return out
	await _both(body, "element_at")


# ---------------------------------------------------------------------------
# R9: catalog
# ---------------------------------------------------------------------------

func test_catalog() -> void:
	var cat := UxmlControls.catalog()
	h.check(cat.size() >= 70, "%d elements" % cat.size())
	var names := {}
	var bad_attr: Array = []
	var bad_tag: Array = []
	var bad_enum: Array = []
	for e in cat:
		h.check(not names.has(e["name"]), "%s once" % e["name"])
		names[e["name"]] = true
		if not UssControls.is_known_control(e["name"]):
			bad_tag.append(e["name"])
		h.eq(e["editor_only"], UxmlEditorParts.TAGS.has(e["name"]), "%s editor_only" % e["name"])
		h.eq(e["namespace"], "UnityEditor.UIElements" if e["editor_only"] else "UnityEngine.UIElements", "%s namespace" % e["name"])
		var an := {}
		for a in e["attributes"]:
			if an.has(a["name"]):
				bad_attr.append("%s.%s twice" % [e["name"], a["name"]])
			an[a["name"]] = true
			if not UssControls.KNOWN_ATTRIBUTES.has(a["name"]):
				bad_attr.append("%s.%s" % [e["name"], a["name"]])
			if a["type"] == "enum" and not (a["choices"] as PackedStringArray).has(a["default"]):
				bad_enum.append("%s.%s" % [e["name"], a["name"]])
	h.eq(bad_tag, [], "every catalog element is a known control")
	h.eq(bad_attr, [], "every catalog attribute is one godot-uxml reads, once")
	h.eq(bad_enum, [], "every enum default is one of its choices")
	for t in UssControls.IMPLICIT_CLASSES:
		if t in ["TextInput", "IntegerInput", "LongInput", "FloatInput", "DoubleInput", "UnsignedIntegerInput",
				"UnsignedLongInput", "Hash128Input", "PopupTextElement", "ObjectFieldDisplay",
				"ObjectFieldSelector", "PopupField`1", "BreadcrumbItem"]:
			continue
		h.check(names.has(t), "the catalog lists %s" % t)
	var btn := UxmlControls.describe("Button")
	h.eq(btn["namespace"], "UnityEngine.UIElements", "Button namespace")
	h.check(btn["attributes"].any(func(a): return a["name"] == "text"), "Button has text")
	h.eq(UxmlControls.describe("Slider")["attributes"].filter(func(a): return a["name"] == "high-value")[0]["default"], "10", "Slider high-value default")
	h.eq(UxmlControls.describe("ScrollView")["container"], true, "ScrollView takes children")
	h.eq(UxmlControls.describe("Nope"), {}, "an unknown element")
	cat[0]["name"] = "changed"
	h.eq(UxmlControls.catalog()[0]["name"], "VisualElement", "the caller gets a copy")


# ---------------------------------------------------------------------------
# Fixes
# ---------------------------------------------------------------------------

func test_background_image_none_is_no_file() -> void:
	var doc := UxmlDocument.new()
	doc.editor_theme = "always"
	h.root.add_child(doc)
	doc.load_document("ed-toolbar.uxml", "res://bench/parity/cases")
	var bad: Array = []
	for d in doc.diagnostics:
		if String(d["message"]).contains('"none"'):
			bad.append(UxmlDiagnostic.format(d))
	h.eq(bad, [], "background-image: none (ToolbarToggle checkmark, editor skin) reports no missing file")
	_unload(doc)


func test_background_image_none_checked_at_runtime() -> void:
	var doc := UxmlDocument.new()
	doc.editor_theme = "always"
	h.root.add_child(doc)
	doc.load_document("ed-toolbar.uxml", "res://bench/parity/cases")
	var el := doc.get_element_model("tt-on")
	h.check(doc._states.get(el, {}).has("checked"), "the ToolbarToggle starts :checked")
	for on in [false, true, false, true]:
		el.set_attribute("value", "true" if on else "false")
		_settle(doc)
	h.check(doc._states.get(el, {}).has("checked"), "checked again at runtime")
	doc.set_forced_states(el, PackedStringArray(["hover", "checked"]))
	_settle(doc)
	doc.clear_forced_states()
	_settle(doc)
	var bad: Array = []
	for d in doc.diagnostics:
		if String(d["message"]).contains('"none"'):
			bad.append(UxmlDiagnostic.format(d))
	h.eq(bad, [], "a ToolbarToggle checked, unchecked and hovered at runtime reports no missing file")
	_unload(doc)


# ---------------------------------------------------------------------------
# R12: drag and drop of collection items
# ---------------------------------------------------------------------------

func _mouse(doc: UxmlDocument, pos: Vector2, button := -1, pressed := false, held := true) -> void:
	var ev: InputEvent
	if button < 0:
		var mm := InputEventMouseMotion.new()
		mm.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
		mm.position = pos
		mm.global_position = pos
		ev = mm
	else:
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_LEFT
		mb.pressed = pressed
		mb.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		mb.position = pos
		mb.global_position = pos
		ev = mb
	doc.get_viewport().push_input(ev)


## Press at `from`, move past the drag distance, then through `path`;
## release at the last point unless `release` is false.
func _drag(doc: UxmlDocument, from: Vector2, path: Array, release := true) -> void:
	_mouse(doc, from, -1, false, false)
	_mouse(doc, from, MOUSE_BUTTON_LEFT, true)
	_mouse(doc, from + Vector2(0, 1), -1)
	_mouse(doc, from + Vector2(8, 1), -1)
	for p in path:
		_mouse(doc, p, -1)
	if release:
		_mouse(doc, path[-1] if not path.is_empty() else from, MOUSE_BUTTON_LEFT, false)


## Records the drag signals of `doc` as text.
func _dnd_log(doc: UxmlDocument) -> Array:
	var log: Array = []
	doc.items_drag_started.connect(func(n, i, p): log.append("start %s %s %s" % [n, i, p]))
	doc.items_drag_updated.connect(func(n, p, t):
		log.append("update %s %s %s" % [n, p, "{}" if t.is_empty() else "%s i%d at%d %s p%s c%d m%d" % [
			t["element_name"], t["index"], t["insert_at_index"],
			["over", "between", "outside"][t["drop_position"]], t["parent_id"], t["child_index"], t["visual_mode"]]]))
	doc.items_drag_ended.connect(func(n, p, r): log.append("end %s %s %s" % [n, p, r]))
	doc.item_index_changed.connect(func(n, a, b): log.append("moved %s %s %s" % [n, a, b]))
	return log


static func _results(log: Array) -> Array:
	var out: Array = []
	for l in log:
		var s := String(l)
		if s.begins_with("end "):
			out.append(s.get_slice(" ", s.get_slice_count(" ") - 1))
	return out


func test_list_drag_and_drop() -> void:
	var body := func():
		var doc := _mk("r12a", '<ui:ListView name="lv" reorderable="true" selection-type="Multiple" fixed-item-height="20" style="position: absolute; left: 10px; top: 10px; width: 200px; height: 200px;" />'
			+ '<ui:ListView name="plain" fixed-item-height="20" style="position: absolute; left: 250px; top: 10px; width: 100px; height: 100px;" />',
			"", Vector2(400, 300))
		var items := ["a", "b", "c", "d", "e"]
		doc.set_items_source("lv", items)
		doc.set_items_source("plain", ["x", "y"])
		_settle(doc)
		var out: Array = []
		var log := _dnd_log(doc)
		var r0 := doc.get_item_rect("lv", 0)
		var r2 := doc.get_item_rect("lv", 2)
		h.eq(r2.size, Vector2(r0.size.x, 20), "an item rect is one row high")
		h.eq(r2.position.y - r0.position.y, 40.0, "rows are fixed-item-height apart")
		h.eq(doc.get_item_index_at("lv", r2.get_center()), 2, "the item at a point")
		h.eq(doc.get_item_index_at("lv", Vector2(300, 250)), -1, "no item outside the list")
		h.eq(doc.get_item_index_at("lv", r0.position + Vector2(5, 5 * 20 + 10)), -1, "no item below the last")
		h.eq(doc.get_item_rect("lv", 7), Rect2(), "no rect for an item that is not on a row")
		h.eq(doc.get_item_rect("nope", 0), Rect2(), "no rect for an unknown list")
		out.append([r0, r2])
		# Reorder a onto the top band of d: between c and d (insert 3).
		var c0 := r0.get_center()
		var r3 := doc.get_item_rect("lv", 3)
		var over3 := r3.get_center()
		var top3 := r3.position + Vector2(20, 2)
		_drag(doc, c0, [over3, top3], false)
		var d := doc.get_drag()
		h.eq(d.get("indices"), [0], "the drag takes the pressed item")
		var t: Dictionary = d.get("target", {})
		h.eq(t.get("insert_at_index"), 3, "the top band drops before the item")
		h.eq(t.get("drop_position"), UxmlDocument.DragPosition.BETWEEN_ITEMS, "between items")
		h.eq(t.get("visual_mode"), UxmlDocument.DragVisualMode.MOVE, "a reorderable list moves")
		var ov: Control = doc._dnd_overlay
		h.check(ov != null and ov.visible and (ov.get_child(0) as Control).visible, "the bar is drawn")
		if ov != null:
			h.eq(ov.position.y + (ov.get_child(0) as Control).position.y + 1.0, r3.position.y, "the bar is on the top edge of the item")
		_mouse(doc, top3, MOUSE_BUTTON_LEFT, false)
		h.eq(items, ["b", "c", "a", "d", "e"], "the bound Array moved")
		h.eq(doc.get_selected_indices("lv"), [2], "the moved item stays selected")
		h.eq(doc.get_drag(), {}, "no drag after the release")
		h.check(doc._dnd_overlay == null, "the indicator is gone")
		# The middle of an item: a list does not drop over an item.
		_drag(doc, doc.get_item_rect("lv", 0).get_center(), [doc.get_item_rect("lv", 4).get_center()])
		h.eq(items, ["b", "c", "a", "d", "e"], "a drop over an item is rejected")
		# A multiple selection moves together, to the end.
		doc.set_selection("lv", [1, 3])
		var r4 := doc.get_item_rect("lv", 4)
		_drag(doc, doc.get_item_rect("lv", 3).get_center(), [r4.position + Vector2(20, r4.size.y + 30)])
		h.eq(items, ["b", "a", "e", "c", "d"], "both selected items moved to the end, in order")
		h.eq(doc.get_selected_indices("lv"), [3, 4], "the moved items stay selected")
		# A plain click on a multiple selection selects on the release.
		doc.set_selection("lv", [0, 1])
		var c1 := doc.get_item_rect("lv", 1).get_center()
		_mouse(doc, c1, MOUSE_BUTTON_LEFT, true)
		h.eq(doc.get_selected_indices("lv"), [0, 1], "the press keeps the selection")
		_mouse(doc, c1, MOUSE_BUTTON_LEFT, false)
		h.eq(doc.get_selected_indices("lv"), [1], "the release selects the item")
		# Escape cancels.
		_drag(doc, doc.get_item_rect("lv", 0).get_center(), [top3], false)
		var key := InputEventKey.new()
		key.keycode = KEY_ESCAPE
		key.physical_keycode = KEY_ESCAPE
		key.pressed = true
		doc.get_viewport().push_input(key)
		h.eq(doc.get_drag(), {}, "Escape ends the drag")
		_mouse(doc, top3, MOUSE_BUTTON_LEFT, false)
		h.eq(items, ["b", "a", "e", "c", "d"], "a canceled drag moves nothing")
		# Outside every collection.
		_drag(doc, doc.get_item_rect("lv", 0).get_center(), [Vector2(390, 290)])
		# A list that is not reorderable does not drag.
		_drag(doc, doc.get_item_rect("plain", 0).get_center(), [doc.get_item_rect("plain", 1).get_center()])
		h.check(not log.any(func(l): return String(l).begins_with("start plain")), "no drag from a list that is not reorderable")
		h.eq(_results(log), ["dropped", "rejected", "dropped", "canceled", "outside"], "the drag results")
		out.append_array(log)
		_unload(doc)
		return out
	await _both(body, "list drag and drop")


func test_tree_drag_and_drop() -> void:
	var body := func():
		var doc := _mk("r12b", '<ui:TreeView name="tv" reorderable="true" fixed-item-height="20" style="position: absolute; left: 0; top: 0; width: 200px; height: 200px;" />'
			+ '<ui:TreeView name="cb" fixed-item-height="20" style="position: absolute; left: 0; top: 210px; width: 200px; height: 80px;" />'
			+ '<ui:ListView name="pal" fixed-item-height="20" style="position: absolute; left: 220px; top: 0; width: 150px; height: 100px;" />',
			"", Vector2(400, 300))
		var roots := [
			{"id": 1, "data": "one", "children": [{"id": 11, "data": "one-a"}, {"id": 12, "data": "one-b"}]},
			{"id": 2, "data": "two", "children": []},
			{"id": 3, "data": "three"}]
		doc.set_tree_source("tv", roots)
		doc.set_tree_item_expanded("tv", 1, true)
		doc.set_tree_source("cb", [{"id": "r", "data": "root", "children": [{"id": "k", "data": "kid"}]}])
		doc.set_tree_item_expanded("cb", "r", true)
		doc.set_items_source("pal", ["Button", "Label"])
		_settle(doc)
		var out: Array = []
		var log := _dnd_log(doc)
		# Visible: 0 one, 1 one-a, 2 one-b, 3 two, 4 three.
		# one-b into two (over the item).
		_drag(doc, doc.get_item_rect("tv", 2).get_center(), [doc.get_item_rect("tv", 3).get_center()], false)
		var t: Dictionary = doc.get_drag().get("target", {})
		h.eq([t.get("parent_id"), t.get("child_index"), t.get("drop_position")], [2, -1, UxmlDocument.DragPosition.OVER_ITEM], "over an item: into it, at the end")
		h.check(doc._dnd_overlay != null and (doc._dnd_overlay.get_child(1) as Control).visible, "the item outline is drawn")
		var hover_row = doc._dnd.get("hover")
		h.check(hover_row != null and UxmlParts.control_classes(hover_row).has("unity-collection-view__item--drag-hover"), "the item row has the drag-hover class")
		_mouse(doc, doc.get_item_rect("tv", 3).get_center(), MOUSE_BUTTON_LEFT, false)
		h.check(hover_row != null and not UxmlParts.control_classes(hover_row).has("unity-collection-view__item--drag-hover"), "the class goes with the drag")
		h.eq(_txt(roots), "[{id: 1, data: one, children: [{id: 11, data: one-a}]}, {id: 2, data: two, children: [{id: 12, data: one-b}]}, {id: 3, data: three}]",
			"the tree data moved")
		h.eq(doc.get_tree_item("tv", 3).get("id"), 12, "the parent opened; the item is visible under it")
		h.eq(doc.get_selected_indices("tv"), [3], "the moved item stays selected")
		# Visible: 0 one, 1 one-a, 2 two, 3 one-b, 4 three.
		# one into its own child: rejected.
		_drag(doc, doc.get_item_rect("tv", 0).get_center(), [doc.get_item_rect("tv", 1).get_center()])
		# three between one-a and two (top band of two): a root before two.
		var r2 := doc.get_item_rect("tv", 2)
		_drag(doc, doc.get_item_rect("tv", 4).get_center(), [r2.position + Vector2(30, 2)], false)
		t = doc.get_drag().get("target", {})
		h.eq([t.get("parent_id"), t.get("child_index"), t.get("insert_at_index")], [null, 1, 2], "between: the parent and child index of the next item")
		_mouse(doc, r2.position + Vector2(30, 2), MOUSE_BUTTON_LEFT, false)
		h.eq(roots.map(func(x): return x["id"]), [1, 3, 2], "a root moved between roots")
		# Callbacks: a palette list drags into a tree that copies.
		var calls: Array = []
		h.eq(doc.set_drag_and_drop("pal", {
			"can_start_drag": func(a): calls.append("can %s %s" % [a["index"], a["ids"]]); return a["index"] == 0,
			"setup_drag_and_drop": func(a): calls.append("setup %s" % [a["indices"]]); return {"title": "+ Button", "data": {"kind": "palette"}},
		}), OK, "set_drag_and_drop")
		h.eq(doc.set_drag_and_drop("cb", {
			"drag_and_drop_update": func(a): return UxmlDocument.DragVisualMode.COPY if a["source"] == "pal" else UxmlDocument.DragVisualMode.REJECTED,
			"handle_drop": func(a): calls.append("drop %s %s %s %s %s" % [a["source"], a["data"], a["parent_id"], a["child_index"], a["title"]]); return UxmlDocument.DragVisualMode.COPY,
		}), OK, "drop callbacks")
		h.eq(doc.set_drag_and_drop("cb", {"bogus": func(): pass}), ERR_INVALID_PARAMETER, "an unknown key")
		h.eq(doc.set_drag_and_drop("nope", {}), ERR_DOES_NOT_EXIST, "an unknown collection")
		_drag(doc, doc.get_item_rect("pal", 1).get_center(), [doc.get_item_rect("cb", 0).get_center()])
		_drag(doc, doc.get_item_rect("pal", 0).get_center(), [Vector2(300, 150)], false)
		h.eq(doc.get_drag().get("title"), "+ Button", "the drag title from setup")
		h.eq(doc.get_drag().get("data"), {"kind": "palette"}, "the drag data from setup")
		h.eq(doc.get_drag().get("target"), {}, "no target outside the collections")
		var rk := doc.get_item_rect("cb", 1)
		_mouse(doc, rk.position + Vector2(10, 2), -1)
		_mouse(doc, rk.position + Vector2(10, 2), MOUSE_BUTTON_LEFT, false)
		# The tree that copies does not take its own items (update rejects).
		_drag(doc, doc.get_item_rect("cb", 1).get_center(), [doc.get_item_rect("cb", 0).get_center()])
		h.eq(calls, ["can 1 [1]", "can 0 [0]", "setup [0]", "drop pal { \"kind\": \"palette\" } r 0 + Button"], "the callbacks")
		h.eq(_results(log), ["dropped", "rejected", "dropped", "dropped"], "the drag results")
		out.append_array(log)
		out.append_array(calls)
		_unload(doc)
		return out
	await _both(body, "tree drag and drop")


# ---------------------------------------------------------------------------
# R14: rectangles in another element's space
# ---------------------------------------------------------------------------

## Equal within 0.01 pixel (rotations and scales round).
static func _near(a: Rect2, b: Rect2) -> bool:
	return (a.position - b.position).length() < 0.01 and (a.size - b.size).length() < 0.01


func test_element_rect() -> void:
	var body := func():
		var doc := _mk("r14", '<ui:VisualElement name="p" style="position: absolute; left: 20px; top: 30px; width: 200px; height: 100px; border-width: 2px; padding: 5px;">'
			+ '<ui:VisualElement name="c" style="width: 50px; height: 40px; margin-left: 10px;" />'
			+ '<ui:VisualElement name="pct" style="width: 100px; height: 20px; padding-left: 10%; border-left-width: 3px;" /></ui:VisualElement>'
			+ '<ui:VisualElement name="rot" style="position: absolute; left: 250px; top: 10px; width: 100px; height: 20px; rotate: 90deg;">'
			+ '<ui:VisualElement name="rc" style="width: 10px; height: 10px;" /></ui:VisualElement>'
			+ '<ui:VisualElement name="sc" style="position: absolute; left: 20px; top: 200px; width: 40px; height: 20px; scale: 2 2; transform-origin: 0 0;">'
			+ '<ui:VisualElement name="sk" style="position: absolute; left: 5px; top: 5px; width: 10px; height: 4px;" /></ui:VisualElement>'
			+ '<ui:VisualElement name="gone" style="display: none; width: 10px; height: 10px;" />',
			"", Vector2(400, 300))
		var out: Array = []
		var p := _el(doc, "p")
		var c := _el(doc, "c")
		h.eq(doc.get_element_rect(c), Rect2(37, 37, 50, 40), "border box in document coordinates")
		h.eq(doc.get_element_rect(c, p), Rect2(17, 7, 50, 40), "in the parent's space (its border box origin)")
		h.eq(doc.get_element_rect(p, c), Rect2(-17, -7, 200, 100), "in the child's space")
		h.eq(doc.get_element_rect(p, null, "padding"), Rect2(22, 32, 196, 96), "padding box")
		h.eq(doc.get_element_rect(p, null, "content"), Rect2(27, 37, 186, 86), "content box")
		h.eq(doc.get_element_rect(p, p, "content"), Rect2(7, 7, 186, 86), "content box in its own space")
		# 10% of the parent's content width (186) = 18.6, 19 on the grid.
		var pct := doc.get_element_rect(_el(doc, "pct"), _el(doc, "pct"), "content")
		h.eq(pct.position.x, 3.0 + 19.0, "percentage padding as the layout resolved it")
		var rot := doc.get_element_rect(_el(doc, "rot"))
		h.check(_near(rot, Rect2(290, -30, 20, 100)), "a rotated box: the bounding box (%s)" % rot)
		var rc := doc.get_element_rect(_el(doc, "rc"), _el(doc, "rot"))
		h.check(_near(rc, Rect2(0, 0, 10, 10)), "a child in its rotated parent's space (%s)" % rc)
		var sk := _el(doc, "sk")
		var skr := doc.get_element_rect(sk)
		h.check(_near(skr, Rect2(30, 210, 20, 8)), "a scaled parent scales the child (%s)" % skr)
		var skl := doc.get_element_rect(sk, _el(doc, "sc"))
		h.check(_near(skl, Rect2(5, 5, 10, 4)), "in the scaled parent's space (%s)" % skl)
		var t := doc.get_element_transform(c, p)
		h.check(_near(Rect2(t * Vector2.ZERO, Vector2.ZERO), Rect2(17, 7, 0, 0)), "LocalToWorld of the origin")
		h.check(_near(Rect2(t.affine_inverse() * Vector2(17, 7), Vector2.ZERO), Rect2()), "WorldToLocal")
		h.eq(doc.get_element_rect(_el(doc, "gone")), Rect2(), "display: none has no rect")
		h.eq(doc.get_element_rect(c, _el(doc, "gone")), Rect2(), "nor a space")
		h.eq(doc.get_element_rect(c, null, "margin"), Rect2(), "an unknown box")
		h.eq(doc.get_element_rect(null), Rect2(), "no element")
		var tg := doc.get_element_transform(_el(doc, "gone"))
		h.eq([tg.x, tg.y], [Vector2.ZERO, Vector2.ZERO], "no transform without a layout")
		# A pending restyle runs first.
		c.set_attribute("style", "width: 60px; height: 40px; margin-left: 10px;")
		h.eq(doc.get_element_rect(c, p), Rect2(17, 7, 60, 40), "a pending restyle runs first")
		out.append(doc.get_element_rect(_el(doc, "pct"), null, "content"))
		out.append([rot.position.round(), rot.size.round()])
		var old := c
		doc.reload()
		h.eq(doc.get_element_rect(old), Rect2(), "an element of an earlier load")
		_unload(doc)
		return out
	await _both(body, "element rect")


# ---------------------------------------------------------------------------
# R11: end offsets
# ---------------------------------------------------------------------------

func test_diagnostics_have_end_offsets() -> void:
	var body := func():
		var doc := _mk("r11", '<ui:Label name="a" class="u" bogus-attr="1" text="x" />'
			+ '<ui:VisualElement name="b" style="width: abc; height: var(--nope);" />',
			".u { bogus-prop: 1; color: nonsense; }\n.v { @media x; }")
		var out: Array = []
		var src := doc.get_document_model().source
		var missing: Array = []
		for d in doc.diagnostics:
			if not d.has("end_offset") or int(d["end_offset"]) < int(d["offset"]):
				missing.append(UxmlDiagnostic.format(d))
			out.append([d["kind"], d["offset"], d.get("end_offset")])
		h.eq(missing, [], "every diagnostic has an end_offset at or after its offset")
		var a := _el(doc, "a")
		var b := _el(doc, "b")
		var seen := {}
		for d in doc.diagnostics:
			if d["file"] != doc.get_document_model().path:
				continue
			if d["kind"] == "unsupported-attribute":
				h.eq(src.substr(d["offset"], d["end_offset"] - d["offset"]), 'bogus-attr="1"', "an attribute diagnostic spans the attribute")
				seen["attr"] = true
			elif d["offset"] == a.open_tag_start or d["offset"] == b.open_tag_start:
				var el := a if d["offset"] == a.open_tag_start else b
				h.eq(d["end_offset"], el.open_tag_end, "%s on an element spans its open tag" % d["kind"])
				seen[d["kind"]] = true
		h.check(seen.has("attr") and seen.has("unsupported-property") and seen.has("unresolved-var"),
			"attribute, cascade and var diagnostics were seen: %s" % [seen.keys()])
		_unload(doc)
		return out
	await _both(body, "end offsets")
	h.eq(UxmlDiagnostic.end_of(".a { color: red; }", 5), 15, "a USS declaration ends before `;`")
	h.eq(UxmlDiagnostic.end_of('<ui:Label text="a>b" />x', 0), 23, "an open tag ends past `>` outside quotes")
	h.eq(UxmlDiagnostic.end_of("", 0), 0, "no source")


# ---------------------------------------------------------------------------
# R11: severity
# ---------------------------------------------------------------------------

func test_diagnostics_have_a_severity() -> void:
	var body := func():
		var doc := _mk("r11s", '<Style src="missing.uss" /><ui:Label name="a" bogus-attr="1" text="x" />'
			+ '<ui:VisualElement name="b" style="width: abc;" />',
			":root { color: red; }\n.u { bogus-prop: 1; }\n.v { color: red; @media x; }\n.w { color")
		var out: Array = []
		var wrong: Array = []
		var seen := {}
		for d in doc.diagnostics:
			var sev := String(d.get("severity", ""))
			if sev != UxmlDiagnostic.severity_of(String(d["kind"])):
				wrong.append(UxmlDiagnostic.format(d))
			seen[sev] = true
			out.append("%s|%s" % [d["kind"], sev])
		h.eq(wrong, [], "every diagnostic has the severity of its kind")
		h.check(seen.has("error") and seen.has("warning") and seen.has("info"),
			"errors, warnings and information were seen: %s" % [seen.keys()])
		_unload(doc)
		out.sort()
		return out
	await _both(body, "severity")
	h.eq(UxmlDiagnostic.severity_of("malformed"), "error", "broken syntax is an error")
	h.eq(UxmlDiagnostic.severity_of("missing-file"), "error", "a missing file is an error")
	h.eq(UxmlDiagnostic.severity_of("version-dependent"), "info", "version-dependent is information")
	h.eq(UxmlDiagnostic.severity_of("unsupported-property"), "warning", "an ignored property is a warning")
	for native in [true, false]:
		var saved := UxmlParser.use_native
		UxmlParser.use_native = native
		var w: Array = UxmlParser.new().parse("<a><b></a>", "x.uxml")["warnings"]
		UxmlParser.use_native = saved
		h.check(not w.is_empty() and w[0].get("severity") == "error",
			"a parser diagnostic has a severity (native %s)" % native)


# ---------------------------------------------------------------------------
# R15: text and display updates
# ---------------------------------------------------------------------------

## Border boxes of the named authored elements, in document space.
static func _named_rects(doc: UxmlDocument) -> Array:
	var out: Array = []
	for el in doc.get_document_model().root.walk():
		if el.part_of == null and el.get_attribute("name") != null:
			out.append([String(el.get_attribute("name")), doc.get_element_rect(el)])
	return out


func test_model_text_reaches_the_control() -> void:
	var src := ('<ui:Label name="l" text="a" /><ui:Button name="b" text="b" /><ui:TextElement name="t" text="t" />'
		+ '<ui:Label name="e" text="x" parse-escape-sequences="true" /><ui:Button name="r" text="r" />'
		+ '<ui:Toggle name="tg" label="L" />')
	var final := (src.replace('text="a"', 'text="model label"').replace('text="b"', 'text="model button"')
		.replace('text="t"', 'text="model element"').replace('text="x"', 'text="one\\ntwo"')
		.replace('name="r" text="r"', 'name="r" text="&lt;b&gt;bold&lt;/b&gt;"').replace('label="L"', 'label="Toggle label"'))
	var body := func():
		var doc := _mk("r15m", src, ".x { color: red; }")
		_settle(doc)
		_el(doc, "l").set_attribute("text", "model label")
		_el(doc, "b").set_attribute("text", "model button")
		_el(doc, "t").set_attribute("text", "model element")
		_el(doc, "e").set_attribute("text", "one\\ntwo")
		_el(doc, "r").set_attribute("text", "<b>bold</b>")
		_el(doc, "tg").set_attribute("label", "Toggle label")
		_settle(doc)
		h.eq(doc.get_native("l").text, "model label", "a Label shows its new text attribute")
		h.eq(doc.get_native("b").text, "model button", "a Button shows its new text attribute")
		h.eq(doc.get_native("t").text, "model element", "a TextElement shows its new text attribute")
		h.eq(doc.get_native("e").text, "one\ntwo", "escape sequences are decoded as at the load")
		h.eq(doc.get_native("r").text, "bold", "a Button draws the text without rich text tags")
		var out := _named_rects(doc)
		var fresh := _mk("r15m_f", final, ".x { color: red; }")
		_settle(fresh)
		_same(out, _named_rects(fresh), "model text changes lay out as a fresh load")
		_unload(fresh)
		_unload(doc)
		return out
	await _both(body, "model text")


func test_text_changes_without_a_layout() -> void:
	var uss := (".fixed { width: 120px; height: 20px; }\n.col { width: 200px; }\n"
		+ ".row { flex-direction: row; width: 300px; height: 24px; }\n.grow { flex-grow: 1; }\n"
		+ ".auto { align-self: flex-start; }\n.wrap { white-space: normal; width: 80px; }\n")
	var src := ('<ui:Label name="fixed" class="fixed" text="a" />'
		+ '<ui:VisualElement class="col"><ui:Label name="stretched" text="b" /></ui:VisualElement>'
		+ '<ui:VisualElement name="row" class="row"><ui:Label name="cell" class="grow" text="c" /><ui:Button name="btn" text="d" /></ui:VisualElement>'
		+ '<ui:Label name="auto" class="auto" text="e" />')
	var final := (src.replace('text="a"', 'text="from the model"')
		.replace('text="b"', 'text="a longer text in a column"').replace('text="c"', 'text="a longer cell"')
		.replace('text="e"', 'text="a longer label of its own width"')
		.replace('name="row" class="row"', 'name="row" class="row" style="display: none;"'))
	var body := func():
		var doc := _mk("r15l", src, uss, Vector2(600, 400))
		_settle(doc)
		var n := doc.layout_count
		doc.set_text("fixed", "a much longer text than before")
		doc._restyle_now()
		h.eq(doc.layout_count, n, "a Label of a fixed size: no layout")
		doc.set_text("stretched", "a longer text in a column")
		doc._restyle_now()
		h.eq(doc.layout_count, n, "a Label stretched in a column of a fixed width: no layout")
		_el(doc, "fixed").set_attribute("text", "from the model")
		doc._restyle_now()
		h.eq(doc.layout_count, n, "a model text change of a fixed Label: no layout")
		doc.set_text("cell", "a longer cell")
		doc._restyle_now()
		h.eq(doc.layout_count, n + 1, "a growing cell whose width follows its text lays out")
		doc.set_text("auto", "a longer label of its own width")
		doc._restyle_now()
		h.eq(doc.layout_count, n + 2, "a Label of its own width lays out")
		# A display change of a settled document is one layout pass; the
		# measures confirm the settling pass after it. (Layouts right after
		# each other are a stream: test_settle_snapshot_in_a_stream_of_layouts.)
		_settle(doc)
		n = doc.layout_count
		_el(doc, "row").set_attribute("style", "display: none;")
		doc._restyle_now()
		h.eq(doc.layout_count, n + 1, "a display change lays out once")
		doc._restyle_now()
		doc._restyle_now()
		h.eq(doc.layout_count, n + 1, "and needs no settling layout")
		h.eq(doc.get_native("fixed").text, "from the model", "the control has the text")
		var out := _named_rects(doc)
		var fresh := _mk("r15l_f", final, uss, Vector2(600, 400))
		_settle(fresh)
		_same(out, _named_rects(fresh), "the document after the changes equals a fresh load")
		_unload(fresh)
		_unload(doc)
		# Wrapping text lays out at every change. (A document with wrapping
		# text keeps no settling snapshot: its settling pass lays out.)
		var wd := _mk("r15w", '<ui:Label name="wrap" class="wrap" text="f" />', uss, Vector2(600, 400))
		_settle(wd)
		var wn := wd.layout_count
		wd.set_text("wrap", "wrapping text lays out every time")
		wd._restyle_now()
		h.eq(wd.layout_count, wn + 1, "wrapping text lays out")
		out.append(_named_rects(wd))
		_unload(wd)
		return out
	await _both(body, "text without layout")


## A stream of layouts takes no settle snapshot; the first restyle that only
## settles ends the stream, and the rects are those of a fresh load.
func test_settle_snapshot_in_a_stream_of_layouts() -> void:
	var src := '<ui:VisualElement name="box" style="width: 10px; height: 10px;" /><ui:Label name="l" text="x" />'
	var body := func():
		var doc := _mk("r15s", src, "", Vector2(400, 300))
		_settle(doc)
		var n := doc.layout_count
		var box := _el(doc, "box")
		box.set_attribute("style", "width: 20px; height: 10px;")
		doc._restyle_now()
		h.eq(doc.layout_count, n + 1, "a size change lays out")
		h.check(not doc._settle_ms.is_empty(), "a first layout keeps a snapshot")
		box.set_attribute("style", "width: 30px; height: 10px;")
		doc._restyle_now()
		h.eq(doc.layout_count, n + 2, "the next size change lays out")
		h.check(doc._settle_ms.is_empty(), "a layout before the snapshot was read: no snapshot")
		box.set_attribute("style", "width: 40px; height: 10px;")
		doc._restyle_now()
		h.check(doc._settle_ms.is_empty(), "no snapshot while the stream runs")
		doc._restyle_now()
		h.eq(doc.layout_count, n + 4, "the end of the stream settles with a layout")
		_settle(doc)
		n = doc.layout_count
		box.set_attribute("style", "width: 50px; height: 10px;")
		doc._restyle_now()
		h.check(not doc._settle_ms.is_empty(), "after the stream a layout keeps a snapshot again")
		doc._restyle_now()
		h.eq(doc.layout_count, n + 1, "and the snapshot settles without a layout")
		var rects := _named_rects(doc)
		_unload(doc)
		var fresh := _mk("r15s", src.replace("width: 10px", "width: 50px"), "", Vector2(400, 300))
		_settle(fresh)
		h.eq(rects, _named_rects(fresh), "the rects of a fresh load")
		_unload(fresh)
		return rects
	await _both(body, "settle snapshot stream")


# ---------------------------------------------------------------------------
# R16: context menus
# ---------------------------------------------------------------------------

func _action_to(m: UxmlPopupMenu, action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	m.window_input.emit(ev)


func _right_click(doc: UxmlDocument, pos: Vector2) -> void:
	for pressed in [true, false]:
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_RIGHT
		mb.pressed = pressed
		mb.button_mask = MOUSE_BUTTON_MASK_RIGHT if pressed else 0
		mb.position = pos
		mb.global_position = pos
		doc.get_viewport().push_input(mb)


static func _has_cls(el: UxmlElement, c: String) -> bool:
	var v = el.get_attribute("class")
	return v != null and String(v).split(" ", false).has(c)


## The label text of item `i` of a menu document.
static func _item_text(md: UxmlDocument, i: int) -> String:
	var it := md.get_element_model("item-%d" % i)
	if it == null:
		return ""
	for el in it.walk():
		if _has_cls(el, "unity-base-dropdown__label"):
			return String(el.get_attribute("text"))
	return ""


func test_context_menu() -> void:
	var body := func():
		var doc := _mk("r16", '<ui:VisualElement name="area" style="width: 200px; height: 100px;">'
			+ '<ui:Label name="inner" text="inside" /></ui:VisualElement>', "")
		await h.process_frame
		var chosen: Array = []
		doc.menu_chosen.connect(func(i): chosen.append(i))
		var m := doc.show_context_menu(Vector2(10, 12), ["Cut", {"text": "Copy", "disabled": true}, "-",
			{"text": "Paste", "checked": true}, {"text": "Gone", "hidden": true}, "Delete"])
		h.check(m != null and m.visible, "show_context_menu opens a menu")
		h.eq(doc.get_context_menu(), m, "get_context_menu")
		var out: Array = []
		if m != null:
			var md := m.document()
			h.check(md.get_element("item-0") != null and md.get_element("item-5") != null, "the items keep their indices")
			h.eq(md.get_element("item-4"), null, "a hidden item is not shown")
			h.eq(_item_text(md, 3), "Paste", "item text")
			h.check(md._states.get(md.get_element_model("item-3"), {}).has("checked"), "a checked item is :checked")
			h.eq(String(md.get_computed_style("item-1").get("opacity", {}).get("value", "")), "0.5",
				"a disabled item has Unity's disabled look")
			var seps := 0
			for el in md.get_document_model().root.walk():
				if _has_cls(el, "unity-base-dropdown__separator-container"):
					seps += 1
			h.eq(seps, 1, "one separator")
			h.eq(UxmlTheme.editor_skin_of(md.get_document_model()), "", "a runtime document gives the runtime look")
			# The headless window is 64 px: the menu moves up and left to fit.
			h.check(m.position.x <= 10 and m.position.y <= 12 and m.position.x >= 0 and m.position.y >= 0,
				"the menu opens at the point or moves up and left to fit: %s" % m.position)
			_action_to(m, "ui_down")
			md._restyle_now()
			h.eq(String(md.get_computed_style("item-0").get("background-color", {}).get("value", "")), "rgb(0, 106, 166)",
				"the highlight has the runtime look")
			_action_to(m, "ui_down")
			md._restyle_now()
			h.check(md._states.get(md.get_element_model("item-3"), {}).has("hover"),
				"Down skips the disabled item and the separator")
			out.append(_txt(md.get_computed_style("item-3")))
			out.append(md.get_element("outer").size)
			_action_to(m, "ui_accept")
			h.eq(chosen, [3], "accept emits menu_chosen with the index of the item")
			h.eq(doc.get_context_menu(), null, "the menu closed")
		# The editor look follows the owner's skin.
		var ed := UxmlDocument.new()
		ed.editor_theme = "always"
		ed.editor_skin = "light"
		h.root.add_child(ed)
		ed.size = Vector2(300, 200)
		ed.load_source(UXML_HEAD + '<ui:Label text="e" /></ui:UXML>')
		var em := ed.show_context_menu(Vector2(5, 5), PackedStringArray(["One", "Two"]))
		h.check(em != null, "a PackedStringArray of items")
		if em != null:
			var emd := em.document()
			h.eq(UxmlTheme.editor_skin_of(emd.get_document_model()), "light", "an editor document gives its skin to the menu")
			_action_to(em, "ui_down")
			emd._restyle_now()
			h.eq(String(emd.get_computed_style("item-0").get("background-color", {}).get("value", "")), "rgb(58, 114, 176)",
				"the highlight has the colour of the light skin")
			out.append(_txt(emd.get_computed_style("item-0")))
			_action_to(em, "ui_cancel")
			h.eq(ed.get_context_menu(), null, "Escape closes the menu")
		_unload(ed)
		# ContextualMenuManipulator: the populate event goes from the picked
		# element up.
		var targets: Array = []
		doc.set_context_menu(_el(doc, "area"), func(a):
			targets.append([a["target"].get_attribute("name"), a["element"].get_attribute("name")])
			return ["Area action"])
		doc.set_context_menu(_el(doc, "inner"), func(a):
			targets.append([a["target"].get_attribute("name"), a["element"].get_attribute("name")])
			return [{"text": "Inner action"}])
		var ir := doc.get_element_rect(_el(doc, "inner"))
		_right_click(doc, doc.get_global_transform() * ir.get_center())
		await h.process_frame
		h.eq(targets, [["inner", "inner"], ["inner", "area"]], "the callbacks run from the target up")
		var cm := doc.get_context_menu()
		h.check(cm != null, "a right-click opens the menu of the manipulators")
		if cm != null:
			h.eq(_item_text(cm.document(), 0), "Inner action", "the target's items come first")
			h.eq(_item_text(cm.document(), 1), "Area action", "then the ancestor's")
			cm.hide()
		doc.set_context_menu(_el(doc, "inner"), Callable())
		doc.set_context_menu(_el(doc, "area"), Callable())
		_right_click(doc, doc.get_global_transform() * ir.get_center())
		await h.process_frame
		h.eq(doc.get_context_menu(), null, "without manipulators a right-click opens nothing")
		_unload(doc)
		return out
	await _both(body, "context menu")


# ---------------------------------------------------------------------------
# R25: a stylesheet reload restyles what the edit can change
# ---------------------------------------------------------------------------

const R25_BODY := '<ui:VisualElement name="panel" class="panel"><ui:Label name="in" class="cell" text="a" />'\
	+ '<ui:VisualElement name="deep"><ui:Label name="in2" text="b" /></ui:VisualElement></ui:VisualElement>'\
	+ '<ui:VisualElement name="other" class="other"><ui:Label name="out" class="cell" text="c" /></ui:VisualElement>'\
	+ '<ui:Button name="btn" class="btn" text="go" />'
const R25_USS := ':root { --c: rgb(1, 1, 1); }\n.panel { width: 200px; background-color: rgb(10, 10, 10); font-size: 12px; }\n'\
	+ '.other { width: 150px; background-color: rgb(20, 20, 20); }\n.cell { height: 20px; color: var(--c); }\n'\
	+ '.btn { min-width: 40px; transition-property: min-width; transition-duration: 1s; }\n'\
	+ '.btn:hover { min-width: 80px; color: rgb(2, 2, 2); }\n'


## A second document of the same text that rebuilds everything at each reload.
func _r25_pair() -> Array:
	var a := _mk("r25", R25_BODY, R25_USS, Vector2(500, 400))
	var b := _mk("r25", R25_BODY, R25_USS, Vector2(500, 400))
	b._partial_reload = false
	return [a, b]


## `a` and `b` after the same reload: the same styles, diagnostics and controls.
func _r25_same(a: UxmlDocument, b: UxmlDocument, what: String) -> void:
	var names := ["panel", "in", "deep", "in2", "other", "out", "btn"]
	for n in names:
		var sa = a.get_computed_style(n)
		var sb = b.get_computed_style(n)
		h.eq(_no_sheet(_txt(_sorted(sa))), _no_sheet(_txt(_sorted(sb))), "%s: the style of %s equals a full rebuild" % [what, n])
	h.eq(_diag_set(a), _diag_set(b), "%s: the diagnostics equal a full rebuild" % what)
	var tp = load("res://tests/test_parking.gd")
	_same(tp.snapshot(a, true), tp.snapshot(b, true), "%s: the controls equal a full rebuild" % what)


static func _sorted(d: Dictionary) -> Dictionary:
	var keys := d.keys()
	keys.sort()
	var out := {}
	for k in keys:
		out[k] = d[k]
	return out


func test_reload_restyles_only_the_edit() -> void:
	var body := func():
		var pair := await _r25_pair()
		var a: UxmlDocument = pair[0]
		var b: UxmlDocument = pair[1]
		var out: Array = []
		var origin := String(a.get_computed_style("panel")["width"]["origin"]["file"])
		var apply_all := func(text: String):
			h.eq(a.reload_stylesheet(origin, text), OK, "reload")
			b.reload_stylesheet(origin, text)
			out.append(a.get_last_reload_mode())
		var other_style: Dictionary = a.get_computed_style("other")
		var other_ctl := a.get_element("other")
		var n := a.layout_count
		# A paint declaration: its elements only, no layout.
		var t1 := R25_USS.replace("rgb(10, 10, 10)", "rgb(11, 11, 11)")
		apply_all.call(t1)
		h.eq(a.get_last_reload_mode(), "restyle", "one value: a restyle")
		h.eq(a.layout_count, n, "a colour lays out nothing")
		h.check(is_same(a.get_computed_style("other"), other_style), "an element outside the rule keeps its style object")
		h.eq(a.get_element("other"), other_ctl, "the controls stay")
		h.eq(String(a.get_computed_style("panel")["background-color"]["value"]), "rgb(11, 11, 11)", "the new value")
		_r25_same(a, b, "paint")
		# An inherited property reaches the subtree of the rule only.
		var t2 := t1.replace("font-size: 12px", "font-size: 17px")
		apply_all.call(t2)
		h.eq(a.get_last_reload_mode(), "restyle", "an inherited value: a restyle")
		h.eq(String(a.get_computed_style("in2")["font-size"]["value"]), "17px", "the value reaches a descendant")
		_r25_same(a, b, "inherited")
		# A length lays out.
		n = a.layout_count
		var t3 := t2.replace("width: 200px", "width: 222px")
		apply_all.call(t3)
		h.eq(a.layout_count, n + 1, "a length lays out once")
		h.eq(a.get_element("panel").size.x, 222.0, "the new width")
		_r25_same(a, b, "layout")
		# A custom property reaches every var() below it.
		var t4 := t3.replace("--c: rgb(1, 1, 1)", "--c: rgb(3, 3, 3)")
		apply_all.call(t4)
		h.eq(String(a.get_computed_style("in")["color"]["value"]), "rgb(3, 3, 3)", "a custom property reaches var()")
		_r25_same(a, b, "custom property")
		# Only transition properties: no apply and no layout.
		n = a.layout_count
		var t5 := t4.replace("transition-duration: 1s", "transition-duration: 2s; transition-delay: 0.5s")
		apply_all.call(t5)
		h.eq(a.layout_count, n, "transition properties lay out nothing")
		h.eq(a._reapply.size(), 0, "transition properties apply nothing")
		h.eq(String(a.get_computed_style("btn")["transition-delay"]["value"]), "0.5s", "the computed style has the new value")
		_r25_same(a, b, "transition")
		# A rule that matches nothing now reads the new text when it matches.
		var t6 := t5.replace("color: rgb(2, 2, 2)", "color: rgb(5, 5, 5)")
		n = a.layout_count
		apply_all.call(t6)
		h.eq(a.layout_count, n, "a rule of a state that is not on lays out nothing")
		for d in [a, b]:
			d.set_element_state("btn", "hover", true)
			d._restyle_now()
		h.eq(String(a.get_computed_style("btn")["color"]["value"]), "rgb(5, 5, 5)", "the state reads the new rule")
		h.eq(a.get_transitions().size(), b.get_transitions().size(), "the new delay and duration start the same transition")
		h.eq(a.explain_style(_el(a, "btn"), "color")[0]["value"], "rgb(5, 5, 5)", "provenance reads the new rule")
		# Running transitions end at their end values; a reload starts none.
		var t7 := t6.replace("min-width: 80px", "min-width: 90px")
		apply_all.call(t7)
		h.eq(a.has_running_transitions(), false, "a reload ends running transitions")
		h.eq(String(a.get_computed_style("btn")["min-width"]["value"]), "90px", "the new end value")
		_r25_same(a, b, "running transition")
		# A selector, a new rule, a removed rule.
		var t8 := t7.replace(".other {", ".other, .cell {")
		apply_all.call(t8)
		h.eq(a.get_last_reload_mode(), "rules", "a selector change compiles the rules in place")
		_r25_same(a, b, "selector")
		# A state of an ancestor in a new first rule: the ancestor keys change,
		# and every later item moves.
		var t8b := "#in:hover > * { padding-left: 1px; }\n" + t8
		apply_all.call(t8b)
		h.eq(a.get_last_reload_mode(), "rules", "a rule added first")
		_r25_same(a, b, "ancestor state")
		apply_all.call(t8)
		_r25_same(a, b, "first rule removed")
		var t9 := t8 + "#in { color: rgb(9, 9, 9); }\n"
		apply_all.call(t9)
		h.eq(a.get_last_reload_mode(), "rules", "a new rule compiles the rules in place")
		h.eq(String(a.get_computed_style("in")["color"]["value"]), "rgb(9, 9, 9)", "the new rule applies")
		_r25_same(a, b, "added rule")
		apply_all.call(t8)
		_r25_same(a, b, "removed rule")
		# Comments and white space only: nothing changes, offsets move.
		var t10 := "/* moved\n*/ a + b { color: red; }\n" + t8
		apply_all.call(t10)
		_r25_same(a, b, "unsupported selector")
		var off := int(_find_diag(a, "unsupported-selector").get("offset", -1))
		apply_all.call("/* more */ " + t10)
		h.eq(a.get_last_reload_mode(), "restyle", "a comment: no rule changes")
		h.eq(int(_find_diag(a, "unsupported-selector").get("offset", -1)), off + 11, "the rule diagnostic moves with the text")
		_r25_same(a, b, "comment")
		# A diagnostic of a value goes with the value, also on a state that is off.
		var bad := 'background-image: url("nope.png")'
		var t11 := t10.replace("height: 20px", "height: 20px; " + bad)
		apply_all.call(t11)
		h.check(_applier_reports(a), "the applier reports a missing image")
		_r25_same(a, b, "bad value")
		apply_all.call(t10)
		h.check(not _applier_reports(a), "the report of the old text goes")
		_r25_same(a, b, "fixed value")
		var stale := t10 + ".other:hover { %s; }\n" % bad.replace("nope", "nope2")
		for d in [a, b]:
			d.set_element_state("other", "hover", true)
			d._restyle_now()
		apply_all.call(stale)
		h.check(_applier_reports(a), "a missing image of a state that is on")
		for d in [a, b]:
			d.set_element_state("other", "hover", false)
			d._restyle_now()
		apply_all.call(stale + "/* c */")
		h.check(not _applier_reports(a), "the report of a state that went off goes at a reload")
		_r25_same(a, b, "state that went off")
		_unload(a)
		_unload(b)
		return out
	await _both(body, "reload restyle")


## A patched sheet under a scope and an imported sheet: the rules of the sheet
## change in every place the sheet is compiled.
func test_reload_patches_imported_sheets() -> void:
	var body := func():
		var dir := ROOT + "/r25i"
		_write(dir + "/Assets/UI/base.uss", ".x { color: rgb(1, 1, 1); }")
		var a := _mk("r25i", '<ui:Label name="l" class="x" text="t" />', '@import "base.uss"; .x { width: 50px; }')
		var origin := ""
		for sh in a.get_document_model().sheets:
			if String(sh["origin"]).ends_with("base.uss"):
				origin = sh["origin"]
		h.check(not origin.is_empty(), "the imported sheet is a sheet of the document")
		h.eq(a.reload_stylesheet(origin, ".x { color: rgb(7, 7, 7); }"), OK, "reload the imported sheet")
		h.eq(a.get_last_reload_mode(), "restyle", "one value of an imported sheet: a restyle")
		h.eq(String(a.get_computed_style("l")["color"]["value"]), "rgb(7, 7, 7)", "the new value")
		h.eq(String(a.get_computed_style("l")["width"]["value"]), "50px", "the importing sheet stays")
		var out := [_no_sheet(_txt(a.get_computed_style("l")))]
		_unload(a)
		return out
	await _both(body, "reload of an import")


## True when the style applier has reported something.
func _applier_reports(doc: UxmlDocument) -> bool:
	return not doc._applier._warned.is_empty()


func _find_diag(doc: UxmlDocument, kind: String) -> Dictionary:
	for d in doc.diagnostics:
		if d.get("kind") == kind:
			return d
	return {}


# ---------------------------------------------------------------------------
# R17: field values without a restyle
# ---------------------------------------------------------------------------

func test_set_field_value() -> void:
	var fields := '<ui:TextField name="text" value="a" /><ui:Toggle name="tog" label="x" />'\
		+ '<ui:DropdownField name="drop" choices="one,two,three" index="0" />'\
		+ '<ui:Slider name="sl" low-value="0" high-value="10" value="1" />'\
		+ '<ui:VisualElement name="box" /><uie:ColorField name="col" />'
	var uss := "#tog:checked { width: 50px; } .unity-toggle:checked { color: rgb(9, 9, 9); }"
	var body := func():
		var doc := _mk("r17", fields, uss)
		var ref := _mk("r17", fields, uss)
		await h.process_frame
		doc._restyle_now()
		ref._restyle_now()
		var out: Array = []
		var sent: Array = []
		doc.value_changed.connect(func(n, v): sent.append([n, v]))
		h.eq(doc.set_field_value("box", 1), false, "an element without a value")
		h.eq(doc.set_field_value("missing", 1), false, "an unknown name")
		# A text value: no restyle, no event.
		h.eq(doc.set_field_value("text", "new text"), true, "a text field")
		h.eq(doc._restyle_queued, false, "a text value queues no restyle")
		h.eq(doc._attr_dirty.size(), 0, "and marks nothing for the cascade")
		h.eq(doc.get_native("text").text, "new text", "the LineEdit shows the value")
		h.eq(doc.get_field_value("text"), "new text", "get_field_value")
		h.eq(sent, [], "no value_changed without notify")
		# The same write with a restyle reaches the same end state.
		ref._behaviors[ref.get_element_model("text")].bind_write("value", "new text")
		# A Toggle: :checked restyles the states, without an event.
		h.eq(doc.set_field_value("tog", true), true, "a toggle")
		h.eq(sent, [], "a toggle emits nothing without notify")
		ref._behaviors[ref.get_element_model("tog")].bind_write("value", true)
		h.eq(doc.set_field_value("drop", "two"), true, "a dropdown")
		ref._behaviors[ref.get_element_model("drop")].bind_write("value", "two")
		h.eq(doc.set_field_value("sl", 4.0), true, "a slider")
		ref._behaviors[ref.get_element_model("sl")].bind_write("value", 4.0)
		h.eq(doc.set_field_value("col", Color(1, 0, 0)), true, "a colour field")
		out.append(str(doc.get_field_value("col")))
		ref._behaviors[ref.get_element_model("col")].bind_write("value", Color(1, 0, 0))
		h.eq(sent, [], "no field emits without notify")
		doc._restyle_now()
		ref._restyle_now()
		await h.process_frame
		doc._restyle_now()
		ref._restyle_now()
		h.eq(String(doc.get_computed_style("tog")["width"]["value"]), "50px", ":checked applies")
		var tp = load("res://tests/test_parking.gd")
		_same(tp.snapshot(doc, true), tp.snapshot(ref, true), "the controls equal a write with a restyle")
		# With notify: once, and only for a new value.
		doc.set_field_value("text", "n2", true)
		h.eq(sent, [["text", "n2"]], "notify emits the new value")
		doc.set_field_value("text", "n2", true)
		h.eq(sent.size(), 1, "the same value emits nothing")
		doc.set_field_value("tog", false, true)
		h.eq(sent[-1], ["tog", false], "a toggle emits once with notify")
		h.eq(sent.size(), 2, "and only once")
		h.eq(doc.is_blocking_signals(), false, "the signals of the document are on again")
		out.append(sent)
		_unload(doc)
		_unload(ref)
		return out
	await _both(body, "field value")


## R27: a key press as the OS delivers it, to the focused control.
func _type(doc: UxmlDocument, ch: String) -> void:
	var ev := InputEventKey.new()
	ev.keycode = OS.find_keycode_from_string(ch.to_upper())
	ev.unicode = ch.unicode_at(0)
	ev.pressed = true
	doc.get_viewport().push_input(ev)
	var rel := InputEventKey.new()
	rel.keycode = ev.keycode
	rel.pressed = false
	doc.get_viewport().push_input(rel)


func test_typing_keeps_the_caret() -> void:
	var fields := '<ui:TextField name="live" /><ui:TextField name="late" is-delayed="true" />'\
		+ '<ui:TextField name="capped" max-length="8" password="true" />'\
		+ '<uie:ToolbarSearchField name="search" />'
	var uss := ".unity-text-field { width: 200px; }"
	var body := func():
		var doc := _mk("r27", fields, uss)
		await h.process_frame
		doc._restyle_now()
		var out: Array = []
		for n in ["live", "late", "capped", "search"]:
			var le: LineEdit = doc.get_native(n) if n != "search" else null
			if le == null:
				for c in doc.get_control_for(_el(doc, n)).find_children("*", "LineEdit", true, false):
					le = c
			le.grab_focus()
			await h.process_frame
			for ch in "slid":
				_type(doc, ch)
				await h.process_frame
				await h.process_frame
			h.eq(le.text, "slid", "%s: typing keeps the order" % n)
			h.eq(le.caret_column, 4, "%s: the caret follows the text" % n)
			out.append([n, le.text, le.caret_column])
			le.release_focus()
			await h.process_frame
		_unload(doc)
		return out
	await _both(body, "typing")


# ---------------------------------------------------------------------------
# R19, R23: runtime classes, finish_transitions, completed transitions
# ---------------------------------------------------------------------------

const R23_USS := '.a { width: 10px; height: 10px; min-width: 100px; transition: min-width 1s linear; }\n'\
	+ '.a:hover { min-width: 200px; }\n.a:checked { min-width: 300px; transition-duration: 0s; }\n'\
	+ '.big { min-width: 150px; } .b { height: 20px; }\n'


func test_author_classes() -> void:
	var body := func():
		var doc := _mk("r19", '<ui:ScrollView name="t" class="a" /><ui:VisualElement class="a" />', R23_USS)
		var t := _el(doc, "t")
		var own := UxmlParts.control_classes(t)
		h.check(not own.is_empty(), "a ScrollView has control classes")
		h.eq(Array(doc.get_author_classes(t)), ["a"], "the author classes")
		doc.set_author_classes(t, PackedStringArray(["b", "big"]))
		h.eq(Array(doc.get_author_classes(t)), ["b", "big"], "the new author classes")
		for c in own:
			h.check(t.class_list().has(c), "the control class %s stays" % c)
		doc._restyle_now()
		h.eq(String(doc.get_computed_style_for(t)["height"]["value"]), "20px", "the rules of the new class apply")
		var unnamed: UxmlElement = doc.get_document_model().root.children[1]
		doc.set_author_classes(unnamed, PackedStringArray())
		doc._restyle_now()
		h.eq(Array(doc.get_author_classes(unnamed)), [], "an element without a name")
		h.check(not doc.get_computed_style_for(unnamed).has("height"), "the rule of the old class goes")
		doc.set_author_classes(UxmlElement.new(), PackedStringArray(["x"]))
		h.eq(Array(doc.get_author_classes(UxmlElement.new())), [], "an element of no load")
		var out := [Array(doc.get_author_classes(t))]
		_unload(doc)
		return out
	await _both(body, "author classes")


func test_finish_transitions() -> void:
	var body := func():
		var doc := _mk("r19f", '<ui:VisualElement name="v" class="a" />', R23_USS)
		var events: Array = []
		doc.transition_end.connect(func(n, p, _t): events.append(["end", n, p]))
		doc.transition_cancel.connect(func(n, p, _t): events.append(["cancel", n, p]))
		doc.finish_transitions()
		h.eq(doc.get_transition_clock(), 0.0, "no transition: nothing happens")
		doc.set_element_state("v", "hover", true)
		doc._restyle_now()
		doc.advance_transitions(0.25)
		h.eq(doc.has_running_transitions(), true, "a transition runs")
		var clock := doc.get_transition_clock()
		doc.finish_transitions()
		h.eq(doc.has_running_transitions(), false, "finish ends it")
		h.eq(String(doc.get_computed_style("v")["min-width"]["value"]), "200px", "at the end value")
		h.eq(doc.get_element("v").size.x, 200.0, "the layout has the end value")
		h.eq(doc.get_transition_clock(), clock, "the clock stays")
		doc._restyle_now()
		h.eq(doc.get_transitions(), [], "the restyle starts nothing")
		h.eq(events, [], "no event")
		# Not a completed transition: the same end value runs again.
		doc.set_element_state("v", "hover", false)
		doc._restyle_now()
		doc.finish_transitions()
		doc.set_element_state("v", "hover", true)
		doc._restyle_now()
		h.eq(doc.get_transitions().size(), 1, "a later change to the same value starts a transition")
		var out := [events, doc.get_transitions().size()]
		_unload(doc)
		return out
	await _both(body, "finish_transitions")


## Unity's StartTransition keeps a completed transition through an instant
## change (a combined duration of 0 returns before the removal), and the
## computed transitions cancel only with a running animation
## (VisualTreeStyleUpdater). A later change to its end value starts nothing.
func test_completed_transition_after_an_instant_change() -> void:
	var body := func():
		var doc := _mk("r23", '<ui:Toggle name="v" class="a" />', R23_USS)
		var set_on := func(state: String, on: bool):
			doc.set_element_state("v", state, on)
			doc._restyle_now()
		set_on.call("hover", true)
		doc.advance_transitions(2.0)
		set_on.call("hover", false)
		doc.advance_transitions(2.0)
		h.eq(doc.has_running_transitions(), false, "completed at 100px")
		set_on.call("checked", true)
		h.eq(doc.get_transitions(), [], "an instant change to 300px")
		h.eq(String(doc.get_computed_style("v")["min-width"]["value"]), "300px", "at once")
		set_on.call("checked", false)
		h.eq(doc.get_transitions(), [], "as Unity: the completed transition stops a change back to 100px")
		h.eq(String(doc.get_computed_style("v")["min-width"]["value"]), "100px", "at once")
		# A tool can start clean.
		set_on.call("checked", true)
		doc.clear_completed_transitions()
		set_on.call("checked", false)
		var tr := doc.get_transitions()
		h.eq(tr.size(), 1, "clear_completed_transitions: the change runs")
		var out := [tr[0]["from"], tr[0]["to"]] if tr.size() == 1 else []
		_unload(doc)
		return out
	await _both(body, "completed transition")


# ---------------------------------------------------------------------------
# R26: the transitions of a state change, without the change
# ---------------------------------------------------------------------------

const R26_BODY := '<ui:VisualElement name="v" class="v"><ui:Label name="kid" class="kid" text="k" /></ui:VisualElement>'\
	+ '<ui:VisualElement name="w" class="w" />'
const R26_USS := '.v { width: 100px; height: 20px; color: rgb(0, 0, 0); transition: width 1s ease-in 0.25s, color 0.5s linear; }\n'\
	+ '.v:hover { width: 200px; color: rgb(255, 0, 0); }\n.v:hover .kid { font-size: 20px; }\n'\
	+ '.kid { font-size: 10px; color: rgb(0, 0, 0); transition: font-size 2s; }\n'\
	+ '.v:checked { width: 300px; transition-duration: 0s; }\n.v:disabled { height: 40px; transition: height 1s; }\n'\
	+ '.w { height: 5px; transition: height 1s; }\n.w:hover { height: 6px; }\n'


static func _tracks(list: Array) -> Array:
	var out: Array = []
	for t in list:
		out.append([t["element"].get_attribute("name"), t["property"], t["from"], t["to"], t["delay"], t["duration"], t["easing"], t["start_time"] - float(t.get("_clock", 0.0))])
	out.sort_custom(func(a, b): return str(a) < str(b))
	return out


func test_preview_transitions() -> void:
	var body := func():
		var doc := _mk("r26", R26_BODY, R26_USS)
		var v := _el(doc, "v")
		var out: Array = []
		var edges := [[[], ["hover"]], [["hover"], []], [[], ["checked"]], [["checked"], []],
			[[], ["disabled"]], [["hover"], ["checked"]], [[], []]]
		for edge in edges:
			var from := PackedStringArray(edge[0])
			var to := PackedStringArray(edge[1])
			var before := _no_sheet(_txt(doc.get_computed_style("v")))
			var layouts := doc.layout_count
			var prev := doc.preview_transitions(v, from, to)
			h.eq(_no_sheet(_txt(doc.get_computed_style("v"))), before, "the document keeps its style")
			h.eq(doc.layout_count, layouts, "and lays out nothing")
			h.eq(doc.has_running_transitions(), false, "and starts nothing")
			# The kinds equal a real run on a new document.
			var real := _mk("r26", R26_BODY, R26_USS)
			real.transitions_manual = true
			real.set_forced_states(_el(real, "v"), from)
			real._restyle_now()
			real.advance_transitions(10.0)
			real.set_forced_states(_el(real, "v"), to)
			real._restyle_now()
			var run := real.get_transitions()
			# The run starts after the first clock move.
			var clock := real.get_transition_clock()
			for t in run:
				t["_clock"] = clock
			_same(_tracks(prev), _tracks(run), "%s -> %s: the same tracks as a real run" % [from, to])
			out.append(_tracks(prev))
			_unload(real)
		# Descendants are in the list; another element's state stays.
		var hover := doc.preview_transitions(v, PackedStringArray(), PackedStringArray(["hover"]))
		var kid := false
		for t in hover:
			if t["element"] == _el(doc, "kid") and t["property"] == "font-size":
				kid = true
		h.check(kid, "a descendant selector gives a track of the descendant")
		doc.set_element_state("w", "hover", true)
		doc._restyle_now()
		h.eq(doc.preview_transitions(v, PackedStringArray(), PackedStringArray()).size(), 0, "no change, no track")
		# A declaration edit reaches the preview.
		var origin := String(doc.get_computed_style("v")["width"]["origin"]["file"])
		doc.reload_stylesheet(origin, R26_USS.replace("width 1s", "width 3s"))
		var after := doc.preview_transitions(v, PackedStringArray(), PackedStringArray(["hover"]))
		var dur := 0.0
		for t in after:
			if t["property"] == "width":
				dur = t["duration"]
		h.eq(dur, 3.0, "the preview reads a reloaded sheet")
		h.eq(doc.preview_transitions(UxmlElement.new(), PackedStringArray(), PackedStringArray(["hover"])), [], "an element of no load")
		_unload(doc)
		return out
	await _both(body, "preview transitions")


# ---------------------------------------------------------------------------
# R20: the public helpers
# ---------------------------------------------------------------------------

func test_public_helpers() -> void:
	h.eq(UssTransitions.easing(UssProperties.EASING_MODES.find("linear"), 0.25), 0.25, "easing(mode, t)")
	h.check(UssProperties.EASING_MODES.has("ease-in-out"), "EASING_MODES")
	h.check((UssTransitions.SHORTHANDS["margin"] as Array).has("margin-top"), "SHORTHANDS")
	var f: Font = ThemeDB.fallback_font
	var shown := UxmlStyleApplier.elide_text("a long text that does not fit", 30.0, "end", f, 14)
	h.check(shown.ends_with("...") and shown.length() < 29, "elide_text(text, width, position, font, size)")
	var el := UxmlElement.new()
	el.attributes = [{"name": "class", "value": "a", "offset": 0}]
	h.eq(UxmlParts.merged_class(el, "b c"), "b c", "merged_class(element, author)")
	UxmlParts._add_control_classes(el, ["own"])
	h.eq(UxmlParts.merged_class(el, "b"), "b own", "merged_class keeps the control classes")


# ---------------------------------------------------------------------------
# R18: the placeholder of a text field elides
# ---------------------------------------------------------------------------

func test_placeholder_elides() -> void:
	const LONG := "a placeholder text that is much longer than the field"
	var body := func():
		var doc := _mk("r18", '<ui:TextField name="f" class="f" placeholder-text="%s" />' % LONG
			+ '<ui:TextField name="g" placeholder-text="%s" style="width: 80px;" />' % LONG,
			'.f { width: 120px; text-overflow: ellipsis; }')
		await h.process_frame
		doc._restyle_now()
		var le := doc.get_native("f") as LineEdit
		var out: Array = []
		h.check(le != null, "the native is a LineEdit")
		h.check(le.placeholder_text.ends_with("...") and le.placeholder_text.length() < LONG.length(), "the placeholder elides")
		h.eq(le.tooltip_text, LONG, "the tooltip has the whole text")
		var width := le.size.x
		var font: Font = le.get_theme_font("font")
		var fs: int = le.get_theme_font_size("font_size")
		h.check(font.get_string_size(le.placeholder_text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= width, "the shown text fits")
		out.append(le.placeholder_text)
		h.eq((doc.get_native("g") as LineEdit).placeholder_text, LONG, "without text-overflow nothing elides")
		# A new width.
		doc.get_element_model("f").set_attribute("style", "width: 220px;")
		doc._restyle_now()
		await h.process_frame
		h.check(le.placeholder_text.length() > String(out[0]).length(), "a wider field shows more")
		out.append(le.placeholder_text)
		doc.get_element_model("f").set_attribute("style", "width: 900px;")
		doc._restyle_now()
		await h.process_frame
		h.eq(le.placeholder_text, LONG, "a field wide enough shows all of it")
		h.eq(le.tooltip_text, "", "and no tooltip")
		doc.get_element_model("f").set_attribute("style", "")
		doc._restyle_now()
		h.check(le.placeholder_text.ends_with("..."), "narrow again")
		# A new placeholder; the value hides the tooltip.
		doc.get_element_model("f").set_attribute("placeholder-text", "another text which also does not fit in here")
		doc._restyle_now()
		h.check(le.placeholder_text.begins_with("another"), "a new placeholder elides")
		h.eq(le.tooltip_text, "another text which also does not fit in here", "the tooltip follows")
		doc.set_field_value("f", "value")
		h.eq(le.tooltip_text, "", "a value: the placeholder and its tooltip do not show")
		doc.set_field_value("f", "")
		h.eq(le.tooltip_text, "another text which also does not fit in here", "empty again")
		# The style: a reload with no layout turns it off and on.
		var origin := String(doc.get_computed_style("f")["width"]["origin"]["file"])
		doc.reload_stylesheet(origin, '.f { width: 120px; }')
		h.eq(le.placeholder_text, "another text which also does not fit in here", "no ellipsis: the whole text")
		h.eq(le.tooltip_text, "", "and no tooltip")
		doc.reload_stylesheet(origin, '.f { width: 120px; text-overflow: ellipsis; -unity-text-overflow-position: start; }')
		h.check(le.placeholder_text.begins_with("..."), "the overflow position applies")
		out.append(le.placeholder_text)
		_unload(doc)
		return out
	await _both(body, "placeholder")


# ---------------------------------------------------------------------------
# R21: a signal when a split view changes size
# ---------------------------------------------------------------------------

func test_split_changed() -> void:
	var body := func():
		var doc := _mk("r21", '<ui:TwoPaneSplitView name="s" fixed-pane-initial-dimension="100" style="width: 400px; height: 200px;">'
			+ '<ui:VisualElement /><ui:VisualElement /></ui:TwoPaneSplitView>', '')
		await h.process_frame
		doc._restyle_now()
		var sent: Array = []
		doc.split_changed.connect(func(n, d): sent.append([n, d]))
		var dl := doc.get_control_for(UxmlContainerParts.get_part(_el(doc, "s"), "dragline"))
		var press := func(on: bool, x: float):
			var ev := InputEventMouseButton.new()
			ev.button_index = MOUSE_BUTTON_LEFT
			ev.pressed = on
			ev.global_position = Vector2(x, 10)
			dl.gui_input.emit(ev)
		var move := func(x: float):
			var ev := InputEventMouseMotion.new()
			ev.global_position = Vector2(x, 10)
			dl.gui_input.emit(ev)
		doc.set_split_dimension("s", 120.0)
		h.eq(sent, [], "set_split_dimension emits nothing")
		press.call(true, 50.0)
		press.call(false, 50.0)
		h.eq(sent, [], "a click without a move emits nothing")
		press.call(true, 50.0)
		move.call(60.0)
		move.call(80.0)
		h.eq(sent, [], "nothing during the drag")
		press.call(false, 80.0)
		h.eq(sent, [["s", 150.0]], "the end of the drag gives the name and the size")
		h.eq(doc.get_split_dimension("s"), 150.0, "get_split_dimension agrees")
		press.call(true, 80.0)
		move.call(90.0)
		move.call(80.0)
		press.call(false, 80.0)
		h.eq(sent.size(), 1, "a drag back to the start emits nothing")
		var out := [sent]
		_unload(doc)
		return out
	await _both(body, "split_changed")


# ---------------------------------------------------------------------------
# R22: text inside a ScrollView, a unitless flex-basis
# ---------------------------------------------------------------------------

func test_text_stable_in_scroll_view() -> void:
	var body := func():
		var doc := _mk("r22", '<ui:VisualElement name="col" style="width: 300px; height: 200px;">'
			+ '<ui:ScrollView name="sv" style="height: 150px;"><ui:Label name="in" text="short" />'
			+ '<ui:VisualElement name="line" style="flex-direction: row;">'
			+ '<ui:Label name="zero" text="a" style="flex-grow: 1; flex-basis: 0;" />'
			+ '<ui:Label name="zero2" text="a" style="flex-grow: 1; flex-basis: 0px;" /></ui:VisualElement>'
			+ '<ui:VisualElement style="height: 400px;" /></ui:ScrollView>'
			+ '<ui:ScrollView name="both" mode="VerticalAndHorizontal" style="height: 40px;"><ui:Label name="wide" text="w" /></ui:ScrollView>'
			+ '</ui:VisualElement>', '')
		await h.process_frame
		doc._restyle_now()
		await h.process_frame
		var out: Array = []
		var rect_of := func(names: Array) -> Array:
			var r: Array = []
			for n in names:
				r.append(doc.get_element_rect(_el(doc, n)))
			return r
		var names := ["sv", "in", "line", "zero", "zero2", "both", "wide"]
		for step in [["in", "a much longer text than the scroll view is wide, so that it would overflow the column at any font"],
				["zero", "a much longer text than the other cell of the row is wide"], ["in", "x"], ["zero", "y"]]:
			var n := doc.layout_count
			doc.set_text(step[0], step[1])
			doc._restyle_now()
			h.eq(doc.layout_count, n, "%s: a text change lays out nothing" % step[0])
			var kept: Array = rect_of.call(names)
			# A full layout gives the same rectangles: the skip loses nothing.
			doc.refresh()
			doc._restyle_now()
			doc._restyle_now()
			_same(kept, rect_of.call(names), "%s: the same rects as a full layout" % step[0])
			out.append(kept)
		var n2 := doc.layout_count
		doc.set_text("wide", "a much longer text than the horizontal scroll view is wide, so the content grows")
		doc._restyle_now()
		h.eq(doc.layout_count, n2 + 1, "with horizontal scrolling the content follows the text")
		out.append(rect_of.call(names))
		_unload(doc)
		return out
	await _both(body, "text in a ScrollView")


# ---------------------------------------------------------------------------
# R24: the selected row of a list without focus in the editor skins
# ---------------------------------------------------------------------------

func test_selected_row_in_the_editor_skins() -> void:
	var expected := {"dark": "rgb(77, 77, 77)", "light": "rgb(174, 174, 174)"}
	for skin in expected:
		var doc := UxmlDocument.new()
		doc.editor_theme = "always"
		doc.editor_skin = skin
		h.root.add_child(doc)
		doc.size = Vector2(200, 100)
		doc.load_source(UXML_HEAD + '<ui:ListView /><ui:VisualElement name="v" class="unity-collection-view">'
			+ '<ui:Label name="r" class="unity-collection-view__item--selected" text="t" /></ui:VisualElement></ui:UXML>')
		h.eq(String(doc.get_computed_style("r")["background-color"]["value"]), expected[skin], "%s: a view without focus" % skin)
		doc.set_element_state("v", "focus", true)
		doc._restyle_now()
		h.eq(String(doc.get_computed_style("r")["background-color"]["value"]), "rgb(58, 114, 176)", "%s: a focused view" % skin)
		_unload(doc)
# ---------------------------------------------------------------------------
# R29: a scroll of a collection view lays out only its rows
# ---------------------------------------------------------------------------

const R29_BODY := '<ui:VisualElement name="side" class="side">'\
	+ '<ui:TreeView name="tree" class="tree" fixed-item-height="20" />'\
	+ '<ui:ListView name="list" class="list" fixed-item-height="18" show-alternating-row-backgrounds="All" />'\
	+ '<ui:MultiColumnListView name="cols" class="list" fixed-item-height="18">'\
	+ '<ui:Columns><ui:Column name="a" title="A" width="80" /><ui:Column name="b" title="B" width="120" /></ui:Columns>'\
	+ '</ui:MultiColumnListView></ui:VisualElement><ui:Label name="after" text="after" />'
const R29_USS := '.side { width: 220px; flex-direction: column; } .tree { height: 120px; } .list { height: 90px; }'\
	+ ' .unity-collection-view__item--selected { padding-left: 3px; }'


static func _r29_roots(n: int, depth: int) -> Array:
	var out: Array = []
	for i in n:
		var kids: Array = _r29_roots(3, depth - 1) if depth > 0 and i % 3 == 0 else []
		out.append({"id": "%d-%d" % [depth, i] + ("x".repeat(i % 7)), "data": "Item %d %s" % [i, "long text ".repeat(i % 4)],
			"children": kids})
	return out


func test_scroll_lays_out_only_the_rows() -> void:
	var body := func():
		var doc := _mk("r29", R29_BODY, R29_USS)
		var ref := _mk("r29", R29_BODY, R29_USS)
		await h.process_frame
		var items: Array = []
		for i in 200:
			items.append("Row %d %s" % [i, "wide ".repeat(i % 5)])
		var cells := func(c: Control, i: int):
			if c is Label:
				(c as Label).text = "cell %d" % i
		for d in [doc, ref]:
			d.set_tree_source("tree", _r29_roots(40, 2))
			d.set_tree_item_expanded("tree", "2-0", true, true)
			d.set_items_source("list", items)
			d.set_items_source("cols", items)
			d.set_column_cell_bind("cols", "a", cells)
			_settle(d)
		var tp = load("res://tests/test_parking.gd")
		var out: Array = []
		var l0 := doc.layout_count
		var s0 := doc.local_layout_count
		var steps := [
			func(d): d.scroll_to_item("tree", 30),
			func(d): d.set_scroll_offset("tree", Vector2(0, 47)),
			func(d): d.set_selection("tree", [4]),
			func(d): d.scroll_to_item("tree", 4),
			func(d): d.set_scroll_offset("list", Vector2(0, 18 * 37 + 5)),
			func(d): d.set_selection("list", [40]),
			func(d): d.scroll_to_item("list", 150),
			func(d): d.set_tree_item_expanded("tree", "2-3", true),
			func(d): d.set_scroll_offset("tree", Vector2(0, 9)),
			func(d): d.set_scroll_offset("cols", Vector2(0, 18 * 20)),
			func(d): d.scroll_to_item("list", 0),
		]
		for k in steps.size():
			for d in [doc, ref]:
				(steps[k] as Callable).call(d)
				d._restyle_now()
				d._restyle_now()
			ref.relayout()
			_settle(ref)
			_same(tp.snapshot(doc, true), tp.snapshot(ref, true), "step %d: the controls equal a layout of the document" % k)
			out.append(_named_rects(doc))
		h.check(doc.local_layout_count > s0, "the scrolls lay out rows alone")
		out.append(doc.layout_count - l0)
		_unload(doc)
		_unload(ref)
		return out
	var tr := await _both(body, "scroll")
	# Expanding a tree item changes the content height (a layout); the
	# multi-column view scrolls horizontally (its rows follow their content).
	h.check(int(tr[-1]) <= 3, "scrolls run no layout of the document (%d layouts)" % int(tr[-1]))


# ---------------------------------------------------------------------------
# R28: a placeholder without a restyle
# ---------------------------------------------------------------------------

func test_set_field_placeholder() -> void:
	var fields := '<ui:TextField name="a" placeholder-text="start" /><ui:TextField name="b" />'\
		+ '<ui:FloatField name="num" placeholder-text="0" /><ui:Toggle name="tog" />'
	var uss := '.unity-text-field { width: 120px; text-overflow: ellipsis; }'
	var body := func():
		var doc := _mk("r28", fields, uss)
		var ref := _mk("r28", fields, uss)
		await h.process_frame
		_settle(doc)
		_settle(ref)
		var out: Array = []
		var l0 := doc.layout_count
		h.eq(doc.set_field_placeholder("tog", "x"), false, "a toggle has no placeholder")
		h.eq(doc.set_field_placeholder("missing", "x"), false, "an unknown name")
		var long := "computed 12.5px from .inspector-row:hover (theme)"
		h.eq(doc.set_field_placeholder("a", long), true, "a text field")
		h.eq(doc._restyle_queued, false, "a new placeholder queues no restyle")
		h.eq(doc._attr_dirty.size(), 0, "and marks nothing for the cascade")
		h.eq(doc.get_field_placeholder("a"), long, "get_field_placeholder")
		var le: LineEdit = doc.get_native("a")
		h.check(le.placeholder_text != long and le.placeholder_text.ends_with("..."), "the placeholder is elided (R18)")
		h.eq(le.tooltip_text, long, "the whole text is the tooltip")
		ref.get_element_model("a").set_attribute("placeholder-text", long)
		# Empty to a placeholder: the input gets the placeholder class.
		h.eq(doc.set_field_placeholder("b", "none"), true, "a field without a placeholder")
		ref.get_element_model("b").set_attribute("placeholder-text", "none")
		h.eq(doc.set_field_placeholder("num", "mixed"), true, "a numeric field")
		ref.get_element_model("num").set_attribute("placeholder-text", "mixed")
		_settle(ref)
		doc._restyle_now()
		doc._restyle_now()
		h.eq(doc.layout_count - l0, 0, "no layout")
		ref.relayout()
		_settle(ref)
		var tp = load("res://tests/test_parking.gd")
		_same(tp.snapshot(doc, true), tp.snapshot(ref, true), "the controls equal an attribute write with a restyle")
		var input_b := UxmlParts.find_part(doc.get_element_model("b"), "input")
		h.check(UxmlParts.control_classes(input_b).has("unity-base-text-field__input--placeholder"), "the placeholder class")
		out.append([le.placeholder_text, doc.get_native("b").placeholder_text])
		_unload(doc)
		_unload(ref)
		return out
	await _both(body, "placeholder")


