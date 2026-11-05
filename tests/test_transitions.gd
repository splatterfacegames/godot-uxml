extends RefCounted
## USS transitions (Unity 6 semantics): shorthand expansion, interpolation,
## discrete switching, delays, easing, retargeting and the shortened
## reversal, cancellation, inheritance, layout, events — each scenario run
## on the native and the GDScript cascade/layout with identical results.
## Time is stepped by hand: transitions_manual + advance_transitions().

const ROOT := "user://uxml_transition_tests"

var h = null


func _init(harness) -> void:
	h = harness


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## A document from inline UXML body + USS, transitions stepped by hand.
func _mk(tag: String, body: String, uss: String) -> UxmlDocument:
	var dir := "%s/%s" % [ROOT, tag]
	_write(dir + "/Assets/UI/t.uss", uss)
	_write(dir + "/Assets/UI/t.uxml",
		'<ui:UXML xmlns:ui="UnityEngine.UIElements"><Style src="t.uss" />%s</ui:UXML>' % body)
	var doc := UxmlDocument.new()
	doc.transitions_manual = true
	h.root.add_child(doc)
	doc.size = Vector2(400, 300)
	doc.load_document("Assets/UI/t.uxml", dir)
	return doc


func _unload(doc: UxmlDocument) -> void:
	h.root.remove_child(doc)
	doc.free()


func _v(doc: UxmlDocument, el: String, prop: String):
	var e = doc.get_computed_style(el).get(prop)
	return null if e == null else e["value"]


func _color(doc: UxmlDocument, el: String, prop: String) -> Color:
	return UssValues.parse_color(String(_v(doc, el, prop)))["color"]


func _px(doc: UxmlDocument, el: String, prop: String) -> float:
	return float(UssValues.parse_length(String(_v(doc, el, prop)))["value"])


func _near(a: float, b: float, msg: String, tol := 0.01) -> void:
	h.check(absf(a - b) <= tol, "%s -- expected %s, got %s" % [msg, b, a])


## Runs `body(doc_factory) -> Array` (a trace of observed values) on the
## native path and the GDScript path; both traces must match exactly.
func _both(body: Callable) -> void:
	var native_ok := ClassDB.class_exists("UxmlNativeCascade")
	var saved_c := UssCascade.use_native
	var saved_l := UxmlDocument.use_native_layout
	var traces: Array = []
	for native in ([true, false] if native_ok else [false]):
		UssCascade.use_native = native
		UxmlDocument.use_native_layout = native
		traces.append(await body.call())
	UssCascade.use_native = saved_c
	UxmlDocument.use_native_layout = saved_l
	if traces.size() == 2:
		h.eq(traces[1], traces[0], "GDScript trace equals native trace")


# ---------------------------------------------------------------------------

func test_shorthand_expands_to_longhands() -> void:
	var exp := UssProperties.expand_shorthand("transition", "margin-right 4s, color 1s ease-in 200ms")
	h.eq(exp, [
		["transition-property", "margin-right, color"],
		["transition-duration", "4s, 1s"],
		["transition-delay", "0s, 200ms"],
		["transition-timing-function", "ease, ease-in"],
	], "transition shorthand lists")
	h.eq(UssProperties.expand_shorthand("transition", "width 2s 1s 3s")[0][1], "all",
		"three times: invalid, initial values")
	h.eq(UssProperties.expand_shorthand("transition", "none, color 1s")[1][1], "0s",
		"none followed by more items: invalid")
	h.eq(UssProperties.expand_shorthand("transition", "none")[0][1], "none", "none alone")
	h.eq(UssProperties.expand_shorthand("transition", "1s linear")[0][1], "all", "property defaults to all")
	h.eq(UssProperties.expand_shorthand("transition", "initial")[3][1], "ease", "initial")


