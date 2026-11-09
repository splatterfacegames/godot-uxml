extends RefCounted
## Panel scaling (Unity's PanelSettings): the scale formulas against Unity's
## own results (bench/parity/probes/panel-scale.json, written by
## tools/unity-dump/run.py --scale-probe from Unity 6000.3), the GDScript
## and native layers against each other, the PanelSettings asset importer
## on files Unity wrote (tests/fixtures/panel_settings/), the `.tss` theme,
## the layout on the pixel grid of a scaled panel, and the runtime's
## points/pixels contract (element_at, get_element_rect, the root box).

const PROBE := "res://bench/parity/probes/panel-scale.json"
const FIXTURES := "res://tests/fixtures/panel_settings"

var h = null


func _init(harness) -> void:
	h = harness


static func settings_of(u: Dictionary) -> Dictionary:
	return UxmlPanelScale.settings_from_unity(u)


func test_resolve_matches_unity_on_every_probe_row() -> void:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PROBE))
	var rows: Array = data["rows"]
	h.check(rows.size() >= 1000, "the probe has its rows (%d)" % rows.size())
	var bad := 0
	var first := ""
	for r in rows:
		var scr: Array = r["screen"]
		var got := UxmlPanelScale.resolve(settings_of(r["settings"]), Vector2(scr[0], scr[1]), float(r["screenDpi"]))
		var ps: Vector2 = got["panel_size"]
		# The dump has each float as its exact double; Godot's JSON parser
		# may be one double ulp off, so both sides compare as floats.
		var F := UxmlPanelScale.f32
		var ok: bool = (F.call(float(got["resolved_scale"])) == F.call(float(r["resolvedScale"]))
			and F.call(float(got["pixels_per_point"])) == F.call(float(r["pixelsPerPoint"]))
			and F.call(ps.x) == F.call(float(r["root"]["width"])) and F.call(ps.y) == F.call(float(r["root"]["height"])))
		if not ok:
			bad += 1
			if first.is_empty():
				first = "%s on %s: ours %s, Unity %s %s %s" % [r["settings"], scr, got, r["resolvedScale"], r["pixelsPerPoint"], r["root"]]
	h.eq(bad, 0, "every probe row resolves as Unity does, to the bit (%s)" % first)


func test_native_resolve_equals_gdscript() -> void:
	if not ClassDB.class_exists("UxmlNative"):
		return
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PROBE))
	var bad := 0
	for r in data["rows"]:
		var scr: Array = r["screen"]
		var st := settings_of(r["settings"])
		var a := UxmlPanelScale.resolve(st, Vector2(scr[0], scr[1]), float(r["screenDpi"]))
		var b: Dictionary = ClassDB.class_call_static("UxmlNative", "panel_scale", st, Vector2(scr[0], scr[1]), float(r["screenDpi"]))
		if float(a["pixels_per_point"]) != float(b["pixels_per_point"]) or float(a["resolved_scale"]) != float(b["resolved_scale"]) \
				or a["panel_size"] != b["panel_size"]:
			bad += 1
	h.eq(bad, 0, "the native panel_scale equals UxmlPanelScale on every probe row")
	var vals := [0.0, 0.4, 0.5, 2.5, 2.6, -1.3, 399.9, 1000.37, 0.75]
	var ppps := [1.0, 2.0, 0.6666666865348816, 1.3333333730697632, 1.7777777910232544, 0.5625]
	var diff := 0
	for v in vals:
		for p in ppps:
			for border in [false, true]:
				var x := UxmlPanelScale.grid_box(v, border, p)
				var y: float = ClassDB.class_call_static("UxmlNative", "panel_grid_box", v, border, p)
				if x != y:
					diff += 1
			if UxmlPanelScale.pixel(v, p) != float(ClassDB.class_call_static("UxmlNative", "panel_pixel", v, p)):
				diff += 1
	h.eq(diff, 0, "pixel() and grid_box() are the same in both cores")


