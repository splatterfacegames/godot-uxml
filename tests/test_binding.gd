extends RefCounted
## Unity runtime data binding (data-source, data-source-path, <Bindings>,
## binding-path, converters, update triggers, two-way) and the common
## VisualElement attributes (tabindex, picking-mode, language-direction,
## usage-hints, view-data-key). `h` is the SceneTree harness from
## run_tests.gd.

const ROOT := "user://godot_uxml_binding"

var h = null


func _init(harness) -> void:
	h = harness


class Player:
	extends RefCounted
	signal property_changed(path)
	var player_name := "Ann"
	var score := 10
	var volume := 50.0
	var muted := false
	var nick := "ann"
	var stats := {"hp": 7, "items": ["sword", "shield"]}
	var pos := Vector2(3, 4)


class Hashed:
	extends RefCounted
	var label := "a"
	var version := 0

	func get_view_hash_code() -> int:
		return version


class Settings:
	extends Resource
	@export var title := "Options"


func _write(dir: String, files: Dictionary) -> String:
	var root := "%s/%s" % [ROOT, dir]
	for p in files:
		var full := "%s/%s" % [root, p]
		DirAccess.make_dir_recursive_absolute(full.get_base_dir())
		var f := FileAccess.open(full, FileAccess.WRITE)
		var text: String = files[p]
		if p.ends_with(".uxml"):
			text = '<ui:UXML xmlns:ui="UnityEngine.UIElements">%s</ui:UXML>' % text
		f.store_string(text)
		f.close()
	return root


func _open(dir: String, body: String, extra: Dictionary = {}, source: Variant = null) -> UxmlDocument:
	var files := {"Assets/UI/main.uxml": body}
	files.merge(extra)
	var root := _write(dir, files)
	var doc := UxmlDocument.new()
	h.root.add_child(doc)
	doc.size = Vector2(400, 600)
	if source != null:
		doc.set_data_source(source)
	doc.load_document("Assets/UI/main.uxml", root)
	return doc


func _close(doc: UxmlDocument) -> void:
	h.root.remove_child(doc)
	doc.queue_free()


func _kinds(warnings: Array) -> Array:
	var out: Array = []
	for d in warnings:
		out.append(d["kind"])
	return out


func _text(doc: UxmlDocument, n: String) -> String:
	return String(doc.get_native(n).text)


## The drawn text of a control part (UxmlParts role) of element `n`.
func _part_text(doc: UxmlDocument, n: String, role: String) -> String:
	var p := UxmlParts.find_part(doc.get_element_model(n), role)
	if p == null:
		return "<no part>"
	var c: Control = doc._controls.get(p)
	if c is RichTextLabel:
		return String(c.get_meta("uxml_rich_src", ""))
	return String(c.get("text"))


func _part_shown(doc: UxmlDocument, n: String, role: String) -> bool:
	var p := UxmlParts.find_part(doc.get_element_model(n), role)
	return p != null and (doc._controls.get(p) as Control).visible


# ---------------------------------------------------------------------------
# Model: <Bindings> extraction and PropertyPath
# ---------------------------------------------------------------------------

func test_bindings_leave_the_tree() -> void:
	var src := '<ui:UXML xmlns:ui="UnityEngine.UIElements"><ui:VisualElement name="box">' \
		+ '<Bindings><ui:DataBinding property="text" data-source-path="a.b" binding-mode="ToTarget" update-trigger="EveryUpdate" source-to-ui-converters="g1, g2"/></Bindings>' \
		+ '<ui:Label name="l"/></ui:VisualElement></ui:UXML>'
	var doc := UxmlLoader.load_source(src, "inline/b.uxml", UxmlResourceResolver.new("res://"))
	var box := doc.find_by_name("box")
	h.eq(box.children.size(), 1, "only the Label stays a child")
	h.eq(box.children[0].local, "Label", "the Label is the remaining child")
	for el in doc.root.walk():
		h.check(el.local != "Bindings" and el.local != "DataBinding", "no binding element in the tree")
	var list: Array = doc.bindings.get(box, [])
	h.eq(list.size(), 1, "one descriptor recorded")
	h.eq(list[0]["property"], "text", "property")
	h.eq(list[0]["parts"], ["a", "b"], "parsed path")
	h.eq(list[0]["mode"], UxmlBinding.TO_TARGET, "binding-mode")
	h.eq(list[0]["trigger"], UxmlBinding.EVERY_UPDATE, "update-trigger")
	h.eq(list[0]["to_ui"], ["g1", "g2"], "converter groups split")
	h.eq(doc.warnings.size(), 0, "no diagnostics: %s" % [doc.warnings])


func test_binding_diagnostics() -> void:
	var src := '<ui:UXML xmlns:ui="UnityEngine.UIElements"><Bindings/><ui:Label name="l">' \
		+ '<Bindings><ui:DataBinding data-source-path="a"/>' \
		+ '<ui:DataBinding property="text" binding-mode="Sideways" update-trigger="Hourly" bogus="1"/>' \
		+ '<ui:DataBinding property="text" data-source-path="a..b"/>' \
		+ '<ui:LocalizedString property="text"/></Bindings></ui:Label>' \
		+ '<ui:DataBinding property="text"/></ui:UXML>'
	var doc := UxmlLoader.load_source(src, "inline/d.uxml", UxmlResourceResolver.new("res://"))
	var kinds := _kinds(doc.warnings)
	h.eq(kinds.count("malformed"), 3, "root <Bindings>, missing property, stray DataBinding: %s" % [doc.warnings])
	h.eq(kinds.count("unsupported-value"), 3, "bad mode, bad trigger, bad path")
	h.eq(kinds.count("unsupported-attribute"), 1, "unknown DataBinding attribute")
	h.eq(kinds.count("unsupported-feature"), 1, "a C# binding type")
	h.eq(kinds.count("unsupported-control"), 0, "binding tags are known tags")
	var l := doc.find_by_name("l")
	h.eq((doc.bindings.get(l, []) as Array).size(), 1, "the binding with bad enums still loads")
	h.eq(doc.bindings[l][0]["mode"], UxmlBinding.TWO_WAY, "bad mode falls back to TwoWay")
	h.eq(doc.bindings[l][0]["trigger"], UxmlBinding.ON_SOURCE_CHANGED, "bad trigger falls back")


