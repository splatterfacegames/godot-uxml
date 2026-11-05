class_name RefUxmlDocument
extends Control
@warning_ignore_start("inference_on_variant", "unsafe_method_access", "untyped_declaration")
## A native Godot Control that renders a UXML document.
##
## Place it in a scene like any Control (exported `uxml_path`/`project_root`
## work without the editor plugin enabled — the addon is pure GDScript), or
## drive it from code:
##
##   var doc := UxmlDocument.new()
##   add_child(doc)
##   doc.load_document("res://ui/menu.uxml")
##   doc.button_pressed.connect(func(name): print(name))
##   doc.get_element("play-button").pressed.connect(_on_play)
##
## `get_element(name)` returns the element's box — for wrapped controls
## (Slider/TextField/DropdownField/Image/ScrollView) that is a UxmlField or
## UxmlBox; `get_native(name)` returns the interactive native inside
## (HSlider, LineEdit, TextureRect, ScrollContainer). Native signals stay
## native; the document adds convenience signals that carry the authored
## `name` attribute.
##
## Pseudo-states map to real Control state: hover <- mouse_entered/exited,
## focus <- focus_entered/exited, active <- button held, checked <- toggle
## state, disabled <- enabled="false" or set_enabled(). Every change
## re-resolves the cascade with element_states/disabled_elements and
## re-applies, so :hover etc. work exactly like the authored USS says.

signal button_pressed(element_name)
signal value_changed(element_name, value)
signal loaded(success)

## The UXML file to load. Setting it while the node is inside the tree
## reloads the document.
@export var uxml_path: String = "":
	set(v):
		if v == uxml_path:
			return
		uxml_path = v
		if auto_load and is_inside_tree():
			load_document(v, project_root)

## Project root every reference (Style src, url(), images, fonts) is
## contained inside. All resolver path forms are accepted.
@export var project_root: String = "res://"

## Load `uxml_path` automatically when the node is ready.
@export var auto_load: bool = true

## Every diagnostic produced by the last load: parse/cascade warnings plus
## runtime `unsupported-value`/`duplicate-name`/`missing-file` entries.
var diagnostics: Array = []

var _doc: UxmlDocumentModel = null
var _resolver: UxmlResourceResolver = null
var _styles: Dictionary = {}
var _controls: Dictionary = {}      # UxmlElement -> outer Control
var _natives: Dictionary = {}       # UxmlElement -> interactive native
var _scroll: Dictionary = {}        # UxmlElement -> scroll content Control
var _by_name: Dictionary = {}       # String -> UxmlElement (first wins)
var _el_names: Dictionary = {}      # UxmlElement -> String
var _parents: Dictionary = {}       # UxmlElement -> UxmlElement
var _states: Dictionary = {}        # UxmlElement -> {state: true}
var _disabled_rt: Dictionary = {}   # UxmlElement -> bool (runtime override via set_enabled)
var _disabled_eff: Dictionary = {}  # UxmlElement -> true (effective, incl. attr + ancestry)
var _gone_eff: Dictionary = {}      # UxmlElement -> true (effective display:none incl. ancestors)
var _rt_warnings: Array = []
var _applier: RefStyleApplier = null  # one per load: its dedupe set and
                                      # resource caches span all restyles
var _layout_warned: Dictionary = {}    # shared dedupe for layout warnings
var _effective_root: String = ""       # root the last successful load used
var _root_box: UxmlBox = null
var _restyle_queued := false


func _init() -> void:
	_root_box = UxmlBox.new()
	_root_box.name = "uxml-root"
	_root_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root_box)
	_ensure_input_map()


## Godot's default ui_* actions cover keyboard and d-pad navigation but
## leave ui_accept without a joypad binding. UXML interfaces are expected
## to work with a controller out of the box, so the document adds the
## standard Joypad A mapping once when the action has no joy events.
static func _ensure_input_map() -> void:
	var pad := {
		"ui_accept": JOY_BUTTON_A,
		"ui_up": JOY_BUTTON_DPAD_UP,
		"ui_down": JOY_BUTTON_DPAD_DOWN,
		"ui_left": JOY_BUTTON_DPAD_LEFT,
		"ui_right": JOY_BUTTON_DPAD_RIGHT,
	}
	for action in pad:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		var has_joy := false
		for ev in InputMap.action_get_events(action):
			if ev is InputEventJoypadButton or ev is InputEventJoypadMotion:
				has_joy = true
				break
		if has_joy:
			continue
		var ev := InputEventJoypadButton.new()
		ev.button_index = pad[action]
		InputMap.action_add_event(action, ev)


