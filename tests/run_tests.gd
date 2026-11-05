extends SceneTree
## godot-uxml milestone 1 test suite: UXML parser, USS parser, resource
## resolution, and the cascade.
##
## Run headless:
##   godot --headless --path <project> --script res://tests/run_tests.gd
##
## Every test_* method runs; a nonzero exit code means a failure.

const FIXTURES := "res://tests/fixtures"

var _checks := 0
var _failures := 0
var _current := ""


func _initialize() -> void:
	# Suites: this script's own test_* methods (milestone 1) plus RefCounted
	# suite objects that receive this harness in _init. Suite methods may be
	# coroutines (await process_frame for real input delivery).
	var suites: Array = [[self, "core"]]
	for entry in [
		["res://tests/test_layout.gd", "layout"],
		["res://tests/test_runtime.gd", "runtime"],
		["res://tests/test_templates.gd", "templates"],
		["res://tests/test_transitions.gd", "transitions"],
		["res://tests/test_binding.gd", "binding"],
		["res://tests/test_visual.gd", "visual"],
		["res://tests/test_controls.gd", "controls"],
	]:
		var cls = load(entry[0])
		if cls == null:
			_failures += 1
			print("FAIL: could not load suite %s" % entry[0])
			continue
		suites.append([cls.new(self), entry[1]])

	var test_count := 0
	for pair in suites:
		var suite = pair[0]
		var tag: String = pair[1]
		var names: Array = []
		for m in suite.get_method_list():
			var n: String = m["name"]
			if n.begins_with("test_"):
				names.append(n)
		names.sort()
		for n in names:
			_current = "%s.%s" % [tag, n]
			var checks_before := _checks
			print("RUN %s" % _current)
			# Object.call() on a coroutine errors ("async without await");
			# Callable.call() under await dispatches cleanly either way.
			await Callable(suite, n).call()
			test_count += 1
			if _checks == checks_before:
				_failures += 1
				print("FAIL %s: test produced no checks (aborted or empty)" % _current)
	print("")
	# SUITE_COMPLETE is the harness completion marker: external wrappers must
	# require it, because a script error can silently truncate a test.
	print("SUITE_COMPLETE %d tests" % test_count)
	if _failures == 0:
		print("PASS: %d checks across %d tests" % [_checks, test_count])
	else:
		print("FAIL: %d of %d checks failed" % [_failures, _checks])
	quit(0 if _failures == 0 else 1)


## True when the run has a real display: synthetic mouse motion/click
## delivery only works with a windowing DisplayServer. Mouse-dependent tests
## skip headless runs; keyboard/joypad delivery works everywhere.
func has_display() -> bool:
	return DisplayServer.get_name() != "headless"


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

func check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL %s: %s" % [_current, msg])


func eq(actual: Variant, expected: Variant, msg: String) -> void:
	_checks += 1
	if actual != expected:
		_failures += 1
		print("FAIL %s: %s -- expected <%s>, got <%s>" % [_current, msg, expected, actual])


func _resolver(root: String = "") -> UxmlResourceResolver:
	return UxmlResourceResolver.new(FIXTURES + "/options" if root.is_empty() else root)


## Parse a small inline document: UXML body inside a ui:UXML root, `uss` as a
## top-level sheet scoped to the root (like the reference parse(uxml, uss)).
func _doc(body: String, uss: String = "") -> UxmlDocumentModel:
	var src := '<ui:UXML xmlns:ui="UnityEngine.UIElements">%s</ui:UXML>' % body
	return UxmlLoader.load_source(src, "inline/test.uxml", _resolver(FIXTURES + "/options"), uss)


func _resolved(doc: UxmlDocumentModel, options: Dictionary = {}) -> Dictionary:
	return UssStyleResolver.resolve(doc, options)


## Winning value of one property on the named element.
func _val(doc: UxmlDocumentModel, element_name: String, property: String, options: Dictionary = {}) -> Variant:
	var el := doc.find_by_name(element_name)
	if el == null:
		return "<no element %s>" % element_name
	var res := _resolved(doc, options)
	var style: Dictionary = res["styles"].get(el, {})
	var entry = style.get(property)
	return null if entry == null else entry["value"]


func _kinds(list: Array) -> Array:
	var out: Array = []
	for d in list:
		out.append(d["kind"])
	return out


func _count_kind(list: Array, kind: String) -> int:
	var n := 0
	for d in list:
		if d["kind"] == kind:
			n += 1
	return n


func _has_kind(list: Array, kind: String) -> bool:
	return _count_kind(list, kind) > 0


# ---------------------------------------------------------------------------
# UXML parser
# ---------------------------------------------------------------------------

func test_uxml_namespaces_and_tags() -> void:
	var r := UxmlParser.new().parse(
		'<ui:UXML xmlns:ui="UnityEngine.UIElements"><acme:Panel name="p"><ui:Label text="x" /></acme:Panel></ui:UXML>'
	)
	var root: UxmlElement = r["root"]
	eq(root.prefix, "ui", "root prefix")
	eq(root.local, "UXML", "root local name")
	var panel: UxmlElement = root.children[0]
	eq(panel.prefix, "acme", "foreign prefix kept")
	eq(panel.local, "Panel", "foreign local name")
	eq(panel.children.size(), 1, "child inside foreign element")
	eq(panel.children[0].local, "Label", "child tag")
	eq(r["warnings"].size(), 0, "clean parse has no warnings")


func test_uxml_entities_decoded() -> void:
	var r := UxmlParser.new().parse(
		'<ui:UXML><ui:Button text="Play &amp; Go" tooltip="Press &quot;Enter&quot;" other="Quit &#x26; Save &#38; then" /></ui:UXML>'
	)
	var b: UxmlElement = r["root"].children[0]
	eq(b.get_attribute("text"), "Play & Go", "&amp; decodes")
	eq(b.get_attribute("tooltip"), 'Press "Enter"', "&quot; decodes")
	eq(b.get_attribute("other"), "Quit & Save & then", "numeric refs decode")


func test_uxml_comments_and_prologue_skipped() -> void:
	var r := UxmlParser.new().parse(
		'<?xml version="1.0"?>\n<!-- before -->\n<ui:UXML><!-- inside --><ui:Label /><!-- between --><ui:Button /></ui:UXML>\n<!-- after -->'
	)
	var root: UxmlElement = r["root"]
	eq(root.local, "UXML", "root after prologue/comment")
	eq(root.children.size(), 2, "comments do not create elements")


func test_uxml_nesting_and_self_closing() -> void:
	var r := UxmlParser.new().parse(
		'<ui:UXML><ui:A><ui:B><ui:C /></ui:B><ui:D /></ui:A></ui:UXML>'
	)
	var a: UxmlElement = r["root"].children[0]
	eq(a.children.size(), 2, "two children")
	eq(a.children[0].children[0].local, "C", "deep child")
	eq(a.children[1].children.size(), 0, "self-closing has no children")