func test_transition_properties_are_supported() -> void:
	var src := '<ui:UXML xmlns:ui="UnityEngine.UIElements"><ui:Label name="a" class="x" /></ui:UXML>'
	var doc := UxmlLoader.load_source(src, "inline/t.uxml",
		UxmlResourceResolver.new("res://tests/fixtures/options"),
		'.x { transition: color 1s; transition-delay: 2s; color: red; }')
	var res := UssStyleResolver.resolve(doc)
	var n := 0
	for w in res["warnings"]:
		if w["kind"] == "unsupported-property":
			n += 1
	h.eq(n, 0, "transition properties do not warn")
	var st: Dictionary = res["styles"][doc.find_by_name("a")]
	h.eq(st["transition-delay"]["value"], "2s", "later longhand beats the shorthand's delay")
	h.eq(st["transition-property"]["value"], "color", "property from the shorthand")


func test_easing_curves() -> void:
	# Unity's curves (Easing.cs / ComputedTransitionUtils), spot values.
	_near(UssTransitions.easing(0, 0.5), 0.725, "ease (best-fit cubic)", 1e-6)
	_near(UssTransitions.easing(1, 0.5), 0.25, "ease-in (quad)", 1e-6)
	_near(UssTransitions.easing(2, 0.5), 0.75, "ease-out (quad)", 1e-6)
	_near(UssTransitions.easing(3, 0.25), 0.125, "ease-in-out", 1e-6)
	_near(UssTransitions.easing(4, 0.3), 0.3, "linear", 1e-6)
	_near(UssTransitions.easing(5, 0.5), 1.0 - sqrt(0.5), "ease-in-sine", 1e-6)
	_near(UssTransitions.easing(9, 0.5), 0.875, "ease-out-cubic", 1e-6)
	_near(UssTransitions.easing(11, 1.0), 1.0, "ease-in-circ end", 1e-6)
	_near(UssTransitions.easing(15, 1.0), 1.0, "ease-out-elastic end", 1e-6)
	h.check(UssTransitions.easing(17, 0.2) < 0.0, "ease-in-back undershoots")
	_near(UssTransitions.easing(21, 0.2), 7.5625 * 0.04, "ease-out-bounce first arc", 1e-6)
	for m in UssProperties.EASING_MODES.size():
		_near(UssTransitions.easing(m, 0.0), 0.0, "%s starts at 0" % UssProperties.EASING_MODES[m], 1e-6)
		_near(UssTransitions.easing(m, 1.0), 1.0, "%s ends at 1" % UssProperties.EASING_MODES[m], 1e-6)


func test_color_transition_linear_and_events() -> void:
	await _both(func() -> Array:
		var doc := _mk("color", '<ui:VisualElement name="box" class="box" />',
			'.box { width: 50px; height: 50px; background-color: rgb(0, 0, 0); transition: background-color 1s linear; }\n'
			+ '.on { background-color: rgb(255, 0, 0); }')
		var events: Array = []
		doc.transition_run.connect(func(n, p, t): events.append(["run", n, p, t]))
		doc.transition_start.connect(func(n, p, t): events.append(["start", n, p, t]))
		doc.transition_end.connect(func(n, p, t): events.append(["end", n, p, t]))
		doc.transition_cancel.connect(func(n, p, t): events.append(["cancel", n, p, t]))
		var trace: Array = []
		h.eq(doc.has_running_transitions(), false, "nothing runs after load")
		doc.set_class("box", "box on")
		doc._restyle_now()
		h.check(doc.has_running_transitions(), "class change starts a transition")
		_near(_color(doc, "box", "background-color").r, 0.0, "start value right after the change")
		trace.append(_v(doc, "box", "background-color"))
		doc.advance_transitions(0.25)
		_near(_color(doc, "box", "background-color").r, 0.25, "a quarter of the way at 0.25s")
		trace.append(_v(doc, "box", "background-color"))
		doc.advance_transitions(0.5)
		_near(_color(doc, "box", "background-color").r, 0.75, "three quarters at 0.75s")
		trace.append(_v(doc, "box", "background-color"))
		doc.advance_transitions(0.5)
		h.eq(_v(doc, "box", "background-color"), "rgb(255, 0, 0)", "end: the authored value itself")
		h.eq(doc.has_running_transitions(), false, "finished")
		var box := doc.get_element("box") as UxmlBox
		trace.append(_v(doc, "box", "background-color"))
		h.eq(events, [
			["run", "box", "background-color", 0.0],
			["start", "box", "background-color", 0.0],
			["end", "box", "background-color", 1.0],
		], "run, start, end events")
		trace.append(events)
		trace.append(box != null)
		_unload(doc)
		return trace)


