class_name UxmlRuntimeV2Glue
extends RefCounted
## Runtime v2 of a UxmlDocument (docs/design.md, "Runtime v2"): the
## document is drawn by the native core (UxmlRuntimeV2, native/src/v2.rs)
## into canvas items under the document's root box, with no Control per
## element. This side loads the cascade in table mode, hands the native
## runtime the value parsers and resources of runtime v1 (so both read
## every value the same way), and answers the document's element API.
##
## Phase 1 covers static documents (VisualElement, TemplateContainer, plain
## Label, Image; the box model, borders, radii, backgrounds, slices,
## clipping, opacity, text). load() returns why a document is not covered;
## UxmlDocument then loads it on runtime v1. A change that a covered
## document cannot take on v2 (a class that brings a transition, say)
## moves it to runtime v1 (UxmlDocument._v2_fallback).

## The tags runtime v2 draws (non-visual tags are skipped).
const TAGS := {"VisualElement": true, "TemplateContainer": true, "Label": true, "Image": true,
	"UXML": true, "Style": true}

var doc: UxmlDocument
var cascade: UssCascade
var rt: Object = null  # UxmlRuntimeV2
var applier: UxmlStyleApplier
var factory: UxmlControlFactory
var warnings: Array = []
var hovered: Dictionary = {}   # UxmlElement -> true (the :hover chain)
var active: Dictionary = {}    # UxmlElement -> true (the :active chain)
var _probe: Label = null
var _dirty: Dictionary = {}
var _queued := false
var _restyle_all := false

static var _mask_material: ShaderMaterial = null


func _init(p_doc: UxmlDocument) -> void:
	doc = p_doc


## Why the elements of `model` are not drawn by runtime v2, or "".
static func uncovered(model: UxmlDocumentModel) -> String:
	if not ClassDB.class_exists("UxmlRuntimeV2"):
		return "the native core is not loaded"
	if not UssCascade.use_native or not doc_native_layout():
		return "the GDScript path"
	if model == null or model.root == null:
		return "no document"
	if not model.bindings.is_empty():
		return "data bindings"
	for el in model.root.walk():
		if not TAGS.has(el.local):
			return "element <%s>" % el.local
		if el.part_of != null:
			return "control parts"
	return ""


static func doc_native_layout() -> bool:
	return ClassDB.class_exists("UxmlNativeCascade")


func _step(name: String, t0: int) -> int:
	var t := Time.get_ticks_usec()
	var prof = UxmlDocument.profile
	if prof != null:
		prof[name] = float(prof.get(name, 0.0)) + (t - t0) / 1000.0
	return t


## Loads doc's model on runtime v2. "" on success, else why not (nothing
## of v2 is left then).
func load() -> String:
	var t0 := Time.get_ticks_usec()
	var why := uncovered(doc._doc)
	if not why.is_empty():
		return why
	cascade = UssCascade.new(doc._doc)
	if cascade._native == null:
		return "no native cascade"
	cascade._native.call("set_table_mode", true)
	t0 = _step("v2: cascade setup", t0)
	cascade.update(doc._restyle_options())
	t0 = _step("v2: first cascade", t0)
	warnings = []
	applier = UxmlStyleApplier.new(doc._resolver, doc._doc.path, doc._doc.source, warnings)
	applier.element_paths = doc._doc.element_paths
	applier.unity_line_metrics = doc.theme_path == UxmlTheme.DEFAULT
	factory = UxmlControlFactory.new(doc._resolver, doc._doc.path, doc._doc.source, warnings)
	factory.element_paths = doc._doc.element_paths
	_probe = Label.new()
	_probe.name = "uxml-v2-probe"
	_probe.visible = false
	_probe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	doc._root_box.add_child(_probe)
	rt = ClassDB.instantiate("UxmlRuntimeV2")
	why = rt.call("build", cascade._native, doc._root_box, self, applier.unity_line_metrics)
	t0 = _step("v2: build", t0)
	if why.is_empty() and not warnings.is_empty():
		# A value runtime v1 reports: v1 reports it per element.
		why = "a style diagnostic"
	if not why.is_empty():
		dispose()
		return why
	_index()
	t0 = _step("v2: index", t0)
	rt.call("layout", doc.size)
	t0 = _step("v2: layout", t0)
	rt.call("draw")
	t0 = _step("v2: draw", t0)
	var on_changed := _on_model_changed
	for el in cascade.els:
		el.changed = on_changed
	if not doc._root_box.gui_input.is_connected(_on_gui_input):
		doc._root_box.gui_input.connect(_on_gui_input)
		doc._root_box.mouse_exited.connect(_on_mouse_exited)
	_step("v2: wiring", t0)
	return ""


