extends RefCounted
## Milestone 2 layout tests: the flex-subset geometry engine, driven through
## real parsed UXML/USS and the real cascade — only the intrinsic leaf
## measure is injected, so every asserted rectangle comes out of the same
## code path the runtime uses.

var h = null


func _init(harness) -> void:
	h = harness


## Parse body+uss, resolve, and run UxmlFlexLayout with a fake intrinsic
## measure: elements carry natural sizes by `name` via `intrinsic`.
func _layout(
	body: String,
	uss: String,
	host: Vector2,
	intrinsic: Dictionary = {}
) -> Dictionary:
	var doc: UxmlDocumentModel = h._doc(body, uss)
	var res := UssStyleResolver.resolve(doc, {})
	var warnings: Array = []
	var measurer := func(el: UxmlElement, _style: Dictionary, _hint: float) -> Vector2:
		var n = el.get_attribute("name")
		if n != null and intrinsic.has(String(n)):
			return intrinsic[String(n)]
		return Vector2.ZERO
	var out := UxmlFlexLayout.compute(
		doc.root, res["styles"], host, measurer, warnings,
		{"source": doc.source, "file": doc.path}
	)
	return {
		"doc": doc, "rects": out["rects"], "content": out["content_sizes"],
		"warnings": warnings + res["warnings"],
	}


func _rect(r: Dictionary, name: String) -> Variant:
	var el: UxmlElement = r["doc"].find_by_name(name)
	if el == null:
		return "no element %s" % name
	return r["rects"].get(el, "no rect for %s" % name)


func _vec_eq(actual: Variant, expected: Rect2, msg: String) -> void:
	if actual is Rect2:
		var ok := (
			is_equal_approx(actual.position.x, expected.position.x)
			and is_equal_approx(actual.position.y, expected.position.y)
			and is_equal_approx(actual.size.x, expected.size.x)
			and is_equal_approx(actual.size.y, expected.size.y)
		)
		h.check(ok, "%s -- expected %s, got %s" % [msg, expected, actual])
	else:
		h.check(false, "%s -- %s" % [msg, actual])


func _warn_kinds(r: Dictionary) -> Array:
	var out: Array = []
	for d in r["warnings"]:
		out.append(d["kind"])
	return out


# Acceptance case 1: row, padding, gap, grow, stretch cross.
func test_row_grow_and_stretch() -> void:
	var r := _layout(
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="c"/>'
		+ '<ui:VisualElement name="b" class="c"/>'
		+ '</ui:VisualElement>',
		'.row { flex-direction: row; width: 400px; height: 200px; padding: 10px; gap: 10px; }'
		+ '.c { flex-basis: 100px; flex-grow: 1; }',
		Vector2(400, 200)
	)
	# Inner 380, one gap 10, free 170 -> each 185; stretch height 180.
	_vec_eq(_rect(r, "a"), Rect2(10, 10, 185, 180), "first child 185x180 at x10")
	_vec_eq(_rect(r, "b"), Rect2(205, 10, 185, 180), "second child at x205")


# Acceptance case 1 (border variant): border consumes content space.
func test_border_width_shrinks_content() -> void:
	var r := _layout(
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="c"/>'
		+ '<ui:VisualElement name="b" class="c"/>'
		+ '</ui:VisualElement>',
		'.row { flex-direction: row; width: 400px; height: 200px; padding: 10px;'
		+ ' gap: 10px; border-width: 5px; border-color: #ffffff; }'
		+ '.c { flex-basis: 100px; flex-grow: 1; }',
		Vector2(400, 200)
	)
	# Inner 370 wide, free 160 -> each 180; offset by pad+border = 15.
	_vec_eq(_rect(r, "a"), Rect2(15, 15, 180, 170), "border+padding offset")
	_vec_eq(_rect(r, "b"), Rect2(205, 15, 180, 170), "second child after gap")