func test_delay_and_negative_delay() -> void:
	await _both(func() -> Array:
		var doc := _mk("delay", '<ui:VisualElement name="a" class="a" /><ui:VisualElement name="b" class="b" />',
			'.a { width: 0px; height: 10px; transition: width 1s linear 500ms; }\n'
			+ '.b { width: 0px; height: 10px; transition: width 1s linear -500ms; }\n'
			+ '.on { width: 100px; }')
		var trace: Array = []
		var starts: Array = []
		doc.transition_start.connect(func(n, _p, t): starts.append([n, t]))
		doc.set_class("a", "a on")
		doc.set_class("b", "b on")
		doc._restyle_now()
		doc.advance_transitions(0.0)
		_near(_px(doc, "a", "width"), 0.0, "positive delay: held at the start value")
		_near(_px(doc, "b", "width"), 50.0, "negative delay: starts half way")
		trace.append([_v(doc, "a", "width"), _v(doc, "b", "width")])
		doc.advance_transitions(0.25)
		_near(_px(doc, "a", "width"), 0.0, "still delayed at 0.25s")
		_near(_px(doc, "b", "width"), 75.0, "negative delay at 0.25s")
		doc.advance_transitions(0.5)
		_near(_px(doc, "a", "width"), 25.0, "delayed transition a quarter in")
		trace.append([_v(doc, "a", "width"), _v(doc, "b", "width")])
		h.eq(starts, [["b", 0.5], ["a", 0.0]], "start events carry the negative delay as elapsed time")
		doc.advance_transitions(1.0)
		h.eq(_v(doc, "a", "width"), "100px", "delayed transition ends")
		trace.append(starts)
		_unload(doc)
		return trace)


func test_layout_follows_animated_width() -> void:
	await _both(func() -> Array:
		var doc := _mk("layout", '<ui:VisualElement name="w" class="w" />',
			'.w { width: 100px; height: 20px; transition: width 1s linear; }\n.on { width: 300px; }')
		var c := doc.get_element("w")
		doc.set_class("w", "w on")
		doc._restyle_now()
		var trace: Array = [c.size.x]
		_near(c.size.x, 100.0, "layout at start")
		doc.advance_transitions(0.5)
		_near(c.size.x, 200.0, "layout re-runs for a layout property")
		trace.append(c.size.x)
		doc.advance_transitions(0.5)
		_near(c.size.x, 300.0, "layout at end")
		trace.append(c.size.x)
		_unload(doc)
		return trace)


func test_reversal_is_shortened() -> void:
	await _both(func() -> Array:
		var doc := _mk("reverse", '<ui:VisualElement name="r" class="r" />',
			'.r { width: 0px; height: 10px; transition: width 1s linear; }\n.on { width: 100px; }')
		var events: Array = []
		doc.transition_run.connect(func(_n, _p, t): events.append(["run", t]))
		doc.transition_cancel.connect(func(_n, _p, t): events.append(["cancel", t]))
		doc.transition_end.connect(func(_n, _p, t): events.append(["end", t]))
		doc.set_class("r", "r on")
		doc._restyle_now()
		doc.advance_transitions(0.5)
		_near(_px(doc, "r", "width"), 50.0, "half way")
		doc.set_class("r", "r")
		doc._restyle_now()
		_near(_px(doc, "r", "width"), 50.0, "reversal starts at the current value")
		doc.advance_transitions(0.25)
		# Reversing shortening factor 0.5: back to 0 in 500ms, not 1s.
		_near(_px(doc, "r", "width"), 25.0, "reversal runs at the original speed")
		var mid: Variant = _v(doc, "r", "width")
		doc.advance_transitions(0.25)
		h.eq(_v(doc, "r", "width"), "0px", "reversal ends after half the duration")
		h.eq(events, [["run", 0.0], ["cancel", 0.0], ["run", 0.0], ["end", 0.5]],
			"retarget: cancel + run, end reports the shortened duration")
		var trace: Array = [mid, events]
		_unload(doc)
		return trace)


