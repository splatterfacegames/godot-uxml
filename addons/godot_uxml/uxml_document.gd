class_name UxmlDocument
extends Control
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
## re-resolves the cascade with element_states/disabled_elements
## (incrementally) and re-applies what changed, so :hover etc. work exactly
## like the authored USS says. refresh() re-applies everything; relayout()
## is the cheap per-frame form for text-only updates.

signal button_pressed(element_name)
signal value_changed(element_name, value)
signal loaded(success)
## USS transition events (Unity's TransitionRunEvent / TransitionStartEvent /
## TransitionEndEvent / TransitionCancelEvent). `element_name` is the
## element's `name` attribute ("" when it has none), `property` the
## animated longhand, `elapsed_time` the event's elapsedTime in seconds.
## Emitted after the restyle that produced them.
signal transition_run(element_name, property, elapsed_time)
signal transition_start(element_name, property, elapsed_time)
signal transition_end(element_name, property, elapsed_time)
signal transition_cancel(element_name, property, elapsed_time)
## A rich text <link="id"> or <a href="url"> was clicked in a Label.
signal link_clicked(element_name, link_id)

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

## The default theme stylesheet, spliced ahead of every author sheet (see
## UxmlTheme). Empty disables the theme; another path replaces it. Read at
## load time.
@export var theme_path: String = UxmlTheme.DEFAULT

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
# Effective flags per cascade preorder index (attr + runtime + ancestry):
var _dis: PackedByteArray = PackedByteArray()   # disabled
var _gone: PackedByteArray = PackedByteArray()  # display:none on self or an ancestor
var _rt_warnings: Array = []
var _applier: UxmlStyleApplier = null  # one per load: its dedupe set and
                                      # resource caches span all restyles
var _layout_warned: Dictionary = {}    # shared dedupe for layout warnings
var _effective_root: String = ""       # root the last successful load used
var _root_box: UxmlBox = null
var _restyle_queued := false
## Use the native flex pass when the extension is loaded (it requires the
## native cascade). False forces UxmlFlexLayout — the reference path.
static var use_native_layout := true
var _cascade: UssCascade = null        # persistent incremental cascade per load
var _full_apply := true                # next restyle re-applies every control
var _force_layout := true              # next restyle lays out even if paint-only
var _rects: Dictionary = {}            # last layout results, reused when a
var _insets: Dictionary = {}           # paint-only restyle skips the layout
# Settling. Theme overrides reach a control's minimum size through a
# deferred engine update, so the layout right after an apply (and anything
# an apply derives from control sizes, like UxmlField.natural_size) can see
# stale measures; the original runtime corrected that on the next restyle
# because every restyle re-applied and re-laid out everything. A pass that
# applied controls therefore re-applies them on the next pass and keeps
# laying out until a layout reproduces the previous rects — the same fixed
# point the full re-apply/re-layout reaches — before paint-only restyles
# are allowed to skip the layout.
var _reapply: Array = []
var _unsettled := true
var _pending_fresh := false
var _el_of: Dictionary = {}           # outer Control -> UxmlElement
var _layout_records: Dictionary = {}  # flex layout's parsed-style cache
var _layout_xcache: Dictionary = {}   # flex layout's validated cross-pass cache
var _attr_dirty: Dictionary = {}      # UxmlElement -> true (set_attribute since last restyle)
var _placed_force: Array = []         # elements re-applied this restyle (inset hooks must run)
# Virtualized ListViews: list element -> {rows: Array[UxmlListRow], h, count,
# bind, first, applied, alt}. Rows are pooled copies of the item template.
var _lists: Dictionary = {}
var _pooled: Dictionary = {}          # UxmlElement -> true (inside a pooled row)
var _behaviors: Dictionary = {}       # control UxmlElement -> UxmlBehaviors.Behavior

## Unity's default ListView fixed-item-height.
const LIST_DEFAULT_ITEM_HEIGHT := 22.0
var _scan_all := true                 # next restyle re-reads every element's attributes
var _transitions: UssTransitions = null  # running USS transitions (per load)

## When true, transitions advance only through advance_transitions() —
## deterministic time for tests and tools. When false (default) they follow
## the frame clock (_process delta).
var transitions_manual := false
# Data binding and the VisualElement base attributes (tabindex,
# picking-mode, view-data-key, ...): runtime/uxml_binding.gd and
# runtime/uxml_common_attributes.gd. Kept across loads.
var _attrs: UxmlCommonAttributes = null
var _binding: UxmlBinding = null

## Computed-style properties that can change neither the flex geometry nor
## any control's intrinsic measure: a restyle that only changes these
## re-applies the affected controls but skips the layout pass. Custom
## properties (--*) are also paint-only — their effect arrives through the
## properties that reference them.
const PAINT_ONLY := {
	"background-color": true, "color": true,
	"border-top-color": true, "border-right-color": true,
	"border-bottom-color": true, "border-left-color": true,
	"border-top-left-radius": true, "border-top-right-radius": true,
	"border-bottom-right-radius": true, "border-bottom-left-radius": true,
	"-unity-background-image-tint-color": true,
	"-unity-text-outline-color": true,
	"-unity-text-align": true, "visibility": true,
	# Painted without affecting flex geometry or intrinsic measures.
	# Elision (text-overflow, and overflow, which gates it) is recomputed by
	# the applier after every restyle; the measurer always measures full text.
	"opacity": true, "overflow": true, "-unity-overflow-clip-box": true,
	"translate": true, "rotate": true, "scale": true, "transform-origin": true,
	"text-shadow": true, "text-overflow": true, "-unity-text-overflow-position": true,
	"background-position-x": true, "background-position-y": true,
	"background-repeat": true, "background-size": true,
	"-unity-slice-type": true, "-unity-slice-scale": true,
	"cursor": true,
	"-unity-text-generator": true, "-unity-editor-text-rendering-mode": true,
	# Canvas group / material only (UxmlFilter, CanvasItem.material).
	"filter": true, "-unity-material": true,
}