func test_base_attributes_are_known() -> void:
	var src := '<ui:UXML xmlns:ui="UnityEngine.UIElements"><ui:VisualElement data-source-path="a" data-source-type="Player, Assembly-CSharp" tabindex="1" picking-mode="Ignore" view-data-key="k" usage-hints="DynamicTransform" language-direction="RTL"><ui:Slider binding-path="volume"/></ui:VisualElement></ui:UXML>'
	var doc := UxmlLoader.load_source(src, "inline/k.uxml", UxmlResourceResolver.new("res://"))
	h.eq(_kinds(doc.warnings).count("unsupported-attribute"), 0, "base attributes accepted: %s" % [doc.warnings])


func test_property_path_syntax() -> void:
	h.eq(UxmlBindings.parse_path("a.b[2].c"), ["a", "b", 2, "c"], "names and index")
	h.eq(UxmlBindings.parse_path(""), [], "empty path")
	h.eq(UxmlBindings.parse_path("[3]"), [3], "index only")
	h.eq(UxmlBindings.parse_path('map["k ey"].x'), ["map", "k ey", "x"], "quoted key")
	h.eq(UxmlBindings.parse_path("map[key]"), ["map", "key"], "bare key")
	for bad in ["a..b", ".a", "a.", "a[", "a[]", "a[-1]", "a.[0]", "a b"]:
		h.eq(UxmlBindings.parse_path(bad), null, "invalid path %s" % bad)
	h.eq(UxmlBindings.path_to_string(["a", 2, "c"]), "a[2].c", "round trip")


func test_bindings_do_not_change_layout() -> void:
	var with := '<ui:VisualElement name="row" style="flex-direction: row; justify-content: space-between; width: 300px;">' \
		+ '<Bindings><ui:DataBinding property="style.opacity" data-source-path="x"/></Bindings>' \
		+ '<ui:Label name="a" text="A"/><ui:Label name="b" text="B"/></ui:VisualElement>'
	var without := '<ui:VisualElement name="row" style="flex-direction: row; justify-content: space-between; width: 300px;">' \
		+ '<ui:Label name="a" text="A"/><ui:Label name="b" text="B"/></ui:VisualElement>'
	var d1 := _open("layout1", with)
	var d2 := _open("layout2", without)
	await h.process_frame
	h.eq(d1.get_element("b").position, d2.get_element("b").position, "a <Bindings> child takes no space")
	h.eq(d1.get_element("row").get_child_count(), d2.get_element("row").get_child_count(), "no control for <Bindings>")
	_close(d1)
	_close(d2)


# ---------------------------------------------------------------------------
# Runtime: data sources and contexts
# ---------------------------------------------------------------------------

func test_paths_compose_down_the_hierarchy() -> void:
	var p := Player.new()
	var doc := _open("compose", '<ui:VisualElement name="outer" data-source-path="stats">' \
		+ '<ui:VisualElement name="inner" data-source-path="items">' \
		+ '<ui:Label name="first"><Bindings><ui:DataBinding property="text" data-source-path="[1]"/></Bindings></ui:Label>' \
		+ '</ui:VisualElement>' \
		+ '<ui:Label name="hp"><Bindings><ui:DataBinding property="text" data-source-path="hp"/></Bindings></ui:Label>' \
		+ '</ui:VisualElement>' \
		+ '<ui:Label name="who" data-source-path="playerName"><Bindings><ui:DataBinding property="text"/></Bindings></ui:Label>', {}, p)
	h.eq(_text(doc, "first"), "shield", "root source + stats + items + [1]")
	h.eq(_text(doc, "hp"), "7", "root source + stats + hp")
	h.eq(_text(doc, "who"), "Ann", "camelCase path reads the snake_case property")
	var ctx := doc.get_data_source_context("first")
	h.check(is_same(ctx["source"], p), "context source is the document source")
	h.eq(ctx["path"], "stats.items", "context path composes")
	h.eq(_kinds(doc.diagnostics).count("binding-failed"), 0, "no binding failures: %s" % [doc.diagnostics])
	_close(doc)


func test_nearest_source_wins_and_binding_source() -> void:
	var a := {"title": "outer", "inner": {"title": "nested"}}
	var b := {"title": "own"}
	UxmlDocument.register_data_source_asset("Assets/Data/B.asset", b)
	var doc := _open("nearest", '<ui:VisualElement name="panel" data-source-path="inner">' \
		+ '<ui:Label name="t1"><Bindings><ui:DataBinding property="text" data-source-path="title"/></Bindings></ui:Label>' \
		+ '<ui:Label name="t2"><Bindings><ui:DataBinding property="text" data-source-path="title" data-source="project://database/Assets/Data/B.asset?fileID=11400000&amp;guid=0&amp;type=2#B"/></Bindings></ui:Label>' \
		+ '</ui:VisualElement>', {}, a)
	h.eq(_text(doc, "t1"), "nested", "document source with composed path")
	h.eq(_text(doc, "t2"), "own", "a DataBinding data-source uses only its own path")
	doc.set_data_source({"inner": {"title": "panel"}}, "panel")
	doc.update_bindings()
	h.eq(_text(doc, "t1"), "panel", "the nearest source wins; its holder's own path still applies")
	h.eq(_text(doc, "t2"), "own", "a binding source ignores the element source")
	UxmlDocument.register_data_source_asset("Assets/Data/B.asset", null)
	_close(doc)


func test_element_source_takes_its_own_path() -> void:
	# Unity: the element that holds the data source contributes its own
	# data-source-path; ancestors above it do not.
	var doc := _open("ownpath", '<ui:VisualElement data-source-path="ignored">' \
		+ '<ui:VisualElement name="panel" data-source-path="inner">' \
		+ '<ui:Label name="t"><Bindings><ui:DataBinding property="text" data-source-path="title"/></Bindings></ui:Label>' \
		+ '</ui:VisualElement></ui:VisualElement>')
	doc.set_data_source({"inner": {"title": "deep"}}, "panel")
	doc.update_bindings()
	h.eq(_text(doc, "t"), "deep", "source holder's path + binding path")
	h.eq(doc.get_data_source_context("t")["path"], "inner", "ancestor paths above the source holder are not used")
	_close(doc)


