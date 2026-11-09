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
## clipping, opacity, text). Phase 2 adds the interactive widgets (Button,
## Toggle, Slider, SliderInt, DropdownField, TextField): their part trees
## are table elements drawn by the core like any element, and each
## focusable or interactive element gets ONE interaction Control
## (`proxies`), placed at the element's rect, that draws nothing (a text
## field's editor is a real LineEdit/TextEdit, which draws its text):
##
##   Button         a flat Button with empty styleboxes (pressed, ui_accept,
##                  accessibility); the core draws the box and the text
##   Toggle         a UxmlToggle (ui_accept, toggled, button_pressed)
##   Slider(Int)    a UxmlSlider (keys, value, value_changed)
##   DropdownField  a UxmlPopupField (ui_accept, selected, item_selected)
##   TextField      the LineEdit / TextEdit of its editor part
##   focusable="true" VisualElement: a plain Control
##
## The proxies take the keyboard and controller focus (Godot's focus and
## neighbour search over them), never the mouse: pointer input comes from
## the core's hit test on the root box and goes to the element under it.
## Values, :checked, :focus, signals and the field API are runtime v1's
## behaviors (UxmlBehaviors, UxmlInputBehaviors), run on the proxies; the
## document's element maps (`_controls`, `_natives`, `_by_name`,
## `_behaviors`, `_parents`) hold the proxies, so get_element, get_native,
## get_control_for, set_field_value and the focus APIs work as on v1.
##
## load() returns why a document is not covered; UxmlDocument then loads it
## on runtime v1. A change that a covered document cannot take on v2 (a
## class that brings a transition, say) moves it to runtime v1
## (UxmlDocument._v2_fallback).

## The tags runtime v2 draws (non-visual tags are skipped).
const TAGS := {"VisualElement": true, "TemplateContainer": true, "Label": true, "Image": true,
	"UXML": true, "Style": true, "Button": true, "Toggle": true, "Slider": true, "SliderInt": true,
	"DropdownField": true, "TextField": true, "ScrollView": true, "RadioButton": true,
	"RadioButtonGroup": true, "Foldout": true, "ProgressBar": true, "EnumField": true, "MinMaxSlider": true,
	"ListView": true}

const _COLLECTIONS := {"ListView": true, "TreeView": true, "MultiColumnListView": true, "MultiColumnTreeView": true}
## The kinds of the controls (UxmlRuntimeV2 K_*).
const _CONTROL_KINDS := {"Button": 4, "Toggle": 1, "Slider": 1, "SliderInt": 1, "DropdownField": 1, "TextField": 1,
	"ScrollView": 1, "RadioButton": 1, "RadioButtonGroup": 1, "Foldout": 1, "ProgressBar": 1, "EnumField": 1,
	"MinMaxSlider": 1, "ListView": 1}
var _has_tabindex := false

## The part tags of the controls v2 covers, and the kinds the core gives
## them (v2.rs K_*).
const K_BOX := 1
const K_LABEL := 2
const K_BUTTON := 4
const K_EDIT := 5
const F_PLAIN := 0x40
const F_PART := 0x20
const F_ATTRS_OK := 0x80
const F_UNPICKED := 0x10
## The part roles Unity does not pick (UxmlControlFactory._part_input).
const UNPICKED := {"checkmark": true, "text": true, "checkmark-background": true, "title": true,
	"title-container": true, "progress": true, "icon": true, "arrow": true}
const PART_KINDS := {"VisualElement": K_BOX, "TextInput": K_BOX, "Label": K_LABEL,
	"TextElement": K_LABEL | F_PLAIN, "PopupTextElement": K_LABEL | F_PLAIN,
	"Scroller": K_BOX, "ScrollerSlider": K_BOX, "RepeatButton": K_BUTTON, "Toggle": K_BOX,
	"RadioButton": K_BOX, "ScrollView": K_BOX, "TemplateContainer": K_BOX, "TextField": K_BOX,
	"IntegerField": K_BOX, "FloatField": K_BOX}

## The attributes of the controls that v2 implements (beside COMMON).
const CONTROL_ATTRS := {
	"Button": ["text", "enable-rich-text", "parse-escape-sequences", "display-tooltip-when-elided"],
	"Toggle": ["value", "label", "text", "toggle-on-label-click"],
	"Slider": ["value", "low-value", "high-value", "label", "page-size", "direction", "inverted", "fill", "show-input-field"],
	"SliderInt": ["value", "low-value", "high-value", "label", "page-size", "direction", "inverted", "fill", "show-input-field"],
	"DropdownField": ["choices", "index", "value", "label"],
	"TextField": ["value", "text", "label", "max-length", "password", "mask-character", "readonly",
		"placeholder-text", "hide-placeholder-on-focus", "is-delayed", "keyboard-type", "auto-correction",
		"hide-mobile-input", "select-all-on-focus", "select-all-on-mouse-up", "select-word-by-double-click",
		"select-line-by-triple-click", "emoji-fallback-support", "multiline", "vertical-scroller-visibility"],
	"RadioButton": ["value", "label", "text"],
	"RadioButtonGroup": ["value", "label", "choices"],
	"Foldout": ["text", "value", "toggle-on-label-click"],
	"ProgressBar": ["value", "low-value", "high-value", "title"],
	"EnumField": ["type", "value", "label", "include-obsolete-values"],
	"MinMaxSlider": ["min-value", "max-value", "low-limit", "high-limit", "label"],
	"ListView": ["fixed-item-height", "item-template", "show-alternating-row-backgrounds",
		"selection-type", "show-border", "virtualization-method", "horizontal-scrolling",
		"show-bound-collection-size", "binding-source-selection-mode"],
	"ScrollView": ["mode", "horizontal-scroller-visibility", "vertical-scroller-visibility",
		"show-horizontal-scroller", "show-vertical-scroller", "mouse-wheel-scroll-size",
		"horizontal-page-size", "vertical-page-size", "nested-interaction-kind", "touch-scroll-type",
		"elasticity", "scroll-deceleration-rate"],
}
## Tags that never have a behavior (UxmlBehaviors._create gives null).
const NO_BEHAVIOR := {"VisualElement": true, "Label": true, "Image": true, "TemplateContainer": true,
	"UXML": true, "Style": true, "Button": true, "TextInput": true, "TextElement": true,
	"PopupTextElement": true, "RepeatButton": true, "ScrollerSlider": true}
const COMMON_ATTRS := {"name": true, "class": true, "style": true, "tooltip": true, "focusable": true,
	"picking-mode": true, "enabled": true, "view-data-key": true, "usage-hints": true, "tabindex": true}

var doc: UxmlDocument
var cascade: UssCascade
var rt: Object = null  # UxmlRuntimeV2
var applier: UxmlStyleApplier
var factory: UxmlControlFactory
var warnings: Array = []
var hovered: Dictionary = {}   # UxmlElement -> true (the :hover chain)
var active: Dictionary = {}    # UxmlElement -> true (the :active chain)
## Interaction Controls: element index -> Control (see the class doc).
var proxies: Dictionary = {}
## The editor parts (index -> LineEdit/TextEdit), applied by the applier.
var editors: Dictionary = {}
## The element of each interaction Control.
var _proxy_el: Dictionary = {}
var _probe: Label = null
var _bprobe: Button = null
var _dirty: Dictionary = {}
var _queued := false
var _restyle_all := false
## The element pressed by the pointer (its interaction owner), or null.
var _pressed: UxmlElement = null
var _tooltip_el: UxmlElement = null
var _menu_anchor: Control = null
## The restyle state: the option revision seen (UxmlDocument._opt_rev), a
## layout request, the effective flags of the last pass, the elements it
## restyled, the disabled flags the interaction Controls follow, the
## behaviors with layout hooks, the indices of the interaction Controls.
var _seen_rev := -1
var _layout_req := false
var _draw_req := false  # a text or a focus box changed: lay out if needed, draw
var _flags: Array = [PackedByteArray(), PackedByteArray(), PackedByteArray()]
var _restyled: Dictionary = {}
var _last_dis := PackedByteArray()
var _hooked: Array = []
## The interaction Controls in the order of _proxy_idx, and which are editors.
var _proxy_ctls: Array = []
## The Control each editor sits in (at its field's place), by element.
var _edit_wrap: Dictionary = {}
var _proxy_edit := PackedByteArray()
var _proxy_idx := PackedInt32Array()
var _editor_shown: Dictionary = {}  # editor index -> shown at its last placement