func _init() -> void:
	set_process(false)
	_root_box = UxmlBox.new()
	_root_box.name = "uxml-root"
	_root_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root_box)
	_attrs = UxmlCommonAttributes.new(self)
	_binding = UxmlBinding.new(self, _attrs)
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
	elif what == NOTIFICATION_ENTER_TREE or what == NOTIFICATION_EXIT_TREE:
		_binding.set_active(what == NOTIFICATION_ENTER_TREE)
	elif what == NOTIFICATION_PREDELETE:
		_binding.clear()


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

## Parse, resolve, instantiate and lay out `path`. `root` overrides
## project_root for this load. Returns OK, or ERR_FILE_CANT_OPEN when the
## document itself could not be read (the diagnostic is in `diagnostics`,
## the previous tree is gone, nothing stale is left on screen).
func load_document(path: String, root: String = "") -> int:
	if _doc != null:
		_attrs.capture_view_data()
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
	UxmlTheme.attach(_doc, theme_path)
	_index()
	_restyle_now()
	_attrs.restore_view_data()
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
	_dis = PackedByteArray()
	_gone = PackedByteArray()
	_styles = {}
	_rt_warnings = []
	# The applier holds the old _rt_warnings array by reference — it must be
	# rebuilt with the new one rather than warned into a dead array.
	_applier = null
	_layout_warned = {}
	_cascade = null
	_full_apply = true
	_force_layout = true
	_rects = {}
	_insets = {}
	_reapply = []
	_unsettled = true
	_pending_fresh = false
	_el_of = {}
	_layout_records = {}
	_layout_xcache = {}
	_attr_dirty = {}
	_scan_all = true
	_lists = {}
	_pooled = {}
	_transitions = null
	set_process(false)
	_binding.clear()
	_attrs.clear()
	_behaviors = {}
	_doc = null
	diagnostics = []


## Parent map, name index (first wins, duplicates diagnosed), runtime
## control tree, and signal wiring — everything keyed off the element tree.
func _index() -> void:
	_expand_lists()
	if not _lists.is_empty():
		_rt_warnings.append_array(UxmlBindings.extract(_doc))  # item templates
	# Control part trees (Toggle label/input/checkmark, Foldout content, ...)
	# become real model elements before anything indexes the tree.
	UxmlParts.expand(_doc)
	var stack: Array = [_doc.root]
	while not stack.is_empty():
		var el: UxmlElement = stack.pop_back()
		for child in el.children:
			_parents[child] = el
			stack.append(child)
	for el in _doc.root.walk():
		if _pooled.has(el) or el.part_of != null:
			continue  # pooled list rows repeat their template's names; parts are internal
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
	factory.element_paths = _doc.element_paths
	for child in _doc.root.children:
		if UssControls.is_non_visual(child.local):
			continue
		_root_box.add_child(factory.build(child))
	_controls = factory.controls
	_natives = factory.natives
	_scroll = factory.scroll_contents
	_controls[_doc.root] = _root_box
	for el in _controls:
		_el_of[_controls[el]] = el
	for lel in _lists:
		var lsc := _natives.get(lel) as ScrollContainer
		if lsc != null:
			lsc.get_v_scroll_bar().value_changed.connect(_on_list_scrolled.bind(lel))
	# Observable model: set_attribute() on any element restyles just it.
	var on_changed := _on_model_changed
	for el in _doc.root.walk():
		el.changed = on_changed
	for el in _controls:
		if el == _doc.root:
			continue
		_wire(el, _controls[el])
	_behaviors = UxmlBehaviors.attach_all(self)
	_attrs.setup()
	_binding.setup()


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
	if native is Button and (el.local == "Button" or el.local == "RepeatButton"):
		native.pressed.connect(func(): button_pressed.emit(el_name))
		native.button_down.connect(_set_state.bind(el, "active", true))
		native.button_up.connect(_set_state.bind(el, "active", false))
	elif native is UxmlToggle:
		pass  # value, :checked and value_changed: UxmlBehaviors.ToggleBehavior
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
	elif native is RichTextLabel:
		native.meta_clicked.connect(func(meta):
			link_clicked.emit(el_name, str(meta)))


## Any left-button press on a control toggles :active — the USS "pressed"
## state — for every element, not just buttons. A focused ScrollView also
## scrolls on the navigation keys (native ScrollContainer only handles the
## wheel); the keys are consumed so focus does not jump away.
func _on_gui_input(ev: InputEvent, el: UxmlElement) -> void:
	var mb := ev as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		# Unity sets :active on the clickable control, not on its parts: a
		# part passes the press on to its control, which takes the state.
		var pc = _controls.get(el)
		if el.part_of == null or pc is UxmlToggle or pc is BaseButton:
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