# Acceptance case 2: shrink distribution and min/max freeze.
func test_shrink_and_minmax() -> void:
	var uss := '.row { flex-direction: row; width: 300px; } .c { flex-basis: 200px; }'
	var r := _layout(
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="c"/><ui:VisualElement name="b" class="c"/>'
		+ '</ui:VisualElement>',
		uss, Vector2(300, 100)
	)
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 150, 0), "shrink: 150 each")
	_vec_eq(_rect(r, "b"), Rect2(150, 0, 150, 0), "shrink: second at 150")

	# First clamped by min-width 180 -> 180, second takes the remaining 120.
	r = _layout(
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="c min"/><ui:VisualElement name="b" class="c"/>'
		+ '</ui:VisualElement>',
		uss + '.min { min-width: 180px; }', Vector2(300, 100)
	)
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 180, 0), "frozen at min 180")
	_vec_eq(_rect(r, "b"), Rect2(180, 0, 120, 0), "remainder redistributed")

	# Grow with max-width freeze: free space goes to the unfrozen sibling.
	r = _layout(
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="g cap"/><ui:VisualElement name="b" class="g"/>'
		+ '</ui:VisualElement>',
		'.row { flex-direction: row; width: 400px; }'
		+ '.g { flex-basis: 0px; flex-grow: 1; } .cap { max-width: 120px; }',
		Vector2(400, 100)
	)
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 120, 0), "capped at max 120")
	_vec_eq(_rect(r, "b"), Rect2(120, 0, 280, 0), "rest grows to fill")


# Acceptance case 3: percentage widths against content box; re-layout on
# host change without reloading.
func test_percent_and_host_resize() -> void:
	var body := (
		'<ui:VisualElement name="p" class="p">'
		+ '<ui:VisualElement name="c" class="c">'
		+ '<ui:VisualElement name="n" class="n"/>'
		+ '</ui:VisualElement></ui:VisualElement>'
	)
	var uss := (
		'.p { width: 100%; padding: 10px; }'
		+ '.c { width: 50%; } .n { width: 50%; }'
	)
	var r := _layout(body, uss, Vector2(400, 200))
	_vec_eq(_rect(r, "c"), Rect2(10, 10, 190, 0), "50% of content 380")
	_vec_eq(_rect(r, "n"), Rect2(0, 0, 95, 0), "nested 50% of 190 content")

	var r2 := _layout(body, uss, Vector2(800, 200))
	_vec_eq(_rect(r2, "c"), Rect2(10, 10, 390, 0), "host 800: 50% of 780")
	_vec_eq(_rect(r2, "n"), Rect2(0, 0, 195, 0), "nested stays proportional")


# Acceptance case 4: wrapping row, gap, align-self; column direction and
# intrinsic content sizing covered too.
func test_wrap_gap_and_align() -> void:
	var r := _layout(
		'<ui:VisualElement name="w" class="w">'
		+ '<ui:VisualElement name="c1" class="c tall"/>'
		+ '<ui:VisualElement name="c2" class="c end"/>'
		+ '<ui:VisualElement name="c3" class="c"/>'
		+ '</ui:VisualElement>',
		'.w { flex-direction: row; flex-wrap: wrap; width: 300px; gap: 10px; }'
		+ '.c { width: 140px; height: 50px; }'
		+ '.tall { height: 80px; } .end { align-self: flex-end; }',
		Vector2(300, 300)
	)
	_vec_eq(_rect(r, "c1"), Rect2(0, 0, 140, 80), "first on line 1")
	_vec_eq(_rect(r, "c2"), Rect2(150, 30, 140, 50), "align-self flex-end in 80px line")
	_vec_eq(_rect(r, "c3"), Rect2(0, 90, 140, 50), "third wraps: line cross 80 + gap 10")

	# Column direction: children stack vertically by intrinsic height.
	r = _layout(
		'<ui:VisualElement name="col" class="col">'
		+ '<ui:VisualElement name="x"/><ui:VisualElement name="y"/>'
		+ '</ui:VisualElement>',
		'.col { flex-direction: column; width: 200px; gap: 5px; }',
		Vector2(200, 200),
		{"x": Vector2(60, 20), "y": Vector2(40, 30)}
	)
	_vec_eq(_rect(r, "x"), Rect2(0, 0, 200, 20), "column first, stretched cross")
	_vec_eq(_rect(r, "y"), Rect2(0, 25, 200, 30), "column second below gap")