func test_uxml_mismatched_close_tag() -> void:
	var r := UxmlParser.new().parse(
		'<ui:UXML><ui:VisualElement><ui:Button /></ui:Other></ui:UXML>'
	)
	var ve: UxmlElement = r["root"].children[0]
	eq(ve.local, "VisualElement", "element recovered")
	eq(ve.children.size(), 1, "children kept under mismatched close")
	eq(_count_kind(r["warnings"], "malformed"), 1, "mismatch warns once")
	check(r["warnings"][0]["message"].find("does not match") >= 0, "message names the mismatch")


func test_uxml_empty_document() -> void:
	for src in ["", "   \n\t ", "<!-- only a comment -->"]:
		var r := UxmlParser.new().parse(src)
		eq(_count_kind(r["warnings"], "malformed"), 1, "no root warns for <%s>" % src.substr(0, 12))
		eq(r["root"].children.size(), 0, "empty root")


func test_uxml_bad_attributes() -> void:
	var r := UxmlParser.new().parse(
		'<ui:UXML><ui:Label valueless unquoted=abc ok="1" /></ui:UXML>'
	)
	var el: UxmlElement = r["root"].children[0]
	eq(el.get_attribute("valueless"), "", "valueless attribute kept")
	eq(el.get_attribute("unquoted"), "", "unquoted value kept empty")
	eq(el.get_attribute("ok"), "1", "normal attribute fine")
	check(_count_kind(r["warnings"], "malformed") >= 2, "bad attributes warn")


func test_uxml_duplicate_attribute() -> void:
	var r := UxmlParser.new().parse('<ui:UXML><ui:Label name="a" name="b" /></ui:UXML>')
	var el: UxmlElement = r["root"].children[0]
	eq(el.get_attribute("name"), "a", "first duplicate wins")
	eq(_count_kind(r["warnings"], "malformed"), 1, "duplicate warns")


func test_uxml_unterminated_element() -> void:
	var r := UxmlParser.new().parse('<ui:UXML><ui:VisualElement><ui:Button /></ui:UXML>')
	check(_has_kind(r["warnings"], "malformed"), "unterminated element warns")


# ---------------------------------------------------------------------------
# USS parser
# ---------------------------------------------------------------------------

func test_uss_comments_ignored() -> void:
	var r := UssParser.new().parse('/* header */ .a { color: red; /* inner */ } /* tail */')
	eq(r["items"].size(), 1, "one rule")
	eq(r["items"][0]["rule"]["declarations"].size(), 1, "one declaration")


func test_uss_quoted_values() -> void:
	var r := UssParser.new().parse('.a { background-image: url("dir/with;semi.png"); }')
	var decl: Dictionary = r["items"][0]["rule"]["declarations"][0]
	eq(decl["value"], 'url("dir/with;semi.png")', "semicolon inside quotes kept")


func test_uss_declaration_without_value() -> void:
	var r := UssParser.new().parse('.a { color; width: 1px; }')
	var rule: Dictionary = r["items"][0]["rule"]
	eq(rule["declarations"].size(), 1, "valid declaration survives")
	eq(_count_kind(r["warnings"], "malformed"), 1, "declaration without value warns")


func test_uss_selector_group() -> void:
	var r := UssParser.new().parse('.a, #b > Label.c { color: red; }')
	var sels: Array = r["items"][0]["rule"]["selectors"]
	eq(sels.size(), 2, "comma group splits")
	var parts: Array = sels[1]["parts"]
	eq(parts.size(), 2, "two compounds")
	eq(parts[1]["combinator"], "child", "child combinator")


func test_uss_import_items() -> void:
	var r := UssParser.new().parse('@import url("a.uss");\n@import \'b.uss\';\n.x { color: red; }')
	eq(r["items"][0]["kind"], "import", "url() import")
	eq(r["items"][0]["url"], "a.uss", "url path")
	eq(r["items"][1]["kind"], "import", "bare-string import")
	eq(r["items"][1]["url"], "b.uss", "bare path")
	eq(r["items"][2]["kind"], "rule", "rule after imports")


func test_uss_import_unquoted_warns() -> void:
	var r := UssParser.new().parse('@import url(a.uss);')
	eq(_count_kind(r["warnings"], "malformed"), 1, "unquoted import warns")
	eq(r["items"][0]["kind"], "unknown", "not an import item")


func test_uss_block_at_rule_unknown() -> void:
	var r := UssParser.new().parse('@media screen { .a { color: red; } } .b { color: blue; }')
	eq(r["items"][0]["kind"], "unknown", "media block is unknown")
	eq(r["items"][1]["kind"], "rule", "next rule still parses")


func test_uss_unterminated_rule() -> void:
	var r := UssParser.new().parse('.a { color: red;')
	eq(_count_kind(r["warnings"], "malformed"), 1, "unterminated block warns")


# ---------------------------------------------------------------------------
# Cascade: matching & specificity
# ---------------------------------------------------------------------------

const ONE := '<ui:Label name="a" class="x y" text="t" />'


func test_name_beats_class_regardless_of_order() -> void:
	eq(_val(_doc(ONE, '.x { color: red; } #a { color: blue; }'), 'a', 'color'), 'blue', "id first")
	eq(_val(_doc(ONE, '#a { color: blue; } .x { color: red; }'), 'a', 'color'), 'blue', "id still wins when class is later")


func test_class_beats_type_regardless_of_order() -> void:
	eq(_val(_doc(ONE, 'Label { color: red; } .x { color: blue; }'), 'a', 'color'), 'blue', "class first")
	eq(_val(_doc(ONE, '.x { color: blue; } Label { color: red; }'), 'a', 'color'), 'blue', "class still wins when type is later")


func test_type_beats_universal() -> void:
	eq(_val(_doc(ONE, 'Label { color: blue; } * { color: red; }'), 'a', 'color'), 'blue', "type beats *")
	eq(_val(_doc(ONE, '* { color: red; } Label { color: blue; }'), 'a', 'color'), 'blue', "type still beats *")


func test_equal_specificity_later_wins() -> void:
	eq(_val(_doc(ONE, '.x { color: red; } .y { color: blue; }'), 'a', 'color'), 'blue', "later rule wins tie")


func test_compound_two_classes_beat_one() -> void:
	eq(_val(_doc(ONE, '.x.y { color: blue; } .x { color: red; }'), 'a', 'color'), 'blue', ".x.y beats .x")


func test_group_scored_by_best_match() -> void:
	# `.x, #a` matches via #a -> specificity (1,0,0) -> beats a later .y rule.
	eq(_val(_doc(ONE, '.x, #a { color: blue; } .y { color: red; }'), 'a', 'color'), 'blue', "group takes best matching selector")


