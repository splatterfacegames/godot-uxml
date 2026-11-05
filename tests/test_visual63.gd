extends RefCounted
## Unity 6.3 visual features: filter (built-in and custom functions,
## chains, transitions, nesting), -unity-material, -unity-text-auto-size,
## blurred text-shadow, resource() lookup and template inline style URLs.
##
## Expected filter colors are Unity 6000.3.24f1 pixels (gamma color space,
## 8-bit), read back from a runtime panel rendered in batch mode: a
## 40x40 element with background rgb(200, 100, 50) ("opaque") or
## rgba(200, 100, 50, 0.5) ("half"), as premultiplied 0..255 values.

var h = null
const ROOT := "user://v63"


func _init(harness) -> void:
	h = harness


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _png(path: String, color: Color, size := 4) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(color)
	img.save_png(path)


func _doc(root: String, uxml: String, size := Vector2(400, 300), native := true, theme := true) -> UxmlDocument:
	UssCascade.use_native = native
	var doc := UxmlDocument.new()
	doc.transitions_manual = true
	if not theme:
		doc.theme_path = ""  # geometry pinned to authored USS only
	h.root.add_child(doc)
	doc.size = size
	doc.load_document(uxml, root)
	UssCascade.use_native = true
	return doc


func _unload(doc: UxmlDocument) -> void:
	h.root.remove_child(doc)
	doc.free()


func _messages(doc: UxmlDocument) -> String:
	var out := []
	for d in doc.diagnostics:
		out.append(String(d["message"]))
	return "\n".join(out)


## A one-sheet document under ROOT/<name>.
func _setup(name: String, uxml_body: String, uss: String) -> String:
	var dir := ROOT + "/" + name
	_write(dir + "/Assets/UI/main.uxml",
		'<ui:UXML xmlns:ui="UnityEngine.UIElements"><Style src="main.uss" />%s</ui:UXML>' % uxml_body)
	_write(dir + "/Assets/UI/main.uss", uss)
	return dir


# ---------------------------------------------------------------------------
# filter values
# ---------------------------------------------------------------------------

func test_filter_parse() -> void:
	var r := UssValues.parse_filter("blur(3px) grayscale(50%) hue-rotate(90deg) tint(#00ff99)")
	h.check(r["ok"], "built-in chain parses")
	var f: Array = r["funcs"]
	h.eq(f.size(), 4, "four functions")
	h.eq(f[0]["params"][0], 3.0, "blur length in px")
	h.eq(f[1]["params"][0], 0.5, "percent / 100")
	h.check(absf(f[2]["params"][0] - PI / 2.0) < 1e-6, "deg -> rad")
	h.check(f[3]["params"][0] is Color, "tint color")
	h.eq(UssValues.parse_filter("hue-rotate(1)")["funcs"][0]["params"][0], 1.0, "bare angle is radians (Unity)")
	h.eq(UssValues.parse_filter("hue-rotate(0.5turn)")["funcs"][0]["params"][0], PI, "turn")
	h.check(not UssValues.parse_filter("grayscale()")["ok"], "an empty argument list is an import error in Unity")
	h.check(not UssValues.parse_filter("drop-shadow(1px 1px red)")["ok"], "drop-shadow is not USS")
	h.check(UssValues.parse_filter("none")["funcs"].is_empty(), "none")
	var c := UssValues.parse_filter('filter(url("Filters/Swirl.asset") 10px, red)')
	h.check(c["ok"], "custom filter parses")
	h.eq(c["funcs"][0]["ref"], 'url("Filters/Swirl.asset")', "definition reference")
	h.eq(c["funcs"][0]["params"].size(), 2, "custom parameters (comma tolerated)")
	h.eq(UssValues.parse_filter('filter("/Assets/F.asset" 1)')["funcs"][0]["ref"], "/Assets/F.asset", "quoted path")
	var m := UssValues.parse_filter("blur(1px 2px)")
	h.check(m["ok"] and not m["problems"].is_empty(), "extra parameter diagnosed, value kept")