func test_formulas() -> void:
	var sws := {"scale_mode": 2, "reference_resolution": Vector2i(1920, 1080), "screen_match_mode": 0, "match": 0.5}
	var r := UxmlPanelScale.resolve(sws, Vector2(2560, 1440), 96.0)
	h.eq(r["panel_size"], Vector2(1920, 1080), "2560x1440 at reference 1920x1080 is a 1920x1080 panel")
	h.check(absf(float(r["pixels_per_point"]) - 4.0 / 3.0) < 1e-6, "at 1.33 pixels per point")
	# MatchWidthOrHeight is a linear blend of the two ratios (Mathf.Lerp),
	# not uGUI's logarithmic one: 1080x1920 at match 0.5 is 1.1701, not 1.
	r = UxmlPanelScale.resolve(sws, Vector2(1080, 1920), 96.0)
	h.check(absf(float(r["pixels_per_point"]) - (0.5625 + 1.7777778) / 2.0) < 1e-5, "a portrait screen blends the ratios linearly")
	var expand := sws.duplicate()
	expand["screen_match_mode"] = 2
	h.check(absf(float(UxmlPanelScale.resolve(expand, Vector2(1080, 1920), 96.0)["pixels_per_point"]) - 0.5625) < 1e-6, "Expand takes the smaller ratio")
	var shrink := sws.duplicate()
	shrink["screen_match_mode"] = 1
	h.check(absf(float(UxmlPanelScale.resolve(shrink, Vector2(1080, 1920), 96.0)["pixels_per_point"]) - 1.7777778) < 1e-6, "Shrink takes the larger ratio")
	var phys := {"scale_mode": 1, "reference_dpi": 96.0, "fallback_dpi": 144.0}
	h.eq(float(UxmlPanelScale.resolve(phys, Vector2(800, 600), 192.0)["pixels_per_point"]), 2.0, "constant physical size: the screen DPI over the reference DPI")
	h.eq(float(UxmlPanelScale.resolve(phys, Vector2(800, 600), 0.0)["pixels_per_point"]), 1.5, "an unknown DPI uses the fallback DPI")
	var px := {"scale_mode": 0, "scale": 2.0}
	r = UxmlPanelScale.resolve(px, Vector2(800, 600), 96.0)
	h.eq(r["panel_size"], Vector2(400, 300), "constant pixel size at scale 2 halves the panel")
	h.eq(float(UxmlPanelScale.resolve({"scale_mode": 0, "scale": 0.0}, Vector2(800, 600), 96.0)["resolved_scale"]), 0.0, "a scale of 0 resolves to 0 (Unity draws nothing)")
	h.eq(UxmlPanelScale.grid_box(0.4, true, 4.0 / 3.0), 0.75, "a 0.4pt border is one pixel at 1.33 pixels per point")
	h.eq(UxmlPanelScale.grid_box(2.5, false, 2.0), 2.5, "2.5pt is on the grid at 2 pixels per point")
	h.eq(UxmlPanelScale.pixel(400.0, 4.0 / 3.0), 399.75, "400pt is 533 pixels at 1.33 pixels per point")


func test_unity_asset_import() -> void:
	var ps := UxmlPanelSettings.load_unity_asset(FIXTURES + "/ScaledPanel.asset")
	h.check(ps != null, "a PanelSettings asset that Unity wrote is read")
	if ps == null:
		return
	h.eq(ps.scale_mode, UxmlPanelSettings.ScaleMode.SCALE_WITH_SCREEN_SIZE, "m_ScaleMode 2")
	h.eq(ps.reference_resolution, Vector2i(1920, 1080), "m_ReferenceResolution")
	h.eq(ps.match_width_or_height, 0.5, "m_Match")
	h.eq(ps.theme_style_sheet, FIXTURES + "/ScaledPanel.tss", "themeUss found by the GUID of the .tss.meta beside it")
	h.eq(ps.import_warnings.size(), 0, "no import warnings")
	var ex := UxmlPanelSettings.load_unity_asset(FIXTURES + "/ExpandPanel.asset")
	h.eq(ex.screen_match_mode, UxmlPanelSettings.ScreenMatchMode.EXPAND, "m_ScreenMatchMode 2 is Expand")
	h.eq(ex.reference_resolution, Vector2i(1280, 720), "Expand's reference resolution")
	# Unity gives a PanelSettings made without a theme the project's first
	# theme style sheet (here ScaledPanel.tss), and writes it to the asset.
	h.eq(ex.theme_style_sheet, FIXTURES + "/ScaledPanel.tss", "the theme Unity wrote")
	var phys := UxmlPanelSettings.load_unity_asset(FIXTURES + "/PhysicalPanel.asset")
	h.eq(phys.scale_mode, UxmlPanelSettings.ScaleMode.CONSTANT_PHYSICAL_SIZE, "m_ScaleMode 1")
	h.eq(phys.reference_dpi, 144.0, "m_ReferenceDpi")
	h.eq(phys.fallback_dpi, 120.0, "m_FallbackDpi")
	var pix := UxmlPanelSettings.load_unity_asset(FIXTURES + "/PixelPanel.asset")
	h.eq(pix.scale_mode, UxmlPanelSettings.ScaleMode.CONSTANT_PIXEL_SIZE, "m_ScaleMode 0")
	h.eq(pix.scale, 2.0, "m_Scale")
	h.check(UxmlPanelSettings.load_unity_asset(FIXTURES + "/ScaledPanel.tss") == null, "a file that is not a PanelSettings asset is null")
	var missing := UxmlPanelSettings.from_unity_yaml(FileAccess.get_file_as_string(FIXTURES + "/ScaledPanel.asset").replace(
		"0715698b6a5f3c948981e5db3c7a7027", "ffffffffffffffffffffffffffffffff"), FIXTURES + "/ScaledPanel.asset", FIXTURES)
	h.eq(missing.import_warnings.size(), 1, "a theme GUID that no .meta has is a warning")