# Acceptance case 5: display:none consumes nothing; visibility:hidden keeps
# its box; margins stay outside the border box.
func test_display_visibility_and_margins() -> void:
	var r := _layout(
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="c"/>'
		+ '<ui:VisualElement name="gone" class="c none"/>'
		+ '<ui:VisualElement name="hid" class="c ghost"/>'
		+ '<ui:VisualElement name="b" class="c"/>'
		+ '</ui:VisualElement>',
		'.row { flex-direction: row; width: 400px; }'
		+ '.c { width: 100px; height: 50px; }'
		+ '.none { display: none; } .ghost { visibility: hidden; }',
		Vector2(400, 100)
	)
	var gone = _rect(r, "gone")
	h.check(not gone is Rect2, "display:none has no rect (got %s)" % gone)
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 100, 50), "a at start")
	_vec_eq(_rect(r, "hid"), Rect2(100, 0, 100, 50), "hidden keeps its space")
	_vec_eq(_rect(r, "b"), Rect2(200, 0, 100, 50), "b after hidden, not after gone")

	# Margins are outside the border box: the control stays 100 wide while
	# the flow reserves 120.
	r = _layout(
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="c m"/><ui:VisualElement name="b" class="c"/>'
		+ '</ui:VisualElement>',
		'.row { flex-direction: row; width: 400px; }'
		+ '.c { width: 100px; height: 50px; } .m { margin: 10px; }',
		Vector2(400, 100)
	)
	_vec_eq(_rect(r, "a"), Rect2(10, 10, 100, 50), "margin offsets, width stays 100")
	_vec_eq(_rect(r, "b"), Rect2(120, 0, 100, 50), "sibling placed after margin box")


# justify-content distribution modes.
func test_justify_content() -> void:
	var base := (
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="c"/><ui:VisualElement name="b" class="c"/>'
		+ '</ui:VisualElement>'
	)
	var uss := '.row { flex-direction: row; width: 300px; %s } .c { width: 50px; height: 20px; }'
	var r := _layout(base, uss % "justify-content: space-between;", Vector2(300, 50))
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 50, 20), "space-between first")
	_vec_eq(_rect(r, "b"), Rect2(250, 0, 50, 20), "space-between last")

	r = _layout(base, uss % "justify-content: center;", Vector2(300, 50))
	_vec_eq(_rect(r, "a"), Rect2(100, 0, 50, 20), "centered first")
	_vec_eq(_rect(r, "b"), Rect2(150, 0, 50, 20), "centered second")

	r = _layout(base, uss % "justify-content: space-evenly;", Vector2(300, 50))
	_vec_eq(_rect(r, "a"), Rect2(66.667, 0, 50, 20), "evenly first ~66.7")
	_vec_eq(_rect(r, "b"), Rect2(183.333, 0, 50, 20), "evenly second ~183.3")


# Auto sizes: intrinsic content drives auto dimensions; percentages of an
# indefinite axis fall back rather than exploding.
func test_auto_and_indefinite_percent() -> void:
	var r := _layout(
		'<ui:VisualElement name="col" class="col">'
		+ '<ui:Label name="txt"/><ui:VisualElement name="box" class="b"/>'
		+ '</ui:VisualElement>',
		'.col { width: 200px; } .b { height: 10px; }',
		Vector2(200, 200),
		{"txt": Vector2(80, 16)}
	)
	_vec_eq(_rect(r, "txt"), Rect2(0, 0, 200, 16), "auto height = intrinsic")
	_vec_eq(_rect(r, "box"), Rect2(0, 16, 200, 10), "explicit height after")

	# Auto-size container wraps its content (column: max child width).
	r = _layout(
		'<ui:VisualElement name="wrap"><ui:VisualElement name="col" class="col">'
		+ '<ui:VisualElement name="i" class="i"/></ui:VisualElement></ui:VisualElement>',
		'.col { } .i { width: 50px; height: 10px; }',
		Vector2(300, 200)
	)
	_vec_eq(_rect(r, "col"), Rect2(0, 0, 300, 10), "auto width stretches to host")

	# flex-basis percentage resolves against the main content size.
	r = _layout(
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="c"/><ui:VisualElement name="b" class="c"/>'
		+ '</ui:VisualElement>',
		'.row { flex-direction: row; width: 200px; } .c { flex-basis: 50%; height: 10px; }',
		Vector2(200, 100)
	)
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 100, 10), "basis 50% of 200")
	_vec_eq(_rect(r, "b"), Rect2(100, 0, 100, 10), "second basis 50%")