func _ready() -> void:
	if auto_load and not uxml_path.is_empty() and _doc == null:
		load_document(uxml_path, project_root)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _doc != null:
		_do_layout()


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

## Parse, resolve, instantiate and lay out `path`. `root` overrides
## project_root for this load. Returns OK, or ERR_FILE_CANT_OPEN when the
## document itself could not be read (the diagnostic is in `diagnostics`,
## the previous tree is gone, nothing stale is left on screen).
func load_document(path: String, root: String = "") -> int:
	_clear()
	var effective_root := root if not root.is_empty() else project_root
	_resolver = UxmlResourceResolver.new(effective_root)
	_doc = UxmlLoader.load_file_with_resolver(path, _resolver)
	if _doc.path.is_empty():
		# The document file itself did not load: keep the diagnostic, show
		# nothing, report failure.
		diagnostics = _doc.warnings.duplicate()
		_doc = null
		loaded.emit(false)
		return ERR_FILE_CANT_OPEN

	_effective_root = effective_root
	_index()
	_restyle_now()
	loaded.emit(true)
	return OK


## Alias for load_document when a `load` verb reads better.
func load_uxml(path: String, root: String = "") -> int:
	return load_document(path, root)


## `load` spelling for callers that prefer it. Note this shadows the global
## load() inside this class's own methods only.
func load(path: String, root: String = "") -> int:
	return load_document(path, root)


## Re-load the last loaded document from disk, keeping the project root
## that load actually used — an explicit root passed to load_document()
## survives reload() instead of falling back to the exported default.
func reload() -> int:
	if _doc == null or _doc.path.is_empty():
		return ERR_UNCONFIGURED
	var path := _doc.path
	var root := _effective_root
	return load_document(path, root)


func _clear() -> void:
	for child in _root_box.get_children():
		_root_box.remove_child(child)
		child.queue_free()
	_controls.clear()
	_natives.clear()
	_scroll.clear()
	_by_name.clear()
	_el_names.clear()
	_parents.clear()
	_states.clear()
	_disabled_rt.clear()
	_disabled_eff.clear()
	_gone_eff.clear()
	_styles = {}
	_rt_warnings = []
	# The applier holds the old _rt_warnings array by reference — it must be
	# rebuilt with the new one rather than warned into a dead array.
	_applier = null
	_layout_warned = {}
	_doc = null
	diagnostics = []


## Parent map, name index (first wins, duplicates diagnosed), runtime
## control tree, and signal wiring — everything keyed off the element tree.
func _index() -> void:
	var stack: Array = [_doc.root]
	while not stack.is_empty():
		var el: UxmlElement = stack.pop_back()
		for child in el.children:
			_parents[child] = el
			stack.append(child)
	for el in _doc.root.walk():
		var n = el.get_attribute("name")
		if n == null:
			continue
		var ns := String(n)
		if _by_name.has(ns):
			_rt_warnings.append(UxmlDiagnostic.make(
				"duplicate-name",
				'name "%s" is declared more than once; get_element returns the first' % ns,
				_doc.source, el.open_tag_start, _doc.path
			))
			continue
		_by_name[ns] = el
		_el_names[el] = ns

	var factory := UxmlControlFactory.new(_resolver, _doc.path, _doc.source, _rt_warnings)
	for child in _doc.root.children:
		if UssControls.is_non_visual(child.local):
			continue
		_root_box.add_child(factory.build(child))
	_controls = factory.controls
	_natives = factory.natives
	_scroll = factory.scroll_contents
	_controls[_doc.root] = _root_box
	for el in _controls:
		if el == _doc.root:
			continue
		_wire(el, _controls[el])


# ---------------------------------------------------------------------------
# Signals / runtime state
# ---------------------------------------------------------------------------