## Re-resolve the cascade with the current runtime states, re-apply the
## controls whose style or effective state changed, and re-layout unless
## every change was paint-only. Coalesced: several state changes in one
## frame produce one pass. The cascade is incremental (only elements whose
## inputs changed are recomputed), so the cost scales with what changed,
## not with the document.
##
## `only_transitions`: called by the transition clock when nothing but
## running transitions changed — the cascade then visits only the animated
## elements' subtrees.
func _restyle_now(only_transitions: bool = false) -> void:
	_restyle_queued = false
	if _doc == null:
		return
	var element_states := {}
	for el in _states:
		var s: Dictionary = _states[el]
		if not s.is_empty():
			element_states[el] = s.keys()
	# The resolver gets the explicit runtime sets and descends them the same
	# way it descends enabled="false"; enabled_elements carries the
	# SetEnabled(true) override that cancels the attribute.
	var runtime_disabled := {}
	var runtime_enabled := {}
	for el in _disabled_rt:
		(runtime_disabled if _disabled_rt[el] else runtime_enabled)[el] = true
	if _cascade == null:
		_cascade = UssCascade.new(_doc)
		_full_apply = true
		_force_layout = true
		if _cascade._native != null and use_native_layout:
			# Native flex pass: hand it the controls per preorder index.
			var ctl: Array = []
			var kinds := PackedByteArray()
			var nats: Array = []
			for cel in _cascade.els:
				var cc = _controls.get(cel)
				ctl.append(cc)
				kinds.append((1 if cc is UxmlBox else 0) | (2 if cc is UxmlField else 0))
				nats.append(_natives.get(cel))
			_cascade._native.call("set_controls", ctl, kinds, nats)
	var dirty = null
	if not _scan_all:
		var dl := PackedInt32Array()
		var cidx: Dictionary = _cascade.index
		for el in _attr_dirty:
			var di = cidx.get(el)
			if di != null:
				dl.append(di)
		dirty = dl
	_attr_dirty.clear()
	_scan_all = false
	var options := {
		"element_states": element_states,
		"disabled_elements": runtime_disabled,
		"enabled_elements": runtime_enabled,
	}
	var changed := _cascade.update(options, false, dirty, only_transitions and dirty != null)
	var olds: Array = _cascade.last_old
	if _transitions == null:
		_transitions = UssTransitions.new(_cascade)
		_transitions.size_of = _percent_base
		_transitions.filter_defaults = _filter_defaults
	elif not changed.is_empty():
		# Start / retarget / cancel transitions; their overrides are the
		# animated computed values (extra cascade passes, merged here).
		var merged: Array = _transitions.after_update(changed, olds, options)
		changed = merged[0]
		olds = merged[1]
	_styles = _cascade.styles
	var cels: Array = _cascade.els
	# Effective disabled (attribute/runtime, descending — the document's
	# overrides reach the cascade as disabled/enabled_elements, so the rule
	# is identical) and display:none (self or ancestor), kept by the cascade
	# (natively when available). An element whose flags flipped re-applies.
	var ef: Array = _cascade.effective_flags()
	_dis = ef[1]
	_gone = ef[2]
	var flipped: Array = []
	for fi in (ef[0] as PackedInt32Array):
		flipped.append(cels[fi])
	# One applier per load: its warning dedupe and resource caches must
	# survive restyles or every hover would re-report and re-load misses.
	if _applier == null:
		_applier = UxmlStyleApplier.new(
			_resolver, _doc.path, _doc.source, _rt_warnings
		)
		_applier.element_paths = _doc.element_paths
	var need_layout := _force_layout or _full_apply or _unsettled
	var applied: Array = []
	var fresh := 0  # applied[0..fresh) changed this pass; the rest are re-applies
	# Only applies that can change a measure keep the document unsettled:
	# paint-only changes (colors, radii, ...) never move a minimum size, so
	# a stream of hovers right after a load must not relayout forever.
	var measure_fresh := _full_apply
	if _full_apply:
		applied = _controls.keys()
		fresh = applied.size()
	else:
		var els: Array = _cascade.els
		var seen := {}
		for k in changed.size():
			var el: UxmlElement = els[changed[k]]
			seen[el] = true
			if not _paint_only(olds[k], _styles[el]):
				need_layout = true
				measure_fresh = true
		# Effective disabled / display:none flips (ancestors included).
		# Disabled flips relayout too: native disabled styling may change
		# a control's minimum size.
		for el in flipped:
			seen[el] = true
			need_layout = true
			measure_fresh = true
		for el in seen:
			if _controls.has(el):
				applied.append(el)
		fresh = applied.size()
		for el in _reapply:
			if not seen.has(el) and _controls.has(el):
				seen[el] = true
				applied.append(el)
		for c in _applier.drifting:
			var del = _el_of.get(c)
			if del != null:
				need_layout = true
				measure_fresh = true
				if not seen.has(del):
					seen[del] = true
					applied.append(del)
	_reapply = applied.slice(0, fresh)
	var cindex: Dictionary = _cascade.index
	for el in applied:
		var c: Control = _controls[el]
		var st: Dictionary = _styles.get(el, {})
		var ci: int = cindex[el]
		_applier.apply(el, c, _natives.get(el, c), st,
			_dis[ci] == 1, _gone[ci] == 1)
		if c is UxmlToggle:
			(c as UxmlToggle).disabled = _dis[ci] == 1 or _gone[ci] == 1
	_full_apply = false
	_force_layout = false
	if need_layout:
		_pending_fresh = measure_fresh
		_placed_force = applied
		_do_layout()
		_placed_force = []
	else:
		# Re-applied themed controls got fresh styleboxes: hand them the
		# resolved insets of the (unchanged) last layout.
		if _native_layout():
			var idx := PackedInt32Array()
			for el in applied:
				idx.append(cindex[el])
			_cascade._native.call("place_only", _applier, idx)
		else:
			for el in applied:
				_place_control(el)
		_update_elision()
	# Runtime warnings accumulate during apply/layout — surface last so they
	# are all included.
	diagnostics = _doc.warnings + _cascade.collect_warnings() + _rt_warnings
	if _transitions != null:
		set_process(_transitions.active() and not transitions_manual)
		_transitions.flush_events(_emit_transition_event)