## One filter pass on a premultiplied 0..255 color, then Unity's composite
## (rgb clamped to alpha).
func _run(chain: Array, c: Array) -> Array:
	var col := Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0, c[3] / 255.0)
	for fn in chain:
		col = UxmlFilter.apply_color_effect(UxmlFilter.color_effect(fn[0], fn[1]), col)
	col = Color(minf(col.r, col.a), minf(col.g, col.a), minf(col.b, col.a), col.a)
	return [col.r * 255.0, col.g * 255.0, col.b * 255.0, col.a * 255.0]


func _near(got: Array, want: Array, tol: float) -> bool:
	for k in 4:
		if absf(got[k] - want[k]) > tol:
			return false
	return true


func test_filter_math_matches_unity() -> void:
	var opaque := [200, 100, 50, 255]
	var half := [100, 50, 25, 128]
	var cases := [
		[[["invert", 1.0]], opaque, [55, 155, 205, 255]],
		[[["invert", 1.0]], half, [128, 128, 128, 128]],
		[[["invert", 0.5]], opaque, [127, 127, 127, 255]],
		[[["contrast", 0.5]], opaque, [164, 114, 89, 255]],
		[[["contrast", 0.5]], half, [114, 89, 76, 128]],
		[[["contrast", 2.0]], opaque, [255, 72, 0, 255]],
		[[["contrast", 2.0]], half, [72, 0, 0, 128]],
		[[["grayscale", 1.0]], opaque, [118, 118, 118, 255]],
		[[["grayscale", 1.0]], half, [59, 59, 59, 128]],
		[[["sepia", 1.0]], opaque, [165, 147, 114, 255]],
		[[["sepia", 1.0]], half, [82, 73, 57, 128]],
		[[["hue-rotate", PI / 2.0]], opaque, [50, 146, 35, 255]],
		[[["hue-rotate", PI / 2.0]], half, [25, 73, 18, 128]],
		[[["hue-rotate", 1.0]], opaque, [105, 132, 12, 255]],
		[[["tint", Color(0, 1, 0.6)]], opaque, [0, 100, 30, 255]],
		[[["tint", Color(1, 1, 1, 0.5)]], opaque, [100, 50, 25, 127]],
		[[["opacity", 0.5]], opaque, [100, 50, 25, 127]],
		[[["opacity", 0.5]], half, [50, 25, 12, 64]],
		[[["grayscale", 1.0], ["invert", 1.0]], opaque, [137, 137, 137, 255]],
		[[["grayscale", 1.0], ["invert", 1.0]], half, [128, 128, 128, 128]],
		[[["invert", 1.0], ["opacity", 0.5]], opaque, [27, 77, 102, 127]],
		[[["invert", 1.0], ["opacity", 0.5]], half, [64, 64, 64, 64]],
		[[["invert", 1.0], ["invert", 1.0]], opaque, [200, 100, 50, 255]],
	]
	for cs in cases:
		var got := _run(cs[0], cs[1])
		# Unity stores every pass in an 8-bit target: allow 1.5 steps.
		h.check(_near(got, cs[2], 1.5), "%s on %s -> %s (Unity %s)" % [cs[0], cs[1], got, cs[2]])
	# Transparent pixels stay transparent (Unity composites rgb / a).
	var clear := _run([["invert", 1.0]], [0, 0, 0, 0])
	h.check(_near(clear, [0, 0, 0, 0], 0.01), "invert keeps transparent pixels transparent")