func test_tss_theme() -> void:
	var t := UxmlTheme.tss_parts(FIXTURES + "/ScaledPanel.tss")
	h.check(bool(t[0]), "the .tss imports unity-theme://default")
	h.eq(t[1], [FIXTURES + "/ScaledPanel.tss"], "its own rules are a theme sheet after the default theme")
	var doc: UxmlDocumentModel = h._doc('<ui:Label name="l" text="x" />')
	UxmlTheme.attach(doc, FIXTURES + "/ScaledPanel.tss")
	h.check(UxmlTheme.uses_default(doc), "the document has the default theme")
	var st: Dictionary = UssStyleResolver.resolve(doc, {})["styles"]
	var l: UxmlElement = doc.root.find_by_name("l")
	h.eq(String(st[l]["color"]["value"]), "rgb(255, 0, 0)", "the .tss rule styles the Label over the default theme")
	h.eq(String(st[l]["margin-left"]["value"]), "2px", "the default theme still styles it")


func _laid(uss: String, ppp: float) -> Dictionary:
	var doc: UxmlDocumentModel = h._doc('<ui:VisualElement name="row" class="row"><ui:VisualElement name="a" class="b" /><ui:VisualElement name="m" class="b" /><ui:VisualElement name="bo" class="b"><ui:VisualElement name="in" /></ui:VisualElement></ui:VisualElement>', uss)
	var st: Dictionary = UssStyleResolver.resolve(doc, {})["styles"]
	var res := UxmlFlexLayout.compute(doc.root, st, Vector2(400, 300), func(_e, _s, _h): return Vector2.ZERO, [],
		{"pixel_grid": true, "pixels_per_point": ppp})
	var out := {}
	for el in doc.root.walk():
		var n = el.get_attribute("name")
		if n != null:
			out[String(n)] = res["rects"].get(el)
	return out


func test_layout_on_the_scaled_pixel_grid() -> void:
	var uss := ".row { flex-direction: row; } .b { width: 20px; height: 20px; } #m { margin-left: 0.4px; } #bo { border-left-width: 0.4px; }"
	var one := _laid(uss, 1.0)
	h.eq(one["a"], Rect2(0, 0, 20, 20), "at 1 pixel per point: whole points")
	h.eq(one["m"].position.x, 20.0, "a 0.4px margin is 0 at 1 pixel per point")
	var r := _laid(uss, 4.0 / 3.0)
	# 400pt = 533.3px -> 533px = 399.75pt; 20pt = 26.7px -> 27px = 20.25pt
	# (measured in Unity, lay-fraction at 2560x1440).
	h.eq(r["row"].size.x, 399.75, "the row is 533 pixels wide")
	h.eq(r["a"].size.x, 20.25, "a 20pt box is 27 pixels wide")
	h.eq(r["m"].position.x, 21.0, "a 0.4pt margin is one pixel (0.75pt) after a box that ends at 20.25pt")
	h.eq(r["in"].position.x, 0.75, "a 0.4pt border is one pixel")


func _scaled_doc(ps: UxmlPanelSettings, host: Vector2) -> UxmlDocument:
	var doc := UxmlDocument.new()
	doc.theme_path = ""
	doc.panel_settings = ps
	h.root.add_child(doc)
	doc.size = host
	doc.load_source('<ui:UXML xmlns:ui="UnityEngine.UIElements"><ui:VisualElement name="box" style="position: absolute; left: 100px; top: 50px; width: 200px; height: 100px; background-color: red;"><ui:Label name="t" text="Hello" style="font-size: 20px;" /></ui:VisualElement></ui:UXML>')
	return doc