# ---------------------------------------------------------------------------
# Transitions
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _transitions == null or not _transitions.active() or transitions_manual:
		set_process(false)
		return
	_transitions.advance(delta * 1000.0)
	if not _transitions.tick():
		_transitions.flush_events(_emit_transition_event)
	elif not _restyle_queued:
		# Only the animated values changed: restyle them now. A restyle
		# already queued this frame picks the new values up instead.
		_restyle_now(_attr_dirty.is_empty())


## Advance running USS transitions by `seconds` and restyle synchronously.
## For deterministic stepping set `transitions_manual` first; the frame
## clock then leaves transition time alone.
func advance_transitions(seconds: float) -> void:
	if _transitions == null or _doc == null:
		return
	_transitions.advance(seconds * 1000.0)
	_transitions.tick()
	_restyle_now(not _restyle_queued and _attr_dirty.is_empty())


## True while a USS transition runs.
func has_running_transitions() -> bool:
	return _transitions != null and _transitions.active()


func _emit_transition_event(kind: int, index: int, property: String, elapsed: float) -> void:
	var el: UxmlElement = _cascade.els[index]
	var nm: String = _el_names.get(el, "")
	match kind:
		UssTransitions.Event.RUN:
			transition_run.emit(nm, property, elapsed)
		UssTransitions.Event.START:
			transition_start.emit(nm, property, elapsed)
		UssTransitions.Event.END:
			transition_end.emit(nm, property, elapsed)
		UssTransitions.Event.CANCEL:
			transition_cancel.emit(nm, property, elapsed)


## Percentage base for converting a transition's px/% start value
## (VisualElement.GetParentSizeForLengthConversion): the parent's laid-out
## width or height, or the element's own size for radii, translate and
## transform-origin. NAN when unknown.
func _percent_base(index: int, property: String, sub: int) -> float:
	var el: UxmlElement = _cascade.els[index]
	var own: Control = _controls.get(el)
	var par = _parents.get(el)
	var pc: Control = null if par == null else _controls.get(par)
	match property:
		"top", "bottom", "height", "min-height", "max-height":
			return NAN if pc == null else pc.size.y
		"left", "right", "width", "min-width", "max-width", \
		"margin-top", "margin-right", "margin-bottom", "margin-left", \
		"padding-top", "padding-right", "padding-bottom", "padding-left":
			return NAN if pc == null else pc.size.x
		"flex-basis":
			if pc == null:
				return NAN
			var dir = (_styles.get(par, {}) as Dictionary).get("flex-direction")
			var d := "column" if dir == null else String(dir["value"])
			return pc.size.y if d.begins_with("column") else pc.size.x
		"border-top-left-radius", "border-top-right-radius", \
		"border-bottom-right-radius", "border-bottom-left-radius":
			return NAN if own == null else own.size.x
		"translate", "transform-origin":
			if own == null:
				return NAN
			return own.size.x if sub == 0 else own.size.y
	return NAN


## Interpolation defaults of a custom filter function (UssTransitions pads a
## shorter filter list with them).
func _filter_defaults(index: int, ref: String, entry) -> Array:
	if _applier == null or index < 0 or _cascade == null:
		return []
	return _applier.filter_interpolation_defaults(ref, entry if entry is Dictionary else {}, _cascade.els[index])


## True when two computed styles differ only in PAINT_ONLY properties.
static func _paint_only(old, new: Dictionary) -> bool:
	if old == null:
		return false
	var o: Dictionary = old
	for prop in new:
		var ne: Dictionary = new[prop]
		var oe = o.get(prop)
		if oe != null and oe["value"] == ne["value"]:
			continue
		if PAINT_ONLY.has(prop) or prop.begins_with("--"):
			continue
		return false
	for prop in o:
		if new.has(prop):
			continue
		if PAINT_ONLY.has(prop) or prop.begins_with("--"):
			continue
		return false
	return true


func _measure_leaf(el: UxmlElement, _style: Dictionary, content_w: float) -> Vector2:
	var c: Control = _controls.get(el)
	if c == null:
		return Vector2.ZERO
	if ((c is Label or c is RichTextLabel) and c.autowrap_mode != TextServer.AUTOWRAP_OFF
			and content_w >= 0.0 and not c.has_meta(&"uxml_autosize")):
		# Label reports its wrapped height from its current width — hand it
		# the width the line assigned so the measurement is honest.
		c.size.x = content_w
	var ms: Vector2
	if _applier != null and _applier.auto_sizes > 0 and c.has_meta(&"uxml_autosize"):
		# -unity-text-auto-size: the size at the font size that fits the
		# width hint (UxmlStyleApplier.autosize_measure, shared with the
		# native measurer).
		ms = UxmlStyleApplier.autosize_measure(c, content_w)
	elif c is UxmlBox:
		# Our own wrappers keep the intrinsic measure in natural_size —
		# custom_minimum_size would also clamp the laid-out Control size,
		# which is not Yoga semantics.
		ms = c.natural_size
	elif _applier != null and _applier.clip_texts > 0 and c.has_meta(&"uxml_clip_text"):
		# overflow: hidden text (clip_text, so the box may be narrower than
		# the text) and elided text measure as the full text, as Unity
		# measures them; the shown state is put back afterwards.
		var shown = c.get(&"text")
		var swap: bool = c.has_meta(&"uxml_full_text") and shown == c.get_meta(&"uxml_elided")
		c.set(&"clip_text", false)
		if swap:
			c.set(&"text", c.get_meta(&"uxml_full_text"))
		ms = c.get_combined_minimum_size()
		if swap:
			c.set(&"text", shown)
		c.set(&"clip_text", true)
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