## Unity's blur(3px) on a 10x10 white square at (30, 30): alpha along the
## row y = 35, x = 15..55 (horizontal pass, 8-bit store, vertical pass).
func test_blur_kernel_matches_unity() -> void:
	var unity := [0, 0, 0, 0, 0, 0, 0, 1, 4, 7, 15, 28, 46, 70, 100, 130, 159, 182, 199, 207, 207,
		199, 182, 159, 130, 100, 70, 46, 28, 15, 7, 4, 1, 0, 0, 0, 0, 0, 0, 0, 0]
	var sigma := 3.0
	var k := int(UxmlFilter.blur_margin(sigma))
	h.eq(k, 10, "kernel radius ceil(3 sigma + 1)")
	var w := PackedFloat64Array()
	var wsum := 0.0
	for o in range(-k, k + 1):
		var x := exp(-0.5 * pow(float(o) / sigma, 2.0))
		w.append(x)
		wsum += x
	var cover := func(p: int) -> float:
		var s := 0.0
		for o in range(-k, k + 1):
			if p + o >= 30 and p + o <= 39:
				s += w[o + k]
		return s / wsum
	var v: float = cover.call(35)
	var worst := 0.0
	for x in range(15, 56):
		var a: float = cover.call(x) * v * 255.0
		worst = maxf(worst, absf(a - unity[x - 15]))
	h.check(worst <= 2.0, "separable Gaussian matches Unity within 2/255 (worst %.2f)" % worst)


# ---------------------------------------------------------------------------
# filter runtime
# ---------------------------------------------------------------------------

func test_filter_runtime() -> void:
	var dir := _setup("filter", '<ui:VisualElement name="a" class="box f"><ui:VisualElement name="b" class="box g" /></ui:VisualElement>'
		+ '<ui:VisualElement name="p" class="box"><ui:Label name="kid" text="x" /></ui:VisualElement>',
		'.box { width: 50px; height: 50px; background-color: red; }\n'
		+ '.f { filter: grayscale(100%) blur(2px) invert(1); }\n'
		+ '.g { filter: sepia(1); }\n'
		+ '.none { filter: none; }\n'
		+ '.big { filter: blur(20px); }\n')
	var doc := _doc(dir, "Assets/UI/main.uxml")
	await h.process_frame
	var a := doc.get_element("a")
	h.check(a.has_meta(&"uxml_filter"), "filtered element gets a canvas group")
	var f: UxmlFilter = a.get_meta(&"uxml_filter")
	var mat := f.get_material() as ShaderMaterial
	h.check(mat != null and mat.shader == UxmlFilter.shader(), "built-in filter shader")
	h.eq(mat.get_shader_parameter("op_count"), 2, "two color passes")
	h.eq(mat.get_shader_parameter("pre_count"), 1, "grayscale runs before the blur")
	h.check(absf(float(mat.get_shader_parameter("sigma")) - 2.0) < 0.01, "blur sigma")
	h.eq(mat.get_shader_parameter("tap_step"), 1.0, "a small blur samples every pixel")
	var msgs := _messages(doc)
	h.check(msgs.contains("does not nest canvas groups"), "nested filter diagnosed")
	var b := doc.get_element("b")
	h.check(not (b.get_meta(&"uxml_filter") as UxmlFilter).enabled, "the inner filter is off")
	h.check(not doc.get_element("p").has_meta(&"uxml_filter"), "an element without filter gets nothing")
	# A large blur samples a back-buffer mipmap.
	doc.set_class("a", "box big")
	await h.process_frame
	h.check(float(mat.get_shader_parameter("tap_step")) > 1.0, "a large blur steps through a mipmap")
	h.check((b.get_meta(&"uxml_filter") as UxmlFilter).enabled == false, "still nested")
	# filter: none removes the group and re-enables the inner filter.
	doc.set_class("a", "box none")
	await h.process_frame
	h.check(not a.has_meta(&"uxml_filter"), "filter: none removes the canvas group")
	h.check((b.get_meta(&"uxml_filter") as UxmlFilter).enabled, "the inner filter draws again")
	_unload(doc)