static var _mask_material: ShaderMaterial = null
static var _empty_box: StyleBoxEmpty = null


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
	var stack: Array = [model.root]
	while not stack.is_empty():
		var el: UxmlElement = stack.pop_back()
		var ch: Array = el.children
		var k := ch.size() - 1
		while k >= 0:
			stack.append(ch[k])
			k -= 1
		if el._part_of != null:
			if not PART_KINDS.has(el.local):
				return "part <%s>" % el.local
			continue
		if not TAGS.has(el.local):
			return "element <%s>" % el.local
		var allowed = CONTROL_ATTRS.get(el.local)
		if allowed == null or (allowed as Array).is_empty():
			continue  # the core checks the attributes of static elements
		for a in el.attributes:
			var n := String(a["name"])
			if not COMMON_ATTRS.has(n) and not allowed.has(n):
				return "attribute %s of <%s>" % [n, el.local]
		match el.local:
			"TextField":
				if UxmlInputParts.has_inner_scroll_view(el):
					return "a TextField with a scroller"
			"ListView":
				# FixedHeight rows (DynamicHeight measures its rows' Controls).
				if UxmlContainerParts.is_dynamic(el):
					return "a DynamicHeight ListView"
				if UxmlParts._bool(el, "horizontal-scrolling", false):
					return "a ListView with horizontal scrolling"
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
	# Control part trees become model elements (as runtime v1's _index
	# builds them; once per model).
	# Collection views: their item templates and pools (UxmlDocument._index).
	var collections := false
	if not doc._doc.has_meta(&"uxml_parts_expanded"):
		collections = doc._prepare_collections()
	UxmlParts.expand(doc._doc)
	if collections:
		doc._rt_warnings.append_array(UxmlBindings.extract(doc._doc))
		if not doc._doc.bindings.is_empty():
			return "data bindings"
	t0 = _step("v2: part trees", t0)
	cascade = UssCascade.new(doc._doc)
	if cascade._native == null:
		return "no native cascade"
	cascade._native.call("set_table_mode", true)
	t0 = _step("v2: cascade setup", t0)
	warnings = []
	applier = UxmlStyleApplier.new(doc._resolver, doc._doc.path, doc._doc.source, warnings)
	applier.element_paths = doc._doc.element_paths
	applier.unity_line_metrics = doc.theme_path == UxmlTheme.DEFAULT
	# Panel scaling: the boxes, borders and text lines on the device pixel
	# grid (UxmlDocument._update_scale).
	applier.set_pixels_per_point(doc._grid_ppp)
	factory = UxmlControlFactory.new(doc._resolver, doc._doc.path, doc._doc.source, warnings)
	factory.element_paths = doc._doc.element_paths
	_probe = Label.new()
	_probe.name = "uxml-v2-probe"
	_probe.visible = false
	_probe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	doc._root_box.add_child(_probe)
	_bprobe = Button.new()
	_bprobe.name = "uxml-v2-button-probe"
	_bprobe.visible = false
	_bprobe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bprobe.focus_mode = Control.FOCUS_NONE
	doc._root_box.add_child(_bprobe)
	# The element maps, the interaction Controls and the behaviors: the
	# behaviors set their states (:checked) before the first cascade.
	var kinds := _index()
	t0 = _step("v2: index", t0)
	_make_proxies()
	# tabindex: Unity's focus ring over the interaction Controls (runtime
	# v1's UxmlCommonAttributes, which reads the document's element maps).
	if _has_tabindex:
		doc._attrs.rebuild_focus_ring()
	t0 = _step("v2: controls", t0)
	cascade.update(_options())
	t0 = _step("v2: first cascade", t0)
	rt = ClassDB.instantiate("UxmlRuntimeV2")
	rt.call("set_scale", doc._grid_ppp, _oversampling())
	why = rt.call("build", cascade._native, doc._root_box, self, applier.unity_line_metrics, kinds)
	t0 = _step("v2: build", t0)
	if why.is_empty() and not _diag_free():
		# A value runtime v1 reports: v1 reports it per element.
		why = "a style diagnostic"
	if not why.is_empty():
		dispose()
		return why
	_duplicates()
	var on_changed := _on_model_changed
	for el in cascade.els:
		el.changed = on_changed
	for i in editors:
		rt.call("set_edit_control", i, editors[i])
	_flags = cascade.effective_flags()
	_sync_disabled()
	t0 = _step("v2: wire model", t0)
	_apply_editors(PackedInt32Array(editors.keys()))
	t0 = _step("v2: apply editors", t0)
	_seen_rev = doc._opt_rev
	_layout(true)
	if not _failed.is_empty():
		# A restyle of the load (a layout hook's styles) left v2.
		why = _failed
		dispose()
		return why
	t0 = _step("v2: layout", t0)
	rt.call("draw")
	t0 = _step("v2: draw", t0)
	if not doc._root_box.gui_input.is_connected(_on_gui_input):
		doc._root_box.gui_input.connect(_on_gui_input)
		doc._root_box.mouse_exited.connect(_on_mouse_exited)
	_step("v2: wiring", t0)
	return ""


## The kinds the core gives the elements (0: it decides), and the
## document's element maps: names (first wins, parts excluded), parents.
func _index() -> PackedByteArray:
	var els: Array = cascade.els
	var par: PackedInt32Array = cascade._parent
	var kinds := PackedByteArray()
	var n_els := els.size()
	kinds.resize(n_els)
	_has_tabindex = false
	# The elements of the pooled rows of collection views: no names (the
	# rows repeat them; runtime v1's _pooled).
	var pooled := {}
	for el in els:
		if _COLLECTIONS.has(el.local) and el._part_of == null:
			for row in UxmlContainerParts.rows_of(el):
				for sub in row.walk():
					if sub.part_of == null:
						pooled[sub] = true
	doc._pooled = pooled
	var parents := doc._parents
	var by_name := doc._by_name
	var el_names := doc._el_names
	for i in n_els:
		var el: UxmlElement = els[i]
		if i > 0:
			parents[el] = els[par[i]]
		var local := el.local
		if el._part_of != null:
			var k: int = PART_KINDS.get(local, 0)
			var role := el.part_role
			if role == "editor":
				k = K_EDIT
			if UNPICKED.has(role) or UxmlControlFactory.UNPICKED_CONTAINER_PARTS.has(role):
				k |= F_UNPICKED
			kinds[i] = k | F_ATTRS_OK | F_PART
			for a in el.attributes:
				if a["name"] == "tabindex":
					_has_tabindex = true
			continue
		var ck: int = _CONTROL_KINDS.get(local, 0)
		if ck != 0:
			kinds[i] = ck | F_ATTRS_OK
		# The first `name` (get_attribute) and whether a tabindex is set.
		var nm = null
		for a in el.attributes:
			var an: String = a["name"]
			if an == "name":
				if nm == null:
					nm = a["value"]
			elif an == "tabindex":
				_has_tabindex = true
		if not pooled.is_empty() and pooled.has(el):
			kinds[i] |= F_PART
			continue
		if nm != null and not by_name.has(String(nm)):
			by_name[String(nm)] = el
			el_names[el] = String(nm)
	return kinds


## Duplicate names are diagnosed as runtime v1 does (the native side keeps
## the first element of each name).
func _duplicates() -> void:
	var els: Array = cascade.els
	for i in (rt.call("duplicate_names") as PackedInt32Array):
		var el: UxmlElement = els[i]
		warnings.append(UxmlDiagnostic.make(
			"duplicate-name",
			'name "%s" is declared more than once; get_element returns the first' % String(el.get_attribute("name")),
			doc._doc.source, el.open_tag_start, doc._doc.path))


func _diag_free() -> bool:
	return warnings.is_empty() and doc._rt_warnings.is_empty()


# ---------------------------------------------------------------------------
# Interaction Controls
# ---------------------------------------------------------------------------

static func _no_box() -> StyleBoxEmpty:
	if _empty_box == null:
		_empty_box = StyleBoxEmpty.new()
	return _empty_box


## The document cannot stay on runtime v2: it moves to v1 (during the load,
## load() returns why).
var _failed := ""


func _fail(why: String) -> void:
	if OS.has_environment("V2DBG"): print("FAIL ", why, " ", warnings.map(func(w): return w.message if w is Object else str(w)), " ", doc._rt_warnings.map(func(w): return str(w)))
	if doc._v2 == self:
		doc._v2_fallback(why)
		return
	_failed = why
	rt = null


## The collection view whose scroll view `content` is the content
## container of, or null.
func _collection_of(content: UxmlElement) -> UxmlElement:
	var sv := content.part_of
	if sv == null or sv.part_role != "scroll-view":
		return null
	var cv := sv.part_of
	return cv if cv != null and UxmlContainerParts.is_collection(cv.local) else null


## One interaction Control per focusable or interactive element, the
## editors of the text fields, and the behaviors of the controls.
func _make_proxies() -> void:
	var els: Array = cascade.els
	var behaviors := {}
	_lazy = {}
	var lazy := not eager and not _needs_all()
	for i in els.size():
		var el: UxmlElement = els[i]
		var c: Control = null
		var is_part := el._part_of != null
		var local := el.local
		# Most elements have no Control (Labels, boxes, most parts).
		if is_part:
			if local != "Toggle" and local != "RadioButton" and el.part_role != "content" and el.part_role != "editor":
				continue
		elif not _CONTROL_KINDS.has(local) and local != "VisualElement" and local != "TemplateContainer":
			continue
		if is_part and (local == "Toggle" or local == "RadioButton"):
			# A control that is a part (a Foldout's Toggle, the choices of a
			# RadioButtonGroup): its own UxmlToggle.
			var pt := UxmlToggle.new()
			pt.radio = el.local == "RadioButton"
			pt.set_pressed_no_signal(UxmlParts._bool(el, "value", false))
			c = pt
			c.mouse_filter = Control.MOUSE_FILTER_IGNORE
			c.set_meta("uxml_focus", c.focus_mode)
			doc._natives[el] = c
		elif is_part and el.part_role == "content" and _collection_of(el) != null:
			# Unity: the scroll view's content container of a collection
			# view takes the focus (CollectionBehavior.setup connects it).
			c = Control.new()
			c.focus_mode = Control.FOCUS_ALL
			c.mouse_filter = Control.MOUSE_FILTER_IGNORE
			c.set_meta("uxml_focus", c.focus_mode)
		elif is_part:
			if el.part_role == "editor":
				c = UxmlTextInput.create(el)
				factory._apply_common_attributes(el, c)
				c.set_meta("uxml_mouse", c.mouse_filter)
				c.set_meta("uxml_focus", c.focus_mode)
				c.set_meta("uxml_editable", c.editable)
				editors[i] = c
				var field := el.part_of
				if field.has_attribute("focusable"):
					# `focusable` of the field applies to its editor
					# (UxmlControlFactory._apply_common_attributes).
					c.focus_mode = Control.FOCUS_ALL if UxmlParts._attr(field, "focusable") == "true" else Control.FOCUS_NONE
					c.set_meta("uxml_focus", c.focus_mode)
				c.mouse_entered.connect(_on_editor_hover.bind(el))
				c.gui_input.connect(_on_editor_input.bind(el))
				# The field's native is its editor (UxmlControlFactory.build).
				doc._natives[el.part_of] = c
			else:
				continue
		elif _lazy_kind(el):
			# Made on first need (_ctl): the focus, a press, the API.
			if lazy:
				_lazy[i] = el
			else:
				_make_lazy(i, el)
			continue
		else:
			match el.local:
				"Toggle", "RadioButton":
					var t := UxmlToggle.new()
					t.radio = el.local == "RadioButton"
					t.set_pressed_no_signal(UxmlParts._bool(el, "value", false))
					c = t
				"Slider", "SliderInt":
					c = UxmlSlider.new()
					behaviors[el] = V2SliderBehavior.new()
				"DropdownField", "EnumField":
					c = UxmlPopupField.new()
					behaviors[el] = V2PopupBehavior.new()
				"MinMaxSlider":
					c = UxmlSlider.new()
					behaviors[el] = V2MinMaxBehavior.new()
				"ScrollView":
					behaviors[el] = V2ScrollViewBehavior.new()
					if UxmlParts._attr(el, "focusable") == "true":
						c = Control.new()
						c.focus_mode = Control.FOCUS_ALL
						c.gui_input.connect(_on_scroll_key.bind(el))
			if c == null:
				continue
			_common_setup(el, c)
		if not behaviors.has(el) and el.local in ["Toggle", "RadioButton"]:
			behaviors[el] = UxmlBehaviors.ToggleBehavior.new()
		_register(i, el, c)
		if editors.has(i):
			# The editor sits in a Control at its field's place, as runtime
			# v1's sits in its field's Control: its position and size are
			# then the same f32 values in the same frame (_place_proxies).
			var w := Control.new()
			w.name = "uxml-v2-editor-%d" % i
			w.mouse_filter = Control.MOUSE_FILTER_IGNORE
			w.focus_mode = Control.FOCUS_NONE
			_edit_wrap[i] = w
			doc._root_box.add_child(w)
			w.add_child(c)
		else:
			doc._root_box.add_child(c)
		var target := c
		target.focus_entered.connect(_on_focus.bind(el, true))
		target.focus_exited.connect(_on_focus.bind(el, false))
	# The behaviors of the other controls, as runtime v1 makes them
	# (UxmlBehaviors.attach_all: parts included).
	for el in els:
		if behaviors.has(el) or NO_BEHAVIOR.has(el.local):
			continue
		var vb = null
		if el.local == "ScrollView":
			vb = V2ScrollViewBehavior.new()
		elif el.local == "ListView":
			vb = V2CollectionBehavior.new()
		else:
			vb = UxmlBehaviors._create(el)
		if vb != null:
			behaviors[el] = vb
	for el in behaviors:
		var b = behaviors[el]
		b.doc = doc
		b.el = el
		if b is V2SliderBehavior or b is V2PopupBehavior or b is V2ScrollViewBehavior or b is V2MinMaxBehavior \
				or b is V2CollectionBehavior:
			b.glue = self
	doc._behaviors = behaviors
	for el in behaviors:
		behaviors[el].setup()
	_hooked = []
	for el in behaviors:
		var hb = behaviors[el]
		if hb is V2SliderBehavior or hb is V2MinMaxBehavior or hb is V2ScrollViewBehavior \
				or hb is V2CollectionBehavior:
			_hooked.append(hb)
	_index_slots()
	if not _lazy.is_empty() and _nav == null:
		# Keyboard and controller navigation into an element whose Control
		# is not made yet: the Controls Godot's search can pick are made
		# before the GUI sees the event (Node._input runs first).
		_nav = V2Nav.new()
		_nav.glue = self
		_nav.name = "uxml-v2-nav"
		doc._root_box.add_child(_nav, false, Node.INTERNAL_MODE_BACK)