func test_inline_beats_id() -> void:
	var doc := _doc('<ui:Label name="a" style="color: green;" />', '#a { color: blue; }')
	eq(_val(doc, 'a', 'color'), 'green', "inline beats #id")


func test_descendant_vs_child() -> void:
	var doc := _doc(
		'<ui:VisualElement name="p" class="p"><ui:VisualElement><ui:Label name="deep" class="c" /></ui:VisualElement><ui:Label name="direct" class="c" /></ui:VisualElement>',
		'.p .c { color: red; } .p > .c { color: blue; }'
	)
	eq(_val(doc, 'deep', 'color'), 'red', "grandchild: only descendant matches")
	eq(_val(doc, 'direct', 'color'), 'blue', "direct child: child combinator wins later")


func test_pseudo_states() -> void:
	var doc := _doc(ONE, 'Label { color: red; } Label:hover { color: blue; }')
	eq(_val(doc, 'a', 'color'), 'red', "hover inactive: base wins")
	eq(_val(doc, 'a', 'color', {"active_states": ["hover"]}), 'blue', "hover active globally")
	eq(_val(doc, 'a', 'color', {"states": {"#a": ["hover"]}}), 'blue', "hover via per-element key")
	eq(_val(doc, 'a', 'color', {"states": {"#other": ["hover"]}}), 'red', "key targeting another element does nothing")


func test_disabled_state_from_enabled_attr() -> void:
	var doc := _doc(
		'<ui:VisualElement name="p" enabled="false"><ui:Label name="kid" /></ui:VisualElement><ui:Label name="normal" />',
		'VisualElement:disabled { color: blue; } Label:disabled { color: green; } Label:enabled { color: red; }'
	)
	eq(_val(doc, 'p', 'color'), 'blue', "enabled=false matches :disabled")
	eq(_val(doc, 'kid', 'color'), 'green', "disabled descends to children")
	eq(_val(doc, 'normal', 'color'), 'red', "normal element is :enabled")


func test_implicit_unity_classes_match() -> void:
	var doc := _doc('<ui:Button name="b" text="x" />', '.unity-button { color: teal; }')
	eq(_val(doc, 'b', 'color'), 'teal', ".unity-button matches a plain Button")


func test_unsupported_selector_drops_rule() -> void:
	# Every one of these must be ignored AND warned about; none may apply as
	# if it were a universal match.
	for sel in ['.x + .y', '.x ~ .y', '.x[disabled]', '.x::before', '.x:nth-child(2)']:
		var doc := _doc(ONE, '%s { color: red; } .x { color: blue; }' % sel)
		var res := _resolved(doc)
		eq(_val(doc, 'a', 'color'), 'blue', "%s does not leak" % sel)
		eq(_count_kind(res["warnings"], "unsupported-selector"), 1, "%s warns" % sel)


func test_unsupported_pseudo_drops_rule() -> void:
	for sel in ['.x:visited', '.x:focus-visible']:
		var doc := _doc(ONE, '%s { color: red; } .x { color: blue; }' % sel)
		var res := _resolved(doc)
		eq(_val(doc, 'a', 'color'), 'blue', "%s does not leak" % sel)
		eq(_count_kind(res["warnings"], "unsupported-selector"), 1, "%s warns" % sel)


func test_root_pseudo() -> void:
	var doc := _doc('<ui:VisualElement name="kid" />', ':root { color: purple; } Label { color: orange; }')
	var res := _resolved(doc)
	var root_style: Dictionary = res["styles"][doc.root]
	eq(root_style["color"]["value"], 'purple', ":root matches the scope element")
	var kid := doc.find_by_name('kid')
	# The child still shows purple, but only through inheritance — :root did
	# not match it directly.
	eq(res["styles"][kid]["color"]["origin"]["kind"], 'inherited', "child color comes via inheritance, not :root")
	eq(_count_kind(res["warnings"], "version-dependent"), 1, ":root use warns once")


func test_bad_states_key_warns() -> void:
	var doc := _doc(ONE, '.x { color: red; }')
	var res := _resolved(doc, {"states": {"[bogus]": ["hover"]}})
	eq(_count_kind(res["warnings"], "unsupported-selector"), 1, "unusable states key warns")
	eq(_val(doc, 'a', 'color'), 'red', "base style unaffected")


# ---------------------------------------------------------------------------
# Cascade: inheritance, variables, shorthands
# ---------------------------------------------------------------------------

func test_inherited_properties() -> void:
	var doc := _doc(
		'<ui:VisualElement name="p" class="p"><ui:Label name="kid" /></ui:VisualElement>',
		'.p { color: red; font-size: 20px; width: 100px; }'
	)
	eq(_val(doc, 'kid', 'color'), 'red', "color inherits")
	eq(_val(doc, 'kid', 'font-size'), '20px', "font-size inherits")
	eq(_val(doc, 'kid', 'width'), null, "width does not inherit")


func test_custom_property_flows_down() -> void:
	var doc := _doc(
		'<ui:VisualElement name="p" class="p"><ui:Label name="kid" /></ui:VisualElement>',
		'.p { --accent: #123456; } .p Label { color: var(--accent); }'
	)
	eq(_val(doc, 'kid', 'color'), '#123456', "var() reads inherited custom property")


func test_var_fallback() -> void:
	var doc := _doc(ONE, '.x { color: var(--missing, #abcdef); }')
	eq(_val(doc, 'a', 'color'), '#abcdef', "var() fallback used when property missing")


func test_var_referencing_var() -> void:
	var doc := _doc(
		'<ui:VisualElement name="p" class="p"><ui:Label name="kid" /></ui:VisualElement>',
		'.p { --a: var(--b); --b: green; } .p Label { color: var(--a); }'
	)
	eq(_val(doc, 'kid', 'color'), 'green', "chained var() resolves")


func test_var_missing_drops_with_warning() -> void:
	var doc := _doc(ONE, '.x { color: var(--nope); }')
	var res := _resolved(doc)
	eq(_val(doc, 'a', 'color'), null, "unresolvable var() drops declaration")
	eq(_count_kind(res["warnings"], "unresolved-var"), 1, "unresolvable var() warns")


func test_var_cycle_drops_with_warning() -> void:
	var doc := _doc(ONE, '.x { --a: var(--b); --b: var(--a); color: var(--a); }')
	var res := _resolved(doc)
	eq(_val(doc, 'a', 'color'), null, "cyclic var() drops")
	eq(_val(doc, 'a', '--a'), null, "cyclic custom property dropped too")
	# Each declaration caught in the cycle is dropped and warned about.
	eq(_count_kind(res["warnings"], "unresolved-var"), 3, "every cyclic declaration warns")