func test_filter_is_paint_only() -> void:
	var o := {"width": {"value": "10px", "origin": {}}, "filter": {"value": "none", "origin": {}}}
	var n := {"width": {"value": "10px", "origin": {}}, "filter": {"value": "blur(4px)", "origin": {}},
		"-unity-material": {"value": 'url("m.tres")', "origin": {}}}
	h.check(UxmlDocument._paint_only(o, n), "filter and -unity-material changes skip the layout")
	var t := {"width": {"value": "10px", "origin": {}}, "-unity-text-auto-size": {"value": "best-fit 1px 2px", "origin": {}}}
	h.check(not UxmlDocument._paint_only(o, t), "-unity-text-auto-size changes run the layout")


func test_custom_filter() -> void:
	var dir := _setup("custom", '<ui:VisualElement name="a" class="box f" /><ui:VisualElement name="m" class="box mixed" />',
		'.box { width: 20px; height: 20px; }\n'
		+ '.f { filter: filter(url("../Filters/Swirl.asset") 45deg 0.25); }\n'
		+ '.mixed { filter: filter(resource("Fx/Plain") 0.5) blur(2px); }\n')
	_write(dir + "/Assets/Filters/Swirl.gdshader",
		"shader_type canvas_item;\nuniform sampler2D screen_texture : hint_screen_texture;\nuniform float angle;\nuniform float radius;\n"
		+ "void fragment() { COLOR = textureLod(screen_texture, SCREEN_UV, 0.0); }\n")
	_write(dir + "/Assets/Filters/Swirl.tres",
		'[gd_resource type="Resource" script_class="UxmlFilterDefinition" load_steps=4 format=3]\n\n'
		+ '[ext_resource type="Script" path="res://addons/godot_uxml/runtime/uxml_filter_definition.gd" id="1"]\n'
		+ '[ext_resource type="Shader" path="%s/Assets/Filters/Swirl.gdshader" id="2"]\n\n' % dir
		+ '[sub_resource type="ShaderMaterial" id="m"]\nshader = ExtResource("2")\n\n'
		+ '[resource]\nscript = ExtResource("1")\nfilter_name = "swirl"\nmaterial = SubResource("m")\n'
		+ 'parameter_names = PackedStringArray("angle", "radius")\ninterpolation_defaults = [0.0, 0.5]\n'
		+ 'margins = Vector4(4, 4, 4, 4)\n')
	_write(dir + "/Assets/Resources/Fx/Plain.gdshader",
		"shader_type canvas_item;\nuniform sampler2D screen_texture : hint_screen_texture;\nuniform float amount;\n"
		+ "void fragment() { COLOR = textureLod(screen_texture, SCREEN_UV, 0.0) * amount; }\n")
	var doc := _doc(dir, "Assets/UI/main.uxml")
	await h.process_frame
	var f: UxmlFilter = doc.get_element("a").get_meta(&"uxml_filter")
	var mat := f.get_material() as ShaderMaterial
	h.check(mat != null and mat.shader != UxmlFilter.shader(), "custom definition material (%s)" % _messages(doc))
	if mat != null:
		h.check(absf(float(mat.get_shader_parameter("angle")) - PI / 4.0) < 1e-5, "parameter 0 bound by name")
		h.eq(mat.get_shader_parameter("radius"), 0.25, "parameter 1 bound by name")
	var g: UxmlFilter = doc.get_element("m").get_meta(&"uxml_filter")
	var gm := g.get_material() as ShaderMaterial
	h.check(gm != null and gm.get_shader_parameter("amount") == 0.5, "a plain shader from resource() binds uniforms in order")
	h.check(_messages(doc).contains("draws alone"), "custom function in a chain diagnosed")
	_unload(doc)