# ---------------------------------------------------------------------------
# Lazy interaction Controls
# ---------------------------------------------------------------------------
# The Controls of Buttons and focusable VisualElements hold no value and no
# behavior: they are made on first need (_ctl), not at the load. A Control
# made later is the one the load would have made, in the same place among
# the root box's children (Godot's Tab order is the tree order) and with the
# state of now: its placement (UxmlRuntimeV2.placed_of), its disabled flag,
# its accessibility name. What makes one:
#   - a press on its element (the core's hit test: _press);
#   - the API: get_element, get_native, get_control_for, get_native_for,
#     get_focus_ring (UxmlDocument calls ensure());
#   - keyboard and controller navigation: before the GUI handles a focus
#     action, the Controls that Godot's search can pick are made
#     (_prepare_navigation: the next and previous valid ones in tree order,
#     the first and last, the nearest in the direction of an arrow);
#   - tabindex (Unity's focus ring is a chain of Controls) and Godot's
#     accessibility (the tree is built from nodes): every Control at the load.

## Make every interaction Control at the load (tests, equivalence: the
## reference of the lazy Controls).
static var eager := false
## Element index -> UxmlElement whose Control is not made yet.
var _lazy: Dictionary = {}
var _nav: Node = null


class V2Nav extends Node:
	var glue

	func _input(ev: InputEvent) -> void:
		if glue != null:
			glue._prepare_navigation(ev)


## Whether the Control of `el` is made on first need.
static func _lazy_kind(el: UxmlElement) -> bool:
	match el.local:
		"Button":
			return el._part_of == null
		"VisualElement", "TemplateContainer":
			return el._part_of == null and UxmlParts._attr(el, "focusable") == "true"
	return false


## Every Control at the load: tabindex builds Unity's focus ring over the
## Controls, Godot's accessibility tree is built from them.
func _needs_all() -> bool:
	if doc.is_inside_tree() and doc.get_tree().is_accessibility_enabled():
		return true
	return _has_tabindex  # (_index)


## The Control of a lazy kind (a flat Button, a plain focusable Control).
func _make_lazy(i: int, el: UxmlElement) -> Control:
	var c: Control
	if el.local == "Button":
		var b := Button.new()
		b.flat = true
		for slot in ["normal", "hover", "pressed", "disabled", "focus", "hover_pressed"]:
			b.add_theme_stylebox_override(slot, _no_box())
		b.focus_mode = Control.FOCUS_ALL
		b.accessibility_name = UxmlParts._attr(el, "text") if rt == null else String(rt.call("get_text", i))
		var nm: String = doc._el_names.get(el, "")
		b.pressed.connect(func(): doc.button_pressed.emit(nm))
		b.button_down.connect(doc._set_state.bind(el, "active", true))
		b.button_up.connect(doc._set_state.bind(el, "active", false))
		c = b
	else:
		c = Control.new()
		c.focus_mode = Control.FOCUS_ALL
	_common_setup(el, c)
	_register(i, el, c)
	_add_ordered(i, c)
	c.focus_entered.connect(_on_focus.bind(el, true))
	c.focus_exited.connect(_on_focus.bind(el, false))
	return c


## The attributes every non-part interaction Control takes.
func _common_setup(el: UxmlElement, c: Control) -> void:
	if el.has_attribute("focusable"):
		c.focus_mode = Control.FOCUS_ALL if UxmlParts._attr(el, "focusable") == "true" else Control.FOCUS_NONE
	var tip := UxmlParts._attr(el, "tooltip")
	if not tip.is_empty():
		c.tooltip_text = tip
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.set_meta("uxml_focus", c.focus_mode)
	doc._natives[el] = c


func _register(i: int, el: UxmlElement, c: Control) -> void:
	c.name = "uxml-v2-%d" % i
	proxies[i] = c
	_proxy_el[c] = el
	doc._controls[el] = c
	doc._el_of[c] = el
	c.visible = false


## Adds Control `c` of element i to the root box in document order (at the
## load, in order; later before the next made Control).
func _add_ordered(i: int, c: Control) -> void:
	var box := doc._root_box
	var before: Node = null
	if not _proxy_idx.is_empty():
		var w := _proxy_idx.bsearch(i)
		for k in range(w, _proxy_idx.size()):
			var n = _proxy_ctls[k]
			if n != null and _proxy_idx[k] != i:
				before = _edit_wrap.get(_proxy_idx[k], n)
				break
	box.add_child(c)
	if before != null and before.get_parent() == box:
		box.move_child(c, before.get_index())


## The interaction slots in document order (made and lazy), for the
## placement (place_states) and the search of _prepare_navigation.
func _index_slots() -> void:
	var all: Array = proxies.keys() + _lazy.keys()
	all.sort()
	_proxy_idx = PackedInt32Array(all)
	_proxy_ctls = []
	_proxy_edit = PackedByteArray()
	for i in _proxy_idx:
		_proxy_ctls.append(proxies.get(i))
		_proxy_edit.append(1 if editors.has(i) else 0)


## The interaction Control of element i, made now if it is lazy; null for
## an element without one.
func _ctl(i: int) -> Control:
	var c = proxies.get(i)
	if c != null or not _lazy.has(i):
		return c
	var el: UxmlElement = _lazy[i]
	_lazy.erase(i)
	c = _make_lazy(i, el)
	_proxy_ctls[_proxy_idx.bsearch(i)] = c
	# The state of now: disabled, placement.
	if rt != null:
		var dis: PackedByteArray = _flags[1]
		var off := i < dis.size() and dis[i] == 1
		if c is BaseButton:
			(c as BaseButton).disabled = off
		var fm: int = Control.FOCUS_NONE if off else int(c.get_meta("uxml_focus", c.focus_mode))
		if c.focus_mode != fm:
			c.focus_mode = fm
		var p: Array = rt.call("placed_of", i)
		if p.size() == 6:
			c.position = p[0]
			c.size = p[1]
			c.visible = bool(p[4]) and (p[3] as Vector2).x > 0.0 and (p[3] as Vector2).y > 0.0
	return c


## The Control of `el` for the API (made now if it is lazy).
func ensure(el: UxmlElement) -> void:
	if not _lazy.is_empty() and el != null:
		var i := index_of(el)
		if i >= 0:
			_ctl(i)


func ensure_all() -> void:
	for i in _lazy.keys():
		_ctl(i)


const _NAV_ACTIONS := [&"ui_focus_next", &"ui_focus_prev", &"ui_left", &"ui_up", &"ui_right", &"ui_down"]


## Before the GUI handles a focus action (Viewport._gui_input_event), makes
## the Controls its search can pick: Control.find_next_valid_focus /
## find_prev_valid_focus walk the tree from the focus owner (or the first
## Control of the viewport), and _get_focus_neighbor takes the nearest
## focusable Control in the direction. A slot is valid as Godot's walk
## sees it: shown at its last placement, focus mode ALL.
func _prepare_navigation(ev: InputEvent) -> void:
	if _lazy.is_empty() or rt == null or not ev.is_pressed():
		return
	var act := -1
	for k in _NAV_ACTIONS.size():
		if ev.is_action_pressed(_NAV_ACTIONS[k], true, true) or ev.is_action_pressed(_NAV_ACTIONS[k]):
			act = k
			break
	if act < 0:
		return
	var vp := doc._root_box.get_viewport()
	if vp == null:
		return
	var from: Control = vp.gui_get_focus_owner()
	if from == null:
		for ch in vp.get_children(true):
			if ch is Control and (ch as Control).is_visible_in_tree() and not (ch as Control).is_set_as_top_level():
				from = ch
				break
	if from == null:
		return
	var valid := _valid_slots()
	var at := -1  # the slot of the focus owner
	var fel = _proxy_el.get(from)
	if fel != null:
		at = _proxy_idx.bsearch(index_of(fel))
	if act < 2:
		# Tab order: the next and previous valid slot of the focus owner, the
		# first and the last (the walk enters the root box from either end).
		var want := {}
		for k in valid.size():
			if valid[k] == 1:
				want[k] = true
				break
		for k in range(valid.size() - 1, -1, -1):
			if valid[k] == 1:
				want[k] = true
				break
		if at >= 0:
			for k in range(at + 1, valid.size()):
				if valid[k] == 1:
					want[k] = true
					break
			for k in range(at - 1, -1, -1):
				if valid[k] == 1:
					want[k] = true
					break
		for k in want:
			_ctl(_proxy_idx[k])
		return
	# An arrow: Control._get_focus_neighbor. A ScrollContainer above the
	# focus owner or the document repositions the search: every Control.
	var n: Node = from
	while n != null:
		if n is ScrollContainer:
			ensure_all()
			return
		n = n.get_parent()
	n = doc._root_box
	while n != null:
		if n is ScrollContainer:
			ensure_all()
			return
		n = n.get_parent()
	var side: int = [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM][act - 2]
	if not from.get_focus_neighbor(side).is_empty():
		return
	var vdir: Vector2 = [Vector2(-1, 0), Vector2(0, -1), Vector2(1, 0), Vector2(0, 1)][act - 2]
	var fr := from.get_global_rect()
	var maxd: float = maxf(vdir.dot(fr.position), vdir.dot(fr.end))
	var g := doc._root_box.get_global_transform()
	var gs := g.get_scale()
	var dists := {}
	var best := INF
	for k in valid.size():
		if valid[k] == 0 or k == at:
			continue
		var p: Array = rt.call("placed_of", _proxy_idx[k])
		var c = _proxy_ctls[k]
		var rc: Rect2
		if c != null:
			rc = (c as Control).get_global_rect()
		else:
			rc = Rect2(g * (p[0] as Vector2), gs * (p[1] as Vector2))
		if maxf(vdir.dot(rc.position), vdir.dot(rc.end)) <= maxd + 0.00001:
			continue
		var ab: Vector2 = (rc.get_center() - fr.get_center()).abs() - 0.5 * rc.size - 0.5 * fr.size
		var d := 0.0
		if ab.x > 0.0:
			d += ab.x * ab.x
		if ab.y > 0.0:
			d += ab.y * ab.y
		dists[k] = d
		best = minf(best, d)
	# The nearest, with its ties (Godot breaks them by alignment), and a
	# margin for the rounding of Godot's single-precision sums.
	var lim := best + maxf(1e-3, best * 1e-4)
	for k in dists:
		if dists[k] <= lim and _proxy_ctls[k] == null:
			_ctl(_proxy_idx[k])