## Duplicate names are diagnosed as runtime v1 does (the native side keeps
## the first element of each name).
func _index() -> void:
	var els: Array = cascade.els
	for i in (rt.call("duplicate_names") as PackedInt32Array):
		var el: UxmlElement = els[i]
		warnings.append(UxmlDiagnostic.make(
			"duplicate-name",
			'name "%s" is declared more than once; get_element returns the first' % String(el.get_attribute("name")),
			doc._doc.source, el.open_tag_start, doc._doc.path))


## The first element named `element_name`, or null.
func named(element_name: String) -> UxmlElement:
	if rt == null:
		return null
	var i: int = rt.call("find_name", element_name)
	return null if i < 0 else cascade.els[i]


func parent_of(el: UxmlElement) -> UxmlElement:
	var i := index_of(el)
	if i <= 0:
		return null
	return cascade.els[cascade._parent[i]]


func dispose() -> void:
	if rt != null:
		rt.call("free_items")
	rt = null
	if _probe != null and is_instance_valid(_probe):
		if _probe.get_parent() != null:
			_probe.get_parent().remove_child(_probe)
		_probe.free()
	_probe = null
	if doc != null and doc._root_box.gui_input.is_connected(_on_gui_input):
		doc._root_box.gui_input.disconnect(_on_gui_input)
		doc._root_box.mouse_exited.disconnect(_on_mouse_exited)
	if cascade != null:
		for el in cascade.els:
			el.changed = Callable()
	cascade = null
	applier = null
	factory = null
	hovered = {}
	active = {}
	_dirty = {}


func diagnostics() -> Array:
	return doc._doc.warnings + cascade.collect_warnings() + warnings + (rt.call("warnings") as Array)


func index_of(el: UxmlElement) -> int:
	if el == null or cascade == null:
		return -1
	return int(cascade.index.get(el, -1))


# ---------------------------------------------------------------------------
# Values and resources, as runtime v1 reads them (called by the native side)
# ---------------------------------------------------------------------------

func v2_color(v) -> Variant:
	var r := UssValues.parse_color(String(v))
	return r["color"] if r["ok"] else null


func v2_opacity(v) -> Variant:
	var r := UssValues.parse_opacity(String(v))
	return float(r["value"]) if r["ok"] else null


func v2_make_box(rec: Array) -> StyleBox:
	return UxmlStyleApplier._make_box(rec)


## A Label's theme items, read from a Label under the root box.
func v2_label_theme() -> Dictionary:
	var sb := _probe.get_theme_stylebox(&"normal")
	var m := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	if sb != null:
		m = PackedFloat32Array([sb.get_margin(SIDE_LEFT), sb.get_margin(SIDE_TOP),
			sb.get_margin(SIDE_RIGHT), sb.get_margin(SIDE_BOTTOM)])
	return {
		"font_color": _probe.get_theme_color(&"font_color"),
		"line_spacing": _probe.get_theme_constant(&"line_spacing"),
		"paragraph_spacing": _probe.get_theme_constant(&"paragraph_spacing"),
		"outline_size": _probe.get_theme_constant(&"outline_size"),
		"font_outline_color": _probe.get_theme_color(&"font_outline_color"),
		"font_shadow_color": _probe.get_theme_color(&"font_shadow_color"),
		"shadow_offset_x": _probe.get_theme_constant(&"shadow_offset_x"),
		"shadow_offset_y": _probe.get_theme_constant(&"shadow_offset_y"),
		"shadow_outline_size": _probe.get_theme_constant(&"shadow_outline_size"),
		"normal_margins": m,
	}