func test_json_and_resource_data_source_assets() -> void:
	var root := _write("assets", {"Assets/Data/menu.json": '{"title": "From JSON", "rows": [1, 2, 3]}'})
	var s := Settings.new()
	s.title = "From resource"
	UxmlDocument.register_data_source_asset("settings", s)
	var doc := _open("assets", '<ui:Label name="j" data-source="../Data/menu.json"><Bindings><ui:DataBinding property="text" data-source-path="rows[2]"/></Bindings></ui:Label>' \
		+ '<ui:Label name="r" data-source="settings"><Bindings><ui:DataBinding property="text" data-source-path="title"/></Bindings></ui:Label>' \
		+ '<ui:Label name="m" data-source="Assets/Data/missing.asset"><Bindings><ui:DataBinding property="text" data-source-path="x"/></Bindings></ui:Label>')
	h.check(not root.is_empty(), "fixture written")
	h.eq(_text(doc, "j"), "3", "JSON file as data source")
	h.eq(_text(doc, "r"), "From resource", "registered asset key")
	h.check(_kinds(doc.diagnostics).has("missing-file"), "an unknown asset is diagnosed")
	UxmlDocument.register_data_source_asset("settings", null)
	_close(doc)


func test_document_source_survives_reload() -> void:
	var doc := _open("reload", '<ui:Label name="l"><Bindings><ui:DataBinding property="text" data-source-path="title"/></Bindings></ui:Label>', {}, {"title": "kept"})
	h.eq(_text(doc, "l"), "kept", "bound before reload")
	doc.reload()
	h.eq(_text(doc, "l"), "kept", "bound after reload")
	_close(doc)


# ---------------------------------------------------------------------------
# Update triggers and modes
# ---------------------------------------------------------------------------

func test_on_source_changed_needs_a_notification() -> void:
	var data := {"score": 1, "name": "x"}
	var doc := _open("osc", '<ui:Label name="score"><Bindings><ui:DataBinding property="text" data-source-path="score"/></Bindings></ui:Label>', {}, data)
	h.eq(_text(doc, "score"), "1", "initial")
	data["score"] = 2
	await h.process_frame
	h.eq(_text(doc, "score"), "1", "no notification: no update")
	doc.notify_changed(data, "name")
	await h.process_frame
	h.eq(_text(doc, "score"), "1", "a change at another path does not update")
	doc.notify_changed(data, "score")
	await h.process_frame
	h.eq(_text(doc, "score"), "2", "notify_changed updates on the next frame")
	data["score"] = 3
	doc.notify_changed(data)
	doc.update_bindings()
	h.eq(_text(doc, "score"), "3", "an empty path matches every binding; update_bindings flushes now")
	h.check(not doc._binding._ticking, "no frame hook without EveryUpdate bindings")
	_close(doc)


func test_source_signals() -> void:
	var p := Player.new()
	var s := Settings.new()
	var doc := _open("signals", '<ui:Label name="n"><Bindings><ui:DataBinding property="text" data-source-path="player_name"/></Bindings></ui:Label>' \
		+ '<ui:Label name="t"><Bindings><ui:DataBinding property="text" data-source-path="title"/></Bindings></ui:Label>', {}, p)
	doc.set_data_source(s, "t")
	doc.update_bindings()
	h.eq(_text(doc, "t"), "Options", "resource source")
	p.player_name = "Bob"
	p.property_changed.emit("player_name")
	await h.process_frame
	h.eq(_text(doc, "n"), "Bob", "property_changed(path) signal updates")
	s.title = "Changed"
	s.emit_changed()
	await h.process_frame
	h.eq(_text(doc, "t"), "Changed", "Resource.changed updates")
	_close(doc)


func test_view_hash_provider_is_polled() -> void:
	var src := Hashed.new()
	var doc := _open("hash", '<ui:Label name="l"><Bindings><ui:DataBinding property="text" data-source-path="label"/></Bindings></ui:Label>', {}, src)
	h.check(doc._binding._ticking, "a hash provider source starts the frame hook")
	src.label = "b"
	await h.process_frame
	h.eq(_text(doc, "l"), "a", "same hash: no update")
	src.version += 1
	await h.process_frame
	await h.process_frame
	h.eq(_text(doc, "l"), "b", "new hash: update")
	_close(doc)
	h.check(not doc._binding._ticking, "the frame hook stops on unload")


func test_every_update_once_and_dirty() -> void:
	var data := {"a": 1, "b": 1, "c": 1}
	var doc := _open("triggers", '<ui:Label name="a"><Bindings><ui:DataBinding property="text" data-source-path="a" update-trigger="EveryUpdate"/></Bindings></ui:Label>' \
		+ '<ui:Label name="b"><Bindings><ui:DataBinding property="text" data-source-path="b" binding-mode="ToTargetOnce"/></Bindings></ui:Label>' \
		+ '<ui:Label name="c"><Bindings><ui:DataBinding property="text" data-source-path="c" update-trigger="WhenDirty"/></Bindings></ui:Label>', {}, data)
	h.check(doc._binding._ticking, "EveryUpdate starts the frame hook")
	data["a"] = 2
	data["b"] = 2
	data["c"] = 2
	doc.notify_changed(data)
	await h.process_frame
	await h.process_frame
	h.eq(_text(doc, "a"), "2", "EveryUpdate polls")
	h.eq(_text(doc, "b"), "1", "ToTargetOnce ignores changes")
	h.eq(_text(doc, "c"), "1", "WhenDirty ignores notifications")
	doc.mark_binding_dirty("c", "text")
	doc.mark_binding_dirty("b")
	doc.update_bindings()
	h.eq(_text(doc, "c"), "2", "WhenDirty updates when marked dirty")
	h.eq(_text(doc, "b"), "2", "a dirty ToTargetOnce binding updates")
	_close(doc)