## Per slot: 1 when Godot's walk takes its Control (shown at its last
## placement, focus mode ALL, enabled).
func _valid_slots() -> PackedByteArray:
	var v: PackedByteArray = rt.call("placed_shown", _proxy_idx)
	var dis: PackedByteArray = _flags[1]
	for k in _proxy_idx.size():
		if v[k] == 0:
			continue
		var i := _proxy_idx[k]
		var c = _proxy_ctls[k]
		var fm: int
		if c != null:
			if not (c as Control).is_visible_in_tree():
				v[k] = 0
				continue
			fm = (c as Control).focus_mode
		else:
			fm = Control.FOCUS_NONE if (i < dis.size() and dis[i] == 1) else \
				(Control.FOCUS_NONE if UxmlParts._attr(_lazy[i], "focusable") == "false" else Control.FOCUS_ALL)
		if fm != Control.FOCUS_ALL:
			v[k] = 0
	return v


func _on_focus(el: UxmlElement, on: bool) -> void:
	# The editor reports :focus for its field (UxmlDocument._wire).
	var owner := el.part_of if el.part_of != null and el.part_role == "editor" else el
	doc._set_state(owner, "focus", on)
	var i := index_of(el)
	if rt != null and i >= 0 and int(rt.call("kind_of", i)) == K_BUTTON:
		rt.call("set_focused", i, on)
		_draw_req = true
		queue()


## Places the interaction Controls at their elements' rects (inside the
## clips of their clipping ancestors) and shows those that are shown: one
## native call for all of them (UxmlRuntimeV2.place_states).
func _place_proxies() -> void:
	if _proxy_idx.is_empty():
		return
	var st: Array = rt.call("place_states", _proxy_idx)
	var rects: PackedVector2Array = st[0]
	var shown_f: PackedByteArray = st[1]
	var ops: PackedFloat32Array = st[2]
	var which: PackedInt32Array = st[3]
	if which.is_empty():
		return
	# Positions and sizes in one native call; what it leaves: the
	# visibility changes, the editors.
	var vis_k: PackedInt32Array = ClassDB.class_call_static(&"UxmlRuntimeV2", &"apply_rects", _proxy_ctls, rects, shown_f, which, _proxy_edit)
	for k in vis_k:
		var c: Control = _proxy_ctls[which[k]]  # vis_k: made Controls only
		var shown := shown_f[k] == 1 and rects[k * 4 + 3].x > 0.0 and rects[k * 4 + 3].y > 0.0
		if c.visible != shown:
			c.visible = shown
		if not shown and c.has_focus():
			c.release_focus()
	if editors.is_empty():
		return
	for k in which.size():
		var w := which[k]
		if _proxy_edit[w] == 0:
			continue
		var i := _proxy_idx[w]
		var c: Control = _proxy_ctls[w]
		var wrap: Control = _edit_wrap[i]
		var r: Rect2 = rt.call("local_rect", i)
		var host := Rect2(rects[k * 4], rects[k * 4 + 1])
		var at := r.position
		var wp: Vector2
		# An ancestor with overflow: hidden clips the editor (runtime v1's
		# Controls clip their children, also where the editor is taller than
		# its rect at its minimum size): the Control it sits in is that clip,
		# unless the clip holds the editor's rect and its minimum size.
		var clip: Rect2 = rt.call("clip_of", i)
		var full := Rect2(host.position, host.size.max(c.get_combined_minimum_size()))
		var clipped := clip.size.x >= 0.0 and not clip.encloses(full)
		if clipped:
			wp = clip.position
			at = host.position - clip.position
			if wrap.size != clip.size:
				wrap.size = clip.size
		else:
			wp = _editor_frame(i, host.position - r.position)
		if wrap.clip_contents != clipped:
			wrap.clip_contents = clipped
		if wrap.position != wp:
			wrap.position = wp
		if c.position != at:
			c.position = at
		if c.size != r.size:
			c.size = r.size
		# The editor draws: it stays at its rect (its own clip), with the
		# opacity of its ancestors (v1 nests it in their Controls).
		var a := ops[k]
		if c.modulate.a != a:
			c.modulate = Color(1, 1, 1, a)
		_editor_shown[i] = shown_f[k] == 1
		var want := shown_f[k] == 1 and bool(c.get_meta(&"uxml_v2_visible", true))
		if c.visible != want:
			c.visible = want


## Where the Control editor `i` sits in goes in the root box: the position
## whose global transform is that of runtime v1's field Control the editor
## is nested in (Godot composes the transforms of nested Controls in f32;
## another sum moves the text by a device pixel on a scaled panel). `pos`:
## the field's host position.
func _editor_frame(i: int, pos: Vector2) -> Vector2:
	if not doc._scaled or not doc.is_inside_tree():
		return pos
	var chain: Array = []
	var k: int = cascade._parent[i]
	while k > 0:
		chain.append(k)
		k = cascade._parent[k]
	var root_g := doc._root_box.get_global_transform()
	var g := root_g
	for j in range(chain.size() - 1, -1, -1):
		var r: Rect2 = rt.call("local_rect", chain[j])
		g = g * Transform2D(0.0, r.position)
	var want := g.origin
	var p := root_g.affine_inverse() * want
	for n in 8:
		var got := (root_g * Transform2D(0.0, p)).origin
		if got == want:
			return p
		if got.x != want.x:
			p.x = ClassDB.class_call_static(&"UxmlRuntimeV2", &"f32_step", p.x, 1 if got.x < want.x else -1)
		if got.y != want.y:
			p.y = ClassDB.class_call_static(&"UxmlRuntimeV2", &"f32_step", p.y, 1 if got.y < want.y else -1)
	return pos


# ---------------------------------------------------------------------------
# Editors (TextField): real LineEdit / TextEdit Controls, applied by the
# applier as runtime v1 applies them
# ---------------------------------------------------------------------------

## Applies the editors whose style (`changed`) or disabled and display
## flags changed since their last apply.
func _apply_editors(changed: PackedInt32Array) -> void:
	if editors.is_empty():
		return
	var dis: PackedByteArray = _flags[1]
	var gone: PackedByteArray = _flags[2]
	var ch := {}
	for i in changed:
		ch[i] = true
	for i in editors:
		var c: Control = editors[i]
		var f := dis[i] * 2 + gone[i]
		if not ch.has(i) and c.has_meta(&"uxml_v2_flags") and int(c.get_meta(&"uxml_v2_flags")) == f:
			continue
		c.set_meta(&"uxml_v2_flags", f)
		var el: UxmlElement = cascade.els[i]
		var style: Dictionary = cascade._native.call("style_of", i)
		applier.apply(el, c, c, style, dis[i] == 1, gone[i] == 1)
		c.set_meta(&"uxml_v2_visible", c.visible)
		if not bool(_editor_shown.get(i, true)):
			c.visible = false


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


## [px, ratio] of a `translate` value (UxmlStyleApplier._apply_transform),
## or null for a value v1 reports.
func v2_translate(v) -> Variant:
	var t := UssValues.parse_translate(String(v))
	if not t["ok"]:
		return null
	return [t["px"], t["ratio"]]


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


## A Button's theme items and the locale its text is shaped in.
func v2_button_theme() -> Dictionary:
	return {
		"font_color": _bprobe.get_theme_color(&"font_color"),
		"font_disabled_color": _bprobe.get_theme_color(&"font_disabled_color"),
		"font_focus_color": _bprobe.get_theme_color(&"font_focus_color"),
		"line_spacing": _bprobe.get_theme_constant(&"line_spacing"),
		"outline_size": _bprobe.get_theme_constant(&"outline_size"),
		"font_outline_color": _bprobe.get_theme_color(&"font_outline_color"),
		"locale": TranslationServer.get_tool_locale() if Engine.is_editor_hint() else TranslationServer.get_locale(),
	}


## [font, size] of text element i: the font and size a Label (a Button) of
## runtime v1 draws with (UxmlStyleApplier._apply_themed_inner).
func v2_font(i: int, button: bool = false) -> Array:
	var el: UxmlElement = cascade.els[i]
	var style: Dictionary = cascade._native.call("style_of", i)
	var probe: Control = _bprobe if button else _probe
	applier._capture_base_font(probe)
	var font: Font = applier._font(probe, style, el)
	if applier.unity_line_metrics and not UxmlStyleApplier._has_url_font(style):
		font = applier._line_font(probe, font, style, el)
	var fs := applier._effective_font_size(probe, style, el)
	if font == null:
		font = probe.get_theme_font(&"font")
	# Unity's line height on a scaled panel (UxmlStyleApplier._set_line_fix).
	var lf := PackedFloat64Array()
	var ppp := applier.pixels_per_point
	if ppp != 1.0 and applier.unity_line_metrics and not UxmlStyleApplier._has_url_font(style) and fs > 0 and font != null:
		lf = PackedFloat64Array([font.get_height(fs),
			ceilf(UxmlStyleApplier.UNITY_LINE_EM * floorf(float(fs) * ppp + 0.5) - 0.001) / ppp])
	return [font, fs, lf]