# ScrollView geometry: the viewport stays at the authored height while the
# content box reports the full scrollable size and children lay out inside
# it in content coordinates.
func test_scrollview_content_box() -> void:
	var r := _layout(
		'<ui:ScrollView name="sv" class="sv">'
		+ '<ui:VisualElement name="tall" class="tall"/>'
		+ '</ui:ScrollView>',
		'.sv { height: 150px; width: 200px; } .tall { height: 400px; }',
		Vector2(400, 300)
	)
	_vec_eq(_rect(r, "sv"), Rect2(0, 0, 200, 150), "viewport keeps authored 150")
	var tall = _rect(r, "tall")
	h.check(tall is Rect2 and tall.size.y >= 399.0, "content keeps its 400 height, got %s" % tall)
	var cs: Vector2 = r["content"].get(r["doc"].find_by_name("sv"), Vector2.ZERO)
	h.check(cs.y >= 400.0, "scroll content height %s >= 400" % cs)


# An explicit width/height is a preferred size, not the automatic minimum:
# empty elements shrink below it down to their content size (CSS
# min-main-size:auto = content size, not the declared dimension).
func test_explicit_dims_shrink() -> void:
	var r := _layout(
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="c"/><ui:VisualElement name="b" class="c"/>'
		+ '</ui:VisualElement>',
		'.row { flex-direction: row; width: 300px; } .c { width: 200px; height: 10px; }',
		Vector2(300, 100)
	)
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 150, 10), "empty explicit-200 shrinks to 150")
	_vec_eq(_rect(r, "b"), Rect2(150, 0, 150, 10), "second shrinks too")

	# Content is NOT a shrink floor in Yoga: a 200-wide item holding a
	# 160-wide child shrinks to 150 and the child overflows (verified
	# against installed yoga-layout 3.2.1).
	r = _layout(
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="c"><ui:VisualElement name="kid" class="k"/></ui:VisualElement>'
		+ '<ui:VisualElement name="b" class="c"/>'
		+ '</ui:VisualElement>',
		'.row { flex-direction: row; width: 300px; } .c { width: 200px; height: 10px; }'
		+ '.k { width: 160px; height: 10px; }',
		Vector2(300, 100)
	)
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 150, 10), "parent shrinks below its content")
	_vec_eq(_rect(r, "b"), Rect2(150, 0, 150, 10), "sibling shrinks evenly")
	_vec_eq(_rect(r, "kid"), Rect2(0, 0, 160, 10), "child keeps its size and overflows")

	# Column direction: explicit heights shrink the same way — no authored
	# min, matching yoga-layout 3.2.1 exactly (column 100x300, children
	# 10x150 at y0/150).
	r = _layout(
		'<ui:VisualElement name="col" class="col">'
		+ '<ui:VisualElement name="a" class="c"/><ui:VisualElement name="b" class="c"/>'
		+ '</ui:VisualElement>',
		'.col { height: 300px; } .c { height: 200px; width: 10px; }',
		Vector2(100, 300)
	)
	_vec_eq(_rect(r, "col"), Rect2(0, 0, 100, 300), "column keeps authored 300")
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 10, 150), "column: explicit height shrinks")
	_vec_eq(_rect(r, "b"), Rect2(0, 150, 10, 150), "second shrinks too")