func test_two_way_write_back() -> void:
	var p := Player.new()
	var doc := _open("twoway", '<ui:Slider name="vol" low-value="0" high-value="100"><Bindings><ui:DataBinding property="value" data-source-path="volume"/></Bindings></ui:Slider>' \
		+ '<ui:SliderInt name="score" low-value="0" high-value="100"><Bindings><ui:DataBinding property="value" data-source-path="score"/></Bindings></ui:SliderInt>' \
		+ '<ui:Toggle name="mute"><Bindings><ui:DataBinding property="value" data-source-path="muted"/></Bindings></ui:Toggle>' \
		+ '<ui:TextField name="nick"><Bindings><ui:DataBinding property="value" data-source-path="nick"/></Bindings></ui:TextField>' \
		+ '<ui:Label name="echo"><Bindings><ui:DataBinding property="text" data-source-path="nick"/></Bindings></ui:Label>' \
		+ '<ui:Slider name="ro" low-value="0" high-value="10"><Bindings><ui:DataBinding property="value" data-source-path="pos.x" binding-mode="ToTarget"/></Bindings></ui:Slider>' \
		+ '<ui:Slider name="ts" low-value="0" high-value="10"><Bindings><ui:DataBinding property="value" data-source-path="pos.y" binding-mode="ToSource"/></Bindings></ui:Slider>', {}, p)
	h.eq((doc.get_native("vol") as HSlider).value, 50.0, "source -> slider")
	h.eq((doc.get_native("score") as HSlider).value, 10.0, "source -> slider int")
	h.eq((doc.get_native("ro") as HSlider).value, 3.0, "ToTarget reads a Vector2 member")
	h.eq((doc.get_native("ts") as HSlider).value, 0.0, "ToSource never writes the UI")
	var changed: Array = []
	doc.value_changed.connect(func(n, v): changed.append([n, v]))
	(doc.get_native("vol") as HSlider).value = 25
	h.eq(p.volume, 25.0, "slider -> source")
	(doc.get_native("score") as HSlider).value = 42
	h.eq(p.score, 42, "slider int -> int source")
	(doc.get_native("mute") as UxmlToggle).button_pressed = true
	h.eq(p.muted, true, "toggle -> source")
	var le := doc.get_native("nick") as LineEdit
	le.text = "zed"
	le.text_changed.emit("zed")
	h.eq(p.nick, "zed", "text field -> source")
	doc.update_bindings()
	h.eq(_text(doc, "echo"), "zed", "a write-back refreshes the other bindings of the path")
	(doc.get_native("ro") as HSlider).value = 9
	h.eq(p.pos.x, 3.0, "ToTarget does not write back")
	(doc.get_native("ts") as HSlider).value = 6
	h.eq(p.pos.y, 6.0, "ToSource writes a Vector2 member back into the Object")
	h.check(changed.size() >= 4, "document value_changed still fires")
	_close(doc)


func test_focused_text_field_is_not_overwritten() -> void:
	var data := {"nick": "a"}
	var doc := _open("focus", '<ui:TextField name="nick"><Bindings><ui:DataBinding property="value" data-source-path="nick"/></Bindings></ui:TextField>', {}, data)
	var le := doc.get_native("nick") as LineEdit
	le.grab_focus()
	data["nick"] = "b"
	doc.notify_changed(data, "nick")
	doc.update_bindings()
	h.eq(le.text, "a", "the focused field keeps the user's text")
	le.release_focus()
	doc.notify_changed(data, "nick")
	doc.update_bindings()
	h.eq(le.text, "b", "an unfocused field updates")
	_close(doc)


func test_converters() -> void:
	UxmlDocument.register_converter("percent", func(v): return "%d%%" % roundi(float(v)), TYPE_FLOAT)
	UxmlDocument.register_converter("percent", func(v): return "n/a")
	UxmlDocument.register_converter("from-ui", func(v): return float(v) / 10.0)
	var p := Player.new()
	var doc := _open("conv", '<ui:Label name="pct"><Bindings><ui:DataBinding property="text" data-source-path="volume" source-to-ui-converters="percent"/></Bindings></ui:Label>' \
		+ '<ui:Label name="str"><Bindings><ui:DataBinding property="text" data-source-path="player_name" source-to-ui-converters="percent"/></Bindings></ui:Label>' \
		+ '<ui:Slider name="s" low-value="0" high-value="10"><Bindings><ui:DataBinding property="value" data-source-path="volume" binding-mode="ToSource" ui-to-source-converters="from-ui"/></Bindings></ui:Slider>' \
		+ '<ui:Label name="nog"><Bindings><ui:DataBinding property="text" data-source-path="score" source-to-ui-converters="nope"/></Bindings></ui:Label>', {}, p)
	h.eq(_text(doc, "pct"), "50%", "typed converter for floats")
	h.eq(_text(doc, "str"), "n/a", "untyped converter for other types")
	(doc.get_native("s") as HSlider).value = 8
	h.eq(p.volume, 0.8, "ui-to-source converter")
	h.eq(_text(doc, "nog"), "10", "an unknown group leaves the value")
	h.check(_kinds(doc.diagnostics).has("binding-failed"), "an unknown group is diagnosed")
	UxmlDocument.unregister_converter_group("percent")
	UxmlDocument.unregister_converter_group("from-ui")
	_close(doc)


# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

func test_element_property_targets() -> void:
	var data := {"label": "Volume", "lo": 2, "hi": 20, "val": 5, "tip": "hint",
		"on": false, "shown": false, "choices": ["Low", "High"], "pick": "High",
		"cap": "Caption", "btn": "Go"}
	var doc := _open("targets", '<ui:Slider name="s"><Bindings>' \
		+ '<ui:DataBinding property="label" data-source-path="label"/>' \
		+ '<ui:DataBinding property="lowValue" data-source-path="lo"/>' \
		+ '<ui:DataBinding property="high-value" data-source-path="hi"/>' \
		+ '<ui:DataBinding property="value" data-source-path="val"/>' \
		+ '<ui:DataBinding property="tooltip" data-source-path="tip"/></Bindings></ui:Slider>' \
		+ '<ui:Button name="b"><Bindings><ui:DataBinding property="enabledSelf" data-source-path="on"/>' \
		+ '<ui:DataBinding property="text" data-source-path="btn"/></Bindings></ui:Button>' \
		+ '<ui:Label name="l" text="x"><Bindings><ui:DataBinding property="visible" data-source-path="shown"/></Bindings></ui:Label>' \
		+ '<ui:DropdownField name="d"><Bindings><ui:DataBinding property="choices" data-source-path="choices"/>' \
		+ '<ui:DataBinding property="value" data-source-path="pick"/></Bindings></ui:DropdownField>' \
		+ '<ui:Toggle name="t"><Bindings><ui:DataBinding property="label" data-source-path="cap"/></Bindings></ui:Toggle>', {}, data)
	await h.process_frame
	var s := doc.get_native("s") as HSlider
	h.eq((doc.get_element("s") as UxmlField).caption.text, "Volume", "label")
	h.eq(s.min_value, 2.0, "lowValue")
	h.eq(s.max_value, 20.0, "high-value")
	h.eq(s.value, 5.0, "value")
	h.eq(doc.get_element("s").tooltip_text, "hint", "tooltip")
	h.eq(doc.get_element_model("s").get_attribute("label"), "Volume", "the model attribute follows")
	h.check((doc.get_native("b") as Button).disabled, "enabledSelf false disables")
	h.eq(_text(doc, "b"), "Go", "button text")
	h.check(not doc.get_element("l").visible, "visible false hides")
	var ob := doc.get_native("d") as OptionButton
	h.eq(ob.item_count, 2, "choices")
	h.eq(ob.get_item_text(ob.selected), "High", "dropdown value selects by text")
	h.eq(_part_text(doc, "t", "label"), "Caption", "toggle label")
	data["on"] = true
	data["shown"] = true
	doc.notify_changed(data)
	await h.process_frame
	await h.process_frame
	h.check(not (doc.get_native("b") as Button).disabled, "enabledSelf true enables")
	h.check(doc.get_element("l").visible, "visible true shows")
	h.eq(_kinds(doc.diagnostics).count("binding-failed"), 0, "no failures: %s" % [doc.diagnostics])
	_close(doc)