## [box style, image style, image texture, text inset by the box] of
## element i with a background image (UxmlStyleApplier._apply_box for a
## box, _apply_themed_inner for a Label).
static var _URL_PROPS := PackedStringArray(["background-image"])


func v2_boxes(i: int, label: bool) -> Array:
	var el: UxmlElement = cascade.els[i]
	# The values, and the origin of the url() (the file it resolves against).
	var style: Dictionary = cascade._native.call("style_of_lite", i, _URL_PROPS)
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


## The text a Label shows elided at `width` (UxmlStyleApplier.elide_text).
func v2_elide(text: String, width: float, pos: String, font: Font, fs: int) -> String:
	return UxmlStyleApplier.elide_text(text, width, pos, font, fs)


## [mask box, mask material] of a rounded clip (UxmlClip.set_radii) with
## the inset `widths` (top, right, bottom, left).
func v2_mask(radii: PackedFloat64Array, widths: PackedFloat64Array) -> Array:
	var mask := UxmlBoxStyle.new()
	mask.bg_color = Color.WHITE
	mask.radii = radii
	mask.fill_inner = true
	mask.widths = widths
	mask.px = applier.pixels_per_point
	if _mask_material == null:
		var sh := Shader.new()
		sh.code = UxmlClip.MASK_SHADER
		_mask_material = ShaderMaterial.new()
		_mask_material.shader = sh
	return [mask, _mask_material]


# ---------------------------------------------------------------------------
# Lifetime
# ---------------------------------------------------------------------------

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
	if _menu_anchor != null and is_instance_valid(_menu_anchor):
		_menu_anchor.queue_free()
	_menu_anchor = null
	if _nav != null and is_instance_valid(_nav):
		_nav.glue = null
		if _nav.get_parent() != null:
			_nav.get_parent().remove_child(_nav)
		_nav.free()
	_nav = null
	_lazy = {}
	for c in [_probe, _bprobe] + proxies.values():
		if c != null and is_instance_valid(c):
			if c.get_parent() != null:
				c.get_parent().remove_child(c)
			c.free()
	for w in _edit_wrap.values():
		if is_instance_valid(w):
			if w.get_parent() != null:
				w.get_parent().remove_child(w)
			w.free()
	_edit_wrap = {}
	_probe = null
	_bprobe = null
	proxies = {}
	editors = {}
	_proxy_el = {}
	_hooked = []  # the behaviors hold the glue: no cycle left
	_restyled = {}
	_editor_shown = {}
	_proxy_idx = PackedInt32Array()
	if doc != null:
		if doc._root_box.gui_input.is_connected(_on_gui_input):
			doc._root_box.gui_input.disconnect(_on_gui_input)
			doc._root_box.mouse_exited.disconnect(_on_mouse_exited)
		doc._root_box.tooltip_text = ""
		# The maps of this load (runtime v1 builds its own).
		doc._controls.clear()
		doc._natives.clear()
		doc._by_name.clear()
		doc._el_names.clear()
		doc._parents.clear()
		doc._el_of.clear()
		# doc._states stay: a document that moves to runtime v1 keeps its
		# pseudo-states (runtime v1's behaviors set :checked again).
		doc._behaviors = {}
		doc._layout_hooks = []
		doc._post_layout = []
		doc._placeholder_fields = []
	if cascade != null:
		for el in cascade.els:
			el.changed = Callable()
	cascade = null
	applier = null
	factory = null
	hovered = {}
	active = {}
	_dirty = {}
	_pressed = null


func diagnostics() -> Array:
	return doc._doc.warnings + cascade.collect_warnings() + warnings + doc._rt_warnings + (rt.call("warnings") as Array)


func index_of(el: UxmlElement) -> int:
	if el == null or cascade == null:
		return -1
	return int(cascade.index.get(el, -1))


# ---------------------------------------------------------------------------
# Changes: model edits, pseudo-states, resizes
# ---------------------------------------------------------------------------

func _on_model_changed(el: UxmlElement) -> void:
	var b = doc._behaviors.get(el)
	if el == doc._quiet_field and el.changed_attribute == doc._quiet_attr:
		# set_field_value, set_field_placeholder (UxmlDocument._on_model_changed).
		b.on_quiet_change(doc._quiet_attr)
		return
	_dirty[el] = true
	if el.changed_attribute == "tabindex":
		ensure_all()
		doc._attrs.rebuild_focus_ring()
	if el.changed_attribute == "text" and el.local == "Label":
		var i := index_of(el)
		if i >= 0:
			var t = el.get_attribute("text")
			rt.call("set_text", i, "" if t == null else String(t))
	elif el.changed_attribute == "text" and b == null and UxmlDocument._OWN_TEXT.has(el.local):
		set_text(el, UxmlControlFactory.text_of(el, true))
	if b != null:
		b.on_model_changed()
	queue()


## A behavior changed the text of part `p` (its `text` attribute).
func part_text(p: UxmlElement) -> void:
	set_text(p, UxmlParts._attr(p, "text"))


func queue() -> void:
	if _queued:
		return
	_queued = true
	# Bounded per frame as runtime v1's restyles (UxmlDocument._restyles_this_frame).
	if doc._restyles_this_frame(_flush):
		_flush.call_deferred()


func _flush() -> void:
	if _queued and rt != null:
		restyle()


## Runs the cascade for what changed, restyles, lays out and draws. False
## when the document must move to runtime v1. A restyle with nothing to do
## (no dirty element, no new state or option, no layout request) returns at
## once (runtime v1's _quiet).
func restyle() -> bool:
	_queued = false
	if rt == null:
		return true
	if _dirty.is_empty() and not _restyle_all and not _layout_req and not _draw_req and doc._opt_rev == _seen_rev:
		return true
	var layout_req := _layout_req
	_layout_req = false
	_draw_req = false
	var changed := PackedInt32Array()
	if not _dirty.is_empty() or _restyle_all or doc._opt_rev != _seen_rev:
		_seen_rev = doc._opt_rev
		changed = _restyle_pass()
		if rt == null:
			return false
	_layout(layout_req, not changed.is_empty())
	if rt == null:
		return false
	rt.call("draw")
	doc.diagnostics = diagnostics()
	return true


## The cascade and the records of what changed; the indices whose computed
## style changed (empty when the document moved to runtime v1: rt is null).
func _restyle_pass() -> PackedInt32Array:
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
	if why.is_empty() and not _diag_free():
		why = "a style diagnostic"
	if not why.is_empty():
		_fail(why)
		return PackedInt32Array()
	_flags = cascade.effective_flags()
	_restyled = {}
	for i in changed:
		_restyled[i] = true
	_apply_editors(changed)
	_sync_disabled()
	return changed


## Lays out when something the layout reads changed (or `force`); the
## layout hooks of the behaviors (a slider's dragger follows its track, the
## ScrollViews place their Scrollers) run after a layout that moved a rect
## or a restyle (`restyled`), and can change inline styles, which restyle
## and lay out again (as runtime v1's _post_layout). The interaction
## Controls follow.
func _layout(force: bool = false, restyled: bool = true) -> void:
	var t0 := Time.get_ticks_usec()
	var moved: bool = rt.call("layout_if_needed", doc._layout_host(), force or _editor_measures_changed())
	t0 = _step("layout: pass", t0)
	if (moved or force) and _editor_insets():
		# The resolved insets changed what an editor measures.
		rt.call("layout_if_needed", doc._layout_host(), true)
		t0 = _step("layout: editor insets pass", t0)
	if not moved and not restyled and not force:
		# Position offsets (a scroll, collection rows) move the interaction
		# Controls without a restyle.
		if rt.call("take_vis_changed"):
			_place_proxies()
		return
	if not moved and not force:
		# A paint-only restyle: the hooks whose parts were restyled, and
		# the interaction Controls only when a visibility changed.
		for b in _hooked:
			if not b is V2ScrollViewBehavior:
				b.v2_after_layout()
		if not _dirty.is_empty():
			moved = true  # a hook wrote a style: the full path below
		elif rt.call("take_vis_changed"):
			_place_proxies()
			return
		else:
			return
	for k in 4:
		var hooked := false
		for b in _hooked:
			if b is V2ScrollViewBehavior:
				b.after_layout()
				hooked = true
			else:
				hooked = b.v2_after_layout() or hooked
		t0 = _step("layout: hooks", t0)
		if not hooked or _dirty.is_empty():
			break
		var ch := _restyle_pass()
		t0 = _step("layout: hook restyle", t0)
		if rt == null:
			return
		if rt.call("layout_if_needed", doc._layout_host(), false):
			moved = true
		t0 = _step("layout: hook pass", t0)
		restyled = restyled or not ch.is_empty()
	rt.call("take_vis_changed")
	_place_proxies()
	t0 = _step("layout: place", t0)
	elide_placeholders()
	_step("layout: elide", t0)


## text-overflow: ellipsis on a text field elides its placeholder at the
## width of its editor (runtime v1's _update_elision after a placement).
func elide_placeholders() -> void:
	if doc._v2 != self:
		return
	for b in doc._placeholder_fields:
		b.elide_placeholder()


## The insets the layout resolved (padding and borders on the pixel grid)
## become the editors' stylebox margins, as runtime v1's placement hands
## them to UxmlStyleApplier.apply_resolved_insets. True when that changed
## what an editor measures.
func _editor_insets() -> bool:
	if editors.is_empty():
		return false
	for i in editors:
		var ins: Array = rt.call("insets_of", i)
		if ins.size() == 2:
			applier.apply_resolved_insets(editors[i], ins[0], ins[1])
	return _editor_measures_changed()


## The editors' minimum sizes (what the layout measures of them) changed
## since the last layout.
func _editor_measures_changed() -> bool:
	var changed := false
	for i in editors:
		var c: Control = editors[i]
		var m := c.get_combined_minimum_size()
		if m != c.get_meta(&"uxml_v2_min", Vector2(-1, -1)):
			c.set_meta(&"uxml_v2_min", m)
			changed = true
	return changed


## Whether element `x` was restyled by the last restyle pass.
func restyled(x: UxmlElement) -> bool:
	return _restyled.has(index_of(x))


## The disabled state of the interaction Controls (runtime v1's
## UxmlStyleApplier.apply_flags: disabled natives, no focus), when the
## disabled flags changed.
func _sync_disabled() -> void:
	if proxies.is_empty():
		return
	var dis: PackedByteArray = _flags[1]
	if dis == _last_dis:
		return
	_last_dis = dis
	for i in proxies:
		if editors.has(i):
			continue
		var c: Control = proxies[i]
		var off := dis[i] == 1
		if c is BaseButton:
			(c as BaseButton).disabled = off
		elif c is UxmlToggle:
			(c as UxmlToggle).disabled = off
		var fm: int = Control.FOCUS_NONE if off else int(c.get_meta("uxml_focus", c.focus_mode))
		if c.focus_mode != fm:
			c.focus_mode = fm
			if off and c.has_focus():
				c.release_focus()