func test_box_shorthands() -> void:
	var doc := _doc(ONE, '.x { padding: 1px 2px; margin: 1px 2px 3px; border-width: 1px 2px 3px 4px; border-radius: 5px; }')
	eq(_val(doc, 'a', 'padding-top'), '1px', "padding 2-value top")
	eq(_val(doc, 'a', 'padding-left'), '2px', "padding 2-value left")
	eq(_val(doc, 'a', 'margin-bottom'), '3px', "margin 3-value bottom")
	eq(_val(doc, 'a', 'margin-left'), '2px', "margin 3-value left")
	eq(_val(doc, 'a', 'border-left-width'), '4px', "border-width 4-value left")
	eq(_val(doc, 'a', 'border-bottom-right-radius'), '5px', "radius order bottom-right")


func test_flex_shorthand() -> void:
	var doc := _doc('<ui:Label name="a" class="x" />', '.x { flex: 2; }')
	var d2 := _doc('<ui:Label name="b" class="z" />', '.z { flex: none; }')
	eq(_val(doc, 'a', 'flex-grow'), '2', "flex: 2 grow")
	eq(_val(doc, 'a', 'flex-basis'), '0', "flex: 2 basis zero")
	eq(_val(_doc('<ui:Label name="b" class="y" />', '.y { flex: 1 30px; }'), 'b', 'flex-basis'), '30px', "flex: 1 30px basis")
	eq(_val(d2, 'b', 'flex-shrink'), '0', "flex: none shrink")


func test_shorthand_loses_to_later_longhand() -> void:
	var doc := _doc(ONE, '.x { padding: 10px; } .x { padding-left: 2px; }')
	eq(_val(doc, 'a', 'padding-left'), '2px', "longhand after shorthand wins its side")
	eq(_val(doc, 'a', 'padding-top'), '10px', "other sides keep shorthand")


func test_unsupported_property_warns_but_keeps() -> void:
	var doc := _doc(ONE, '.x { -unity-material: url("m.mat"); color: red; }')
	var res := _resolved(doc)
	eq(_count_kind(res["warnings"], "unsupported-property"), 1, "-unity-material warns")
	eq(_val(doc, 'a', '-unity-material'), 'url("m.mat")', "value still computed")
	eq(_val(doc, 'a', 'color'), 'red', "supported property unaffected")


# ---------------------------------------------------------------------------
# Document assembly: <Style src>, @import, scoping, cycles, traversal
# ---------------------------------------------------------------------------

func test_fixture_menu_parses_and_cascades() -> void:
	var doc := UxmlLoader.load_file(FIXTURES + "/menu/Assets/UI/Menu.uxml", FIXTURES + "/menu")
	eq(doc.warnings.size(), 0, "menu fixture parses cleanly")
	var play := doc.find_by_name("play-button")
	var quit := doc.find_by_name("quit-button")
	check(play != null and quit != null, "menu buttons found")
	eq(play.get_attribute("text"), "Play & Go", "entity decoded text")
	eq(quit.get_attribute("text"), "Quit & Save", "entity decoded single-quoted text")
	eq(doc.sheets.size(), 1, "linked stylesheet loaded")
	eq(_val(doc, 'play-button', 'background-color'), '#18794e', "compound .menu-button.primary wins over later .menu-button")
	eq(_val(doc, 'quit-button', 'background-color'), null, "plain .menu-button has no background")
	eq(_val(doc, 'quit-button', 'min-width'), '180px', "later .menu-button rule applies")


func test_fixture_options_controls() -> void:
	var doc := UxmlLoader.load_file(FIXTURES + "/options/Assets/UI/Options.uxml", FIXTURES + "/options")
	var names := ["profile-name", "volume", "ui-scale", "quality", "fullscreen", "accent", "icon-asset"]
	for n in names:
		check(doc.find_by_name(n) != null, "options element %s exists" % n)
	var slider := doc.find_by_name("ui-scale")
	eq(slider.get_attribute("low-value"), "0.75", "slider low-value")
	eq(slider.get_attribute("value"), "1.25", "slider value")
	eq(_val(doc, 'volume', 'min-width'), '180px', ".option-control rule applies")


func test_fixture_resolution_paths() -> void:
	var doc := UxmlLoader.load_file(
		FIXTURES + "/resolution/Assets/UI/screen.uxml", FIXTURES + "/resolution"
	)
	eq(doc.sheets.size(), 2, "base.uss + imported theme.uss")
	eq(_val(doc, 'screen', 'background-image'), 'url("../Resources/UI/icon.png")', "screen background")
	eq(_val(doc, 'screen', 'color'), 'rgb(32, 48, 64)', "color from nested import")


func test_fixture_unsupported_control_and_selectors() -> void:
	var doc := UxmlLoader.load_file(
		FIXTURES + "/unsupported/Assets/UI/Unsupported.uxml", FIXTURES + "/unsupported"
	)
	eq(_count_kind(doc.warnings, "unsupported-control"), 1, "acme control warns")
	var panel := doc.find_by_name("unknown-panel")
	check(panel != null, "unknown element kept in tree")
	eq(panel.children.size(), 2, "children preserved under unknown control")
	var res := _resolved(doc)
	# Both USS rules carry unsupported selector fragments; neither may apply.
	eq(_count_kind(res["warnings"], "unsupported-selector"), 2, "both bad selectors warn")
	eq(_val(doc, 'preserved-label', 'color'), null, "no style leaks through :focus-visible rule")


func test_fixture_malformed_recovers() -> void:
	var doc := UxmlLoader.load_file(FIXTURES + "/malformed/Assets/UI/Malformed.uxml", FIXTURES + "/malformed")
	check(doc.root != null, "malformed doc still yields a tree")
	check(doc.warnings.size() > 0, "malformed doc reports warnings")


func test_nested_styles_import_order() -> void:
	var doc := UxmlLoader.load_file(
		FIXTURES + "/nested-styles/Assets/UI/Nested.uxml", FIXTURES + "/nested-styles"
	)
	eq(doc.sheets.size(), 2, "base + imported buttons sheet")
	# Imported sheet lands at the @import position, so base.uss's own later
	# .nested-action rule wins the color tie while width survives from import.
	eq(_val(doc, 'nested-action', 'color'), '#16324f', "importing sheet wins later tie")
	eq(_val(doc, 'nested-action', 'width'), '160px', "imported rule still applies")
	eq(_val(doc, 'nested-action', 'background-color'), '#245f9e', "imported background")