func test_filter_transition() -> void:
	var dir := _setup("ftr", '<ui:VisualElement name="a" class="t" /><ui:VisualElement name="b" class="t2" />',
		'.t { width: 10px; height: 10px; filter: blur(0px); transition: filter 1s linear; }\n'
		+ '.t.on { filter: blur(10px) invert(100%); }\n'
		+ '.t2 { width: 10px; height: 10px; filter: invert(0) blur(0px); transition: filter 1s linear; }\n'
		+ '.t2.on { filter: blur(10px) invert(1); }\n')
	var doc := _doc(dir, "Assets/UI/main.uxml")
	await h.process_frame
	doc.set_class("a", "t on")
	doc.set_class("b", "t2 on")
	doc._restyle_now()
	doc.advance_transitions(0.5)
	h.eq(doc.get_computed_style("a")["filter"]["value"], "blur(5) invert(0.5)",
		"blur and the padded invert interpolate (invert pads with 0)")
	h.eq(doc.get_computed_style("b")["filter"]["value"], "blur(10px) invert(1)",
		"mismatched function order applies at once")
	var f: UxmlFilter = doc.get_element("a").get_meta(&"uxml_filter")
	h.check(absf(float((f.get_material() as ShaderMaterial).get_shader_parameter("sigma")) - 5.0) < 0.01,
		"the animated value is painted")
	doc.advance_transitions(1.0)
	h.eq(doc.get_computed_style("a")["filter"]["value"], "blur(10px) invert(100%)", "end value as authored")
	_unload(doc)


func test_transition_values() -> void:
	var t := UssTransitions.new(null)
	var an := {"kind": UssTransitions.K_FILTER, "eased": 1.5,
		"a": [[["opacity", "", [0.2]]]], "b": [[["opacity", "", [0.6]], ["tint", "", [Color(0, 0, 0, 1)]]]],
		"a_entry": null, "b_entry": null}
	t._lerp(an)
	h.eq(UssTransitions._filter_text(an["cur"]), "opacity(0.6) tint(rgba(0, 0, 0, 1))",
		"t clamps to 1 (Mathf.Lerp); tint pads from white")
	an["eased"] = 0.5
	t._lerp(an)
	h.eq(UssTransitions._filter_text(an["cur"]), "opacity(0.4) tint(rgba(127.5, 127.5, 127.5, 1))", "midpoint")
	var mt := {"kind": UssTransitions.K_MATERIAL, "eased": 0.5,
		"a": ['url("m.tres")', [["_A", "float", 0.0]]],
		"b": ['url("m.tres")', [["_A", "float", 1.0], ["_C", "color", Color(1, 0, 0, 1)]]],
		"a_entry": null, "b_entry": null}
	t._lerp(mt)
	h.eq(UssTransitions._material_text(mt["cur"]), 'url("m.tres") prop("_A" 0.5) prop("_C" rgba(127.5, 0, 0, 0.5))',
		"material properties lerp; a missing one pads with zero")
	mt["eased"] = 0.9995
	t._lerp(mt)
	h.eq(mt["cur"], mt["b"], "above 0.999 the end value itself")
	h.check(t._converted(0, "-unity-material", UssTransitions.K_MATERIAL, ['url("a")', []], ['url("b")', []]) == null,
		"different materials do not interpolate")
	h.check(t._converted(0, "-unity-material", UssTransitions.K_MATERIAL, ["", []], ['url("b")', []]) != null,
		"from no material interpolates")


# ---------------------------------------------------------------------------
# -unity-material
# ---------------------------------------------------------------------------