func is_disabled(el: UxmlElement) -> bool:
	var i := index_of(el)
	if i < 0:
		return false
	return (cascade.effective_flags()[1] as PackedByteArray)[i] == 1


func set_text(el: UxmlElement, text: String) -> void:
	var i := index_of(el)
	if i >= 0 and rt.call("set_text", i, text):
		var c = proxies.get(i)
		if c is Button:
			(c as Button).accessibility_name = text
		_draw_req = true
		queue()


func refresh() -> void:
	_restyle_all = true
	for el in cascade.els:
		_dirty[el] = true
	queue()


## The oversampling of the text: a scaled panel rasterizes its glyphs at
## the font size times the canvas scale, as runtime v1's Labels under the
## root box (CanvasItem.oversampling_with_scale); 0 (the viewport's) when
## not scaled.
func _oversampling() -> float:
	if not doc._scaled or not doc.is_inside_tree():
		return 0.0
	var sc := doc._root_box.get_global_transform().get_scale()
	var vp := doc.get_viewport()
	return maxf(absf(sc.x), absf(sc.y)) * (vp.get_oversampling() if vp != null else 1.0)


## Panel scaling changed (UxmlDocument._on_panel_settings_changed, a resize
## of a scaled panel, entering the tree): the new grid (records made again,
## the editors applied again) and oversampling, laid out and drawn.
func rescale() -> void:
	if rt == null:
		return
	var regrid := applier.pixels_per_point != doc._grid_ppp
	applier.set_pixels_per_point(doc._grid_ppp)
	var why: String = rt.call("set_scale", doc._grid_ppp, _oversampling())
	if why.is_empty() and not _diag_free():
		why = "a style diagnostic"
	if not why.is_empty():
		_fail(why)
		return
	if regrid:
		for i in editors:
			(editors[i] as Control).remove_meta(&"uxml_v2_flags")
		_apply_editors(PackedInt32Array())
	relayout()


## A resize (NOTIFICATION_RESIZED): lays out and draws now.
func relayout() -> void:
	if rt == null:
		return
	_layout(true)
	if rt != null:
		rt.call("draw")


## UxmlDocument.relayout(): the next restyle lays out (code may have
## changed what an editor measures).
func request_layout() -> void:
	_layout_req = true
	queue()


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


# ---------------------------------------------------------------------------
# Pointer input from the core's hit test
# ---------------------------------------------------------------------------

## :hover and :active from the core's hit test: the element under the
## pointer and its ancestors (Unity's hover chain). A press goes to the
## interactive element under the pointer (its control, for a part): it
## takes the focus and does what the control does on a click.
func _on_gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		_set_chain(hovered, _chain_at(mm.position))
		_update_tooltip(mm.position)
		if _pressed != null:
			var b = doc._behaviors.get(_pressed)
			if b is V2SliderBehavior or b is V2ScrollViewBehavior or b is V2MinMaxBehavior:
				b.v2_motion(mm)
	elif ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed \
			and (ev as InputEventMouseButton).button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN,
				MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
		_wheel(ev as InputEventMouseButton)
	elif ev is InputEventPanGesture:
		_wheel_by((ev as InputEventPanGesture).position, (ev as InputEventPanGesture).delta)
	elif ev is InputEventMouseButton and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := ev as InputEventMouseButton
		if mb.pressed:
			_set_chain(active, _chain_at(mb.position))
			_press(mb)
		else:
			_set_chain(active, {})
			_release(mb)


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


## The innermost element with an interaction Control or a behavior at
## `p`, its control for a part.
func _target_at(p: Vector2) -> UxmlElement:
	var i: int = rt.call("pick", p, true)
	var els: Array = cascade.els
	var par: PackedInt32Array = cascade._parent
	while i > 0:
		var el: UxmlElement = els[i]
		if proxies.has(i) or _lazy.has(i) or (el.part_of == null and doc._behaviors.has(el)):
			return el
		i = par[i]
	return null


func _press(mb: InputEventMouseButton) -> void:
	var el := _target_at(mb.position)
	_pressed = el
	if el == null:
		return
	var i := index_of(el)
	var c: Control = _ctl(i)
	if is_disabled(el):
		return
	var b = doc._behaviors.get(el)
	if el.part_role == "content" and _collection_of(el) != null:
		# A press on the rows of a collection view (its content container
		# is the innermost element with a Control under them).
		var cb = doc._behaviors.get(_collection_of(el))
		if cb is V2CollectionBehavior:
			cb.v2_press(mb)
			return
	if b is V2SliderBehavior or b is V2MinMaxBehavior:
		b.v2_press(mb)
		return
	if b is V2ScrollViewBehavior:
		if not b.v2_press(mb):
			_pressed = null
		if c != null and c.focus_mode != Control.FOCUS_NONE:
			c.grab_focus()
		return
	if c != null and c.focus_mode != Control.FOCUS_NONE:
		c.grab_focus()
	if b is V2PopupBehavior:
		b.open_menu()
	elif b is UxmlInputBehaviors.TextFieldBehavior:
		var ed = b.native()
		if ed is Control and (ed as Control).visible:
			(ed as Control).grab_focus()


func _release(mb: InputEventMouseButton) -> void:
	var el := _pressed
	_pressed = null
	if el == null:
		return
	var b = doc._behaviors.get(el)
	if b is V2SliderBehavior or b is V2ScrollViewBehavior or b is V2MinMaxBehavior:
		b.v2_release()
		return
	if el.part_role == "content" and _collection_of(el) != null:
		var cb = doc._behaviors.get(_collection_of(el))
		if cb is V2CollectionBehavior:
			cb.v2_release(mb)
			return
	if is_disabled(el) or _target_at(mb.position) != el:
		return
	var c: Control = _ctl(index_of(el))
	if c is UxmlToggle:
		(c as UxmlToggle)._activate()
	elif c is Button:
		(c as Button).pressed.emit()


## The wheel scrolls the innermost ScrollView under the pointer that moves
## (Unity ScrollView.OnScrollWheel: at a bound the event goes on to an
## outer ScrollView).
func _wheel(mb: InputEventMouseButton) -> void:
	var f := mb.factor if mb.factor > 0.0 else 1.0
	var d := Vector2.ZERO
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_DOWN:
			d.y = f
		MOUSE_BUTTON_WHEEL_UP:
			d.y = -f
		MOUSE_BUTTON_WHEEL_RIGHT:
			d.x = f
		MOUSE_BUTTON_WHEEL_LEFT:
			d.x = -f
	_wheel_by(mb.position, d)


func _wheel_by(p: Vector2, delta: Vector2) -> void:
	var i: int = rt.call("pick", p, true)
	var els: Array = cascade.els
	var par: PackedInt32Array = cascade._parent
	while i > 0:
		var el: UxmlElement = els[i]
		var b = doc._behaviors.get(el)
		if b is V2ScrollViewBehavior and el.part_of == null:
			var before: Vector2 = b.offset()
			b.wheel(delta)
			if b.offset() != before or UxmlParts._attr(el, "nested-interaction-kind", "Default") == "StopScrolling":
				doc._root_box.accept_event()
				return
		i = par[i]


## A focused ScrollView (focusable="true") scrolls on the navigation keys.
func _on_scroll_key(ev: InputEvent, el: UxmlElement) -> void:
	var b = doc._behaviors.get(el)
	var c: Control = proxies.get(index_of(el))
	if b != null and c != null and b.key_scroll(ev):
		c.accept_event()


## The editor of a text field: the pointer over it is over its field.
func _on_editor_hover(el: UxmlElement) -> void:
	var i := index_of(el)
	if i < 0 or rt == null:
		return
	var r: Rect2 = rt.call("host_rect", i)
	_set_chain(hovered, _chain_at(r.get_center()))


func _on_editor_input(ev: InputEvent, el: UxmlElement) -> void:
	var mb := ev as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			var i := index_of(el)
			var r: Rect2 = rt.call("host_rect", i)
			_set_chain(active, _chain_at(r.get_center()))
		else:
			_set_chain(active, {})


## The tooltip of the element under the pointer (Unity: the innermost
## element with a tooltip), shown by the root box.
func _update_tooltip(p: Vector2) -> void:
	var i: int = rt.call("pick", p, true)
	var els: Array = cascade.els
	var par: PackedInt32Array = cascade._parent
	var tip := ""
	var at: UxmlElement = null
	while i > 0:
		var el: UxmlElement = els[i]
		if bool(rt.call("is_elided", i)) and UxmlParts._attr(el, "display-tooltip-when-elided", "true") != "false":
			# display-tooltip-when-elided: the full text (UxmlStyleApplier._elided_tooltip).
			tip = String(rt.call("get_text", i))
			at = el
			break
		var t = el.get_attribute("tooltip")
		if t != null and not String(t).is_empty():
			tip = String(t)
			at = el
			break
		i = par[i]
	if at != _tooltip_el:
		_tooltip_el = at
		doc._root_box.tooltip_text = tip


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


## A transient Control at element `el`'s rect: a popup menu's anchor.
func anchor_at(el: UxmlElement) -> Control:
	if _menu_anchor != null and is_instance_valid(_menu_anchor):
		_menu_anchor.queue_free()
	var a := Control.new()
	a.name = "uxml-v2-anchor"
	a.mouse_filter = Control.MOUSE_FILTER_IGNORE
	a.focus_mode = Control.FOCUS_NONE
	var r: Rect2 = rt.call("host_rect", index_of(el))
	a.position = r.position
	a.size = r.size
	doc._root_box.add_child(a)
	_menu_anchor = a
	return a


# ---------------------------------------------------------------------------
# Element API
# ---------------------------------------------------------------------------

func computed_style(el: UxmlElement) -> Dictionary:
	var i := index_of(el)
	if i < 0:
		return {}
	var st: Dictionary = cascade._native.call("style_of", i)
	if el.has_meta(&"uxml_translate_native"):
		# The scroll offset (content, draggers) is a position offset of the
		# table, runtime v1's inline translate: its computed entry, as the
		# last declaration of the inline style.
		var t: Vector2 = el.get_meta(&"uxml_translate", Vector2.ZERO)
		if t != Vector2.ZERO:
			var n := 0
			for d in String(el.get_attribute("style") if el.has_attribute("style") else "").split(";"):
				if not d.strip_edges().is_empty():
					n += 1
			st = st.duplicate()
			st["translate"] = {"value": "%s %s" % [UxmlContainerParts.px(t.x), UxmlContainerParts.px(t.y)],
				"origin": {"kind": "inline", "decl_index": n}}
	return st