func test_missing_stylesheet_diagnostic() -> void:
	var doc := UxmlLoader.load_source(
		'<ui:UXML xmlns:ui="UnityEngine.UIElements"><Style src="nope.uss" /><ui:Label name="a" /></ui:UXML>',
		FIXTURES + "/options/Assets/UI/Missing.uxml",
		_resolver(FIXTURES + "/options")
	)
	eq(_count_kind(doc.warnings, "missing-file"), 1, "missing <Style src> warns")
	check(doc.warnings[0]["file"].find("Missing.uxml") >= 0 or doc.warnings[0]["message"].find("nope.uss") >= 0,
		"warning names the missing reference")


func test_import_cycle_diagnostic() -> void:
	var doc := UxmlLoader.load_file(FIXTURES + "/cycle/Assets/UI/cycle.uxml", FIXTURES + "/cycle")
	eq(doc.sheets.size(), 2, "both sheets load once")
	eq(_count_kind(doc.warnings, "import-cycle"), 1, "cycle diagnosed")
	eq(_val(doc, 'v', 'color'), '#111111', "importing sheet's own rule wins")
	var res := _resolved(doc)
	var v := doc.find_by_name('v')
	eq(res["styles"][v]["color"]["value"], '#111111', "cycle does not break cascade")
	eq(res["styles"][v]["color"]["origin"]["file"], doc.sheets[0]["origin"], "winner provenance is a.uss")


func test_path_traversal_blocked() -> void:
	var doc := UxmlLoader.load_file(FIXTURES + "/traversal/Assets/UI/main.uxml", FIXTURES + "/traversal")
	eq(_count_kind(doc.warnings, "path-outside-root"), 1, "escape outside root blocked")
	eq(_count_kind(doc.warnings, "missing-file"), 1, "in-root missing file diagnosed")
	eq(_val(doc, 'v', 'color'), 'red', "own rules still apply")


func test_stylesheet_scope() -> void:
	var doc := UxmlLoader.load_file(FIXTURES + "/scope/Assets/UI/scoped.uxml", FIXTURES + "/scope")
	eq(_val(doc, 'inside', 'color'), 'rgb(1, 2, 3)', "sheet applies inside its subtree")
	eq(_val(doc, 'outside', 'color'), null, "sheet does not apply outside its subtree")


func test_project_url_forms() -> void:
	var r := _resolver(FIXTURES + "/resolution")
	eq(r.resolve("project://database/Assets/UI/base.uss")["path"],
		FIXTURES + "/resolution/Assets/UI/base.uss", "project://database")
	eq(r.resolve("/Assets/UI/base.uss")["path"],
		FIXTURES + "/resolution/Assets/UI/base.uss", "rooted /Assets")
	eq(r.resolve("Packages/com.example.ui/theme.uss")["path"],
		FIXTURES + "/resolution/Packages/com.example.ui/theme.uss", "Packages root")
	eq(r.resolve("nested/theme.uss", FIXTURES + "/resolution/Assets/UI/base.uss")["path"],
		FIXTURES + "/resolution/Assets/UI/nested/theme.uss", "relative to containing sheet")
	eq(r.resolve("../Resources/UI/icon.png", FIXTURES + "/resolution/Assets/UI/base.uss")["path"],
		FIXTURES + "/resolution/Assets/Resources/UI/icon.png", "relative .. within root")
	check(not r.resolve("project://database/../../outside.uss")["ok"], "project:// escape rejected")
	check(not r.resolve("res://tests/fixtures/options/Assets/UI/Options.uss")["ok"], "res:// outside root rejected")


# ---------------------------------------------------------------------------
# Review regression: entity decoding is single-pass
# ---------------------------------------------------------------------------

func test_entities_single_pass() -> void:
	var r := UxmlParser.new().parse(
		'<ui:UXML><ui:Label a="&#38;lt;" b="&#x26;#65;" c="&amp;lt;" d="&#65;" e="&lt;&gt;&quot;&apos;&amp;" f="&#x41;&#x20AC;" /></ui:UXML>'
	)
	var el: UxmlElement = r["root"].children[0]
	eq(el.get_attribute("a"), "&lt;", "&#38;lt; decodes once to literal &lt;")
	eq(el.get_attribute("b"), "&#65;", "&#x26;#65; decodes once to literal &#65;")
	eq(el.get_attribute("c"), "&lt;", "&amp;lt; -> literal &lt;")
	eq(el.get_attribute("d"), "A", "&#65; -> A")
	eq(el.get_attribute("e"), "<>\"'&", "named entities decode once")
	eq(el.get_attribute("f"), "A" + char(0x20AC), "hex + astral-range decode")


func test_entities_invalid_numeric_left_alone() -> void:
	var r := UxmlParser.new().parse(
		'<ui:UXML><ui:Label a="&#xD800;" b="&#x110000;" c="&bogus;" /></ui:UXML>'
	)
	var el: UxmlElement = r["root"].children[0]
	eq(el.get_attribute("a"), "&#xD800;", "surrogate half kept literal")
	eq(el.get_attribute("b"), "&#x110000;", "out of range kept literal")
	eq(el.get_attribute("c"), "&bogus;", "unknown entity kept literal")


func test_uxml_content_after_root_warns() -> void:
	var r := UxmlParser.new().parse('<ui:UXML /><ui:Other />')
	eq(_count_kind(r["warnings"], "malformed"), 1, "second root warns")
	var r2 := UxmlParser.new().parse('<ui:UXML></ui:UXML></ui:Stray>')
	eq(_count_kind(r2["warnings"], "malformed"), 1, "trailing close tag warns")
	var r3 := UxmlParser.new().parse('<ui:UXML />')
	eq(r3["warnings"].size(), 0, "clean single root stays quiet")


# ---------------------------------------------------------------------------
# Review regression: path canonicalization
# ---------------------------------------------------------------------------

func test_resolver_default_res_root() -> void:
	# The default root is res:// — it must survive normalization.
	var r := UxmlResourceResolver.new()
	eq(r.project_root, "res://", "default root keeps its scheme")
	var res := r.resolve_text("res://tests/fixtures/options/Assets/UI/Options.uss")
	check(res["ok"], "default resolver resolves a real res:// file")
	check(String(res["text"]).find(".options-shell") >= 0, "resolve_text reads file contents")


# Unity asset references written by UI Builder carry a query and a
# sub-asset fragment; the file is the part before them.
func test_resolver_strips_unity_asset_query() -> void:
	var r := UxmlResourceResolver.new("res://tests/fixtures/options")
	var res := r.resolve_text("project://database/Assets/UI/Options.uss?fileID=7433441132597879392&guid=0123456789abcdef&type=3#Options")
	check(res["ok"], "query and fragment are stripped: %s" % [res.get("diagnostic")])
	check(r.resolve("Assets/UI/Options.uss#Options")["ok"], "a fragment alone is stripped")