# Stretch is a cross-axis assignment, not an override of min/max: a
# stretched item still clamps to its authored bounds on both axes.
func test_stretch_honors_min_max() -> void:
	var r := _layout(
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="a"/><ui:VisualElement name="b" class="b"/>'
		+ '</ui:VisualElement>',
		'.row { flex-direction: row; width: 200px; height: 100px; }'
		+ '.a { width: 50px; max-height: 30px; } .b { width: 50px; height: 60px; }',
		Vector2(200, 100)
	)
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 50, 30), "row stretch capped at max-height 30")
	_vec_eq(_rect(r, "b"), Rect2(50, 0, 50, 60), "explicit height unaffected")

	# A min taller than the line still wins over the stretch.
	r = _layout(
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="a"/>'
		+ '</ui:VisualElement>',
		'.row { flex-direction: row; width: 200px; height: 50px; }'
		+ '.a { width: 50px; min-height: 80px; }',
		Vector2(200, 50)
	)
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 50, 80), "min-height beats a shorter line")

	# Column direction: cross is width, same clamp applies.
	r = _layout(
		'<ui:VisualElement name="col" class="col">'
		+ '<ui:VisualElement name="a" class="a"/>'
		+ '</ui:VisualElement>',
		'.col { flex-direction: column; width: 100px; }'
		+ '.a { height: 20px; max-width: 40px; }',
		Vector2(100, 50)
	)
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 40, 20), "column stretch capped at max-width")


# The gap shorthand expands in the cascade, so declaration order with
# row-gap/column-gap decides the winner — the runtime never re-splits it.
func test_gap_shorthand_cascade_order() -> void:
	var body := (
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="c"/><ui:VisualElement name="b" class="c"/>'
		+ '</ui:VisualElement>'
	)
	var kids := '.c { width: 50px; height: 10px; }'

	# Later longhand beats the earlier shorthand.
	var r := _layout(
		body,
		'.row { flex-direction: row; width: 200px; gap: 10px; column-gap: 40px; }' + kids,
		Vector2(200, 50)
	)
	_vec_eq(_rect(r, "b"), Rect2(90, 0, 50, 10), "column-gap 40 beats earlier gap")

	# Later shorthand beats the earlier longhand.
	r = _layout(
		body,
		'.row { flex-direction: row; width: 200px; column-gap: 40px; gap: 10px; }' + kids,
		Vector2(200, 50)
	)
	_vec_eq(_rect(r, "b"), Rect2(60, 0, 50, 10), "later gap overrides column-gap")

	# Two-value gap: first is row-gap, second column-gap (main axis in a row).
	r = _layout(
		body,
		'.row { flex-direction: row; width: 200px; gap: 7px 25px; }' + kids,
		Vector2(200, 50)
	)
	_vec_eq(_rect(r, "b"), Rect2(75, 0, 50, 10), "gap second value is column-gap")


# Negative margins are supported (they pull the box backward and shrink
# the space siblings see); negative padding is invalid and diagnosed.
func test_negative_margins() -> void:
	var r := _layout(
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="c n"/><ui:VisualElement name="b" class="c"/>'
		+ '</ui:VisualElement>',
		'.row { flex-direction: row; width: 300px; }'
		+ '.c { width: 100px; height: 10px; } .n { margin-left: -20px; }',
		Vector2(300, 50)
	)
	_vec_eq(_rect(r, "a"), Rect2(-20, 0, 100, 10), "negative margin pulls left")
	_vec_eq(_rect(r, "b"), Rect2(80, 0, 100, 10), "sibling follows the pulled box")

	r = _layout(
		'<ui:VisualElement name="p" class="p"><ui:VisualElement name="c"/></ui:VisualElement>',
		'.p { padding-left: -15px; width: 100px; }',
		Vector2(100, 50)
	)
	h.check(_warn_kinds(r).has("unsupported-value"), "negative padding diagnosed")
	var c = _rect(r, "c")
	h.check(c is Rect2 and c.position.x < 0.01,
		"negative padding clamps to 0, got %s" % c)