## Elements whose intrinsic measure depends on measurer call history: a
## wrapping Label reports its height at the width the previous measure left
## on it. Mapped to the control's current width; the layout tracks that
## width through the pass (see UxmlFlexLayout._measure_call).
func _volatile_measures() -> Dictionary:
	var out := {}
	for el in _controls:
		var c: Control = _controls[el]
		if ((c is Label or c is RichTextLabel) and c.autowrap_mode != TextServer.AUTOWRAP_OFF
				and not c.has_meta(&"uxml_autosize")):
			out[el] = c.size.x
	return out


## Best-fit text elements: their measure reads the width hint although they
## are not volatile (UxmlFlexLayout options["hinted"]).
func _autosize_elements() -> Dictionary:
	var out := {}
	if _applier == null or _applier.auto_sizes == 0:
		return out
	for el in _controls:
		if (_controls[el] as Control).has_meta(&"uxml_autosize"):
			out[el] = true
	return out


## Current width of a volatile element's control (after the engine clamps
## a measure-time size write).
func _volatile_width(el: UxmlElement) -> float:
	return (_controls[el] as Control).size.x


func _scroll_bar_width() -> float:
	for el in _scroll:
		var sc: ScrollContainer = _natives.get(el)
		if sc != null:
			var v := sc.get_v_scroll_bar()
			if v != null:
				return v.get_combined_minimum_size().x
	return 0.0


## Run the flex pass for `host` without touching controls' placement:
## the native pass when the extension is loaded, UxmlFlexLayout otherwise.
func _compute_layout(host: Vector2) -> Dictionary:
	if _cascade != null and _cascade._native != null and use_native_layout:
		_cascade._native.call("set_text_clip", _applier != null and _applier.clip_texts > 0)
		_cascade._native.call("set_auto_size", _applier if _applier != null and _applier.auto_sizes > 0 else null)
		var r: Array = _cascade._native.call(
			"layout", host, _scroll_bar_width(), _layout_warned, _rt_warnings)
		return {"rects": r[0], "content_sizes": r[1], "insets": r[2]}
	return UxmlFlexLayout.compute(
		_doc.root, _styles, host,
		_measure_leaf, _rt_warnings,
		{"source": _doc.source, "file": _doc.path,
		 "scroll_bar_width": _scroll_bar_width(),
		 "warned": _layout_warned,
		 "volatile": _volatile_measures(),
		 "volatile_width": _volatile_width,
		 "hinted": _autosize_elements(),
		 "records": _layout_records,
		 "xcache": _layout_xcache,
		 # _measure_leaf only reads its width hint for wrapping Labels
		 # (the volatile set); every other measure is hint-independent.
		 "hint_free": true}
	)


func _native_layout() -> bool:
	return _cascade != null and _cascade._native != null and use_native_layout


func _do_layout() -> void:
	if _doc == null:
		return
	if _native_layout():
		# Native layout + placement; results stay native.
		_cascade._native.call("set_text_clip", _applier != null and _applier.clip_texts > 0)
		_cascade._native.call("set_auto_size", _applier if _applier != null and _applier.auto_sizes > 0 else null)
		var force := PackedInt32Array()
		var cidx: Dictionary = _cascade.index
		for el in _placed_force:
			force.append(cidx[el])
		var r: Array = _cascade._native.call(
			"layout_place", size, _scroll_bar_width(), _layout_warned, _rt_warnings,
			_applier, force, _placed_force.size() == _controls.size())
		var sizes: Dictionary = r[1]
		for el in _scroll:
			(_scroll[el] as Control).custom_minimum_size = sizes.get(el, Vector2.ZERO)
		_unsettled = _pending_fresh or bool(r[0])
		_pending_fresh = false
		_lists_after_layout()
		_update_elision()
		return
	var prev := _rects
	var res := _compute_layout(size)
	_rects = res["rects"]
	_insets = res["insets"]
	for el in _controls:
		if el == _doc.root:
			continue
		_place_control(el)
	var sizes: Dictionary = res["content_sizes"]
	for el in _scroll:
		var content: Control = _scroll[el]
		content.custom_minimum_size = sizes.get(el, Vector2.ZERO)
	# Not settled until a layout with no fresh applies reproduces the
	# previous rects (see _reapply).
	_unsettled = _pending_fresh or prev != _rects
	_pending_fresh = false
	_lists_after_layout()
	_update_elision()


## text-overflow: ellipsis needs the laid-out width: elide after placement
## (both layout paths and the paint-only path run this same code).
func _update_elision() -> void:
	if _applier != null and not _applier.elide.is_empty():
		_applier.update_elision()