func _wire(el: UxmlElement, c: Control) -> void:
	var native: Control = _natives.get(el, c)
	c.mouse_entered.connect(_set_state.bind(el, "hover", true))
	c.mouse_exited.connect(_set_state.bind(el, "hover", false))
	if c != native:
		# The wrapper reports hover for the whole field; the inner native
		# reports it too, so both nested areas drive :hover.
		native.mouse_entered.connect(_set_state.bind(el, "hover", true))
		native.mouse_exited.connect(_set_state.bind(el, "hover", false))
	c.focus_entered.connect(_set_state.bind(el, "focus", true))
	c.focus_exited.connect(_set_state.bind(el, "focus", false))
	c.gui_input.connect(_on_gui_input.bind(el))
	if native != c:
		# The wrapper never takes focus or key input — the focused inner
		# native reports :focus, :active and scroll keys for the element.
		native.focus_entered.connect(_set_state.bind(el, "focus", true))
		native.focus_exited.connect(_set_state.bind(el, "focus", false))
		native.gui_input.connect(_on_gui_input.bind(el))

	var el_name := _el_names.get(el, "")
	if el.local == "Button" and native is Button:
		native.pressed.connect(func(): button_pressed.emit(el_name))
		native.button_down.connect(_set_state.bind(el, "active", true))
		native.button_up.connect(_set_state.bind(el, "active", false))
	elif native is CheckBox:
		native.toggled.connect(func(on: bool):
			_set_state(el, "checked", on)
			value_changed.emit(el_name, on))
		# button_pressed was assigned before this connect — sync :checked.
		if native.button_pressed:
			_set_state(el, "checked", true)
		native.button_down.connect(_set_state.bind(el, "active", true))
		native.button_up.connect(_set_state.bind(el, "active", false))
	elif native is HSlider:
		native.value_changed.connect(func(v: float):
			if el.local == "SliderInt":
				value_changed.emit(el_name, int(v))
			else:
				value_changed.emit(el_name, v))
		native.drag_started.connect(_set_state.bind(el, "active", true))
		native.drag_ended.connect(func(_changed: bool):
			_set_state(el, "active", false))
	elif native is LineEdit:
		native.text_changed.connect(func(t: String):
			value_changed.emit(el_name, t))
	elif native is TextEdit:
		native.text_changed.connect(func():
			value_changed.emit(el_name, native.text))
	elif native is OptionButton:
		native.item_selected.connect(func(i: int):
			value_changed.emit(el_name, native.get_item_text(i)))


## Any left-button press on a control toggles :active — the USS "pressed"
## state — for every element, not just buttons. A focused ScrollView also
## scrolls on the navigation keys (native ScrollContainer only handles the
## wheel); the keys are consumed so focus does not jump away.
func _on_gui_input(ev: InputEvent, el: UxmlElement) -> void:
	var mb := ev as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		_set_state(el, "active", mb.pressed)
		return
	var sc := _natives.get(el) as ScrollContainer
	if sc == null:
		return
	var bar := sc.get_v_scroll_bar()
	if bar == null or bar.max_value - bar.page <= 0.0:
		return  # nothing to scroll: let navigation keys pass through
	var line := maxf(16.0, bar.step)
	if ev.is_action_pressed("ui_down"):
		sc.scroll_vertical += line
	elif ev.is_action_pressed("ui_up"):
		sc.scroll_vertical -= line
	elif ev.is_action_pressed("ui_page_down"):
		sc.scroll_vertical += bar.page
	elif ev.is_action_pressed("ui_page_up"):
		sc.scroll_vertical -= bar.page
	else:
		return
	sc.accept_event()


func _set_state(el: UxmlElement, state: String, on: bool) -> void:
	var set: Dictionary = _states.get(el, {})
	if on:
		if set.has(state):
			return
		set[state] = true
	else:
		if not set.has(state):
			return
		set.erase(state)
	_states[el] = set
	_queue_restyle()


func _queue_restyle() -> void:
	if _restyle_queued:
		return
	_restyle_queued = true
	call_deferred("_restyle_now")