## [font, size] of Label i: the font and size a Label of runtime v1 draws
## with (UxmlStyleApplier._apply_themed_inner).
func v2_font(i: int) -> Array:
	var el: UxmlElement = cascade.els[i]
	var style: Dictionary = cascade._native.call("style_of", i)
	applier._capture_base_font(_probe)
	var font: Font = applier._font(_probe, style, el)
	if applier.unity_line_metrics and not UxmlStyleApplier._has_url_font(style):
		font = applier._line_font(_probe, font, style, el)
	var fs := applier._effective_font_size(_probe, style, el)
	if font == null:
		font = _probe.get_theme_font(&"font")
	return [font, fs]


## [box style, image style, image texture, text inset by the box] of
## element i with a background image (UxmlStyleApplier._apply_box for a
## box, _apply_themed_inner for a Label).
func v2_boxes(i: int, label: bool) -> Array:
	var el: UxmlElement = cascade.els[i]
	var style: Dictionary = cascade._native.call("style_of", i)
	var tex := applier._texture(style, "background-image", el)
	if label:
		var sb: StyleBox = applier._stylebox(style, el)
		if sb == null and tex != null:
			sb = applier._image_stylebox(tex, style, el)
			for side in ["left", "top", "right", "bottom"]:
				sb.set("content_margin_" + side, 0.0)
		elif sb != null and tex != null and UxmlStyleApplier._box_drawn(sb):
			sb = applier._with_image(style, el, tex)
		elif sb != null and tex != null:
			var tsb := applier._image_stylebox(tex, style, el)
			if sb.has_meta("uxml_margins"):
				tsb.set_meta("uxml_margins", sb.get_meta("uxml_margins"))
			sb = tsb
		return [sb, null, null, sb != null and sb.has_meta("uxml_margins")]
	var box := UxmlStyleApplier._make_box(applier._box_rec(style, el, false))
	if tex != null and box != null and UxmlStyleApplier._box_drawn(box):
		return [applier._with_image(style, el, tex), null, null, true]
	if tex != null and applier._needs_placement(style):
		return [box, applier._image_stylebox(tex, style, el), null, box != null]
	if tex != null and applier._has_slice_or_tint(style):
		return [box, applier._texture_stylebox(tex, style, el), null, box != null]
	return [box, null, tex, box != null]


## [texture, stretch mode, tint] of Image i (UxmlControlFactory._create_image
## and UxmlStyleApplier._apply_image), or [] without a texture.
func v2_image(i: int) -> Array:
	var el: UxmlElement = cascade.els[i]
	var style: Dictionary = cascade._native.call("style_of", i)
	var tex: Texture2D = null
	var ref := factory._first_attr(el, ["src", "image"])
	if not ref.is_empty():
		tex = factory._load_texture(ref, el)
	if style.has("--unity-image"):
		var t := applier._texture(style, "--unity-image", el)
		if t != null:
			tex = t
	if tex == null:
		return []
	var mode := TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var fit := applier._str(style, "--unity-image-size")
	if UxmlStyleApplier._IMAGE_FIT.has(fit):
		mode = UxmlStyleApplier._IMAGE_FIT[fit]
	var tint = applier._color(style, "--unity-image-tint-color", el) if style.has("--unity-image-tint-color") else null
	return [tex, mode, tint if tint != null else Color.WHITE]


## [mask box, mask material] of a rounded clip (UxmlClip.set_radii) with
## the inset `widths` (top, right, bottom, left).
func v2_mask(radii: PackedFloat64Array, widths: PackedFloat64Array) -> Array:
	var mask := UxmlBoxStyle.new()
	mask.bg_color = Color.WHITE
	mask.radii = radii
	mask.fill_inner = true
	mask.widths = widths
	if _mask_material == null:
		var sh := Shader.new()
		sh.code = UxmlClip.MASK_SHADER
		_mask_material = ShaderMaterial.new()
		_mask_material.shader = sh
	return [mask, _mask_material]


# ---------------------------------------------------------------------------
# Changes: model edits, pseudo-states, resizes
# ---------------------------------------------------------------------------

func _on_model_changed(el: UxmlElement) -> void:
	_dirty[el] = true
	if el.changed_attribute == "text" and el.local == "Label":
		var i := index_of(el)
		if i >= 0:
			var t = el.get_attribute("text")
			rt.call("set_text", i, "" if t == null else String(t))
	queue()