func test_retarget_to_new_value() -> void:
	await _both(func() -> Array:
		var doc := _mk("retarget", '<ui:VisualElement name="r" class="r" />',
			'.r { width: 0px; height: 10px; transition: width 1s linear; }\n'
			+ '.on { width: 100px; }\n.far { width: 200px; }')
		doc.set_class("r", "r on")
		doc._restyle_now()
		doc.advance_transitions(0.5)
		doc.set_class("r", "r far")
		doc._restyle_now()
		_near(_px(doc, "r", "width"), 50.0, "new transition starts from the current value")
		doc.advance_transitions(0.5)
		_near(_px(doc, "r", "width"), 125.0, "full duration towards the new target")
		var trace: Array = [_v(doc, "r", "width")]
		doc.advance_transitions(0.5)
		h.eq(_v(doc, "r", "width"), "200px", "ends at the new target")
		_unload(doc)
		return trace)


func test_discrete_switches_half_way() -> void:
	await _both(func() -> Array:
		var doc := _mk("discrete", '<ui:VisualElement name="d" class="d"><ui:Label text="x" /></ui:VisualElement>',
			'.d { flex-direction: column; transition: flex-direction 1s linear; }\n.on { flex-direction: row; }')
		doc.set_class("d", "d on")
		doc._restyle_now()
		doc.advance_transitions(0.4)
		h.eq(_v(doc, "d", "flex-direction"), "column", "before the midpoint: start value")
		doc.advance_transitions(0.2)
		h.eq(_v(doc, "d", "flex-direction"), "row", "after the midpoint: end value")
		var trace: Array = [_v(doc, "d", "flex-direction")]
		doc.advance_transitions(1.0)
		h.eq(doc.has_running_transitions(), false, "discrete transition ends")
		_unload(doc)
		return trace)


func test_non_animatable_and_unlisted_change_immediately() -> void:
	await _both(func() -> Array:
		var doc := _mk("immediate", '<ui:VisualElement name="n" class="n" />',
			'.n { height: 10px; width: auto; color: rgb(0, 0, 0); transition: width 1s, display 1s; }\n'
			+ '.on { width: 100px; display: none; color: rgb(255, 255, 255); }')
		doc.set_class("n", "n on")
		doc._restyle_now()
		h.eq(_v(doc, "n", "width"), "100px", "auto -> length: no transition")
		h.eq(_v(doc, "n", "display"), "none", "display is not animatable")
		h.eq(_v(doc, "n", "color"), "rgb(255, 255, 255)", "color is not in transition-property")
		h.eq(doc.has_running_transitions(), false, "nothing runs")
		var trace: Array = [_v(doc, "n", "width")]
		_unload(doc)
		return trace)