func test_material() -> void:
	var dir := _setup("mat", '<ui:VisualElement name="a" class="box m"><ui:Label name="kid" text="x" /></ui:VisualElement>'
		+ '<ui:VisualElement name="b" class="box plain" />',
		'.box { width: 20px; height: 20px; }\n'
		+ '.m { -unity-material: url("../Materials/Glow.mat") prop("_Strength" 0.5) prop("_Tint" red) prop("_Offset" 1 2); }\n'
		+ '.plain { -unity-material: url("../Materials/Glow.mat"); }\n'
		+ '.off { -unity-material: none; }\n')
	_write(dir + "/Assets/Materials/Glow.gdshader",
		"shader_type canvas_item;\nuniform float strength = 1.0;\nuniform vec4 tint : source_color;\nuniform vec2 offset;\n"
		+ "void fragment() { COLOR *= tint * strength; }\n")
	_write(dir + "/Assets/Materials/Glow.tres",
		'[gd_resource type="ShaderMaterial" load_steps=2 format=3]\n\n'
		+ '[ext_resource type="Shader" path="%s/Assets/Materials/Glow.gdshader" id="1"]\n\n' % dir
		+ '[resource]\nshader = ExtResource("1")\n')
	var doc := _doc(dir, "Assets/UI/main.uxml")
	await h.process_frame
	var a := doc.get_element("a")
	var m := a.material as ShaderMaterial
	h.check(m != null, "url(.mat) maps to the Godot .tres beside it (%s)" % _messages(doc))
	if m != null:
		h.eq(m.get_shader_parameter("strength"), 0.5, "prop(\"_Strength\") -> uniform strength")
		h.eq(m.get_shader_parameter("tint"), Color(1, 0, 0, 1), "color property")
		h.eq(m.get_shader_parameter("offset"), Vector2(1, 2), "vector property to vec2")
	var kid := doc.get_element("kid")
	h.check(kid.material is ShaderMaterial, "-unity-material inherits")
	var b := doc.get_element("b")
	h.check(b.material != null and b.material != m, "no prop(): the shared material")
	doc.set_class("a", "box off")
	await h.process_frame
	h.eq(a.material, null, "none removes the material")
	_unload(doc)


# ---------------------------------------------------------------------------
# text-shadow blur
# ---------------------------------------------------------------------------

func test_text_shadow_blur() -> void:
	var dir := _setup("shadow", '<ui:Label name="soft" class="soft" text="Soft" />'
		+ '<ui:VisualElement name="p" class="f"><ui:Label name="inner" class="soft" text="In" /></ui:VisualElement>',
		'.soft { text-shadow: 2px 3px 4px rgba(0, 0, 0, 0.5); }\n.f { filter: grayscale(1); }\n')
	var doc := _doc(dir, "Assets/UI/main.uxml")
	await h.process_frame
	var soft: Label = doc.get_element("soft")
	h.check(soft.has_meta(&"uxml_shadow"), "a blurred shadow gets a blurred copy")
	var s: UxmlTextShadow = soft.get_meta(&"uxml_shadow")
	h.eq(s.copy.text, "Soft", "the copy follows the text")
	h.eq(s.copy.position, Vector2(2, 3), "shadow offset")
	h.check(absf(s.copy.get_theme_color("font_color").a - 0.5) < 0.01, "shadow color")
	h.check(not soft.has_theme_color_override("font_shadow_color"), "no sharp Godot shadow under the blur")
	var inner: Label = doc.get_element("inner")
	var si: UxmlTextShadow = inner.get_meta(&"uxml_shadow")
	h.check(not si.enabled, "a blur inside a filtered element is off")
	h.check(inner.has_theme_color_override("font_shadow_color"), "and the shadow draws sharp")
	h.check(_messages(doc).contains("shadow is drawn sharp"), "diagnosed")
	doc.set_text("soft", "Changed")
	await h.process_frame
	await h.process_frame
	h.eq(s.copy.text, "Changed", "text set by game code reaches the copy")
	_unload(doc)


# ---------------------------------------------------------------------------
# -unity-text-auto-size
# ---------------------------------------------------------------------------