## Re-resolve the cascade with the current runtime states, re-apply all
## styles, and re-layout. Coalesced: several state changes in one frame
## produce one pass.
func _restyle_now() -> void:
	_restyle_queued = false
	if _doc == null:
		return
	var element_states := {}
	for el in _states:
		var s: Dictionary = _states[el]
		if not s.is_empty():
			element_states[el] = s.keys()
	_compute_disabled()
	# The resolver gets the explicit runtime sets and descends them the same
	# way it descends enabled="false"; enabled_elements carries the
	# SetEnabled(true) override that cancels the attribute.
	var runtime_disabled := {}
	var runtime_enabled := {}
	for el in _disabled_rt:
		(runtime_disabled if _disabled_rt[el] else runtime_enabled)[el] = true
	var res := RefStyleResolver.resolve(_doc, {
		"element_states": element_states,
		"disabled_elements": runtime_disabled,
		"enabled_elements": runtime_enabled,
	})
	_styles = res["styles"]
	_compute_gone()
	# One applier per load: its warning dedupe and resource caches must
	# survive restyles or every hover would re-report and re-load misses.
	if _applier == null:
		_applier = RefStyleApplier.new(
			_resolver, _doc.path, _doc.source, _rt_warnings
		)
	for el in _controls:
		var c: Control = _controls[el]
		var st: Dictionary = _styles.get(el, {})
		_applier.apply(el, c, _natives.get(el, c), st,
			_disabled_eff.has(el), _gone_eff.has(el))
	_do_layout()
	# Runtime warnings accumulate during apply/layout — surface last so they
	# are all included.
	diagnostics = _doc.warnings + res["warnings"] + _rt_warnings


func _compute_disabled() -> void:
	_disabled_eff.clear()
	var stack: Array = [[_doc.root, false]]
	while not stack.is_empty():
		var frame: Array = stack.pop_back()
		var el: UxmlElement = frame[0]
		# A set_enabled() call is an override: it wins over the enabled
		# attribute for this element. A disabled ancestor still wins over
		# everything — Unity's SetEnabled disables the whole subtree.
		var own: bool = (
			_disabled_rt[el] if _disabled_rt.has(el)
			else el.get_attribute("enabled") == "false"
		)
		var dis: bool = frame[1] or own
		if dis:
			_disabled_eff[el] = true
		for child in el.children:
			stack.append([child, dis])


## Effective display:none: display is not inherited in USS, but a hidden
## ancestor makes the whole subtree inert — descendants get the same
## focus/mouse/input suppression as the element itself.
func _compute_gone() -> void:
	_gone_eff.clear()
	var stack: Array = [[_doc.root, false]]
	while not stack.is_empty():
		var frame: Array = stack.pop_back()
		var el: UxmlElement = frame[0]
		var st: Dictionary = _styles.get(el, {})
		var disp = st.get("display")
		var gone: bool = (
			frame[1]
			or (disp != null and String(disp["value"]) == "none")
		)
		if gone:
			_gone_eff[el] = true
		for child in el.children:
			stack.append([child, gone])


func _measure_leaf(el: UxmlElement, _style: Dictionary, content_w: float) -> Vector2:
	var c: Control = _controls.get(el)
	if c == null:
		return Vector2.ZERO
	if c is Label and c.autowrap_mode != TextServer.AUTOWRAP_OFF and content_w >= 0.0:
		# Label reports its wrapped height from its current width — hand it
		# the width the line assigned so the measurement is honest.
		c.size.x = content_w
	var ms: Vector2
	if c is UxmlBox:
		# Our own wrappers keep the intrinsic measure in natural_size —
		# custom_minimum_size would also clamp the laid-out Control size,
		# which is not Yoga semantics.
		ms = c.natural_size
	else:
		ms = c.get_combined_minimum_size()
	# A USS stylebox carries padding+border as content margins, which the
	# minimum size already counts — the flex pass adds the same insets on
	# top of the intrinsic size, so take them back out here. Only styleboxes
	# this runtime built carry the meta; theme margins stay counted.
	if c.has_theme_stylebox_override("normal"):
		var sb: StyleBox = c.get_theme_stylebox("normal")
		if sb != null and sb.has_meta("uxml_margins"):
			var m: Array = sb.get_meta("uxml_margins")
			ms.x = maxf(0.0, ms.x - m[0] - m[2])
			ms.y = maxf(0.0, ms.y - m[1] - m[3])
	return ms


func _scroll_bar_width() -> float:
	for el in _scroll:
		var sc: ScrollContainer = _natives.get(el)
		if sc != null:
			var v := sc.get_v_scroll_bar()
			if v != null:
				return v.get_combined_minimum_size().x
	return 0.0