func test_inherited_value_animates_children() -> void:
	await _both(func() -> Array:
		var doc := _mk("inherit", '<ui:VisualElement name="p" class="p"><ui:Label name="c" text="x" /></ui:VisualElement>',
			'.p { color: rgb(0, 0, 0); transition: color 1s linear; }\n.on { color: rgb(0, 0, 255); }')
		doc.set_class("p", "p on")
		doc._restyle_now()
		doc.advance_transitions(0.5)
		_near(_color(doc, "c", "color").b, 0.5, "child inherits the animated colour")
		h.eq(_v(doc, "c", "color"), _v(doc, "p", "color"), "child value equals the parent's current value")
		var lbl := doc.get_native("c") as Label
		_near(lbl.get_theme_color("font_color").b, 0.5, "applier paints the animated colour", 0.02)
		var trace: Array = [_v(doc, "c", "color")]
		doc.advance_transitions(0.5)
		h.eq(_v(doc, "c", "color"), "rgb(0, 0, 255)", "child ends with the parent")
		_unload(doc)
		return trace)


func test_removing_transition_cancels_to_end_value() -> void:
	await _both(func() -> Array:
		var doc := _mk("cancel", '<ui:VisualElement name="x" class="x" />',
			'.x { height: 10px; width: 0px; transition: width 1s linear; }\n'
			+ '.on { width: 100px; }\n.stop { transition-property: none; }')
		var events: Array = []
		doc.transition_cancel.connect(func(n, p, t): events.append([n, p, t]))
		doc.set_class("x", "x on")
		doc._restyle_now()
		doc.advance_transitions(0.25)
		doc.set_class("x", "x on stop")
		doc._restyle_now()
		h.eq(_v(doc, "x", "width"), "100px", "cancelled transition jumps to its end value")
		h.eq(doc.has_running_transitions(), false, "nothing runs")
		h.eq(events, [["x", "width", 0.25]], "cancel event with elapsed time")
		var trace: Array = [events]
		_unload(doc)
		return trace)


func test_unit_conversion_px_to_percent() -> void:
	await _both(func() -> Array:
		var doc := _mk("units", '<ui:VisualElement name="p" style="width: 400px; height: 100px;"><ui:VisualElement name="u" class="u" /></ui:VisualElement>',
			'.u { height: 10px; width: 100px; transition: width 1s linear; }\n.on { width: 50%; }')
		doc.set_class("u", "u on")
		doc._restyle_now()
		h.eq(_v(doc, "u", "width"), "25%", "start converted to the end unit against the parent")
		doc.advance_transitions(0.5)
		h.eq(_v(doc, "u", "width"), "37.5%", "interpolated in percent")
		_near(doc.get_element("u").size.x, 150.0, "layout of the percentage")
		var trace: Array = [_v(doc, "u", "width")]
		_unload(doc)
		return trace)


func test_shorthand_property_names_and_lists_cycle() -> void:
	await _both(func() -> Array:
		var doc := _mk("lists", '<ui:VisualElement name="m" class="m" />',
			'.m { height: 10px; margin: 0px; border-color: rgb(0, 0, 0); border-width: 1px;\n'
			+ ' transition-property: margin, border-color; transition-duration: 1s, 2s; transition-timing-function: linear; }\n'
			+ '.on { margin: 10px; border-color: rgb(255, 255, 255); }')
		doc.set_class("m", "m on")
		doc._restyle_now()
		doc.advance_transitions(0.5)
		_near(_px(doc, "m", "margin-left"), 5.0, "margin shorthand name animates the longhands")
		_near(_color(doc, "m", "border-top-color").r, 0.25, "second duration applies to border-color")
		var trace: Array = [_v(doc, "m", "margin-top"), _v(doc, "m", "border-left-color")]
		doc.advance_transitions(2.0)
		h.eq(doc.has_running_transitions(), false, "all done")
		_unload(doc)
		return trace)