func test_runtime_points_and_pixels() -> void:
	var ps := UxmlPanelSettings.new()
	ps.scale_mode = UxmlPanelSettings.ScaleMode.SCALE_WITH_SCREEN_SIZE
	ps.reference_resolution = Vector2i(960, 540)
	ps.match_width_or_height = 0.5
	var doc := _scaled_doc(ps, Vector2(1920, 1080))
	h.eq(doc.get_pixels_per_point(), 2.0, "1920x1080 at reference 960x540: 2 pixels per point")
	h.eq(doc.get_panel_size(), Vector2(960, 540), "the panel is 960x540 points")
	var box := doc.get_element_model("box")
	var root := doc.get_document_model().root
	h.eq(doc.get_element_rect(box, root), Rect2(100, 50, 200, 100), "in the root's space: panel points (Unity's worldBound)")
	h.eq(doc.get_element_rect(box), Rect2(200, 100, 400, 200), "in the document's space: pixels of the document Control")
	h.eq(doc.element_at(Vector2(500, 280)), box, "element_at takes document pixels")
	h.eq(doc.element_at(Vector2(150, 75)), null, "(150, 75) pixels is outside the box at (200, 100)")
	h.eq(doc.panel_to_document(Vector2(100, 50)), Vector2(200, 100), "panel_to_document")
	h.eq(doc.document_to_panel(Vector2(200, 100)), Vector2(100, 50), "document_to_panel")
	var c := doc.get_element("box")
	h.eq(c.size, Vector2(200, 100), "controls are sized in points")
	h.eq(c.get_global_rect().size, Vector2(400, 200), "and drawn at the scale")
	# A resize resolves the scale again.
	doc.size = Vector2(960, 540)
	h.eq(doc.get_pixels_per_point(), 1.0, "960x540: 1 pixel per point")
	h.eq(doc.get_element_rect(box), Rect2(100, 50, 200, 100), "the box is 200x100 pixels")
	# Changing the settings resource relays out.
	ps.scale_mode = UxmlPanelSettings.ScaleMode.CONSTANT_PIXEL_SIZE
	ps.scale = 1.5
	doc._restyle_now()
	h.eq(doc.get_pixels_per_point(), 1.5, "a settings change applies")
	h.eq(doc.get_element_rect(box), Rect2(150, 75, 300, 150), "the box at 1.5")
	doc.panel_settings = null
	doc._restyle_now()
	h.eq(doc.get_pixels_per_point(), 1.0, "no settings: 1 pixel per point")
	h.eq(doc.get_panel_size(), doc.size, "and the panel is the document's size")
	h.root.remove_child(doc)
	doc.queue_free()


func test_runtime_constant_physical_size_dpi() -> void:
	var ps := UxmlPanelSettings.new()
	ps.scale_mode = UxmlPanelSettings.ScaleMode.CONSTANT_PHYSICAL_SIZE
	ps.reference_dpi = 96.0
	var doc := _scaled_doc(ps, Vector2(800, 600))
	doc.screen_dpi = 144.0
	doc._restyle_now()
	h.eq(doc.get_pixels_per_point(), 1.5, "a 144 dpi screen at reference 96: 1.5 pixels per point")
	h.root.remove_child(doc)
	doc.queue_free()


func test_runtime_asset_property() -> void:
	var doc := UxmlDocument.new()
	doc.theme_path = ""
	doc.panel_settings_asset = FIXTURES + "/PixelPanel.asset"
	h.root.add_child(doc)
	doc.size = Vector2(800, 600)
	doc.load_source('<ui:UXML xmlns:ui="UnityEngine.UIElements"><ui:VisualElement name="v" style="width: 100%; height: 100%;" /></ui:UXML>')
	h.eq(doc.get_pixels_per_point(), 2.0, "panel_settings_asset loads the asset (scale 2)")
	h.eq(doc.get_element("v").size, Vector2(400, 300), "the panel is 400x300 points")
	h.root.remove_child(doc)
	doc.queue_free()


func test_dropdown_menu_at_the_panel_scale() -> void:
	var ps := UxmlPanelSettings.new()
	ps.scale_mode = UxmlPanelSettings.ScaleMode.CONSTANT_PIXEL_SIZE
	ps.scale = 2.0
	var doc := UxmlDocument.new()
	doc.panel_settings = ps
	h.root.add_child(doc)
	doc.size = Vector2(800, 600)
	doc.load_source('<ui:UXML xmlns:ui="UnityEngine.UIElements"><ui:DropdownField name="dd" choices="One,Two,Three" index="0" style="width: 200px;" /></ui:UXML>')
	var el := doc.get_element_model("dd")
	var b = doc._behaviors.get(el)
	h.check(b != null and b.has_method("open_menu"), "the dropdown has its behavior")
	if b == null:
		return
	b.open_menu()
	var menus := doc.find_children("*", "UxmlPopupMenu", true, false)
	h.eq(menus.size(), 1, "the menu opened")
	if menus.size() == 1:
		var m: UxmlPopupMenu = menus[0]
		h.eq(m.document().get_pixels_per_point(), 2.0, "the menu draws at the panel's scale")
		# A 200pt field (196pt input): the menu document is 396 pixels wide
		# ((196 + 2) points at 2), its panel 198 points.
		h.eq(m.document().size.x, 396.0, "the menu is sized in pixels")
		h.eq(m.document().get_panel_size().x, 198.0, "its panel is in points")
		m.hide()
	h.root.remove_child(doc)
	doc.queue_free()