func test_style_targets() -> void:
	var data := {"bg": Color(1, 0, 0, 1), "w": 120, "op": 0.5, "disp": "flex"}
	var doc := _open("style", '<ui:VisualElement name="box" style="height: 30px; width: 10px;"><Bindings>' \
		+ '<ui:DataBinding property="style.backgroundColor" data-source-path="bg"/>' \
		+ '<ui:DataBinding property="style.width" data-source-path="w"/>' \
		+ '<ui:DataBinding property="style.opacity" data-source-path="op"/>' \
		+ '<ui:DataBinding property="style.display" data-source-path="disp"/></Bindings></ui:VisualElement>', {}, data)
	await h.process_frame
	var st := doc.get_computed_style("box")
	h.eq(String(st["background-color"]["value"]), "rgba(255, 0, 0, 1)", "style.backgroundColor from a Color")
	h.eq(String(st["width"]["value"]), "120px", "style.width from a number gets px")
	h.eq(String(st["opacity"]["value"]), "0.5", "style.opacity stays unitless")
	h.eq(doc.get_element("box").size.x, 120.0, "the bound width reaches the layout")
	h.eq(String(st["height"]["value"]), "30px", "authored inline style is kept")
	data["disp"] = "none"
	doc.notify_changed(data, "disp")
	await h.process_frame
	await h.process_frame
	h.check(not doc.get_element("box").visible, "style.display none hides")
	h.eq(UxmlBinding.uss_name("unityFontStyleAndWeight"), "-unity-font-style", "Unity style name")
	h.eq(UxmlBinding.uss_name("unityBackgroundImageTintColor"), "-unity-background-image-tint-color", "unity prefix")
	h.eq(UxmlBinding.uss_name("borderTopLeftRadius"), "border-top-left-radius", "camelCase")
	_close(doc)


func test_binding_path_maps_to_value() -> void:
	var p := Player.new()
	var doc := _open("bpath", '<ui:VisualElement data-source-path="stats">' \
		+ '<ui:Label name="hp" binding-path="hp"/></ui:VisualElement>' \
		+ '<ui:Slider name="v" low-value="0" high-value="100" binding-path="volume"/>' \
		+ '<ui:VisualElement name="ve" binding-path="x"/>', {}, p)
	h.eq(_text(doc, "hp"), "7", "Label binding-path binds text inside the context path")
	h.eq((doc.get_native("v") as HSlider).value, 50.0, "Slider binding-path binds value")
	(doc.get_native("v") as HSlider).value = 75
	h.eq(p.volume, 75.0, "binding-path is two-way")
	h.eq(doc.get_bindings("v")[0]["origin"], "binding-path", "binding origin is reported")
	h.check(_kinds(doc.diagnostics).has("binding-failed"), "binding-path on a VisualElement is diagnosed")
	_close(doc)


func test_code_bindings_and_bad_targets() -> void:
	var data := {"t": "code"}
	var doc := _open("code", '<ui:Label name="l"/><ui:VisualElement name="v"><Bindings><ui:DataBinding property="nonsense" data-source-path="t"/></Bindings></ui:VisualElement>' \
		+ '<ui:Label name="miss"><Bindings><ui:DataBinding property="text" data-source-path="nope.deeper"/></Bindings></ui:Label>', {}, data)
	h.check(doc.add_binding("l", "text", "t", {"mode": "ToTarget"}), "add_binding")
	doc.update_bindings()
	h.eq(_text(doc, "l"), "code", "a binding made in code")
	h.eq(doc.get_bindings("l").size(), 1, "one binding")
	doc.add_binding("l", "text", "t")
	h.eq(doc.get_bindings("l").size(), 1, "the same property replaces the binding")
	doc.remove_binding("l", "text")
	h.eq(doc.get_bindings("l").size(), 0, "remove_binding")
	var kinds := _kinds(doc.diagnostics)
	h.check(kinds.count("binding-failed") >= 2, "unknown property and unresolved path diagnosed: %s" % [doc.diagnostics])
	_close(doc)


func test_list_view_items_source_auto_assign() -> void:
	var items := [{"name": "one"}, {"name": "two"}, {"name": "three"}]
	var doc := _open("list", '<ui:ListView name="list" fixed-item-height="20" item-template="row.uxml" binding-source-selection-mode="AutoAssign" style="height: 200px;">' \
		+ '<Bindings><ui:DataBinding property="itemsSource" data-source-path="items"/></Bindings></ui:ListView>',
		{"Assets/UI/row.uxml": '<ui:Label name="title"><Bindings><ui:DataBinding property="text" data-source-path="name"/></Bindings></ui:Label>'},
		{"items": items})
	await h.process_frame
	var rows: Array = doc.get_list_rows("list")
	h.check(rows.size() >= 3, "pooled rows")
	h.eq((rows[0] as UxmlListRow).get_native("title").text, "one", "row 0 bound to items[0]")
	h.eq((rows[2] as UxmlListRow).get_native("title").text, "three", "row 2 bound to items[2]")
	h.eq((rows[0] as UxmlListRow).index, 0, "row index")
	h.check((rows[3] as UxmlListRow).index < 0, "rows past the count are unused")
	h.eq(_kinds(doc.diagnostics).count("unsupported-control"), 0, "no binding tag reaches the factory")
	_close(doc)
	doc = _open("list2", '<ui:ListView name="list" fixed-item-height="20" item-template="row.uxml" style="height: 200px;"/>',
		{"Assets/UI/row.uxml": '<ui:Label name="title"><Bindings><ui:DataBinding property="text" binding-mode="Bogus"/></Bindings></ui:Label>'})
	h.eq(_kinds(doc.diagnostics).count("unsupported-value"), 1, "a bad binding in an item template reports once, not once per row")
	_close(doc)