func _autosize_doc(native: bool) -> UxmlDocument:
	var dir := _setup("autosize",
		'<ui:VisualElement name="col" class="col">'
		+ '<ui:Label name="free" class="t a" text="Hello" />'
		+ '<ui:Label name="w60" class="t a" text="Hello" style="width: 60px;" />'
		+ '<ui:Label name="h20" class="t a" text="Hello" style="height: 20px;" />'
		+ '<ui:Label name="box" class="t a" text="Hello" style="width: 30px; height: 30px;" />'
		+ '<ui:Label name="std" class="a" text="Hello" style="width: 60px;" />'
		+ '</ui:VisualElement>'
		+ '<ui:VisualElement name="stretch" class="stretch"><ui:Label name="st" class="t a" text="Hello there" /></ui:VisualElement>',
		'.col { align-items: flex-start; }\n'
		+ '.stretch { width: 100px; }\n'
		+ '.t { -unity-text-generator: advanced; }\n'
		+ '.a { -unity-text-auto-size: best-fit 10px 40px; }\n')
	UxmlDocument.use_native_layout = native
	# Sizes below are pinned to authored USS: the default theme adds Label
	# margins and padding that change the fitted widths.
	var doc := _doc(dir, "Assets/UI/main.uxml", Vector2(400, 600), native, false)
	UxmlDocument.use_native_layout = true
	return doc


func _fs(c: Control) -> int:
	return c.get_theme_font_size("font_size")


func _text_w(c: Label, s: int) -> float:
	return c.get_theme_font("font").get_string_size(c.text, HORIZONTAL_ALIGNMENT_LEFT, -1, s).x


func test_auto_size() -> void:
	var doc := _autosize_doc(true)
	await h.process_frame
	await h.process_frame
	var free: Label = doc.get_element("free")
	h.eq(_fs(free), 40, "no constraint: the maximum size (Unity measures at max)")
	var w60: Label = doc.get_element("w60")
	var s := _fs(w60)
	h.check(s > 10 and s < 40, "a fixed width fits the width (%d)" % s)
	h.check(_text_w(w60, s) <= 60.0 and _text_w(w60, s + 1) > 60.0, "largest size that fits 60px")
	h.eq(w60.size.y, w60.get_combined_minimum_size().y, "the auto height follows the fitted size")
	var h20: Label = doc.get_element("h20")
	h.check(_fs(h20) < 20, "a fixed height fits the height (%d)" % _fs(h20))
	h.check(h20.size.x < free.size.x, "the auto width follows the fitted size")
	var box: Label = doc.get_element("box")
	h.check(_fs(box) >= 10 and _fs(box) < _fs(w60), "both limits (%d)" % _fs(box))
	var std: Label = doc.get_element("std")
	h.check(not std.has_meta(&"uxml_autosize"), "standard generator: ignored, as in Unity")
	h.check(_messages(doc).contains("needs -unity-text-generator: advanced"), "and diagnosed")
	var st: Label = doc.get_element("st")
	h.eq(st.size.x, 100.0, "stretched to the column width")
	h.check(_text_w(st, _fs(st)) <= 100.0 and _fs(st) < 40, "a stretched item fits its stretched width (%d)" % _fs(st))
	h.eq(st.size.y, st.get_combined_minimum_size().y, "and measures its height at that size")
	# Text set by game code refits on the next layout.
	free.text = "Hello world, a much longer line of text"
	doc.refresh()
	await h.process_frame
	h.eq(_fs(free), 40, "unconstrained text keeps the maximum")
	_unload(doc)


func test_auto_size_native_and_gdscript_agree() -> void:
	var a := _autosize_doc(true)
	var b := _autosize_doc(false)
	await h.process_frame
	await h.process_frame
	h.check(a._native_layout() and not b._native_layout(), "both layout paths run")
	var bad := ""
	for n in ["free", "w60", "h20", "box", "std", "st", "col", "stretch"]:
		var ca: Control = a.get_element(n)
		var cb: Control = b.get_element(n)
		if ca.position != cb.position or ca.size != cb.size or _fs(ca) != _fs(cb):
			bad = "%s: %s %s %d vs %s %s %d" % [n, ca.position, ca.size, _fs(ca), cb.position, cb.size, _fs(cb)]
			break
	h.eq(bad, "", "native and GDScript measurers agree")
	_unload(a)
	_unload(b)


# ---------------------------------------------------------------------------
# resource() and template inline style URLs
# ---------------------------------------------------------------------------