## Position/size one element's control from the last layout and inset its
## internal chrome.
func _place_control(el: UxmlElement) -> void:
	if el == _doc.root:
		return
	var c: Control = _controls[el]
	var r = _rects.get(el)
	if r == null:
		return  # display:none — already hidden by the applier
	if _applier != null and _applier.auto_sizes > 0 and c.has_meta(&"uxml_autosize"):
		# Fit the font to the laid-out content box before the size lands,
		# so the old font's minimum size cannot hold the box open.
		var ip = _insets.get(el)
		var cs: Vector2 = r.size if ip == null else r.size - ip[0] - ip[1]
		UxmlStyleApplier.autosize_place(c, cs)
	c.position = r.position
	c.size = r.size
	# Internal chrome the flex pass does not position lives inside the
	# element's content box: field caption+native shift by the resolved
	# padding/border insets, and an Image's anchored TextureRect gets
	# matching anchor offsets. (ScrollView is deliberately excluded —
	# its content children already carry the pad/border offset inside
	# the scroll content control, so insetting the viewport would
	# double-apply it.)
	var pair = _insets.get(el)
	if pair == null:
		return
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
	if el == null:
		return null
	var b = _behaviors.get(el)
	if b != null:
		return b.native()
	return _natives.get(el)


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
	# Unity's SetEnabled also adds/removes `unity-disabled` on the element.
	UxmlParts.toggle_control_class(el, "unity-disabled", not enabled)
	_queue_restyle()


## Drive a pseudo-state by hand for states without a native event
## (:selected), or to force one for testing. hover/focus/active/checked are
## normally driven by real input; :disabled descends — use set_enabled for
## the subtree form.
func set_element_state(element_name: String, state: String, on: bool) -> void:
	var el: UxmlElement = _by_name.get(element_name)
	if el != null:
		_set_state(el, state, on)


## Set a Label's or Button's text. Rich text tags are parsed for a Label
## that was created with rich text (a RichTextLabel); setting `text` on that
## control directly would bypass the Unity tags. Re-lays out.
func set_text(element_name: String, text: String) -> void:
	var el: UxmlElement = _by_name.get(element_name)
	if el == null:
		return
	_set_control_text(_natives.get(el), text)


## Write `text` into a text control (Label, RichTextLabel, Button): the
## path set_text, text parts of controls (UxmlBehaviors.sync_text) and
## text bindings share. Rich text tags are parsed for a RichTextLabel.
## Returns false for a control without text.
func _set_control_text(c: Control, text: String) -> bool:
	if c is RichTextLabel:
		var pr := UxmlRichText.parse(text)
		if not pr["rich"]:
			# Text without tags is one plain run (parse() leaves ops empty).
			pr = {"rich": false, "ops": [["t", text]] if not text.is_empty() else [],
				"plain": text, "dropped": PackedStringArray()}
		c.set_meta("uxml_rich", pr)
		c.set_meta("uxml_rich_src", text)
		c.remove_meta("uxml_rich_key")
		refresh()
		return true
	if c is Label or c is Button:
		if c.has_meta("uxml_full_text"):
			c.remove_meta("uxml_full_text")
			c.remove_meta("uxml_elided")
		c.set("text", text)
		relayout()
		return true
	return false


## Replace the element's `class` attribute and re-resolve. Runtime class
## changes are how game code switches authored variants (e.g. .selected).
func set_class(element_name: String, class_string: String) -> void:
	var el: UxmlElement = _by_name.get(element_name)
	if el == null:
		return
	# Through the observable model: notifies _on_model_changed (which
	# queues the restyle) only if the value actually changed. Classes the
	# control itself added (UxmlParts.control_classes) are kept.
	el.set_attribute("class", UxmlParts.merged_class(el, class_string))


func _on_model_changed(el: UxmlElement) -> void:
	_attr_dirty[el] = true
	_queue_restyle()
	var b = _behaviors.get(el)
	if b != null:
		b.on_model_changed()


## Re-resolve and re-lay out after changes the runtime cannot see — e.g.
## code mutating a Label's text directly.
func refresh() -> void:
	_full_apply = true
	_force_layout = true
	_scan_all = true  # also picks up direct edits of UxmlElement.attributes
	_queue_restyle()


# ---------------------------------------------------------------------------
# Virtualized ListView
# ---------------------------------------------------------------------------

## Give a ListView its items: `count` items, `bind.call(row: UxmlListRow,
## index: int)` fills a pooled row for an item. Only enough rows to cover
## the viewport exist; scrolling re-binds them. Call again whenever the
## item count changes or every row must be re-bound.
func set_list_source(list_name: String, count: int, bind: Callable) -> void:
	var el: UxmlElement = _by_name.get(list_name)
	if el == null or not _lists.has(el):
		return
	var info: Dictionary = _lists[el]
	info["count"] = maxi(0, count)
	info["bind"] = bind
	_list_refresh(el, true)


## Re-bind every visible row of a list (item data changed in place).
func refresh_list(list_name: String) -> void:
	var el: UxmlElement = _by_name.get(list_name)
	if el != null and _lists.has(el):
		_list_refresh(el, true)


## The pooled rows of a list (for games that want to style them directly).
func get_list_rows(list_name: String) -> Array:
	var el: UxmlElement = _by_name.get(list_name)
	return [] if el == null or not _lists.has(el) else _lists[el]["rows"]