func test_bindings_inside_templates() -> void:
	var doc := _open("tmpl", '<ui:Template name="Card" src="card.uxml"/><ui:Instance template="Card" data-source-path="a"/>' \
		+ '<ui:Instance template="Card" data-source-path="b"/>',
		{"Assets/UI/card.uxml": '<ui:Label name="v"><Bindings><ui:DataBinding property="text" data-source-path="v"/></Bindings></ui:Label>'},
		{"a": {"v": "A"}, "b": {"v": "B"}})
	var labels: Array = []
	for el in doc._controls:
		if el.local == "Label":
			labels.append(doc._natives[el].text)
	labels.sort()
	h.eq(labels, ["A", "B"], "each instance binds through its own data-source-path")
	h.eq(_kinds(doc.diagnostics).count("unsupported-control"), 0, "no binding tags left: %s" % [doc.diagnostics])
	_close(doc)


# ---------------------------------------------------------------------------
# Part-tree controls (runtime/controls/): bindings write through behaviors
# ---------------------------------------------------------------------------

func test_part_tree_control_targets() -> void:
	var data := {"on": true, "cap": "", "txt": "Mute", "radio": true,
		"open": false, "ftext": "Section", "pv": 25, "plo": 0, "phi": 50, "ptitle": "Half",
		"gtext": "Group", "htext": "Careful", "htype": "Warning", "ptext": "Popup",
		"pick": 2, "sel": [1]}
	var doc := _open("parts", '<ui:Toggle name="t"><Bindings>' \
		+ '<ui:DataBinding property="value" data-source-path="on"/>' \
		+ '<ui:DataBinding property="label" data-source-path="cap"/>' \
		+ '<ui:DataBinding property="text" data-source-path="txt"/></Bindings></ui:Toggle>' \
		+ '<ui:RadioButton name="r"><Bindings><ui:DataBinding property="value" data-source-path="radio"/></Bindings></ui:RadioButton>' \
		+ '<ui:Foldout name="f"><Bindings><ui:DataBinding property="value" data-source-path="open"/>' \
		+ '<ui:DataBinding property="text" data-source-path="ftext"/></Bindings><ui:Label name="inner" text="in"/></ui:Foldout>' \
		+ '<ui:ProgressBar name="p"><Bindings><ui:DataBinding property="value" data-source-path="pv"/>' \
		+ '<ui:DataBinding property="lowValue" data-source-path="plo"/>' \
		+ '<ui:DataBinding property="highValue" data-source-path="phi"/>' \
		+ '<ui:DataBinding property="title" data-source-path="ptitle"/></Bindings></ui:ProgressBar>' \
		+ '<ui:GroupBox name="g"><Bindings><ui:DataBinding property="text" data-source-path="gtext"/></Bindings></ui:GroupBox>' \
		+ '<ui:HelpBox name="hb" message-type="Info"><Bindings><ui:DataBinding property="text" data-source-path="htext"/>' \
		+ '<ui:DataBinding property="messageType" data-source-path="htype"/></Bindings></ui:HelpBox>' \
		+ '<ui:PopupWindow name="pw"><Bindings><ui:DataBinding property="text" data-source-path="ptext"/></Bindings></ui:PopupWindow>' \
		+ '<ui:RadioButtonGroup name="rg" choices="a,b,c"><Bindings><ui:DataBinding property="value" data-source-path="pick"/></Bindings></ui:RadioButtonGroup>' \
		+ '<ui:ToggleButtonGroup name="tg"><Bindings><ui:DataBinding property="value" data-source-path="sel"/></Bindings>' \
		+ '<ui:Button text="x"/><ui:Button text="y"/><ui:Button text="z"/></ui:ToggleButtonGroup>', {}, data)
	await h.process_frame
	await h.process_frame
	var t := doc.get_native("t") as UxmlToggle
	h.check(t.button_pressed, "Toggle value from the source")
	h.check("checked" in doc._states.get(doc.get_element_model("t"), {}), "a bound Toggle value sets :checked")
	h.eq(_part_text(doc, "t", "text"), "Mute", "Toggle text part")
	h.check(not _part_shown(doc, "t", "label"), "an empty bound label keeps the label part hidden")
	h.check("unity-base-field--no-label" in doc.get_element_model("t").class_list(), "empty bound label: --no-label")
	h.check((doc.get_native("r") as UxmlToggle).button_pressed, "RadioButton value")
	var f := doc.get_element_model("f")
	var content := UxmlParts.content_container(f)
	h.eq(content.get_attribute("style"), "display: none;", "Foldout value false closes #unity-content")
	h.check(doc.get_element_model("inner") in content.children, "author children stay in the content container")
	h.eq(_part_text_of(doc, UxmlParts.find_part(f, "toggle"), "text"), "Section", "Foldout text reaches the Toggle part")
	var pe := doc.get_element_model("p")
	h.eq(UxmlParts.find_part(pe, "progress").get_attribute("style"), "right: 50%;", "ProgressBar value / high-value")
	h.eq(_part_text(doc, "p", "title"), "Half", "ProgressBar title")
	h.eq(_part_text(doc, "g", "label"), "Group", "GroupBox text label part (hidden placeholder shown)")
	h.check(_part_shown(doc, "g", "label"), "a non-empty bound GroupBox text shows the label")
	h.eq(_part_text(doc, "hb", "label"), "Careful", "HelpBox text")
	h.check("unity-help-box__icon--warning" in UxmlParts.find_part(doc.get_element_model("hb"), "icon").class_list(), "HelpBox messageType")
	h.eq(_text(doc, "pw"), "Popup", "PopupWindow text")
	var rg := doc.get_element_model("rg")
	var radios: Array = UxmlParts.find_part(rg, "choices").children
	h.check((doc._controls[radios[2]] as UxmlToggle).button_pressed, "RadioButtonGroup value selects the radio")
	h.eq(doc._behaviors[doc.get_element_model("tg")].selected_indices(), [1], "ToggleButtonGroup value")
	h.eq(_kinds(doc.diagnostics).count("binding-failed"), 0, "no failures: %s" % [doc.diagnostics])

	# Source changes after load.
	data["cap"] = "Sound"
	data["on"] = false
	data["open"] = true
	data["pick"] = 0
	doc.notify_changed(data)
	await h.process_frame
	await h.process_frame
	h.eq(_part_text(doc, "t", "label"), "Sound", "a bound label part shows its text")
	h.check(_part_shown(doc, "t", "label"), "the label part shows once not empty")
	h.check(not ("unity-base-field--no-label" in doc.get_element_model("t").class_list()), "--no-label leaves")
	h.check(not t.button_pressed, "Toggle value false")
	h.check(not doc._styles.get(UxmlParts.find_part(doc.get_element_model("t"), "input"), {}).is_empty(), "parts restyle")
	h.check(content.get_attribute("style") == null or content.get_attribute("style") == "", "Foldout opens from the source")
	h.check((doc._controls[radios[0]] as UxmlToggle).button_pressed and not (doc._controls[radios[2]] as UxmlToggle).button_pressed, "RadioButtonGroup reselects")

	# Two-way: user edits write the source back.
	t.button_pressed = true
	h.eq(data["on"], true, "Toggle -> source")
	(doc._controls[UxmlParts.find_part(f, "toggle")] as UxmlToggle).button_pressed = false
	h.eq(data["open"], false, "Foldout -> source")
	(doc._controls[radios[1]] as UxmlToggle).button_pressed = true
	h.eq(data["pick"], 1, "RadioButtonGroup -> source")
	var tg_b: Array = UxmlParts.content_container(doc.get_element_model("tg")).children
	(doc._controls[tg_b[2]] as Button).pressed.emit()
	h.eq(data["sel"], [2], "ToggleButtonGroup -> source")
	_close(doc)