# Value-level strictness the applier relies on: exact CSS named colors and
# no trailing garbage or mismatched quotes inside functional values.
func test_uss_value_strictness() -> void:
	var c := UssValues.parse_color("green")
	h.check(c["ok"], "green parses")
	h.check(absf(c["color"].g - 0.50196) < 0.002 and c["color"].r < 0.002,
		"CSS green is #008000, not #00ff00 (got %s)" % c["color"])
	h.check(absf(UssValues.parse_color("lime")["color"].g - 1.0) < 0.001,
		"lime keeps #00ff00")
	for bad in ["rgb(1,2,3) x", "rgba(1,2,3,0.5)junk"]:
		h.check(not UssValues.parse_color(bad)["ok"], "%s rejected" % bad)
	for bad in ["url(\"a.png')", "url(a.png) tail", "url()", "url(\"a.png\""]:
		h.check(not UssValues.parse_url(bad)["ok"], "%s rejected" % bad)
	h.check(UssValues.parse_url("url(\"a.png\")")["ok"], "quoted url ok")
	h.check(UssValues.parse_url("url(a.png)")["ok"], "bare url ok")


# Diagnostics: bad units and unsupported values are reported once, never
# silently applied.
func test_value_diagnostics() -> void:
	var r := _layout(
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="c"><ui:VisualElement name="a2"/></ui:VisualElement>'
		+ '</ui:VisualElement>',
		'.row { flex-direction: row; width: 100px; }'
		+ '.c { width: 10em; padding-left: auto; flex-direction: diagonal; height: 5px; }',
		Vector2(100, 100)
	)
	var kinds := _warn_kinds(r)
	h.check(kinds.count("unsupported-value") >= 3,
		"em/auto-padding/bad-direction diagnosed once each, got %s" % [kinds])
	# The em width fell back (auto -> intrinsic 0) rather than becoming 10px.
	var a = _rect(r, "a")
	h.check(a is Rect2 and a.size.x < 1.0, "em width not treated as px: %s" % a)


# gap takes 1 or 2 values; 3+ is invalid at parse time — the declaration
# drops with a diagnostic instead of truncating to a valid pair, and an
# earlier valid declaration still wins.
func test_gap_shorthand_arity() -> void:
	var body := (
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="c"/><ui:VisualElement name="b" class="c"/>'
		+ '</ui:VisualElement>'
	)
	var kids := '.c { width: 10px; height: 10px; }'

	var r := _layout(
		body,
		'.row { flex-direction: row; width: 100px; gap: 5px; gap: 1px 2px 3px; }' + kids,
		Vector2(100, 20)
	)
	h.check(_warn_kinds(r).has("invalid-shorthand"),
		"3-token gap explicitly diagnosed (kinds %s)" % [_warn_kinds(r)])
	_vec_eq(_rect(r, "b"), Rect2(15, 0, 10, 10),
		"invalid gap does not truncate; earlier valid 5px wins")

	r = _layout(
		body,
		'.row { flex-direction: row; width: 100px; gap: 3px 7px; }' + kids,
		Vector2(100, 20)
	)
	h.check(not _warn_kinds(r).has("invalid-shorthand"), "2-token gap is valid")
	_vec_eq(_rect(r, "b"), Rect2(17, 0, 10, 10), "2-token gap: column-gap 7")