## The edge lengths of `el`'s computed style that the slider hooks read
## (UxmlInputParts.layout_styles: margins, borders), as computed_style's
## entries ({prop: {value}}), without making the whole style.
const _HOOK_PROPS := ["margin-left", "margin-right", "border-left-width", "border-right-width"]


func style_lengths(el: UxmlElement) -> Dictionary:
	var i := index_of(el)
	if i < 0:
		return {}
	return cascade._native.call("style_values", i, PackedStringArray(_HOOK_PROPS))


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


func is_shown(el: UxmlElement) -> bool:
	var i := index_of(el)
	return i >= 0 and rt != null and bool(rt.call("is_shown", i))


## The border-box size of `el` as runtime v1's Control has it: the size of
## its last layout (a Control keeps it under display: none), else zero.
func size_of(el: UxmlElement) -> Vector2:
	var i := index_of(el)
	return Vector2.ZERO if i < 0 or rt == null else rt.call("last_size", i)


func insets(el: UxmlElement) -> Array:
	var i := index_of(el)
	if i < 0:
		return [Vector2.ZERO, Vector2.ZERO]
	var r: Array = rt.call("insets_of", i)
	return r if r.size() == 2 else [Vector2.ZERO, Vector2.ZERO]


func element_at(local_point: Vector2, respect_picking: bool, include_parts: bool = true) -> UxmlElement:
	var p := doc._root_box.get_transform().affine_inverse() * local_point
	var i: int = rt.call("pick", p, respect_picking)
	if i <= 0:
		return null
	var hit: UxmlElement = cascade.els[i]
	if not include_parts:
		while hit.part_of != null:
			hit = hit.part_of
	return hit


# ---------------------------------------------------------------------------
# Behaviors that read the geometry of parts: runtime v1's, with the part
# rects of the table instead of part Controls
# ---------------------------------------------------------------------------

## Slider and SliderInt: runtime v1's SliderBehavior; the pointer arrives
## from the core's hit test in root box coordinates, and the sizes of the
## drag container and the dragger are the table's.
class V2SliderBehavior extends UxmlInputBehaviors.SliderBehavior:
	var glue

	func size_of(x: UxmlElement) -> Vector2:
		return glue.size_of(x)

	func style_of(x: UxmlElement) -> Dictionary:
		return glue.computed_style(x)

	func is_disabled() -> bool:
		return glue.is_disabled(el)

	var _hook_key: Array = []
	var _hook_idx := PackedInt32Array()
	var _hook_ep := -1

	## The layout hook (runtime v1's _after_layout): true when a style of
	## the dragger changed. Runtime v1 runs it for the subtrees its
	## placement changed (UxmlDocument._run_layout_hooks): here when the
	## sizes it reads changed (a value change places the dragger itself).
	func v2_after_layout() -> bool:
		# The sizes it reads changed in no layout since its last run, and
		# its dragger was not restyled: nothing to do (no GDScript reads).
		if _hook_idx.is_empty():
			_hook_idx = PackedInt32Array([glue.index_of(part("drag-container")), glue.index_of(part("dragger"))])
		var ep: int = glue.rt.call("size_epoch", _hook_idx)
		if ep == _hook_ep and not glue._restyled.has(_hook_idx[1]):
			return false
		_hook_ep = ep
		var key := [size_of(part("drag-container")), size_of(part("dragger"))]
		if key == _hook_key and not glue.restyled(part("dragger")):
			return false
		_hook_key = key
		return UxmlInputParts.layout_styles(el, size_of, glue.style_lengths, _parts)

	func _local(x: UxmlElement, p: Vector2) -> Vector2:
		var r = glue.host_rect(x)
		return p if r == null else p - (r as Rect2).position

	func v2_press(mb: InputEventMouseButton) -> void:
		var c := native() as UxmlSlider
		if c == null or is_disabled():
			return
		var dc := part("drag-container")
		if dc == null:
			return
		var p := _local(dc, mb.position)
		if not Rect2(Vector2.ZERO, size_of(dc)).has_point(p):
			if c.focus_mode != Control.FOCUS_NONE:
				c.grab_focus()
			return
		if c.focus_mode != Control.FOCUS_NONE:
			c.grab_focus()
		_pressed = true
		set_state(dc, "active", true)
		_start = p
		_last = p
		_drag_dir = DRAG_NONE
		_on_click()
		if not is_zero_approx(page_size()):
			_start_repeat(c)

	func v2_motion(mm: InputEventMouseMotion) -> void:
		if not _pressed:
			return
		_last = _local(part("drag-container"), mm.position)
		if _drag_dir == DRAG_NONE:
			_drag_dir = DRAG_FREE
		if _drag_dir == DRAG_FREE:
			_on_drag()

	func v2_release() -> void:
		_release()

	func _on_repeat() -> void:
		if not _pressed:
			_repeat.stop()
			return
		_repeat.wait_time = REPEAT_MS / 1000.0
		if Rect2(Vector2.ZERO, size_of(part("drag-container"))).has_point(_last):
			_on_click()

	func _on_click() -> void:
		if _drag_dir == DRAG_FREE:
			return
		var dcs := size_of(part("drag-container"))
		var dgs := size_of(part("dragger"))
		if part("dragger") == null:
			return
		var horizontal := not vertical()
		if _drag_dir == DRAG_NONE:
			if is_zero_approx(page_size()):
				var length := dcs.x if horizontal else dcs.y
				var dlen := dgs.x if horizontal else dgs.y
				var total := length - dlen
				var t := _translate()
				var target := (_start.x if horizontal else _start.y) - dlen / 2.0
				var pos := maxf(0.0, minf(target, total))
				var at := Vector2(pos, t.y) if horizontal else Vector2(t.x, pos)
				_set_translate(at)
				_drag_start = Rect2(at, dgs)
				_drag_dir = DRAG_FREE
				_from_drag(length, dlen, pos)
				return
			_drag_start = Rect2(_translate(), dgs)
		var t2 := _translate()
		if horizontal:
			_from_click(dcs.x, dgs.x, t2.x, _last.x)
		else:
			_from_click(dcs.y, dgs.y, t2.y, _last.y)

	func _on_drag() -> void:
		var dcs := size_of(part("drag-container"))
		var dgs := size_of(part("dragger"))
		var delta := _last - _start
		if not vertical():
			_from_drag(dcs.x, dgs.x, _drag_start.position.x + delta.x)
		else:
			_from_drag(dcs.y, dgs.y, _drag_start.position.y + delta.y)

	func _lerp_dir(position_t: float) -> float:
		var t := 1.0 - position_t if vertical() else position_t
		var a := low()
		var b := high()
		if inverted():
			var tmp := a
			a = b
			b = tmp
		var v := lerpf(a, b, t)
		if integer():
			return UxmlNumeric.round_even(v)
		var span := size_of(part("drag-container")).x - size_of(part("dragger")).x
		var min_diff := 0.0 if span == 0.0 else absf((high() - low()) / span)
		var dec := 0
		if min_diff != 0.0:
			dec = clampi(-floori(log(min_diff) / log(10.0)), 0, 15)
		return UxmlNumeric.round_away(v, dec)


## DropdownField: runtime v1's PopupBehavior; the menu opens under the
## input part's rect.
class V2PopupBehavior extends UxmlInputBehaviors.PopupBehavior:
	var glue

	func is_disabled() -> bool:
		return glue.is_disabled(el)

	func open_menu() -> void:
		if _menu != null and is_instance_valid(_menu):
			return
		var input := part("input")
		var anchor: Control = glue.anchor_at(input if input != null else el)
		_menu = UxmlPopupMenu.open(anchor, items(), index(), doc.theme_path, doc)
		_menu.chosen.connect(choose.bind(true))
		_menu.popup_hide.connect(_on_menu_closed)
		set_state(el, "active", true)