func _part_text_of(doc: UxmlDocument, owner: UxmlElement, role: String) -> String:
	var p := UxmlParts.find_part(owner, role)
	if p == null:
		return "<no part>"
	return String((doc._controls.get(p) as Control).get("text"))


## Template instances inside part-tree controls: the Instance becomes an
## author child of the control and moves into its content container; the
## bindings inside the template still bind.
func test_bindings_in_templates_inside_controls() -> void:
	var data := {"rows": {"v": "Row text", "on": true}}
	var doc := _open("tmplctl", '<ui:Template name="Row" src="row.uxml"/>' \
		+ '<ui:Foldout name="f" text="F"><ui:Instance template="Row" data-source-path="rows"/></ui:Foldout>' \
		+ '<ui:GroupBox name="g" text="G"><ui:Instance template="Row" data-source-path="rows"/></ui:GroupBox>',
		{"Assets/UI/row.uxml": '<ui:Label name="v"><Bindings><ui:DataBinding property="text" data-source-path="v"/></Bindings></ui:Label>' \
			+ '<ui:Toggle name="tt"><Bindings><ui:DataBinding property="value" data-source-path="on"/></Bindings></ui:Toggle>'},
		data)
	await h.process_frame
	var f := doc.get_element_model("f")
	var content := UxmlParts.content_container(f)
	h.eq(content.children.size(), 1, "the instance is in #unity-content")
	h.eq(content.children[0].local, "TemplateContainer", "as a TemplateContainer")
	var labels: Array = []
	var toggles := 0
	for el in doc._controls:
		if el.local == "Label" and el.part_of == null:
			labels.append(_shown(doc._controls[el]))
		if el.local == "Toggle" and el.part_of == null and (doc._controls[el] as UxmlToggle).button_pressed:
			toggles += 1
	h.eq(labels, ["Row text", "Row text"], "template bindings inside Foldout and GroupBox")
	h.eq(toggles, 2, "template Toggle values bind")
	_close(doc)


func _shown(c: Control) -> String:
	if c is RichTextLabel:
		return String(c.get_meta("uxml_rich_src", ""))
	return String(c.get("text"))


## Rich text survives the merge of bindings and part trees: a bound Label
## with Unity tags is a RichTextLabel, and a text binding re-parses it.
func test_rich_text_binding() -> void:
	var data := {"t": "<b>bold</b> plain"}
	var doc := _open("rich", '<ui:Label name="l" text="&lt;b&gt;x&lt;/b&gt;"><Bindings><ui:DataBinding property="text" data-source-path="t"/></Bindings></ui:Label>', {}, data)
	await h.process_frame
	var c := doc.get_native("l")
	h.check(c is RichTextLabel, "a Label with rich text tags is a RichTextLabel")
	h.eq(String(c.get_meta("uxml_rich_src")), "<b>bold</b> plain", "the binding writes the rich source")
	h.eq((c.get_meta("uxml_rich") as Dictionary)["plain"], "bold plain", "and re-parses the tags")
	h.eq((c as RichTextLabel).get_parsed_text(), "bold plain", "the styled runs render")
	data["t"] = "no tags"
	doc.notify_changed(data)
	await h.process_frame
	await h.process_frame
	h.eq((c as RichTextLabel).get_parsed_text(), "no tags", "text without tags still renders in a RichTextLabel")
	h.eq(_kinds(doc.diagnostics).count("binding-failed"), 0, "no failures: %s" % [doc.diagnostics])
	_close(doc)


# ---------------------------------------------------------------------------
# Common attributes
# ---------------------------------------------------------------------------