## Instantiate each ListView's row pool from its item-template, before the
## cascade and controls exist, so rows are ordinary elements: author
## selectors, var() and states all reach them.
func _expand_lists() -> void:
	var lists: Array = []
	for el in _doc.root.walk():
		if el.local == "ListView":
			lists.append(el)
	for el in lists:
		var h := LIST_DEFAULT_ITEM_HEIGHT
		var hv = el.get_attribute("fixed-item-height")
		if hv != null:
			var n := UssValues.parse_number(String(hv))
			if is_nan(n) or n <= 0.0:
				_rt_warnings.append(UxmlDiagnostic.make("unsupported-value",
					'fixed-item-height="%s" is not a positive number; %s used' % [hv, LIST_DEFAULT_ITEM_HEIGHT],
					_doc.source, el.open_tag_start, _doc.path))
			else:
				h = n
		var vm = el.get_attribute("virtualization-method")
		if vm != null and String(vm) != "FixedHeight":
			_rt_warnings.append(UxmlDiagnostic.make("unsupported-value",
				'virtualization-method="%s" is not supported; FixedHeight used' % vm,
				_doc.source, el.open_tag_start, _doc.path))
		var alt_v = el.get_attribute("show-alternating-row-backgrounds")
		var alt: bool = alt_v != null and ["ContentOnly", "All", "true"].has(String(alt_v))
		var template: Array = _load_item_template(el)
		var pool := clampi(int(ceil(_list_pool_height() / h)) + 3, 3, 1000)
		var rows: Array = []
		for k in pool:
			var row := UxmlElement.new()
			row.prefix = el.prefix
			row.local = "VisualElement"
			row.open_tag_start = el.open_tag_start
			row.open_tag_end = el.open_tag_end
			row.attributes = [
				{"name": "class", "value": "unity-collection-view__item unity-list-view__item", "offset": 0},
				{"name": "style", "value": _row_style(h, false), "offset": 0},
			]
			for t in template:
				row.children.append(_clone_element(t, el))
			el.children.append(row)
			for sub in row.walk():
				_pooled[sub] = true
			rows.append(UxmlListRow.new(self, row))
		_lists[el] = {"rows": rows, "h": h, "count": 0, "bind": Callable(),
			"first": 0, "applied": 0, "alt": alt}


func _row_style(h: float, visible: bool) -> String:
	return "height: %spx; flex-shrink: 0;%s" % [h, "" if visible else " display: none;"]


## Rows must cover the tallest viewport a list can get: the document, the
## window, or the screen, whichever is largest (at least 1080px).
func _list_pool_height() -> float:
	var hgt := maxf(size.y, 1080.0)
	if is_inside_tree():
		hgt = maxf(hgt, get_viewport_rect().size.y)
	return maxf(hgt, float(DisplayServer.screen_get_size().y))


## The item template's visual top-level elements; its <Style> sheets are
## attached to the document scoped to the ListView.
func _load_item_template(el: UxmlElement) -> Array:
	var src = el.get_attribute("item-template")
	if src == null or String(src).is_empty():
		_rt_warnings.append(UxmlDiagnostic.make("malformed",
			"<ListView> has no item-template; it shows no rows",
			_doc.source, el.open_tag_start, _doc.path))
		return []
	var res := _resolver.resolve_text(String(src), _doc.path_of(el))
	if not res["ok"]:
		var d: Dictionary = res["diagnostic"].duplicate()
		d["message"] = 'item-template "%s" could not be loaded: %s' % [src, d["message"]]
		d["file"] = _doc.path
		var lc := UxmlDiagnostic.line_col(_doc.source, el.open_tag_start)
		d["offset"] = el.open_tag_start
		d["line"] = lc.x
		d["column"] = lc.y
		_rt_warnings.append(d)
		return []
	var parsed := UxmlParser.new().parse(res["text"], res["path"])
	_rt_warnings.append_array(parsed["warnings"])
	var out: Array = []
	for child in (parsed["root"] as UxmlElement).children:
		if child.local == "Style":
			var s = child.get_attribute("src")
			if s != null and not String(s).is_empty():
				UxmlLoader.attach_sheet(_doc, _resolver, String(s), res["path"], el)
			continue
		if UssControls.is_non_visual(child.local):
			continue
		out.append(child)
	return out


## Deep copy of a template element; diagnostics point at the ListView.
func _clone_element(t: UxmlElement, at: UxmlElement) -> UxmlElement:
	var c := UxmlElement.new()
	c.prefix = t.prefix
	c.local = t.local
	c.open_tag_start = at.open_tag_start
	c.open_tag_end = at.open_tag_end
	for a in t.attributes:
		c.attributes.append({"name": a["name"], "value": a["value"], "offset": 0})
	for ch in t.children:
		c.children.append(_clone_element(ch, at))
	return c


func _on_list_scrolled(_value: float, el: UxmlElement) -> void:
	_list_refresh(el, false)


## Map pool slots onto items from the current scroll position. Item i
## lives in slot i % pool (Unity-style recycling): when scrolling, rows that
## stay in view keep their item and only rows that scrolled out are re-bound
## (all of them when `rebind_all`). Slots past the end are hidden.
func _list_refresh(el: UxmlElement, rebind_all: bool) -> void:
	var info: Dictionary = _lists[el]
	var rows: Array = info["rows"]
	var pool := rows.size()
	var h: float = info["h"]
	var count: int = info["count"]
	var sc := _natives.get(el) as ScrollContainer
	var scroll := 0.0 if sc == null else float(sc.scroll_vertical)
	var first := clampi(int(floor(scroll / h)), 0, maxi(0, count - pool))
	info["first"] = first
	var bind: Callable = info["bind"]
	var rebound := false
	for k in pool:
		var row: UxmlListRow = rows[k]
		# The item in [first, first + pool) that maps to slot k.
		var idx := first + posmod(k - first, pool)
		var visible := idx < count
		row.element.set_attribute("style", _row_style(h, visible))
		if not visible:
			row.index = -1
			continue
		if row.index != idx or rebind_all:
			row.index = idx
			if info["alt"]:
				row.element.set_attribute("class",
					"unity-collection-view__item unity-list-view__item"
					+ (" unity-collection-view__item--alternative-background" if idx % 2 == 1 else ""))
			if bind.is_valid():
				bind.call(row, idx)
			rebound = true
	if rebound:
		relayout()  # bound content may change rows' internal layout
	_list_place(el)