func _do_layout() -> void:
	if _doc == null:
		return
	var res := RefFlexLayout.compute(
		_doc.root, _styles, size,
		_measure_leaf, _rt_warnings,
		{"source": _doc.source, "file": _doc.path,
		 "scroll_bar_width": _scroll_bar_width(),
		 "warned": _layout_warned}
	)
	var rects: Dictionary = res["rects"]
	var insets: Dictionary = res["insets"]
	for el in _controls:
		if el == _doc.root:
			continue
		var c: Control = _controls[el]
		var r = rects.get(el)
		if r == null:
			continue  # display:none — already hidden by the applier
		c.position = r.position
		c.size = r.size
		# Internal chrome the flex pass does not position lives inside the
		# element's content box: field caption+native shift by the resolved
		# padding/border insets, and an Image's anchored TextureRect gets
		# matching anchor offsets. (ScrollView is deliberately excluded —
		# its content children already carry the pad/border offset inside
		# the scroll content control, so insetting the viewport would
		# double-apply it.)
		var pair = insets.get(el)
		if pair == null:
			continue
		var start: Vector2 = pair[0]
		var end: Vector2 = pair[1]
		if c is UxmlField:
			c.set_content_insets(start, end)
		else:
			var inner: Control = _natives.get(el)
			if inner is TextureRect:
				inner.offset_left = start.x
				inner.offset_top = start.y
				inner.offset_right = -end.x
				inner.offset_bottom = -end.y
			# Unwrapped themed controls draw their own text inside the
			# stylebox's content margins — hand them the same resolved
			# insets (percentage padding included) the box layout used.
			if _applier != null:
				_applier.apply_resolved_insets(c, start, end)
	for el in _scroll:
		var content: Control = _scroll[el]
		content.custom_minimum_size = res["content_sizes"].get(el, Vector2.ZERO)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## The element's outer control, or null. For labeled fields this is the
## UxmlField wrapper; for Image/ScrollView the host box.
func get_element(element_name: String) -> Control:
	var el: UxmlElement = _by_name.get(element_name)
	return null if el == null else _controls.get(el)


func get_element_by_name(element_name: String) -> Control:
	return get_element(element_name)


## The interactive native inside the element's box (HSlider, LineEdit,
## CheckBox, OptionButton, Button, Label, TextureRect, ScrollContainer).
## Same as get_element for unwrapped controls.
func get_native(element_name: String) -> Control:
	var el: UxmlElement = _by_name.get(element_name)
	return null if el == null else _natives.get(el)


## The semantic element, for attribute/structure access.
func get_element_model(element_name: String) -> UxmlElement:
	return _by_name.get(element_name)


## The last computed style for the element (property -> {value, origin}).
func get_computed_style(element_name: String) -> Dictionary:
	var el: UxmlElement = _by_name.get(element_name)
	return {} if el == null else _styles.get(el, {})


## Unity's SetEnabled: an override on top of the authored enabled
## attribute — set_enabled(true) re-enables even enabled="false" elements.
## The state descends the whole subtree — native disabled flags plus the
## :disabled pseudo — until called again. A disabled ancestor still wins.
func set_enabled(element_name: String, enabled: bool) -> void:
	var el: UxmlElement = _by_name.get(element_name)
	if el == null:
		return
	_disabled_rt[el] = not enabled
	_queue_restyle()


## Drive a pseudo-state by hand for states without a native event
## (:selected), or to force one for testing. hover/focus/active/checked are
## normally driven by real input; :disabled descends — use set_enabled for
## the subtree form.
func set_element_state(element_name: String, state: String, on: bool) -> void:
	var el: UxmlElement = _by_name.get(element_name)
	if el != null:
		_set_state(el, state, on)


## Replace the element's `class` attribute and re-resolve. Runtime class
## changes are how game code switches authored variants (e.g. .selected).
func set_class(element_name: String, class_string: String) -> void:
	var el: UxmlElement = _by_name.get(element_name)
	if el == null:
		return
	for attr in el.attributes:
		if attr["name"] == "class":
			attr["value"] = class_string
			_queue_restyle()
			return
	el.attributes.append({"name": "class", "value": class_string, "offset": 0})
	_queue_restyle()


## Re-resolve and re-lay out after changes the runtime cannot see — e.g.
## code mutating a Label's text directly.
func refresh() -> void:
	_queue_restyle()
