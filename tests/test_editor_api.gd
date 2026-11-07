extends RefCounted
## The tool APIs an editor uses (docs/design.md, "Editor APIs"): loads with
## a caller resolver, element handles, the source offset contract, partial
## reloads, cascade provenance, forced pseudo-states, transition snapshot
## and seek, the hit test, the element catalog, template instances, end
## offsets on diagnostics, drag and drop of collection items, and element
## rectangles in another element's space. Scenarios that read cascade, layout or
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
		h.eq(doc.get_element_for(Control.new()), null, "a control outside the document")
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