## Rows are laid out in pool-slot order (slot k at its layout y); each is
## shifted by (item - slot) * h to its item's position, and the scroll
## content is sized for every item.
func _list_place(el: UxmlElement) -> void:
	var info: Dictionary = _lists[el]
	var h: float = info["h"]
	var rows: Array = info["rows"]
	var applied: Dictionary = info["applied_rows"] if info.has("applied_rows") else {}
	for k in rows.size():
		var row: UxmlListRow = rows[k]
		var want := 0 if row.index < 0 else row.index - k
		var have: int = applied.get(k, 0)
		if want != have:
			var c: Control = _controls.get(row.element)
			if c != null:
				c.position.y += (want - have) * h
			applied[k] = want
	info["applied_rows"] = applied
	var content := _scroll.get(el) as Control
	if content != null:
		var cnt: int = info["count"]
		var top := 0.0
		if not rows.is_empty() and cnt > 0:
			var c0: Control = _controls.get((rows[0] as UxmlListRow).element)
			if c0 != null:
				top = c0.position.y - float(applied.get(0, 0)) * h
		content.custom_minimum_size = Vector2(
			content.custom_minimum_size.x, top + cnt * h if cnt > 0 else 0.0)


## A layout pass put every row back at its slot position.
func _lists_after_layout() -> void:
	for el in _lists:
		_lists[el]["applied_rows"] = {}
		_list_place(el)


## Re-lay out only — for content changes that cannot affect styling, e.g.
## game code updating Label/Button text every frame. Cheaper than
## refresh(): the cascade is still checked incrementally, but controls are
## not re-applied unless their computed style actually changed. Coalesced
## with other pending restyles like every other mutation.
func relayout() -> void:
	_force_layout = true
	_queue_restyle()


# ---------------------------------------------------------------------------
# Data binding (Unity 6 runtime binding; see runtime/uxml_binding.gd)
# ---------------------------------------------------------------------------
# `element` arguments: null or "" = the document root, a name, a
# UxmlElement, or one of the element's Controls.

## Unity VisualElement.dataSource. Any Object, Dictionary or Array. The
## document-level source and sources set on named elements survive
## load_document()/reload().
func set_data_source(source: Variant, element: Variant = null) -> void:
	_binding.set_data_source(source, element)


func get_data_source(element: Variant = null) -> Variant:
	return _binding.get_data_source(element)


## Unity VisualElement.dataSourcePath (PropertyPath text, e.g. "a.b[2]").
## Returns false for text that is not a property path.
func set_data_source_path(path: String, element: Variant = null) -> bool:
	return _binding.set_data_source_path(path, element)


func get_data_source_path(element: Variant = null) -> String:
	return _binding.get_data_source_path(element)


## Unity GetHierarchicalDataSourceContext: {source, path}.
func get_data_source_context(element: Variant = null) -> Dictionary:
	return _binding.get_context(element)


## The nearest data-source-type at or above the element.
func get_data_source_type(element: Variant = null) -> String:
	return _binding.get_data_source_type(element)


## Unity SetBinding(property, new DataBinding{...}). `options`: mode
## ("TwoWay", "ToSource", "ToTarget", "ToTargetOnce"), trigger
## ("OnSourceChanged", "EveryUpdate", "WhenDirty"), data_source, to_ui and
## to_source (Arrays of converter group ids).
func add_binding(element: Variant, property: String, path: String, options: Dictionary = {}) -> bool:
	return _binding.add_binding(element, property, path, options)


## Unity ClearBinding. "" removes every binding of the element.
func remove_binding(element: Variant, property: String = "") -> void:
	_binding.remove_binding(element, property)


func get_bindings(element: Variant) -> Array:
	return _binding.get_bindings(element)


## The source (null = every source) changed at `path` ("" = anywhere).
## OnSourceChanged bindings below that path update on the next flush.
func notify_changed(source: Variant = null, path: String = "") -> void:
	_binding.notify_changed(source, path)


## Unity Binding.MarkDirty (for WhenDirty bindings, or to force one).
func mark_binding_dirty(element: Variant, property: String = "") -> void:
	_binding.mark_dirty(element, property)


## Run pending binding updates now instead of at the end of the frame.
func update_bindings() -> void:
	_binding.flush()


## Unity ConverterGroups: add `converter` (value -> value) to a group that
## `source-to-ui-converters` / `ui-to-source-converters` name. Global.
static func register_converter(group_id: String, converter: Callable, source_type: int = -1) -> void:
	UxmlBinding.register_converter(group_id, converter, source_type)


static func unregister_converter_group(group_id: String) -> void:
	UxmlBinding.unregister_converter_group(group_id)


static func register_global_converter(converter: Callable, source_type: int = -1) -> void:
	UxmlBinding.register_global_converter(converter, source_type)


## Give a `data-source` attribute value (Unity asset reference) a Godot
## source. null removes the entry. Global; register before the load.
static func register_data_source_asset(key: String, source: Variant) -> void:
	UxmlBinding.register_data_source_asset(key, source)


# ---------------------------------------------------------------------------
# View data (view-data-key) and focus ring (tabindex)
# ---------------------------------------------------------------------------

## View state per full view-data-key ("outer__inner"):
## {key: {"scroll_offset": Vector2}}. Save it with the game and give it
## back with set_view_data(). The document also keeps it across
## load_document()/reload().
func get_view_data() -> Dictionary:
	return _attrs.get_view_data()


func set_view_data(data: Dictionary) -> void:
	_attrs.set_view_data(data)


## The focus targets in Tab order, when the document uses tabindex.
func get_focus_ring() -> Array:
	return _attrs.focus_ring()