## ScrollView: runtime v1's ScrollViewBehavior with the sizes and rects of
## the table; the Scrollers take the pointer here (the buttons step by a
## page, the track pages toward the pointer, the dragger follows it).
class V2ScrollViewBehavior extends UxmlContainerBehaviors.ScrollViewBehavior:
	var glue
	var _drag_sc: UxmlElement = null  # the Scroller whose dragger is dragged
	var _grab := 0.0
	## The elements whose translate is a position offset of the table (the
	## scroll offset out of the cascade): the content, the draggers.
	var _tl_els: Array = []
	var _tl_idx := PackedInt32Array()
	var _tl_last := PackedVector2Array()

	func setup() -> void:
		var content := UxmlContainerParts.get_part(el, "content")
		if content != null:
			_tl_els.append(content)
		for role in ["vertical-scroller", "horizontal-scroller"]:
			var sc := UxmlContainerParts.get_part(el, role)
			if sc == null:
				continue
			for r in ["dragger", "dragger-border"]:
				var x := UxmlContainerParts.get_part(sc, r)
				if x != null:
					_tl_els.append(x)
		for x in _tl_els:
			x.set_meta(&"uxml_translate_native", true)
			_tl_idx.append(glue.index_of(x))
		super()

	## The translates of the content and the draggers to the table.
	func _push() -> void:
		if _tl_idx.is_empty() or glue.rt == null:
			return
		var offs := PackedVector2Array()
		for x in _tl_els:
			offs.append(x.get_meta(&"uxml_translate", Vector2.ZERO))
		if offs == _tl_last:
			return
		_tl_last = offs
		glue.rt.call("set_offsets", _tl_idx, offs, true)
		glue._draw_req = true
		glue.queue()

	func set_offset(off: Vector2) -> void:
		super(off)
		_push()

	func after_layout() -> void:
		super()
		_push()

	func _size_of(x: UxmlElement):
		return null if x == null else glue.size_of(x)

	func _rect_of(x: UxmlElement):
		if x == null or not glue.is_shown(x):
			return null
		return glue.rt.call("local_rect", glue.index_of(x))

	## Unity ScrollView.ScrollTo of `child`: an interaction Control of the
	## document, or an element.
	func scroll_to(child) -> void:
		var x: UxmlElement = child if child is UxmlElement else glue._proxy_el.get(child)
		if x != null:
			scroll_to_element(x)

	func scroll_to_element(x: UxmlElement) -> void:
		var cr = glue.host_rect(_content)
		var xr = glue.host_rect(x)
		var vsz = _size_of(_vp)
		if cr == null or xr == null or vsz == null:
			return
		var inside := false
		var q := x
		while q != null:
			if q == _content:
				inside = true
				break
			q = glue.parent_of(q)
		if not inside:
			return
		# Both rects include the content's translate: the difference is the
		# child's place in the content.
		var r := Rect2((xr as Rect2).position - (cr as Rect2).position, (xr as Rect2).size)
		var off := offset()
		var view: Vector2 = vsz
		if r.position.y < off.y:
			off.y = r.position.y
		elif r.end.y > off.y + view.y:
			off.y = minf(r.position.y, r.end.y - view.y)
		if r.position.x < off.x:
			off.x = r.position.x
		elif r.end.x > off.x + view.x:
			off.x = minf(r.position.x, r.end.x - view.x)
		_pending = null
		set_offset(off)

	## The Scrollers follow the offset (runtime v1's ScrollerBehavior.refresh).
	func _sync_scrollers() -> void:
		for sc in [_vs, _hs]:
			if sc != null:
				UxmlContainerParts.update_scroller(sc, _size_of)
		_push()

	## A press on a Scroller of this view; false when it is not on one.
	func v2_press(mb: InputEventMouseButton) -> bool:
		for sc in [_vs, _hs]:
			if sc == null or not glue.is_shown(sc):
				continue
			var r = glue.host_rect(sc)
			if r == null or not (r as Rect2).has_point(mb.position):
				continue
			if glue.is_disabled(sc):
				return true
			var axis := 1 if sc == _vs else 0
			for role in ["low-button", "high-button"]:
				var bt := UxmlContainerParts.get_part(sc, role)
				var br = glue.host_rect(bt) if bt != null else null
				if br != null and (br as Rect2).has_point(mb.position):
					_step(sc, -1.0 if role == "low-button" else 1.0)
					return true
			var dg := UxmlContainerParts.get_part(sc, "dragger")
			var dr = glue.host_rect(dg) if dg != null else null
			if dr != null and (dr as Rect2).has_point(mb.position):
				_drag_sc = sc
				_grab = mb.position[axis] - (dr as Rect2).position[axis]
				return true
			# The track pages toward the pointer.
			if dr != null:
				_step(sc, -1.0 if mb.position[axis] < (dr as Rect2).position[axis] else 1.0)
			return true
		return false

	func v2_motion(mm: InputEventMouseMotion) -> void:
		if _drag_sc == null:
			return
		var axis := 1 if _drag_sc == _vs else 0
		var cr = glue.host_rect(UxmlContainerParts.get_part(_drag_sc, "drag-container"))
		var gs = _size_of(UxmlContainerParts.get_part(_drag_sc, "dragger"))
		if cr == null or gs == null:
			return
		var track: float = (cr as Rect2).size[axis] - (gs as Vector2)[axis]
		if track <= 0.0:
			return
		var t := clampf((mm.position[axis] - _grab - (cr as Rect2).position[axis]) / track, 0.0, 1.0)
		var off := offset()
		off[axis] = t * scroll_range()[axis]
		_pending = null
		set_offset(off)

	func v2_release() -> void:
		_drag_sc = null

	## One page of Scroller `sc` (Unity's ScrollerBehavior.page()).
	func _step(sc: UxmlElement, dir: float) -> void:
		var vertical: bool = sc == _vs
		var p := UssValues.parse_number(UxmlParts._attr(el, "vertical-page-size" if vertical else "horizontal-page-size", "-1"))
		if is_nan(p) or p < 0.0:
			var gs = _size_of(UxmlContainerParts.get_part(sc, "dragger"))
			p = 20.0 if gs == null else maxf(1.0, ((gs as Vector2).y if vertical else (gs as Vector2).x) * 0.1)
		var off := offset()
		if vertical:
			off.y += dir * p
		else:
			off.x += dir * p
		_pending = null
		set_offset(off)


## MinMaxSlider: runtime v1's MinMaxBehavior with the table's part rects.
class V2MinMaxBehavior extends UxmlInputBehaviors.MinMaxBehavior:
	var glue
	var _hook_key: Array = []
	var _hook_idx := PackedInt32Array()
	var _hook_ep := -1

	func size_of(x: UxmlElement) -> Vector2:
		return glue.size_of(x)

	func style_of(x: UxmlElement) -> Dictionary:
		return glue.computed_style(x)

	func is_disabled() -> bool:
		return glue.is_disabled(el)

	func v2_after_layout() -> bool:
		if _hook_idx.is_empty():
			_hook_idx = PackedInt32Array([glue.index_of(part("input")), glue.index_of(part("thumb-min")), glue.index_of(part("thumb-max")), glue.index_of(part("dragger"))])
		var ep: int = glue.rt.call("size_epoch", _hook_idx)
		if ep == _hook_ep and not glue._restyled.has(_hook_idx[3]):
			return false
		_hook_ep = ep
		var key := [size_of(part("input")), size_of(part("thumb-min")), size_of(part("thumb-max"))]
		if key == _hook_key and not glue.restyled(part("dragger")):
			return false
		_hook_key = key
		return UxmlInputParts.layout_styles(el, size_of, glue.style_lengths, _parts)

	func _input_pos(p: Vector2) -> Vector2:
		var r = glue.host_rect(part("input"))
		return p if r == null else p - (r as Rect2).position

	func _has(role: String, p: Vector2) -> bool:
		var x := part(role)
		var r = glue.host_rect(x) if x != null else null
		return r != null and (r as Rect2).has_point(p)

	## SetSliderValueFromClick, with the thumbs' and dragger's rects.
	func v2_press(mb: InputEventMouseButton) -> void:
		var c := native() as UxmlSlider
		if c == null or is_disabled():
			return
		var p := _input_pos(mb.position)
		if not Rect2(Vector2.ZERO, size_of(part("input"))).has_point(p):
			return
		if c.focus_mode != Control.FOCUS_NONE:
			c.grab_focus()
		var dr = glue.host_rect(part("dragger"))
		var dx := -1.0e9
		var dw := 0.0
		if dr != null:
			dx = _input_pos((dr as Rect2).position).x
			dw = (dr as Rect2).size.x
		if _has("thumb-min", mb.position):
			_state = MIN_THUMB
		elif _has("thumb-max", mb.position):
			_state = MAX_THUMB
		elif p.x > dx and p.x < dx + dw:
			_state = MIDDLE
		else:
			_state = NO_THUMB
		if _state == NO_THUMB:
			var nv := _from_position(p.x)
			if p.x < dx:
				_state = MIN_THUMB
				_set_value(Vector2(nv, _v.y), true)
			else:
				_state = MAX_THUMB
				_set_value(Vector2(_v.x, nv), true)
		_set_nav_state(_state)
		_start_value = _v
		_start = p
		_pressed = true

	func v2_motion(mm: InputEventMouseMotion) -> void:
		if _pressed:
			_drag(_start.x, _input_pos(mm.position).x)

	func v2_release() -> void:
		_pressed = false


## ListView: runtime v1's CollectionBehavior on the table. The pooled rows
## are table elements bound as v1 binds them (the same code); a row moves
## to its item's place by a position offset outside the layout
## (UxmlRuntimeV2.set_offsets, as v1's _place moves the row's Control), and
## the pointer comes from the core's hit test.
class V2CollectionBehavior extends UxmlContainerBehaviors.CollectionBehavior:
	var glue
	var _row_idx := PackedInt32Array()
	var _offs := PackedVector2Array()

	func setup() -> void:
		super()
		_row_idx = PackedInt32Array()
		for r in _rows:
			_row_idx.append(glue.index_of((r as UxmlListRow).element))

	func _viewport_h() -> float:
		var vp := UxmlContainerParts.get_part(_sv, "viewport") if _sv != null else null
		return 0.0 if vp == null else (glue.size_of(vp) as Vector2).y

	## Slot k is laid out at k * h; its row is drawn at its item's place.
	func _place() -> void:
		if _row_idx.is_empty():
			return
		var h := item_height()
		var offs := PackedVector2Array()
		offs.resize(_rows.size())
		for k in _rows.size():
			var idx: int = (_rows[k] as UxmlListRow).index
			offs[k] = Vector2(0.0, 0.0 if idx < 0 else (idx - k) * h)
		if offs == _offs:
			return
		_offs = offs
		glue.rt.call("set_offsets", _row_idx, offs, false)
		glue._draw_req = true
		glue.queue()

	func after_layout() -> void:
		v2_after_layout()

	## The layout hook: the rows at their places; a viewport that changed
	## takes more or fewer rows (Unity's Resize). True when that wrote
	## styles.
	func v2_after_layout() -> bool:
		_place()
		if _rows_for_viewport() != _active:
			refresh(false)
			return true
		return false

	## Root box coordinates of a global point.
	func _local(gp: Vector2) -> Vector2:
		return glue.doc._root_box.get_global_transform().affine_inverse() * gp

	func _row_holds(row: UxmlListRow, p: Vector2) -> bool:
		if row.index < 0 or not glue.is_shown(row.element):
			return false
		var r = glue.host_rect(row.element)
		return r != null and (r as Rect2).has_point(p)

	## The bound, drawn row under root box point `p` inside the viewport.
	func _row_at_local(p: Vector2) -> UxmlListRow:
		var vp := UxmlContainerParts.get_part(_sv, "viewport") if _sv != null else null
		if vp != null:
			var vr = glue.host_rect(vp)
			if vr == null or not glue.is_shown(vp) or not (vr as Rect2).has_point(p):
				return null
		for k in _active:
			var row: UxmlListRow = _rows[k]
			if _row_holds(row, p):
				return row
		return null

	func row_at(gp: Vector2) -> UxmlListRow:
		return _row_at_local(_local(gp))

	func row_of(i: int) -> UxmlListRow:
		if i < 0:
			return null
		for k in _active:
			var row: UxmlListRow = _rows[k]
			if row.index == i and glue.is_shown(row.element):
				return row
		return null

	func item_rect(i: int) -> Rect2:
		var row := row_of(i)
		if row == null:
			return Rect2()
		var r = glue.host_rect(row.element)
		if r == null:
			return Rect2()
		return UxmlDocument.xform_rect(glue.doc._root_box.get_global_transform(), r)

	## A press on the rows (root box coordinates): runtime v1's row input.
	func v2_press(mb: InputEventMouseButton) -> void:
		var row := _row_at_local(mb.position)
		if row == null:
			var cc := control_of(_content)
			if cc != null and cc.focus_mode != Control.FOCUS_NONE:
				cc.grab_focus()
			return
		_on_row_input(mb, row)

	func v2_release(mb: InputEventMouseButton) -> void:
		var row := _row_at_local(mb.position)
		_on_row_input(mb, row if row != null else (_rows[0] if not _rows.is_empty() else null))