func test_no_per_frame_work_when_idle() -> void:
	var doc := _mk("idle", '<ui:VisualElement name="i" class="i" />',
		'.i { height: 10px; background-color: rgb(0, 0, 0); transition: background-color 100ms; }\n.on { background-color: rgb(9, 9, 9); }')
	doc.transitions_manual = false
	h.eq(doc.is_processing(), false, "no _process without transitions")
	doc.set_class("i", "i on")
	doc._restyle_now()
	h.check(doc.is_processing(), "frame clock drives a running transition")
	for _f in 5000:
		await h.process_frame
		if not doc.has_running_transitions():
			break
	await h.process_frame
	h.eq(doc.has_running_transitions(), false, "transition finished on the frame clock")
	h.eq(doc.is_processing(), false, "processing stops when nothing runs")
	h.eq(_v(doc, "i", "background-color"), "rgb(9, 9, 9)", "end value")
	_unload(doc)


func test_child_with_own_transition_on_inherited_property() -> void:
	await _both(func() -> Array:
		var doc := _mk("lag", '<ui:VisualElement name="p" class="p"><ui:Label name="c" class="c" text="x" /></ui:VisualElement>',
			'.p { color: rgb(0, 0, 0); transition: color 1s linear; }\n.on { color: rgb(0, 0, 255); }\n'
			+ '.c { transition: color 1s linear; }')
		var child_events: Array = []
		doc.transition_run.connect(func(n, p, _t): if n == "c": child_events.append(["run", p]))
		doc.transition_cancel.connect(func(n, p, _t): if n == "c": child_events.append(["cancel", p]))
		doc.set_class("p", "p on")
		doc._restyle_now()
		# Unity: the parent's computed colour is still the start value when
		# the child is styled, so the child sees no change (here: a run and
		# a cancel inside one restyle, which collapse to nothing).
		h.eq(child_events, [], "no child events on the starting restyle")
		h.eq(_v(doc, "c", "color"), _v(doc, "p", "color"), "child inherits the start value")
		doc.advance_transitions(0.5)
		h.eq(child_events, [["run", "color"]], "parent animation restarts the child's own transition")
		_near(_color(doc, "p", "color").b, 0.5, "parent half way")
		h.check(_color(doc, "c", "color").b < 0.5, "child lags behind its parent")
		var trace: Array = [_v(doc, "c", "color"), child_events.duplicate()]
		doc.advance_transitions(3.0)
		# Both finished in that frame; the child's own transition ended at
		# the parent's half-way colour, and the parent's end value now
		# reaches it as a new change — a new transition from there.
		_near(_color(doc, "c", "color").b, 0.5, "child restarts from its last end value", 0.02)
		h.check(doc.has_running_transitions(), "child's follow-up transition runs")
		doc.advance_transitions(1.0)
		h.eq(_v(doc, "c", "color"), "rgb(0, 0, 255)", "child settles on the inherited end value")
		h.eq(doc.has_running_transitions(), false, "all done")
		_unload(doc)
		return trace)


func test_refresh_keeps_and_reload_clears_transitions() -> void:
	await _both(func() -> Array:
		var doc := _mk("refresh", '<ui:VisualElement name="f" class="f" />',
			'.f { height: 10px; width: 0px; transition: width 1s linear; }\n.on { width: 100px; }')
		doc.set_class("f", "f on")
		doc._restyle_now()
		doc.advance_transitions(0.5)
		doc.refresh()
		doc._restyle_now()
		_near(_px(doc, "f", "width"), 50.0, "refresh keeps the animated value")
		h.check(doc.has_running_transitions(), "refresh keeps the transition running")
		doc.advance_transitions(0.25)
		_near(_px(doc, "f", "width"), 75.0, "transition continues after refresh")
		var kinds: Array = []
		for d in doc.diagnostics:
			if String(d.get("message", "")).find("transition") >= 0:
				kinds.append(d["kind"])
		h.eq(kinds, [], "no diagnostics about transition properties")
		doc.reload()
		h.eq(doc.has_running_transitions(), false, "reload drops running transitions")
		h.eq(_v(doc, "f", "width"), "0px", "reloaded document starts from its authored value")
		var trace: Array = [_v(doc, "f", "width")]
		_unload(doc)
		return trace)