func test_resolver_user_scheme() -> void:
	var dir := "user://uxml_test_tmp"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var f := FileAccess.open(dir + "/probe.uss", FileAccess.WRITE)
	f.store_string(".p { color: red; }")
	f.close()
	var r := UxmlResourceResolver.new(dir)
	var res := r.resolve_text("probe.uss")
	check(res["ok"], "user:// project root resolves")
	eq(res["text"], ".p { color: red; }", "user:// file contents read")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir + "/probe.uss"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))


func test_resolver_nested_dotdot_within_root() -> void:
	var r := _resolver(FIXTURES + "/options")
	var res := r.resolve("Assets/UI/../UI/Options.uss")
	check(res["ok"], "nested .. staying inside root is fine")
	eq(res["path"], FIXTURES + "/options/Assets/UI/Options.uss", ".. collapsed correctly")


func test_resolver_dotdot_escape_rejected() -> void:
	var r := _resolver(FIXTURES + "/options")
	check(not r.resolve("Assets/../../escape.uss")["ok"], ".. escaping root rejected")
	check(not r.resolve("res://tests/fixtures/options/../escape.uss")["ok"], "res:// .. escape rejected")
	check(not r.resolve("res://../outside.uss")["ok"], "res:// .. above scheme root rejected")


func test_resolver_prefix_sibling_rejected() -> void:
	# res://tests/fixtures/optionsx shares a string prefix with the root but
	# is not inside it.
	var r := _resolver(FIXTURES + "/options")
	check(not r.resolve("res://tests/fixtures/optionsx/evil.uss")["ok"], "prefix sibling dir rejected")


func test_resolver_windows_forms() -> void:
	var abs_root := ProjectSettings.globalize_path(FIXTURES + "/options")
	for root in [abs_root, abs_root.replace("/", "\\")]:
		var r := UxmlResourceResolver.new(root)
		var res := r.resolve_text("Assets/UI/Options.uss")
		check(res["ok"], "windows root form works: %s" % root)
		check(not res["text"].is_empty(), "file read under windows root form")
	var r2 := UxmlResourceResolver.new(abs_root)
	var res2 := r2.resolve("Assets\\UI\\Options.uss")
	check(res2["ok"], "backslash reference normalized")
	check(not r2.resolve("B:/dev/games/godot-uxml/tests/fixtures/options/../x.uss")["ok"], "abs .. escape rejected")


func test_collapse_canonicalization() -> void:
	eq(UxmlResourceResolver.collapse_path("/a/b/../c"), "/a/c", "unix abs keeps root slash")
	eq(UxmlResourceResolver.collapse_path("//server/share/../x"), "//server/x", "UNC keeps double slash")
	eq(UxmlResourceResolver.collapse_path("res://a/../b"), "res://b", "res:// scheme kept")
	eq(UxmlResourceResolver.collapse_path("C:/a/../b"), "C:/b", "drive kept")
	eq(UxmlResourceResolver.collapse_path("C:\\a\\..\\b"), "C:/b", "backslashes normalized")
	eq(UxmlResourceResolver.collapse_path("a/./b"), "a/b", "dot segments dropped")


# ---------------------------------------------------------------------------
# Review regression: malformed selectors must not broaden
# ---------------------------------------------------------------------------

func test_malformed_selectors_drop_rule() -> void:
	# The valid rule comes FIRST and the malformed one LAST, with equal
	# specificity to whatever the malformed selector would broaden into —
	# so any accidental broadening makes red win and the test catches it.
	for pair in [
		['Label +', 'Label'],
		['Label + ', 'Label'],
		['.x ~', '.x'],
		['.x >', '.x'],
		['> .x', '.x'],
		['.x > > .y', '.x'],
		['.x,', '.x'],
		[',.x', '.x'],
	]:
		var sel: String = pair[0]
		var base: String = pair[1]
		var doc := _doc(ONE, '%s { color: blue; } %s { color: red; }' % [base, sel])
		var res := _resolved(doc)
		eq(_val(doc, 'a', 'color'), 'blue', "malformed <%s> does not leak" % sel)
		check(_count_kind(res["warnings"], "unsupported-selector") >= 1,
			"malformed <%s> diagnoses" % sel)


# ---------------------------------------------------------------------------
# Review regression: variables resolve before shorthand expansion
# ---------------------------------------------------------------------------

func test_var_in_box_shorthand() -> void:
	for pair in [
		["--p1", ["1px", "1px", "1px", "1px"]],
		["--p2", ["1px", "2px", "1px", "2px"]],
		["--p3", ["1px", "2px", "3px", "2px"]],
		["--p4", ["1px", "2px", "3px", "4px"]],
	]:
		var prop: String = pair[0]
		var expect: Array = pair[1]
		var d := _doc(ONE, '.x { %s; padding: var(%s); }' % [_var_decl(prop), prop])
		eq(_val(d, 'a', 'padding-top'), expect[0], "var %s top" % prop)
		eq(_val(d, 'a', 'padding-right'), expect[1], "var %s right" % prop)
		eq(_val(d, 'a', 'padding-bottom'), expect[2], "var %s bottom" % prop)
		eq(_val(d, 'a', 'padding-left'), expect[3], "var %s left" % prop)


func _var_decl(name: String) -> String:
	var values := {"--p1": "1px", "--p2": "1px 2px", "--p3": "1px 2px 3px", "--p4": "1px 2px 3px 4px"}
	return "%s: %s" % [name, values[name]]


func test_var_in_flex_shorthand() -> void:
	var doc := _doc(ONE, '.x { --f: 1 30px; flex: var(--f); }')
	eq(_val(doc, 'a', 'flex-grow'), '1', "var flex grow")
	eq(_val(doc, 'a', 'flex-basis'), '30px', "var flex basis")


func test_var_shorthand_vs_longhand_order() -> void:
	# A later longhand overrides one side of a var()-driven shorthand...
	var d1 := _doc(ONE, '.x { --pad: 4px 8px; padding: var(--pad); padding-left: 9px; }')
	eq(_val(d1, 'a', 'padding-left'), '9px', "later longhand beats var shorthand side")
	eq(_val(d1, 'a', 'padding-top'), '4px', "other sides keep var shorthand")
	# ...and a later var()-driven shorthand overrides an earlier longhand.
	var d2 := _doc(ONE, '.x { --pad: 4px 8px; padding-left: 9px; padding: var(--pad); }')
	eq(_val(d2, 'a', 'padding-left'), '8px', "later var shorthand beats earlier longhand")
	eq(_val(d2, 'a', 'padding-top'), '4px', "shorthand top")