# A flex item's CONTENT may shrink to 0, but its border box never shrinks
# below the resolved padding+border total on that axis — verified against
# installed yoga-layout 3.2.1 (row 20x50, w80/shrink1 child with 12+12
# padding and 2+2 border -> 28 wide, not 20). The floor also beats
# explicit dims and max bounds, and applies on the cross axis.
func test_padding_border_floor() -> void:
	var r := _layout(
		'<ui:VisualElement name="row" class="row"><ui:VisualElement name="a" class="c"/></ui:VisualElement>',
		'.row { flex-direction: row; width: 20px; height: 50px; }'
		+ '.c { width: 80px; padding-left: 12px; padding-right: 12px;'
		+ ' border-left-width: 2px; border-right-width: 2px; }',
		Vector2(20, 50)
	)
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 28, 50), "shrink stops at pad+border floor 28")

	r = _layout(
		'<ui:VisualElement name="col" class="col"><ui:VisualElement name="a" class="c"/></ui:VisualElement>',
		'.col { width: 50px; height: 20px; }'
		+ '.c { height: 80px; padding-top: 12px; padding-bottom: 12px;'
		+ ' border-top-width: 2px; border-bottom-width: 2px; }',
		Vector2(50, 20)
	)
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 50, 28), "column: height floors at 28")

	r = _layout(
		'<ui:VisualElement name="row" class="row"><ui:VisualElement name="a" class="c"/></ui:VisualElement>',
		'.row { flex-direction: row; width: 200px; height: 50px; }'
		+ '.c { width: 10px; padding-left: 12px; padding-right: 12px;'
		+ ' border-left-width: 2px; border-right-width: 2px; }',
		Vector2(200, 50)
	)
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 28, 50), "explicit width 10 floored to 28")

	r = _layout(
		'<ui:VisualElement name="row" class="row"><ui:VisualElement name="a" class="c"/></ui:VisualElement>',
		'.row { flex-direction: row; width: 200px; height: 50px; }'
		+ '.c { width: 80px; max-width: 10px; padding-left: 12px; padding-right: 12px;'
		+ ' border-left-width: 2px; border-right-width: 2px; }',
		Vector2(200, 50)
	)
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 28, 50), "max-width 10 raised to floor 28")

	r = _layout(
		'<ui:VisualElement name="row" class="row"><ui:VisualElement name="a" class="c"/></ui:VisualElement>',
		'.row { flex-direction: row; width: 200px; height: 50px; }'
		+ '.c { width: 10px; height: 10px; padding-top: 12px; padding-bottom: 12px;'
		+ ' border-top-width: 2px; border-bottom-width: 2px; }',
		Vector2(200, 50)
	)
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 10, 28), "cross: explicit height 10 floored to 28")


# margin: auto (Yoga): auto margins take a line's free main-axis space
# before justify-content, and center or push an item on the cross axis
# (no stretch when a cross margin is auto).
func test_auto_margins() -> void:
	var r := _layout(
		'<ui:VisualElement name="row" class="row">'
		+ '<ui:VisualElement name="a" class="c"/>'
		+ '<ui:VisualElement name="b" class="c push"/>'
		+ '</ui:VisualElement>'
		+ '<ui:VisualElement name="col" class="col">'
		+ '<ui:VisualElement name="m" class="mid"/>'
		+ '<ui:VisualElement name="e" class="end"/>'
		+ '</ui:VisualElement>',
		'.row { flex-direction: row; width: 300px; height: 50px; justify-content: center; }'
		+ '.c { width: 50px; height: 20px; }'
		+ '.push { margin-left: auto; }'
		+ '.col { width: 300px; height: 200px; }'
		+ '.mid { width: 100px; height: 40px; margin: 0 auto; }'
		+ '.end { height: 40px; width: 60px; margin-left: auto; margin-top: auto; }',
		Vector2(300, 400)
	)
	_vec_eq(_rect(r, "a"), Rect2(0, 0, 50, 20), "justify ignored: a at start")
	_vec_eq(_rect(r, "b"), Rect2(250, 0, 50, 20), "auto margin-left pushes b to the end")
	_vec_eq(_rect(r, "m"), Rect2(100, 0, 100, 40), "auto side margins center on the cross axis")
	_vec_eq(_rect(r, "e"), Rect2(240, 160, 60, 40), "auto top takes the free main space; auto left pushes across")
	h.check(not _warn_kinds(r).has("unsupported-value"), "margin auto is not diagnosed: %s" % [_warn_kinds(r)])