func test_tabindex_focus_ring() -> void:
	var doc := _open("tab", '<ui:Button name="a" text="a"/>' \
		+ '<ui:Button name="b" text="b" tabindex="2"/>' \
		+ '<ui:Button name="c" text="c" tabindex="-1"/>' \
		+ '<ui:Button name="d" text="d" tabindex="1"/>' \
		+ '<ui:Button name="e" text="e"/>' \
		+ '<ui:VisualElement name="f" tabindex="3"/>' \
		+ '<ui:Button name="g" text="g" tabindex="x"/>')
	var names: Array = []
	for t in doc.get_focus_ring():
		names.append(doc._el_names.get(doc._el_of.get(t)))
	h.eq(names, ["d", "b", "a", "e", "g"], "positive tabindex first, then 0 in tree order; negative and unfocusable left out")
	h.eq((doc.get_native("c") as Control).focus_mode, Control.FOCUS_CLICK, "negative tabindex: focusable by pointer only")
	h.eq(doc.get_native("d").get_node(doc.get_native("d").focus_next), doc.get_native("b"), "focus_next chain")
	h.eq(doc.get_native("d").get_node(doc.get_native("d").focus_previous), doc.get_native("g"), "focus_previous wraps")
	h.check(_kinds(doc.diagnostics).has("unsupported-value"), "invalid tabindex diagnosed")
	await h.process_frame
	doc.get_native("d").grab_focus()
	for key in [KEY_TAB]:
		var ev := InputEventKey.new()
		ev.keycode = key
		ev.pressed = true
		Input.parse_input_event(ev)
		ev = ev.duplicate()
		ev.pressed = false
		Input.parse_input_event(ev)
	await h.process_frame
	h.check(doc.get_native("b").has_focus(), "Tab follows the ring")
	doc.set_enabled("a", false)
	await h.process_frame
	await h.process_frame
	var ev2 := InputEventKey.new()
	ev2.keycode = KEY_TAB
	ev2.pressed = true
	Input.parse_input_event(ev2)
	var ev3 := ev2.duplicate()
	ev3.pressed = false
	Input.parse_input_event(ev3)
	await h.process_frame
	h.check(doc.get_native("e").has_focus(), "Tab skips a disabled ring member")
	_close(doc)


func test_no_tabindex_keeps_godot_order() -> void:
	var doc := _open("notab", '<ui:Button name="a" text="a"/><ui:Button name="b" text="b"/>')
	h.eq(doc.get_focus_ring().size(), 0, "no ring without tabindex")
	h.eq(doc.get_native("a").focus_next, NodePath(), "no chain written")
	_close(doc)


func test_picking_mode() -> void:
	var doc := _open("pick", '<ui:Button name="b" text="b" picking-mode="Ignore"/>' \
		+ '<ui:VisualElement name="v" picking-mode="Position"/><ui:Slider name="s" picking-mode="Ignore"/>' \
		+ '<ui:VisualElement name="bad" picking-mode="Sometimes"/>')
	await h.process_frame
	h.eq(doc.get_native("b").mouse_filter, Control.MOUSE_FILTER_IGNORE, "Ignore lets pointer events through")
	h.eq(doc.get_native("s").mouse_filter, Control.MOUSE_FILTER_IGNORE, "Ignore reaches the inner native")
	h.eq(doc.get_element("s").mouse_filter, Control.MOUSE_FILTER_IGNORE, "and the wrapper")
	h.check(doc.get_element("v").mouse_filter != Control.MOUSE_FILTER_IGNORE, "Position keeps picking")
	doc.set_element_state("b", "hover", true)
	await h.process_frame
	h.eq(doc.get_native("b").mouse_filter, Control.MOUSE_FILTER_IGNORE, "a restyle keeps Ignore")
	h.check(_kinds(doc.diagnostics).has("unsupported-value"), "invalid picking-mode diagnosed")
	_close(doc)


func test_language_direction() -> void:
	var doc := _open("dir", '<ui:VisualElement language-direction="RTL"><ui:Label name="l" text="abc"/>' \
		+ '<ui:TextField name="t" label="cap"/><ui:Label name="ltr" text="x" language-direction="LTR"/></ui:VisualElement>' \
		+ '<ui:Label name="plain" text="p"/>')
	h.eq((doc.get_native("l") as Label).text_direction, Control.TEXT_DIRECTION_RTL, "inherited RTL")
	h.eq((doc.get_native("t") as LineEdit).text_direction, Control.TEXT_DIRECTION_RTL, "RTL on a text field")
	h.eq((doc.get_element("t") as UxmlField).caption.text_direction, Control.TEXT_DIRECTION_RTL, "and its caption")
	h.eq((doc.get_native("ltr") as Label).text_direction, Control.TEXT_DIRECTION_LTR, "nearest value wins")
	var probe := Label.new()
	h.eq((doc.get_native("plain") as Label).text_direction, probe.text_direction, "outside: Godot default")
	probe.free()
	_close(doc)


func test_usage_hints_are_accepted() -> void:
	var doc := _open("hints", '<ui:VisualElement usage-hints="DynamicTransform, GroupTransform"/>' \
		+ '<ui:VisualElement usage-hints="MaskContainer|DynamicColor"/>')
	h.eq(_kinds(doc.diagnostics).count("unsupported-value") + _kinds(doc.diagnostics).count("unsupported-attribute"), 0, "valid hints: no diagnostics")
	_close(doc)
	doc = _open("hints2", '<ui:VisualElement usage-hints="Turbo"/>')
	h.check(_kinds(doc.diagnostics).has("unsupported-value"), "an unknown hint is diagnosed")
	_close(doc)


func test_view_data_round_trip() -> void:
	var rows := ""
	for i in 40:
		rows += '<ui:Label text="row %d" style="height: 30px; flex-shrink: 0;"/>' % i
	var body := '<ui:VisualElement view-data-key="page"><ui:ScrollView name="sv" view-data-key="list" style="height: 200px;">%s</ui:ScrollView></ui:VisualElement>' % rows
	var doc := _open("view", body)
	await h.process_frame
	await h.process_frame
	# Updated with unity/controls-containers: the ScrollView is a part tree;
	# its offset is set and read through the document.
	doc.set_scroll_offset("sv", Vector2(0, 300))
	var vd := doc.get_view_data()
	h.eq(vd.keys(), ["page__list"], "full hierarchical key")
	h.eq(vd["page__list"]["scroll_offset"], Vector2(0, 300), "scroll offset captured")
	doc.reload()
	await h.process_frame
	await h.process_frame
	h.eq(doc.get_scroll_offset("sv"), Vector2(0, 300), "restored after reload")
	doc.set_view_data({"page__list": {"scroll_offset": Vector2(0, 120)}})
	await h.process_frame
	h.eq(doc.get_scroll_offset("sv"), Vector2(0, 120), "set_view_data applies")
	_close(doc)
	var fresh := UxmlDocument.new()
	h.root.add_child(fresh)
	fresh.size = Vector2(400, 600)
	fresh.set_view_data({"page__list": {"scroll_offset": Vector2(0, 90)}})
	fresh.load_document("Assets/UI/main.uxml", "%s/view" % ROOT)
	await h.process_frame
	await h.process_frame
	h.eq(fresh.get_scroll_offset("sv"), Vector2(0, 90), "view data given before the load is restored")
	_close(fresh)