func test_resource_lookup() -> void:
	var dir := ROOT + "/res"
	_png(dir + "/Assets/Art/Resources/Icons/play.png", Color.RED)
	_png(dir + "/Packages/com.x.ui/Runtime/Resources/Icons/pkg.png", Color.BLUE)
	_png(dir + "/Assets/Resources/Icons/both.png", Color.GREEN)
	_write(dir + "/Assets/Resources/Icons/both.tres", "[gd_resource type=\"Gradient\" format=3]\n\n[resource]\n")
	var r := UxmlResourceResolver.new(dir)
	var p := r.resolve('resource("Icons/play")', "", "texture")
	h.check(p["ok"] and String(p["path"]).ends_with("Assets/Art/Resources/Icons/play.png"),
		"a nested Assets/**/Resources folder (%s)" % p["path"])
	var q := r.resolve("resource('Icons/pkg')", "", "texture")
	h.check(q["ok"] and String(q["path"]).ends_with("Packages/com.x.ui/Runtime/Resources/Icons/pkg.png"), "a package Resources folder")
	h.check(String(r.resolve('resource("Icons/both")', "", "texture")["path"]).ends_with(".png"),
		"textures try image formats before .tres")
	var miss := r.resolve('resource("Icons/nope")', "", "texture")
	h.check(not miss["ok"] and miss["diagnostic"]["kind"] == "missing-file", "a miss is missing-file")
	h.check(not r.resolve('resource("../x")', "", "texture")["ok"], "no climbing out of a Resources folder")
	h.check(r._resource_cache.has("texture|Icons/play"), "results are cached")
	_write(dir + "/Assets/UI/main.uxml",
		'<ui:UXML xmlns:ui="UnityEngine.UIElements"><Style src="main.uss" /><ui:VisualElement name="a" class="a" /><ui:VisualElement name="m" class="m" /></ui:UXML>')
	_write(dir + "/Assets/UI/main.uss",
		'.a { width: 10px; height: 10px; background-image: resource("Icons/play"); cursor: resource("Icons/pkg") 1 1; }\n'
		+ '.m { width: 10px; height: 10px; background-image: resource("Icons/missing"); }\n')
	var doc := _doc(dir, "Assets/UI/main.uxml")
	await h.process_frame
	var box: UxmlBox = doc.get_element("a")
	h.check(box.box_texture != null, "background-image: resource() loads (%s)" % _messages(doc))
	var kinds := []
	for d in doc.diagnostics:
		kinds.append(d["kind"])
	h.check(kinds.has("missing-file"), "a missing resource() is diagnosed")
	h.check(not _messages(doc).contains("not supported"), "resource() is no longer unsupported")
	_unload(doc)


func test_template_inline_style_url() -> void:
	var dir := ROOT + "/tpl"
	_png(dir + "/Assets/UI/Parts/part.png", Color.RED)
	_write(dir + "/Assets/UI/Parts/Part.uxml",
		'<ui:UXML xmlns:ui="UnityEngine.UIElements"><ui:VisualElement name="img" style="width: 10px; height: 10px; background-image: url(&quot;part.png&quot;);">'
		+ '<ui:VisualElement name="kid" style="width: 4px; height: 4px; cursor: url(&quot;part.png&quot;);" /></ui:VisualElement></ui:UXML>')
	_write(dir + "/Assets/UI/main.uxml",
		'<ui:UXML xmlns:ui="UnityEngine.UIElements"><ui:Template name="Part" src="Parts/Part.uxml" />'
		+ '<ui:Instance template="Part" name="inst" /></ui:UXML>')
	var doc := _doc(dir, "Assets/UI/main.uxml")
	await h.process_frame
	var img: UxmlBox = doc.get_element("img")
	h.check(img.box_texture != null, "an inline url() in a template resolves against the template (%s)" % _messages(doc))
	h.check(not _messages(doc).contains("missing"), "no missing-file")
	_unload(doc)