func test_var_shorthand_specificity_and_inline() -> void:
	# Winning --pad comes from the more specific rule; the padding shorthand
	# then expands from it.
	var d1 := _doc(ONE, '.x { --pad: 1px 2px; } #a { --pad: 9px; } .x { padding: var(--pad); }')
	eq(_val(d1, 'a', 'padding-left'), '9px', "id-scoped --pad wins then expands")
	var d2 := _doc('<ui:Label name="a" class="x" style="padding: 7px 3px;" />', '#a { padding: 1px; }')
	eq(_val(d2, 'a', 'padding-left'), '3px', "inline shorthand expands and beats id")
	var d3 := _doc('<ui:Label name="a" class="x" style="--pad: 5px 6px; padding: var(--pad);" />', '.x { padding: 1px; }')
	eq(_val(d3, 'a', 'padding-right'), '6px', "inline var shorthand expands")


func test_var_shorthand_inherited_custom() -> void:
	# --pad is declared on the parent and inherits; the child's own padding
	# declaration expands from the inherited value.
	var doc := _doc(
		'<ui:VisualElement class="p"><ui:Label name="kid" /></ui:VisualElement>',
		'.p { --pad: 4px 8px; } Label { padding: var(--pad); }'
	)
	eq(_val(doc, 'kid', 'padding-left'), '8px', "inherited custom property expands for child")
	eq(_val(doc, 'kid', 'padding-top'), '4px', "inherited custom property top edge")


# ---------------------------------------------------------------------------
# Review regression: nested var() and malformed var() diagnostics
# ---------------------------------------------------------------------------

func test_var_nested_fallback() -> void:
	var d1 := _doc(ONE, '.x { --base: 6px; width: var(--missing, var(--base, 8px)); }')
	eq(_val(d1, 'a', 'width'), '6px', "nested var resolves through defined property")
	var d2 := _doc(ONE, '.x { width: var(--missing, var(--also-missing, 8px)); }')
	eq(_val(d2, 'a', 'width'), '8px', "nested fallback reaches its own fallback")
	var d3 := _doc(ONE, '.x { color: var(--missing, rgb(1, 2, 3)); }')
	eq(_val(d3, 'a', 'color'), 'rgb(1, 2, 3)', "fallback containing parens/commas")


func test_var_siblings_and_quoted_fallback() -> void:
	var d1 := _doc(ONE, '.x { --x: 1px; --y: 2px; margin: var(--x) var(--y); }')
	eq(_val(d1, 'a', 'margin-top'), '1px', "sibling vars first")
	eq(_val(d1, 'a', 'margin-right'), '2px', "sibling vars second")
	var d2 := _doc(ONE, '.x { content: var(--missing, "a,b"); }')
	eq(_val(d2, 'a', 'content'), '"a,b"', "quoted fallback keeps its comma")


func test_var_cycle_uses_fallback() -> void:
	# A cyclic custom property is guaranteed-invalid (css-variables-1); at a
	# use site outside the cycle, var() substitutes its fallback — the
	# referencing declaration is NOT invalid, only the property itself.
	var doc := _doc(ONE, '.x { --a: var(--b); --b: var(--a); width: var(--a, 9px); }')
	var res := _resolved(doc)
	eq(_val(doc, 'a', 'width'), '9px', "cyclic reference substitutes use-site fallback")
	eq(_val(doc, 'a', '--a'), null, "cyclic custom property still dropped")
	eq(_val(doc, 'a', '--b'), null, "other cyclic property dropped")
	eq(_count_kind(res["warnings"], "unresolved-var"), 2, "each cyclic declaration warns")


func test_var_cycle_internal_fallback_does_not_rescue() -> void:
	# --a's own declaration references --b, which closes the cycle back on
	# --a: --a is inside the dependency cycle, so the fallback in its own
	# declaration cannot validate it (it never gets "4px").
	var doc := _doc(ONE, '.x { --a: var(--b, 4px); --b: var(--a); width: var(--a, 9px); }')
	var res := _resolved(doc)
	eq(_val(doc, 'a', '--a'), null, "fallback inside a cyclic property does not validate it")
	eq(_val(doc, 'a', 'width'), '9px', "outer use site still gets its fallback")
	eq(_count_kind(res["warnings"], "unresolved-var"), 2, "cycle members each warn")
	# A self-reference is a cycle too.
	var d2 := _doc(ONE, '.x { --a: var(--a, 5px); width: var(--a, 9px); }')
	eq(_val(d2, 'a', '--a'), null, "self-referencing property is cyclic")
	eq(_val(d2, 'a', 'width'), '9px', "self-cycle use-site fallback applies")
	# An invalid (but non-cyclic) referenced property also falls back.
	var d3 := _doc(ONE, '.x { --a: var(--missing); width: var(--a, 7px); }')
	eq(_val(d3, 'a', 'width'), '7px', "invalid referenced property falls back")
	# ...while a defined valid value wins over the fallback.
	var d4 := _doc(ONE, '.x { --a: 3px; width: var(--a, 9px); }')
	eq(_val(d4, 'a', 'width'), '3px', "defined value wins over fallback")


func test_var_malformed_drops_with_warning() -> void:
	for expr in ['var(--a', 'var(4px)', 'var()', 'var(--ok,']:
		var doc := _doc(ONE, '.x { width: %s; }' % expr)
		var res := _resolved(doc)
		eq(_val(doc, 'a', 'width'), null, "malformed <%s> does not survive as a value" % expr)
		eq(_count_kind(res["warnings"], "unresolved-var"), 1, "malformed <%s> warns" % expr)


# ---------------------------------------------------------------------------
# Review regression: diagnostics coverage
# ---------------------------------------------------------------------------

func test_unsupported_at_rules_warn_and_do_not_apply() -> void:
	# The valid rule comes FIRST and the at-rule LAST: if the unsupported
	# block's inner rules were ever applied, their later source order would
	# make red win — so this catches leakage, not just absence of effect.
	var doc := _doc(ONE, '.x { color: blue; } @media screen { .x { color: red; } }')
	var res := _resolved(doc)
	eq(_val(doc, 'a', 'color'), 'blue', "@media contents never apply")
	eq(_count_kind(doc.warnings, "unsupported-feature"), 1, "@media diagnosed")
	var doc2 := _doc(ONE, '.x { color: blue; } @supports (display: grid) { .x { color: red; } }')
	eq(_count_kind(doc2.warnings, "unsupported-feature"), 1, "@supports diagnosed")
	eq(_val(doc2, 'a', 'color'), 'blue', "@supports contents never apply")


func test_style_element_src_diagnostics() -> void:
	var doc := UxmlLoader.load_source(
		'<ui:UXML xmlns:ui="UnityEngine.UIElements"><Style /><Style src="" /><Style src="Options.uss" /><ui:Label name="a" /></ui:UXML>',
		FIXTURES + "/options/Assets/UI/StyleSrc.uxml",
		_resolver(FIXTURES + "/options")
	)
	eq(_count_kind(doc.warnings, "malformed"), 2, "missing and empty src each warn")
	eq(doc.sheets.size(), 1, "the real stylesheet still loads")