func test_all_animates_every_changed_property() -> void:
	await _both(func() -> Array:
		var doc := _mk("all", '<ui:VisualElement name="a" class="a" />',
			'.a { height: 10px; width: 10px; opacity: 1; background-color: rgb(0, 0, 0); transition: all 1s linear; }\n'
			+ '.on { width: 30px; opacity: 0.5; background-color: rgb(0, 255, 0); display: flex; }')
		var runs: Array = []
		doc.transition_run.connect(func(_n, p, _t): runs.append(p))
		doc.set_class("a", "a on")
		doc._restyle_now()
		doc.advance_transitions(0.5)
		_near(_px(doc, "a", "width"), 20.0, "all: width")
		_near(float(_v(doc, "a", "opacity")), 0.75, "all: opacity")
		_near(_color(doc, "a", "background-color").g, 0.5, "all: background-color")
		runs.sort()
		h.eq(runs, ["background-color", "opacity", "width"], "one run event per changed animatable property")
		var trace: Array = [_v(doc, "a", "width"), _v(doc, "a", "opacity"), _v(doc, "a", "background-color")]
		_unload(doc)
		return trace)


# ---------------------------------------------------------------------------
# Transitions with the default theme and control part trees
# ---------------------------------------------------------------------------

## A part element (the Toggle checkmark) animates an author state rule; a
## theme-styled property (the Button hover colour, the `unity-disabled`
## opacity) animates from the theme value to the new theme value.
func test_transitions_on_parts_and_theme_values() -> void:
	await _both(func() -> Array:
		var doc := _mk("parts", '<ui:Toggle name="t" label="L" /><ui:Button name="b" text="B" />'
			+ '<ui:Button name="c" text="C" class="fade" />',
			'.unity-toggle__checkmark { transition: background-color 1s linear; }\n'
			+ '.unity-toggle__input:checked > .unity-toggle__checkmark { background-color: rgb(255, 0, 0); }\n'
			+ '.unity-button { transition: background-color 1s linear; }\n'
			+ '.fade { transition: opacity 1s linear; }')
		var trace: Array = []
		var check := UxmlParts.find_part(doc.get_element_model("t"), "checkmark")
		(doc.get_native("t") as UxmlToggle).button_pressed = true
		doc._restyle_now()
		h.check(doc.has_running_transitions(), "a :checked change on a part starts a transition")
		doc.advance_transitions(0.5)
		var mid: Color = UssValues.parse_color(String(doc._styles[check]["background-color"]["value"]))["color"]
		_near(mid.g * 255.0, 120.0, "the checkmark part is half way from the theme rgb(240, 240, 240)", 0.6)
		trace.append(doc._styles[check]["background-color"]["value"])
		doc.advance_transitions(0.6)
		h.eq(doc._styles[check]["background-color"]["value"], "rgb(255, 0, 0)", "the part reaches the end value")
		# Theme value -> theme value (.unity-button -> .unity-button:hover).
		h.eq(_v(doc, "b", "background-color"), "rgb(188, 188, 188)", "theme Button colour")
		doc.set_element_state("b", "hover", true)
		doc._restyle_now()
		doc.advance_transitions(0.5)
		var hc := _color(doc, "b", "background-color")
		_near(hc.r * 255.0, (188.0 + 209.0) / 2.0, "theme colour half way to the theme hover colour", 0.6)
		trace.append(_v(doc, "b", "background-color"))
		# The disabled opacity of the theme animates too.
		doc.set_enabled("c", false)
		doc._restyle_now()
		doc.advance_transitions(0.5)
		_near(float(_v(doc, "c", "opacity")), 0.75, "unity-disabled opacity half way")
		_near((doc.get_element("c") as Control).modulate.a, 0.75, "the painted opacity follows")
		trace.append(_v(doc, "c", "opacity"))
		doc.advance_transitions(0.6)
		_near((doc.get_element("c") as Control).modulate.a, 0.5, "end: opacity 0.5")
		_unload(doc)
		return trace)