func queue() -> void:
	if _queued:
		return
	_queued = true
	_flush.call_deferred()


func _flush() -> void:
	if _queued and rt != null:
		restyle()


## Runs the cascade for what changed, restyles, lays out and draws. False
## when the document must move to runtime v1.
func restyle() -> bool:
	_queued = false
	if rt == null:
		return true
	var dl := PackedInt32Array()
	for el in _dirty:
		var i := index_of(el)
		if i >= 0:
			dl.append(i)
	var all := _restyle_all
	_dirty = {}
	_restyle_all = false
	var changed: PackedInt32Array = cascade.update(_options(), all, null if all else dl)
	var why: String = rt.call("restyle", changed)
	if why.is_empty() and not warnings.is_empty():
		why = "a style diagnostic"
	if not why.is_empty():
		doc._v2_fallback(why)
		return false
	rt.call("layout", doc.size)
	rt.call("draw")
	doc.diagnostics = diagnostics()
	return true


func set_text(el: UxmlElement, text: String) -> void:
	var i := index_of(el)
	if i >= 0 and rt.call("set_text", i, text):
		queue()


func refresh() -> void:
	_restyle_all = true
	for el in cascade.els:
		_dirty[el] = true
	queue()


func relayout() -> void:
	if rt == null:
		return
	rt.call("layout", doc.size)
	rt.call("draw")


func _options() -> Dictionary:
	var o := doc._restyle_options()
	if hovered.is_empty() and active.is_empty():
		return o
	var es: Dictionary = (o.get("element_states", {}) as Dictionary).duplicate()
	for el in hovered:
		var a: Array = Array(es.get(el, []))
		a.append("hover")
		es[el] = a
	for el in active:
		var a: Array = Array(es.get(el, []))
		a.append("active")
		es[el] = a
	o["element_states"] = es
	return o


## :hover and :active from the core's hit test: the element under the
## pointer and its ancestors (Unity's hover chain).
func _on_gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		_set_chain(hovered, _chain_at((ev as InputEventMouseMotion).position))
	elif ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		if (ev as InputEventMouseButton).pressed:
			_set_chain(active, _chain_at((ev as InputEventMouseButton).position))
		else:
			_set_chain(active, {})


func _on_mouse_exited() -> void:
	_set_chain(hovered, {})


func _chain_at(p: Vector2) -> Dictionary:
	var out := {}
	var i: int = rt.call("pick", p, true)
	var els: Array = cascade.els
	var par: PackedInt32Array = cascade._parent
	while i > 0:
		out[els[i]] = true
		i = par[i]
	return out


func _set_chain(target: Dictionary, chain: Dictionary) -> void:
	if chain.size() == target.size():
		var same := true
		for el in chain:
			if not target.has(el):
				same = false
				break
		if same:
			return
	for el in target:
		if not chain.has(el):
			_dirty[el] = true
	for el in chain:
		if not target.has(el):
			_dirty[el] = true
	target.clear()
	target.merge(chain)
	queue()


# ---------------------------------------------------------------------------
# Element API
# ---------------------------------------------------------------------------

func computed_style(el: UxmlElement) -> Dictionary:
	var i := index_of(el)
	return {} if i < 0 else cascade._native.call("style_of", i)


## The border box of `el` in the root box's coordinates, or null when it
## has no layout (display: none on it or above, or not drawn).
func host_rect(el: UxmlElement):
	var i := index_of(el)
	if i < 0 or int(rt.call("kind_of", i)) == 0:
		return null
	var flags: Array = cascade.effective_flags()
	if (flags[2] as PackedByteArray)[i] == 1:
		return null
	return rt.call("host_rect", i)


func insets(el: UxmlElement) -> Array:
	var i := index_of(el)
	if i < 0:
		return [Vector2.ZERO, Vector2.ZERO]
	var r: Array = rt.call("insets_of", i)
	return r if r.size() == 2 else [Vector2.ZERO, Vector2.ZERO]


func element_at(local_point: Vector2, respect_picking: bool) -> UxmlElement:
	var p := doc._root_box.get_transform().affine_inverse() * local_point
	var i: int = rt.call("pick", p, respect_picking)
	if i <= 0:
		return null
	return cascade.els[i]