func test_unsupported_attributes_warn() -> void:
	var doc := UxmlLoader.load_source(
		'<ui:UXML xmlns:ui="UnityEngine.UIElements"><ui:Label name="a" mystery-mode="orbital" text="x" tooltip="t" /></ui:UXML>',
		"inline/test.uxml", _resolver(FIXTURES + "/options")
	)
	eq(_count_kind(doc.warnings, "unsupported-attribute"), 1, "unknown attribute warns once")
	check(doc.warnings[0]["message"].find("mystery-mode") >= 0, "warning names the attribute")
	check(doc.warnings[0]["message"].find("Label") >= 0, "warning names the element")
	# Namespace declarations and used attributes are not flagged.
	for d in doc.warnings:
		check(d["message"].find("xmlns") < 0, "xmlns not flagged")
		check(d["message"].find("tooltip") < 0 or d["kind"] != "unsupported-attribute",
			"tooltip not flagged")


func test_comments_stripped_from_values() -> void:
	var doc := _doc(ONE, '.x { color: red /*note*/; width: /*a*/ 4px /*b*/; }')
	eq(_val(doc, 'a', 'color'), 'red', "trailing comment removed from value")
	eq(_val(doc, 'a', 'width'), '4px', "comments inside value removed")


func test_escaped_quotes_in_values() -> void:
	var r := UssParser.new().parse('.x { background-image: url("a\\"b.png"); width: 1px; }')
	var rule: Dictionary = r["items"][0]["rule"]
	eq(rule["declarations"].size(), 2, "escaped quote does not end the value early")
	eq(rule["declarations"][0]["value"], 'url("a\\"b.png")', "value keeps escaped quote text")
	eq(rule["declarations"][1]["property"], "width", "next declaration still parses")


# ---------------------------------------------------------------------------
# Review regression: documented support is honest
# ---------------------------------------------------------------------------

func test_out_of_scope_properties_warn() -> void:
	# filter, -unity-material and -unity-text-auto-size are later Unity
	# versions' properties, not yet implemented.
	var doc := _doc(ONE, '.x { -unity-material: none; filter: blur(2px); -unity-text-auto-size: best-fit; color: red; }')
	var res := _resolved(doc)
	eq(_count_kind(res["warnings"], "unsupported-property"), 3, "out-of-scope properties each warn")
	eq(_val(doc, 'a', 'color'), 'red', "supported property unaffected")


# The visual properties (opacity, cursor, text spacing, ...) are inside the
# supported envelope: no unsupported-property diagnostic.
func test_visual_properties_supported() -> void:
	var doc := _doc(ONE, '.x { cursor: link; opacity: 0.5; letter-spacing: 2px; overflow: hidden; '
		+ 'translate: 5px 10%; rotate: 45deg; scale: 2; transform-origin: left top; '
		+ 'word-spacing: 1px; -unity-paragraph-spacing: 3px; text-shadow: 1px 1px red; '
		+ 'text-overflow: ellipsis; -unity-text-overflow-position: middle; white-space: pre-wrap; '
		+ '-unity-text-generator: advanced; -unity-editor-text-rendering-mode: bitmap; '
		+ 'background-position: right 4px bottom; background-repeat: repeat-x; background-size: cover; '
		+ '-unity-background-scale-mode: scale-to-fit; -unity-slice-type: tiled; '
		+ '-unity-overflow-clip-box: content-box; }')
	var res := _resolved(doc)
	eq(_count_kind(res["warnings"], "unsupported-property"), 0, "visual properties are supported")
	eq(_val(doc, 'a', 'background-size'), 'contain', "scale mode (later) expands over background-size")
	eq(_val(doc, 'a', 'background-position-x'), 'center', "scale mode resets position-x")
	eq(_val(doc, 'a', 'background-repeat'), 'no-repeat no-repeat', "scale mode resets repeat")


func test_background_position_shorthand() -> void:
	var cases := [
		["left", "left", "center"], ["bottom", "center", "bottom"], ["center", "center", "center"],
		["10px 20%", "left 10px", "top 20%"], ["bottom right", "right", "bottom"],
		["top left", "left", "top"], ["right 5px bottom 6px", "right 5px", "bottom 6px"],
		["left top 3px", "left", "top 3px"], ["right 4px center", "right 4px", "center"],
	]
	for c in cases:
		var doc := _doc(ONE, '.x { background-position: %s; }' % c[0])
		eq(_val(doc, 'a', 'background-position-x'), c[1], "background-position: %s -> x" % c[0])
		eq(_val(doc, 'a', 'background-position-y'), c[2], "background-position: %s -> y" % c[0])
	var bad := _doc(ONE, '.x { background-position: 1px 2px 3px; }')
	var res := _resolved(bad)
	eq(_count_kind(res["warnings"], "invalid-shorthand"), 1, "malformed background-position is dropped")


# all: initial resets every non-custom property to its initial value (the
# entry disappears, inheritance included); later declarations still win.
func test_all_initial() -> void:
	var body := '<ui:VisualElement name="p" class="p"><ui:Label name="a" class="x" text="t" /></ui:VisualElement>'
	var doc := _doc(body, '.p { color: red; --tok: 4px; } .x { width: 10px; opacity: 0.5; all: initial; height: 3px; } .x { padding-left: var(--tok); }')
	var res := _resolved(doc)
	var st: Dictionary = res["styles"][doc.find_by_name("a")]
	check(not st.has("width"), "all: initial drops an earlier declaration")
	check(not st.has("opacity"), "all: initial drops opacity")
	check(not st.has("color"), "all: initial stops inheritance")
	eq(st.get("height", {}).get("value"), "3px", "a later declaration in the rule still wins")
	eq(st.get("padding-left", {}).get("value"), "4px", "custom properties are untouched")
	eq(_count_kind(res["warnings"], "unsupported-property"), 0, "all expands to supported longhands only")
	var initial := _doc(ONE, '.x { color: red; } #a { color: initial; }')
	check(not (_resolved(initial)["styles"][initial.find_by_name("a")] as Dictionary).has("color"),
		"a single initial keyword drops the property")


func test_recognized_but_unmapped_controls_warn() -> void:
	# Foldout left this list when it became a Unity part tree (runtime/controls).
	for tag in ["IntegerField", "FloatField"]:
		var doc := UxmlLoader.load_source(
			'<ui:UXML xmlns:ui="UnityEngine.UIElements"><ui:%s name="f"><ui:Label name="k" /></ui:%s></ui:UXML>' % [tag, tag],
			"inline/test.uxml", _resolver(FIXTURES + "/options")
		)
		eq(_count_kind(doc.warnings, "unsupported-control"), 1, "%s warns until mapped" % tag)
		check(doc.find_by_name("k") != null, "%s children preserved" % tag)
